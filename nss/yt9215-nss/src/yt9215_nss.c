// SPDX-License-Identifier: GPL-2.0-only
/*
 * yt9215_nss.c - re-arm a Motorcomm YT9215 as a plain 802.1Q fabric after
 * the yt921x DSA driver has been unbound, so the IPQ50xx NSS firmware can
 * own the trunk GMAC (it cannot parse the YT921x CPU tag).
 *
 * Written for the Xiaomi CR8816 (IPQ5018 + YT9215S at MDIO 0x1d on mdio1,
 * front PHYs on ports 0-3 = lan1, lan2, lan3, wan; port 8 = EXT0 SerDes in
 * 2500base-x to GMAC1).
 *
 * Instead of undoing what DSA did piece by piece, the switch gets a hardware
 * reset (the same reset yt921x itself does at probe), which puts it back in
 * its unmanaged power-on state: CPU tag off, learning on, every port
 * forwarding, front MACs following their PHYs. Then it does exactly what
 * yt921x does to bring the CPU SerDes up (port_config + port_up for a
 * fixed 2500base-x link), and programs the VLAN split:
 *
 *   vlans="1:8t,0u,1u,2u;2:8t,3u"   (default)
 *
 * PVIDs follow each port's untagged VLAN, ingress is VLAN-aware with
 * membership filtering, so WAN and LAN never mix. A bus error anywhere
 * leaves every port in STP disabled and fails the load.
 *
 * identify=1 only checks the chip ID, for the service to ask before it
 * unbinds the DSA driver. dump=1 prints port/SerDes state and returns
 * -EAGAIN without changing anything.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/delay.h>
#include <linux/phy.h>
#include <linux/mii.h>
#include <linux/string.h>
#include <linux/bits.h>
#include <linux/bitfield.h>

/* SMI framing (yt921x.h) */
#define SMI_ADDR_W		0x0	/* switchid 0, addr, write */
#define SMI_ADDR_R		0x1	/* switchid 0, addr, read */
#define SMI_DATA_W		0x2
#define SMI_DATA_R		0x3

#define YT_RST			0x80000
#define  YT_RST_HW		BIT(31)
#define YT_FUNC			0x80004
#define  YT_FUNC_MIB		BIT(1)
#define YT_CHIP_ID		0x80008
#define  YT9215_MAJOR		0x9002
#define YT_EXT_CPU_PORT		0x8000c
#define YT_SERDES_CTRL		0x80028
#define YT_SERDESn(p)		(0x8008c + 4 * ((p) - 8))
#define  SERDES_MODE_M		GENMASK(9, 7)
#define  SERDES_MODE_1000BASEX	(2 << 7)
#define  SERDES_MODE_2500BASEX	(4 << 7)
#define  SERDES_RX_PAUSE	BIT(6)
#define  SERDES_TX_PAUSE	BIT(5)
#define  SERDES_LINK		BIT(4)
#define  SERDES_DUPLEX		BIT(3)
#define  SERDES_SPEED_M		GENMASK(2, 0)
#define YT_PORTn_CTRL(p)	(0x80100 + 4 * (p))
#define YT_PORTn_STATUS(p)	(0x80200 + 4 * (p))
#define  PORT_PAUSE_AN		BIT(10)
#define  PORT_LINK_AN		BIT(9)	/* CTRL: MAC follows PHY; STATUS: link */
#define  PORT_DUPLEX		BIT(7)
#define  PORT_RX_PAUSE		BIT(6)
#define  PORT_TX_PAUSE		BIT(5)
#define  PORT_RX_MAC_EN		BIT(4)
#define  PORT_TX_MAC_EN		BIT(3)
#define  PORT_SPEED_M		GENMASK(2, 0)
#define YT_MDIO_POLLINGn(p)	(0x80364 + 4 * ((p) - 8))
#define  POLL_DUPLEX		BIT(4)
#define  POLL_LINK		BIT(3)
#define YT_XMII_CTRL		0x80394
#define YT_XMIIn(p)		(0x80400 + 8 * ((p) - 8))
#define  XMII_LINK		BIT(19)

