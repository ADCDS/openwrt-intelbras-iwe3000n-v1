# M5 — hostapd AP on the RTL8192EE

**Status: reached, 2026-09-01.** hostapd runs a WPA2 AP on the RTL8192EE; a
real client authenticates, associates, completes the 4-way handshake and
passes traffic (20/20 pings). The board state and what remains are in the two
sections at the very end.

This file is a lab notebook, in order, ~1000 lines. It keeps every "Update:"
including the ones later retracted, because the evidence that killed a theory
is what a future reader needs. If you want only the result, read this
summary and the last two sections.

**What was wrong, in the order it was found** (each has a section below):

1. **The PCIe interrupt never reached the CPU** — the SoC's interrupt
   controller routing register for the PCIe line was zero.
   `patches/irqchip-rtl819x-route-pcie.patch`.
2. **The efuse was read byte-swapped** on this big-endian CPU, so the chip's
   MAC, TX power and crystal calibration were discarded and the radio ran on
   defaults. `patches/rtlwifi-efuse-big-endian-eeprom-id.patch`.
3. **RX descriptors were handed to hardware before their buffer was in
   them** — a refill race in rtlwifi that looked like DMA corruption.
   `patches/rtlwifi-rx-refill-before-hw-release.patch`.
4. **The box froze on every AP start**: a level-triggered INTA storm through
   the ISR's `irq_enabled == 0` early return, ~130 kHz, starving softirqs
   (the "stopped timer softirq"). Found with an in-kernel probe.
   `patches/rtlwifi-zzfix-isr-quiesce-when-disabled.patch`.
5. **The box ran out of memory**: rtlwifi's default RX rings cost 16 MiB on a
   32 MiB host, surfacing as SIGBUS/SIGSEGV in userspace and an AP that
   intermittently did not hear its client. `patches/rtlwifi-rx-ring-64.patch`.
6. **A phone joining froze it again**: with a live client, quiescing the chip
   is not enough — the line has to be masked at the controller while the
   driver holds its interrupts off. `patches/rtlwifi-zzfix4-mask-irq-while-driver-disabled.patch`.

**Retracted along the way:** a `raise_softirq()` "fix" (console-print timing
made it look like it worked); a posted-MMIO-write theory for the 1.3–1.9 s
management-frame delays (A/B test killed it; the delays were real and stopped
reproducing once memory pressure was gone, mechanism never pinned); and, in
the earliest version of this file, the RF front end.

**Still open:** ~10 % of cold boots fault in rcS (I/D-cache coherence
suspected); the wlan MAC's last byte varies per boot; ~23 % loss at 1 pkt/s
(power-save shaped); no DHCP server; and the phone re-test of fix 6.

---

Everything below is the notebook, verified on hardware, in the order written.

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

## Board state (historical — superseded by "Board state (current)" below)

The board runs the tree as committed: baseline `pci-rtl819x.c` plus the RX
refill fix. It boots cleanly, `eth0` is up, and it is recoverable via the
loader's TFTP at the kernel burn address `0x00010000`. `mtd0` untouched.

The endpoint is currently wedged from the debugging session, so `wlan0` is absent
until the board is cold power-cycled.

## What to do next (historical — the softirq livelock below is what this pointed to)

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

## Update: the softirq livelock is a stopped TIMER_SOFTIRQ, not an RX/TX hang

The livelock above is real, reproduces on every hostapd AP start (right after
`wlan0: interface state UNINITIALIZED->COUNTRY_UPDATE`), regardless of whether
the PCIe link is healthy this boot or not, and regardless of every RX/TX fix in
this document. It is **not explained by anything in rtlwifi or mac80211's own
code** — this took several rounds of instrumentation to pin down, including one
false lead worth recording so it isn't retried.

**False lead: `NET_TX` frozen at 1.** An early instrumentation pass (per-CPU
`kstat_softirqs_cpu()` snapshots) showed every softirq vector's dispatch count
flat except `NET_TX_SOFTIRQ`, which read exactly 1 and never moved again. Since
the kernel increments a vector's kstat count *before* calling its handler, "1
and frozen" reads naturally as "`net_tx_action()` was entered once and never
returned." `rtl_pci_tx()` was checked and is non-blocking, so the search moved
into the qdisc/mac80211 xmit chain — a plausible-looking trail that turned out
to be wrong.

**What actually happens (found in three steps once the console-flooding trap
below was cleared):**

1. `local_softirq_pending()` shows bit `0x02` (`TIMER_SOFTIRQ`) permanently set
   from the moment the freeze starts.
