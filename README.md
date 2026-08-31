# openwrt-intelbras-iwe3000n-v1

OpenWrt for the **Intelbras IWE 3000N v1** — RealTek **RTL8196E**, 4 MB flash,
32 MB RAM, RTL8192ER 2.4 GHz radio.

> ## Status: **nothing works yet. Nothing has been built yet.**
>
> This repo is a plan and an assessment, not a build recipe. There is no
> `build.sh`, no image, no boot. Do not expect to flash anything from here.
>
> Compare [`../../dir842/openwrt-dlink-dir842-r1`](../../dir842/openwrt-dlink-dir842-r1),
> which is what this becomes if it works out.

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
| Wi-Fi | **RTL8192ER**, 2×2 802.11b/g/n, 2 internal 2 dBi antennas, vendor `rtl8192cd` driver |
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

## Proposed milestones

Nothing past M1 should start before M0 and M1 are both done.

- **M0 — Back it up.** *Half done.* The boot log is captured (2026-08-31) and
  answered the flash chip — Winbond **W25Q32**, JEDEC `0xEF4016`, 4 MB single-IO
  — the loader version, the real MTD offsets, and the existence of OpenWrt
  **failsafe mode** as an overlay-level recovery path. **The 4 MB dump is still
  outstanding and is now the only thing blocking everything else.**
  *(See [`../iwe3000n-firmware/README.md`](../iwe3000n-firmware/README.md).)*
- **M1 — Map the board.** Partly answered: the LAN jack is **a VLAN on the SoC
  switch**, not a lone PHY (`eth0 vid=9 Member port 0x10f`, `eth1 vid=8 Member
  port 0x110`, `peth0` mapped to `eth1`). Still open: whether the loader stops on
  a keypress and which one, the GPIO map for LEDs and the reset button, and where
  the factory MAC lives.
- **M2 — Pick a base.** Decide between the three routes in
  [`docs/FEASIBILITY.md`](docs/FEASIBILITY.md) §"Three routes". This is the real
  decision point and it should be made with M0/M1 evidence, not now.
- **M3 — RAM-boot something.** Any kernel that reaches a shell over serial
  without touching flash. Copy the DIR-842's posture: RAM-only until proven.
- **M4 — Ethernet, then flash write.** Not before a network path exists to
  recover over.
- **M5 — Wi-Fi.** `rtl8192cd`, reusing
  [`../../dir842/dir842-rtl8192cd-driver/`](../../dir842/dir842-rtl8192cd-driver/)
  where it applies.

## What this device would actually be good for

Worth deciding early, because it shapes M2. With one 100 Mbit port and a 2.4 GHz
n radio, this is never going to be a gateway. Realistic end states: a dumb AP, a
serial-over-IP box, an mqtt/sensor node, or simply *a Lexra target to learn on*.
If the answer is "a dumb AP", stock already does that, and the honest question in
[`docs/FEASIBILITY.md`](docs/FEASIBILITY.md) §"Is this worth it" applies.
