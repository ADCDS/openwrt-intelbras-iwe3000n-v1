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
#   ./build.sh deps     clone upstream (pinned), build the toolchain docker image (~45 min, ~8 GB)
#   ./build.sh overlay  apply this port's files to the upstream tree
#   ./build.sh kernel   overlay, then build the kernel in docker
#   ./build.sh rootfs   fix the /etc symlinks, add the AP, then build the squashfs
#   ./build.sh release  kernel + rootfs, then copy both to out/ with checksums
#   ./build.sh shell    a shell in the builder container
#
# Nothing here writes to the device. Flashing is a separate, deliberate step —
# docs/INSTALL.md — and read docs/RECOVERY.md before any of it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/rtl8196e-gateway"
# Upstream is pinned. Their build applies every patch in patches-6.18/ and
# rejects fuzz, so a newer upstream can break this recipe silently; bump the
# pin deliberately, rebuild, re-test on hardware, then commit.
UPSTREAM_URL=https://github.com/jnilo1/rtl8196e-gateway.git
UPSTREAM_REV="${UPSTREAM_REV:-v4.2.0}"      # d2eb4b8912b2f60a26b48ad62692fb9cec427623
KDIR="$UP/3-Main-SoC-Realtek-RTL8196E/32-Kernel"
IMG=rtl8196e-gateway-builder
BOARD_SYM=DTB_RTL8196E_IWE3000N
DTS=rtl8196e-intelbras-iwe3000n

die() { echo "error: $*" >&2; exit 1; }

