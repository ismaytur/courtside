# Pinned upstream sources for the native engine. Bump a version = change the URL and the sha256
# together (`shasum -a 256 <file>`). Sources:
#   libtorrent: GitHub release asset (sha256 from the release's asset digest)
#   boost:      archives.boost.io (sha256 from the .json next to the tarball); headers only
#   ffmpeg:     ffmpeg.org/releases (ffmpeg publishes GPG signatures only; sha256 recorded on
#               first download and checked ever after)

LIBTORRENT_VERSION=2.0.15
LIBTORRENT_URL=https://github.com/arvidn/libtorrent/releases/download/v2.0.15/libtorrent-rasterbar-2.0.15.tar.gz
LIBTORRENT_SHA256=5e2e79129823b7ea48721164c32b5aaf83d3fd733b5502100f6705b29f27bb02

BOOST_VERSION=1.90.0
BOOST_URL=https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.bz2
BOOST_SHA256=49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305

FFMPEG_VERSION=8.1.3
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.gz
FFMPEG_SHA256=bd458826a039b48a9606e794554c75eb4c4984b84173f7afa3128eae89336f2b
