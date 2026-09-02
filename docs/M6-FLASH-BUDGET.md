# M6 — everything still fits 4 MB

**Status: verified on hardware 2026-09-01.**

Read from the running board, not computed:

```
# cat /proc/mtd
dev:    size   erasesize  name
mtd0: 00010000 00010000 "boot"
mtd1: 001f0000 00010000 "kernel"
mtd2: 00190000 00010000 "rootfs"
mtd3: 00070000 00010000 "rootfs_data"

# df -h /userdata
/dev/mtdblock3   448.0K   196.0K   252.0K  44% /userdata
```

| partition | range | size | image | used |
|---|---|---|---|---|
| `boot` | `0x000000`–`0x010000` | 64 KiB | — | never written |
| `kernel` | `0x010000`–`0x200000` | 1984 KiB | 1816 KiB (v1.0) | **91 %** |
| `rootfs` | `0x200000`–`0x390000` | 1600 KiB | 1392 KiB (v1.0) | 87 % |
| `rootfs_data` | `0x390000`–`0x400000` | 448 KiB | — | 44 % in use |

`0x10000 + 0x1f0000 + 0x190000 + 0x70000 = 0x400000` — **exactly 4 MiB, no
slack and no overlap.**

**The overlay is 448 KiB against stock's 440 KiB**, so it is not smaller, which
was the goal's condition. It is *larger* by 8 KiB because the boundary was
placed at `0x390000` to keep `rootfs_data` aligned while giving the kernel room.

## What the budget was spent on

The kernel carries the whole wireless stack built in — cfg80211, mac80211,
rtlwifi, rtl8192ee — plus `rtl8192eefw.bin` and `regulatory.db` linked via
`CONFIG_EXTRA_FIRMWARE`, because a built-in driver probes before the rootfs
mounts and cannot load a blob from it. That took the image from 1408 KiB (M1) to
1784 KiB.

Paying for it: IPv6, `RTLWIFI_DEBUG`, `MAC80211_MESH` and the cfg80211/mac80211
debugfs entries are off. That is what brought a 1896 KiB image down to 1764, and
the firmware then added 20 KiB.

## The kernel partition is the tight one, and there is a hard ceiling

90 % is uncomfortable, and it cannot simply be enlarged: **the RealTek loader
refuses to write a kernel image somewhere between 1808 and 1896 KiB.** It
accepts the image over TFTP, prints `checksum Ok !` and the burn address, then
scans `no sys signature at 000NN000!` 48 times and gives up *without writing and
without an error*. 1764 KiB writes, and so does the 1808 KiB v1.0 kernel;
1896 KiB does not. The exact threshold was not bisected.

So the practical kernel ceiling on this board is the loader's, not the partition
table's, and it is roughly 100 KiB above where the current image sits. Anything
substantial added to the kernel from here needs something else removed.

The rootfs had 677 KiB free at M6; v1.0 spent most of it on `wpa_supplicant`
(client mode, ~430 KiB compressed), `udhcpd`, the button/LED scripts and the
SSH host key, then the mDNS responder -- 208 KiB remain. The kernel grew 8 KiB
(GPIO sysfs for the button, IP multicast for mDNS) to 1816 KiB, which the
loader still writes.
