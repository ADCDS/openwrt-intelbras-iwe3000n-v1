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

- **The efuse read.** Up to M4 the driver printed `RTL8XXX did not boot from
  eeprom` (a garbage-MMIO symptom of the BAR 2 aperture bug); correcting `ranges`
  stopped it and MAC init succeeded. But the efuse *content* was still wrong,
  which only a debug build revealed: `EEPROM ID(0x2981) is invalid!!`, the magic
  0x8129 read byte-swapped on this big-endian CPU. That is a real rtlwifi bug,
  fixed in M5 (`patches/rtlwifi-efuse-big-endian-eeprom-id.patch`); the efuse now
  reads `Autoload OK` and the chip's real MAC and calibration load. See
  `M5-AP.md`.
- **The RTL8192EE's own efuse MAC** (now `00:e0:4c:81:92:b2`, read correctly
  after the efuse fix) is the chip's, not the board's `D8:77:8B:3F:E2:01` from
  the H601 block. Wiring the H601 MAC in is future work sharing the `nvmem-cell`
  mechanism the ethernet MAC needs (see `M2-ETHERNET.md`).
- **`BAR 0 [io size 0x0100]: can't assign; no space`** — the endpoint asks for a
  0x100-byte I/O BAR the driver never uses, and the DT declares no I/O range.
  **Leave it that way.** Adding an I/O range does not silence it harmlessly — it
  makes the generic host bridge call `devm_pci_remap_iospace()` →
  `vmap_page_range()`, which BUGs on this Lexra MIPS (no `PCI_IOBASE` fixmap).
  See `M5-AP.md` for the full trace. The warning is the correct outcome.
