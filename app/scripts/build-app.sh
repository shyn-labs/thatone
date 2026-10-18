#!/usr/bin/env bash
# Builds app/build/ThatOne.app (ad-hoc signed; for use on this Mac). `--install` also copies it to ~/Applications.
# `--release` instead builds the distributable app/build/release/ThatOne.app and its archive (see the release block below).
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE=0
for arg in "$@"; do case "$arg" in --release) RELEASE=1 ;; esac; done
if [ "$RELEASE" = 1 ]; then
  # Release build. It writes only app/build/release/ThatOne.app, app/.build-release (its own SwiftPM scratch, so the dev
  # build cache is left alone) and dist/release/; it never touches build/ThatOne.app and is never installed.
  for arg in "$@"; do
    case "$arg" in
      --release) ;;
      --install) echo "build-app.sh: --release --install is not supported: the installed app stays a dev build (a release" \
                      "build is signed with a different identity, so macOS would ask for Keychain and Photos access again)" >&2
                 exit 2 ;;
      *) echo "build-app.sh: unknown option: $arg (usage: build-app.sh [--install | --release])" >&2; exit 2 ;;
    esac
  done
  # Environment that would weaken the gate is refused before anything is built (the gate, run with --release, refuses
  # the same): a replacement denylist or allowlist (SHYN_LEAK_DENYLIST / SHYN_ARTIFACT_ALLOW set at all, even empty)
  # and a /Users/runner home, which turns on the gate's CI mode (no home/username needles). --ci is not an option here.
  for var in SHYN_LEAK_DENYLIST SHYN_ARTIFACT_ALLOW; do
    if [ -n "${!var+set}" ]; then
      echo "build-app.sh --release: $var is set: a release is gated with the owner's default denylist and allowlist" \
           "only; unset it" >&2
      exit 1
    fi
  done
  if [ "${HOME-}" = /Users/runner ]; then
    echo "build-app.sh --release: the home dir is the GitHub runner's, which would turn on the gate's CI mode;" \
         "build releases on the owner's machine" >&2
    exit 1
  fi
  # The gate reads the denylist, allowlist and home needle from HOME, so a release runs with the user's real home only.
  # A startup file (BASH_ENV / ENV) or an exported shell function can replace any command the release decision runs (a
  # function may even be named /usr/bin/env), so both are refused; the tools that decide the outcome are called by full
  # path below.
  REAL_HOME="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null \
               | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')"
  if [[ -z "$REAL_HOME" || "${HOME-}" != "$REAL_HOME" ]]; then
    echo "build-app.sh --release: HOME is not this user's home dir (the gate reads its denylist, allowlist and home" \
         "needle from it); build with the real HOME" >&2
    exit 1
  fi
  if [[ -n "${BASH_ENV+set}${ENV+set}" || -n "$(builtin declare -F)" ]]; then
    echo "build-app.sh --release: BASH_ENV, ENV or an exported shell function is set; they can replace the commands" \
         "that decide the release; unset them" >&2
    exit 1
  fi
  # Signing identity: THATONE_RELEASE_IDENTITY (a name or SHA-1 hash), else the project's self-signed "Shyn Dev".
  # THATONE_SIGN_IDENTITY is the DEV build's variable and is ignored here. Checked before anything is built. Refused:
  # ad-hoc ("-": no stable identity, and it hides that no real identity was chosen), any "Apple Development" certificate
  # (it carries a person's Apple ID and team id into every copy of the app) and any identity whose resolved name is not in
  # THATONE_ALLOWED_AUTHORITIES (comma separated, exact; unset means "Shyn Dev"), the same list the gate enforces
  # afterwards. Set but without entries (empty, only commas or spaces) it is refused; set, a NOTICE prints its entry count.
  REL_IDENTITY="${THATONE_RELEASE_IDENTITY:-Shyn Dev}"
  refuse() { echo "build-app.sh --release: refusing to sign with $1: $2; set THATONE_RELEASE_IDENTITY to a neutral identity" \
                  "(default \"Shyn Dev\"; THATONE_SIGN_IDENTITY is ignored by --release)" >&2; exit 1; }
  if [ "$REL_IDENTITY" = "-" ]; then refuse "the ad-hoc identity (-)" "a release needs a stable, named identity"; fi
  case "$REL_IDENTITY" in "Apple Development"*) refuse "an \"Apple Development\" identity" "that certificate names a person's Apple ID and team" ;; esac
  # `find-identity` without -v: a self-signed identity is listed but not "valid" (its certificate is not trusted).
  REL_NAME=""
  WANT_HASH="$(printf '%s' "$REL_IDENTITY" | tr 'a-f' 'A-F')"
  while IFS= read -r line; do
    if [ "${line#* }" = "$REL_IDENTITY" ] || [ "${line%% *}" = "$WANT_HASH" ]; then REL_NAME="${line#* }"; break; fi
  done < <(security find-identity -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)".*$/\1 \2/p')
  if [ -z "$REL_NAME" ]; then refuse "\"$REL_IDENTITY\"" "no code-signing identity with that name or hash is in the keychain"; fi
  case "$REL_NAME" in "Apple Development"*) refuse "an \"Apple Development\" identity (given by hash)" "that certificate names a person's Apple ID and team" ;; esac
  AUTH_OK=0
  AUTH_N=0
  IFS=',' read -r -a AUTH_LIST <<< "${THATONE_ALLOWED_AUTHORITIES-Shyn Dev}"
  for auth in ${AUTH_LIST[@]+"${AUTH_LIST[@]}"}; do
    auth="${auth#"${auth%%[![:space:]]*}"}"; auth="${auth%"${auth##*[![:space:]]}"}"
    if [ -n "$auth" ]; then AUTH_N=$((AUTH_N + 1)); fi
    if [ -n "$auth" ] && [ "$auth" = "$REL_NAME" ]; then AUTH_OK=1; fi
  done
  if [ "$AUTH_N" = 0 ]; then
    echo "build-app.sh --release: THATONE_ALLOWED_AUTHORITIES is set but has no entries: unset it for the default" \
         "\"Shyn Dev\" or list the allowed authorities" >&2
    exit 1
  fi
  if [ -n "${THATONE_ALLOWED_AUTHORITIES+set}" ]; then
    echo "NOTICE: signing authorities set by THATONE_ALLOWED_AUTHORITIES ($AUTH_N entries)"
  fi
  if [ "$AUTH_OK" != 1 ]; then
    echo "build-app.sh --release: the identity \"$REL_NAME\" is not in THATONE_ALLOWED_AUTHORITIES (\"${THATONE_ALLOWED_AUTHORITIES-Shyn Dev}\"):" \
         "the gate would reject the package; choose an allowed identity with THATONE_RELEASE_IDENTITY or widen" \
         "THATONE_ALLOWED_AUTHORITIES" >&2
    exit 1
  fi

  # Path scrub: no debug stabs (-Xlinker -S: they held absolute object and source paths in the builder's checkout), and any
  # path the compilers would still embed is rewritten to /build/... (checkouts first: the more specific prefix).
  ROOT="$(cd .. && pwd)"
  SCRATCH="$(pwd)/.build-release"
  ../engine/scripts/fetch-sqlcipher.sh                       # no-op when the framework is already present
  swift build -c release --product ThatOne --scratch-path "$SCRATCH" \
    -Xlinker -S \
    -Xswiftc -file-prefix-map -Xswiftc "$SCRATCH/checkouts=/build/checkouts" \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/build/thatone" \
    -Xcc "-ffile-prefix-map=$SCRATCH/checkouts=/build/checkouts" \
    -Xcc "-ffile-prefix-map=$ROOT=/build/thatone"
  BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/ThatOne"
  OUT=build/release/ThatOne.app
  rm -rf "$OUT"
  mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
  cp "$BIN" "$OUT/Contents/MacOS/ThatOne"
  cp -R "$(dirname "$BIN")/SQLCipher.framework" "$OUT/Contents/Frameworks/"
  install_name_tool -add_rpath @executable_path/../Frameworks "$OUT/Contents/MacOS/ThatOne"
  codesign --force --sign "$REL_IDENTITY" "$OUT/Contents/Frameworks/SQLCipher.framework"
  cp Resources/Info.plist "$OUT/Contents/Info.plist"
  plutil -lint "$OUT/Contents/Info.plist" > /dev/null
  codesign --force --sign "$REL_IDENTITY" --identifier com.shynlabs.thatone "$OUT"
  codesign --verify --strict "$OUT"
  echo "built app/$OUT (release, signed with \"$REL_NAME\")"
  # package-release.sh removes any earlier package, writes <final>.partial and prints <final> (repo-root relative) as its
  # last line. The gate scans the .partial exactly as it would ship (contents, archive headers, names, link targets,
  # signing authority of every bundle); only a pass renames it to <final>, a failure leaves <final>.rejected and no file
  # under the publish name. Test-only hooks never reach the gate from here. The gate is always the repo's own
  # scripts/check-artifact-leaks.py (no override variable; THATONE_GATE no longer exists), run by the system interpreter
  # in isolated mode (-I: no PYTHON* variables, no user site, no python3 from PATH), with --release.
  PKG_OUTPUT="$(scripts/package-release.sh)"
  printf '%s\n' "$PKG_OUTPUT"
  PKG="../$(printf '%s\n' "$PKG_OUTPUT" | /usr/bin/tail -n 1)"
  if /usr/bin/env -u THATONE_CODESIGN -u SHYN_GATE_USERNAME -u SHYN_GATE_TEST_DELAY_MS -u THATONE_GATE \
       /usr/bin/python3 -I ../scripts/check-artifact-leaks.py --release --tarball "$PKG.partial"; then
    /bin/mv -f "$PKG.partial" "$PKG"
    echo "OK: release package passed the gate: ${PKG#../}"
  else
    /bin/mv -f "$PKG.partial" "$PKG.rejected"
    echo "build-app.sh: artifact leak scan failed: not releasing (rejected package kept as ${PKG#../}.rejected; no file" \
         "exists under the publish name)" >&2
    exit 1
  fi
  exit 0
fi
# A stable signature keeps macOS's Keychain and Photos approvals across rebuilds. Use THATONE_SIGN_IDENTITY, else the first
# "Apple Development" identity in the keychain, else fall back to ad-hoc ("-"), which asks again after every rebuild.
IDENTITY="${THATONE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\([0-9A-F]\{40\}\) "Apple Development.*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
../engine/scripts/fetch-sqlcipher.sh                         # no-op when the framework is already present
swift build -c release --product ThatOne
BIN="$(swift build -c release --show-bin-path)/ThatOne"
rm -rf build/ThatOne.app
mkdir -p build/ThatOne.app/Contents/MacOS build/ThatOne.app/Contents/Resources build/ThatOne.app/Contents/Frameworks
cp "$BIN" build/ThatOne.app/Contents/MacOS/ThatOne
# SQLCipher is a dynamic framework: ship it inside the bundle and let the binary find it there.
cp -R "$(dirname "$BIN")/SQLCipher.framework" build/ThatOne.app/Contents/Frameworks/
install_name_tool -add_rpath @executable_path/../Frameworks build/ThatOne.app/Contents/MacOS/ThatOne
codesign --force --sign "$IDENTITY" build/ThatOne.app/Contents/Frameworks/SQLCipher.framework
cp Resources/Info.plist build/ThatOne.app/Contents/Info.plist
plutil -lint build/ThatOne.app/Contents/Info.plist > /dev/null
codesign --force --sign "$IDENTITY" --identifier com.shynlabs.thatone build/ThatOne.app
codesign --verify --strict build/ThatOne.app
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ThatOne.app"
  cp -R build/ThatOne.app "$HOME/Applications/ThatOne.app"
  echo "installed $HOME/Applications/ThatOne.app"
fi
echo "built $(pwd)/build/ThatOne.app (signed with $([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "identity ${IDENTITY:0:8}…"))"
