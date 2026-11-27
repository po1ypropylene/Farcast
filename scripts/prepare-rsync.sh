#!/bin/bash
# Build the independently executable rsync from its matching release sources.
set -euo pipefail
recipe="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cache="${1:-.dependencies/rsync}"
mkdir -p "$cache"
cd "$cache"
version=3.5.2
archive="rsync-$version.tar.gz"
digest=a10d591825251e070f74c98df3daad195def4ed81b4a2de16169026aea33f6c8
if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 "https://github.com/RsyncProject/rsync/releases/download/v$version/$archive" -o "$archive.download"
    mv "$archive.download" "$archive"
fi
echo "$digest  $archive" | shasum -a 256 -c -
recipe_hash="$(shasum -a 256 "$recipe" | cut -d' ' -f1)"
if [[ -x rsync && -f recipe.sha256 && "$(cat recipe.sha256)" == "$recipe_hash" ]]; then exit 0; fi
work="$(mktemp -d "$PWD/build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
tar -xzf "$archive" -C "$work"
(
    cd "$work/rsync-$version"
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin MACOSX_DEPLOYMENT_TARGET=27.0
    export CC=clang CFLAGS="-O2 -arch arm64"
    ./configure --disable-md2man --disable-openssl --disable-xxhash --disable-zstd --disable-lz4 --disable-idn --with-included-popt --with-included-zlib
    make -j8 rsync
)
install -m 755 "$work/rsync-$version/rsync" rsync
echo "$recipe_hash" > recipe.sha256
