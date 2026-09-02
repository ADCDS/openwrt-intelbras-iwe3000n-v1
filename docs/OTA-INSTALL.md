# Installing without opening the case (design note, not yet verified)

The v1.0 install path needs a serial console because the RealTek loader's TFTP
is the only writer we drive. This note records a **network** path — the stock
web updater — worked out by reverse-engineering the vendor firmware. **It has
not been exercised on hardware yet**; the pieces are here so it can be.

The idea is the same one the sibling DIR-842 port uses: stock's own firmware
updater accepts a vendor-shaped image over the LAN and flashes it with
`mtd write`, touching only the `linux` region — never `mtd0`. If our image is
wrapped in the container stock expects, stock installs it for us.

## The stock update mechanism

Stock is an OpenWrt fork and carries the whole sysupgrade stack:
`/sbin/sysupgrade`, `/sbin/mtd`, `/lib/upgrade/platform.sh`,
`/etc/sysupgrade.conf`, plus a uhttpd + Lua web UI whose firmware page is
`www/cgi-bin/modules/system/firmware/`. Stock also boots **dropbear and
telnetd** (`etc/rc.d/S50dropbear`, `S50telnet`), so a network root shell is a
second route if the admin password is known — then `mtd write combined.img
linux` needs no wrapping at all.

## The vendor image container (`iwe3000n_0.8.6.bin`, confirmed byte-exact)

| offset | size | field |
|---|---|---|
| `0x00` | 16 | **MD5 of everything from `0x10` to EOF**, unkeyed (no secret, unlike D-Link) |
| `0x10` | 4 | format tag `b3 00 aa 06` (constant) |
| `0x14` | 16 | **`cvimg` header** (`cs6c`), big-endian: load `0x80500000`, **burn `0x00010000`**, length |
| `0x24` | … | payload: OpenWrt lzma-loader + kernel, then the squashfs (`hsqs`) |
| EOF-4 | 4 | `deadc0de` |

The on-flash `mtd1` equals this file with the 20-byte prefix stripped and byte
0 = `cs6c`. So the updater **checks the MD5, strips the 20-byte prefix, and
writes the `cs6c` image to `mtd1` at `0x10000`.** There is no signing key to
forge.

## The wrapped image, and how it is built

`tools/mkota.py` builds it, and the v1.0 release ships the result as
**`iwe3000n-v1-v1.0-webflash.bin`**. What it does, checked against the exact
bytes read back from a running unit's flash:

```
mkota.py kernel.img rootfs.img -o webflash.bin --tag-from <vendor.bin>
```

The bytes the updater writes to flash (`0x10000` onward) must equal the layout
this port boots from, so the wrapper is not a repackage of the two loader
images -- it reproduces the flash:

- **flash `0x10000` = `kernel.img` verbatim.** The kernel keeps its `cs6c`
  header; the loader boots through it. So the wrapped payload begins with the
  whole `*-kernel.img`.
- **flash `0x200000` = raw squashfs (`hsqs`).** The rootfs `r6cr` header is
  *not* on flash -- the kernel mounts `/dev/mtdblock2` as squashfs, so `hsqs`
  must sit at `0x200000`. So the wrapper strips the 16-byte `r6cr` header (and
  the trailing 2-byte cvimg checksum) from `*-rootfs.img` and pads the kernel
  out to `0x1F0000` so the squashfs lands exactly at `0x200000`.

It is then wrapped in the vendor container: `[MD5(16)][tag b3 00 aa 06][kernel
+ pad + squashfs][deadc0de]`, `MD5 = md5(everything after the first 16 bytes)`.
The updater strips the 20-byte prefix and writes the rest verbatim.

Upload `webflash.bin` through the stock web UI's firmware page.

## Before trusting it

- **Prove the container first**: upload the *unmodified* vendor
  `iwe3000n_0.8.6.bin` back through the web UI and watch (serial, once) whether
  it calls `sysupgrade`/`mtd write`. That confirms the updater accepts the
  format before a wrapped port image is risked.
- **One unknown remains**: `firmware_model.lua` may enforce a model/version
  string, and the web UI is a custom Lua "Orbit" app, not LuCI. Its bytes could
  not be read offline: the stock squashfs data blocks use RealTek's
  Lexra-modified LZMA, which no mainline `xz`/`unsquashfs` decodes — two
  independent analysis passes recovered every file *name* (1039 inodes) but not
  the *contents*. Two ways to get the Lua: run `sasquatch` (the vendor-tolerant
  unsquashfs fork) against `iwe3000n-firmware/mtd2-rootfs.bin`, or read it from
  a live stock root shell. Settle this before trusting a wrapped image.
- **Keep the `cs6c` burn field `0x00010000` and the payload within `mtd1`.**
  The web/sysupgrade path writes only `linux`; that is the property that keeps
  `mtd0` safe. Reject any image whose burn field is not `0x00010000`.

Until this is done on hardware, [`INSTALL.md`](INSTALL.md) (serial + loader
TFTP) is the supported path.
