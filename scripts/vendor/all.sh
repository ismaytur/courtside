#!/bin/bash
# Build everything native the app links or bundles: libtorrent (+ boost headers) and ffmpeg.
#   --if-missing   skip if the outputs are already there (used by `mise run build`/`test`)
. "$(dirname "$0")/common.sh"

if [[ "${1:-}" == "--if-missing" ]] \
  && [[ -f "$BUILD/libtorrent/lib/libtorrent-rasterbar.a" && -x "$BUILD/ffmpeg/bin/ffmpeg" ]]; then
  exit 0
fi
"$ROOT/scripts/vendor/libtorrent.sh"
"$ROOT/scripts/vendor/ffmpeg.sh"
log "vendor done"
ls -l "$BUILD/libtorrent/lib/libtorrent-rasterbar.a" "$BUILD/ffmpeg/bin/ffmpeg" "$BUILD/ffmpeg/bin/ffprobe"
