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

## The GPL question: answered, and the answer is no

Searched 2026-08-31. **Intelbras has no source release and no source-request
process.** Checked directly rather than assumed:

- `intelbras.com/pt-br/{gpl, codigo-fonte, open-source, software-livre}` all
  return **404**, with `/pt-br/ajuda-download` returning 200 as a control — real
  404s, not a bot block.
- The [IWE 3000N download page](https://www.intelbras.com/pt-br/ajuda-download/download/repetidor-de-sinal-wireless-iwe-3000n)
  lists three items: guide, manual, firmware. No source.
- The manual and quick-guide PDFs contain no GPL/GNU/"código fonte" text at all —
  many vendors put the written offer there; this one does not.
- [Intelbras forum t=36346](https://forum.intelbras.com.br/viewtopic.php?t=36346):
  staff replies in 2014, 2016 and 2018 say only that OpenWrt "não foi homologada".
- The [`intelbras` GitHub org](https://github.com/intelbras) has three
  hackathon repos, untouched since 2018.

A cold GPL demand to their support address is the only avenue, and it is
probably not worth the wait — see below.

## The vendor image, which does exist

`https://backend.intelbras.com/sites/default/files/2019-03/iwe3000n_0.8.6.zip`
(403s a bare curl; wants a browser User-Agent and Referer). Downloaded, verified
and committed to
[`../../iwe3000n-firmware/vendor/`](../../iwe3000n-firmware/vendor/).

## The build system is public even though the vendor's tree is not

`realtek_4181`, `linux-realtek_4181_rtl8196e` and `realtek_4181/generic` return
**zero hits** anywhere — Intelbras's target rename is private. But the tree it was
renamed *from* is not:

- [vido89/Open-Wrt-RTK](https://github.com/vido89/Open-Wrt-RTK)'s
  `target/linux/realtek/image/Makefile` defines
  `mkcmdline = board=$(1) console=$(2),$(3) linuxpart=0x$(4)`, and its rtl8196e
  profile is `SingleProfile,AP,ttyS0,38400,...,0x80500000,10000` — which
  **generates this device's kernel command line byte for byte**. Its `target.mk`
  says "RTL8196E (4181) based boards", which is where the `4181` naming comes
  from. `tools/rtk-tools/src/cvimg.c`, which writes the `cs6c` header found in
  the vendor image, is in the same tree.
- `RSDK-4.6.4 Build 424`, the exact compiler in `/proc/version`, appears in
  [cgoder/openwrt_rtk](https://github.com/cgoder/openwrt_rtk) and
  [Vyacheslav-S/openwrt-rtk819](https://github.com/Vyacheslav-S/openwrt-rtk819).
- Canonical upstream: [`rtk_openwrtSDK_v2.5.tar.gz`](https://sourceforge.net/projects/rtl819x/files/)
  (529 MB, 2016), including `defconfig_rtl8196e`.
- Full `rtl8192cd` C source is public — 119 files including `8192e_reg.h`, no
  object blobs. That is the driver this board's radio needs.

**Inference, clearly labelled as such:** Intelbras appears to have taken
`rtk_openwrt_src` essentially verbatim, renamed the target, and added a
`board=IWE3000N` profile line. If so, a GPL release would add almost nothing.

## Nobody has done an Intelbras device before

Zero results on GitHub, the OpenWrt wiki, the OpenWrt ToH and Brazilian forums.
[OpenWrt forum, January 2024](https://forum.openwrt.org/t/intelbras-routers/185016):
*"No Intelbras devices are currently supported."* This would be the first.

## The candidate trees, compared

Last activity and capabilities verified directly against each repo.

| tree | last commit | what it is | eth | 8192E wifi | 4 MB |
|---|---|---|---|---|---|
| [jnilo1/rtl8196e-gateway](https://github.com/jnilo1/rtl8196e-gateway) | **2026-08-22** | mainline Linux 6.18 port | **yes** | **no** (`CONFIG_WLAN` unset) | targets 16 MB; **4 MB fit unmeasured** |
| [lekswrt/rtl8196e](https://github.com/lekswrt/rtl8196e) | 2019-11-24 | OpenWrt 14.07 + RSDK, Linux 3.10.49 | yes (vendor) | **yes**, `rtl8192cd` incl. `8192e_reg.h` | yes; TFTP flashing documented |
| [DawsenGao/openwrt-rtl819x](https://github.com/DawsenGao/openwrt-rtl819x) | 2018-01-31 | same lineage, cleaner history | yes | yes | branches: BB, CC, AA |
| [vido89/Open-Wrt-RTK](https://github.com/vido89/Open-Wrt-RTK) | 2020-03-15 | 728 MB SDK dump with populated `build_dir` | yes | yes | — |
| [shibajee/linux-rtl8196e](https://github.com/shibajee/linux-rtl8196e) | 2020-03-27 | Linux 5.4 skeleton | no | no | **`rtl8196e_totolink_n100re.dts`: 32 MB RAM, 4 MB flash, boot 0x0/0x10000, kernel 0x10000, `console=ttyS0,38400n8`** |
| [frederic/rtl819x-toolchain](https://github.com/frederic/rtl819x-toolchain) | 2014-03-24 | SDK v3.2.3, Linux 2.6.30 | — | — | `0x400000` |

`shibajee`'s TOTOLINK N100RE device tree is worth calling out separately: same
flash size, same RAM size, same console rate and the same kernel offset as the
IWE 3000N. It is the closest published description of this board's layout.

Mainline OpenWrt remains a dead end — the official `realtek` target is
rtl838x/839x/930x/931x switch silicon, and the RTL8196E branch stalled in April
2021 with ethernet unfinished.

## In-workspace prior art## In-workspace prior art

Not third-party, and more directly useful than most of the above:

- [`../../../dir842/openwrt-dlink-dir842-r1/`](../../../dir842/openwrt-dlink-dir842-r1/)
  — a completed RealTek port (RTL8197F) in this workspace. Its `docs/BENCH.md`,
  `docs/RESTORE-STOCK.md` and RAM-boot-first posture are the template.
- [`../../../dir842/dir842-rtl8192cd-driver/`](../../../dir842/dir842-rtl8192cd-driver/)
  — the vendor Wi-Fi driver, already carved out, already ported once to 4.14.
