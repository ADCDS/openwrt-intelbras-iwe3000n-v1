# M3 — PCIe host reaches L0

**Status: achieved on hardware 2026-09-01.**

```
LTSSM = 0x039DF411     (& 0x1f) == 0x11  -> L0
CFG   = 0x818B10EC     -> 10ec:818b, the RTL8192EE
```

Read live from the running board. `0x818B10EC` at `0x18b10000` is the goal's M3
criterion: the RTL8192EE reachable from code that is not Realtek's.

## The sequence that works

Verified step by step with `devmem` on the running board rather than through
build-and-flash cycles.

```sh
# 1. Turn the PCIe IP on. Nothing else has any effect until this is done.
#    bit14 = active_pcie0; bits 12,13,18 are RTL8196E-specific.
CLK_MANAGE=0x18000010          # |= (1<<14)|(1<<12)|(1<<13)|(1<<18)  = 0x00047000
# 2. PERST, in the same register -- bit 26, NOT a GPIO.
#                                 |= (1<<26)                          = 0x04000000
# 3. MDIO reset, at syscon 0x50 (NOT 0x3c).
0x18000050 = 0x8, then 0x9, then 0xB
# 4. Program the PHY: 16 MDIO writes, 40 MHz variant.
#    word = ((reg & 0x1f) << 8) | ((val & 0xffff) << 16) | 1, written to 0x18b01000
0x00=0xD087 0x01=0x0003 0x02=0x4d18 0x05=0x0BCB 0x06=0xF148 0x07=0x31ff
0x08=0x18d5 0x09=0x539c 0x0a=0x20eb 0x0d=0x1766 0x0b=0x0711 0x0f=0x0a00
0x19=0xFCE0 0x1a=0x7e4f 0x1b=0xFC01 0x1e=0xC280
# 5. PHY out of reset.
0x18b01008 = 0x1, then 0x81
# 6. Poll 0x18b00728 for (x & 0x1f) == 0x11.
```

40 MHz is the right variant because the stock firmware's own boot log says so:
`[   16.800000] 98 - 40MHz Clock Source`.

## Why it took so long: the source was in the wrong place

Everything up to this point was read out of `8192cd_host.c`, the **wireless
driver**, because that is where Realtek does PCIe bring-up on other SoCs — and
it is what printed this board's stock `Find Port=0 Device:Vender ID=818b10ec`.

For the RTL8196E the host bring-up is in the **kernel**, at
`arch/rlx/soc-rtl8196e/pci.c` in `lekswrt/rtl8196e`. Three registers differ, and
all three matter:

| | what the wifi-driver branches use | what the RTL8196E actually uses |
|---|---|---|
| PCIe IP enable | *absent* | `CLK_MANAGE \|= (1<<14)` + `(1<<12)\|(1<<13)\|(1<<18)` |
| PERST | GPIO `0x18003500/08/0c` | `CLK_MANAGE \|= (1<<26)` |
| MDIO reset | `0x1800003c` | `0x18000050` |

The first is the one that mattered. Its comment is *"first, Turn On PCIE IP"*.
Without bit 14 the entire block is undecoded — and on this SoC an undecoded read
returns `0`, identical to a register that exists and holds zero, so there was no
signal distinguishing "wrong address" from "held in reset" from "not powered".
The moment bit 14 was set, `0x18b01008` read back `0x81` instead of `0x00`.

## Corrections to earlier notes in this repo

- **`0xcc011901` is not a "crystal write".** `0x18b01000` is the MDIO *command*
  register: `((reg & 0x1f) << 8) | (val << 16) | 1`. So that value is an MDIO
  write of `0xcc01` to PHY register `0x19`. The previous `UNVERIFIED` note in
  `pci-rtl819x.c` describing it as an external-crystal setting was wrong.
- **Reading `0` from `0x18b01000` never meant anything.** An MDIO command
  register is write-triggered; read-back of zero is expected behaviour.
- **The addresses were always right.** An earlier theory held that `0x18b0xxxx`
  came from a branch guarded for other SoCs, since `rtl8196b_pci_reset` is
  excluded for `CONFIG_RTL_8196E`. Disproving that is what led to the kernel
  source: `lekswrt`'s `rtl8196e` target uses the identical addresses.

## What was tried and failed, in order

1. PHY reset alone, no clock, no delays — LTSSM 0x00.
2. Plus clock `0x500` and MDIO reset at `0x3c`, 10 ms settles — LTSSM 0x00.
3. Plus the PCIe PLL `0x18000044 = 0x9` — LTSSM 0x00.
4. Plus `0x18b01000 = 0xcc011901` — LTSSM 0x00.
5. Plus a 40 MHz PHY table from the `ePHY[]` array in the wifi driver — LTSSM 0x00.
6. Plus PERST via GPIO `0x18003500/08/0c` and pinmux — LTSSM 0x00.
7. PERST via `CLK_MANAGE` bit 26 — LTSSM 0x00, but correct.
8. **Plus `CLK_MANAGE` bits 14/12/13/18** — block decodes, PHY reads back.
9. **Plus the 16-entry RTL8196E MDIO table** — **LTSSM 0x11, CFG 0x818B10EC.**

Steps 1-6 were all reading the wrong SoC's code. Step 8 is the one that counts.

Also failed, and still open as a loose end: extracting the stock `rtl8192cd.ko`
from our own dump to read the board's addresses directly. `unsquashfs` 4.6.1
dies with `xz uncompress failed with error code 7` on the vendor's filter — 17
of 911 inodes recovered. A squashfs build with the MIPS BCJ filter would do it.

## Next

This is proven with `devmem`, not yet in the driver. `pci-rtl819x.c` needs the
sequence above plus stage 2 (config accessors, resource windows, host bridge
registration) before Linux enumerates the device and M4 can start.
