#!/bin/bash
# Builds dist/Courtside.app (or $APP_OUT): the release binary plus ffmpeg/ffprobe, an icon and
# an Info.plist, ad-hoc signed so macOS runs it on this Mac. Run via `mise run build`.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="${APP_OUT:-$ROOT/dist/Courtside.app}"
FFBIN="$ROOT/vendor/build/ffmpeg/bin"

scripts/vendor/all.sh --if-missing
swift build -c release --product Courtside
BIN="$(swift build -c release --show-bin-path)/Courtside"

VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
[ -z "$(git status --porcelain 2>/dev/null)" ] || VERSION="$VERSION-dirty"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Courtside"
cp "$FFBIN/ffmpeg" "$FFBIN/ffprobe" "$APP/Contents/Resources/"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" Resources/Info.plist.template > "$APP/Contents/Info.plist"

ICONS="$(mktemp -d)"
trap 'rm -rf "$ICONS"' EXIT
swift Resources/make-icon.swift "$ICONS/AppIcon.iconset"
iconutil -c icns "$ICONS/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Inner binaries first, then the bundle (which seals the Info.plist and resources).
codesign --force --sign - "$APP/Contents/Resources/ffmpeg" "$APP/Contents/Resources/ffprobe"
codesign --force --sign - "$APP/Contents/MacOS/Courtside"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($VERSION, $(du -sh "$APP" | cut -f1))"
