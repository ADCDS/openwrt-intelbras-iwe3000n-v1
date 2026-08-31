# Getting the radio working

jnilo1's tree ships with `# CONFIG_WLAN is not set` and no wireless driver. This
is the plan to change that. Written 2026-08-31; **nothing here has been built or
booted yet.**

## The reframing

The obvious reading of "jnilo1 has no Wi-Fi" is that the vendor `rtl8192cd`
driver must be forward-ported from Linux 3.10 to 6.18. That driver is
[in this workspace already](../../../dir842/dir842-rtl8192cd-driver/): **37 MB,
291 `.c` files, 374 headers**, WEXT-era, with its own PCIe bring-up, its own
bridge/NAT hooks and its own hostapd fork. Forward-porting it would be the
largest single piece of work in this project.

**It is very likely unnecessary.** The boot log says what the radio actually is:

```
[   18.830000] Find Port=0 Device:Vender ID=818b10ec
```

PCI vendor `0x10ec`, device `0x818b` — that is the **RTL8192EE**, and mainline
Linux has driven it since **3.16**. `CONFIG_RTL8192EE` lives in
`drivers/net/wireless/realtek/rtlwifi/rtl8192ee/` and is present in 6.18. It is
a proper mac80211 driver: nl80211, hostapd, `iw`, all the normal tooling — none
of which the vendor driver offers.

So the wireless driver is free. **The missing piece is underneath it.**

## The actual gap: a PCIe host controller

`CONFIG_RTL8192EE` depends on `CONFIG_PCI`, and:

- jnilo1's `config-6.18-realtek.txt` has **no `CONFIG_PCI` at all**
- their `files-6.18/` tree contains **no PCI code whatsoever**
- mainline has no PCIe host driver for RTL819x

The vendor works around this by having the *Wi-Fi driver itself* bring up the
SoC's PCIe host — which is why that `Find Port=0` line is printed by
`8192cd_host.c`, a wireless driver, and not by a PCI subsystem.

So the work is: **write a PCIe host controller driver for the RTL819x**, then
`CONFIG_PCI=y` + `CONFIG_RTL8192EE=m` does the rest.

## The raw material

The register sequence is already in the workspace, in
`dir842-rtl8192cd-driver/rtl8192cd/8192cd_host.c` (2060 lines) — and critically,
**it is the same code that printed `Find Port=0` on our RTL8196E**, so the
register layout is known to apply to this SoC and not just the DIR-842's
RTL8197F.

PHY power/reset, port 0 (`BSP_PCIE0_H_PWRCR`):

```c
REG32(pcie_phy) = 0x01;   /* bit7 PHY reset = 0, bit0 enable LTSSM = 1 */
REG32(pcie_phy) = 0x81;   /* bit7 PHY reset = 1, bit0 enable LTSSM = 1 */
```

Link-up poll and config window:

```c
dbgaddr = 0xb8b00728;                    /* port 0; port 1 = 0xb8b20728 */
while (--i) {
        if ((REG32(dbgaddr) & 0x1f) == 0x11)   /* LTSSM L0 */
                break;
        delay_ms(100);
}
cfgaddr = 0xb8b10000;                    /* port 0; port 1 = 0xb8b30000 */
```

Those are KSEG1 addresses, so the physical ones a devicetree node would carry:

| | phys | |
|---|---|---|
| port 0 debug/status | `0x18b00728` | LTSSM state in bits 4:0, `0x11` = L0 |
| port 0 config space | `0x18b10000` | where `10ec:818b` was read from |
| port 1 debug/status | `0x18b20728` | second slot, unused on this board |
| port 1 config space | `0x18b30000` | |

`8192cd_host.c` also carries the MDIO PHY setup and per-SoC reset procedures
behind `CONFIG_RTL_8198B` / `CONFIG_RTL_8197F` ifdefs; the RTL8196E path needs
reading out of the same file.

## Size budget

This is the constraint that could still sink it. The kernel partition in the
[proposed layout](PORT-PLAN.md) is 1664 KiB and the base 6.18 image is already
1408 KiB, so **the wireless stack cannot be built in — it has to be modules in
the rootfs**, which has 1920 KiB.

What has to fit there, alongside BusyBox and dropbear (~1.4 MB uncompressed
skeleton):

- `cfg80211.ko`, `mac80211.ko` — the big ones
- `rtlwifi.ko`, `rtl8192ee.ko`, `rtl_pci.ko`
- `rtlwifi/rtl8192eefw.bin` firmware blob
- `hostapd` for AP mode, if this is to be an access point at all

**None of these sizes have been measured for MIPS/6.18 and they must be before
committing to this route.** For scale, the stock 3.10 system on this very board
runs `cfg80211` at 230,103 bytes and `rtl8192cd` at 1,363,888 bytes in RAM — so
a mainline stack in the same ballpark is plausible but not guaranteed, and
squashfs compression is what makes it fit or not.

If it does not fit, the levers are: a smaller rootfs skeleton, dropping dropbear,
building `mac80211` with fewer features, or moving the kernel/rootfs boundary
(there is 256 KiB of slack in the kernel partition at 85 % use).

## A stage-2 gotcha found while wiring the build

The upstream config carries **`CONFIG_PCI_DRIVERS_LEGACY=y`**. On MIPS that
selects the old `struct pci_controller` model; DT host-bridge drivers that use
`devm_pci_alloc_host_bridge()` and `pci_host_probe()` — which is what stage 2
plans to do — need **`CONFIG_PCI_DRIVERS_GENERIC`** instead. The two are a
`choice` in `arch/mips/Kconfig`.

This does not affect stage 1, which registers no bridge. It does mean stage 2
starts with an arch-level config flip whose knock-on effects on the rest of the
MIPS build are not yet known. Worth finding out early rather than at the point
of registering the bridge.

## Order of work

1. `CONFIG_PCI=y` and a stub `pci-rtl819x.c` that only brings up the PHY and
   polls for link, logging what it finds at `0x18b10000`. **Success is reading
   back `818b10ec` from mainline code** — that alone proves the whole approach.
2. Flesh it into a real `pci-host-generic`-style driver with config-space
   accessors and a devicetree binding.
3. `CONFIG_RTL8192EE=m`, load it, see whether `rtlwifi` probes.
4. Firmware blob into the rootfs; `iw dev` should show a phy.
5. hostapd, AP mode, and only then any performance work.

Step 1 is the honest go/no-go. If mainline code can read the PCI config header,
the rest is ordinary driver work; if it cannot, the RTL8196E PCIe block needs
reverse-engineering beyond what the vendor source shows, and the calculation
changes.

## The fallback

If the PCIe route fails, the alternatives are both worse:

- **Forward-port `rtl8192cd` to 6.18** — the 37 MB WEXT driver. Enormous, and
  the result is a driver with no nl80211, so LuCI-style status and modern
  hostapd never work properly. This is what the stock firmware does.
- **Switch to [lekswrt/rtl8196e](https://github.com/lekswrt/rtl8196e)** — working
  ethernet *and* 8192E Wi-Fi at 4 MB today, on Linux 3.10.49 / OpenWrt 14.07,
  unmaintained since 2019. A working radio on an old kernel, immediately.

Keeping lekswrt as the fallback is what makes attempting the PCIe driver
reasonable: failure costs time, not the device.
