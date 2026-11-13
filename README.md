# OpenWrt NSS cho Xiaomi CR8806 (M79) - sửa ECC 4-bit và cpufreq

## Kết quả phân tích file của bạn

| | Firmware gốc Xiaomi (`mtd18_rootfs.bin`) | Bản build sẵn (`...factory.ubi`) |
|---|---|---|
| Kernel | Linux **4.4.60** (QSDK, ARM 32-bit) | Linux 6.18.60 (ARM64) |
| DTB U-Boot chọn | `config@mp02.1` (IPQ5018/AP-MP02.1) | `config@mp02.1` |
| `nand-ecc-strength` | **4** (step 512) | **8** → lỗi `requires 2128 bytes ... -22` |
| Tần số CPU | 800 + **1008 MHz** @1.1 V | 1008 + **1296 MHz** @1.1 V (ép xung, patch 0974) |

Trang 2048 + 64 OOB: với 8-bit ECC, 4 codeword cần 2128 byte > 2112 byte của trang, nên driver
`spi-qpic-snand` trả về `-EINVAL`. Mức 1296 MHz là patch thêm vào trên 1008 MHz định mức và
chạy ở cùng 1.1 V. Bản gốc của Xiaomi tối đa chỉ 1008 MHz.

Script chỉ thêm đoạn này vào cuối `target/linux/qualcommax/dts/ipq5018-cr8806.dts` (giá trị đọc từ DTB gốc):

```dts
&qpic_nand {
	nand@0 {
		nand-ecc-step-size = <512>;
		nand-ecc-strength = <4>;
	};
};
&{/opp-table-cpu} {
	/delete-node/ opp-1296000000;
};
```

Tôi đã biên dịch DTS này trên cây kernel 6.18.60 có áp patch của target. So với DTB của bản build sẵn,
chỉ có đúng 2 thay đổi: ECC 8 thành 4, và bỏ mức 1296 MHz.

## 0. Muốn thử ngay, không cần build

`openwrt-qualcommax-ipq50xx-xiaomi_cr8806-squashfs-factory-ecc4.ubi` là bản build sẵn của bạn,
chỉ thay DTB (kernel và rootfs giữ nguyên từng byte, hash của kernel trùng với bản gốc). Flash nó
theo cách bạn đã flash bản cũ. Nếu nó boot qua được `spi-nand` và `cpufreq` thì bản tự build cũng sẽ chạy.

Có thể tự làm lại với bất kỳ file factory.ubi nào:
```bash
STEP=repack REPACK_IN=openwrt-...-factory.ubi ./build-cr8806.sh
```

## 1. Build trên máy Linux (Ubuntu 22.04/24.04, chạy bằng user thường)

```bash
chmod +x build-cr8806.sh
./build-cr8806.sh /duong/dan/mtd18_rootfs.bin
# File ra: ./cr8806-build/output/
#   *-squashfs-factory.ubi     -> flash lần đầu
#   *-squashfs-sysupgrade.bin  -> nâng cấp từ OpenWrt
#   *-squashfs-uImage.itb      -> kernel FIT (kernel + DTB đã sửa)
```
Cần khoảng 40 GB ổ trống. Lần đầu mất 1 đến 3 giờ tùy số nhân CPU. Cuối quá trình, script tự tách DTB
trong `factory.ubi` vừa build để kiểm tra lại ECC = 4 và CPU tối đa 1008 MHz.

Các tùy chọn (biến môi trường):

| Biến | Ý nghĩa |
|---|---|
| `CPUFREQ_MODE=off` | Tắt hẳn cpufreq nếu vẫn treo ở `cpufreq` với chỉ 1008 MHz |
| `FEEDS_MIRROR=github` | Lấy feeds từ GitHub khi git.openwrt.org chậm |
| `LUCI_LANG=` | Bỏ tiếng Việt, chỉ dùng tiếng Anh |
| `STEP=patch / config / build / verify / repack` | Chạy từng bước riêng |
| `JOBS=8` | Số luồng make |

