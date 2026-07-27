#
# gl-mcu: battery/MCU controller daemon, reimplemented for the GL-XE3000
# OpenWrt 25.12 port. See files/usr/sbin/gl-mcu for the protocol/architecture
# notes.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-mcu
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/gl-mcu
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=GL.iNet XE3000 battery/MCU daemon, reimplemented
  DEPENDS:=+lua-eco +lua-eco-termios +lua-eco-ubus +lua-eco-uci +lua-eco-log +lua-cjson-lua5.4 +gl-oui-rpc
endef

define Package/gl-mcu/description
  Battery/MCU controller for the GL-XE3000, talking JSON-over-UART to the
  onboard MCU on /dev/ttyS1 @ 9600 baud. Reimplements the documented protocol
  (byte-substitution framing on outgoing messages) rather than transplanting
  GL's closed firmware. Registers ubus object "mcu" matching GL's own
  method surface.
endef

define Build/Compile
endef

define Package/gl-mcu/install
	$(CP) ./files/* $(1)/
endef

define Package/gl-mcu/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/gl-mcu enable
}
exit 0
endef

$(eval $(call BuildPackage,gl-mcu))
