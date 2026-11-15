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
HERE="$(cd "$(dirname "$0")" && pwd)"
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

/*
 * QCN6122 tren CR8816: reset GPIO 18 (DTB goc mp03.3: boot-args <2 4 2 0x12 0 0>).
 * cr880x.dtsi dung GPIO 27 cua CR8806 -> userPD2 "USER-PD DOG stalled init".
 */
&q6v5_wcss {
	boot-args = <0x2 4 2 18 0 0>;
};

/* BDF Wi-Fi rieng cua CR8816 (stock bdwlan.b23 / qcn6122 bdwlan.b60) */
&wifi { qcom,ath11k-calibration-variant = "Xiaomi-CR8816"; };
&wifi1 { qcom,ath11k-calibration-variant = "Xiaomi-CR8816"; };

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
      print "\t\t-ipq-wifi-xiaomi_cr8806 \\"
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

# --- 5. board-2.bin Wi-Fi tu firmware goc CR8816 ------------------------------
# board CR8806 (0x90/0x10) lam QCN6122 crash "USER-PD DOG stalled init".
for c in IPQ5018 QCN6122; do
  if [ -f "$HERE/wifi-cr8816/board-2.bin.$c" ]; then
    mkdir -p "files/lib/firmware/ath11k/$c/hw1.0"
    cp "$HERE/wifi-cr8816/board-2.bin.$c" "files/lib/firmware/ath11k/$c/hw1.0/board-2.bin"
  else
    echo "[port-cr8816] CANH BAO: thieu $HERE/wifi-cr8816/board-2.bin.$c" >&2
  fi
done

# --- 6. Danh dau boot thanh cong cho U-Boot Xiaomi --------------------------
# bootmiwifi tang flag_try_sys1_failed moi lan boot; neu khong reset, U-Boot
# co the chuyen sang rootfs_1. Reset ve 0 khi he thong da len.
mkdir -p files/etc/init.d files/etc/rc.d
cat > files/etc/init.d/mi_bootok <<'INIT'
#!/bin/sh /etc/rc.common
START=99
boot() {
	case "$(board_name)" in
	xiaomi,cr8816|xiaomi,cr8806) ;;
	*) return 0 ;;
	esac
	command -v fw_printenv >/dev/null || return 0
	[ "$(fw_printenv -n flag_try_sys1_failed 2>/dev/null)" = 0 ] || fw_setenv flag_try_sys1_failed 0
	[ "$(fw_printenv -n flag_boot_success 2>/dev/null)" = 1 ] || fw_setenv flag_boot_success 1
}
INIT
chmod 755 files/etc/init.d/mi_bootok
ln -sf ../init.d/mi_bootok files/etc/rc.d/S99mi_bootok

# --- 7. Shaping upload khi WAN chi 10/100M -----------------------------------
# CPU<->YT9215 la 2.5G, GMAC khong ho tro pause: xuong cong 100M thi bo dem
# switch tran -> upload con ~6 Mbps. tbf 90% toc do link, burst nho -> ~80 Mbps.
mkdir -p files/etc/hotplug.d/iface
cat > files/etc/hotplug.d/iface/30-cr8816-wanshape <<'HP'
#!/bin/sh
[ "$ACTION" = ifup ] || exit 0
[ "$INTERFACE" = wan ] || [ "$INTERFACE" = wan6 ] || exit 0
. /lib/functions.sh
case "$(board_name)" in xiaomi,cr8816) ;; *) exit 0 ;; esac
[ "$(uci -q get network.globals.cr8816_wanshape)" = 0 ] && exit 0
command -v tc >/dev/null || exit 0
dev=wan
sp=$(cat /sys/class/net/$dev/speed 2>/dev/null)
case "$sp" in ''|-1|*[!0-9]*) exit 0 ;; esac
if [ "$sp" -le 100 ]; then
	tc qdisc replace dev $dev root tbf rate $((sp * 9 / 10))mbit burst 4k latency 50ms
	logger -t cr8816 "wan ${sp}M: upload shaping $((sp * 9 / 10))mbit"