#define YT_INT_MBUS_OP		0xf0000
#define  MBUS_OP_START		BIT(0)
#define YT_INT_MBUS_CTRL	0xf0004
#define  MBUS_CTRL_PORT_M	GENMASK(25, 21)
#define  MBUS_CTRL_REG_M	GENMASK(20, 16)
#define  MBUS_CTRL_OP_M		GENMASK(3, 2)
#define  MBUS_CTRL_WRITE	(1 << 2)
#define  MBUS_CTRL_READ		(2 << 2)
#define YT_INT_MBUS_DOUT	0xf0008
#define YT_INT_MBUS_DIN		0xf000c

#define YT_VLAN_IGR_FILTER	0x180280
#define YT_PORTn_ISOLATION(p)	(0x180294 + 4 * (p))
#define YT_STP0			0x18038c
#define YT_PORTn_LEARN(p)	(0x1803d0 + 4 * (p))
#define  LEARN_DIS		BIT(17)
#define YT_CPU_COPY		0x180690
#define YT_ACT_UNK_UCAST	0x180734
#define YT_ACT_UNK_MCAST	0x180738
#define YT_VLANn_CTRL(v)	(0x188000 + 8 * (v))
#define YT_PORTn_IGR_TPID(p)	(0x210010 + 4 * (p))
#define YT_PORTn_VLAN_CTRL(p)	(0x230010 + 4 * (p))
#define  PVID_M			GENMASK(17, 6)
#define YT_PORTn_VLAN_CTRL1(p)	(0x230080 + 4 * (p))

#define YT_NPORTS		11

static char *bus_id = "90000.mdio-1";
module_param(bus_id, charp, 0444);
MODULE_PARM_DESC(bus_id, "MDIO bus holding the switch");

static int sw_addr = 0x1d;
module_param(sw_addr, int, 0444);
MODULE_PARM_DESC(sw_addr, "switch SMI address");

static int trunk_port = 8;
module_param(trunk_port, int, 0444);
MODULE_PARM_DESC(trunk_port, "switch SerDes port carrying the trunk (8 or 9)");

static int trunk_speed = 2500;
module_param(trunk_speed, int, 0444);
MODULE_PARM_DESC(trunk_speed, "trunk speed, 2500 (2500base-x) or 1000 (1000base-x)");

static bool pause = true;
module_param(pause, bool, 0444);
MODULE_PARM_DESC(pause, "flow control on the trunk");

static char *phys = "0,1,2,3";
module_param(phys, charp, 0444);
MODULE_PARM_DESC(phys, "internal PHYs to wake");

static char *vlans = "1:8t,0u,1u,2u;2:8t,3u";
module_param(vlans, charp, 0444);
MODULE_PARM_DESC(vlans, "VLAN program, e.g. 1:8t,0u,1u,2u;2:8t,3u");

static bool reset = true;
module_param(reset, bool, 0444);
MODULE_PARM_DESC(reset, "hardware-reset the switch before programming it");

static bool identify;
module_param(identify, bool, 0444);
MODULE_PARM_DESC(identify, "only check the chip ID");

static bool dump;
module_param(dump, bool, 0444);
MODULE_PARM_DESC(dump, "print port state and change nothing");

static struct mii_bus *bus;
static int yt_error;
static u16 used_ports;	/* every port named in vlans */
static u16 first_vid = 1;

static void yt_fail(int ret)
{
	if (ret < 0 && !yt_error)
		yt_error = ret;
}

static int yt_read(u32 reg, u32 *val)
{
	int ret, hi, lo;

	mutex_lock(&bus->mdio_lock);
	ret = __mdiobus_write(bus, sw_addr, SMI_ADDR_R, reg >> 16);
	if (!ret)
		ret = __mdiobus_write(bus, sw_addr, SMI_ADDR_R, reg & 0xffff);
	hi = ret ? ret : __mdiobus_read(bus, sw_addr, SMI_DATA_R);
	lo = hi < 0 ? hi : __mdiobus_read(bus, sw_addr, SMI_DATA_R);
	mutex_unlock(&bus->mdio_lock);

	if (lo < 0) {
		yt_fail(lo);
		*val = 0;
		return lo;
	}
	*val = ((u32)hi << 16) | (u16)lo;
	return 0;
}

static int yt_write(u32 reg, u32 val)
{
	int ret;

	mutex_lock(&bus->mdio_lock);
	ret = __mdiobus_write(bus, sw_addr, SMI_ADDR_W, reg >> 16);
	if (!ret)
		ret = __mdiobus_write(bus, sw_addr, SMI_ADDR_W, reg & 0xffff);
	if (!ret)
		ret = __mdiobus_write(bus, sw_addr, SMI_DATA_W, val >> 16);
	if (!ret)
		ret = __mdiobus_write(bus, sw_addr, SMI_DATA_W, val & 0xffff);
	mutex_unlock(&bus->mdio_lock);

	yt_fail(ret);
	return ret;
}

