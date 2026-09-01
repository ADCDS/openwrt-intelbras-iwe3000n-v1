// SPDX-License-Identifier: GPL-2.0
/*
 * PCIe host controller for Realtek RTL819x SoCs (RTL8196E and relatives).
 *
 * The RTL8196E's on-board Wi-Fi is a PCIe device -- 10ec:818b, an RTL8192EE,
 * which mainline has driven since 3.16. What mainline lacks is any way to bring
 * up the SoC's PCIe host, so CONFIG_PCI is normally off on these boards and the
 * radio is unreachable. Realtek's own stack hides this by doing the host
 * bring-up inside the *wireless* driver, which is why a stock boot prints its
 * PCIe discovery line from a wifi module.
 *
 * The register sequence below is from arch/rlx/soc-rtl8196e/pci.c in
 * lekswrt/rtl8196e -- the RTL8196E's own kernel code, not the wireless driver's
 * bring-up for other SoCs. That distinction cost a lot of debugging: the wifi
 * driver's branches use a different PERST (GPIO rather than CLK_MANAGE bit 26),
 * a different MDIO reset register (0x3c rather than 0x50), and crucially they
 * omit the PCIe IP enable entirely.
 *
 * Every value here was verified on an Intelbras IWE 3000N by poking the
 * registers with devmem before it was written into this file. The end state is
 * LTSSM 0x11 and config dword 0 reading 0x818b10ec.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_pci.h>
#include <linux/pci.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#define DRV_NAME "rtl819x-pcie"

/*
 * System controller. CLK_MANAGE carries the PCIe IP enable, the RTL8196E's
 * extra clock bits and PERST -- all three in one register.
 */
#define RTL819X_SYSC_CLK_MANAGE		0x0010
#define  RTL819X_ACTIVE_PCIE0		BIT(14)	/* "first, Turn On PCIE IP" */
#define  RTL819X_8196E_CLK_BITS		(BIT(12) | BIT(13) | BIT(18))
#define  RTL819X_PERST			BIT(26)	/* not a GPIO */
#define RTL819X_SYSC_PCIE0_PHY		0x0050	/* MDIO reset; not 0x3c */
#define  RTL819X_MDIO_BIT3		BIT(3)
#define  RTL819X_MDIO_RST		BIT(0)
#define  RTL819X_MDIO_LOAD_DONE		BIT(1)

/* PCIe block, "RC extended" register window. */
#define RTL819X_MDIO_CMD		0x0000	/* write-triggered */
#define  RTL819X_MDIO_REG_SHIFT		8
#define  RTL819X_MDIO_DATA_SHIFT	16
#define  RTL819X_MDIO_WRITE		BIT(0)
#define RTL819X_PHY_PWRCR		0x0008
#define  RTL819X_PHY_LTSSM_EN		BIT(0)
#define  RTL819X_PHY_RESET_N		BIT(7)

/* Root-complex config space; LTSSM state lives above the standard header. */
#define RTL819X_RC_LTSSM		0x0728
#define  RTL819X_LTSSM_STATE		GENMASK(4, 0)
#define  RTL819X_LTSSM_L0		0x11

#define RTL819X_SETTLE_MS		10

struct rtl819x_pcie {
	struct device *dev;
	void __iomem *rc_cfg;		/* root complex config space  */
	void __iomem *dev_cfg;		/* downstream device config   */
	void __iomem *phy;		/* PHY + MDIO command window  */
	struct regmap *sysc;
	u8 rc_bus;
};

/*
 * PHY initialisation table, RTL8196E, 40 MHz reference clock.
 *
 * Taken from arch/rlx/soc-rtl8196e/pci.c under CONFIG_PHY_EAT_40MHZ. 40 MHz is
 * right for this board because the stock firmware's own boot log says so:
 * "98 - 40MHz Clock Source". A 25 MHz board wants reg 6 = 0xf848 and no reg 5.
 */
