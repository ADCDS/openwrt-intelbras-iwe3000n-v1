#!/usr/bin/env bash
# build-mdns.sh -- cross-build the minimal mDNS responder for the IWE 3000N.
# Self-contained (tools/mdns-announce.c), static, musl, ~25 KB. Run in the
# toolchain container:
#   docker run --rm -v "$PWD/rtl8196e-gateway:/workspace" -v "$PWD/tools:/tools" \
#       rtl8196e-gateway-builder bash /tools/build-mdns.sh
set -euo pipefail
TC=$(ls -d /home/builder/x-tools/*/bin | head -1); export PATH="$TC:$PATH"
CROSS=mips-lexra-linux-musl; CC="${CROSS}-gcc"
OUT=/workspace/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/prebuilt
mkdir -p "$OUT"
rm -f "$OUT/mdns-announce"        # never ship a stale binary if the build fails
$CC -O2 -static -Wall -D_GNU_SOURCE -o /tmp/mdns-announce /tools/mdns-announce.c
"${CROSS}-strip" /tmp/mdns-announce
cp /tmp/mdns-announce "$OUT/"; ls -l "$OUT/mdns-announce"
