# M4 — rtl8192ee probes and the firmware loads

**Status: achieved on hardware 2026-09-01.**

```
rtl8192ee 0000:01:00.0: enabling device (0000 -> 0002)
rtl8192ee: Using firmware rtlwifi/rtl8192eefw.bin
ieee80211 phy0: Selected rate control algorithm 'rtl_rc'
rtlwifi: rtlwifi: wireless switch is on

# ls /sys/class/ieee80211/
phy0
# ip -o link
lo   eth0   wlan0
```

No firmware error, a registered `phy0`, and a `wlan0` netdev. The goal's M4
wording asks for `iw dev` to show a phy; `iw` is not in this rootfs (upstream
ships none, see M5), so sysfs is the equivalent evidence.

## Verified on the board

```
rtl819x-pcie 18b00000.pcie: host bridge /soc/pcie@b00000 ranges:
rtl819x-pcie 18b00000.pcie:      MEM 0x0018c00000..0x00193fffff -> 0x0018c00000
rtl819x-pcie 18b00000.pcie: link up, downstream device 10ec:818b
rtl819x-pcie 18b00000.pcie: PCI host bridge to bus 0000:00
pci 0000:01:00.0: [10ec:818b] type 00 class 0x028000 PCIe Endpoint
pci 0000:01:00.0: BAR 2 [mem 0x18c00000-0x18c03fff 64bit]: assigned
rtl8192ee 0000:01:00.0: enabling device (0000 -> 0002)
rtlwifi: rtlwifi: wireless switch is on
rtl8192ee: Using firmware rtlwifi/rtl8192eefw.bin
```

The RTL8192EE is enumerated by mainline's PCI core as a proper endpoint, its
MMIO BAR is assigned out of the DT range, and mainline's `rtl8192ee` driver
binds to it. This is the whole point of M3/M4: no Realtek vendor code anywhere
in the path.

## The two faults between "link up" and "driver bound"

**Config space is 32-bit only.** With `pci_generic_config_read`/`write` the root
port's header type register read back as **16** — not a valid header type — and
the PCI core said `unknown header type 16, ignoring device` and enumerated
nothing. The `_32` variants read the containing dword and shift; with those the
same register reads `type 00` and enumeration proceeds.

**Firmware cannot live in the rootfs.** The driver is built in (upstream has
`CONFIG_MODULES` unset), so it probes at ~3.0 s during kernel init — before the
rootfs is mounted at ~3.1 s. `/lib/firmware/rtlwifi/rtl8192eefw.bin` was present
in the squashfs and still failed:

```
rtl8192ee: Direct firmware load for rtlwifi/rtl8192eefw.bin failed with error -2
rtlwifi: Selected firmware is not available
```

`-2` is ENOENT, and it is a timing fact, not a missing file. The fix is
`CONFIG_EXTRA_FIRMWARE`, which links the blob into the kernel image.

**And staging that firmware has an ordering trap.** `EXTRA_FIRMWARE_DIR` is
relative to the kernel source tree, but `build.sh kernel` wipes that tree
(`IMEM_POLICY_DISABLE=1` requires a clean one) *after* the overlay step runs.
Blobs staged straight into the tree are deleted before the build, and the image
comes out byte-identical with no firmware in it and no error anywhere. They go
in `files-6.18/firmware/` instead, which upstream copies over the tree after
extraction.

## Known, not yet addressed

- **`rtlwifi: RTL8XXX did not boot from eeprom, check it !!`** — this board has
  no EEPROM; its calibration is in the H601 block at `mtd0+0x6000`. The driver
  falls back to defaults, which is probably why the MAC is also wrong. Reading
  the real values out of `mtd0` is future work and shares the `nvmem-cell`
  mechanism the ethernet MAC needs (see `M2-ETHERNET.md`).
- **`BAR 0 [io size 0x0100]: can't assign; no space`** — the endpoint asks for
  an I/O BAR and the DT `ranges` declares only memory. rtlwifi uses MMIO, so
  this is harmless, but an `0x01000000` I/O range could be added to silence it.
