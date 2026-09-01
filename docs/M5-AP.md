# M5 — hostapd AP on the RTL8192EE

**Status: not complete. Three real driver bugs found and fixed; the radio still
emits nothing, and a monitor capture pins the cause on the board's RF front end
— antenna-switch/PA settings mainline has no profile for.** What works is
verified on hardware; what does not is characterised down to the register level
and confirmed off the air below. No guess here is presented as a result.

## Layer by layer, what was wrong and what is fixed

### 1. MAC init failed — BAR 2 was in the I/O aperture (FIXED)

The RTL8196E decodes two fixed apertures (its own `bspchip.h`):

```
BSP_PCIE0_D_IO   0xB8C00000  -> phys 0x18C00000   I/O transactions
BSP_PCIE0_D_MEM  0xB9000000  -> phys 0x19000000   memory transactions
```

The first DT declared a single window at `0x18c00000` as *memory*. That is the
I/O aperture, so BAR 2 (the only BAR `rtl8192ee` uses) was assigned there and
every register access went out as a PCIe I/O TLP. `_rtl92ee_init_mac()` — the
first bulk-MMIO step — timed out (`Init MAC failed`) while link training and
config space, which never touch BAR 2, looked healthy.

Fix: one memory range at `0x19000000`. Verified:
`pci 0000:01:00.0: BAR 2 [mem 0x19000000-0x19003fff 64bit]: assigned`, and MAC
init stopped failing. (No I/O range is declared — see the DT comment; an I/O
range trips a `vmap_page_range` BUG on this Lexra MIPS.)

### 2. The efuse read was byte-swapped — big-endian bug in rtlwifi (FIXED)

With MMIO working, the driver still rejected the chip's efuse:

```
rtlwifi: EEPROM ID(0x2981) is invalid!!
```

`0x2981` is `0x8129` (the RTL8192E magic) with its bytes swapped, and it is not
`0xffff`, so the efuse *is* programmed — it was being read wrong. The RTL8196E is
big-endian (`CONFIG_CPU_BIG_ENDIAN=y`); `rtl_get_hwinfo()` in `rtlwifi/efuse.c`
reads the little-endian efuse map with plain `*(u16 *)` casts, so every 16-bit
field comes out byte-swapped. The ID check failed and the driver fell back to
default MAC / TX-power / crystal calibration.

Fix: `patches/rtlwifi-efuse-big-endian-eeprom-id.patch` reads those fields with
`le16_to_cpup()` (a no-op on little-endian, so a correct general fix). Verified:

```
rtlwifi: Autoload OK
rtlwifi: EEPROMId = 0x8129
rtlwifi: Chip RF Type: RF_2T2R
```

The real MAC and the real TXAGC/crystal values now load from the efuse.

### 3. Power save (FIXED, but not the cause)

An AP with no associated client is "idle", and rtlwifi's power-save then reports
the radio off — `FillH2CCommand8192E(): Return because RF is off!!!` on a 2 s
loop. The DT bootargs now carry `rtl8192ee.ips=0 fwlps=0 swlps=0` (verified
`ips=N fwlps=N swlps=N`), which clears that state completely (the message count
drops from ~160 to 0). Correct for an rtlwifi AP — but it did **not** put RF on
the air: a second monitor capture with power-save fully off still saw zero
frames from our BSSID. So the "RF is off" software state was a red herring for
emission; power save is ruled out as the cause.

## Where it stands: armed to transmit, but silent

After all three fixes, `hostapd` reaches `AP-ENABLED` and **every transmit-path
register is enabled**, read live over BAR 2 with `devmem` while the AP ran:

| reg | value | meaning |
|-----|-------|---------|
| 0x100 CR | `0x16FF` | MACTXEN, MACRXEN, TXDMA/RXDMA, PROTOCOL, SCHEDULE, **ENSWBCN** all set |
| 0x1c RF_CTRL | byte `0x07` | RFEN, RFRSTB, RFSDMRSTB — RF enabled, out of reset |
| 0x800 RFMOD | `0x83040000` | CCK_EN and OFDM_EN set — BB TX path on |
| 0x522 TXPAUSE | `0x00` | no queue paused, beacon queue free to send |
| 0xe00.. TXAGC | `0x37373939`… | per-rate TX power ~0x30–0x3D of 0x3F — healthy, not zero |

IQK runs (`Path A/B Tx IQK Success`, `Path B Rx IQK Success`; `Path A Rx IQK
Fail` is common and non-fatal) and `hw init` returns 0.

**And yet nothing reaches the air at all.** A monitor-mode capture settles it.
The RT3070 on the build host, put in monitor mode on channel 6, captured 120
frames in 12 s: **113 from the co-channel Realtek AP 30 cm away** (`00:e0:4c:81:
86:86`) and **zero from our BSSID** `00:e0:4c:81:92:c2`. Monitor mode passes
raw frames including bad-FCS ones, so a malformed beacon would still show — the
silence is total. A phone sees nothing either. The PCIe interrupt count stays 0
(`/proc/interrupts`: `14 rtl_pci`), consistent with the radio emitting nothing.

## The remaining blocker: the antenna path is not driven

The monitor capture rules out the beacon-content / DMA theory outright — a
malformed frame would have been captured, and nothing was. The MAC, BB and
beacon logic are all armed (registers above), TX power is real, yet **no RF
energy leaves the radio.**

The RF core itself is not dead: Tx IQK succeeds, and IQK runs through the RF
chip's *internal* loopback. So the chip can generate a TX tone internally but it
never reaches the antenna. That points at the board's **RF front end** — the
antenna switch and any external PA/LNA, driven by board-specific GPIO/RFE
settings. Mainline `rtl8192ee` configures these from a small set of known board
profiles; it has none for the IWE 3000N (`board_type` reads `0x0` from the
efuse), so whatever antenna-switch GPIOs this board needs are never set and TX
is left routed into a dead internal path.

This is exactly the M3 stop-condition, reached at M5: the RF-front-end register
knowledge lives in the vendor `rtl8192cd` driver (which was written for this
board and this big-endian SoC), not in mainline. Recovering it means reading the
vendor driver's antenna-switch/RFE setup for this board and porting it — real
work that changes the project's cost.

## What a person could do next

- Port the vendor antenna-switch / RFE setup. Read how `rtl8192cd` (in the
  vendor SDK, and in `lekswrt/rtl8196e`) configures the antenna switch and any
  external PA GPIOs for this board, and reproduce it in the mainline
  `rtl8192ee` `_rtl92ee_phy_set_rf_on` / RFE path. This is the direct fix for the
  dead antenna path.
- Or take the `lekswrt/rtl8196e` fallback wholesale (working eth + 8192E at 4 MB,
  Linux 3.10): it runs the *vendor* `rtl8192cd` driver, which already knows this
  board's RF front end and reads H601 calibration, sidestepping both the
  efuse-endian bug and the antenna-path gap by not being mainline rtlwifi at all.

## What is done and reusable

- The PCIe host driver (`files/drivers/pci/controller/pci-rtl819x.c`), link
  training, enumeration, MAC init — all solid (M3/M4).
- `tools/build-hostapd.sh` — static hostapd 2.11 at `/sbin/hostapd`; reaches
  `AP-ENABLED`.
- `files/rootfs/etc/hostapd.conf` — 2.4 GHz WPA2-PSK, channel 6.
- The efuse patch and `ips=0` are correct and stay in the tree regardless of the
  RF outcome — any working radio on this board needs them.