static void yt_update(u32 reg, u32 mask, u32 val)
{
	u32 old, new;

	if (yt_read(reg, &old))
		return;
	new = (old & ~mask) | (val & mask);
	if (new != old)
		yt_write(reg, new);
}

static int yt_mbus_wait(void)
{
	u32 v;
	int i;

	for (i = 0; i < 100; i++) {
		if (yt_read(YT_INT_MBUS_OP, &v))
			return -EIO;
		if (!(v & MBUS_OP_START))
			return 0;
		usleep_range(100, 200);
	}
	yt_fail(-ETIMEDOUT);
	return -ETIMEDOUT;
}

static int yt_phy_read(int phy, int reg, u16 *val)
{
	u32 v;

	if (yt_mbus_wait())
		return -EIO;
	yt_update(YT_INT_MBUS_CTRL, MBUS_CTRL_PORT_M | MBUS_CTRL_REG_M | MBUS_CTRL_OP_M,
		  FIELD_PREP(MBUS_CTRL_PORT_M, phy) | FIELD_PREP(MBUS_CTRL_REG_M, reg) |
		  MBUS_CTRL_READ);
	yt_write(YT_INT_MBUS_OP, MBUS_OP_START);
	if (yt_mbus_wait() || yt_read(YT_INT_MBUS_DIN, &v))
		return -EIO;
	*val = v;
	return 0;
}

static int yt_phy_write(int phy, int reg, u16 val)
{
	if (yt_mbus_wait())
		return -EIO;
	yt_update(YT_INT_MBUS_CTRL, MBUS_CTRL_PORT_M | MBUS_CTRL_REG_M | MBUS_CTRL_OP_M,
		  FIELD_PREP(MBUS_CTRL_PORT_M, phy) | FIELD_PREP(MBUS_CTRL_REG_M, reg) |
		  MBUS_CTRL_WRITE);
	yt_write(YT_INT_MBUS_DOUT, val);
	yt_write(YT_INT_MBUS_OP, MBUS_OP_START);
	return yt_mbus_wait();
}

static void yt_stp_all(u32 state)
{
	u32 mask = 0, val = 0;
	int p;

	for (p = 0; p < YT_NPORTS; p++) {
		if (!(used_ports & BIT(p)))
			continue;
		mask |= 3u << (2 * p);
		val |= state << (2 * p);
	}
	yt_update(YT_STP0, mask, val);
}

static void yt_dump(const char *when)
{
	u32 ctrl, st, sds = 0, ext = 0;
	int p;

	yt_read(YT_EXT_CPU_PORT, &ext);
	if (trunk_port >= 8)
		yt_read(YT_SERDESn(trunk_port), &sds);
	pr_info("yt9215-nss: [%s] EXT_CPU_PORT 0x%08x SERDES%d 0x%08x\n",
		when, ext, trunk_port, sds);
	for (p = 0; p < YT_NPORTS; p++) {
		if (!(used_ports & BIT(p)))
			continue;
		yt_read(YT_PORTn_CTRL(p), &ctrl);
		yt_read(YT_PORTn_STATUS(p), &st);
		pr_info("yt9215-nss: [%s] port %d ctrl 0x%04x status 0x%04x (%s, speed %lu, %s)\n",
			when, p, ctrl, st, st & PORT_LINK_AN ? "up" : "down",
			FIELD_GET(PORT_SPEED_M, st), st & PORT_DUPLEX ? "full" : "half");
	}
}