## 2. Build bằng GitHub Actions (không cần máy Linux)

1. Tạo một repo mới (có thể để private), rồi đưa lên:
   - `build-cr8806.sh`
   - `.github/workflows/build-cr8806.yml`
   - `stock/stock_rootfs.bin` (file `mtd18_rootfs.bin` đổi tên, khoảng 30 MB)
2. Vào **Actions → Build OpenWrt NSS - Xiaomi CR8806 → Run workflow**.
3. Khoảng 2 đến 4 giờ sau, tải file từ **Artifacts** của lần chạy.

## Máy của Tony là CR8816 (switch Motorcomm YT9215S), không phải CR8806 (QCA8337)

Dựa trên các phân vùng gốc anh gửi:

| Nguồn | Nội dung |
|---|---|
| `bdata` (mtd15) | `model=CR8816`, `uart_en=0`, `ssh_en=0` |
| rootfs gốc `/etc/config/misc` | `option model CR8816`, 256 MB DDR3 |
| rootfs gốc `/lib/modules/4.4.60/yt_switch.ko` | driver **Motorcomm YT9215S** gắn trên `/soc/mdio@90000` |
| rootfs gốc `/etc/config/port_map` | cổng 1/2/3 là phy 0/1/2, cổng WAN là phy 3 |
| DTB gốc | GMAC1 nối switch qua uniphy SGMII (`switch_mac_mode 0x0f`), GPIO 26 dùng để reset |
| U-Boot (mtd11 = mtd12) | có lệnh `smi_read`/`smi_write` để truy cập YT9215; chỉ thêm `console=ttyMSM0` khi `uart_en=1` |

Bản build cho CR8806 khai báo switch QCA8337 ở địa chỉ 17, nên log báo `qca8k ... Switch id detected ff`
và các cổng LAN/WAN không hoạt động. Kernel 6.18 của fanha99 đã có sẵn driver DSA `yt921x`
(backport 967-*), chỉ chưa được bật.

`port-cr8816.sh` làm các việc sau:
- Tạo `ipq5018-cr8816.dts`: bỏ QCA8337, thêm `switch@1d` với `motorcomm,yt9215`, gồm lan1-3 (port 0-2),
  wan (port 3) và CPU là port 8 (SGMII 1G, nối GMAC1).
- Thêm profile `xiaomi_cr8816` (FIT `config@mp02.1`, UBI) và bật `CONFIG_NET_DSA_YT921X=y`.
- Thêm `xiaomi,cr8816` vào các script caldata, LED, sysupgrade, uboot-env và `02_network`
  (chỉ một CPU port là eth1).

DTS này đã biên dịch thành công trên kernel 6.18.60 có áp patch của target
(`ipq5018-cr8816.compiled.dts`). Phải build lại toàn bộ, vì cần bật driver trong kernel:
```bash
BOARD=cr8816 ./build-cr8806.sh mtd18_rootfs.bin
```
GitHub Actions: chọn `board = cr8816`.

### Nên kiểm tra trên U-Boot trước khi build (2 phút)
```
smi_read 0x80008    # chip ID, mong đợi 0x9002xxxx (YT9215)
smi_read 0x80028    # SERDES_CTRL: các cổng EXT đang bật
smi_read 0x8008c    # cấu hình serdes port 8
smi_read 0x80090    # cấu hình serdes port 9
smi_read 0x80220    # trạng thái port 8
smi_read 0x80224    # trạng thái port 9
```
Nếu `smi_read` không chạy, hoặc chip ID không phải `0x9002…`, thì địa chỉ SMI không phải 0x1d.
Khi đó đổi `reg = <0x0>` và tên node thành `switch@0`.
Nếu cổng 9 là cổng có link/serdes, còn cổng 8 thì không, thì đổi `ethernet-port@8` thành `@9` (`reg = <9>`).

