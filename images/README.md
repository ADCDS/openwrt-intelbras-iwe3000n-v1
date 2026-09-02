# Prebuilt images — v1.0

Built by `./build.sh release v1.0`, upstream jnilo1/rtl8196e-gateway pinned at
**v4.2.0**, inside the toolchain container. Nothing outside this repository and
that pinned upstream went into them.

> **The `.img` files are not committed to git** (build artefacts). Download
> them from the repo's [release page](https://github.com/ADCDS/openwrt-intelbras-iwe3000n-v1/releases/latest),
> drop them in this directory, then verify:
>
> ```sh
> sha256sum --ignore-missing -c sha256sums.txt
> ```
>
> The checksums here are the authoritative record of what v1.0 is.

| file | bytes | fits | burn address | writes |
|---|---|---|---|---|
| `iwe3000n-v1-v1.0-kernel.img` | 1 851 392 | 1808 KiB of 1984 KiB (91 %) | `0x00010000` | the `kernel` partition |
| `iwe3000n-v1-v1.0-rootfs.img` | 949 800 | 927 KiB of 1600 KiB (57 %) | `0x00200000` | the `rootfs` partition |

Both are `cvimg`-headed for the stock RealTek loader's TFTP; the loader reads
the burn address from the header and prints it (`burn Addr =0x...!`) before
writing. Neither touches `mtd0`. Install: [`../docs/INSTALL.md`](../docs/INSTALL.md).
Recovery: [`../docs/RECOVERY.md`](../docs/RECOVERY.md).

**What v1.0 is:** Linux 6.18.45, ethernet, PCIe, mainline `rtl8192ee`, hostapd
2.11 WPA2 AP `IWE3000N-test` up at boot on `192.168.50.1/24`, a **udhcpd DHCP
server** (`.100`–`.200`), and **SSH** (dropbear, root login). Hardware-gated
before tagging from a clean flash + cold power cycle: all three services start
unattended, a WPA2 client gets a DHCP lease, `ssh root@192.168.50.1` logs in,
ping clean.

⚠ Default images broadcast an AP whose passphrase (`iwe3000n-bench`), root
password (`root`) and SSH host key are all in this repo, with a `BR` regulatory
domain. SSH is reachable by anyone who joins the AP. Read the README's warning
box before this touches a real network.
