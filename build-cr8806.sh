#!/usr/bin/env bash
# =============================================================================
#  build-cr8806.sh - Build OpenWrt NSS (kernel 6.18) cho Xiaomi CR8806 (M79)
#  Nguon: https://github.com/fanha99/openwrt-xiaomi-cr8806-nss
#
#  Script lam tron goi:
#    1. Tach FIT kernel tu dump UBI goc (mtd18_rootfs.bin / stock_rootfs.bin),
#       lay DTB cua Xiaomi (config@mp03.3), decompile ra .dts va doc:
#         - nand-ecc-strength / nand-ecc-step-size cua QPIC NAND
#         - operating-points (bang tan so CPU) cua kernel goc
#    2. Patch ipq5018-cr8806.dts trong ma nguon fanha99:
#         - &qpic_nand / nand@0 : ECC theo stock (4-bit / 512 byte)
#         - opp-table-cpu       : bo cac muc tan so cao hon stock (1296 MHz)
#    3. Tao .config (chi xiaomi_cr8806, profile 256 MB, NSS, LuCI) + make defconfig
#    4. make download + make -j$(nproc) -> *.itb (kernel FIT) va *factory.ubi
#    5. Kiem tra lai DTB nam trong factory.ubi vua build (ECC + OPP)
#
#  Cach dung:
#    ./build-cr8806.sh /duong/dan/mtd18_rootfs.bin
#
#  Bien moi truong tuy chon:
#    BOARD=cr8806                cr8806 (QCA8337) | cr8816 (Motorcomm YT9215S, can port-cr8816.sh)
#    WORKDIR=$PWD/cr8806-build   thu muc lam viec
#    SRC_REPO=...                repo nguon (mac dinh fanha99)
#    SRC_BRANCH=main             nhanh
#    STOCK_CONFIG=mp03.3         ten config FIT trong kernel goc (machid 0x8040002 -> mp03.3)
#    ECC_STRENGTH=               ep gia tri ECC (bo trong = lay tu stock, du phong 4)
#    CPUFREQ_MODE=stock          stock: chi giu OPP <= tan so max cua stock (1008 MHz)
#                                off  : tat han cpufreq (CPU giu tan so U-Boot dat)
#    LUCI_LANG=vi                ngon ngu LuCI them vao (bo trong = chi tieng Anh)
#    JOBS=$(nproc)               so luong make
#    FEEDS_MIRROR=github         lay feeds tu GitHub thay vi git.openwrt.org
#    SKIP_DEPS=1                 khong apt-get cai goi phu thuoc
#    STEP=all                    all | patch | config | build | verify | repack
#    VERIFY_UBI=file.ubi         (voi STEP=verify) kiem tra 1 file .ubi bat ky
#    REPACK_IN=file.ubi          (voi STEP=repack) sua DTB cua 1 factory.ubi build san
# =============================================================================
set -Eeuo pipefail

STOCK_IN="${1:-${STOCK_IN:-}}"
WORKDIR="${WORKDIR:-$PWD/cr8806-build}"
SRC_REPO="${SRC_REPO:-https://github.com/fanha99/openwrt-xiaomi-cr8806-nss.git}"
SRC_BRANCH="${SRC_BRANCH:-main}"
STOCK_CONFIG="${STOCK_CONFIG:-mp03.3}"   # machid 0x8040002 -> U-Boot Xiaomi chon config@mp03.3
ECC_STRENGTH="${ECC_STRENGTH:-}"
CPUFREQ_MODE="${CPUFREQ_MODE:-stock}"
LUCI_LANG="${LUCI_LANG:-vi}"
JOBS="${JOBS:-$(nproc)}"
STEP="${STEP:-all}"
# BOARD=cr8816: may CR8816 dung switch Motorcomm YT9215S (xem port-cr8816.sh)
BOARD="${BOARD:-cr8806}"
case "$BOARD" in cr8806|cr8816) ;; *) echo "BOARD phai la cr8806 hoac cr8816" >&2; exit 1 ;; esac
DEV="xiaomi_$BOARD"