### Những điểm chưa chắc chắn
- **NSS cho đường dây (wired) chưa chạy được với YT9215.** Plane `dsa` của fanha99 cần một tagger
  `tag_8021q` riêng cho từng loại switch (hiện chỉ có qca8k, rtl8365mb, an8855). Vì vậy NAT có dây sẽ
  chạy trên CPU (dùng software flow offload). Wi-Fi offload qua NSS vẫn có thể dùng được.
- **Wi-Fi QCN6122** bị crash (`USER-PD DOG ... wlan1`, `board_id 0xff`). Cần đối chiếu BDF/caldata
  với firmware gốc (`/lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.b*`). Việc này để làm ở bước sau.
- Console: anh chạy `setenv uart_en 1; saveenv` trong U-Boot để U-Boot thêm `console=ttyMSM0,115200n8`.

## Cấu hình được tạo

- Chỉ có thiết bị `xiaomi_cr8806` (single profile), dùng profile bộ nhớ 256 MB (`ATH11K 256M`, `NSS LOW`).
- NSS: `nss-tools-dwmac`, firmware 12.5, ECM, PPPoE/VLAN, SQM NSS, Wi-Fi offload (lấy từ `.github/ci/ipq50xx` của repo).
- LuCI: `luci`, `luci-ssl` (HTTPS), `luci-app-nss`, `luci-app-sqm`, `luci-proto-ppp`, giao diện tiếng Việt.
- `make defconfig` đã chạy thử với mã nguồn fanha99 (commit `83b63e1`) và giữ đủ các gói trên.

## Lưu ý

- README của repo khuyên **revert commit "debug aids for NSS bring-up work"** khi build bản dùng thật
  (nó bật `DEVMEM` và tắt `STRICT_DEVMEM`). Script không tự revert.
- Comment trong `ipq5018-cr880x.dtsi` của fanha99 nói U-Boot gốc dùng 8-bit ECC. Điều đó chỉ đúng
  với chip NAND có OOB 128 byte. Với Winbond 2048+64 của bạn, DTB gốc và kernel Xiaomi dùng 4-bit.
  Vì vậy bản này chỉ dành cho máy của bạn, không dùng cho máy CR8806 khác loại chip.

## Lỗi "Config not availabale" khi boot từ NAND (bootmiwifi)

U-Boot Xiaomi không dùng config mặc định của FIT. Nó đọc `machid` (máy này là `0x8040002`) rồi tra bảng
DTB nhúng trong U-Boot: `0x8040002` ứng với **`config@mp03.3`**. File FIT chỉ có `config@mp02.1` nên
U-Boot báo `Config not availabale` và reset. (Boot bằng tay `bootm` qua TFTP thì dùng config mặc định nên không lỗi.)

- Sửa nhanh, không cần flash lại: `setenv config_name config@mp02.1; saveenv; reset`
- Hoặc flash `...xiaomi_cr8816-squashfs-factory-yt9215-mp03.3.ubi` (FIT có cả `config@mp03.3` và `config@mp02.1`).
- `port-cr8816.sh` giờ đặt `DEVICE_DTS_CONFIG := config@mp03.3`.

## CR8816 v2 (13/11): đã chạy LuCI, console gõ được
DTB của CR8816 phải theo `config@mp03.3` (không phải mp02.1 của CR8806): UART ở GPIO 20/21, LED ở GPIO 24-27,
nút mesh/reset ở GPIO 28/38, link CPU ↔ YT9215 chạy 2.5G (`2500base-x`). `port-cr8816.sh` đã có các sửa này;
chọn tốc độ bằng `CPU_SPEED=2500` (mặc định) hoặc `CPU_SPEED=1000`.
File thử: `cr8816-initramfs-v2-cpu{2500,1000}.itb`, `cr8816-factory-v2-cpu{2500,1000}.ubi`.
