# M5 — hostapd AP on the RTL8192EE

**Status: not complete, but the root cause is now proven and it is in our own
code, not the RF hardware. Three driver bugs are fixed; the radio emits nothing
because the RTL8192EE's PCIe interrupt is never delivered to the CPU, so the
interrupt-driven beacon path never runs.** An earlier version of this file blamed
the RF front end / antenna path — that was wrong, and the section below shows the
config-space read that disproves it. Everything is verified on hardware.

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

## The real blocker: the PCIe interrupt is never delivered

The monitor capture ruled out a *malformed* beacon (nothing was transmitted at
all). The next question — is a valid beacon even being handed to the hardware? —
has a clean answer, and it is not the antenna.

The rtl8192ee beacon is **interrupt-driven**. mac80211's beacon is fetched and
DMA'd to the chip by `_rtl_pci_prepare_bcn_tasklet` (in `rtlwifi/pci.c`), and
that tasklet is scheduled from exactly one place: the PCIe interrupt handler, on
the beacon-DMA interrupt (`pci.c` `tasklet_schedule(...irq_prepare_bcn_tasklet)`
under `RTL_IMR_BCNINT`). No other code path schedules it. So no interrupt means
no beacon, ever.

And the interrupt never arrives. Read straight from config space, stable across
repeated samples with the AP running:

```
EP  0000:01:00.0 status (0x06) = 0x0018   bit 3 (Interrupt Status) = 1  -> INTx asserted
EP  0000:01:00.0 command(0x04) = 0x0007   bit 10 (INTx disable) = 0     -> INTx enabled
EP  interrupt pin (0x3d)       = 0x01     INTA; no MSI capability in use
RC  0000:00:00.0 status (0x06) = 0x0010   bit 3 = 0                     -> not propagated up
/proc/interrupts  "14 rtl_pci"  = 0                                     -> CPU never sees it
```

The endpoint is **asserting its legacy INTA continuously**, and the root complex
is **not forwarding it** to SoC interrupt line 14 (which `bspchip.h` confirms is
the PCIe IRQ). The line number in the devicetree is right; the RC simply never
raises it. This also explains everything else that looked dead: RX, TX-done, C2H
— the entire datapath past the polled `hw_init` is interrupt-driven, and none of
it runs.

This is **not** an RF or antenna problem and needs no vendor register knowledge.
It is a host-side defect in the PCIe host controller written for this port
(`files/drivers/pci/controller/pci-rtl819x.c`): the RTL819x root complex needs
its INTx forwarding enabled (or a small irqchip/demux built) so an endpoint INTA
becomes an assertion on INTC line 14. That is mainline work, in our own code.

## What to do next

- **Fix the interrupt forwarding in `pci-rtl819x.c`.** The endpoint already
  asserts INTA; the RC just has to deliver it. Find the RTL819x RC interrupt
  enable/mask register (vendor `rtl8196e` PCIe bring-up, or the datasheet) and
  set it during probe, or register the RC as an irqchip that demuxes its
  interrupt-status register onto the endpoint's virq. Then confirm
  `/proc/interrupts` "14 rtl_pci" starts counting, and the beacon should follow.
- This makes the mainline path viable again: the remaining blocker is a bounded
  bug in code we own, not the open-ended RF/endian work the antenna theory
  implied.

## What is done and reusable

- The PCIe host driver (`files/drivers/pci/controller/pci-rtl819x.c`), link
  training, enumeration, MAC init — all solid (M3/M4).
- `tools/build-hostapd.sh` — static hostapd 2.11 at `/sbin/hostapd`; reaches
  `AP-ENABLED`.
- `files/rootfs/etc/hostapd.conf` — 2.4 GHz WPA2-PSK, channel 6.
- The efuse patch and `ips=0` are correct and stay in the tree regardless of the
  RF outcome — any working radio on this board needs them.
