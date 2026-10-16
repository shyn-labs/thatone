#!/usr/bin/env bash
# Builds app/build/ThatOne.app (ad-hoc signed; for use on this Mac). `--install` also copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
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
