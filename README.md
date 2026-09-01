# openwrt-intelbras-iwe3000n-v1

OpenWrt for the **Intelbras IWE 3000N v1** — RealTek **RTL8196E**, 4 MB flash,
32 MB RAM, RTL8192EE 2.4 GHz radio.

> ## Status: **it boots, routes, and beacons.** jnilo1 Linux 6.18 on the board.
>
> M1–M6 are verified on hardware and committed. The board runs a 1784 KiB
> kernel + squashfs rootfs flashed over the loader's TFTP: ethernet works, the
> RTL8192EE comes up over a from-scratch PCIe host driver, and `hostapd` brings
> up a WPA2 AP that reaches `AP-ENABLED`. The one thing left is a real client
> associating and passing traffic, which needs a person with a phone — see
> [`docs/M5-AP.md`](docs/M5-AP.md). Per-milestone results are in `docs/M*.md`.
>
> `./build.sh kernel` and `./build.sh rootfs` build the images; recovery to
> stock is [`../iwe3000n-firmware/RESTORE-TO-STOCK.md`](../iwe3000n-firmware/RESTORE-TO-STOCK.md).
> Compare [`../../dir842/openwrt-dlink-dir842-r1`](../../dir842/openwrt-dlink-dir842-r1).

## Read this first

**[`docs/FEASIBILITY.md`](docs/FEASIBILITY.md)** — the honest assessment. It
argues that the interesting target here is probably *not* current OpenWrt, and
explains why. If you only read one file, read that one.

**[`docs/PRIOR-ART.md`](docs/PRIOR-ART.md)** — who has already done RTL8196E
work, and what they got working.

## The hardware

| | |
|---|---|
| SoC | RealTek **RTL8196E** — Lexra **RLX5281**, ~400 MHz, MIPS16, 32 TLB entries |
| RAM | **32 MB** (`MemTotal: 29284 kB`) |
| Flash | **4 MB**, 4 KB erase — layout in [`../iwe3000n-firmware/PARTITIONS.md`](../iwe3000n-firmware/PARTITIONS.md) |
| Wi-Fi | **RTL8192EE** (`10ec:818b`, PCIe), 2×2 802.11b/g/n, 2 internal antennas; mainline `rtl8192ee` |
| Ethernet | **one** 100 Mbit LAN jack |
| Power | mains, wall-plug form factor, 6 W max |
| Console | **38400 8N1** |

## The situation in three facts

1. **Stock firmware is already OpenWrt** — and the boot log removes any doubt:
   the kernel is unpacked by *OpenWrt's own* lzma-loader, `OpenWrt kernel loader
   for Realtek 819X, Copyright (C) 2011 Gabor Juhos`. Add
   `DISTRIB_TARGET="realtek_4181/generic"`, BusyBox 1.22.1, Linux 3.10.49 built
   October 2018 with `Realtek RSDK-4.6.4`, full uci and overlayfs, and OpenWrt
   failsafe on the console. This is a vendor fork of roughly Barrier Breaker.
   Everything you would normally have to bring up — kernel, ethernet driver,
   Wi-Fi driver, flash map, boot — **already works on this box today.** The job
   is replacing a fork you do not control, not a bring-up from zero.

2. **4 MB / 32 MB is below OpenWrt's supported floor.** Upstream has told people
   not to buy 4/32 devices since 18.06. The replacement image has to fit in the
   3.94 MB `linux` partition, kernel and rootfs together.

3. **The core is a Lexra RLX5281, not a MIPS32.** Lexra omitted patented
   instructions, so a stock `mips-linux` toolchain does not simply work. The
   RTL8196E is on the *better* side of this (it has `lwl/lwr/swl/swr`, unlike the
   older RTL8186), but mainline Linux and mainline OpenWrt have never carried
   RTL819x. OpenWrt's `realtek` target is RTL838x/RTL839x **switch** silicon —
   different chips, not this.

## Milestones

All verified on hardware and committed; the write-up for each is in
`docs/`. The descriptions below are the original plan, annotated with results.

- **M0 — Back it up.** *Half done.* The boot log is captured (2026-08-31) and
  answered the flash chip — Winbond **W25Q32**, JEDEC `0xEF4016`, 4 MB single-IO
  — the loader version, the real MTD offsets, and the existence of OpenWrt
  **failsafe mode** as an overlay-level recovery path. **The 4 MB dump is still
  outstanding and is now the only thing blocking everything else.**
  *(See [`../iwe3000n-firmware/README.md`](../iwe3000n-firmware/README.md).)*
- **M1 — Map the board.** ✅ [`docs/M1-BOOT.md`](docs/M1-BOOT.md). The LAN jack
  is **a VLAN on the SoC switch**, not a lone PHY (`eth0 vid=9 Member port
  0x10f`, `eth1 vid=8 Member port 0x110`, `peth0` mapped to `eth1`). The loader
  stops on a 24-ESC burst; the factory MAC lives in the H601 block at
  `mtd0+0x6000` and is not yet wired into the driver (see `M2-ETHERNET.md`).
- **M2 — Pick a base.** ✅ **Done: [jnilo1/rtl8196e-gateway](https://github.com/jnilo1/rtl8196e-gateway)**,
  mainline Linux 6.18. The 4 MB question that blocked this decision is answered
  — it fits, with 85 % of a 1664 KiB kernel partition used and the overlay no
  smaller than stock's. See **[`docs/PORT-PLAN.md`](docs/PORT-PLAN.md)**, which
  also explains why no bootloader replacement is needed and what the route
  costs (no Wi-Fi).
- **M3 — RAM-boot something.** ✅ Kernel reaches a serial shell; PCIe host
  trains to L0. [`docs/M3-PCIE.md`](docs/M3-PCIE.md).
- **M4 — Ethernet, then flash write.** ✅ Ethernet works and the loader's TFTP
  writes the kernel at `0x00010000`; the RTL8192EE enumerates over a
  from-scratch PCIe host driver. [`docs/M4-RADIO.md`](docs/M4-RADIO.md).
- **M5 — Wi-Fi.** ✅ **The radio works.** Not a `rtl8192cd` forward-port after
  all — the radio is a **RTL8192EE** (`10ec:818b`) mainline has driven since
  Linux 3.16, and the missing piece was a **PCIe host controller** for the
  RTL819x, now written (`files/drivers/pci/controller/pci-rtl819x.c`). `hostapd`
  reaches `AP-ENABLED`; a real-client test needs a phone.
  [`docs/M5-AP.md`](docs/M5-AP.md), [`docs/WIFI-PLAN.md`](docs/WIFI-PLAN.md).
- **M6 — Fit 4 MB.** ✅ Kernel 1784 KiB, rootfs 923 KiB, both within their
  partitions. [`docs/M6-FLASH-BUDGET.md`](docs/M6-FLASH-BUDGET.md).

## Read also

- **[`docs/PORT-PLAN.md`](docs/PORT-PLAN.md)** — the chosen base, the 4 MB
  arithmetic, the proposed flash layout, and what has to be built.
- **[`docs/WIFI-PLAN.md`](docs/WIFI-PLAN.md)** — how the radio gets back, and
  the one experiment that decides whether it can.

## What this device would actually be good for

Worth deciding early, because it shapes M2. With one 100 Mbit port and a 2.4 GHz
n radio, this is never going to be a gateway. Realistic end states: a dumb AP, a
serial-over-IP box, an mqtt/sensor node, or simply *a Lexra target to learn on*.
If the answer is "a dumb AP", stock already does that, and the honest question in
[`docs/FEASIBILITY.md`](docs/FEASIBILITY.md) §"Is this worth it" applies.
