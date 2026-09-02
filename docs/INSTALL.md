# Installing

Two images, both written through the stock RealTek loader's TFTP, both inside
stock's `linux` region. `mtd0` is never touched. Read
[`RECOVERY.md`](RECOVERY.md) first and take the backup it describes.

You need: a **3.3 V UART** on the board's console header (**38400 8N1**), an
Ethernet cable to the board's single jack, a TFTP client with `-c put`
(`tftp-hpa`), and the two images from a release or from `./build.sh release`.

## 1. Serial console

Open the case. The four-pin header on the board is the console; left to right
as photographed, **3V3, TX, RX, GND**:

![The console header with each wire labelled: 3V3 purple, TX gray, RX white, GND black](img/console-header.jpg)

Router TX goes to your adapter's RX and vice versa. Wire GND first. Leave 3V3
unconnected unless your adapter is powered from it — the bench here uses an
ESP32-S3 running [uart-ota](https://github.com/ADCDS/uart-ota) as a network
serial bridge, powered from that pin:

![The IWE 3000N open on the bench, wired to an ESP32-S3 running uart-ota](img/bench-bridge.jpg)

⚠ The board carries **mains** on the same PCB, a few centimetres from the
header. Wire it unplugged; only then plug it in.

## 2. Reach the loader

Power on with the console open. The loader prints its banner and boots the
kernel within about a second. Send a burst of **ESC** (two dozen over ~250 ms)
right after the banner — or, from a running Linux, type `reboot` and send the
burst when the banner reappears. You want:

```
---Escape booting by user
...
<RealTek>
```

The prompt does not echo an empty line; type `IPCONFIG` to see it respond.
Do not type `J` on its own.

## 3. Flash

Put the workstation on the loader's subnet and wait for ARP:

```sh
sudo ip addr add 192.168.1.10/24 dev <your-eth>
ip neigh show 192.168.1.6          # wait until this prints an lladdr
tftp -m binary 192.168.1.6 -c put iwe3000n-v1-v1.0-kernel.img
```

The console must show, in this order, **`checksum Ok !`**,
**`burn Addr =0x00010000!`**, **`Flash Write Successed!`**. If the burn
address is anything else, stop. Then the rootfs:

```sh
tftp -m binary 192.168.1.6 -c put iwe3000n-v1-v1.0-rootfs.img
```

expecting **`burn Addr =0x00200000!`**. A kernel without its rootfs
reboot-loops; that is recoverable, just flash the rootfs.

Power-cycle. Expect `===== System ready =====` and `(none) login:` about five
seconds after power-on. If instead you see a `SIGSEGV` a few seconds in,
power-cycle again — see *Known issues* in the README.

## 4. First login, and the AP

Log in as **`root`, password `root`** (upstream's default, baked into the
read-only rootfs — see `files/rootfs/README.md` for why and how to change it).

The AP starts on its own (`/etc/init.d/S90wifi`):

| | |
|---|---|
| SSID | `IWE3000N-test` |
| security | WPA2-PSK / CCMP, passphrase **`iwe3000n-bench`** |
| band / channel | 2.4 GHz, channel 6, 802.11n HT20 |
| AP address | `192.168.50.1/24` |

A **DHCP server** hands clients `192.168.50.100`–`.200`, so joining is enough —
no static address needed. (A static address in the `/24` still works if you
prefer.) **SSH** is up too: `ssh root@192.168.50.1`, password `root`. The host key is a
fixed one shipped in the image (shared across all units — a bench key, see
`files/rootfs/etc/dropbear/README.md`).

```sh
ssh root@192.168.50.1                             # password: root
hostapd_cli -i wlan0 status | grep ^state        # state=ENABLED
hostapd_cli -i wlan0 all_sta                      # your client, flags=[AUTH][ASSOC][AUTHORIZED]...
cat /tmp/udhcpd.leases | wc -l                    # a lease per client
```

To change SSID or passphrase, edit `files/rootfs/etc/hostapd.conf` and rebuild
the rootfs — or, for the current boot only, copy it to `/tmp`, edit, and
`killall hostapd; hostapd -B /tmp/hostapd.conf`.

Ethernet comes up as `eth0` with a random MAC and no address; `ip addr add`
what you need, or `udhcpc -i eth0`. There is no DHCP *server* on `eth0`, only
on the AP.

## 5. Updating

Same as installing: loader, TFTP, kernel then rootfs. `rootfs_data` (jffs2,
448 KiB) is left alone by both writes, but nothing in this rootfs persists
there yet, so there is nothing to lose either.
