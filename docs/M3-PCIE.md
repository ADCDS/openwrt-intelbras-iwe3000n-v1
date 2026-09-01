# M3 — PCIe host reaching L0

**Status: not achieved. Characterised, reproducible, and the remaining work is
now known rather than guessed.**

## What the board does

```
[    1.823840] rtl819x-pcie 18b00000.pcie: link training failed, LTSSM = 0x00
[    1.846760] rtl819x-pcie 18b00000.pcie: LTSSM reads 0 -- the PHY is not running, not merely unlinked
[    1.876920] rtl819x-pcie 18b00000.pcie: probe with driver rtl819x-pcie failed with error -145
```

The driver loads, runs and reports cleanly. The plumbing is right; the hardware
is not coming up.

## What was measured, live, with devmem on the running board

The board has `/sbin/devmem`, so the sequence was tested directly rather than
through build-and-flash cycles.

**The system controller works. The PCIe block does not exist as far as the CPU
is concerned:**

| address | reads | |
|---|---|---|
| `0x18000000` | `0x8196E001` | SoC ID — devmem works, and this *is* an RTL8196E |
| `0x18002000` | `0x30000000` | UART0, live |
| `0x18003500` | `0xFFFFFFDF` | GPIO, live |
| `0x18000010` | `0x01000F08` | our clock + PHY-reset writes **took** |
| `0x1800003c` | `0x0000000F` | our MDIO-reset writes **took** |
| `0x18000044` | `0x00000009` | PCIe PLL enable **took** |
| `0x18b00000` | `0x00000000` | PCIe root complex |
| `0x18b01008` | `0x00000000` | PHY control — **writes vanish**, `0x81` reads back `0x00` |
| `0x18b00728` | `0x00000000` | LTSSM |
| `0x18b10000` | `0x00000000` | device config space |
| `0x18f00000` | `0x00000000` | **an address that decodes nothing reads the same** |

That last row matters: on this SoC an undecoded read returns 0 rather than
faulting, so "reads 0" and "not present" are indistinguishable. The PCIe block
is either unpowered or not yet decoding.

The **complete** vendor sequence was executed live, in order, with 1 s between
steps — PLL `0x18000044=0x9`, clock `0x18000010|=0x500`, MDIO reset
`0x1800003c=0x1` then `0x3`, PHY `0x18b01008=0x1` then `0x81`, crystal
`0x18b01000=0xcc011901`, PHY-reset bit `0x18000010|=0x01000000`. Every
system-controller write read back correctly. **Every PCIe-block write was lost
and every read returned zero.**

## The addresses are right

An early theory was that `0x18b0xxxx` came from a vendor branch guarded for
other SoCs (`rtl8196b_pci_reset` is explicitly excluded for `CONFIG_RTL_8196E`).
That theory is **wrong**, and checking it is what produced the real answer.

`lekswrt/rtl8196e` — an OpenWrt tree with an actual `rtl8196e` target — carries
`target/linux/realtek/files/drivers/net/wireless/rtl8192cd/8192cd_host.c` using
**the same addresses**: `0xb8000044`, `0xb8000010`, `0xb800003C`, `0xb8b01008`,
`0xb8b01000`. So the register map applies to this SoC.

## What is actually missing

The same file contains what the reset sequence alone does not:

- **`PCIE_PHY_MDIO_Write(portnum, regaddr, val)`** (line 1877) — an MDIO
  controller for the PCIe PHY.
- **41 PHY register writes** in `{port, reg, value}` tables:
  `{0, 8, 0x18d7}, {0, 9, 0x530c}, {0, 0xa, 0x00e8}, {0, 0xb, 0x0511},
  {0, 0xc, 0x0828}, {0, 0xd, 0x17a6}, {0, 0xe, 0x98c5}, {0, 0xf, 0x0f0f},
  {0, 0x10, 0x000c}, {0, 0x11, 0x3c00}, …`
- The RTL8196E target config selects `CONFIG_RTL_PCIE_SIMPLE_INIT=y`,
  `CONFIG_AUTO_PCIE_PHY_SCAN=y`, `CONFIG_USE_PCIE_SLOT_0=y` — a specific init
  path, not the generic one.

**So M3 is not "release a reset bit". It is: implement an MDIO controller for
the PCIe PHY, drive a 41-entry initialisation table through it, and only then
does the register block become readable.** The knowledge exists; the scope is a
sub-project, not a patch.

## What was tried and failed

- **Reset-only sequence** (two writes to `0x18b01008`, no delays, no clock):
  LTSSM 0x00. This was the first attempt and it was wrong in three ways at once.
- **Adding the clock and MDIO reset** with 10 ms settles: LTSSM 0x00.
- **Adding the PCIe PLL** (`0x18000044 = 0x9`, missed initially): LTSSM 0x00.
- **Adding the external-crystal write** (`0x18b01000 = 0xcc011901`): LTSSM 0x00.
- **Extracting the stock `rtl8192cd.ko`** from our own flash dump to read this
  board's real addresses: `unsquashfs` 4.6.1 fails with `xz uncompress failed
  with error code 7` on most files — the vendor used an XZ filter it cannot
  handle. Only 17 of 911 inodes came out, and the module was not among them.
  Worth retrying with a squashfs build that has the MIPS BCJ filter.

## Where this leaves the project

M4–M6 all sit behind M3, so the radio half of the goal is behind a piece of work
that is larger than it looked when the route was chosen. Nothing about M1 or M2
is affected — ethernet is measured and working.

The fallback stated in `FEASIBILITY.md` is unchanged and is now more attractive:
**`lekswrt/rtl8196e` already has this PHY init working**, along with the
`rtl8192cd` driver, on Linux 3.10.49 at 4 MB. Its `8192cd_host.c` is the very
file quoted above. Trading a modern kernel for a working radio is a real option,
and the same tree is where the MDIO sequence would be ported *from* either way.
