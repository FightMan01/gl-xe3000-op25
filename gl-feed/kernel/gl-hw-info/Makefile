include $(TOPDIR)/rules.mk

PKG_NAME:=gl-hw-info
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/gl-hw-info
  SUBMENU:=Other modules
  TITLE:=GL.iNet /proc/gl-hw-info compatibility
  FILES:=$(PKG_BUILD_DIR)/gl-hw-info.ko
  AUTOLOAD:=$(call AutoLoad,10,gl-hw-info,1)
endef

define KernelPackage/gl-hw-info/description
  Provides /proc/gl-hw-info, which GL.iNet's own userspace (the GoodCloud
  client among others) reads for the board description and the factory
  identity: MAC, DDNS name, serial number, country and the device
  certificate and key. GL's stock kernel fills it from its device tree; here
  an init script writes the values once at boot from the factory partition.
endef

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define KernelPackage/gl-hw-info/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/gl-hw-info.init $(1)/etc/init.d/gl-hw-info
endef

$(eval $(call KernelPackage,gl-hw-info))
