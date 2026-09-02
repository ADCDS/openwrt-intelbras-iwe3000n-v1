# Recovery, flash map, and the one rule

**Nothing writes `mtd0`.** The first 64 KiB of the flash hold the RealTek
bootloader *and* this unit's factory block — its MAC address and what reads
like per-channel TX-power calibration. There is no separate calibration
partition on this board and no vendor image contains that block, so a
destroyed `mtd0` is a destroyed unit. Everything else on the chip can be put
back.

Every image this repo produces carries its burn address in its own header
(`0x00010000` for the kernel, `0x00200000` for the rootfs), the stock loader
writes only where the header says, and `build.sh release` refuses to package
an image aimed anywhere else. Still: read the loader's `burn Addr =` line
before trusting a write.

## The flash, as stock lays it out

Winbond W25Q32, 4 MiB, SPI-NOR, single-IO. Measured from the stock kernel's
own MTD table (which is what the loader's `linuxpart=0x10000` implies), not
derived:

| mtd | start | end | size | |
|---|---|---|---|---|
| mtd0 | `0x000000` | `0x010000` | 64 KiB | `boot` — loader + factory block. **Never written.** |
| mtd1 | `0x010000` | `0x400000` | 4032 KiB | `linux` — stock kernel + rootfs as one region |
| ↳ kernel | `0x010000` | `0x111000` | 1028 KiB | LZMA kernel, ahead of the squashfs |
| mtd2 | `0x111000` | `0x400000` | 2.9 MiB | `rootfs` — squashfs |
| mtd3 | `0x392000` | `0x400000` | 440 KiB | `rootfs_data` — jffs2 overlay, carved from the tail |

The factory block sits at `mtd0 + 0x6000`, tagged `H601`, with two copies of
the MAC at `+0x0d` and `+0x13` and a table of small values after it. `mtd0` is
densely used (0.3 % erased bytes) — it is not a loader with blank space behind
it.

## The flash, as this port lays it out

Set in `files/arch/mips/boot/dts/realtek/rtl8196e-intelbras-iwe3000n.dts` and
confirmed from `/proc/mtd` on the running board:

| partition | start | end | size | written by |
|---|---|---|---|---|
| `boot` | `0x000000` | `0x010000` | 64 KiB | nobody |
| `kernel` | `0x010000` | `0x200000` | 1984 KiB | `*-kernel.img`, burn `0x00010000` |
| `rootfs` | `0x200000` | `0x390000` | 1600 KiB | `*-rootfs.img`, burn `0x00200000` |
| `rootfs_data` | `0x390000` | `0x400000` | 448 KiB | the board itself (jffs2 on first boot) |

`0x10000 + 0x1f0000 + 0x190000 + 0x70000 = 0x400000` — exactly the chip.
Because both images live inside stock's `linux` region and neither touches
`boot`, flashing this port is identity-preserving, and restoring stock is a
matter of writing `linux` back.

## Back up before you flash

Stock is an OpenWrt fork and drops you into a **root shell with no password**
on the serial console (`admin@meurepetidor:/#`). From there, read every
partition:

```sh
for i in 0 1 2 3; do dd if=/dev/mtd$i of=/tmp/mtd$i.bin; md5sum /tmp/mtd$i.bin; done
```

`/tmp` is RAM, and the whole chip is 4 MiB, so it fits. Move the files off over
the LAN with whatever stock's BusyBox offers (`tftp -p`, `nc`), compare the
`md5sum` on both ends, and **keep the copy off the device** — it is the only
restore source that carries *your* unit's `mtd0`. Intelbras's own firmware
(`iwe3000n_0.8.6.zip`, from their download page for the IWE 3000N; the server
wants a browser User-Agent) covers `linux` only and will bring a unit back to a
working stock system, but not to its original MAC or calibration.

## Two ways back

**Stock's failsafe.** While stock is still installed, its preinit prints
`Press the [f] key and hit [enter] to enter failsafe mode` on the console every
boot. Failsafe boots the squashfs with the overlay unmounted, which undoes any
mistake confined to configuration; `firstboot` wipes the overlay. This path
does not exist once this port is installed (the rootfs here is BusyBox +
dropbear, not OpenWrt).

**The loader's TFTP.** The RealTek loader stops on **ESC** — it advertises no
prompt and no countdown, but a burst of a couple of dozen ESCs during the boot
window (after `Booting...`, before the kernel's first line) lands you at
`<RealTek>`. It brings its Ethernet up before it prompts:

```
---RealTek(RTL8196E)at 2015.01.14-09:49+0800 v1.0 [16bit](400MHz)
---Escape booting by user
P0phymode=01, embedded phy
---Ethernet init Okay!
<RealTek>
```

What the prompt is known to do, from trying it:

- `IPCONFIG` — reports its address, `192.168.1.6`.
- A TFTP **put** to that address of a `cvimg`-headed image writes it at the
  header's burn address and reports `checksum Ok !`, `burn Addr =0x...!`,
  `Flash Write Successed!`.
- `J <addr>` jumps. **`J` with no operand jumps to garbage** and wedges the
  loader until a power cycle.
- `HELP`, `?`, `D`, `BOOT`, `GO`, `RESET`, `reboot` are all `Unknown command !`.
- It answers ARP but not ICMP — `ping` proving nothing is expected. Wait for
  `ip neigh show 192.168.1.6` to show an `lladdr` before transferring; the PHY
  needs a few seconds after link-up.
- It **silently refuses kernels above a size somewhere between 1808 and
  1896 KiB**: `checksum Ok !`, the burn address, then a scan of
  `no sys signature at ...` and no write. Kernels up to 1816 KiB (v1.0 ships
  1812) write fine.

⚠ Never type at the loader prompt at the wrong baud rate. It is a command
interpreter with flash-write commands; garbage bytes are still bytes. The
console is **38400 8N1**, for the loader and for Linux.

To restore stock from your own dump, TFTP-put the `mtd1` slice **only if it
carries a `cvimg` header** — a raw `dd` of `mtd1` does not; the loader
needs the header to know where to write. Intelbras's `iwe3000n_0.8.6.bin` is
a `cvimg` image (`cs6c` magic, the same the kernel image here uses) and is the
practical stock-restore file. Neither restore has been exercised on this bench
yet — check the burn address the loader prints against `0x00010000` before
letting it write.

## What has actually gone wrong, and what it cost

- A kernel flashed without a matching rootfs panics (`Unable to mount root fs`)
  and reboot-loops every 10 s. Harmless: each loop is another loader window.
  Flash both images.
- A hung PCIe endpoint (the radio) needs a **cold power cycle**, not a reboot.
- Roughly one cold boot in ten faults in userspace before `System ready`
  (see README, *Known issues*). A power cycle clears it.
- Nothing has ever written `mtd0`, and the sequence above has been repeated a
  few dozen times on this unit while developing the port.
