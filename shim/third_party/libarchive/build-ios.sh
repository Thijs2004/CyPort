#!/bin/bash
# Builds libarchive (zip, 7z, rar/rar5 readers) and the liblzma it needs for 7z as iOS arm64 static libraries, for the
# in-app mod manager (shim/ModManagerCore.m). Output, committed so build.sh needs neither network nor cmake:
#   ios/libarchive.a  ios/liblzma.a  include/archive.h  include/archive_entry.h
# Sources: the official release tarballs, checked against the SHA-256 below. Work folder: $WORK (default build/libarchive-work).
#   LIBARCHIVE_TARBALL=/path/libarchive-3.8.1.tar.xz  XZ_TARBALL=/path/xz-5.8.1.tar.gz   use local copies (no download)
# Needs: Xcode (iphoneos SDK), cmake, ninja.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LA_VER=3.8.1; LA_SHA=19f917d42d530f98815ac824d90c7eaf648e9d9a50e4f309c812457ffa5496b5
XZ_VER=5.8.1; XZ_SHA=507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543
WORK="${WORK:-$HERE/../../../build/libarchive-work}"; mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

fetch() {   # fetch <local override> <url> <sha256> <dest>
  if [ -n "$1" ]; then cp "$1" "$4"; elif [ ! -f "$4" ]; then curl -fsSL -o "$4" "$2"; fi
  [ "$(shasum -a 256 "$4" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch: $4"; exit 1; }
}
fetch "${LIBARCHIVE_TARBALL:-}" "https://github.com/libarchive/libarchive/releases/download/v$LA_VER/libarchive-$LA_VER.tar.xz" "$LA_SHA" "$WORK/libarchive-$LA_VER.tar.xz"
fetch "${XZ_TARBALL:-}" "https://github.com/tukaani-project/xz/releases/download/v$XZ_VER/xz-$XZ_VER.tar.gz" "$XZ_SHA" "$WORK/xz-$XZ_VER.tar.gz"
rm -rf "$WORK/src" "$WORK/b-xz" "$WORK/b-la" "$WORK/prefix"; mkdir -p "$WORK/src"
tar -xf "$WORK/xz-$XZ_VER.tar.gz" -C "$WORK/src"
tar -xf "$WORK/libarchive-$LA_VER.tar.xz" -C "$WORK/src"

IOS=(-G Ninja -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64
     -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$WORK/prefix"
     -DCMAKE_C_FLAGS="-fvisibility=hidden")

echo "==> liblzma $XZ_VER"
cmake -S "$WORK/src/xz-$XZ_VER" -B "$WORK/b-xz" "${IOS[@]}" -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF \
  -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF -DXZ_NLS=OFF -DXZ_THREADS=no >/dev/null
ninja -C "$WORK/b-xz" liblzma >/dev/null
cmake --install "$WORK/b-xz" >/dev/null

echo "==> libarchive $LA_VER"
cmake -S "$WORK/src/libarchive-$LA_VER" -B "$WORK/b-la" "${IOS[@]}" \
  -DENABLE_TEST=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_INSTALL=ON \
  -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_ZSTD=OFF \
  -DENABLE_LZO=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_WIN32_XMLLITE=OFF -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF \
  -DENABLE_LIBGCC=OFF -DENABLE_CNG=OFF -DENABLE_ACL=OFF -DENABLE_XATTR=OFF -DENABLE_WERROR=OFF \
  -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_ICONV=ON -DENABLE_LZMA=ON \
  -DLIBLZMA_INCLUDE_DIR="$WORK/prefix/include" -DLIBLZMA_LIBRARY="$WORK/prefix/lib/liblzma.a" \
  -DCMAKE_FIND_ROOT_PATH="$WORK/prefix" >/dev/null
ninja -C "$WORK/b-la" archive_static >/dev/null

rm -rf "$HERE/ios" "$HERE/include"; mkdir -p "$HERE/ios" "$HERE/include"
cp "$WORK/prefix/lib/liblzma.a" "$HERE/ios/"
cp "$WORK/b-la/libarchive/libarchive.a" "$HERE/ios/"
cp "$WORK/src/libarchive-$LA_VER/libarchive/archive.h" "$WORK/src/libarchive-$LA_VER/libarchive/archive_entry.h" "$HERE/include/"
cp "$WORK/src/libarchive-$LA_VER/COPYING" "$HERE/COPYING.libarchive"
cp "$WORK/src/xz-$XZ_VER/COPYING.0BSD" "$HERE/COPYING.xz"
grep -E "HAVE_(ZLIB_H|BZLIB_H|LZMA_H|ICONV_H|LIBLZMA|LIBZ|LIBBZ2) " "$WORK/b-la/config.h" || true
ls -l "$HERE/ios"
