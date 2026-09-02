#!/usr/bin/env python3
"""mkota.py -- wrap the two v1.0 loader images into one image the stock
Intelbras web updater accepts, so the port can be installed over the network
with no serial console. See docs/OTA-INSTALL.md.

The stock updater strips a 20-byte prefix (16-byte MD5 + 4-byte tag) and writes
the rest VERBATIM to the flash 'linux' region starting at 0x10000. So the bytes
after the prefix must equal the flash layout this port boots from, which was
read back from a running unit:

  flash 0x10000  = kernel.img verbatim   (starts with the cs6c cvimg header --
                   the loader keeps the kernel header and boots through it)
  flash 0x200000 = raw squashfs (hsqs)   (the loader strips the rootfs r6cr
                   header; the kernel mounts /dev/mtdblock2 as squashfs, so the
                   squashfs magic must sit at 0x200000)

Container (matches vendor iwe3000n_0.8.6.bin, verified byte-exact):

  [ MD5(16) ][ tag(4)=b3 00 aa 06 ][ cs6c image = kernel.img ][ FF pad ]
  [ raw squashfs ][ deadc0de(4) ]
  MD5 = md5(everything after the first 16 bytes)

Usage:
  mkota.py KERNEL.img ROOTFS.img -o OUT.bin [--tag-from VENDOR.bin]
"""
import argparse, hashlib, struct, sys

KERNEL_FLASH = 0x10000        # kernel partition start
ROOTFS_FLASH = 0x200000       # rootfs partition start
PAD_TARGET   = ROOTFS_FLASH - KERNEL_FLASH   # 0x1F0000: kernel image + pad
CVIMG_HDR    = 16             # cvimg header length
CVIMG_CKSUM  = 2              # cvimg trailing 16-bit checksum
DEFAULT_TAG  = bytes.fromhex('b300aa06')
DEADC0DE     = bytes.fromhex('deadc0de')

def cvimg_fields(img):
    sig = img[0:4]
    start, burn, length = struct.unpack('>III', img[4:16])
    return sig, start, burn, length

def main():
    ap = argparse.ArgumentParser(description="wrap v1.0 images for the stock web updater")
    ap.add_argument('kernel'); ap.add_argument('rootfs')
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('--tag-from', help="copy the 4-byte format tag from a vendor .bin (bytes 0x10..0x14)")
    a = ap.parse_args()

    kernel = open(a.kernel, 'rb').read()
    rootfs = open(a.rootfs, 'rb').read()

    ksig, _, kburn, klen = cvimg_fields(kernel)
    rsig, _, rburn, rlen = cvimg_fields(rootfs)
    if ksig != b'cs6c':
        sys.exit(f"kernel is not a cs6c image (got {ksig!r})")
    if kburn != KERNEL_FLASH:
        sys.exit(f"kernel burn addr is 0x{kburn:x}, expected 0x{KERNEL_FLASH:x}")
    if rsig != b'r6cr':
        sys.exit(f"rootfs is not an r6cr image (got {rsig!r})")
    if rburn != ROOTFS_FLASH:
        sys.exit(f"rootfs burn addr is 0x{rburn:x}, expected 0x{ROOTFS_FLASH:x}")
    if len(kernel) > PAD_TARGET:
        sys.exit(f"kernel image {len(kernel)} exceeds the kernel partition {PAD_TARGET}")

    # squashfs on flash is the rootfs image with the 16-byte r6cr header and the
    # trailing 2-byte cvimg checksum removed (the loader writes only the payload).
    squashfs = rootfs[CVIMG_HDR:len(rootfs) - CVIMG_CKSUM]
    if squashfs[0:4] != b'hsqs':
        sys.exit(f"rootfs payload is not squashfs (got {squashfs[0:4]!r})")

    tag = DEFAULT_TAG
    if a.tag_from:
        v = open(a.tag_from, 'rb').read()
        tag = v[0x10:0x14]
        if v[0x14:0x18] != b'cs6c':
            sys.exit("--tag-from file does not have cs6c at 0x14; not a vendor image")

    combined = kernel + b'\xff' * (PAD_TARGET - len(kernel)) + squashfs
    body = tag + combined + DEADC0DE
    md5 = hashlib.md5(body).digest()
    ota = md5 + body
    open(a.out, 'wb').write(ota)

    # self-check the layout the updater will write to flash (body without tag)
    flash = combined + DEADC0DE
    assert flash[0:4] == b'cs6c'
    assert flash[ROOTFS_FLASH - KERNEL_FLASH:][0:4] == b'hsqs'
    assert hashlib.md5(ota[16:]).digest() == ota[:16]
    print(f"wrote {a.out}: {len(ota)} bytes")
    print(f"  MD5 prefix      {md5.hex()}")
    print(f"  tag             {tag.hex()}")
    print(f"  kernel          {len(kernel)} B (cs6c, burn 0x{kburn:05x})")
    print(f"  pad             {PAD_TARGET - len(kernel)} B of 0xFF")
    print(f"  squashfs        {len(squashfs)} B (hsqs, lands at flash 0x{ROOTFS_FLASH:06x})")
    print(f"  flash image     {len(flash)} B written to 0x{KERNEL_FLASH:05x} (mtd0 untouched)")

if __name__ == '__main__':
    main()