else
	tc qdisc show dev $dev | grep -q tbf && tc qdisc del dev $dev root
fi
exit 0
HP

# --- 8. NSS thu nghiem: switch YT9215 lam fabric 802.1Q (topology vlan-trunk) -
# yt921x (DSA) bi unbind luc boot, yt9215-nss reset switch, tat CPU tag, chia
# VLAN 1 = lan1-3 (port 0-2), VLAN 2 = wan (port 3), trunk port 8 tagged ->
# eth1.1 / eth1.2. Tat bang CR8816_NSS=0.
if [ "${CR8816_NSS:-1}" = 1 ]; then
  rm -rf package/kernel/yt9215-nss
  cp -r "$HERE/nss/yt9215-nss" package/kernel/yt9215-nss
  grep -q 'kmod-yt9215-nss' "$MK" ||
    sed -i '/define Device\/xiaomi_cr8816/,/^endef/ s/^\t\t-ipq-wifi-xiaomi_cr8806 \\$/\t\t-ipq-wifi-xiaomi_cr8806 kmod-yt9215-nss \\/' "$MK"
  grep -q 'kmod-yt9215-nss' "$MK" || { echo "[port-cr8816] khong them duoc kmod-yt9215-nss" >&2; exit 1; }

  INIT=package/nss/nss-tools/files/nss-dwmac.init
  DEF=package/nss/nss-tools/files/nss-dwmac.defaults
  if ! grep -q 'yt9215)' "$INIT"; then
    gawk '
      !a && /^\trtl8367s\)$/ && infn {
        print "\tyt9215)"
        print "\t\tdriver=yt921x"
        print "\t\t[ -n \"$dev\" ] || dev=\"90000.mdio-1:1d\""
        print "\t\t;;"
        a=1
      }
      /^switch_to_trunk\(\)/ { infn=1 }
      !b && /^\tvtu="\$\(uci -q get nss.general.vtu\)"$/ {
        print "\tif [ \"$fabric\" = \"yt9215\" ]; then"
        print "\t\tif ! insmod \"/lib/modules/$(uname -r)/yt9215-nss.ko\" identify=1; then"
        print "\t\t\tlogger -p user.err -t nss \"yt9215-nss: no YT9215 answers - yt921x stays bound\""
        print "\t\t\treturn 1"
        print "\t\tfi"
        print "\t\trmmod yt9215_nss"
        print "\tfi"
        print ""
        b=1
      }
      { print }
      END { if (!a || !b) exit 1 }' "$INIT" >"$INIT.tmp" && mv "$INIT.tmp" "$INIT" ||
      { echo "[port-cr8816] patch nss-dwmac.init that bai" >&2; exit 1; }
  fi
  if ! grep -q 'xiaomi,cr8816)' "$DEF"; then
    gawk '
      !a && /^nss_dwmac_board_defaults\(\)/ { infn=1 }
      !a && infn && /^\t\*\)$/ {
        print "\txiaomi,cr8816)"
        print "\t\t# YT9215S: port 8 = CPU (2500base-x, GMAC1 = eth1), 0-2 = lan1-3,"
        print "\t\t# 3 = wan. yt921x is unbound, yt9215-nss re-arms the fabric."
        print "\t\t# GMAC0 (eth0) is unused. Wi-Fi offload (wifili) on: tested on"
        print "\t\t# both radios 2026-11-15 (QCN6122 BDF borrowed from the CR8806)."
        print "\t\tfw_mask='"'"'0x2'"'"'"
        print "\t\ttrunk='"'"'eth1'"'"'"
        print "\t\ttrunk_if='"'"'1'"'"'"
        print "\t\tfabric='"'"'yt9215'"'"'"
        print "\t\tswitch_dev='"'"'90000.mdio-1:1d'"'"'"
        print "\t\tswitch_args='"'"''"'"'"
        print "\t\twifi_offload='"'"'1'"'"'"
        print "\t\tvtu='"'"'1:8t,0u,1u,2u;2:8t,3u'"'"'"
        print "\t\t;;"
        a=1
      }
      { print }
      END { if (!a) exit 1 }' "$DEF" >"$DEF.tmp" && mv "$DEF.tmp" "$DEF" ||
      { echo "[port-cr8816] patch nss-dwmac.defaults that bai" >&2; exit 1; }
  fi
  # LuCI Port status: lan1..wan netdevs are gone with DSA unbound; read the
  # front ports from yt9215-nss instead (stock panel kept as the fallback).
  mkdir -p files/usr/share/cr8816 files/usr/share/rpcd/acl.d files/etc/uci-defaults
  cp "$HERE/nss/yt9215-nss/luci/29_ports.js" files/usr/share/cr8816/29_ports.js
  cp "$HERE/nss/yt9215-nss/luci/acl-cr8816-switch.json" files/usr/share/rpcd/acl.d/luci-cr8816-switch.json
  cp "$HERE/nss/yt9215-nss/luci/95-cr8816-ports" files/etc/uci-defaults/95-cr8816-ports
  chmod 755 files/etc/uci-defaults/95-cr8816-ports
  sed -i 's/^dev=wan$/dev=$(uci -q get network.wan.device); dev=${dev:-wan}\ncase "$dev" in *.*) exit 0 ;; esac  # NSS trunk: eth1.2 bao toc do trunk, khong phai cong WAN/' files/etc/hotplug.d/iface/30-cr8816-wanshape
