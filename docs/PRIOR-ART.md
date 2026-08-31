# Prior art — RTL8196E / RTL819x on OpenWrt

Collected 2026-08-31. **None of these has been evaluated hands-on yet** — this is
a reading list for milestone M2, not a recommendation.

## Community trees

| project | what it claims | why it matters here |
|---|---|---|
| [vido89/Open-Wrt-RTK](https://github.com/vido89/Open-Wrt-RTK) | rtl819xd, **rtl8196e**, rtl8881a; TOTOLINK N601RT as a supported device | Names our exact SoC and has a concrete supported device — the closest thing to a starting base |
| [lekswrt/rtl8196e](https://github.com/orgs/lekswrt/repositories?type=all) | OpenWrt for RTL8196E with working packages and USB | Second independent RTL8196E tree |
| [DawsenGao/openwrt-rtl819x](https://github.com/DawsenGao/openwrt-rtl819x) | Historical pre-merge OpenWrt (Barrier Breaker) for rtl819x | Same generation as our stock firmware — likely the least friction |
| [jnilo1/rtl8196e-gateway](https://github.com/jnilo1/rtl8196e-gateway) | Open-source Linux firmware for RTL8196E smart-home gateways (Lidl Silvercrest, Sengled G4) | A *working* RTL8196E Linux firmware on comparably tiny hardware — closest analogue to our flash budget |
| [frederic/rtl819x-toolchain](https://github.com/frederic/rtl819x-toolchain/blob/master/README) | toolchain for rtl819x | The Lexra toolchain problem, already solved by someone |

## Forum threads worth reading before starting

- [Working Realtek SoC RTL8196E 97D 97F in last master](https://forum.openwrt.org/t/working-realtek-soc-rtl8196e-97d-97f-in-last-master/70975)
  — the main development thread. RTL8196E/97D/97F ported to master around August
  2020, kernel 4.14 with work toward 5.4/5.10. Early status in that thread:
  *RTL8196E boots but without ethernet and USB support.* Check how far it got
  before assuming it is a base.
- [Any plans for Realtek SOC support?](https://forum.openwrt.org/t/any-plans-for-realtek-soc-support/15727)
  — where the Lexra instruction problem is laid out: the RLX4181/RLX5281 have the
  unaligned instructions and are the easier ones; RTL8186 does not.
- [U-Boot for Realtek MIPS SoC (RTL819x)](https://forum.openwrt.org/t/u-boot-for-realtek-mips-soc-rtl819x/145475)
  — relevant only if the stock loader turns out to have no usable recovery mode.
- [Revive 4MB Flash(/32MB Mem) Devices with RAM overlay root](https://forum.openwrt.org/t/revive-4mb-flash-32mb-mem-devices-with-ram-overlay-root/139802)
  — the mitigation for our binding constraint.

## The unsearched lead

**Intelbras GPL sources for the IWE 3000N.** Stock is a GPL'd OpenWrt derivative,
so a source release may exist. Nobody has looked yet. This is the single
highest-value thing to check next — see [`FEASIBILITY.md`](FEASIBILITY.md)
route C.

A kernel warning on the live unit printed the vendor's own build path, which
gives unusually specific things to search for:

```
/home/build/zeus/build_dir/target-mips-rlx4181-linux/
  linux-realtek_4181_rtl8196e/compat-wireless-2014-05-22/
```

Search terms, in rough order of how distinctive they are:

- `linux-realtek_4181_rtl8196e` — the target directory name
- `target-mips-rlx4181-linux` — the toolchain triple
- `compat-wireless-2014-05-22` — the backports snapshot; also tells you which
  upstream compat-wireless tarball to fetch if only a patch set is published
- `zeus` — the build tree name; weak on its own, useful as a confirmation
- `realtek_4181/generic` + `b3e88c` — from `/etc/openwrt_release`

Worth trying: Intelbras's own support/downloads pages, a GPL request to
Intelbras (they are a Brazilian company and the GPL obligation applies), and
GitHub code search for `linux-realtek_4181_rtl8196e`.

## In-workspace prior art

Not third-party, and more directly useful than most of the above:

- [`../../../dir842/openwrt-dlink-dir842-r1/`](../../../dir842/openwrt-dlink-dir842-r1/)
  — a completed RealTek port (RTL8197F) in this workspace. Its `docs/BENCH.md`,
  `docs/RESTORE-STOCK.md` and RAM-boot-first posture are the template.
- [`../../../dir842/dir842-rtl8192cd-driver/`](../../../dir842/dir842-rtl8192cd-driver/)
  — the vendor Wi-Fi driver, already carved out, already ported once to 4.14.
