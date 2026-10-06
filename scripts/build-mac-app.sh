#!/bin/bash
# Builds dist/Courtside.app: a native Mac window that runs Courtside from its own clone of the
# GitHub repo (~/Library/Application Support/Courtside/repo), updating it on launch.
# Needs Xcode (or the Command Line Tools), Node, git and ffmpeg. Usage: npm run build:app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_OUT:-dist/Courtside.app}"
NODE="$(command -v node)" || { echo "node not found on PATH"; exit 1; }
GIT="$(command -v git)" || { echo "git not found on PATH"; exit 1; }
FFMPEG="$(command -v ffmpeg || true)"
[ -n "$FFMPEG" ] || echo "warning: ffmpeg not found; in-app playback won't work (brew install ffmpeg)"
REPO_URL="$(git remote get-url origin)"
VERSION="$(node -p 'require("./package.json").version')"

# Apps opened from Finder don't get your shell's PATH, so record where the tools live.
APP_PATH=""
for dir in "$(dirname "$NODE")" "$(dirname "$GIT")" ${FFMPEG:+"$(dirname "$FFMPEG")"} /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  case ":$APP_PATH:" in *":$dir:"*) ;; *) APP_PATH="${APP_PATH:+$APP_PATH:}$dir" ;; esac
done

echo "Building $APP"
echo "  repo: $REPO_URL"
echo "  node: $NODE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/Courtside" mac/Courtside.swift -framework Cocoa -framework WebKit

cat > "$APP/Contents/Resources/launch.json" <<JSON
{ "repoURL": "$REPO_URL", "node": "$NODE", "path": "$APP_PATH" }
JSON

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Courtside</string>
  <key>CFBundleDisplayName</key><string>Courtside</string>
  <key>CFBundleIdentifier</key><string>com.ismaytur.courtside</string>
  <key>CFBundleExecutable</key><string>Courtside</string>
  <key>CFBundleIconFile</key><string>Courtside</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.sports</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Icon: the app draws it, then sips/iconutil turn it into an .icns.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$APP/Contents/MacOS/Courtside" --render-icon "$TMP/icon.png"
mkdir "$TMP/Courtside.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/Courtside.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/Courtside.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/Courtside.iconset" -o "$APP/Contents/Resources/Courtside.icns"

# Ad-hoc signature: enough to run on this Mac without a developer account.
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
echo "Drag it to /Applications (or run: open $APP)."
