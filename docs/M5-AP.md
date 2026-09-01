# M5 — hostapd AP with a real client

**Status: not achieved. hostapd runs; the radio's MAC init fails.**

## How far it gets

hostapd is cross-built, installed, starts, opens nl80211, and drives the driver
correctly. It fails at the point where the radio hardware must actually come up:

```
# /sbin/hostapd -B /etc/hostapd.conf
rfkill: Cannot open RFKILL control device
[   90.299800] rtl8192ee: Init MAC failed
Could not set interface wlan0 flags (UP): No such file or directory
nl80211: Could not set interface 'wlan0' UP
Segmentation fault
```

Everything before that is healthy — `phy0` exists, `wlan0` exists, the firmware
loads, `wireless switch is on`. The failure is `_rtl92ee_init_mac()` inside the
driver, not hostapd, and it happens every time `wlan0` is brought up.

(The segfault is hostapd's own cleanup path after the interface fails to come
up. It is a symptom, not the cause.)

## The likely cause, stated as a hypothesis

The driver says so on every boot:

```
rtlwifi: RTL8XXX did not boot from eeprom, check it !!
```

Mainline `rtlwifi` expects to read per-chip calibration and MAC from the
RTL8192EE's own EEPROM/efuse. **This board has none** — its radio is soldered
down and its calibration lives in the H601 block at `mtd0+0x6000`, alongside the
MAC `D8:77:8B:3F:E2:01` (see `../../iwe3000n-firmware/PARTITIONS.md`). The vendor
driver reads that block and pushes the values into the chip; mainline has no
such path, so the chip is being initialised with defaults and the power-on
sequence times out.

**This is a hypothesis, not a diagnosis.** What supports it: the eeprom warning
is emitted before every failure, the same block is known to hold the ethernet
MAC this port also gets wrong (`M2-ETHERNET.md`), and `Init MAC failed` is a
power-sequence timeout rather than a bus error — the PCIe link itself is fine
and config space reads correctly throughout. What has not been done: reading the
H601 block's layout, or confirming which values `_rtl92ee_init_mac()` actually
depends on.

## What closing M5 would take

1. Decode the H601 block — the two MACs are at `0x600d`/`0x6013`, and the byte
   table after `0x6043` looks like per-channel TX power, but the rest is
   unmapped.
2. Get those values to the driver. Either an `nvmem-cell` on the `boot`
   partition feeding a patched `rtlwifi` efuse path, or a DT property the driver
   reads instead of the efuse. The same `nvmem-cell` closes the ethernet MAC gap.
3. Then hostapd, then a real client — which needs a person with a phone, since
   "a real client associates and passes traffic" cannot be self-tested.

## What is already done and reusable

- `tools/build-hostapd.sh` — hostapd 2.11 + libnl-tiny, **statically linked**,
  cross-built with the Lexra toolchain. 1074208 bytes, in the rootfs at
  `/sbin/hostapd`, and it runs.
- `files/rootfs/etc/hostapd.conf` — 2.4 GHz WPA2-PSK on channel 6.
- Four build traps solved and commented in the script: CFLAGS via the
  environment (not the make command line, which overrides hostapd's own
  `+=`), `-D_GNU_SOURCE` for musl's `struct ucred`, `CONFIG_LIBNL_TINY` rather
  than `CONFIG_LIBNL32`, and `-static` because this rootfs ships no dynamic
  loader — a dynamically linked binary fails as "not found" even though the
  file is plainly there.
- `sbin/`, not `usr/sbin/`: the latter is a symlink to `/userdata/usr/sbin`,
  the partition this board does not have.
