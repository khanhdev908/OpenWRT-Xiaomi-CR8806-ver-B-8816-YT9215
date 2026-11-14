include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=yt9215-nss
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/yt9215-nss
  SECTION:=kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Network Devices
  TITLE:=Motorcomm YT9215 fabric re-arm after yt921x teardown
  DEPENDS:=@TARGET_qualcommax_ipq50xx
  FILES:=$(PKG_BUILD_DIR)/yt9215-nss.ko
endef

define KernelPackage/yt9215-nss/description
  Resets the YT9215 and programs it as a plain 802.1Q fabric (CPU tag off,
  trunk forced, VLAN split) once the yt921x DSA driver has been unbound,
  so the IPQ50xx NSS firmware can own the trunk GMAC.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	+$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,yt9215-nss))