fi

# --- 9. Tu bat Wi-Fi lan dau (OpenWrt mac dinh tat) ---------------------------
# Chi dong vao cau hinh wireless con nguyen mac dinh (SSID OpenWrt, khong mat
# khau). ath11k nap muon (sau NSS) nen chay tu hotplug ieee80211, khong phai
# uci-defaults. SSID CR8816 / CR8816-5G, mat khau 12345678 - hay doi ngay.
mkdir -p files/etc/hotplug.d/ieee80211
cat > files/etc/hotplug.d/ieee80211/90-cr8816-wifi-on <<'HP'
#!/bin/sh
[ "$ACTION" = add ] || exit 0
. /lib/functions.sh
case "$(board_name)" in xiaomi,cr8816) ;; *) exit 0 ;; esac
(
	lock /var/lock/cr8816-wifi-on
	for i in $(seq 1 60); do
		[ -s /etc/config/wireless ] && [ "$(uci -q show wireless | grep -c '=wifi-device')" -ge 2 ] && break
		sleep 2
	done
	[ "$(uci -q get wireless.cr8816_auto)" = done ] && { lock -u /var/lock/cr8816-wifi-on; exit 0; }
	changed=0
	for dev in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'); do
		iface=$(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)\.device='$dev'\$/\1/p" | head -1)
		[ -n "$iface" ] || continue
		[ "$(uci -q get wireless.$iface.ssid)" = OpenWrt ] || continue
		[ "$(uci -q get wireless.$iface.encryption)" = none ] || continue
		band=$(uci -q get wireless.$dev.band)
		ssid=CR8816; [ "$band" = 5g ] && ssid=CR8816-5G
		[ "$band" = 5g ] && uci set wireless.$dev.channel=36
		uci set wireless.$dev.disabled=0
		uci set wireless.$dev.country=VN
		uci set wireless.$iface.ssid=$ssid
		uci set wireless.$iface.encryption=psk2
		uci set wireless.$iface.key=12345678
		uci -q delete wireless.$iface.disabled
		changed=1
	done
	uci set wireless.cr8816_auto=done
	uci commit wireless
	[ $changed = 1 ] && { logger -t cr8816 "Wi-Fi bat mac dinh: CR8816 / CR8816-5G"; wifi reload; }
	lock -u /var/lock/cr8816-wifi-on
) </dev/null >/dev/null 2>&1 &
exit 0
HP

echo "[port-cr8816] xong:"
echo "  $T/dts/ipq5018-cr8816.dts"
grep -n 'xiaomi_cr8816' "$MK" | head -2
grep -n 'YT921X' "$CFG"
grep -rln 'xiaomi,cr8816' "$BF" package/boot/uboot-tools/uboot-envtools/files/qualcommax_ipq50xx
