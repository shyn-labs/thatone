#!/usr/bin/env bash
# Packs app/build/release/ThatOne.app into dist/release/ThatOne-v<version>-darwin-arm64.tar.gz (repo root), member
# ThatOne.app at the archive root. Every entry gets a fixed owner (uid/gid 0, shyn:staff) and no extended attributes or
# AppleDouble ._ files, so the archive carries nothing of the builder's account. Run by build-app.sh --release.
# The archive is written as <final>.partial (the gate scans that; build-app.sh renames it to <final> only when the gate
# passes). Any earlier <final>, .partial or .rejected is removed first, so no stale file can pass for this run's package.
# The LAST line printed to stdout is the final intended path (relative to the repo root).
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=app/build/release/ThatOne.app
[ -d "$APP" ] || { echo "package-release.sh: $APP not found: run app/scripts/build-app.sh --release first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Resources/Info.plist)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "package-release.sh: unexpected CFBundleShortVersionString: $VERSION" >&2; exit 1; }
OUT="dist/release/ThatOne-v$VERSION-darwin-arm64.tar.gz"
mkdir -p dist/release
rm -f "$OUT" "$OUT.partial" "$OUT.rejected"
# /usr/bin/tar is bsdtar (libarchive); a GNU tar earlier on PATH would not take these options.
COPYFILE_DISABLE=1 /usr/bin/tar --uid 0 --gid 0 --uname shyn --gname staff --no-xattrs --no-mac-metadata \
  -czf "$OUT.partial" -C app/build/release ThatOne.app
echo "release archive (not yet gated): $OUT.partial"
echo "sha256: $(shasum -a 256 "$OUT.partial" | cut -d' ' -f1)"
echo "$OUT"