need_upstream() {
    if [ ! -d "$UP/.git" ]; then
        echo "==> cloning upstream $UPSTREAM_URL at $UPSTREAM_REV"
        git clone --no-checkout "$UPSTREAM_URL" "$UP"
        git -C "$UP" checkout -q "$UPSTREAM_REV"
    fi
    local want have
    want=$(git -C "$UP" rev-parse "$UPSTREAM_REV^{commit}" 2>/dev/null) \
        || die "upstream has no $UPSTREAM_REV -- git -C '$UP' fetch --tags"
    have=$(git -C "$UP" rev-parse HEAD)
    [ "$want" = "$have" ] || die "upstream is at ${have:0:12}, this recipe is pinned to $UPSTREAM_REV (${want:0:12}).
       git -C '$UP' checkout $UPSTREAM_REV   -- or set UPSTREAM_REV= to move the pin on purpose"
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
    # issue #99 debug: counters shared by rtlwifi's ISR and the timer-ISR probe
    install -Dm644 "$HERE/files/include/linux/rtl_pci_dbg.h" \
                   "$f/include/linux/rtl_pci_dbg.h"

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

    # This port owns every rtlwifi-*/mac80211-*/DEBUG-* patch in upstream's
    # patches-6.18/. Remove them all first, then install the current set:
    # upstream applies the whole directory in glob order, so a patch dropped
    # from this script but left behind on disk keeps getting built in -- which
    # happened, silently, for three experimental patches over several builds.
    for stale in "$KDIR"/patches-6.18/rtlwifi-*.patch "$KDIR"/patches-6.18/mac80211-*.patch "$KDIR"/patches-6.18/DEBUG-*.patch; do
        [ -e "$stale" ] && rm -f "$stale"
    done

    echo "==> [3b'] rtlwifi efuse big-endian fix"
    # The RTL8196E is big-endian; mainline rtlwifi reads the little-endian efuse
    # with *(u16 *) casts, so the EEPROM ID magic 0x8129 is misread as 0x2981,
    # the chip's real MAC/TX-power/xtal calibration is discarded, and the radio
    # comes up on defaults -- AP-ENABLED but silent. See the patch header.
    install -Dm644 "$HERE/patches/rtlwifi-efuse-big-endian-eeprom-id.patch" \
                   "$KDIR/patches-6.18/rtlwifi-efuse-big-endian-eeprom-id.patch"

    echo "==> rtlwifi RX refill-before-release race fix"
    install -Dm644 "$HERE/patches/rtlwifi-rx-refill-before-hw-release.patch" \
                   "$KDIR/patches-6.18/rtlwifi-rx-refill-before-hw-release.patch"

    echo "==> rtlwifi: RX ring 512 -> 64 buffers (32 MB host) -- issue #99"
    install -Dm644 "$HERE/patches/rtlwifi-rx-ring-64.patch" \
                   "$KDIR/patches-6.18/rtlwifi-rx-ring-64.patch"

    echo "==> [DEBUG] rtlwifi ISR per-branch counters -- issue #99 INTA storm"
    # rtlwifi-zdebug-* so it sorts after the refill patch above (same file).
    install -Dm644 "$HERE/patches/rtlwifi-zdebug-isr-counters.patch" \
                   "$KDIR/patches-6.18/rtlwifi-zdebug-isr-counters.patch"

    echo "==> rtlwifi: quiesce INTA when the ISR runs driver-disabled -- issue #99 FIX"
    # rtlwifi-zzfix-* so it sorts after the zdebug counters it shares.
    install -Dm644 "$HERE/patches/rtlwifi-zzfix-isr-quiesce-when-disabled.patch" \
                   "$KDIR/patches-6.18/rtlwifi-zzfix-isr-quiesce-when-disabled.patch"

    echo "==> rtlwifi: mask the IRQ line while the ISR finds the driver disabled -- issue #99 FIX 4"
    install -Dm644 "$HERE/patches/rtlwifi-zzfix4-mask-irq-while-driver-disabled.patch" \
                   "$KDIR/patches-6.18/rtlwifi-zzfix4-mask-irq-while-driver-disabled.patch"

    echo "==> rtlwifi: station mode -- IPS off, no MGQ pointer reset at association (see the patch header)"
    install -Dm644 "$HERE/patches/rtlwifi-zzzsta-station-mode.patch" \
                   "$KDIR/patches-6.18/rtlwifi-zzzsta-station-mode.patch"

    echo "==> mac80211 RX tasklet budget (softirq livelock fix)"
    install -Dm644 "$HERE/patches/mac80211-bound-rx-tasklet.patch" \
                   "$KDIR/patches-6.18/mac80211-bound-rx-tasklet.patch"

    echo "==> [DEBUG] mac80211 tasklet/frame-flow counters -- issue #99"
    # Named mac80211-zdebug-* (not DEBUG-*) on purpose: patches-6.18/*.patch
    # applies in alphabetical glob order, and it must land AFTER
    # mac80211-bound-rx-tasklet.patch, whose changes it depends on -- an
    # uppercase "DEBUG-" prefix sorts before every lowercase patch name here
    # and applied too early, failing with hunk mismatches.
    install -Dm644 "$HERE/patches/mac80211-zdebug-tasklet-counters.patch" \
                   "$KDIR/patches-6.18/mac80211-zdebug-tasklet-counters.patch"
    install -Dm644 "$HERE/patches/mac80211-zdebug-rx-irqsafe-counter.patch" \
                   "$KDIR/patches-6.18/mac80211-zdebug-rx-irqsafe-counter.patch"

    echo "==> [DEBUG] timer_list callback trace -- issue #99"
    # Re-enabled: its own volume (2 lines per callback INVOCATION, and only
    # a handful of distinct timer_list callbacks fire at all on this board)
    # turned out to be low -- the actual flood was the OTHER probe's 48-line
    # stack scan on top of this, now removed. This patch's data was useful:
    # it proved callbacks run and return cleanly, and confirmed zero fire at
    # all once the freeze begins.
    install -Dm644 "$HERE/patches/DEBUG-timer-callback-trace.patch" \
                   "$KDIR/patches-6.18/DEBUG-timer-callback-trace.patch"

    echo "==> [3b'\''] rtl819x intc must route the PCIe interrupt"
    # jnilo1's intc ships IRR2=0 (no PCIe); without routing GIMR bit 21 to a CPU
    # IP line the RTL8192EE's INTA never reaches the CPU and the radio is silent.
    #
    # irq-rtl819x.c is a jnilo1 *overlay* file (files-6.18/), copied into the
    # tree AFTER patches-6.18/ is applied -- so a patches-6.18/ patch can't touch
    # it (the file is not there yet at patch time). Patch the overlay copy in
    # place instead, idempotently, and abort loudly if it no longer applies
    # clean (jnilo1 changed the file -> refresh patches/irqchip-rtl819x-route-pcie.patch).
    local intc="$f/drivers/irqchip/irq-rtl819x.c"
    if grep -q REALTEK_HW_PCIE_BIT "$intc"; then
        echo "    already applied"
    else
        patch -p1 -f --no-backup-if-mismatch -d "$f" \
              < "$HERE/patches/irqchip-rtl819x-route-pcie.patch" \
            || { echo "ERROR: irqchip-rtl819x-route-pcie.patch failed on files-6.18" >&2; exit 1; }
    fi

    echo "==> [DEBUG] /proc/rtl819x_intc_stats -- issue #99 storm diagnosis"
    # Temporary: not meant to stay in the tree. Same in-place/idempotent
    # treatment as the PCIe routing patch above, and for the same reason
    # (overlay file, not present yet at patches-6.18 time).
    if grep -q rtl819x_intc_stats_proc_init "$intc"; then
        echo "    already applied"
    else
        patch -p1 -f --no-backup-if-mismatch -d "$f" \
              < "$HERE/patches/DEBUG-intc-stats-proc.patch" \
            || { echo "ERROR: DEBUG-intc-stats-proc.patch failed on files-6.18" >&2; exit 1; }
    fi

    echo "==> [DEBUG] timer-ISR softirq-vector snapshot -- issue #99 storm diagnosis"
    # Same in-place/idempotent overlay-file treatment, same reason.
    local timerc="$f/drivers/clocksource/timer-rtl819x.c"
    if grep -q rtl819x_debug_softirq_snapshot "$timerc"; then
        echo "    already applied"
    else
        patch -p1 -f --no-backup-if-mismatch -d "$f" \
              < "$HERE/patches/DEBUG-timer-softirq-snapshot.patch" \
            || { echo "ERROR: DEBUG-timer-softirq-snapshot.patch failed on files-6.18" >&2; exit 1; }
    fi

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

    echo "==> [3e] firmware for CONFIG_EXTRA_FIRMWARE"
    # EXTRA_FIRMWARE_DIR is relative to the kernel source tree. Staging the
    # blobs directly into that tree does NOT work: cmd_kernel wipes the tree
    # (IMEM_POLICY_DISABLE needs a clean one) after this step runs, so they
    # vanish before the build and the image comes out the same size with no
    # firmware in it. Put them in files-6.18/ instead -- upstream copies that
    # over the tree *after* extraction, which is exactly the right moment.
    local b
    for b in rtlwifi/rtl8192eefw.bin regulatory.db regulatory.db.p7s; do
        [ -f "$HERE/files/rootfs/lib/firmware/$b" ] && \
            install -Dm644 "$HERE/files/rootfs/lib/firmware/$b" "$f/firmware/$b"
    done
    echo "    staged into files-6.18/firmware/"

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
    # Wireless. Built in, not modules: upstream has CONFIG_MODULES unset and
    # their build has no modules_install, so =m would silently produce nothing.
    # The firmware blob is loaded from /lib/firmware in the rootfs.
    # The WPS button and the two panel LEDs are driven from userspace over the
    # classic /sys/class/gpio interface (led, S60button). In 6.18 that lives
    # behind GPIO_SYSFS_LEGACY; without it /sys/class/gpio is empty and export
    # fails. GPIO 4 = WPS button, 13 = red LED, 14 = blue LED (from stock).
    "CONFIG_GPIO_SYSFS": "CONFIG_GPIO_SYSFS=y",
    "CONFIG_GPIO_SYSFS_LEGACY": "CONFIG_GPIO_SYSFS_LEGACY=y",
    "CONFIG_WIRELESS": "CONFIG_WIRELESS=y",
    "CONFIG_CFG80211": "CONFIG_CFG80211=y",
    "CONFIG_MAC80211": "CONFIG_MAC80211=y",
    "CONFIG_WLAN": "CONFIG_WLAN=y",
    "CONFIG_WLAN_VENDOR_REALTEK": "CONFIG_WLAN_VENDOR_REALTEK=y",
    "CONFIG_RTL_CARDS": "CONFIG_RTL_CARDS=y",
    "CONFIG_RTL8192EE": "CONFIG_RTL8192EE=y",
    "CONFIG_FW_LOADER": "CONFIG_FW_LOADER=y",
    # The radio driver is built in, so it probes at ~3 s during kernel init --
    # before the rootfs is mounted. A blob in /lib/firmware can never be there
    # in time and the load fails with -2. Link them into the image instead.
    # Costs ~37 KB of the kernel partition, which is the only place they work.
    "CONFIG_EXTRA_FIRMWARE": 'CONFIG_EXTRA_FIRMWARE="rtlwifi/rtl8192eefw.bin regulatory.db regulatory.db.p7s"',
    # Absolute, inside the container. A relative path resolves against the
    # kernel tree, and upstream's overlay rsync copies only arch/, drivers/,
    # include/ and Documentation/ -- never firmware/ -- so blobs put there
    # never arrive and the build dies with "No rule to make target
    # 'firmware/rtlwifi/rtl8192eefw.bin'".
    "CONFIG_EXTRA_FIRMWARE_DIR": 'CONFIG_EXTRA_FIRMWARE_DIR="/workspace/3-Main-SoC-Realtek-RTL8196E/32-Kernel/files-6.18/firmware"',
    # zboot places the compressed image immediately after the decompressed one
    # when this is 0x0 (auto). With the wireless stack the kernel decompresses
    # to ~7 MB and the auto address landed at 0x806e0000 -- no margin -- and the
    # board jumped to it and went silent, decompressor overwriting its own
    # source. Pin it well clear: 16 MB into a 32 MB part, leaving ~14 MB above.
    # Left on auto (0x0). Pinning it to 0x81000000 to get clear of the
    # decompressed kernel made the loader jump there and hang: every boot that
    # has ever worked on this board had an entry just above the loader's own
    # 0x80500000 staging area (0x805a0000), so it appears to stage the image at
    # the header's address and cannot place it 16 MB up. Auto-placement has
    # room again now the kernel is trimmed.
    "CONFIG_ZBOOT_LOAD_ADDRESS": "CONFIG_ZBOOT_LOAD_ADDRESS=0x0",
    # Size. The loader refuses a 1.9 MB kernel: it prints checksum/burn address
    # and then scans "no sys signature at 000NN000!" from kernel_start+0x1000
    # and gives up without writing. A 1.5 MB kernel writes fine. Whatever the
    # exact limit is, the wireless stack has to be paid for somewhere, and
    # these are the cheapest things on this board.
    #
    # IPv6: nothing in this project uses it; the stock firmware had it but this
    # is a 2.4 GHz AP on a 4 MB part.
    # RTLWIFI_DEBUG: pure format strings and tracing in the radio driver.
    "CONFIG_IPV6": "# CONFIG_IPV6 is not set",
    "CONFIG_RTLWIFI_DEBUG": "# CONFIG_RTLWIFI_DEBUG is not set",
    "CONFIG_CFG80211_DEBUGFS": "# CONFIG_CFG80211_DEBUGFS is not set",
    "CONFIG_MAC80211_DEBUGFS": "# CONFIG_MAC80211_DEBUGFS is not set",
    "CONFIG_MAC80211_MESH": "# CONFIG_MAC80211_MESH is not set",
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
    echo "overlay done. mac80211 + rtl8192ee are built in, with their firmware"
    echo "in CONFIG_EXTRA_FIRMWARE (the rootfs mounts too late to supply it)."
}

