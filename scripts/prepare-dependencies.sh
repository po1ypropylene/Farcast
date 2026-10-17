#!/bin/bash
# Build pinned native libraries for this Mac. End users only need the resulting app.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cmake >/dev/null || { echo 'CMake is required to build dependencies (brew install cmake).' >&2; exit 1; }
xcrun --find clang >/dev/null
source_root="$PWD/.dependencies/sources"
install_root="$PWD/Vendor/Native"
mkdir -p "$source_root" "$install_root" .dependencies/build/openssl
fetch() {
  local name="$1" url="$2" tag="$3" revision="$4"
  if [[ ! -d "$source_root/$name/.git" ]]; then
    # Fetch the immutable revision, including unreleased master snapshots.
    git init "$source_root/$name"
    git -C "$source_root/$name" remote add origin "$url"
    git -C "$source_root/$name" fetch --depth 1 origin "$revision"
    git -C "$source_root/$name" checkout --detach FETCH_HEAD
  fi
  [[ "$(git -C "$source_root/$name" rev-parse HEAD)" == "$revision" ]] || { echo "Unexpected revision for $name; remove its build checkout and retry." >&2; exit 1; }
}
fetch OpenSSL https://github.com/openssl/openssl.git openssl-3.6.5 c8bd5a57108599ac650bbae77fcabe3109dab2e8
fetch libssh2 https://github.com/libssh2/libssh2.git master 3209951db4e47ef902db047d12f9f464f835c27e
fetch FreeRDP https://github.com/FreeRDP/FreeRDP.git 3.32.1 bf217a504e54cc719880c228e82353382cd7d4fa
jobs="$(sysctl -n hw.ncpu)"
[[ "$(uname -m)" == arm64 ]] || { echo "Farcast requires Apple silicon." >&2; exit 1; }
openssl_target=darwin64-arm64-cc
(
  cd .dependencies/build/openssl
  ../../sources/OpenSSL/Configure "$openssl_target" shared no-tests no-module --prefix="$install_root" --openssldir="$install_root/ssl" -mmacosx-version-min=27.0
  make -j "$jobs"
  make install_sw
)
cmake -S "$source_root/libssh2" -B .dependencies/build/libssh2 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$install_root" -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
  -DCRYPTO_BACKEND=OpenSSL -DOPENSSL_ROOT_DIR="$install_root"
cmake --build .dependencies/build/libssh2 -j "$jobs"
cmake --install .dependencies/build/libssh2
cmake -S "$source_root/FreeRDP" -B .dependencies/build/freerdp -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$install_root" -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=ON -DWITH_SERVER=OFF \
  -DWITH_SAMPLE=OFF -DWITH_SDL=OFF -DWITH_X11=OFF -DWITH_FUSE=OFF -DWITH_CUPS=OFF \
  -DWITH_PCSC=OFF -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF \
  -DWITH_OPENH264=OFF -DWITH_GSM=OFF -DWITH_FAAC=OFF -DWITH_FAAD2=OFF -DWITH_LAME=OFF \
  -DWITH_OPUS=OFF -DWITH_VORBIS=OFF -DWITH_ALSA=OFF -DWITH_PULSE=OFF \
  -DWITH_GSSAPI=OFF -DWITH_KRB5=OFF -DWITH_WEBVIEW=OFF -DWITH_MANPAGES=OFF \
  -DCHANNEL_URBDRC=OFF -DWITH_MACAUDIO=ON -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON \
  -DOPENSSL_ROOT_DIR="$install_root" -DOPENSSL_INCLUDE_DIR="$install_root/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$install_root/lib/libcrypto.dylib" -DOPENSSL_SSL_LIBRARY="$install_root/lib/libssl.dylib"
cmake --build .dependencies/build/freerdp -j "$jobs"
cmake --install .dependencies/build/freerdp
printf 'Native dependencies are ready. Open Farcast.xcodeproj and build.\n'
printf 'arm64-macos27-audio1\n' > "$install_root/.platform"

scripts/prepare-wireguard.sh
shasum -a 256 scripts/prepare-dependencies.sh > "$install_root/.build-inputs"
