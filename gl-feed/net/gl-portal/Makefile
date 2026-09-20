# Captive-portal support for the GL GUI and STA repeater.
#
# The kernel part is the GPL wifidog-ng implementation from
# https://github.com/zhaojh329/wifidog-ng, rebuilt here instead of copying the
# vendor 5.4.211 module from the original firmware.  The userspace pieces are
# deliberately small OpenWrt-native adapters: nginx sends intercepted clients
# back to the local GUI and the repeater detector probes through its STA.

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-portal
PKG_VERSION:=1
PKG_RELEASE:=5

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=src/wifidog-ng.c

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/kernel.mk

define Package/gl-portal
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=GL captive portal and repeater portal detection
  DEPENDS:=+ipset +lua-eco +lua-eco-http +lua-eco-ubus +lua-eco-uci +lua-cjson-lua5.4
endef

define Package/gl-portal/description
  Captive-portal redirect support for the GL management UI and captive
  network detection for the WiFi repeater STA uplink.  The optional
  wifidog-ng kernel package is built separately for matching full images;
  the repeater flow remains safe without it because the gate is disabled.
endef

define KernelPackage/gl-wifidog-ng
  SUBMENU:=Other modules
  TITLE:=IPv4 captive-portal interception module
  DEPENDS:=+kmod-nf-nat +kmod-ipt-ipset
  FILES:=$(PKG_BUILD_DIR)/wifidog-ng.ko
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/wifidog-ng.c $(PKG_BUILD_DIR)/
	printf 'obj-m := wifidog-ng.o\n' > $(PKG_BUILD_DIR)/Makefile
endef

KERNEL_MAKE_FLAGS?= \
	ARCH="$(LINUX_KARCH)" \
	CROSS_COMPILE="$(TARGET_CROSS)"

MAKE_OPTS:= \
	$(KERNEL_MAKE_FLAGS) \
	M="$(PKG_BUILD_DIR)"

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" $(MAKE_OPTS) modules
endef

define Package/gl-portal/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/usr/sbin $(1)/usr/share/gl-oui
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/init.d/gl-portal $(1)/etc/init.d/gl-portal
	$(INSTALL_BIN) ./files/etc/init.d/gl-repeater-portal $(1)/etc/init.d/gl-repeater-portal
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-gl-portal $(1)/etc/uci-defaults/95-gl-portal
	$(INSTALL_BIN) ./files/usr/sbin/gl-repeater-portal $(1)/usr/sbin/gl-repeater-portal
	$(INSTALL_DIR) $(1)/usr/share/gl-oui
	$(INSTALL_DATA) ./files/usr/share/gl-oui/gl-portal.lua $(1)/usr/share/gl-oui/gl-portal.lua
endef

define Package/gl-portal/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/gl-portal enable
	/etc/init.d/gl-repeater-portal enable
}
exit 0
endef

$(eval $(call BuildPackage,gl-portal))
$(eval $(call KernelPackage,gl-wifidog-ng))
