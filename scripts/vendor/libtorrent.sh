#!/bin/bash
# libtorrent-rasterbar, static, arm64, against boost *headers* (nothing from boost is compiled).
# No OpenSSL/GnuTLS: on macOS libtorrent hashes with CommonCrypto and does peer encryption with
# its own built-in RC4/DH. Output: vendor/build/libtorrent/{include,lib/libtorrent-rasterbar.a}
# and vendor/build/boost/include (headers the bridge compiles against).
. "$(dirname "$0")/common.sh"

fetch libtorrent "$LIBTORRENT_URL" "$LIBTORRENT_SHA256"
fetch boost "$BOOST_URL" "$BOOST_SHA256" "boost_${BOOST_VERSION//./_}/boost"

mkdir -p "$BUILD/boost/include"
rm -rf "$BUILD/boost/include/boost"
# Copy the headers, don't symlink them: a symlink into vendor/src breaks if that folder is
# cleaned, and the build then fails with "boost/config.hpp not found".
cp -R "$SRC/boost/boost" "$BUILD/boost/include/boost"

log "build libtorrent $LIBTORRENT_VERSION"
out="$BUILD/libtorrent"
work="$BUILD/.libtorrent-work"
rm -rf "$work" "$out"
cmake -S "$SRC/libtorrent" -B "$work" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$out" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibGcrypt=ON \
  -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
  -DBoost_INCLUDE_DIR="$SRC/boost" \
  -DBUILD_SHARED_LIBS=OFF \
  -Ddeprecated-functions=OFF \
  -Di2p=OFF \
  -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF
cmake --build "$work" -j "$JOBS"
cmake --install "$work"
rm -rf "$work"

# The bridge must compile with the same feature macros libtorrent was built with (they change
# struct layouts), so record them for Package.swift.
grep -o 'INTERFACE_COMPILE_DEFINITIONS "[^"]*"' "$out/lib/cmake/LibtorrentRasterbar/LibtorrentRasterbarTargets.cmake" \
  | sed 's/INTERFACE_COMPILE_DEFINITIONS "//; s/"$//' | tr ';' '\n' | grep -v '\$<' > "$out/defines.txt"
log "libtorrent defines: $(tr '\n' ' ' < "$out/defines.txt")"
ls -l "$out/lib/libtorrent-rasterbar.a"
