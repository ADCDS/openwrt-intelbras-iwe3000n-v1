# M5 — hostapd AP on the RTL8192EE

**Status: not complete. The interrupt-delivery root cause is now fixed and
verified (the PCIe IRQ was never reaching the CPU); enabling it exposes the next
layer — the RX DMA corrupts host memory, so the board is unstable once the radio
datapath runs.** An earlier version of this file blamed the RF front end /
antenna path — that was wrong. Everything below is verified on hardware.

## Update: PCIe interrupt delivery fixed (verified), and what it exposed

The interrupt was never delivered because of two intc/DT faults, both now fixed:

- **Wrong hwirq.** The DT mapped the RTL8192EE's INTA to `&intc 14` — the
  *vendor's flat Linux-irq number* (bspchip.h `BSP_PCIE_IRQ`). The mainline
  `realtek,rtl819x-intc` uses the **GIMR bit** as its hwirq, and PCIe is
  `BSP_PCIE_IE = (1 << 21)`. Ethernet proves the scheme: `interrupts = <15>` =
  bit 15 = switch core. Fixed: `&intc 21`.
- **No routing.** jnilo1's intc ships `IRR2 = 0` ("no PCIe"), so the PCIe source
  (GIMR bit 21, IRR2 field [23:20]) was routed to no CPU IP line. Fixed by
  `patches/irqchip-rtl819x-route-pcie.patch`: route it to IP3 (the line ethernet
  uses; the intc is chained to IP2/3/4). The GIMR enable is set dynamically by
  the generic unmask when the wifi driver requests the IRQ, so the routing is
  inert on boards with no PCIe.

Verified on hardware: `/proc/interrupts` now shows `21 rtl_pci` (was `14`, and
never counted); the count climbs 0 → 10 the moment `wlan0` comes up, and reaches
the hundreds at boot. The endpoint's INTA is finally serviced.

**What it exposes.** With the datapath live, the board becomes unstable: busybox
takes `SIGSEGV` (`do_page_fault ... invalid read access from 00031880`, a
userspace address) and bringing up the radio can hang the console entirely
(watchdog then resets it). The interrupt rate is moderate (~hundreds over a boot,
not a storm), so this is not the intc handler failing to quiesce — it is the
**RX DMA writing into the wrong host memory.** The chip masters RX packets into
host DRAM via the ring descriptors; a wrong target address there scribbles over
whatever else lives at that physical page. This has the same shape as the efuse
bug — a mainline rtlwifi path that has never run on a big-endian host — and is
the next thing to find. It is a driver/DMA defect, still host-side and
mainline-fixable, not RF.

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

## The RX-DMA corruption (M5's current blocker), and what it is NOT

With the interrupt delivered, the radio datapath runs and **corrupts random host
memory**: unrelated processes (`mount`, `stty`, `getty`, the shell) take SIGSEGV
at random addresses, and `hostapd` soft-locks the CPU. rtlwifi itself logs no
error — the driver believes everything is fine while memory is scribbled. That is
the signature of the chip DMAing into the wrong host pages, or a wild kernel
pointer in the RX path.

Ruled out, by inspection and by test on hardware:

- **Descriptor endianness** — the TX/RX descriptor setters use `cpu_to_le32` /
  `le32p_replace_bits`; the high address dword is cleared for the 32-bit case.
- **RX length overflow** — `len` is bounds-checked (`skb->end - skb->tail > len`)
  before `skb_put`, and a bad length frees the skb.
- **RX ring pointer math** — read/write pointers come from `rtl_read_dword`
  (endian-correct MMIO), with a normal fifo-space calc.
- **Cache coherency** — `CONFIG_DMA_NONCOHERENT=y`, `dma_default_coherent` is
  false, so the PCIe device is non-coherent and cache-managed, exactly like the
  (working) on-SoC ethernet. Descriptor rings are `dma_alloc_coherent`.
- **Inbound address translation / offset** — the vendor RC bring-up sets no
  inbound window and masks addresses to `0x1FFFFFFF` (identity over the 512 MB
  physical space); mainline with no `dma-ranges` is the same 1:1.
- **DMA mask** — vendor `RTL819x_DMA_MASK = 0xffffffff`; mainline sets 32-bit.
  Full DRAM, no restriction.