cmd_rootfs() {
    need_upstream
    local sk="$UP/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/skeleton"

    echo "==> replacing dangling /etc symlinks with real files"
    # Upstream points these at /userdata, the 12 MB partition their boards have
    # and this one does not. On a 448 KiB overlay they dangle and login is
    # impossible. See files/rootfs/README.md.
    local n
    for n in passwd group; do
        if [ -L "$sk/etc/$n" ] || [ ! -s "$sk/etc/$n" ]; then
            rm -f "$sk/etc/$n"
            install -Dm644 "$HERE/files/rootfs/etc/$n" "$sk/etc/$n"
            echo "    /etc/$n now a real file"
        else
            echo "    /etc/$n already a real file"
        fi
    done

    echo "==> firmware blobs"
    # rtl8192ee asks the firmware loader for this by name at probe. It is not
    # built into the kernel (EXTRA_FIRMWARE would put it in the 1984 KiB kernel
    # partition instead of the roomier rootfs), so it lives here.
    local fw
    for fw in rtlwifi/rtl8192eefw.bin regulatory.db regulatory.db.p7s; do
        if [ -f "$HERE/files/rootfs/lib/firmware/$fw" ]; then
            install -Dm644 "$HERE/files/rootfs/lib/firmware/$fw" "$sk/lib/firmware/$fw"
            echo "    $fw ($(stat -c %s "$HERE/files/rootfs/lib/firmware/$fw") bytes)"
        fi
    done

    echo "==> userspace"
    # hostapd is not optional: mac80211 has no in-kernel AP mode, and upstream
    # ships no hostapd, iw or wpa_supplicant at all. Built by
    # tools/build-hostapd.sh against libnl-tiny.
    local u
    # sbin/, not usr/sbin/: skeleton/usr/sbin is a symlink to
    # /userdata/usr/sbin -- the partition this board does not have -- and
    # install -D refuses to create a directory over a symlink, so the
    # binaries silently never arrived while the .conf did.
    # AP (hostapd) + client (wpa_supplicant), the LED/mode helpers, and the
    # button handlers. wpa_supplicant/wpa_cli come from tools/build-hostapd.sh.
    for u in sbin/hostapd sbin/hostapd_cli sbin/wpa_supplicant sbin/wpa_cli \
             sbin/led sbin/wifi-mode etc/button/short etc/button/long etc/udhcpc.script; do
        [ -f "$HERE/files/rootfs/$u" ] && \
            install -Dm755 "$HERE/files/rootfs/$u" "$sk/$u" && echo "    $u"
    done
    for u in etc/hostapd.conf etc/wpa_supplicant.conf etc/wifi-mode; do
        [ -f "$HERE/files/rootfs/$u" ] && \
            install -Dm644 "$HERE/files/rootfs/$u" "$sk/$u" && echo "    $u"
    done

    echo "==> AP at boot"
    # Upstream's rcS only runs /userdata/etc/init.d/S??*, and /userdata is the
    # partition this board does not have. Teach it to run the rootfs's own
    # /etc/init.d/S??* as well (idempotent: marker comment), and ship the AP
    # start script there.
    install -Dm755 "$HERE/files/rootfs/etc/init.d/S50dropbear" "$sk/etc/init.d/S50dropbear"
    # /etc/dropbear ships as a dangling symlink into /userdata (absent here);
    # replace it with a real directory carrying the shipped host key, so SSH
    # needs no boot-time key generation (the RNG does not seed on an idle boot).
    rm -rf "$sk/etc/dropbear"   # symlink on the first run, a real dir on rebuilds
    install -Dm600 "$HERE/files/rootfs/etc/dropbear/dropbear_ed25519_host_key" \
                   "$sk/etc/dropbear/dropbear_ed25519_host_key"
    install -Dm755 "$HERE/files/rootfs/etc/init.d/S90wifi" "$sk/etc/init.d/S90wifi"
    install -Dm755 "$HERE/files/rootfs/etc/init.d/S60button" "$sk/etc/init.d/S60button"
    install -Dm644 "$HERE/files/rootfs/etc/udhcpd.conf" "$sk/etc/udhcpd.conf"
    local rcs="$sk/etc/init.d/rcS"
    if grep -q "iwe3000n: rootfs init scripts" "$rcs"; then
        echo "    rcS already runs /etc/init.d/S??*"
    else
        python3 - "$rcs" "$HERE/files/rootfs/etc/init.d/rcS-hook.sh" <<'PYH'
import sys
p, h = sys.argv[1], sys.argv[2]
s = open(p).read(); hook = open(h).read()
anchor = 'echo "===== System ready ====="'
assert anchor in s, "rcS anchor not found"
open(p, "w").write(s.replace(anchor, hook + anchor, 1))
PYH
        echo "    rcS now runs /etc/init.d/S??* before 'System ready'"
    fi

    echo "==> busybox: DHCP server applet (udhcpd)"
    # Upstream builds busybox without the DHCP *server*; the AP needs it so
    # clients get an address. Enable it in the base config (idempotent) and
    # rebuild the binary only when the shipped one lacks the applet -- a full
    # busybox rebuild is a few minutes, so skip it once it is in.
    local rfd="$UP/3-Main-SoC-Realtek-RTL8196E/33-Rootfs"
    local bbcfg="$rfd/busybox/busybox.config"
    sed -i 's/^# CONFIG_UDHCPD is not set/CONFIG_UDHCPD=y/' "$bbcfg"
    sed -i 's/^# CONFIG_FEATURE_UDHCPD_WRITE_LEASES_EARLY is not set/CONFIG_FEATURE_UDHCPD_WRITE_LEASES_EARLY=y/' "$bbcfg"
    sed -i 's#^CONFIG_DHCPD_LEASES_FILE=""#CONFIG_DHCPD_LEASES_FILE="/tmp/udhcpd.leases"#' "$bbcfg"
    if strings "$sk/bin/busybox" 2>/dev/null | grep -q '^udhcpd$'; then
        echo "    busybox already has udhcpd"
    else
        echo "    rebuilding busybox with udhcpd"
        docker image inspect "$IMG" >/dev/null 2>&1 || die "no $IMG image; run ./build.sh deps"
        docker run --rm -v "$UP:/workspace" \
            -w /workspace/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/busybox "$IMG" \
            bash -c 'TC=$(ls -d /home/builder/x-tools/*/bin | head -1); export PATH="$TC:$PATH"; ./build_busybox.sh'
    fi

    docker image inspect "$IMG" >/dev/null 2>&1 || die "no $IMG image; run ./build.sh deps"
    docker run --rm -v "$UP:/workspace" \
        -w /workspace/3-Main-SoC-Realtek-RTL8196E/33-Rootfs \
        "$IMG" bash -c './build_rootfs.sh'
}

