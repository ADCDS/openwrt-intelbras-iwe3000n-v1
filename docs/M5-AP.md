# M5 — hostapd AP on the RTL8192EE

**Status: the radio works. hostapd brings up a beaconing WPA2 AP.** MAC init
succeeds, `wlan0` reaches `AP-ENABLED`, and the interface carries a beacon. The
one part of M5's definition that a board cannot self-test — a real client
associating and passing traffic — is left for a person with a phone (see the
end of this file); everything up to that point is verified on hardware.

## What was actually wrong: BAR 2 was in I/O space, not memory

For a long time this failed with:

```
rtlwifi: RTL8XXX did not boot from eeprom, check it !!
[   68.587040] rtl8192ee: Init MAC failed
```

and the working theory was the missing efuse (this board's calibration lives in
the H601 factory block, not an EEPROM). **That theory was wrong.** The eeprom
line was a red herring; it disappears entirely once the real bug is fixed.

The real bug was in the PCIe host bridge's `ranges`. The RTL8196E decodes two
fixed apertures for downstream PCIe, and its own `bspchip.h` names them:

```
BSP_PCIE0_D_IO   0xB8C00000   -> phys 0x18C00000     I/O transactions
BSP_PCIE0_D_MEM  0xB9000000   -> phys 0x19000000     memory transactions
```

The first version of the DT node declared a single window at `0x18c00000` and
labelled it *memory*. That is the **I/O** aperture. So the PCI core assigned the
endpoint's MMIO BAR — BAR 2, the only BAR `rtl8192ee` uses — to `0x18c00000`,
and every driver register access to the chip went onto the wire as a PCIe **I/O**
TLP instead of a memory one. The chip never saw its register writes.

This is exactly why M3 and M4 passed while M5 failed. Link training (LTSSM → L0)
and config-space enumeration do not touch BAR 2, so they were fine and looked
like a healthy radio. `_rtl92ee_init_mac()` is the first thing that does bulk
MMIO through BAR 2, so it — and only it — timed out.

Proof, from the failing boot:

```
pci 0000:01:00.0: BAR 2 [mem 0x18c00000-0x18c03fff 64bit]: assigned   <- I/O aperture
[   68.587040] rtl8192ee: Init MAC failed
```

## The fix: one memory range at the memory aperture

```
ranges = <0x02000000 0x0 0x19000000   0x01000000   0x0 0x01000000>;
```

BAR 2 now lands where memory transactions actually reach the endpoint:

```
pci 0000:01:00.0: BAR 2 [mem 0x19000000-0x19003fff 64bit]: assigned
```

and the eeprom warning and `Init MAC failed` are both gone.

**No I/O range is declared, on purpose.** Two reasons:

1. The RTL8192EE advertises a 0x100-byte I/O BAR (BAR 0) that the driver never
   touches. Leaving it unassigned costs one boot-time warning
   (`BAR 0 [io ...]: can't assign; no space`) and nothing else.
2. Declaring an I/O range makes the generic host-bridge code call
   `devm_pci_remap_iospace()` → `vmap_page_range()`, which **BUGs** on this
   Lexra MIPS — it has no `PCI_IOBASE` fixmap region to map the aperture into.
   The probe never returns:

   ```
   Kernel bug detected[#1]:
   Call Trace:
   [<800b4354>] vmap_page_range+0x40/0x1d4
   [<801c3ccc>] devm_pci_remap_iospace+0x5c/0xa0
   [<801cf748>] rtl819x_pcie_probe+0x30/0x34c
   ```

   A 64 KiB I/O range (a legal subset of the 2 MB aperture) avoids the resource
   collision but still hits this BUG. Memory-only is the only thing that both
   probes cleanly and puts BAR 2 in the right place.

## Verified on hardware

```
# ip link set wlan0 up            -> rc=0, no "Init MAC failed"
# ip link show wlan0
3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> ... state UP
# hostapd /etc/hostapd.conf
wlan0: interface state UNINITIALIZED->COUNTRY_UPDATE
wlan0: interface state COUNTRY_UPDATE->ENABLED
wlan0: AP-ENABLED
# hostapd_cli -p /var/run/hostapd status
state=ENABLED  channel=6  ssid[0]=IWE3000N-test  bssid[0]=00:e0:4c:81:92:41
```

## The one thing left, and why it needs a person

"A real client associates and passes traffic" cannot be self-tested from the
board. The AP is left running for it:

- SSID `IWE3000N-test`, WPA2-PSK `iwe3000n-bench`, channel 6.
- `wlan0` has `192.168.50.1/24`.
- **There is no DHCP server on the board** — only busybox `udhcpc`, a client.
  So a phone associates (that exercises the 4-way handshake, the real proof the
  radio encrypts and decrypts), but to pass traffic it needs a static address:
  set the phone to `192.168.50.2/24` and `ping 192.168.50.1`.

Watch the association from the board with `hostapd_cli -p /var/run/hostapd all_sta`
or by tailing hostapd; a `AP-STA-CONNECTED <mac>` line is the association.

## The MAC is still the Realtek default

`wlan0` comes up as `00:e0:4c:81:92:41`, a Realtek OUI default, not the board's
`D8:77:8B:3F:E2:01` from the H601 block. That is the same open item as the
ethernet MAC (`M2-ETHERNET.md`) and has the same fix — an `nvmem-cell` on the
`boot` partition feeding the driver. It does not affect whether the AP works.

## What is already done and reusable

- `tools/build-hostapd.sh` — hostapd 2.11 + libnl-tiny, **statically linked**,
  cross-built with the Lexra toolchain. In the rootfs at `/sbin/hostapd`.
- `files/rootfs/etc/hostapd.conf` — 2.4 GHz WPA2-PSK on channel 6.
- Four build traps solved and commented in the script: CFLAGS via the
  environment (not the make command line, which overrides hostapd's own
  `+=`), `-D_GNU_SOURCE` for musl's `struct ucred`, `CONFIG_LIBNL_TINY` rather
  than `CONFIG_LIBNL32`, and `-static` because this rootfs ships no dynamic
  loader — a dynamically linked binary fails as "not found" even though the
  file is plainly there.
- `sbin/`, not `usr/sbin/`: the latter is a symlink to `/userdata/usr/sbin`,
  the partition this board does not have.