- **Max Payload Size** — already 128B on both RC and endpoint (confirmed with
  `pci=pcie_bus_safe`, which changed nothing).
- **Upper-16 MB addressing** — the theory that the RC only forwards the low half
  is disproved by the fact that **the vendor firmware runs Wi-Fi on this exact
  32 MB board.** The hardware can DMA the full 32 MB.

What that leaves: a **software difference between mainline `rtl8192ee`'s DMA/RX
path and the vendor `rtl8192cd`.** The vendor driver, written for this SoC and
this big-endian CPU, works here; mainline — which has almost certainly never run
big-endian — does not. Finding it needs a runtime memory-poison/bisection or a
line-by-line DMA comparison against the vendor driver. This is real, open-ended
work: the same "changes the project's cost" boundary, now at the DMA layer.

## Update: the corruption is a softirq livelock in the interrupt-driven path

Further debugging (interrupt live, ISR instrumented) pinned the *shape* of the
bug even though not the exact line:

- The **ring setup is correct** — read on hardware: the `dma_alloc_coherent` RX
  ring is uncached (`virt=0xa0a68000`, KSEG1), and the RX buffer DMA addresses
  are sane and 1:1 (`tail=0x81a6c020 -> dma=0x1a6c020`), spanning both memory
  halves.
- On the **stable (interrupt-inert) kernel the chip still DMAs and there is zero
  corruption** — so the chip's DMA to the right buffers is fine. Corruption
  appears **only when the ISR runs**. It is a driver-software bug in the
  interrupt-driven path, not the DMA engine.
- The hang is a **soft lockup at 100% softirq** (`handle_softirqs`, hostapd
  context) — a wifi tasklet/softirq livelocks, and while spinning it scribbles
  random memory (unrelated processes SIGSEGV at random addresses). RX-only
  (`ip link set wlan0 up`) can be stable; the **beacon/AP path (hostapd)** is
  what livelocks.
- It is **timing/layout dependent**: reserving 192 KiB at the top of DRAM
  (for ramoops) made the RX path stable in one build while the beacon path still
  livelocked. That points at a reentrancy/ordering issue or a DMA over-write
  near a specific region, not a fixed wrong address.

Ruled out on hardware, in addition to the earlier list: descriptor endianness,
RX length bounds, RX ring pointer math, coherency (non-coherent + cache-managed),
inbound translation, DMA mask, MPS, and buffer sizing (whole-page RX buffers, so
no cache-line straddle with other allocations).

Capturing the exact faulting handler defeated the usual tools: the 38400 console
starves during the livelock so `pr_info` never flushes, and the RealTek loader
clears DRAM on reset so ramoops does not survive. Pinning it needs JTAG, or
upstream rtlwifi big-endian expertise, or a differential trace against the vendor
`rtl8192cd` -- the same "changes the project's cost" boundary, now at the last
layer. The efuse and interrupt fixes stand regardless.

## Board state (historical — superseded by "Board state (current)" below)

The RX corruption makes the board unstable once the radio runs, so the board is
currently flashed with a **wifi-inert kernel** (the DT interrupt-map left at the
old `&intc 14`, so the PCIe IRQ never fires and the datapath never starts). It
boots cleanly, ethernet works, no corruption. The repo keeps the real fix
(`&intc 21` + the intc patch); rebuild from the tree to get the interrupt-live
kernel back for continued DMA debugging.

## What to do next (historical — done; superseded by the section at the end)

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

## Update: the corruption had a concrete root cause — an RX refill race (FIXED)

The "softirq livelock scribbles memory" framing above was the *symptom*, not the
cause, and the section before this one should be read with that in mind. The
actual bug is a plain ordering error in `_rtl_pci_rx_interrupt()`, and it is now
fixed by `patches/rtlwifi-rx-refill-before-hw-release.patch`.

In the `use_new_trx_flow` RX path, upstream advances the hardware read pointer
(`rtl_write_word(rtlpriv, 0x3B4, next_rx_rp)`, in `new_trx_end`) **before** it
refills the just-freed buffer descriptor with a fresh skb
(`_rtl_pci_init_one_rxdesc()`, under `no_new`). Between those two points the
descriptor still holds the DMA address of the skb that was *already handed up to
mac80211*, but the hardware has been told the slot is free — so it can DMA an
incoming frame straight into that in-flight skb.

