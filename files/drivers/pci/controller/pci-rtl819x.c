// SPDX-License-Identifier: GPL-2.0
/*
 * PCIe host controller for Realtek RTL819x SoCs (RTL8196E and relatives).
 *
 * STAGE 1 — a deliberate go/no-go probe, not yet a working host bridge.
 *
 * Why this exists at all: the RTL8196E's on-board Wi-Fi is a PCIe device
 * (10ec:818b, an RTL8192EE) that mainline Linux has had a driver for since
 * 3.16. What mainline does not have — and neither does the jnilo1 tree this
 * port is based on — is any way to bring up the SoC's PCIe host, so
 * CONFIG_PCI is off and the radio is unreachable. The Realtek vendor stack
 * hides this by doing the host bring-up inside the *wireless* driver
 * (rtl8192cd/8192cd_host.c), which is why a stock boot prints its PCIe
 * discovery line from a wifi module.
 *
 * What this file does today: reset the PHY, wait for the link, and read the
 * downstream device's config header. If that reads back 0x818b10ec from
 * mainline code, the whole approach is proven and stage 2 (real config
 * accessors, resource windows, host bridge registration) is ordinary work.
 * If it does not, the block needs more reverse engineering than the vendor
 * source exposes.
 *
 * Register knowledge is taken from the vendor driver, and specifically from
 * the code path that is *known to run on this SoC*: PCIE_Check_Link() in
 * 8192cd_host.c polls 0xb8b00728 and reads 0xb8b10000, and those are the two
 * addresses behind the "Find Port=0 Device:Vender ID=818b10ec" line in this
 * board's own boot log. KSEG1 0xb8xxxxxx maps to physical 0x18xxxxxx.
 *
 * Everything below that is NOT covered by that confirmed path is marked
 * UNVERIFIED. The BAR and command-register values in particular come from a
 * branch of the vendor file guarded for other SoCs; they are recorded here
 * because they are the only documentation that exists, not because they have
 * been observed working on an RTL8196E.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/time64.h>

#define DRV_NAME "rtl819x-pcie"

/* Root-complex config space. Standard type-1 header, plus vendor registers
 * above 0x100 — the link status we care about lives at 0x728. */
#define RTL819X_RC_LTSSM		0x0728
#define  RTL819X_LTSSM_STATE		GENMASK(4, 0)
#define  RTL819X_LTSSM_L0		0x11

/* PHY control block. Bit 0 enables the LTSSM, bit 7 releases PHY reset;
 * the vendor writes them in two steps and so do we. */
#define RTL819X_PHY_PWRCR		0x0008
#define  RTL819X_PHY_LTSSM_EN		BIT(0)
#define  RTL819X_PHY_RESET_N		BIT(7)

/* Config-space offsets we read back for the log line. */
#define RTL819X_CFG_VENDOR_DEVICE	0x0000

struct rtl819x_pcie {
	struct device *dev;
	void __iomem *rc_cfg;		/* root complex config space   */
	void __iomem *dev_cfg;		/* downstream device config    */
	void __iomem *phy;		/* PHY power/reset control     */
};

static int rtl819x_pcie_phy_reset(struct rtl819x_pcie *pcie)
{
	/*
	 * Vendor sequence, verbatim in effect:
	 *	REG32(phy) = 0x01;	LTSSM enabled, PHY held in reset
	 *	REG32(phy) = 0x81;	PHY reset released
	 *
	 * The two writes are ordered and the vendor inserts no delay between
	 * them. Keep it that way until there is evidence a delay is needed.
	 */
	writel(RTL819X_PHY_LTSSM_EN, pcie->phy + RTL819X_PHY_PWRCR);
	writel(RTL819X_PHY_LTSSM_EN | RTL819X_PHY_RESET_N,
	       pcie->phy + RTL819X_PHY_PWRCR);

	return 0;
}

static int rtl819x_pcie_wait_link(struct rtl819x_pcie *pcie)
{
	u32 val;
	int ret;

	/*
	 * The vendor polls ten times with a 100 ms sleep, so up to a second.
	 * Match that budget rather than inventing a tighter one — a slow link
	 * that trains in 900 ms is a working link.
	 */
	ret = readl_poll_timeout(pcie->rc_cfg + RTL819X_RC_LTSSM, val,
				 (val & RTL819X_LTSSM_STATE) == RTL819X_LTSSM_L0,
				 100 * USEC_PER_MSEC, USEC_PER_SEC);
	if (ret) {
		dev_err(pcie->dev, "link training failed, LTSSM = 0x%02x\n",
			(u32)(val & RTL819X_LTSSM_STATE));
		return ret;
	}

	return 0;
}

