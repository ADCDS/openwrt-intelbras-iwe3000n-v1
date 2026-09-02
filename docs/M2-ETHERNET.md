# M2 — ethernet carries traffic

**Status: done, measured on hardware 2026-09-01.**

`rtl8196e-eth v2.24` on the IWE 3000N's single 100 Mbit jack, straight into a
USB-Ethernet adapter on the workstation.

## Measured

```
# ip link show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP

# ping -c 4 192.168.1.10
4 packets transmitted, 4 packets received, 0% packet loss
round-trip min/avg/max = 1.000/1.990/4.360 ms
```

and the reverse, workstation → board: `4 received, 0% packet loss,
rtt min/avg/max/mdev = 0.715/0.739/0.770/0.019 ms`.

**iperf3 3.18, 10 s each way, board as client:**

| direction | with I-MEM (M2 build) | without I-MEM (M4/M5 build) |
|---|---|---|
| TX (board → workstation) | **86.3 Mbit/s**, 0 retr | **73.5 Mbit/s**, 0 retr |
| RX (workstation → board) | **94.2 Mbit/s**, 1 retr | **91.2 Mbit/s**, 1 retr |

**Both columns are measured, not estimated.** The wireless stack overran
upstream's 15872-byte on-chip instruction-RAM window by 28 bytes, so
`IMEM_POLICY_DISABLE=1` had to be set from M4 onwards — see `M4-RADIO.md`. That
drops their hot-path optimisation and **costs about 15 % of TX throughput and
3 % of RX**. The second column is what the current image actually does.

Getting it back means trimming `scripts/imem/policies/6.18.45.tsv` by ~28 bytes
of functions rather than disabling the policy wholesale. That is a real, bounded
piece of work and it is not done.

On a 100 Mbit link that is ~94 % of line rate inbound and ~86 % outbound, with
essentially no loss. The asymmetry matches upstream's own figures for this
driver (`POST-MORTEM-driver-perf.md`: TCP RX 86.6→93.7, TCP TX 48.1→69.8) —
this board's TX is *better* than the range they record, so nothing here looks
like a regression.

iperf3 confirms the kernel it is running on:

```
iperf 3.18 (cJSON 1.7.15)
Linux (none) 6.18.45-rtl8196e-v4.2.0 #4 mips
```

## How to reproduce

The board's rootfs has no iperf3 — upstream ships one in
`34-Userdata/iperf3/iperf3` (354,344 bytes, MIPS). `/userdata` has only 252 KiB
free, so put it in RAM instead: `/tmp` is a symlink to `/var/tmp` on ramfs.

```sh
# workstation
cat 34-Userdata/iperf3/iperf3 | nc -l -p 5560
iperf3 -s -B 192.168.1.10 -1

# board
nc 192.168.1.10 5560 > /tmp/iperf3     # then Ctrl-C: busybox nc does not exit on EOF
chmod +x /tmp/iperf3
/tmp/iperf3 -c 192.168.1.10 -t 10      # add -R for the other direction
```

## What was tried and failed

- **`34-Userdata/iperf3` is a directory, not the binary.** Three transfers
  produced a 0-byte file because a directory was being piped into netcat, with
  no error from either end. The binary is `iperf3/iperf3`.
- **busybox `nc` as a client does not exit on EOF** — it sits there until
  interrupted, so a script that waits for the shell prompt hangs.
- **`df` on ramfs reports 0/0/0**, so it looks full when it is not.

## Known gap at M2 -- fixed in v1.0

**`eth0` comes up with a random MAC** — `06:df:06:1c:6d:2e` on this boot, and it
will differ on the next one:

```
2: eth0: ... link/ether 06:df:06:1c:6d:2e brd ff:ff:ff:ff:ff:ff
```

The board's real MAC, `D8:77:8B:xx:xx:xx`, lives in the H601 factory block at
`mtd0` offset `0x6000` (see [`RECOVERY.md`](RECOVERY.md)). Nothing in
this port reads it yet, so every boot presents a new address — DHCP reservations,
ARP caches and anything MAC-pinned will not survive a reboot.

**Fixed in v1.0, in userspace.** `/etc/init.d/S40mac` reads the six bytes at
`mtd0 + 0x600d` and applies them to `eth0` before the network scripts run, so
each unit uses its own address and a DHCP reservation survives a reboot.
Verified on the bench unit: `d8:77:8b:3f:e2:01` out of its own flash.

The device-tree route is tidier -- an `nvmem-cell` on the `boot` partition
feeding `of_get_mac_address()`, which this driver already calls -- but it needs
`CONFIG_NVMEM`, which is off, and the kernel partition is at 91 %. A ~1 KB shell
script was the cheaper way to the same result. `mtd0` is only ever read.

`wlan0` is a separate matter and still varies per boot: that address comes from
the radio chip's efuse, not from the H601 block.