On a fast little-endian host that window is a few instructions and effectively
never loses. On this 400 MHz big-endian RTL8196E under sustained AP-mode RX it
loses constantly, silently scribbling whatever the skb's memory is reused for.
That is exactly the observed signature: random SIGSEGVs in *unrelated* processes,
at random addresses, with no driver-level error — and no corruption at all on a
kernel where the ISR never runs.

The fix moves the `0x3B4` write to after the refill, so the slot is released to
the hardware only once it points at a fresh buffer.

**How it was measured.** Before the fix, hostapd reliably produced SIGSEGVs in
unrelated processes within 4–35 s of the radio coming up. After the fix, a
40-second sustained hostapd run completed with **0 SIGSEGVs and 0 soft lockups**
(liveness counter reached `ALIVE_289`) — an outcome never once observed before
the fix. Note the earlier segfault timings in this document were partly read off
*replayed* uart-ota ring-buffer history rather than live output; the bridge
replays its buffer on connect, which cost real debugging time. Check timestamps
against the current boot before trusting them.

One nit, deliberate: on the rare `goto no_new` path (an `skb` allocation
failure) `next_rx_rp` has not been advanced, so the relocated write stores the
value already in the register. That write is inert, and leaving it unguarded
keeps the patch minimal.

## Update: the PCIe link is intermittent, and a wedged endpoint needs cold power

Separately from the RX bug, the PCIe link does not always train. When it fails it
sits at `LTSSM = 0x04` (Polling) and never reaches L0 (`0x11`), so the RTL8192EE
is never enumerated and `wlan0` is absent. When it does train, everything above
works.

The important, hard-won result: **once the endpoint is in this state, no
SoC-side register sequence recovers it — only physically removing power.**
Measured on hardware, all failing identically at `LTSSM = 0x04` across repeated
warm reboots:

- a real PERST pulse (clear bit 26, hold, set) rather than the plain set, so the
  endpoint actually sees a reset edge;
- retrying the whole power-on + train sequence up to 4×;
- gating the entire PCIe block down first — `ACTIVE_PCIE0` + the 8196E clock bits
  + `PERST` all cleared together, held, then brought back up, so the endpoint's
  reference clock genuinely stops (the closest a warm boot gets to a cold POR);
- the **unmodified baseline driver**, which historically *does* train on some
  cold boots, failing identically on the same wedged endpoint.

That last one is the control that matters: the baseline failing the same way
proves the wedge is endpoint state, not a regression in the bring-up code. So
none of the three mitigations above were merged — none of them was ever observed
to train the link, because they could only be tested against an already-wedged
endpoint. They are recorded here rather than shipped. UNVERIFIED whether any of
them improves cold-boot training; that needs a board on cold power to test.

Practical consequence: **if `wlan0` is missing, power-cycle the board** (remove
power, don't `reboot`). A warm reboot cannot clear it.

## Board state (current)

The board runs the tree as committed: baseline `pci-rtl819x.c` plus the RX
refill fix. It boots cleanly, `eth0` is up, and it is recoverable via the
loader's TFTP at the kernel burn address `0x00010000`. `mtd0` untouched.

The endpoint is currently wedged from the debugging session, so `wlan0` is absent
until the board is cold power-cycled.

## What to do next

- **Cold power-cycle the board**, then confirm `LTSSM 0x11` / `wlan0` present.
- Re-run hostapd and confirm the corruption stays gone over a long run, then
  finish M5 properly: a **real client associating and passing traffic**. That is
  the one M5 criterion still unmet — it has never been demonstrated.
- A **softirq livelock** under sustained RX was seen separately from the
  corruption (100% softirq in `handle_softirqs`). It is not explained by the
  refill race and may still be present; mac80211's RX tasklet has no budget,
  which is a known hazard on a CPU this slow. Re-test after the fix before
  chasing it.
- If the link proves flaky from cold too, the three mitigations above are the
  place to start — but measure each against a *cold* boot, not a warm one.
