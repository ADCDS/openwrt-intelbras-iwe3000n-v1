#!/usr/bin/env bash
#
# build.sh — overlay this port onto jnilo1/rtl8196e-gateway and build a kernel
# for the Intelbras IWE 3000N.
#
# This repo is a recipe, not a fork. Upstream is cloned to ./rtl8196e-gateway
# (gitignored) and left alone except for the four additions their own
# files-6.18/arch/mips/boot/dts/realtek/Makefile documents for adding a board,
# plus the PCIe host driver this board needs for its radio.
#
#   ./build.sh deps     build the toolchain docker image (~45 min, ~8 GB)
#   ./build.sh overlay  apply this port's files to the upstream tree
#   ./build.sh kernel   overlay, then build the kernel in docker
#   ./build.sh shell    a shell in the builder container
#
# Nothing here writes to the device. Flashing is a separate, deliberate step —
# and see ../iwe3000n-firmware/RESTORE-TO-STOCK.md before any of it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/rtl8196e-gateway"
KDIR="$UP/3-Main-SoC-Realtek-RTL8196E/32-Kernel"
IMG=rtl8196e-gateway-builder
BOARD_SYM=DTB_RTL8196E_IWE3000N
DTS=rtl8196e-intelbras-iwe3000n

die() { echo "error: $*" >&2; exit 1; }

need_upstream() {
    [ -d "$UP" ] || die "upstream missing. git clone https://github.com/jnilo1/rtl8196e-gateway.git '$UP'"
}

cmd_deps() {
    need_upstream
    # Docker, not the native install_deps.sh: that script does
    # `dpkg --add-architecture i386` and installs an Ubuntu 22.04 package set,
    # which is not something to run against a Debian host.
    docker build -t "$IMG" "$UP/1-Build-Environment"
}