/* "1:8t,0u,1u,2u;2:8t,3u" -> VLAN entries, PVIDs */
static int yt_parse_vlans(bool apply)
{
	char buf[256], *s, *blk, *tok, *end;
	u16 pvid[YT_NPORTS] = { 0 };
	int p;

	strscpy(buf, vlans, sizeof(buf));
	s = buf;
	while ((blk = strsep(&s, ";")) != NULL) {
		u32 vid, members = 0, untag = 0, a, b;

		if (!*blk)
			continue;
		tok = strsep(&blk, ":");
		if (!blk || kstrtou32(tok, 10, &vid) || vid < 1 || vid > 4094) {
			pr_err("yt9215-nss: bad VLAN block '%s'\n", tok);
			return -EINVAL;
		}
		while ((tok = strsep(&blk, ",")) != NULL) {
			unsigned long port = simple_strtoul(tok, &end, 10);

			if (end == tok || port >= YT_NPORTS ||
			    (*end != 'u' && *end != 't')) {
				pr_err("yt9215-nss: bad port '%s' in VLAN %u\n", tok, vid);
				return -EINVAL;
			}
			members |= BIT(port);
			if (*end == 'u') {
				untag |= BIT(port);
				if (!pvid[port])
					pvid[port] = vid;
			}
		}
		if (!used_ports)
			first_vid = vid;
		used_ports |= members;
		if (!apply)
			continue;
		/* word a: members in 17:7, FID low bits in 31:23; word b:
		 * untagged members in 18:8, FID high bits in 2:0. FID = VID
		 * (independent learning per VLAN).
		 */
		a = (members << 7) | ((vid & 0x1ff) << 23);
		b = (untag << 8) | (vid >> 9);
		yt_write(YT_VLANn_CTRL(vid), a);
		yt_write(YT_VLANn_CTRL(vid) + 4, b);
		pr_info("yt9215-nss: VLAN %u members 0x%03x untagged 0x%03x\n",
			vid, members, untag);
	}

	if (!apply)
		return 0;

	for (p = 0; p < YT_NPORTS; p++) {
		u16 v;

		if (!(used_ports & BIT(p)))
			continue;
		/* the trunk carries everything tagged; an untagged frame from
		 * the host lands in the first VLAN listed
		 */
		v = pvid[p] ? pvid[p] : first_vid;
		yt_update(YT_PORTn_VLAN_CTRL(p), PVID_M, FIELD_PREP(PVID_M, v));
		yt_update(YT_PORTn_VLAN_CTRL1(p), 0x3, 0);
		yt_write(YT_PORTn_IGR_TPID(p), BIT(0));	/* C-tag TPID 0 = 0x8100 */
	}
	yt_update(YT_VLAN_IGR_FILTER, 0x7ff, used_ports);
	return 0;
}

static void yt_trunk_up(void)
{
	int p = trunk_port;
	u32 mode, sspeed, pspeed, ctrl;

	if (trunk_speed == 1000) {
		mode = SERDES_MODE_1000BASEX;
		sspeed = 2;
		pspeed = 2;
	} else {
		mode = SERDES_MODE_2500BASEX;
		sspeed = 4;
		pspeed = 4;
	}

	/* yt921x_port_config(): SerDes, not xMII, in the right mode */
	yt_update(YT_SERDES_CTRL, BIT(p - 8), BIT(p - 8));
	yt_update(YT_XMII_CTRL, BIT(9 - p), 0);
	yt_update(YT_SERDESn(p), SERDES_MODE_M, mode);

	/* yt921x_port_up() for a fixed link */
	ctrl = pspeed | PORT_DUPLEX | PORT_RX_MAC_EN | PORT_TX_MAC_EN;
	if (pause)
		ctrl |= PORT_RX_PAUSE | PORT_TX_PAUSE;
	yt_write(YT_PORTn_CTRL(p), ctrl);

	ctrl = sspeed | SERDES_DUPLEX | SERDES_LINK;
	if (pause)
		ctrl |= SERDES_RX_PAUSE | SERDES_TX_PAUSE;
	yt_update(YT_SERDESn(p), SERDES_SPEED_M | SERDES_DUPLEX | SERDES_LINK |
		  SERDES_RX_PAUSE | SERDES_TX_PAUSE, ctrl);
	yt_update(YT_XMIIn(p), XMII_LINK, XMII_LINK);
	yt_write(YT_MDIO_POLLINGn(p), sspeed | POLL_DUPLEX | POLL_LINK);
}

static void yt_wake_phys(void)
{
	char buf[64], *s, *tok;
	unsigned int phy;
	u16 bmcr;

	strscpy(buf, phys, sizeof(buf));
	s = buf;
	while ((tok = strsep(&s, ",")) != NULL) {
		if (!*tok || kstrtouint(tok, 10, &phy) || phy > 7)
			continue;
		if (yt_phy_read(phy, MII_BMCR, &bmcr))
			continue;
		if (bmcr & BMCR_PDOWN) {
			yt_phy_write(phy, MII_BMCR,
				     (bmcr & ~BMCR_PDOWN) | BMCR_ANENABLE | BMCR_ANRESTART);
			pr_info("yt9215-nss: PHY %u woken (BMCR 0x%04x)\n", phy, bmcr);
		}
	}
}