SRC="$WORKDIR/openwrt"
EXT="$WORKDIR/stock"
VENV="$WORKDIR/venv"
DTS_REL="target/linux/qualcommax/dts/ipq5018-$BOARD.dts"
OUT_REL="bin/targets/qualcommax/ipq50xx"
MARK_BEGIN="/* >>> CR8806 stock-DTB fix (build-cr8806.sh) >>> */"
MARK_END="/* <<< CR8806 stock-DTB fix <<< */"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "Loi o dong $LINENO: $BASH_COMMAND"' ERR

[ "$(id -u)" = 0 ] && [ "${FORCE_UNSAFE_CONFIGURE:-0}" != 1 ] && \
  warn "Dang chay bang root: OpenWrt se tu choi build. Hay chay bang user thuong (hoac export FORCE_UNSAFE_CONFIGURE=1)."

# -----------------------------------------------------------------------------
# 0. Goi phu thuoc
# -----------------------------------------------------------------------------
install_deps() {
  [ "${SKIP_DEPS:-0}" = 1 ] && return 0
  if command -v apt-get >/dev/null; then
    log "Cai goi phu thuoc (apt)"
    local SUDO=""; [ "$(id -u)" != 0 ] && SUDO=sudo
    $SUDO apt-get update -qq || true
    $SUDO apt-get install -y --no-install-recommends \
      build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git \
      libncurses-dev libssl-dev python3 python3-dev python3-pip python3-venv python3-setuptools \
      rsync swig unzip zlib1g-dev file wget curl ccache zstd xz-utils bzip2 patch perl \
      device-tree-compiler u-boot-tools squashfs-tools mtd-utils libelf-dev time \
      || $SUDO apt-get install -y --no-install-recommends \
      build-essential flex bison g++ gawk gettext git libncurses-dev libssl-dev python3 \
      python3-venv rsync swig unzip zlib1g-dev file wget curl zstd xz-utils bzip2 patch \
      device-tree-compiler u-boot-tools squashfs-tools mtd-utils libelf-dev
  else
    warn "Khong phai Debian/Ubuntu: tu cai dtc, dumpimage (u-boot-tools), python3-venv va goi build OpenWrt."
  fi
  if ! command -v ubireader_extract_images >/dev/null && [ ! -x "$VENV/bin/ubireader_extract_images" ]; then
    log "Cai ubi_reader vao $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q ubi_reader
  fi
}
ubireader() { # ubireader <tool> args...
  local t="ubireader_$1"; shift
  if [ -x "$VENV/bin/$t" ]; then "$VENV/bin/$t" "$@"; else "$t" "$@"; fi
}
need() { for c in "$@"; do command -v "$c" >/dev/null || die "Thieu lenh: $c"; done; }

# -----------------------------------------------------------------------------
# Tach DTB tu 1 file (UBI image hoac FIT .itb). In ra duong dan .dtb
#   extract_dtb <file> <outdir> <config-name-or-empty>
# -----------------------------------------------------------------------------
extract_dtb() {
  local in="$1" out="$2" want="$3" fit idx
  need dumpimage dtc file gawk
  rm -rf "$out"; mkdir -p "$out"
  if file -b "$in" | grep -q '^UBI image'; then
    ubireader extract_images -o "$out/ubi" "$in" >/dev/null
    fit=$(find "$out/ubi" -name '*_vol-kernel.ubifs' | head -1)
    [ -n "$fit" ] || die "Khong thay volume 'kernel' trong $in"
  elif file -b "$in" | grep -q 'Device Tree Blob'; then
    fit="$in"
  else
    die "$in khong phai UBI image cung khong phai FIT. (Dump co kem OOB? Hay dump bang 'nanddump' khong OOB hoac dd tu /dev/mtdX.)"
  fi
  dumpimage -l "$fit" 2>/dev/null >"$out/fit.txt"
  # Danh sach " Image N (fdt@xxx)" hoac "(fdt-1)"
  if [ -n "$want" ] && grep -qE "^ Image [0-9]+ \(fdt[@-]${want//./\\.}\)" "$out/fit.txt"; then
    idx=$(grep -E "^ Image [0-9]+ \(fdt[@-]${want//./\\.}\)" "$out/fit.txt" | head -1 | awk '{print $2}')
  else
    [ -n "$want" ] && warn "Khong thay fdt@$want trong FIT, dung DTB dau tien"
    idx=$(grep -E '^ Image [0-9]+ \(fdt' "$out/fit.txt" | head -1 | awk '{print $2}')
  fi
  [ -n "$idx" ] || die "FIT khong co DTB"
  dumpimage -T flat_dt -p "$idx" -o "$out/board.dtb" "$fit" >/dev/null 2>&1
  dtc -q -I dtb -O dts -o "$out/board.dts" "$out/board.dtb"
  echo "$out/board.dts"
}

