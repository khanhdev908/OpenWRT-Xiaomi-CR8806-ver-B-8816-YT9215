#!/usr/bin/env bash
# =============================================================================
#  port-cr8816.sh - Them thiet bi "xiaomi_cr8816" vao ma nguon fanha99
#
#  Phan cung (doc tu firmware goc cua Tony):
#    - bdata: model=CR8816 ; /etc/config/misc: hardware model CR8816
#    - Switch: Motorcomm YT9215S (kmod-yt-9215s-driver / yt_switch.ko tren
#      /soc/mdio@90000), KHONG phai QCA8337 nhu CR8806 -> qca8k bao
#      "Switch id detected ff but expected 13".
#    - /etc/config/port_map: LAN "1","2","3" = phy 0,1,2 ; "WAN" = phy 3
#    - DTB goc: MAC1 -> uniphy SGMII (switch_mac_mode 0x0f) -> switch ;
#      reset switch = GPIO 26 (phy-reset-gpio cua mdio@90000)
#    - Kernel 6.18 cua fanha99 da co driver DSA yt921x (backport 967-*),
#      chi chua bat trong config.
#
#  Cach dung:  port-cr8816.sh <thu-muc-openwrt>
#  Chay lai nhieu lan van an toan.
# =============================================================================
set -Eeuo pipefail
SRC="${1:?port-cr8816.sh <thu-muc-openwrt>}"
cd "$SRC"
T=target/linux/qualcommax
[ -f "$T/dts/ipq5018-cr880x.dtsi" ] || { echo "Khong thay $T/dts/ipq5018-cr880x.dtsi" >&2; exit 1; }

# --- 1. DTS -------------------------------------------------------------------
# Khong ghi de neu da co (giu block sua ECC/OPP ma build-cr8806.sh them vao)
# Toc do CPU <-> switch: 2500 (giong firmware goc, switch_mac_mode 0x0c) hoac 1000
CPU_SPEED="${CPU_SPEED:-2500}"
if [ "$CPU_SPEED" = 2500 ]; then CPU_MODE=2500base-x; else CPU_MODE=sgmii; fi
DTSF="$T/dts/ipq5018-cr8816.dts"
if ! grep -q 'cr8816-v2' "$DTSF" 2>/dev/null; then
cat >"$DTSF" <<'DTS'
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT
/*
 * Xiaomi CR8816 (M79 doi moi): giong CR8806 nhung switch la Motorcomm
 * YT9215S thay cho QCA8337. Giu compatible "xiaomi,cr8816" truoc,
 * "xiaomi,cr8806" sau.
 */

/dts-v1/;

#include "ipq5018-cr880x.dtsi"

/ {
	model = "Xiaomi CR8816 (M79, YT9215S)";
	compatible = "xiaomi,cr8816", "xiaomi,cr8806", "qcom,ipq5018";
};

&qpic_nand {
	nand@0 {
		partitions {
			compatible = "qcom,smem-part";

			partition-art {
				label = "0:art";
				read-only;

				nvmem-layout {
					compatible = "fixed-layout";
					#address-cells = <1>;
					#size-cells = <1>;

					macaddr_art_0: mac-address@0 {
						compatible = "mac-base";
						reg = <0x0 0x6>;
						#nvmem-cell-cells = <1>;
					};

					macaddr_art_6: mac-address@6 {
						compatible = "mac-base";
						reg = <0x6 0x6>;
						#nvmem-cell-cells = <1>;
					};
				};
			};
		};
	};
};

/*
 * Bo QCA8337 cua cr880x.dtsi. GMAC0 + GE PHY noi thang vao YT9215 port 4
 * (nhu CR8806 noi vao PHY4 cua QCA8337); o day chua dung, chi de lam
 * netdev eth0 roi.
 */
&mdio1 {
	/* GPIO 26 tren CR8816 la LED net_blue, khong phai reset switch */
	/delete-property/ reset-gpios;
	/delete-node/ ethernet-switch@17;
	/delete-node/ ethernet-phy@0;
	/delete-node/ ethernet-phy@1;
	/delete-node/ ethernet-phy@2;
	/delete-node/ ethernet-phy@3;
	/delete-node/ ethernet-phy@4;

	switch1: switch@1d {
		compatible = "motorcomm,yt9215";
		/* dia chi SMI mac dinh 0x1d (strap khac: 0x0) */
		reg = <0x1d>;

		mdio {
			#address-cells = <1>;
			#size-cells = <0>;

			yt_phy0: phy@0 { reg = <0>; };
			yt_phy1: phy@1 { reg = <1>; };
			yt_phy2: phy@2 { reg = <2>; };
			yt_phy3: phy@3 { reg = <3>; };
		};

		ethernet-ports {
			#address-cells = <1>;
			#size-cells = <0>;

			ethernet-port@0 {
				reg = <0>;
				label = "lan1";
				phy-mode = "internal";
				phy-handle = <&yt_phy0>;
			};

			ethernet-port@1 {
				reg = <1>;
				label = "lan2";
				phy-mode = "internal";
				phy-handle = <&yt_phy1>;
			};

			ethernet-port@2 {
				reg = <2>;
				label = "lan3";
				phy-mode = "internal";
				phy-handle = <&yt_phy2>;
			};

			ethernet-port@3 {
				reg = <3>;
				label = "wan";
				phy-mode = "internal";
				phy-handle = <&yt_phy3>;
			};

			/* CPU: GMAC1 -> uniphy -> YT9215 EXT0 (port 8) */
			ethernet-port@8 {
				reg = <8>;
				phy-mode = "@CPU_MODE@";
				ethernet = <&gmac1>;

				fixed-link {
					speed = <@CPU_SPEED@>;
					full-duplex;
				};
			};
		};
	};
};

