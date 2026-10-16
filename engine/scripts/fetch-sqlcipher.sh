#!/usr/bin/env bash
# Downloads and verifies SQLCipher 4.19.0 (prebuilt xcframework) into engine/.local/.
# Resumes across stalls: a connection that sends < 3 KB/s for 10 s is dropped and retried.
set -euo pipefail
cd "$(dirname "$0")/.."
URL="https://github.com/sqlcipher/SQLCipher.swift/releases/download/4.19.0/SQLCipher.xcframework.zip"
SUM="39f02d2f04f0de2ba1facf215550bfc6e6e2c9971d5d8ebb0cdd604874781bd7"
mkdir -p .local
if [ -d .local/SQLCipher.xcframework ]; then echo "SQLCipher already present"; exit 0; fi
ZIP=.local/SQLCipher.xcframework.zip
tries=0
until [ "$(shasum -a 256 "$ZIP" 2>/dev/null | cut -d' ' -f1)" = "$SUM" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 300 ]; then echo "giving up after $tries attempts" >&2; exit 1; fi
  curl -sL -C - --speed-limit 3000 --speed-time 10 --connect-timeout 10 -o "$ZIP" "$URL" || true
  sleep 2
done
unzip -q -o "$ZIP" -d .local
echo "SQLCipher ready"
