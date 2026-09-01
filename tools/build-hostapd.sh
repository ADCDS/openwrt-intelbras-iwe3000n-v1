#!/usr/bin/env bash
#
# build-hostapd.sh — cross-build hostapd for the IWE 3000N (M5).
#
# Upstream jnilo1 ships no hostapd, no iw and no wpa_supplicant: their gateway
# is a Zigbee coordinator and has never needed an AP. mac80211 drivers do not
# implement AP mode in the kernel, so hostapd is not optional for M5 — it is
# the thing that runs the AP.
#
# hostapd talks to mac80211 over nl80211, which needs libnl. OpenWrt's
# libnl-tiny is the small option (~25 KB vs ~400 KB for full libnl) and is what
# every 4 MB router build uses, so that is what this builds against.
#
# Runs inside the project's toolchain container; invoke via:
#   docker run --rm -v "$PWD/rtl8196e-gateway:/workspace" -v "$PWD/tools:/tools" \
#       rtl8196e-gateway-builder bash /tools/build-hostapd.sh
set -euo pipefail

TC=$(ls -d /home/builder/x-tools/*/bin | head -1)
export PATH="$TC:$PATH"
CROSS=mips-lexra-linux-musl
export CC="${CROSS}-gcc" AR="${CROSS}-ar" RANLIB="${CROSS}-ranlib" LD="${CROSS}-ld"

WORK=/tmp/hostapd-build
OUT=/workspace/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/prebuilt
mkdir -p "$WORK" "$OUT"
cd "$WORK"

HOSTAPD_VER=2.11
LIBNL_TINY_REV=master

echo "==> libnl-tiny"
[ -d libnl-tiny ] || git clone --depth 1 -b "$LIBNL_TINY_REV" \
    https://github.com/openwrt/libnl-tiny.git
cd libnl-tiny
# libnl-tiny uses cmake upstream now; fall back to a direct compile of the
# handful of sources if cmake is unavailable in the container.
if command -v cmake >/dev/null; then
    cmake -DCMAKE_C_COMPILER="$CC" -DCMAKE_SYSTEM_NAME=Linux . >/dev/null
    make -j"$(nproc)" >/dev/null
else
    $CC -O2 -I./include -fPIC -c src/*.c
    $AR rcs libnl-tiny.a *.o
fi
NLDIR="$PWD"
cd "$WORK"

echo "==> hostapd $HOSTAPD_VER"
[ -f "hostapd-${HOSTAPD_VER}.tar.gz" ] || \
    wget -q "https://w1.fi/releases/hostapd-${HOSTAPD_VER}.tar.gz"
[ -d "hostapd-${HOSTAPD_VER}" ] || tar xf "hostapd-${HOSTAPD_VER}.tar.gz"
cd "hostapd-${HOSTAPD_VER}/hostapd"

# Minimal AP: nl80211, WPA2-PSK, no EAP server, no RADIUS, no ACS, no 802.11ac.
# Every option left out is bytes that do not have to fit in a 1600 KiB rootfs.
cat > .config <<'EOC'
CONFIG_DRIVER_NL80211=y
# CONFIG_LIBNL_TINY, not LIBNL32: the latter makes hostapd's Makefile ask
# pkg-config for libnl-3.0 and link -lnl-3 -lnl-genl-3, neither of which
# exists in a cross sysroot. LIBNL_TINY links -lnl-tiny directly, which is
# what OpenWrt does on every router build.
CONFIG_LIBNL_TINY=y
CONFIG_IEEE80211N=y
CONFIG_WPA=y
CONFIG_NO_RADIUS=y
CONFIG_NO_ACCOUNTING=y
CONFIG_NO_VLAN=y
CONFIG_NO_RANDOM_POOL=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_ELOOP=eloop
EOC

# CFLAGS/LIBS go through the ENVIRONMENT, not the make command line. hostapd's
# Makefile does "CFLAGS += -I../src -I../src/utils", and a command-line
# assignment overrides that append entirely -- every file then fails with
# "fatal error: utils/includes.h: No such file or directory".
# _GNU_SOURCE: libnl-tiny's msg.h uses struct ucred, which musl only
# declares under _GNU_SOURCE. Without it every nl80211 file fails with
# "field 'nm_creds' has incomplete type".
export CFLAGS="-O2 -D_GNU_SOURCE -I${NLDIR}/include -DCONFIG_LIBNL20"
export LIBS="-L${NLDIR} -lnl-tiny"
make CC="$CC" -j"$(nproc)" hostapd hostapd_cli

"${CROSS}-strip" hostapd hostapd_cli
cp hostapd hostapd_cli "$OUT/"
ls -l "$OUT"/hostapd*
echo
echo "Copy these into files/rootfs/usr/sbin/ and re-run ./build.sh rootfs."
