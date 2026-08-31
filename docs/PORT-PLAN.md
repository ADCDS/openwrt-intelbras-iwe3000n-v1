# Port plan — jnilo1/rtl8196e-gateway

Route chosen 2026-08-31. This document answers the question `FEASIBILITY.md`
listed as unmeasured — **does it fit 4 MB** — and it does, with room.

## The size question, answered

Measured from the shipped prebuilt images in
[jnilo1/rtl8196e-gateway](https://github.com/jnilo1/rtl8196e-gateway), not
estimated:

| | bytes | |
|---|---|---|
| `kernel-6.18.img` | 1,441,792 | 1408 KiB |
| `kernel-7.1.img` | 1,462,272 | 1428 KiB |
| rootfs skeleton, uncompressed | ~1.4 MB | squashfs will be well under half |
| **our `linux` region** (`0x010000`–`0x400000`) | 4,128,768 | **4032 KiB** |

The decisive evidence is upstream's own reference layout for the 16 MB Lidl
board:

```
boot+cfg  0x000000 0x020000   128 KB
linux     0x020000 0x1e0000  1920 KB
rootfs    0x200000 0x200000     2 MB
jffs2-fs  0x400000 0xc00000    12 MB
```

**Boot + kernel + rootfs come to exactly `0x400000` — the entire size of our
chip.** Their 12 MB `jffs2-fs` is the only part that does not fit, and it is
userdata for a Zigbee gateway, not something this board needs.

## Proposed flash layout

Drafted in
[`../files/arch/mips/boot/dts/realtek/rtl8196e-intelbras-iwe3000n.dts`](../files/arch/mips/boot/dts/realtek/rtl8196e-intelbras-iwe3000n.dts).

| | start | end | size | |
|---|---|---|---|---|
| `boot` | `0x000000` | `0x010000` | 64 KiB | **read-only, never written** |
| `kernel` | `0x010000` | `0x1B0000` | 1664 KiB | 1408 KiB image → 85 % used |
| `rootfs` | `0x1B0000` | `0x390000` | 1920 KiB | squashfs |
| `rootfs_data` | `0x390000` | `0x400000` | 448 KiB | jffs2 overlay |

Closes exactly on 4 MB. The overlay is deliberately near-identical to stock's
440 KiB at `0x392000`, so nothing about the writable budget gets worse.

Stock splits the same region 1028 KiB kernel / 2.93 MB rootfs; a 6.18 kernel is
1408 KiB, so that boundary has to move. Both figures still want confirming
against a real squashfs once one is built.

## The two findings that make this route work

**1. No bootloader replacement is needed.** Upstream ships a replacement
bootloader, and this board must not use it — `mtd0` holds the H601 factory block
with this unit's MAC and RF calibration, and nothing can regenerate them. That
looked like a blocker and is not: their kernel image is packaged with the
**`cvimg` Realtek header**, and `kernel-6.18.img` begins `63 73 36 63` — `cs6c`,
byte-for-byte the same magic as the Intelbras factory image in
[`../../iwe3000n-firmware/vendor/`](../../iwe3000n-firmware/vendor/). **The stock
loader already knows how to boot this format.** Their bootloader is a
convenience (cleaner output, TFTP percentage, reboot-to-bootloader from Linux),
not a dependency.

One difference to reconcile: the shipped image carries load address
`0x80560000`, while our loader logs `Jump to image start=0x80500000`. The
address lives in the cvimg header and is a build parameter.

**2. The flash chip needs no work.** `spi-rtl819x.c` is a generic SPI
*controller* driver (`compatible = "realtek,rtl819x-spi"`); the chip itself goes
through mainline `jedec,spi-nor`, where W25Q32 has been supported for years.
Upstream's prose says "16 MB GD25Q127C" throughout, but that is their board, not
a driver constraint.

## What actually has to be built

1. **Toolchain** — `1-Build-Environment/install_deps.sh`, ~45 min and ~4 GB, or
   the Docker path. Builds a patched Lexra MIPS toolchain (GCC 15 / binutils
   2.45 / musl), because a stock `mips-linux` toolchain cannot target a Lexra
   core.
2. **Board DTS** — drafted. Memory, console and flash are measured; **LED and
   button GPIOs are not traced and are left as TODO** rather than guessed. The
   EFR32 `radio-bridge` node is dropped; there is no such radio here.
3. **Kernel config** — from `config-6.18-realtek.txt`, minus the Zigbee/EFR32
   pieces.
4. **cvimg load address** — `0x80500000` to match our loader.
5. **Rootfs** — `33-Rootfs/build_rootfs.sh`, BusyBox + dropbear.
6. **Install** — write `kernel` and `rootfs` only. `mtd0` stays untouched, so
   the stock loader and the factory block survive by construction.

## What this route costs

**No Wi-Fi.** `CONFIG_WLAN` is unset upstream and there is no `rtl8192cd` in the
tree. On a device whose only purpose is being a 2.4 GHz repeater, that is the
whole function. Getting it back means forward-porting the vendor driver to 6.x,
which is a project in itself — the source is public (119 files including
`8192e_reg.h`) but the driver is WEXT-era against a modern kernel.

So the realistic near-term outcome is **a modern-kernel RTL8196E box with
working ethernet and no radio**. Worth being explicit about that before the
toolchain build starts.

The alternative, [lekswrt/rtl8196e](https://github.com/lekswrt/rtl8196e), has
working ethernet *and* the 8192E driver at 4 MB, on OpenWrt 14.07 / Linux
3.10.49 — the same vintage the device already runs, unmaintained since 2019.
That trade is set out in [`FEASIBILITY.md`](FEASIBILITY.md).

## Naming

This repo is called `openwrt-intelbras-iwe3000n-v1`, and jnilo1's tree is **not
OpenWrt** — it is mainline Linux plus BusyBox and dropbear, with no uci, no
opkg and no LuCI. The name is now inaccurate. Renaming is cheap today and gets
harder later.
