/* SPDX-License-Identifier: GPL-2.0 */
/*
 * rtl_pci_dbg.h - issue #99 debug counters for the rtlwifi PCI ISR.
 *
 * The RTL8192EE's INTA storms at ~130 kHz the moment an AP interface starts
 * (measured: INTC GIMR bit 21 dispatched 5.3M times, +131k/s, every entry
 * non-empty). These counters, bumped from _rtl_pci_interrupt() and the 8192ee
 * interrupt ops, are read by the rtl819x timer-ISR probe so the storming
 * branch can be named without any console I/O in the ISR itself.
 * Temporary; goes out with the rest of the issue #99 instrumentation.
 */
#ifndef _LINUX_RTL_PCI_DBG_H
#define _LINUX_RTL_PCI_DBG_H
#include <linux/types.h>

struct rtl_pci_dbg_counters {
	u32 isr_calls;		/* _rtl_pci_interrupt() entries */
	u32 not_enabled;	/* returned early: rtlpci->irq_enabled == 0 */
	u32 spurious;		/* inta == 0 or 0xffff */
	u32 rdu, rok, rxfovw, bcnint;
	u32 last_inta, last_intb, or_inta, or_intb;
	u32 rx_remained0;	/* RX path entered with nothing to process */
	u32 enable_calls, disable_calls;
	/* snapshot of the chip on the first irq_enabled==0 entries, and every
	 * status bit the quiesce path had to clear (OR over all entries) */
	u32 ne_hisr, ne_himr, ne_hisre, ne_himre, ne_cleared;
};
extern struct rtl_pci_dbg_counters rtl_pci_dbg;

#endif
