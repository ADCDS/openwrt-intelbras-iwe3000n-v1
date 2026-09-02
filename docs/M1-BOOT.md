# M1 — boots unattended to a shell

**Status: done, verified on hardware 2026-08-31.**

Linux 6.18.45 on the Intelbras IWE 3000N v1 (RTL8196E, Lexra RLX4181). As far as
this project can establish, the first mainline-kernel boot on any Intelbras
device — the OpenWrt forum's position in January 2024 was "No Intelbras devices
are currently supported."

## What was measured

Captured over the `uart-ota` bridge at 38400 8N1, after a cold power cycle with
nothing attached but the console:

```
Jump to image start=0x805a0000...
OF: reserved mem: 0x01ffe000..0x01ffefff boothold@1ffe000
OF: reserved mem: 0x01ffd000..0x01ffdfff watchdog-crash@1ffd000
Kernel command line: console=ttyS0,38400 loglevel=7 root=/dev/mtdblock2 rootfstype=squashfs
Memory: 26200K/32768K available (3381K kernel code, 349K rwdata, 796K rodata,
        1204K init, 117K bss, 6220K reserved)
0x000000000000-0x000000010000 : "boot"
0x000000010000-0x000000200000 : "kernel"
0x000000200000-0x000000390000 : "rootfs"
0x000000390000-0x000000400000 : "rootfs_data"
VFS: Mounted root (squashfs filesystem) readonly on device 31:2.
Freeing unused kernel image (initmem) memory: 1204K
Run /sbin/init as init process
===== System ready =====
(none) login:
```

Drivers that probed: `irq-rtl819x v1.2`, `timer-rtl819x v1.3`, `realtek-spi
v1.2`, `rtl8196e-eth v2.24`, `rtl819x-wdt v1.12`, `rtl8196e-uart-bridge v1.7`.
BogoMIPS 392.70.

The partition table in the boot log is this port's, not upstream's — it is the
proof the board DTS is the one in the image.

## How it was flashed

Both images went in over the loader's TFTP, and **the loader reported each burn
address itself** before writing:

```
Linux kernel upgrade.     checksum Ok !  burn Addr =0x00010000!  Flash Write Successed!
Root filesystem upgrade.  checksum Ok !  burn Addr =0x00200000!  Flash Write Successed!
```

`mtd0` was not written. The stock RealTek loader and the H601 factory block at
`0x6000` are untouched, so the board remains restorable from the verified dump
or from Intelbras's image ([`RECOVERY.md`](RECOVERY.md)).

Procedure, reproducible:

1. Reach the `<RealTek>` prompt. ESC during the boot window works; the reliable
   trigger is `reboot` from the running shell, then a burst of ~24 ESC over
   ~240 ms once the loader announces itself.
2. Put the workstation on the loader's subnet: `IPCONFIG` at the prompt reports
   `Target Address=192.168.1.6`. `sudo ip addr add 192.168.1.10/24 dev <iface>`.
3. **Wait for the link.** The loader's PHY needs several seconds to negotiate
   with a USB-eth adapter; confirm with `ip neigh show 192.168.1.6` returning an
   `lladdr` before transferring. A TFTP started too early just times out.
4. `tftp -m binary 192.168.1.6 -c put <image>`.

## What was tried and failed

- **`HELP`, `?`, `D`, `BOOT`, `GO`, `RESET`, `reboot` are all "Unknown command
  !"** at the loader prompt. Confirmed working: `IPCONFIG`, TFTP put, and `J`.
- **`J` with no operand jumps to whatever address is left in the buffer** — it
  went to `0x8040DC40`, took an undefined exception and wedged the loader,
  costing a power cycle. Do not issue `J` without an address.
- **The loader answers ARP but not ICMP.** jnilo1's replacement bootloader adds
  ping; the stock one has none, so `ping 192.168.1.6` failing proves nothing.
  Use the ARP entry.
- **The first rootfs transfer timed out** because the catcher script did not
  drain the bridge's replay backlog. `uart-ota` replays its whole ring on
  connect, so a state machine watching for `Booting...` / `<RealTek>` matches
  *history* and fires ESC and TFTP while the board is mid-panic. Drain first.
- **A kernel flashed without a matching rootfs panics and reboot-loops**
  (`Unable to mount root fs on "/dev/mtdblock2"`, `Rebooting in 10 seconds`).
  Harmless — every cycle is another loader window — but flash both.

## Not yet true

Reaching a shell needs M2's credential fix: `/etc/passwd` is a dangling symlink
into a `/userdata` partition this board does not have. The login prompt appears
and rejects every password. See `../files/rootfs/README.md`.
