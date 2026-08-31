# Is OpenWrt on the IWE 3000N feasible?

Written 2026-08-31, from one console session on the live unit. No code has been
written and nothing has been built, so treat this as a scoping document that
should be revised the moment M0/M1 evidence exists.

## The three constraints, in order of how much they hurt

### 1. 4 MB flash — this is the binding one

The image has to fit `linux`: **3.94 MB for kernel and rootfs together**, with
440 KB of overlay on the side.

Upstream OpenWrt has discouraged 4/32 devices since 18.06 and the guidance has
not softened; the standard device-page warning tells people outright not to buy
them for a current OpenWrt. This is not a rule that can be argued with — it
reflects that a modern kernel plus the usual userland does not fit. Anything
built here is a stripped, hand-tuned image, and every package decision is a
budget decision.

Mitigations that exist, none free:

- Drop LuCI entirely, ship uci + a serial/SSH-only device.
- `rootfs_data` on RAM (`tmpfs` overlay) — the "revive 4/32" pattern from the
  OpenWrt forum. Config does not survive a reboot unless explicitly saved.
- Stay on an older, smaller base — which is route B below.

### 2. The Lexra core

RTL8196E is a Lexra **RLX5281**. Lexra built MIPS-compatible cores that omitted
instructions covered by an SGI/MIPS patent on unaligned load/store, so a stock
`mips-linux` toolchain does not target them cleanly and needs patching.

The RTL8196E is on the good side of this split: it **does** implement
`lwl/lwr/swl/swr`, unlike the older RTL8186, which is why RTL8196E ports exist at
all. So this is a real cost but a survivable one — and the vendor already solved
it, with `Realtek RSDK-4.6.4` (gcc 4.6.4), which is sitting in
`/proc/version` on the device right now.

**What does not exist:** RTL819x in mainline Linux or mainline OpenWrt. OpenWrt's
`realtek` target is RTL838x/RTL839x switch silicon and is unrelated. Everything
usable is a community fork — see [`PRIOR-ART.md`](PRIOR-ART.md).

### 3. The radio is a vendor driver

`rtl8192cd.ko`, 1.36 MB of it, WEXT-era, driving an RTL8192ER. `mac80211.ko` is
present in `/lib/modules/` but unloaded — there is no nl80211 path to this radio.
Anything that runs here either carries that driver forward or has no Wi-Fi.

Consolation: [`../../../dir842/dir842-rtl8192cd-driver/`](../../../dir842/dir842-rtl8192cd-driver/)
already has this driver family carved out from the DIR-842 work, and the DIR-842
port got it compiling against kernel 4.14 (`g3-rtl8192cd-4.14-port.patch`). It is
a different SoC and a different radio, so the source will not drop in — but the
hard part, "how do you make this vendor tree build against a modern kernel", has
been done once already in this workspace.

## Three routes

**A. Current OpenWrt (24.x/25.x) on a new RTL8196E target.**
Requires writing the target from scratch — no mainline support, Lexra toolchain
work, and then the image has to fit in 3.94 MB. This is a large project with a
plausible outcome of "kernel boots, nothing else does", which is roughly where
the 2020-era community work stalled. *Not recommended as a starting point.*

**B. An old OpenWrt on a community RTL819x fork.**
Barrier Breaker / Chaos Calmer-era trees for rtl819x exist and are the same
generation as what stock already runs. Realistic chance of a booting, usable
image. The catch is that you end up maintaining a 2014-vintage userland with no
security updates — which is *what the device already has*, so it is not a
regression, but it is not much of a prize either.

**C. Rebuild the vendor's own tree.**
Stock is `realtek_4181/generic`, `DISTRIB_REVISION="b3e88c"`. If Intelbras
published GPL sources for it, this is by far the shortest path to a *modified*
firmware you control — the kernel, the ethernet driver, the Wi-Fi driver and the
flash map are all known-good on this exact board.

This route got materially more searchable after a `cfg80211` warning on the live
unit printed the vendor's build path: the tree is called **`zeus`**, the target
directory **`linux-realtek_4181_rtl8196e`**, the toolchain
**`target-mips-rlx4181-linux`**, and the wireless stack
**`compat-wireless-2014-05-22`**. Those are specific enough to search for
directly — see [`PRIOR-ART.md`](PRIOR-ART.md) §"The unsearched lead".

**Action: search for those strings and file a GPL request with Intelbras.** That
should happen before route A or B is costed, because it changes the answer.

## Is this worth it

Stated plainly, because the answer might be no:

- The device is a **2.4 GHz-only, single-100-Mbit-port repeater**. Even a perfect
  port yields a dumb AP that is slower than the DIR-842 already in the rack.
- There is **no vendor image to restore from**, so mistakes are expensive.
- The most defensible reasons to do it anyway: it is a **cheap, expendable Lexra
  target to learn on**; it is a **second data point for the `rtl8192cd` work**
  already underway; and unlike the DIR-842 it is small enough to understand
  completely.

If the goal is a working AP, stock already is one. If the goal is the port
itself, this is a reasonable and fairly self-contained thing to port — provided
M0 lands first, so that failure is recoverable.