cmd_kernel() {
    cmd_overlay

    # Upstream only copies config-6.18-realtek.txt when .config is absent
    # ("if [ ! -f .config ]"). A surviving build tree therefore keeps a stale
    # .config and silently ignores every change to the fragment -- which once
    # produced a "successful" build with the entire wireless stack missing and
    # a kernel only 4 KiB larger. Drop it so the fragment always applies;
    # object files are kept, so this is not a full rebuild.
    rm -f "$KDIR/linux-6.18-rtl8196e/.config"
    docker image inspect "$IMG" >/dev/null 2>&1 || die "no $IMG image; run ./build.sh deps"
    #
    # IMEM_POLICY_DISABLE: upstream places hot-path functions in the SoC's
    # on-chip instruction RAM against a fixed 15872-byte window. Adding the
    # wireless stack pushes the linked-order estimate to 15900 and the build
    # stops ("linked-order estimate 15900 exceeds 15872 bytes"). Their
    # documented escape hatch drops the optimisation; it needs a clean tree.
    #
    # This is a performance trade, not a correctness one, and it invalidates
    # the M2 throughput figures -- re-measure after any build that sets it.
    # The alternative is trimming scripts/imem/policies/6.18.45.tsv by ~28
    # bytes of functions, which keeps the optimisation and is the better fix
    # once the radio works.
    local imem="${IMEM_POLICY_DISABLE:-1}"
    [ "$imem" = "1" ] && rm -rf "$KDIR/linux-6.18-rtl8196e"

    docker run --rm -v "$UP:/workspace" -w /workspace/3-Main-SoC-Realtek-RTL8196E/32-Kernel \
        "$IMG" bash -c "IMEM_POLICY_DISABLE=$imem BOARD=iwe3000n ./build_kernel.sh"
}

