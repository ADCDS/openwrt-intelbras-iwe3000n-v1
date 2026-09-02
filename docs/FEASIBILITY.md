# Is OpenWrt on the IWE 3000N feasible?

> **How it turned out** (2026-09-01). Route B, jnilo1, won — and the paragraph
> below about the radio being a vendor driver was the one assumption that did
> not survive: the chip is an RTL8192EE, mainline `rtl8192ee` drives it, and
> what was missing was a PCIe *host* driver, not a Wi-Fi driver
> ([`WIFI-PLAN.md`](WIFI-PLAN.md)). "No vendor image to restore from" was also
> wrong by the end of the day. Kept as written; the README has the result.

Written 2026-08-31, from one console session on the live unit. No code has been
written and nothing has been built, so treat this as a scoping document that
should be revised the moment M0/M1 evidence exists.

## What changed on 2026-08-31

Three of this document's assumptions were tested and two of them broke:

- **A vendor image exists** and is committed
  (Intelbras 0.8.6 — see [`RECOVERY.md`](RECOVERY.md)). Mistakes
  are cheaper than this document assumed.
- **The bootloader stops on ESC** and initialises Ethernet before giving its
  prompt, so a TFTP recovery path is likely.
- **Route C is closed** — no Intelbras GPL source exists.

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

RTL8196E is a Lexra **RLX4181**. Lexra built MIPS-compatible cores that omitted
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

Consolation: the DIR-842 port in this workspace (its vendor-driver tree is
private) already has this driver family carved out, and got it compiling against kernel 4.14 (`g3-rtl8192cd-4.14-port.patch`). It is
a different SoC and a different radio, so the source will not drop in — but the
hard part, "how do you make this vendor tree build against a modern kernel", has
been done once already in this workspace.

## Three routes

Rewritten 2026-08-31 after the research pass — route C is now closed, and the
recommendation has changed.

**A. Current OpenWrt (24.x/25.x) on a new RTL8196E target.**
Still requires writing the target from scratch, still has to fit 3.94 MB, and
mainline's `realtek` target remains rtl838x/839x switch silicon, unrelated to
this. *Not a starting point.*

**B. An RTL8196E community tree.** Now the recommended route, and the choice is
between two:

- **[lekswrt/rtl8196e](https://github.com/lekswrt/rtl8196e)** — OpenWrt 14.07,
  Linux 3.10.49, the same vintage the device already runs. The **only tree with
  both working ethernet and the `rtl8192cd` 8192E driver at 4 MB**, and it
  documents TFTP flashing. Last commit 2019. This is the fastest path to a
  working device.
- **[jnilo1/rtl8196e-gateway](https://github.com/jnilo1/rtl8196e-gateway)** —
  mainline Linux 6.18, actively developed (last commit 2026-08-22), from-source
  Lexra toolchain, modern SPI-NOR and ethernet. But **WiFi is compiled out**
  (`CONFIG_WLAN` unset) and it targets 16 MB flash — **whether it fits 4 MB is
  unmeasured**, and that is the question that decides it. Getting WiFi would mean
  forward-porting `rtl8192cd` to 6.x, which is a substantial piece of work in its
  own right.

The honest framing: lekswrt gets you a working repeater on an unmaintained 2014
userland. jnilo1 gets you a modern kernel on a device with no radio. Neither is
both.

**C. ~~Rebuild the vendor's own tree.~~ Closed.**
Intelbras publishes no source and has no request process — checked directly, see
[`PRIOR-ART.md`](PRIOR-ART.md). It matters less than expected: their target name
appears nowhere public, but the SDK it was renamed from *is* public, and
vido89's `mkcmdline` generates this device's kernel command line byte for byte.
There is very likely nothing in the vendor tree that is not already available.

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
