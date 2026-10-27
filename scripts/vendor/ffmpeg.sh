#!/bin/bash
# ffmpeg + ffprobe, trimmed to what Courtside needs, LGPL (no --enable-gpl / nonfree), static
# (only macOS system libraries and frameworks), arm64. Output: vendor/build/ffmpeg/bin/{ffmpeg,ffprobe}
#
# Kept: reading MKV/MP4/TS/HLS, writing TS/MP4/HLS (+ MKV for test files), H.264/HEVC/AAC/AC-3
# decoding, AAC encoding (native + AudioToolbox), VideoToolbox H.264/HEVC encode/decode (the
# re-encode fallback for broken GOPs), file/pipe/http input (http = torrent-backed byte source).
. "$(dirname "$0")/common.sh"

fetch ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA256"

log "build ffmpeg $FFMPEG_VERSION"
out="$BUILD/ffmpeg"
work="$BUILD/.ffmpeg-work"
rm -rf "$work" "$out"
mkdir -p "$work"
cd "$work"

"$SRC/ffmpeg/configure" \
  --prefix="$out" \
  --cc=clang --cxx=clang++ --arch=arm64 --target-os=darwin --enable-cross-compile \
  --pkg-config=false \
  --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  --disable-autodetect --disable-everything \
  --disable-doc --disable-ffplay --disable-debug --disable-shared --enable-static \
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
  --enable-protocol=file,pipe,http,tcp \
  --enable-demuxer=matroska,mov,mpegts,hls,aac,h264,hevc \
  --enable-muxer=mp4,mov,hls,segment,mpegts,matroska,null,adts \
  --enable-parser=h264,hevc,aac,ac3 \
  --enable-decoder=h264,hevc,aac,ac3,eac3 \
  --enable-encoder=aac,aac_at,h264_videotoolbox,hevc_videotoolbox \
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata,h264_metadata,filter_units,setts \
  --enable-filter=testsrc2,sine,scale,format,aformat,aresample,anull,null,setpts,asetpts,fps,trim,atrim,copy,acopy
make -j "$JOBS"
make install
cd "$ROOT"
rm -rf "$work" "$out/include" "$out/lib" "$out/share"  # only the two programs are used

# Prove nothing outside macOS itself is linked (no Homebrew, no /usr/local).
for bin in ffmpeg ffprobe; do
  if otool -L "$out/bin/$bin" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/Library/)'; then
    echo "$bin links a non-system library (see above)" >&2; exit 1
  fi
done
"$out/bin/ffmpeg" -hide_banner -version | head -3
ls -l "$out/bin/ffmpeg" "$out/bin/ffprobe"