# Doc thuoc tinh dau tien trong cac node NAND: dts_nand_prop <dts> <prop>
dts_nand_prop() {
  gawk -v P="$2" '
    /(nand|nandcs)[@-][0-9a-f]+ *\{/ {inn=1}
    inn && $1==P { gsub(/[<>;]/,"",$3); print strtonum($3); exit }' "$1"
}
# Tan so max (Hz) tu operating-points (v1, kHz) hoac opp-hz (v2): dts_cpu_max_hz <dts>
dts_cpu_max_hz() {
  gawk '
    $1=="operating-points" { s=$0; sub(/.*</,"",s); sub(/>.*/,"",s); n=split(s,a," ");
      for(i=1;i<=n;i+=2){ v=strtonum(a[i])*1000; if(v>m) m=v } }
    $1=="opp-hz" { s=$0; sub(/.*</,"",s); sub(/>.*/,"",s); n=split(s,a," ");
      v=strtonum(a[1])*4294967296+strtonum(a[2]); if(v>m) m=v }
    END { if(m) printf "%d\n", m }' "$1"
}

# -----------------------------------------------------------------------------
# 1. Lay ma nguon + feeds
# -----------------------------------------------------------------------------
get_source() {
  mkdir -p "$WORKDIR"
  if [ ! -d "$SRC/.git" ]; then
    log "Clone $SRC_REPO ($SRC_BRANCH)"
    # Lich su day du: scripts/getver.sh can no de dat ten phien ban
    # Cache CI co the da khoi phuc san $SRC/dl -> clone vao thu muc tam roi gop
    if [ -d "$SRC" ] && [ -n "$(ls -A "$SRC" 2>/dev/null)" ]; then
      rm -rf "$SRC.tmp"
      git clone -b "$SRC_BRANCH" "$SRC_REPO" "$SRC.tmp"
      cp -a "$SRC.tmp/." "$SRC/"
      rm -rf "$SRC.tmp"
    else
      git clone -b "$SRC_BRANCH" "$SRC_REPO" "$SRC"
    fi
  else
    log "Ma nguon da co o $SRC (khong pull de giu nguyen ban da patch)"
  fi
  if [ "$BOARD" = cr8816 ]; then
    log "Them thiet bi xiaomi_cr8816 (switch YT9215S)"
    bash "$(dirname "$(readlink -f "$0")")/port-cr8816.sh" "$SRC"
  fi
  [ -f "$SRC/$DTS_REL" ] || die "Khong thay $DTS_REL trong ma nguon - repo/nhanh sai?"
  if [ "${FEEDS_MIRROR:-}" = github ] && [ ! -f "$SRC/feeds.conf" ]; then
    # git.openwrt.org cham/bi chan -> dung mirror GitHub (cung commit)
    log "Dung mirror GitHub cho feeds"
    sed -e 's#https://git.openwrt.org/feed/#https://github.com/openwrt/#' \
        -e 's#https://git.openwrt.org/project/luci.git#https://github.com/openwrt/luci.git#' \
        "$SRC/feeds.conf.default" >"$SRC/feeds.conf"
  fi
  if [ ! -d "$SRC/feeds/luci" ] || [ ! -d "$SRC/feeds/nss" ]; then
    log "Cap nhat feeds"
    (cd "$SRC" && ./scripts/feeds update -a && ./scripts/feeds install -a)
  fi
}

# -----------------------------------------------------------------------------
# 2. Extract stock DTB + patch DTS
# -----------------------------------------------------------------------------
patch_dts() {
  local ecc step maxhz stock_dts opp_hz dts="$SRC/$DTS_REL" del=""
  if [ -n "$STOCK_IN" ]; then
    [ -f "$STOCK_IN" ] || die "Khong thay file stock: $STOCK_IN"
    log "Tach DTB goc tu $STOCK_IN (config@$STOCK_CONFIG)"
    stock_dts=$(extract_dtb "$STOCK_IN" "$EXT" "$STOCK_CONFIG")
    cp "$stock_dts" "$WORKDIR/stock-cr8806.dts"
    log "Da luu DTS goc: $WORKDIR/stock-cr8806.dts ($(grep -m1 'model =' "$stock_dts" | sed 's/^\s*//'))"
    ecc=$(dts_nand_prop "$stock_dts" nand-ecc-strength || true)
    step=$(dts_nand_prop "$stock_dts" nand-ecc-step-size || true)
    maxhz=$(dts_cpu_max_hz "$stock_dts" || true)
  else
    warn "Khong co file stock: dung gia tri mac dinh da do tren CR8806 (ECC 4/512, CPU max 1008 MHz)"
  fi
  ecc="${ECC_STRENGTH:-${ecc:-4}}"; step="${step:-512}"; maxhz="${maxhz:-1008000000}"
  [ "$ecc" -le 4 ] || warn "ECC stock = $ecc. Winbond 2048+64 chi chiu 4-bit; kiem tra lai."
  log "Stock: nand-ecc-strength=$ecc, step=$step, CPU max=$((maxhz/1000000)) MHz"

  # Cac OPP trong ipq5018.dtsi cua kernel 6.18 (sau patch 0912 + 0974): 1008 va 1296 MHz.
  # Lay danh sach tu chinh cac patch de khong hardcode.
  for opp_hz in $(grep -hoE 'opp-[0-9]{9,10} \{' "$SRC"/target/linux/qualcommax/patches-6.18/*ipq5018* 2>/dev/null \
                  | grep -oE '[0-9]+' | sort -un); do
    if [ "$CPUFREQ_MODE" = stock ] && [ "$opp_hz" -gt "$maxhz" ]; then
      del+=$'\t'"/delete-node/ opp-${opp_hz};"$'\n'
    fi
  done

  log "Patch $DTS_REL"
  # Xoa block cu (chay lai nhieu lan van an toan)
  gawk -v B="$MARK_BEGIN" -v E="$MARK_END" '
    $0==B {skip=1} !skip {print} $0==E {skip=0}' "$dts" >"$dts.tmp"
  # bo dong trong thua o cuoi file
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$dts.tmp"
  mv "$dts.tmp" "$dts"
  {
    echo
    echo "$MARK_BEGIN"
    echo "/* Gia tri lay tu DTB Xiaomi goc (config@$STOCK_CONFIG). */"
    echo "&qpic_nand {"
    echo "	nand@0 {"
    echo "		/* Winbond SPI NAND 2048+64: 8-bit can 2128 byte/trang -> -EINVAL. */"
    echo "		nand-ecc-step-size = <$step>;"
    echo "		nand-ecc-strength = <$ecc>;"
    echo "	};"
    echo "};"
    if [ "$CPUFREQ_MODE" = off ]; then
      echo
      echo "/* Tat cpufreq: CPU giu tan so do U-Boot dat, khong doi PLL luc chay. */"
      for c in cpu@0 cpu@1; do
        echo "&{/cpus/$c} { /delete-property/ operating-points-v2; };"
      done
    elif [ -n "$del" ]; then
      echo
      echo "/* Chi giu OPP <= $((maxhz/1000000)) MHz nhu kernel goc. */"
      echo "&{/opp-table-cpu} {"
      printf '%s' "$del"
      echo "};"
    fi
    echo "$MARK_END"
  } >>"$dts"
  gawk -v B="$MARK_BEGIN" '$0==B{p=1} p' "$dts"
}

# -----------------------------------------------------------------------------
# 3. .config
# -----------------------------------------------------------------------------
make_config() {
  local ci="$SRC/.github/ci/ipq50xx" missing=()
  log "Tao .config cho $DEV"
  cd "$SRC"
  {
    # Phan chung NSS cua repo (bo dong build-user/domain va cac DEVICE khac)
    if [ -f "$ci/common.config" ]; then
      grep -vE '^CONFIG_(TARGET_MULTI_PROFILE|TARGET_PER_DEVICE_ROOTFS|KERNEL_BUILD_|AUTOREMOVE)' "$ci/common.config"
    fi
    [ -f "$ci/256m.config" ] && grep -vE '^CONFIG_TARGET_DEVICE_' "$ci/256m.config"
    echo "CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_${DEV}=y"
    cat <<'EOF'
# --- Thiet bi: 1 profile duy nhat ---
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
# CONFIG_TARGET_MULTI_PROFILE is not set
# --- 256 MB RAM ---
CONFIG_ATH11K_MEM_PROFILE_256M=y
CONFIG_NSS_MEM_PROFILE_LOW=y
# --- NSS ---
CONFIG_PACKAGE_nss-tools-dwmac=y
CONFIG_PACKAGE_nss-firmware=y
# --- LuCI ---
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-app-nss=y
CONFIG_PACKAGE_luci-app-sqm=y
CONFIG_PACKAGE_luci-proto-ppp=y
# --- Image ---
CONFIG_TARGET_ROOTFS_SQUASHFS=y
# initramfs: *-initramfs-uImage.itb de boot tam vao RAM (tftpboot + bootm)
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_TARGET_INITRAMFS_COMPRESSION_ZSTD=y
CONFIG_CCACHE=y
# CONFIG_KERNEL_DEBUG_INFO is not set
EOF
    [ -n "$LUCI_LANG" ] && echo "CONFIG_LUCI_LANG_${LUCI_LANG}=y"
  } >.config
  # Xoa cache quet package (tmp/) de khong dung thong tin cu luc feeds chua du
  rm -rf tmp
  make defconfig >/dev/null
  for want in CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_${DEV}=y CONFIG_PACKAGE_luci=y \
              CONFIG_PACKAGE_nss-tools-dwmac=y CONFIG_PACKAGE_kmod-qca-nss-drv=y \
              CONFIG_PACKAGE_luci-app-nss=y CONFIG_TARGET_ROOTFS_INITRAMFS=y; do
    grep -qxF "$want" .config || missing+=("$want")
  done
  [ ${#missing[@]} -eq 0 ] || die "make defconfig da bo: ${missing[*]}"
  ./scripts/diffconfig.sh >"$WORKDIR/diffconfig-cr8806.txt"
  log "OK. diffconfig: $WORKDIR/diffconfig-cr8806.txt"
}

# -----------------------------------------------------------------------------
# 4. Build
# -----------------------------------------------------------------------------
build() {
  cd "$SRC"
  log "make download (-j$JOBS)"
  local i
  for i in 1 2 3; do make download -j"$JOBS" && break; warn "download lan $i loi, thu lai"; sleep 5; done
  find dl -size -1024c -name '*.tar*' -delete 2>/dev/null || true
  log "make -j$JOBS (lan dau mat 1-3 gio)"
  if ! make -j"$JOBS" world; then
    warn "Build song song loi -> chay lai 1 luong de xem loi ro rang"
    make -j1 V=s world 2>&1 | tee "$WORKDIR/build-error.log" | tail -80
    die "Build that bai. Log: $WORKDIR/build-error.log"
  fi
}

# -----------------------------------------------------------------------------
# 5. Verify
# -----------------------------------------------------------------------------
verify_ubi() {
  local ubi="$1" dts ecc maxhz ok=1
  log "Kiem tra DTB trong $(basename "$ubi")"
  dts=$(extract_dtb "$ubi" "$WORKDIR/verify" "")
  ecc=$(dts_nand_prop "$dts" nand-ecc-strength || true)
  maxhz=$(dts_cpu_max_hz "$dts" || true)
  echo "    model             : $(grep -m1 'model =' "$dts" | sed 's/.*= //')"
  echo "    nand-ecc-strength : ${ecc:-?}"
  if grep -q 'operating-points-v2' "$dts"; then
    echo "    CPU OPP max       : $(( ${maxhz:-0} / 1000000 )) MHz"
  else
    echo "    CPU OPP           : (cpufreq tat)"
  fi
  [ "${ecc:-0}" -le 4 ] || { warn "ECC van la $ecc -> se loi 'spi-nand failed with error -22'"; ok=0; }
  if grep -q 'operating-points-v2' "$dts" && [ "${maxhz:-0}" -gt 1008000000 ]; then
    warn "Van con OPP > 1008 MHz"; ok=0
  fi
  if [ $ok = 1 ]; then log "DTB dung nhu mong muon."; else die "DTB trong $(basename "$ubi") CHUA dung - dung flash file nay!"; fi
}

collect() {
  local out="$SRC/$OUT_REL" dst="$WORKDIR/output" ubi
  mkdir -p "$dst"
  ubi=$(ls "$out"/*${DEV}*factory.ubi 2>/dev/null | head -1) || true
  [ -n "$ubi" ] || die "Khong thay *factory.ubi trong $out"
  cp -v "$out"/*${DEV}* "$dst"/
  # .itb = kernel FIT (kernel + DTB) = volume 'kernel' trong factory.ubi
  rm -rf "$WORKDIR/itb"
  ubireader extract_images -o "$WORKDIR/itb" "$ubi" >/dev/null
  cp -v "$(find "$WORKDIR/itb" -name '*_vol-kernel.ubifs' | head -1)" \
        "$dst/openwrt-qualcommax-ipq50xx-${DEV}-squashfs-uImage.itb"
  [ -f "$WORKDIR/stock-cr8806.dts" ] && cp "$WORKDIR/stock-cr8806.dts" "$dst"/
  (cd "$dst" && sha256sum -- * >sha256sums.txt)
  verify_ubi "$ubi"
  log "Xong! File o: $dst"
  ls -lh "$dst"
}

# -----------------------------------------------------------------------------
# (Tuy chon) Sua nhanh 1 file factory.ubi build san, khong can build lai:
# thay DTB trong FIT (ECC 4-bit, bo OPP > stock), dong goi lai UBI.
#   STEP=repack REPACK_IN=in.ubi [REPACK_OUT=out.ubi]
# -----------------------------------------------------------------------------
repack_ubi() {
  local in="$1" out="$2" d="$WORKDIR/repack" fit k f cfg np opp mhz
  need fdtget fdtput mkimage ubinize dumpimage dtc gawk
  rm -rf "$d"; mkdir -p "$d"
  ubireader extract_images -o "$d/ubi" "$in" >/dev/null
  fit=$(find "$d/ubi" -name '*_vol-kernel.ubifs' | head -1)
  [ -n "$fit" ] || die "Khong thay volume kernel"
  k=$(fdtget -l "$fit" /images | grep -m1 '^kernel'); f=$(fdtget -l "$fit" /images | grep -m1 '^fdt')
  cfg=$(fdtget "$fit" /configurations default)
  dumpimage -T flat_dt -p 0 -o "$d/kernel.bin" "$fit" >/dev/null 2>&1
  dumpimage -T flat_dt -p 1 -o "$d/board.dtb" "$fit" >/dev/null 2>&1
  np=$(dtc -q -I dtb -O dts "$d/board.dtb" | gawk '
       /^\t*[a-z0-9_,.-]+(@[0-9a-f]+)? \{$/ { l=$0; dep=gsub(/\t/,"",l); path[dep]=$1 }
       /compatible = "spi-nand"/ { p=""; for(i=1;i<=dep;i++) p=p"/"path[i]; print p; exit }')
  [ -n "$np" ] || die "Khong tim thay node spi-nand trong DTB"
  fdtput -t u "$d/board.dtb" "$np" nand-ecc-strength "${ECC_STRENGTH:-4}"
  for opp in $(fdtget -l "$d/board.dtb" /opp-table-cpu 2>/dev/null); do
    mhz=$(( ${opp#opp-} / 1000000 ))
    if [ "$mhz" -gt "${STOCK_MAX_MHZ:-1008}" ]; then fdtput -r "$d/board.dtb" "/opp-table-cpu/$opp"; fi
  done
  cat >"$d/fit.its" <<ITS
/dts-v1/;
/ {
	description = "$(fdtget "$fit" / description)";
	#address-cells = <1>;
	images {
		$k {
			description = "$(fdtget "$fit" /images/$k description)";
			data = /incbin/("kernel.bin");
			type = "kernel"; arch = "$(fdtget "$fit" /images/$k arch)"; os = "linux";
			compression = "$(fdtget "$fit" /images/$k compression)";
			load = <0x$(fdtget -t x "$fit" /images/$k load)>;
			entry = <0x$(fdtget -t x "$fit" /images/$k entry)>;
			hash-1 { algo = "crc32"; };
			hash-2 { algo = "sha1"; };
		};
		$f {
			description = "$(fdtget "$fit" /images/$f description)";
			data = /incbin/("board.dtb");
			type = "flat_dt"; arch = "$(fdtget "$fit" /images/$f arch)"; compression = "none";
			hash-1 { algo = "crc32"; };
			hash-2 { algo = "sha1"; };
		};
	};
	configurations {
		default = "$cfg";
		$cfg { description = "$(fdtget "$fit" /configurations/$cfg description)"; kernel = "$k"; fdt = "$f"; };
	};
};
ITS
  (cd "$d" && mkimage -f fit.its kernel.itb >/dev/null 2>&1) || die "mkimage loi"
  cp "$(find "$d/ubi" -name '*_vol-rootfs.ubifs' | head -1)" "$d/rootfs.squashfs"
  cat >"$d/ubi.ini" <<INI
[kernel]
mode=ubi
vol_id=0
vol_type=dynamic
vol_name=kernel
image=$d/kernel.itb

[rootfs]
mode=ubi
vol_id=1
vol_type=dynamic
vol_name=rootfs
image=$d/rootfs.squashfs

[rootfs_data]
mode=ubi
vol_id=2
vol_type=dynamic
vol_name=rootfs_data
vol_size=1MiB
vol_flags=autoresize
INI
  ubinize -o "$out" -p 128KiB -m 2048 "$d/ubi.ini" >/dev/null 2>&1 || die "ubinize loi"
  cp "$d/kernel.itb" "${out%.ubi}-uImage.itb"
  log "Da tao: $out (+ ${out%.ubi}-uImage.itb)"
  verify_ubi "$out"
}

# -----------------------------------------------------------------------------
case "$STEP" in
  all)    install_deps; get_source; patch_dts; make_config; build; collect ;;
  patch)  install_deps; get_source; patch_dts ;;
  config) get_source; make_config ;;
  build)  build; collect ;;
  verify) install_deps; verify_ubi "${VERIFY_UBI:?VERIFY_UBI=file.ubi}" ;;
  repack) install_deps; repack_ubi "${REPACK_IN:?REPACK_IN=file.ubi}" \
            "${REPACK_OUT:-${REPACK_IN%.ubi}-ecc4.ubi}" ;;
  *) die "STEP khong hop le: $STEP" ;;
esac
