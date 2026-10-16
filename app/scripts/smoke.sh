#!/usr/bin/env bash
# End-to-end smoke test of the built app: launch it over a throwaway data folder with the fake embedding worker, drive it
# with the CLI over the socket, and check one-instance and quit. Prints SMOKE OK on success.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app/build/ThatOne.app/Contents/MacOS/ThatOne"
[ -x "$APP" ] || { echo "build the app first: app/scripts/build-app.sh"; exit 1; }
(cd "$ROOT/engine" && swift build --product thatone > /dev/null)
CLI="$(cd "$ROOT/engine" && swift build --show-bin-path)/thatone"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ths.XXXXXX")"          # short: Unix socket paths are limited to 103 bytes
export THATONE_HOME="$WORK/home" THATONE_KEY_HEX="$(printf '07%.0s' $(seq 32))" THATONE_NO_HOTKEY=1
mkdir -p "$THATONE_HOME" "$WORK/pics"
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "SMOKE FAILED: $*"; exit 1; }

cat > "$THATONE_HOME/config.json" <<JSON
{"folders": [], "exclude": [], "sidecar": ["$ROOT/bakeoff/.venv/bin/python", "$ROOT/bakeoff/tests/fake_worker.py"], "sidecarEnv": {}}
JSON
"$ROOT/bakeoff/.venv/bin/python" - "$WORK/pics" <<'PY'
import struct, sys, zlib
def png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
for i in range(3): png(f"{sys.argv[1]}/img{i}.png", 200 + i * 7, 120, (30 * i, 90, 200))
PY

"$APP" > "$WORK/app.log" 2>&1 &
PID=$!
for _ in $(seq 60); do "$CLI" status 2>/dev/null | grep -q "app:" && break; sleep 0.5; done
"$CLI" status | grep -q "app:" || fail "the app did not answer on its socket ($(tail -3 "$WORK/app.log"))"

"$CLI" index "$WORK/pics" | tail -3 | grep -q "indexed 3" || fail "index did not finish with 3 images"
"$CLI" search anything --json | grep -q '"paths"' || fail "search returned nothing"
"$CLI" ui show_panel | grep -q ok || fail "ui show_panel"
"$CLI" ui hide_panel | grep -q ok || fail "ui hide_panel"

"$APP" > "$WORK/second.log" 2>&1 &
SECOND=$!
for _ in $(seq 20); do kill -0 "$SECOND" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$SECOND" 2>/dev/null; then kill "$SECOND"; fail "a second launch did not exit"; fi
kill -0 "$PID" 2>/dev/null || fail "the first instance died"

"$CLI" ui quit | grep -q ok || fail "ui quit"
for _ in $(seq 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$PID" 2>/dev/null && fail "the app did not quit"
PID=""
[ ! -e "$THATONE_HOME/thatone.sock" ] || fail "the socket file was left behind"
echo "SMOKE OK"