2. `kernel/time/timer.c` already carries `timer_get_running_fn()`,
   `timer_collect_pending_fns()`, and `timer_wheel_stats()` — built by earlier
   work on this exact bug (see the `issue #99` comments at
   `kernel/time/timer.c:1346-1408` and `:1410-1451`) for the watchdog's panic
   notifier, whose integration was later stripped in the `rtl819x-wdt` v1.12
   "production rewrite" (`drivers/watchdog/DESIGN.md` /`AUDIT.md`: "reintroduce
   diagnostics only in a separate debug build, not this driver") — but the
   functions themselves stayed exported. Calling `timer_wheel_stats()` from an
   armed debug probe shows `running=NULL` (nothing hung mid-callback) while
   `overdue` (how far `jiffies` has outrun the wheel's `next_expiry`) climbs
   **unbounded** for as long as the freeze lasts: 43, 499, 1336, 2706, 5206,
   8277, 11329... jiffies at roughly the normal `HZ=250` rate, wheel not
   advancing at all. `timer_wheel_stats()`'s own doc comment names this exact
   shape "a wheel that never catches up to jiffies (death spiral)".
3. A one-line counter added to the top of `run_timer_softirq()` itself
   (`rtl819x_debug_run_timer_softirq_calls`, printed as `rtscalls`) settles it:
   the count is **frozen at the exact value it held when the freeze began** —
   530, in one full run; 532 in another — for the entire rest of the run (60+
   seconds observed), reproduced twice. `run_timer_softirq()` — `TIMER_SOFTIRQ`'s
   own handler — is **never invoked again**, even once, despite the softirq
   showing pending on every sample.

So this is not a hung timer callback (ruled out three separate ways: the
rtlwifi 2 s watchdog is non-blocking by inspection; mac80211's `sta_cleanup`
and `dynamic_ps_timer` are both no-ops or non-blocking with zero stations; the
generic netdev `dev_watchdog` is never armed at all, since `netdev_watchdog_up()`
returns immediately when `.ndo_tx_timeout` is `NULL`, which mac80211's
`ieee80211_dataif_ops` doesn't set). A companion patch printing every
`call_timer_fn()` invocation independently confirms this: several distinct
timers (`tcp_orphan_update`, `entropy_timer`, `blk_rq_timed_out_timer`, ...) fire
and return cleanly, right up to the same moment, then **none ever fire again**.

The bug is upstream of all of that: `handle_softirqs()` sees `TIMER_SOFTIRQ`
marked pending but stops actually dispatching it. Every PC sample taken by a
timer-ISR-based probe during the freeze — dozens of samples, two independent
runs — lands at the exact same instruction: `arch_local_irq_enable+0x14/0x24`,
called from `handle_softirqs+0x9c/0x2e8` (matching the watchdog's own panic
traces from the very first reproduction, before any of this session's
instrumentation existed, so this part of the signature is not an artifact of
the debug patches). `handle_softirqs()`'s own inline retry is bounded
(`MAX_SOFTIRQ_RESTART`, `time_before(jiffies, end)`) and hands off any
remaining work to `wakeup_softirqd()` — a real kernel thread, which needs the
scheduler to actually run it. This kernel is `CONFIG_PREEMPT_NONE=y`: nothing
forces a reschedule mid-kernel-context; a task only gets picked up at an
explicit `schedule()`/`cond_resched()` or a return-to-userspace boundary. The
leading hypothesis — **not yet proven** — is that `ksoftirqd` gets woken but
never actually scheduled, because whatever loop this CPU is in (hardirq exit →
softirq check → hardirq exit → ...) never reaches a point that yields, so
nothing else — not `ksoftirqd`, not hostapd, not a login shell — ever runs
again. This matches every other symptom already on record: the shell becomes
completely unresponsive for the duration (confirmed repeatedly — a `reboot`
typed into a live session during the freeze has no effect at all), yet the
platform timer hardirq keeps firing at a normal rate throughout (confirmed via
a probe *inside* that hardirq handler, which keeps printing on schedule).

**Debug-only patches added for this (all temporary, none meant to stay in the
tree once the mechanism above is confirmed and fixed):**
`DEBUG-intc-stats-proc.patch`, `DEBUG-timer-softirq-snapshot.patch`
(timer-ISR probe: PC sample + `timer_wheel_stats()`/`timer_get_running_fn()`,
gated behind writing `1` to `/proc/rtl819x_debug_arm` so it stays silent
outside a deliberately armed test window — an earlier, unconditionally-verbose
version of this same probe flooded the console badly enough over the board's
slow, character-at-a-time 38400 baud serial console that
`console_unlock()`/`vprintk_emit()` themselves briefly became indistinguishable
from the bug being hunted; keep any future revival of this probe terse),
`DEBUG-timer-callback-trace.patch` (prints every `call_timer_fn()` invocation),
`mac80211-zdebug-tasklet-counters.patch` / `mac80211-zdebug-rx-irqsafe-counter.patch`
(ruled out mac80211's own RX tasklet — never scheduled during the freeze,
so not the cause either).

## Update: the "softirq kick fix" was an instrumentation artifact (retracted)

A `raise_softirq(HRTIMER_SOFTIRQ)` called unconditionally from the timer ISR
was briefly believed to fix the wedge, on the strength of an A/B run where
removing it reproduced the freeze immediately and two clean 60s runs where it
was present. **That conclusion was wrong, and the reasoning behind it is worth
recording so the same trap isn't walked into again.**

The kick was originally written *inside* the debug snapshot function, behind
the same `/proc/rtl819x_debug_arm` gate as the instrumentation. So every run
that "proved" it worked also had the debug trace armed — and arming turns on
`DEBUG-timer-callback-trace`, which printks around **every** `call_timer_fn()`
invocation, system-wide. On this board's 38400-baud polled console each such
line costs ~13-16ms of blocking serial I/O (visible directly in the trace's own
timestamps: `604.323440` → `604.339920` across a single `tcp_orphan_update`
call). Arming therefore injects tens of milliseconds of delay into the softirq
path, once per timer callback. The kick and the delay were never separated.

Splitting them apart — the kick moved to its own function, made unconditional,
and later put behind its own runtime toggle `/proc/rtl819x_debug_kick` so both
variables can be set independently without a rebuild — gives:

| kick | debug prints | runs | result |
|------|--------------|------|--------|
| on   | on           | 3    | no wedge (57s, 57s, 140s) |
| on   | off          | 2    | **wedged** (~21s; 21-45s) |

The kick alone does not prevent the wedge. Whatever protection was observed
tracks the console delay, not the raised vector.

Two further cautions from these runs:

- **The wedge is timing-dependent, not deterministic.** Two runs in the same
  configuration (kick on, prints off) wedged at visibly different points —
  ~21s in one, somewhere between 21s and 45s in the other. Any conclusion on
  this bug drawn from a single run is noise; it needs repeated trials from
  identical cold boots.
- **Watch the harness, not just the board.** Two separate false results came
  from the test rig itself, not the kernel: a login-detection heuristic that
  rejected a perfectly good shell because getty's own audit line
  (`login[40]: root login on 'ttyS0'`) still contained the substring `login`
  in the tail window, and a multi-command toggle line that silently never
  landed — which quietly turned a "prints on, kick off" run into a
  "prints off, kick on" run without any error. Verify the knob actually took
  effect on the board before trusting what a run says. When armed, the trace
  flood also buries any verification echo within about a second, so read back
  quiet-console state *before* arming.

None of this changes the diagnosis in the section above (`TIMER_SOFTIRQ` goes
pending and `run_timer_softirq()` is never entered again); it only removes a
false fix. The root cause is still open.

## Update: what the softlockup reports actually say (register-level)

The console bridge keeps a 2 MiB ring; every freeze's full softlockup report
was in it all along — the tests had only ever looked at the last ~200 bytes,
which is loader banner. Five complete reports were recovered (`BUG: soft
lockup - CPU#0 stuck for 22s! [hostapd:45]`, also `[hostapd:42]`,
`[hostapd:43]`, `[hostapd:45]`, and one `[ip:39]` — so `ip link set wlan0 up`
can trigger it too, not only hostapd). Resolved against `System.map` and the
disassembly of `handle_softirqs()` (toolchain `objdump` from the builder
image), the saved registers are identical in all five and map cleanly onto the
source:

| register | value | meaning |
|---|---|---|
| `epc` | `arch_local_irq_enable+0x14` | inside the IRQ-enable hazard slot |
| `ra` | `handle_softirqs+0x9c` | the `local_irq_enable()` right after `restart:` |
| `$29` (sp) | `8080df68` | the IRQ stack → `irq_exit → do_softirq_own_stack` |
| `$17` (s1) | `806936a8` = `softirq_vec` | `h` just reset |
| `$18` (s2) | `0xa` | `max_restart` — still 10: **the restart loop was never taken** |
| `$19` (s3) | `0x2` (no kick) / `0x100` (kick on) | local `pending`: `TIMER_SOFTIRQ` / `HRTIMER_SOFTIRQ` |
| `Cause` | `0x8800` (4 of 5) / `0x0800` | **IP3 pending in every sample**; IP7 (timer) in four |
| `Status` | `0x10009c04` | IM7/IM4/IM3/IM2 enabled; `IEp` set (IRQs were on) |

So every 4 ms tick over a 22 s lockup found a **fresh** `handle_softirqs()`
frame that had just enabled interrupts and had not yet reached
`h->action()`. `pending` is whatever was raised last — the kick merely
changed which bit sat there — and none of it is ever dispatched. IP3 is the
INTC cascade line; per `drivers/irqchip/irq-rtl819x.c` it carries the switch
core (GIMR bit 15) **and, via IRR2, the PCIe/wifi source (GIMR bit 21)**.
`/proc/interrupts` shows both lines at 0 dispatches right up to the freeze,
and the INTC flight recorder reads `empty 0` at idle.

The `CONFIG_SOFTLOCKUP_DETECTOR_INTR_STORM` section of each report reads
`0% system, 100% softirq, 0% hardirq, 0% idle` for every 4 s window and prints
no IRQ table. With `sched_clock` at 25 MHz, irqtime accounting is active, so
that 0% hardirq is a real measurement: whatever burns the CPU is **not** time
spent inside `irq_enter()..irq_exit()`. It is charged to the interrupted
softirq context — i.e. to a frame that never executes an instruction.

Working hypothesis being measured (a timer-ISR probe that auto-triggers once
the timer wheel is >100 jiffies behind, so it is silent until the wedge and
cannot perturb it — see the earlier retraction for why that matters): a
level source on IP3 asserted while its GIMR bit is masked, the CPU re-taking
IP3 the instant IE goes high, each iteration too short or too early in the
exception path to be accounted, so the interrupted softirq frame never
advances. The probe prints INTC `entries`/`empty` deltas, raw `GIMR`/`GISR`,
`Cause`/`Status`, `pending` and the `run_timer_softirq()` call count every
1.6 s during the wedge.

## Update: root cause — the RTL8192EE's INTA storms at ~130 kHz on AP start

Measured directly, from a timer-ISR probe that stays silent until the wedge
(it first tripped on a false positive — timer-wheel lag from deferrable timers
during `NO_HZ_IDLE` — so it printed through hostapd start; the wedge happened
anyway, which is itself the strongest evidence yet that console output does
not "fix" anything). One line every 1.6 s during the wedge, all identical in
shape:

```
issue99: overdue=10967 pend=0x02 rtscalls=525 cause=00000800 status=10001c00
         GIMR=00209100 GISR=08200004 unmasked_pend=08000004
         intc_entries=5282153(+131304) empty=0(+0) c15=0 c21=5281968
         pc=arch_local_irq_enable+0x14 ra=handle_softirqs+0x9c
  sp[1]=realtek_soc_irq_handler+0x250  sp[5]=handle_percpu_irq+0x44
```

- **`c21` = 5.28 million and climbing by ~131,000 per second**: GIMR bit 21
  — the PCIe/wifi INTA — is being dispatched through the INTC chained
  handler at ~130 kHz. `empty=0`: every entry found bit 21 pending and
  handled it. GIMR bit 21 is enabled, GISR bit 21 is set on every sample.
- `cause=0x0800`: IP3 (the cascade line) asserted at every tick, as the five
  softlockup register dumps already showed. `c15=0`: not the switch.
- `rtscalls` frozen, `pend=0x02`, `overdue` growing at the jiffies rate:
  the interrupted `handle_softirqs()` frame never executes an instruction
  because IP3 is re-taken the moment IE goes high. That is the entire
  "softirq dispatch stops" symptom.
- Idle baseline for comparison: `entries 55 → 82` over 5 s, all UART, `empty 0`.

Each storm iteration is ~7.6 µs: INTC dispatch → `handle_level_irq` (mask,
ack, `_rtl_pci_interrupt()`, unmask) → return → the device still holds INTA
→ immediate re-entry. The ISR is running; it is returning without the device
dropping its line.

Why the box did not reset this time: the probe's own `pr_emerg` from the
timer hardirq goes through `serial8250_console_write()`, which calls
`touch_nmi_watchdog()` — every print pets the softlockup detector, so the
`softlockup: hung tasks` panic (which is what produced every earlier
"Watchdog Timeout" reboot ~25 s in; the loader labels a panic-reboot that
way) never fires, and the rtl819x hardware watchdog window is far longer.
The board sat wedged until power-cycled. Same mechanism explains the
softlockup reports' `100% softirq / 0% hardirq`: irqtime accounting is on
(25 MHz `sched_clock`), and the storm's per-iteration hardirq time is
being attributed in a way that still needs explaining — noted, not resolved.

Two branches of `_rtl_pci_interrupt()` (rtlwifi `pci.c`) can return with
INTA still asserted:

1. `if (rtlpci->irq_enabled == 0) return IRQ_HANDLED;` — and
   `rtl92ee_enable_interrupt()` writes `HIMR`/`HIMRE` *first* and sets
   `irq_enabled = true` *after*. If the device asserts INTA between those
   stores (this in-order core stalls on the posted MMIO write long enough for
   the level line to be latched), the ISR returns untouched-device, the line
   stays high, and the process context that would set the flag never runs
   again. A one-instruction window that a slow UP MIPS with a level-triggered
   cascade hits reliably; a fast SMP x86 never does.
2. `IMR_RDU` ("RX descriptor unavailable") with
   `rx_desc_buff_remained_cnt() == 0`: the ISR W1C-clears HISR and returns,
   but the hardware still has no descriptor, so RDU re-asserts instantly.

A per-branch counter patch (`rtlwifi-zdebug-isr-counters.patch`, read out by
the probe) is the next measurement; it names the branch and the HISR bits.

## Update: the storming branch, named — and the fix

Per-branch counters in `_rtl_pci_interrupt()` (`rtlwifi-zdebug-isr-counters.patch`),
read out by the probe during the wedge:

```
issue99: pci isr=6582638 ne=6582535 sp=0 rdu=0 rok=103 fovw=0 bcn=0 rr0=103
             inta=00000001 or=00000001 intb=00000000 en=105 dis=105
```

6,582,638 ISR entries; **6,582,535 of them took the `if (rtlpci->irq_enabled
== 0) return IRQ_HANDLED;` early return** — the ISR returning without touching
the chip. Only 103 were real (`rok=103`, all `ROK`, and every one of them found
nothing in the ring: `rr0=103` — a separate RX-path problem, noted below).
`en == dis == 105`: the driver's last interrupt-mask call before the storm was
`disable_interrupt()` (HIMR/HIMRE ← 0, `irq_enabled ← false`), issued from
process context by one of the reconfiguration paths around AP start. Not
`RDU` (`rdu=0`), not spurious (`sp=0`), not the enable-side ordering window.

So the mechanism is: the driver zeroes HIMR while the chip has `ROK` set in
HISR; on this board the chip keeps INTA asserted anyway; the intc's
`handle_level_irq` masks, acks its own GISR latch, calls the ISR, unmasks; the
ISR sees `irq_enabled == 0` and returns; the line is still high; the CPU
re-takes IP3 before the interrupted softirq executes an instruction. The
process context that would call `enable_interrupt()` — and clear HISR on its
next real interrupt — never runs again. A level-triggered interrupt
acknowledged at the controller but never quiesced at the source, on a
single-core box with nowhere else to run.

**Fix** (`rtlwifi-zzfix-isr-quiesce-when-disabled.patch`): in that early-return
path, read and write-1-clear HISR/HISRE (via the hal's `interrupt_recognized()`
plus a raw W1C of anything outside `irq_mask`), dispatching nothing, so the
line drops and the process context can finish and re-enable. Guarded by
`driver_is_goingto_unload` so teardown never touches a powered-down chip. The
raw offsets are the 8192ee's; the upstream shape would be a hal op.

**Validated on hardware** (fix kernel, kick off, probe armed-by-trigger only,
cold boot, `ip link set wlan0 up; hostapd -B /etc/hostapd.conf`): the shell
answered every 10 s for 190 s, no probe line ever printed (no softirq stayed
pending for 200 ms), no softlockup, no reset, and `rtl_pci` in
`/proc/interrupts` climbed 0 → 439 (t=19 s) → 2059 (57 s) → 4366 (114 s) →
8011 (190 s): a steady ~42 interrupts/s, all serviced. `hostapd_cli status`:
`state=ENABLED channel=6 bss[0]=wlan0 bssid[0]=00:e0:4c:81:92:b0
ssid[0]=IWE3000N-test`. Before the fix the same sequence wedged 14–45 s in
on every one of ~12 attempts across three days of runs. One 190 s run is not a
soak; it is the first time the AP has ever stayed up on this board, and the
rate is the shape of a working interrupt, not a storm.

**Still open, separately:** `rok=103, rr0=103` — every genuine `ROK` interrupt
found `rx_desc_buff_remained_cnt() == 0`. `rtl92ee_rx_desc_buff_remained_cnt()`
returns 0 until the hardware read pointer in `REG_RXQ_TXBD_IDX` has ever been
non-zero (`static bool start_rx`), and these all hit that. Frames are arriving
(the chip says so) but the host is not consuming them yet. This is the next
thing in the way of a client passing traffic, and it is where the earlier
"RX-DMA corruption" work sits.

## Update: on the air, but a client cannot join yet

With the fix kernel running and hostapd `ENABLED`, the build host's RT3070
(`wlx14cc20239af1`) sees the AP for the first time in this project's history:
`BSS 00:e0:4c:81:92:b0 freq 2437 signal -39 dBm SSID IWE3000N-test RSN`.
Every earlier monitor-mode capture saw zero frames from this BSSID.

Association fails. Host-side kernel log across four attempts:

- attempt 1: `send auth (try 1/3)` → `authenticated` → `associate (try 1/3,
  2/3, 3/3)` → `association timed out`. hostapd's `all_sta` afterwards shows
  the client with `flags=[AUTH] aid=0`: the AP received and answered the
  auth frame, then never processed an association request.
- attempts 2–4: `send auth (try 1/3, 2/3, 3/3)` → `authentication timed out`.
  No reply at all.
- Immediately after, the same RT3070 joined the house AP in 24 ms — the
  client is fine.

So the AP's management-frame path is intermittent: RX of auth/assoc frames
not reaching hostapd, or TX of the replies not leaving. The AP stayed alive
throughout (no wedge — the interrupt fix holds under real client traffic).
Which side is at fault is being read from hostapd's own `-dd` log on the AP.

## Update: the AP side of the association is verified end to end

Measured with the build host's RT3070 in monitor mode on channel 6:

- **Beacons**: 203 in 20 s, 1 Mb/s, 11b, −29 dBm, 100 ms apart, sequence
  numbers incrementing.
- **Unicast management TX**: `hostapd_cli deauthenticate <mac>` frames appear
  on the air at 1 Mb/s with correct DA/SA/BSSID, incrementing sequence
  numbers (65, 66, 67, …), Retry set only on retries, length 26; a healthy
  probe response to a third-party station was captured too. FCS clean on all
  267 frames from our BSSID.
- **Auth exchange, driven artificially**: injecting Authentication requests
  from a fake station (`02:aa:bb:cc:dd:ee`) via the monitor vif, the AP ACKed
  every copy the RT3070's hardware retried (the retries happened because the
  ACKs were addressed to the spoofed SA, not the RT3070's own MAC — an
  injection artifact), hostapd logged `authentication OK` + `authentication
  reply`, and a textbook reply hit the air ~20 ms after the request:
  `alg=0 transaction=2 status=0`, DA = requester, 1 Mb/s, len 30.
- hostapd's `-dd` log for the real client: 13 auth frames received (len 30,
  −18 dBm), a reply sent for each. No association request ever arrived.

Two artifacts worth knowing about: rtlwifi reports `IEEE80211_TX_STAT_ACK`
unconditionally (`pci.c`, `_rtl_pci_tx_isr`), so hostapd's `ack=1` in
`Frame TX status event` means nothing; and starting `hostapd -dd` without
redirecting its output puts it in the console foreground, where it eats every
subsequent command — a wasted hour.

So the AP receives, ACKs, answers correctly, and the answers are valid on the
air — yet the RT3070 in station mode times out three tries in a row (it got
one reply through, once, in the very first attempt). Next measurement: a
monitor vif on the *same* RT3070 radio during a real attempt, to see the
exchange from the client's own antenna, plus ftrace on the client's
`ieee80211_rx_mgmt_auth()`.

## Update: the association failure is TX latency — management frames leave ~1.3–1.9 s late

Measured on the air with the RT3070 (monitor vif), against hostapd's own log:

- Injected auth requests from a fake station: the AP received each one (ACKed
  it within µs), hostapd wrote the reply 2 ms later, rtlwifi reported TX-done
  1.7 ms after that — and the reply frame appeared on the air **1.6–1.9 s
  after the request** (retry bursts of 7 copies ~0.5 ms apart, as expected for
  an un-ACKing fake target).
- A real attempt, captured from the client's own radio: five rounds of three
  auth requests, each ACKed by the AP instantly; one reply seen, **1.3 s
  after** its request; the rest never inside the capture window. The client's
  window is 3 × ~100 ms, so from its point of view the AP never answers —
  `authentication timed out`, three tries in a row, every time.
- The MGNT ring register `REG_MGQ_TXBD_IDX` (0x3B0) reads rp == wp at every
  sample around a transmit — the chip fetches every frame immediately. The
  delay is between fetch and air, inside the chip.

Beacons are unaffected (203 in 20 s, 100 ms apart — the BCN queue). A delay
uniformly spread over ~2 s matches "held until the next rtlwifi 2-second
watchdog tick" (which sends H2C commands to the firmware). A per-queue TX
pause (`REG_TXPAUSE`, 0x522) or a firmware MACID/queue gating is the shape to
look for; being measured next.

## Update: the delay is a posted MMIO write that never gets pushed to the chip (being A/B-tested)

TSF-stamped TX inside the driver (post = frame handed to the ring, done =
TX-done processed, air = capture aligned to the AP's own beacons, alignment
spread 0.5–1 ms):

- With the stamping code doing an `rtl_read_dword()` right after each post:
  post→done 0.2 ms, post→air **0–2 ms** — for probe responses to strangers
  *and* for auth replies to the RT3070 (a known station). In that same run the
  client got `authenticated` for the first time since the storm fix and moved
  on to association.
- Without any read after the post (all earlier runs): auth replies 1.3–1.9 s
  late; a probe response or reply appears exactly when *something else*
  touches a device register.
- `devmem` reads of `REG_MGQ_TXBD_IDX` right after a `hostapd_cli deauthenticate`
  always showed rp == wp "immediately" — but the read itself was the flush.

So: MMIO writes to the RTL8192EE are posted in the RTL8196E's PCIe root
complex and sit there until a later PCIe transaction pushes them out. The TXBD
kick, `HIMR = 0`, the RX release at 0x3B4 — every control write — lands late
and at a random time bounded by the next register read (the 2 s DM watchdog is
the usual one). That is also a cleaner story for the original storm:
`disable_interrupt()`'s `HIMR = 0` had not reached the chip when the ISR took
its `irq_enabled == 0` exit, and the quiesce fix works because it *reads*
HISR (which flushes the pending write) before clearing.

Tested and **retracted**. Kernel A (stamps with no MMIO read at post time):
deauths to strangers and probe responses left the radio within −1.2…0.6 ms of
being posted (alignment slop ±1 ms) — no posted-write hold. Kernel B (A + a
read-back after every `pci_write*`): the client's auth frames stopped being
ACKed at all (mac80211 retried them every 20–40 ms, the no-ACK cadence), and
userspace fell apart faster (below). The read-back patch is dropped. What the
"read after post makes it fast" run actually showed is unresolved; the
injected-auth stimulus produced no replies on A, so the known-station case
is still unmeasured on a no-read kernel.

What did become unmistakable on B: **the board's memory is being corrupted
while the AP receives traffic.** With `rtl_pci` at ~27,000 interrupts,
`grep` and `tail` took SIGSEGV on writes to address 0, one `grep` trapped on a
reserved instruction at **EPC=0x00000000** (its return address had been
zeroed), `cat` took SIGBUS. hostapd stayed up. This is the "RX DMA corrupts
host memory" symptom recorded before the RX-refill fix; the fix narrowed it,
it did not end it. It is now the blocker for M5 — nothing above it can be
trusted until it is found. Next measurement: a kernel with
`CONFIG_DMA_API_DEBUG` (double-mapped or mis-synced ring slots are reported
with the driver call site) and `page_poison=1` (DMA into a freed page is
reported on that page's next allocation), driven through the same AP-start and
client-attempt sequence.

Also observed this round: once auth completes, hostapd receives the
association request (`association OK (aid 1)`, `Add associated STA`), but the
board's userspace is fragile while the AP runs — plain `grep`/`tail`/`cut`
died with `Segmentation fault` / `Bus error` on the console, the same
"RX DMA corrupts host memory" symptom the project saw before the refill fix.
hostapd itself stayed up. To be characterised after the A/B.

## Update: the "userspace corruption" is the box running out of memory

Caught red-handed on the debug kernel, in the middle of an AP session:

```
8192 pages RAM / 1529 pages reserved
Out of memory: Killed process 69 (sh) total-vm:928kB, anon-rss:28kB, file-rss:592kB
```

32 MiB total, ~26 MiB usable, ~7.5 MiB of it the uncompressed kernel image.
rtlwifi's RX ring is `RTL_PCI_MAX_RX_COUNT` = 512 descriptors, each backed by a
9100-byte skb that this kernel serves as a 16 KiB page-order allocation:
**8 MiB pinned for wifi RX**. Add hostapd, the page cache for a squashfs root,
and the 4 MiB order-2 fragmentation that 512 such allocations impose, and
memory pressure follows the moment the AP starts receiving. Every "corruption"
symptom on record is a memory-pressure symptom: `Bus error` is SIGBUS from a
squashfs-backed text page evicted and not re-readable, `Segmentation fault …
invalid write access to 00000000` is `malloc()` returning NULL, `cat: applet
not found` is busybox failing to map itself, and the reserved-instruction trap
at `EPC=0x00000000` is a process whose stack page went away under it. The
DMA-API debug run and page poisoning found nothing because there was nothing
of that kind to find. The RX-refill patch that "fixed the corruption" earlier
most likely helped by changing timing and allocation order, not by closing a
DMA race.

This also bears on the association failures: `dev_alloc_skb()` failing in the
RX path silently drops the frame, so under pressure the AP simply does not
hear some of the client's frames, and hostapd's own allocations start
failing too. Intermittency across boots is what memory pressure looks like.

Fix (`rtlwifi-rx-ring-64.patch`): RX ring 512 → 64 buffers, changing
`RTL_PCI_MAX_RX_COUNT` and `RX_DESC_NUM_92E` together (the latter programs
`REG_RX_RXBD_NUM`). rtlwifi builds two RX rings (`RTL_PCI_MAX_RX_QUEUE` = 2),
so the old configuration pinned 2 × 512 × 16 KiB = 16 MiB; the new one 2 MiB.

**Measured, same boot sequence, before → after:**

| | 512-entry rings | 64-entry rings |
|---|---|---|
| MemFree at boot | 3,668 kB | **12,816 kB** |
| Slab at boot | 19,436 kB (19,088 unreclaimable) | **4,732 kB** |
| MemFree with hostapd up | (box unusable) | 10,924 kB |
| after client + traffic | — | 10,828 kB, `dmesg` OOM/SIGSEGV/SIGBUS count **0** |

## M5 reached: a real client associates and passes traffic

On the 64-ring kernel (storm quiesce fix + RX refill fix + ring size), cold
boot, `hostapd -B /etc/hostapd.conf`, the build host's RT3070 as the client
(NetworkManager profile, WPA2-PSK, static `192.168.50.2/24`):

```
wlx14cc20239af1: authenticated
wlx14cc20239af1: RX AssocResp from 00:e0:4c:81:92:65 (capab=0x411 status=0 aid=1)
wlx14cc20239af1: associated
Connected to 00:e0:4c:81:92:65 (on wlx14cc20239af1)  SSID: IWE3000N-test
```

hostapd: `14:cc:20:23:9a:f1 flags=[AUTH][ASSOC][AUTHORIZED][SHORT_PREAMBLE][WMM][HT]`
— the 4-way handshake completed. Traffic: host→AP `ping -c 20 -i 0.2`
**19/20 received**; AP→host `ping -c 10` **10/10, 0% loss**. First
association ever on this board.

Second association (same boot) connected on the first try, then:
`ping -i 0.002 -c 500` (56 B) **494/500, 1.2% loss**; `ping -s 1400 -i 0.005
-c 300` **287/300, 4.3%**; `ping -c 60` at 1/s **46/60, 23%**. Bursts pass
well; the slow steady ping loses far more than the fast ones, which is the
shape of a power-save interaction (client dozing between pings, AP-side
buffering/wakeup) rather than of RF or memory trouble — a follow-up, not a
blocker. MemFree held at ~10.8 MiB throughout and `dmesg` stayed clean.

Retrospective, briefly: three distinct faults stacked. (1) A level INTA storm
through the ISR's `irq_enabled == 0` exit froze the box on every AP start
(fixed by quiescing the chip in that path). (2) Memory: the driver's default
16 MiB of RX rings on a 32 MiB host, which surfaced as SIGBUS/SIGSEGV/OOM and,
through failed skb allocations, as an AP that intermittently did not hear its
client. (3) Two false trails on the way — a `raise_softirq()` "fix" that was
console-print timing, and a posted-write theory that A/B testing killed. The
1.3–1.9 s auth-reply delays measured on the 512-ring kernels were real; their
mechanism was never pinned down and they do not reproduce on the 64-ring
kernel, so memory pressure in the TX path is the leading explanation, not a
proven one.

## Update: a phone joining wedged the AP again; and a build-recipe flaw that muddies earlier results

**The recurrence.** With the 64-ring kernel up for 13 min and the RT3070 test
done, a phone attempted to join and the board wedged. The timer-ISR probe
(the auto-triggered one) caught it live: softirqs stuck, and the ISR's
driver-disabled path — the storm fix — firing over and over, each time clearing
fresh `HISR` bits (`ROK|RDU|BCNDMAINT0|TBDOK|TBDER`, accumulated
`0x06110003`). That fix stops a *stale* level INTA; it cannot stop a *live*
one: with a real client's frames arriving, every frame re-asserts INTA, the
cascade re-delivers it, and the process context that had called
`disable_interrupt()` never runs again to re-enable. Same livelock, at the RX
rate. The bench RT3070 never provoked it; a phone's join did.

Where the driver disables interrupts from process context on this chip:
`rtl_pci_stop()`, `rtl_pci_disconnect()`, `rtl_ps_disable_nic()` — and, the
ones that run while an AP is serving clients, `rtl92ee_set_beacon_interval()`
and `rtl92ee_set_beacon_related_registers()` (from `bss_info_changed` when
hostapd updates the beacon for a joining client's ERP/HT capabilities). Each
brackets a few register writes with `disable_interrupt()` … `enable_interrupt()`;
a burst of the joining client's frames inside that bracket is the trigger.

Fix #4 (`rtlwifi-zzfix4-mask-irq-while-driver-disabled.patch`): when the ISR
fires while `irq_enabled` is false, `disable_irq_nosync()` its own line and
remember it; `enable_interrupt()` re-enables. A level INTA cannot storm through
a line masked at the controller. Balanced by the flag, not by pairing.

**The recipe flaw.** `build.sh` installs this port's patches into upstream's
`patches-6.18/` but never removed ones it had stopped installing, and upstream
applies that whole directory. Three experimental patches — the MACID
media-status report (`zzfix2`), the MMIO read-back (`zzfix3`), and the TX
latency stamps (`zzzdebug`) — stayed on disk and were built into every kernel
from the moment each was first tried until now. Concretely: the kernel that
passed the client test above contained ring-64 **plus zzfix2 and zzfix3**;
"kernel A" contained zzfix2; the DMA-debug kernel contained all three. The
committed recipe at `a8db83b` (no zzfix2/zzfix3) describes a configuration that
had never been built. `build.sh` now deletes its own patch families from that
directory before installing the current set. Consequences for the record:
zzfix3 was condemned on "kernel B" evidence that is now confounded (B was
also the first kernel to carry zzfix2... and memory pressure was unmeasured);
zzfix2 may have contributed to the association success. Both are re-testable
cleanly now, one at a time.

**Clean configuration validated** (ring-64 + quiesce + fix #4, nothing else,
fresh cold boot, MemFree 12.8 MiB at boot): the RT3070 authenticated (second
try), associated (`AssocResp status=0 aid=1`), completed WPA2
(`[AUTH][ASSOC][AUTHORIZED][WMM][HT]`) and pinged **20/20, 0% loss**; the
storm probe stayed silent; MemFree 10.6 MiB with the client up. Neither zzfix2
nor zzfix3 is needed; both stay out. (Two earlier "Not connected" results on
this kernel were hostapd not having started — the `-B -f logfile` form does
not produce a log on this build, and one start command never landed; test
harness, not kernel.)

**Boot flakiness, quantified from the console ring** (39 boots): 4 had a
userspace fault before "System ready", all of the same shape —
`do_page_fault(): sending SIGSEGV to mount for invalid read access` on rcS's
very first command, ~4.7 s after power-on, with 12 MiB free and no wifi
traffic yet. Memory pressure made this class of fault frequent; it is not its
cause. The Lexra cache code's `flush_data_cache_page()` writes back and
invalidates the D-cache only — nothing invalidates the I-cache when a page
cache page is remapped executable, and `lexra_cache_init()` sets neither cache
geometry nor alias flags, so the generic alias handling is off for an 8 KiB
D-cache over 4 KiB pages. Instruction/data cache coherence on page reuse is the
leading suspect; a power cycle clears it. Separate work item.


## Update: station mode -- the board joins a WPA2 network

Client mode shipped in v1.0 with `wpa_supplicant`, but the radio never
associated: `wpa_supplicant` logged the auth request as sent, then
`SME: Authentication timeout`. Instrumenting `rtl_op_tx` / `rtl_pci_tx` /
`rtl92ee_set_desc` and capturing the air on the target channel with a second
radio found two independent faults, both invisible because `rtl_dbg()` is
compiled out in this build:

1. **Inactive power-save (IPS)**, on by default in `rtl8192ee`, turns the RF
   off whenever a station is unlinked and not scanning. `rtl_op_tx` then drops
   every management frame (`rfpwr_state != ERFON`). On air: nothing from the
   board, not even probe requests. AP mode never engages IPS, which is why the
   AP work never saw it. Fix: `.inactiveps = false`.

2. With IPS off the station authenticated and associated once -- and then the
   management queue was dead for the rest of the boot. The `REG_MGQ_TXBD_IDX`
   snapshot at every kick showed the hardware **read pointer frozen at the
   write pointer's value of one instant** (`reg=017101d4..d6`, no `MGNTDOK`)
   while later auth frames kept being kicked into the ring (queue depth 131).
   The freeze coincides with `_rtl92ee_download_rsvd_page()`, run once at
   association, which "resets the TX BD pointer" by writing BIT(4) of
   `REG_MGQ_TXBD_NUM + 3` -- a byte that is really the high half of
   `REG_RX_RXBD_NUM`. Skipping that write keeps rp tracking wp through the
   join (`reg=00520052` afterwards) and the 4-way handshake completes.

Result on the bench against a real WPA2 network (BRAVO, channel 11, -18 dBm):
`wpa_state=COMPLETED`, `pairwise_cipher=CCMP`, EAPOL 1/4..4/4 on air in the
correct alternation, DHCP lease from the network's router
(`192.168.100.221`). Both fixes are `patches/rtlwifi-zzzsta-station-mode.patch`.

One more rootfs fix fell out of the traffic test: `udhcpc` obtained the lease
but configured nothing, because the upstream rootfs ships no
`/usr/share/udhcpc/default.script` (there is no `/usr/share` at all). Client
mode now runs `udhcpc -s /etc/udhcpc.script`, which applies the address,
default route and DNS; with that, ping to the network's gateway and to the
internet both pass.

Left open: the reserved-page download is never confirmed by the firmware
(`bcnvalid` stays 0; reported once with `pr_warn_once`) -- the link works
without it. The `/userdata` jffs2 overlay does not reliably mount, so client
configs persist only when it does; `/tmp/wpa_supplicant.conf` is the
dependable per-boot override. The MAC's last byte still changes per boot,
which cost one capture (the filter was on the previous boot's MAC).

## Board state (current)

Kernel: storm quiesce (`zzfix`), IRQ-line mask while driver-disabled (`zzfix4`),
RX refill fix, RX ring 64, plus the issue #99 debug instrumentation (all
default-silent). `build.sh` now removes its own stale patches from upstream's
`patches-6.18/` before installing, so a fresh clone builds what the recipe
says. hostapd `ENABLED`; a real client associates, authorizes and passes
traffic; MemFree ~10.6 MiB with a client up. Kernel at `0x00010000`, rootfs and
`mtd0` untouched, loader TFTP recovery as before. No DHCP server on the board
(busybox has `udhcpc` only) — clients need a static address in
`192.168.50.0/24`, AP is `.1`.

## What to do next

- A second client (a phone) joining is what exposed fix #4's bug; repeat that
  on this kernel, with hostapd logging (`hostapd -dd -t conf >/tmp/h.log 2>&1 &`
  — the `-f` form is inert here).
- Boot flakiness (~10% of cold boots fault in rcS): test the I-cache
  invalidation on exec-page remap and the D-cache alias flags in `c-lexra.c`,
  measured as boot-fault rate over many boots.
- Add a DHCP server to the rootfs (busybox `udhcpd`) so ordinary clients get an
  address.
- Soak; the wifi MAC's random last byte (efuse read); 23% loss at 1 pkt/s
  (power-save shaped); then strip the issue #99 instrumentation and shape the
  quiesce/mask fix as a hal op for upstream.