cmd_overlay() {
    need_upstream
    local f="$KDIR/files-6.18"

    echo "==> copying port files"
    install -Dm644 "$HERE/files/arch/mips/boot/dts/realtek/$DTS.dts" \
                   "$f/arch/mips/boot/dts/realtek/$DTS.dts"
    install -Dm644 "$HERE/files/drivers/pci/controller/pci-rtl819x.c" \
                   "$f/drivers/pci/controller/pci-rtl819x.c"

    # Upstream's dts Makefile lists the four steps for adding a board; 1 is the
    # copy above, 2-4 are below. Each is idempotent so re-running is safe.

    echo "==> [2/4] Kconfig devicetree choice"
    local kc="$f/arch/mips/realtek/Kconfig"
    if ! grep -q "$BOARD_SYM" "$kc"; then
        python3 - "$kc" "$BOARD_SYM" <<'PY'
import sys, re
path, sym = sys.argv[1], sys.argv[2]
s = open(path).read()
entry = """
	config %s
		bool "Intelbras IWE 3000N (rtl8196e-intelbras-iwe3000n.dtb)"
		depends on SOC_RTL8196E
		select BUILTIN_DTB
		help
		  Intelbras IWE 3000N v1, a 2.4 GHz repeater on a 4 MB
		  W25Q32. Keeps the stock RealTek bootloader: mtd0 also
		  holds this unit's MAC and RF calibration.

""" % sym
# append inside the existing choice block, after the last config entry in it
m = list(re.finditer(r'\n\tconfig DTB_RTL8196E_\w+\n(?:\t\t.*\n|\n)*', s))
if not m:
    sys.exit("could not find the DTB choice block")
last = m[-1]
s = s[:last.end()] + entry.lstrip('\n') + s[last.end():]
open(path, 'w').write(s)
PY
        echo "    added $BOARD_SYM"
    else
        echo "    already present"
    fi

    echo "==> [3/4] dts Makefile"
    local mk="$f/arch/mips/boot/dts/realtek/Makefile"
    grep -q "$DTS.dtb" "$mk" || \
        sed -i "/^obj-y/i dtb-\$(CONFIG_$BOARD_SYM)\t+= $DTS.dtb\n" "$mk"

    echo "==> [3b] PCI controller wiring (as a patch, NOT a file overlay)"
    # These two files exist in the vanilla kernel and list every PCI controller
    # driver there is. Dropping our own copies into files-6.18/ would REPLACE
    # them -- which is exactly what an earlier version of this script did, and
    # it silently deleted the entire upstream Kconfig from the build tree. Add
    # to them with a patch instead; upstream applies patches-6.18/*.patch after
    # extracting the tarball, and rejects any fuzz or offset.
    install -Dm644 "$HERE/patches/drivers-pci-controller-rtl819x.patch" \
                   "$KDIR/patches-6.18/drivers-pci-controller-rtl819x.patch"

    echo "==> [3c] SOC_RTL8196E must select HAVE_PCI + PCI_DRIVERS_GENERIC"
    # Upstream selects HW_HAS_PCI, which no longer gates anything: in 6.18
    # drivers/pci/Kconfig has "menuconfig PCI ... depends on HAVE_PCI". Without
    # this, CONFIG_PCI=y in the fragment is unsatisfiable and kconfig drops it
    # without a word -- which is how the first build came out with no PCI at all.
    #
    # PCI_DRIVERS_GENERIC is the second half, and the build teaches it the hard
    # way: without it MIPS defaults to PCI_DRIVERS_LEGACY (def_bool
    # !PCI_DRIVERS_GENERIC), which pulls in arch/mips/pci/pci-legacy.c and that
    # calls pcibios_plat_dev_init() -- a hook every legacy MIPS platform has to
    # define and the realtek platform does not. The link fails with
    # "undefined reference to `pcibios_plat_dev_init'".
    #
    # Defining a stub would work, but generic is the right answer: our host
    # driver is a modern DT one, and PCI_DRIVERS_GENERIC is what
    # devm_pci_alloc_host_bridge()/pci_host_probe() expect.
    #
    local rk="$f/arch/mips/realtek/Kconfig"
    if ! grep -q "select HAVE_PCI" "$rk"; then
        sed -i 's/^\(\t*\)select HW_HAS_PCI$/&\n\1select HAVE_PCI\n\1select PCI_DRIVERS_GENERIC/' "$rk"
        grep -q "select PCI_DRIVERS_GENERIC" "$rk" && echo "    added" || die "could not add the PCI selects"
    else
        echo "    already present"
    fi

    echo "==> [4/4] BOARD map in upstream's build_kernel.sh"
    local bk="$KDIR/build_kernel.sh"
    if ! grep -q "iwe3000n)" "$bk"; then
        sed -i "s|^\( *\)sengled-e39-g8c) BOARD_DTB_SYM=.*|&\n\1iwe3000n) BOARD_DTB_SYM=\"CONFIG_$BOARD_SYM\" ;;|" "$bk"
        echo "    added iwe3000n"
    else
        echo "    already present"
    fi

    echo "==> [3d] cvimg burn address"
    # Upstream builds the kernel image with CVIMG_BURN_ADDR=0x00020000, which is
    # their 128 KiB boot partition. Ours is 64 KiB and the stock RealTek loader
    # is told linuxpart=0x10000, so the kernel has to burn at 0x00010000. The
    # burn address is baked into the cvimg header, and the loader's TFTP writes
    # where the header says -- get this wrong and the image lands 64 KiB into
    # the wrong place with no error.
    local bkc="$KDIR/build_kernel.sh"
    if grep -q 'CVIMG_BURN_ADDR="0x00020000"' "$bkc"; then
        sed -i 's|CVIMG_BURN_ADDR="0x00020000"|CVIMG_BURN_ADDR="${CVIMG_BURN_ADDR:-0x00010000}"|' "$bkc"
        echo "    kernel burn address -> 0x00010000"
    else
        echo "    already patched"
    fi

    echo "==> config fragment"
    local cfg="$KDIR/config-6.18-realtek.txt"
    python3 - "$cfg" "$BOARD_SYM" <<'PY'
import sys
path, sym = sys.argv[1], sys.argv[2]
s = open(path).read().splitlines()
want = {
    "CONFIG_DTB_RTL8196E_GEN": "# CONFIG_DTB_RTL8196E_GEN is not set",
    "CONFIG_%s" % sym: "CONFIG_%s=y" % sym,
    "CONFIG_PCI": "CONFIG_PCI=y",
    "CONFIG_PCIE_RTL819X": "CONFIG_PCIE_RTL819X=y",
}
out, seen = [], set()
for line in s:
    key = line.split("=")[0].lstrip("# ").split(" ")[0]
    if key in want:
        out.append(want[key]); seen.add(key)
    else:
        out.append(line)
for k, v in want.items():
    if k not in seen:
        out.append(v)
open(path, "w").write("\n".join(out) + "\n")
PY
    echo "    board dtb, CONFIG_PCI and CONFIG_PCIE_RTL819X set"
    echo
    echo "overlay done. Note the wireless stack is NOT enabled yet — that waits"
    echo "on the stage 1 result from pci-rtl819x.c. See docs/WIFI-PLAN.md."
}

cmd_kernel() {
    cmd_overlay
    docker image inspect "$IMG" >/dev/null 2>&1 || die "no $IMG image; run ./build.sh deps"
    docker run --rm -v "$UP:/workspace" -w /workspace/3-Main-SoC-Realtek-RTL8196E/32-Kernel \
        "$IMG" bash -c "BOARD=iwe3000n ./build_kernel.sh"
}

cmd_shell() {
    docker run --rm -it -v "$UP:/workspace" "$IMG" bash
}

case "${1:-}" in
    deps)    cmd_deps ;;
    overlay) cmd_overlay ;;
    kernel)  cmd_kernel ;;
    shell)   cmd_shell ;;
    *)       sed -n '3,16p' "$0"; exit 1 ;;
esac