static int __init yt_nss_init(void)
{
	u32 id = 0, v;
	int p, i;

	if (yt_parse_vlans(false))
		return -EINVAL;
	used_ports |= BIT(trunk_port);
	if (trunk_port < 8 || trunk_port > 9)
		return -EINVAL;

	bus = mdio_find_bus(bus_id);
	if (!bus) {
		pr_err("yt9215-nss: no MDIO bus '%s'\n", bus_id);
		return -ENODEV;
	}

	yt_read(YT_CHIP_ID, &id);
	if (yt_error || (id >> 16) != YT9215_MAJOR) {
		pr_err("yt9215-nss: chip id 0x%08x at %s:%02x is not a YT9215 (%d), refusing\n",
		       id, bus_id, sw_addr, yt_error);
		put_device(&bus->dev);
		return -ENODEV;
	}
	pr_info("yt9215-nss: YT9215 chip id 0x%08x on %s:%02x\n", id, bus_id, sw_addr);

	if (identify || dump) {
		if (dump)
			yt_dump("now");
		put_device(&bus->dev);
		return dump ? -EAGAIN : 0;
	}

	yt_dump("before");

	if (reset) {
		yt_write(YT_RST, YT_RST_HW);
		msleep(20);
		/* reads may fail while the chip is in reset: only the
		 * outcome counts
		 */
		for (i = 0; i < 100; i++) {
			if (!yt_read(YT_RST, &v) && v == 0)
				break;
			msleep(10);
		}
		yt_error = 0;
		if (i == 100 || yt_read(YT_CHIP_ID, &v) || (v >> 16) != YT9215_MAJOR) {
			pr_err("yt9215-nss: switch did not come back from reset\n");
			goto fail;
		}
	}

	/* nothing forwards while the fabric is half-programmed */
	yt_stp_all(0);

	yt_update(YT_FUNC, YT_FUNC_MIB, YT_FUNC_MIB);
	/* no CPU tag, no CPU copies: port 8 is an ordinary port now */
	yt_write(YT_EXT_CPU_PORT, 0);
	yt_write(YT_CPU_COPY, 0);

	for (p = 0; p < YT_NPORTS; p++) {
		if (!(used_ports & BIT(p)))
			continue;
		yt_write(YT_PORTn_ISOLATION(p), 0);
		yt_update(YT_PORTn_LEARN(p), LEARN_DIS, 0);
		yt_update(YT_ACT_UNK_UCAST, 3u << (2 * p), 0);	/* flood */
		yt_update(YT_ACT_UNK_MCAST, 3u << (2 * p), 0);
		if (p != trunk_port)
			/* front MACs follow their PHYs */
			yt_update(YT_PORTn_CTRL(p),
				  PORT_LINK_AN | PORT_PAUSE_AN | PORT_RX_MAC_EN | PORT_TX_MAC_EN,
				  PORT_LINK_AN | PORT_PAUSE_AN | PORT_RX_MAC_EN | PORT_TX_MAC_EN);
	}

	yt_trunk_up();
	yt_parse_vlans(true);
	yt_wake_phys();

	if (yt_error)
		goto fail;

	yt_stp_all(3);
	if (yt_error)
		goto fail;

	msleep(50);
	yt_dump("after");
	pr_info("yt9215-nss: fabric re-armed: trunk port %d %d Mb/s%s, VLANs %s\n",
		trunk_port, trunk_speed == 1000 ? 1000 : 2500,
		pause ? " +pause" : "", vlans);
	put_device(&bus->dev);
	bus = NULL;
	return 0;

fail:
	pr_err("yt9215-nss: re-arm failed (%d), ports left blocked\n", yt_error);
	yt_error = 0;
	yt_stp_all(0);
	put_device(&bus->dev);
	bus = NULL;
	return -EIO;
}

static void __exit yt_nss_exit(void)
{
}

module_init(yt_nss_init);
module_exit(yt_nss_exit);

MODULE_DESCRIPTION("Re-arm a Motorcomm YT9215 as an 802.1Q fabric after yt921x teardown");
MODULE_LICENSE("GPL");
