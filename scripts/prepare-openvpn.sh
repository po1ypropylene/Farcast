#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
cache="$root/.dependencies/openvpn"
revision=1b4db00849bfb27e05c226cd13f6985527b6bb79
mkdir -p "$cache" Vendor/Native/lib
fetch() {
  local name="$1" url="$2" digest="$3"
  if [[ ! -f "$cache/$name.tar.gz" ]]; then
    curl --fail --location --retry 3 "$url" -o "$cache/$name.tar.gz"
  fi
  echo "$digest  $cache/$name.tar.gz" | shasum -a 256 -c -
  tar -xzf "$cache/$name.tar.gz" -C "$cache"
}
fetch core "https://codeload.github.com/OpenVPN/openvpn3/tar.gz/$revision" 0b9d511aac7b968854b184cd635ff15cc1e23d4098c278ed545a82fdd2633f9c
fetch asio https://codeload.github.com/chriskohlhoff/asio/tar.gz/refs/tags/asio-1-30-2 755bd7f85a4b269c67ae0ea254907c078d408cce8e1a352ad2ed664d233780e8
fetch fmt https://codeload.github.com/fmtlib/fmt/tar.gz/refs/tags/11.1.4 ac366b7b4c2e9f0dde63a59b3feb5ee59b67974b14ee5dc9ea8ad78aa2c1ee1e
core="$cache/openvpn3-$revision"
flags=(-std=c++20 -O2 -arch arm64 -mmacosx-version-min=27.0 -DFMT_HEADER_ONLY -I"$cache/fmt-11.1.4/include" -DUSE_ASIO -DASIO_STANDALONE -DUSE_OPENSSL -DUSE_TUN_BUILDER -I"$core" -I"$cache/asio-asio-1-30-2/asio/include" -I"$root/Vendor/Native/include")
xcrun clang++ "${flags[@]}" -c "$core/client/ovpncli.cpp" -o "$cache/core.o"
xcrun clang++ "${flags[@]}" -c "$core/openvpn/crypto/data_epoch.cpp" -o "$cache/epoch.o"
xcrun clang++ "${flags[@]}" -c Networking/OpenVPN/bridge.cpp -o "$cache/bridge.o"
xcrun ar rcs Vendor/Native/lib/libfarcast-openvpn.a "$cache/core.o" "$cache/epoch.o" "$cache/bridge.o"
