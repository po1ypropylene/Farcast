#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh openvpn
scripts/prepare-wireguard.sh
cache="$PWD/.dependencies/openvpn"
archive="$cache/server.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 https://swupdate.openvpn.org/community/releases/openvpn-2.6.14.tar.gz -o "$archive"
fi
echo "9eb6a6618352f9e7b771a9d38ae1631b5edfeed6d40233e243e602ddf2195e7a  $archive" | shasum -a 256 -c -
if [[ ! -x "$cache/openvpn-2.6.14/src/openvpn/openvpn" || ! -f "$cache/openvpn-2.6.14/farcast-null-probe-lzo-v3" ]]; then
  [[ -f /opt/homebrew/opt/lzo/include/lzo/lzo1x.h ]] || { echo "The OpenVPN fixture requires Homebrew lzo." >&2; exit 1; }
  tar -xzf "$archive" -C "$cache"
  python3 Tests/Integration/OpenVPN/instrument_null_peer.py "$cache/openvpn-2.6.14/src/openvpn/forward.c"
  root="$PWD"
  (cd "$cache/openvpn-2.6.14"
   ./configure --enable-lzo --disable-lz4 --disable-pkcs11 --disable-plugin-auth-pam --disable-dependency-tracking \
     LZO_CFLAGS="-I/opt/homebrew/opt/lzo/include" LZO_LIBS="-L/opt/homebrew/opt/lzo/lib -llzo2" \
     OPENSSL_CFLAGS="-I$root/Vendor/Native/include" \
     OPENSSL_LIBS="$root/Vendor/Native/lib/libssl.a $root/Vendor/Native/lib/libcrypto.a"
   make clean
   make -j4) > "$fixture_root/build.log" 2>&1
  touch "$cache/openvpn-2.6.14/farcast-null-probe-lzo-v3"
fi
for transport in udp tcp legacy; do
  mkdir "$fixture_root/$transport"
  python3 Tests/Integration/openvpn_fixture.py "$fixture_root/$transport" "$cache/openvpn-2.6.14/src/openvpn/openvpn" "$PWD/Vendor/Native/bin/FarcastWireGuard" "$transport"
done