/* cr8816-v2: GPIO theo DTB goc config@mp03.3 (U-Boot chon theo machid 0x8040002) */
&gmac1 {
	phy-mode = "@CPU_MODE@";
	fixed-link {
		speed = <@CPU_SPEED@>;
	};
};

/* UART that o GPIO 20/21 (cr880x.dtsi dung 28/29 cua CR8806 -> console khong go duoc) */
&serial_0_pins {
	pins = "gpio20", "gpio21";
	function = "blsp0_uart0";
};

/* LED: 24 sys_blue, 25 sys_red, 26 net_blue, 27 net_red */
&led_pins {
	pins = "gpio24", "gpio25", "gpio26", "gpio27";
};
&led_system_blue { gpios = <&tlmm 24 GPIO_ACTIVE_HIGH>; };
&led_system_yellow { gpios = <&tlmm 25 GPIO_ACTIVE_HIGH>; };
&led_internet_blue { gpios = <&tlmm 26 GPIO_ACTIVE_HIGH>; };
&led_internet_yellow { gpios = <&tlmm 27 GPIO_ACTIVE_HIGH>; };

/* Nut: mesh GPIO 28, reset GPIO 38 */
&button_pins {
	pins = "gpio28", "gpio38";
};
/ {
	keys {
		reset-button { gpios = <&tlmm 38 GPIO_ACTIVE_LOW>; };
		mesh-button { gpios = <&tlmm 28 GPIO_ACTIVE_LOW>; };
	};
};
DTS
fi
sed -i "s/@CPU_MODE@/$CPU_MODE/g; s/@CPU_SPEED@/$CPU_SPEED/g" "$DTSF"

# --- 2. Device profile -------------------------------------------------------
MK="$T/image/ipq50xx.mk"
if ! grep -q 'define Device/xiaomi_cr8816' "$MK"; then
  gawk '
    { print }
    /^TARGET_DEVICES \+= xiaomi_cr8806$/ {
      print ""
      print "define Device/xiaomi_cr8816"
      print "\t$(call Device/FitImage)"
      print "\t$(call Device/UbiFit)"
      print "\tDEVICE_VENDOR := Xiaomi"
      print "\tDEVICE_MODEL := CR8816"
      print "\tDEVICE_VARIANT := YT9215S switch"
      print "\tDEVICE_DTS_CONFIG := config@mp03.3"
      print "\tSOC := ipq5018"
      print "\tBLOCKSIZE := 128k"
      print "\tPAGESIZE := 2048"
      print "\tNAND_SIZE := 128m"
      print "\tSUPPORTED_DEVICES += xiaomi,cr8806"
      print "\tDEVICE_PACKAGES := \\"
      print "\t\tath11k-firmware-ipq5018-qcn6122 \\"
      print "\t\tipq-wifi-xiaomi_cr8806 \\"
      print "\t\t-kmod-usb3 -kmod-usb-dwc3 -kmod-usb-dwc3-qcom \\"
      print "\t\t-kmod-fs-ext4 -e2fsprogs -losetup"
      print "endef"
      print "TARGET_DEVICES += xiaomi_cr8816"
    }' "$MK" >"$MK.tmp" && mv "$MK.tmp" "$MK"
fi

# --- 3. Kernel config: driver DSA yt921x --------------------------------------
CFG="$T/ipq50xx/config-default"
for sym in CONFIG_NET_DSA_YT92XX CONFIG_NET_DSA_TAG_YT921X; do
  sed -i "/^# $sym is not set/d;/^$sym=/d" "$CFG"
  echo "$sym=y" >>"$CFG"
done

# --- 4. Board name trong base-files -------------------------------------------
BF="$T/ipq50xx/base-files"
for f in "$BF/etc/hotplug.d/firmware/11-ath11k-caldata" \
         "$BF/etc/board.d/01_leds" \
         "$BF/etc/uci-defaults/15_cr8806_ecm_gro_list" \
         "$BF/lib/upgrade/platform.sh" \
         package/boot/uboot-tools/uboot-envtools/files/qualcommax_ipq50xx; do
  [ -f "$f" ] || continue
  grep -q 'xiaomi,cr8816' "$f" && continue
  sed -i 's/xiaomi,cr8806\([|)]\)/xiaomi,cr8806|xiaomi,cr8816\1/g' "$f"
done
# 02_network: 1 CPU port (eth1), khong tach wan sang eth0
NET="$BF/etc/board.d/02_network"
if ! grep -q 'xiaomi,cr8816' "$NET"; then
  gawk '
    !done && /^\txiaomi,cr8806\|\\$/ {
      print "\txiaomi,cr8816)"
      print "\t\tucidef_set_interfaces_lan_wan \"lan1 lan2 lan3\" \"wan\""
      print "\t\t;;"
      done=1
    }
    { print }' "$NET" >"$NET.tmp" && mv "$NET.tmp" "$NET"
fi

echo "[port-cr8816] xong:"
echo "  $T/dts/ipq5018-cr8816.dts"
grep -n 'xiaomi_cr8816' "$MK" | head -2
grep -n 'YT921X' "$CFG"
grep -rln 'xiaomi,cr8816' "$BF" package/boot/uboot-tools/uboot-envtools/files/qualcommax_ipq50xx