static int rtl819x_pcie_probe(struct platform_device *pdev)
{
	struct rtl819x_pcie *pcie;
	u32 id;
	int ret;

	pcie = devm_kzalloc(&pdev->dev, sizeof(*pcie), GFP_KERNEL);
	if (!pcie)
		return -ENOMEM;

	pcie->dev = &pdev->dev;

	pcie->rc_cfg = devm_platform_ioremap_resource_byname(pdev, "rc-cfg");
	if (IS_ERR(pcie->rc_cfg))
		return PTR_ERR(pcie->rc_cfg);

	pcie->dev_cfg = devm_platform_ioremap_resource_byname(pdev, "dev-cfg");
	if (IS_ERR(pcie->dev_cfg))
		return PTR_ERR(pcie->dev_cfg);

	pcie->phy = devm_platform_ioremap_resource_byname(pdev, "phy");
	if (IS_ERR(pcie->phy))
		return PTR_ERR(pcie->phy);

	ret = rtl819x_pcie_phy_reset(pcie);
	if (ret)
		return ret;

	ret = rtl819x_pcie_wait_link(pcie);
	if (ret)
		return ret;

	/*
	 * The whole point of stage 1. On this board the expected value is
	 * 0x818b10ec — an RTL8192EE, which drivers/net/wireless/realtek/rtlwifi
	 * already supports.
	 */
	id = readl(pcie->dev_cfg + RTL819X_CFG_VENDOR_DEVICE);
	dev_info(pcie->dev, "link up, downstream device %04x:%04x\n",
		 id & 0xffff, id >> 16);

	if (id == 0xffffffff || !id) {
		dev_err(pcie->dev,
			"config space reads as 0x%08x — link is up but config access is wrong\n",
			id);
		return -ENODEV;
	}

	/*
	 * STAGE 2, not implemented:
	 *
	 *  - struct pci_ops with config read/write. Config access here looks
	 *    like a flat window per device rather than the usual
	 *    address/data pair, so map_bus() is likely trivial for bus 0 and
	 *    needs thought for anything behind the root port.
	 *  - Resource windows. The vendor programs the root port's type-1
	 *    bridge registers at RC offsets 0x1c/0x20/0x24 (IO base/limit,
	 *    memory base/limit, prefetchable base/limit) and then writes the
	 *    device BARs directly:
	 *
	 *	PCIE_D_CFG0 + 0x10 = 0x18c00001	 BAR0
	 *	PCIE_D_CFG0 + 0x18 = 0x19000004	 BAR2, 64-bit memory
	 *	PCIE_D_CFG0 + 0x04 = 0x00180007	 cmd: io + mem + bus master
	 *	PCIE_H_CFG  + 0x04 = 0x00100007
	 *
	 *    UNVERIFIED for the RTL8196E — that block sits in a vendor branch
	 *    guarded for other SoCs. Under Linux the PCI core should assign
	 *    BARs from DT ranges instead of hardcoding them; these values are
	 *    recorded as documentation of where the windows physically are.
	 *  - devm_pci_alloc_host_bridge() + pci_host_probe().
	 *  - Interrupts. Not investigated at all yet; the RTL8192EE will need
	 *    one, and whether it is a plain SoC IRQ or something MSI-shaped is
	 *    unknown.
	 */

	dev_info(pcie->dev,
		 "stage 1 only: host bridge not registered, no devices enumerated\n");

	platform_set_drvdata(pdev, pcie);
	return 0;
}

static const struct of_device_id rtl819x_pcie_of_match[] = {
	{ .compatible = "realtek,rtl819x-pcie" },
	{ }
};
MODULE_DEVICE_TABLE(of, rtl819x_pcie_of_match);

static struct platform_driver rtl819x_pcie_driver = {
	.probe = rtl819x_pcie_probe,
	.driver = {
		.name = DRV_NAME,
		.of_match_table = rtl819x_pcie_of_match,
		.suppress_bind_attrs = true,
	},
};
builtin_platform_driver(rtl819x_pcie_driver);

MODULE_DESCRIPTION("Realtek RTL819x PCIe host controller");
MODULE_LICENSE("GPL");