cmd_shell() {
    docker run --rm -it -v "$UP:/workspace" "$IMG" bash
}

# cvimg header: 4-byte signature, load address, burn address, length, all
# big-endian. The loader writes wherever the header says, so print it for the
# release notes and refuse to package an image aimed at the wrong partition.
cvimg_burn_addr() { printf '0x%s' "$(xxd -s 8 -l 4 -p "$1")"; }

cmd_release() {
    local ver="${1:-$(git -C "$HERE" describe --tags --always --dirty)}"
    cmd_kernel
    cmd_rootfs
    local k="$KDIR/kernel-img/iwe3000n/kernel-6.18.img"
    local r="$UP/3-Main-SoC-Realtek-RTL8196E/33-Rootfs/rootfs.bin"
    [ -s "$k" ] && [ -s "$r" ] || die "build produced no images"
    [ "$(cvimg_burn_addr "$k")" = "0x00010000" ] || die "kernel burn address is $(cvimg_burn_addr "$k"), not 0x00010000"
    [ "$(cvimg_burn_addr "$r")" = "0x00200000" ] || die "rootfs burn address is $(cvimg_burn_addr "$r"), not 0x00200000"

    local out="$HERE/out" kn="iwe3000n-v1-${ver}-kernel.img" rn="iwe3000n-v1-${ver}-rootfs.img"
    mkdir -p "$out"
    cp "$k" "$out/$kn"; cp "$r" "$out/$rn"
    (cd "$out" && sha256sum "$kn" "$rn" > sha256sums.txt)
    local ks rs
    ks=$(stat -c %s "$out/$kn"); rs=$(stat -c %s "$out/$rn")
    echo
    echo "release $ver in $out/"
    printf '  %-45s %8d bytes  %4d KiB of 1984 KiB (%d%%)  burn %s\n' "$kn" "$ks" $((ks/1024)) $((ks*100/(1984*1024))) "$(cvimg_burn_addr "$k")"
    printf '  %-45s %8d bytes  %4d KiB of 1600 KiB (%d%%)  burn %s\n' "$rn" "$rs" $((rs/1024)) $((rs*100/(1600*1024))) "$(cvimg_burn_addr "$r")"
    [ "$ks" -le $((1984*1024)) ] || die "kernel does not fit its partition"
    [ "$rs" -le $((1600*1024)) ] || die "rootfs does not fit its partition"
    # The stock loader silently refuses kernels somewhere between 1808 and
    # 1896 KiB (docs/M6-FLASH-BUDGET.md): warn before anyone TFTPs it.
    [ "$ks" -le $((1808*1024)) ] || echo "  WARNING: kernel is larger than any image the loader has been seen to accept (1808 KiB); verify the flash writes"
    cat "$out/sha256sums.txt"
}

case "${1:-}" in
    deps)    cmd_deps ;;
    overlay) cmd_overlay ;;
    kernel)  cmd_kernel ;;
    rootfs)  cmd_rootfs ;;
    release) cmd_release "${2:-}" ;;
    shell)   cmd_shell ;;
    *)       sed -n '3,17p' "$0"; exit 1 ;;
esac
