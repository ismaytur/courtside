#!/bin/bash
# Copies the built app to /Applications, quitting a running Courtside first.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${APP_OUT:-$PWD/dist/Courtside.app}"
DEST="/Applications/Courtside.app"
[ -d "$SRC" ] || { echo "Nothing to install at $SRC; run: mise run build" >&2; exit 1; }

if pgrep -x Courtside >/dev/null; then
  osascript -e 'tell application id "com.ismaytur.courtside" to quit' || true
  for _ in $(seq 1 20); do pgrep -x Courtside >/dev/null || break; sleep 0.5; done
  pkill -x Courtside || true
fi
rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "Installed $DEST"