static const struct {
	u8 reg;
	u16 val;
} rtl819x_phy_init[] = {
	{ 0x00, 0xd087 }, { 0x01, 0x0003 }, { 0x02, 0x4d18 }, { 0x05, 0x0bcb },
	{ 0x06, 0xf148 }, { 0x07, 0x31ff }, { 0x08, 0x18d5 }, { 0x09, 0x539c },
	{ 0x0a, 0x20eb }, { 0x0d, 0x1766 }, { 0x0b, 0x0711 }, { 0x0f, 0x0a00 },
	{ 0x19, 0xfce0 }, { 0x1a, 0x7e4f }, { 0x1b, 0xfc01 }, { 0x1e, 0xc280 },
};

static void rtl819x_mdio_write(struct rtl819x_pcie *pcie, u8 reg, u16 val)
{
	/*
	 * Write-triggered: there is nothing to read back, and a read returns 0
	 * whatever was written. Early debugging treated that zero as evidence
	 * the block was dead; it is not.
	 */
	writel(((reg & 0x1f) << RTL819X_MDIO_REG_SHIFT) |
	       ((u32)val << RTL819X_MDIO_DATA_SHIFT) |
	       RTL819X_MDIO_WRITE,
	       pcie->phy + RTL819X_MDIO_CMD);
	udelay(100);
}

static int rtl819x_pcie_power_on(struct rtl819x_pcie *pcie)
{
	unsigned int i;
	int ret;

	/*
	 * 1. Turn the PCIe IP on. Until this happens the whole 0x18b0_xxxx
	 *    window is undecoded: writes are dropped and reads return 0, which
	 *    on this SoC is indistinguishable from a register that exists and
	 *    holds zero. Everything else is pointless without it.
	 */
	ret = regmap_update_bits(pcie->sysc, RTL819X_SYSC_CLK_MANAGE,
				 RTL819X_ACTIVE_PCIE0 | RTL819X_8196E_CLK_BITS,
				 RTL819X_ACTIVE_PCIE0 | RTL819X_8196E_CLK_BITS);
	if (ret)
		return ret;

	/* 2. PERST, same register, bit 26. */
	ret = regmap_update_bits(pcie->sysc, RTL819X_SYSC_CLK_MANAGE,
				 RTL819X_PERST, RTL819X_PERST);
	if (ret)
		return ret;
	msleep(RTL819X_SETTLE_MS);

	/* 3. MDIO reset: assert, release, then flag the load as done. */
	regmap_write(pcie->sysc, RTL819X_SYSC_PCIE0_PHY, RTL819X_MDIO_BIT3);
	regmap_write(pcie->sysc, RTL819X_SYSC_PCIE0_PHY,
		     RTL819X_MDIO_BIT3 | RTL819X_MDIO_RST);
	regmap_write(pcie->sysc, RTL819X_SYSC_PCIE0_PHY,
		     RTL819X_MDIO_BIT3 | RTL819X_MDIO_LOAD_DONE |
		     RTL819X_MDIO_RST);
	msleep(RTL819X_SETTLE_MS);

	/* 4. Program the PHY. */
	for (i = 0; i < ARRAY_SIZE(rtl819x_phy_init); i++)
		rtl819x_mdio_write(pcie, rtl819x_phy_init[i].reg,
				   rtl819x_phy_init[i].val);
	msleep(RTL819X_SETTLE_MS);

	/* 5. PHY out of reset, LTSSM enabled. */
	writel(RTL819X_PHY_LTSSM_EN, pcie->phy + RTL819X_PHY_PWRCR);
	msleep(RTL819X_SETTLE_MS);
	writel(RTL819X_PHY_LTSSM_EN | RTL819X_PHY_RESET_N,
	       pcie->phy + RTL819X_PHY_PWRCR);
	msleep(RTL819X_SETTLE_MS);

	return 0;
}

