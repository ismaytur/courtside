#!/bin/bash
# Builds dist/Courtside.app: a native Mac window that runs Courtside from its own clone of the
# GitHub repo (~/Library/Application Support/Courtside/repo), updating it on launch.
# Node is bundled in the app (official build, version line from .nvmrc), so the Mac doesn't need
# its own. Needs Xcode (or the Command Line Tools), git, ffmpeg (brew) and internet for the first
# Node download. Usage: npm run build:app  (or bash scripts/build-mac-app.sh, no Node needed)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_OUT:-dist/Courtside.app}"
GIT="$(command -v git)" || { echo "git not found on PATH"; exit 1; }
FFMPEG="$(command -v ffmpeg || true)"
[ -n "$FFMPEG" ] || echo "warning: ffmpeg not found; in-app playback won't work (brew install ffmpeg)"
REPO_URL="$(git remote get-url origin)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- Node: the official macOS build, checksum-verified, cached between builds ----------------
# .nvmrc holds a major line ("24": newest 24.x) or an exact version ("24.9.0").
WANT="$(tr -d ' v\n' < .nvmrc)"
case "$(uname -m)" in arm64) NARCH=arm64 ;; x86_64) NARCH=x64 ;; *) echo "unsupported CPU $(uname -m)"; exit 1 ;; esac
case "$WANT" in *.*) DIST="https://nodejs.org/dist/v$WANT" ;; *) DIST="https://nodejs.org/dist/latest-v$WANT.x" ;; esac
CACHE="$HOME/Library/Caches/Courtside"
mkdir -p "$CACHE"
SUMS="$(curl -fsSL "$DIST/SHASUMS256.txt")" || { echo "couldn't reach $DIST (offline?)"; exit 1; }
LINE="$(grep -E " node-v[0-9.]+-darwin-$NARCH\.tar\.gz\$" <<<"$SUMS" | head -1)"
[ -n "$LINE" ] || { echo "no darwin-$NARCH build listed in $DIST"; exit 1; }
SHA="${LINE%% *}"; TARBALL="${LINE##* }"
if [ ! -f "$CACHE/$TARBALL" ]; then
  echo "Downloading $TARBALL"
  curl -fL --progress-bar -o "$CACHE/$TARBALL.part" "$DIST/$TARBALL"
  mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi
echo "$SHA  $CACHE/$TARBALL" | shasum -a 256 -c - >/dev/null || { rm -f "$CACHE/$TARBALL"; echo "checksum mismatch for $TARBALL (deleted, try again)"; exit 1; }
tar -xzf "$CACHE/$TARBALL" -C "$TMP"
NODE_SRC="$TMP/${TARBALL%.tar.gz}"
VERSION="$("$NODE_SRC/bin/node" -p 'require("./package.json").version')"

# Apps opened from Finder don't get your shell's PATH, so record where git and ffmpeg live.
# The app puts its bundled node/bin in front of this at launch.
APP_PATH=""
for dir in "$(dirname "$GIT")" ${FFMPEG:+"$(dirname "$FFMPEG")"} /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  case ":$APP_PATH:" in *":$dir:"*) ;; *) APP_PATH="${APP_PATH:+$APP_PATH:}$dir" ;; esac
done

echo "Building $APP"
echo "  repo: $REPO_URL"
echo "  node: $("$NODE_SRC/bin/node" --version) ($NARCH, bundled)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/node"
# bin (node, npm, npx) and lib (npm itself; the app runs `npm ci` after updates). Not headers/docs.
ditto "$NODE_SRC/bin" "$APP/Contents/Resources/node/bin"
ditto "$NODE_SRC/lib" "$APP/Contents/Resources/node/lib"
ditto "$NODE_SRC/LICENSE" "$APP/Contents/Resources/node/LICENSE"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/Courtside" mac/Courtside.swift -framework Cocoa -framework WebKit

cat > "$APP/Contents/Resources/launch.json" <<JSON
{ "repoURL": "$REPO_URL", "path": "$APP_PATH" }
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
