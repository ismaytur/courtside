# Shared by the vendor scripts. Sourced, not run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR="$ROOT/vendor"
DOWNLOADS="$VENDOR/downloads"   # tarballs (gitignored)
SRC="$VENDOR/src"               # extracted sources (gitignored)
BUILD="$VENDOR/build"           # install prefixes (gitignored)
. "$ROOT/scripts/vendor/versions.sh"

# Keep Homebrew (and anything else on the user's PATH) out of the build: only the system, Xcode
# and the mise-pinned cmake/ninja. Homebrew's ffmpeg/openssl/pkg-config must never be picked up.
tool_dirs=""
for t in cmake ninja; do
  if p="$(command -v "$t" 2>/dev/null)"; then tool_dirs="$tool_dirs$(dirname "$p"):"; fi
done
export PATH="${tool_dirs}/usr/bin:/bin:/usr/sbin:/sbin"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
export MACOSX_DEPLOYMENT_TARGET=14.0
JOBS="$(sysctl -n hw.ncpu)"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# fetch NAME URL SHA256 -> extracts into $SRC/NAME (fresh each time the tarball changes)
fetch() {
  local name="$1" url="$2" sha="$3" file
  file="$DOWNLOADS/$(basename "$url")"
  mkdir -p "$DOWNLOADS" "$SRC"
  if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]]; then
    log "download $name: $url"
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local got; got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    echo "checksum mismatch for $file: expected $sha, got $got" >&2; rm -f "$file"; exit 1
  fi
  if [[ ! -f "$SRC/$name/.extracted-$sha" ]]; then
    log "extract $name"
    rm -rf "$SRC/$name"; mkdir -p "$SRC/$name"
    shift 3
    tar -xf "$file" -C "$SRC/$name" --strip-components 1 "$@"
    touch "$SRC/$name/.extracted-$sha"
  fi
}