static int rtl819x_pcie_wait_link(struct rtl819x_pcie *pcie)
{
	u32 val;
	int ret;

	ret = readl_poll_timeout(pcie->rc_cfg + RTL819X_RC_LTSSM, val,
				 (val & RTL819X_LTSSM_STATE) == RTL819X_LTSSM_L0,
				 10 * USEC_PER_MSEC, USEC_PER_SEC);
	if (ret) {
		u32 st = val & RTL819X_LTSSM_STATE;

		dev_err(pcie->dev, "link training failed, LTSSM = 0x%02x\n", st);
		if (!st)
			dev_err(pcie->dev,
				"LTSSM reads 0 -- the PCIe block is not decoding; is the IP enabled?\n");
		return ret;
	}
	return 0;
}

/*
 * Config access. Each config space is a flat window rather than the usual
 * address/data pair, so this is just pointer arithmetic. Only device 0 exists
 * on each bus: the root port on the primary bus, the RTL8192EE behind it.
 */
static void __iomem *rtl819x_pcie_map_bus(struct pci_bus *bus,
					  unsigned int devfn, int where)
{
	struct rtl819x_pcie *pcie = bus->sysdata;

	if (PCI_SLOT(devfn) || PCI_FUNC(devfn))
		return NULL;
	if (bus->number == pcie->rc_bus)
		return pcie->rc_cfg + where;
	if (bus->number == pcie->rc_bus + 1)
		return pcie->dev_cfg + where;
	return NULL;
}

/*
 * 32-bit accesses only. With the byte/word accessors the root port's header
 * type register read back as 0x10 -- not a valid header type at all -- and the
 * PCI core logged "unknown header type 16, ignoring device" and refused to
 * enumerate anything behind it. The _32 variants read the containing dword and
 * shift, which this config window is happy with.
 */
static struct pci_ops rtl819x_pcie_ops = {
	.map_bus = rtl819x_pcie_map_bus,
	.read	 = pci_generic_config_read32,
	.write	 = pci_generic_config_write32,
};

static int rtl819x_pcie_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct pci_host_bridge *bridge;
	struct rtl819x_pcie *pcie;
	u32 id;
	int ret;

	bridge = devm_pci_alloc_host_bridge(dev, sizeof(*pcie));
	if (!bridge)
		return -ENOMEM;

	pcie = pci_host_bridge_priv(bridge);
	pcie->dev = dev;

	pcie->rc_cfg = devm_platform_ioremap_resource_byname(pdev, "rc-cfg");
	if (IS_ERR(pcie->rc_cfg))
		return PTR_ERR(pcie->rc_cfg);

	pcie->dev_cfg = devm_platform_ioremap_resource_byname(pdev, "dev-cfg");
	if (IS_ERR(pcie->dev_cfg))
		return PTR_ERR(pcie->dev_cfg);

	pcie->phy = devm_platform_ioremap_resource_byname(pdev, "phy");
	if (IS_ERR(pcie->phy))
		return PTR_ERR(pcie->phy);

	pcie->sysc = syscon_regmap_lookup_by_phandle(dev->of_node,
						     "realtek,syscon");
	if (IS_ERR(pcie->sysc))
		return dev_err_probe(dev, PTR_ERR(pcie->sysc),
				     "no realtek,syscon phandle: the PCIe IP enable lives there\n");

	ret = rtl819x_pcie_power_on(pcie);
	if (ret)
		return ret;

	ret = rtl819x_pcie_wait_link(pcie);
	if (ret)
		return ret;

	id = readl(pcie->dev_cfg);
	dev_info(dev, "link up, downstream device %04x:%04x\n",
		 id & 0xffff, id >> 16);
	if (id == 0xffffffff || !id)
		return dev_err_probe(dev, -ENODEV,
				     "link trained but config space reads 0x%08x\n", id);

	bridge->sysdata = pcie;
	bridge->ops = &rtl819x_pcie_ops;

	ret = pci_host_probe(bridge);
	if (ret)
		return ret;

	pcie->rc_bus = bridge->bus->number;
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
