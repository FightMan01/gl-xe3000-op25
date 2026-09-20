#
# gl-cellular: cellular/modem management for the GL-XE3000's Quectel
# RM520N-GL, reimplemented for the OpenWrt 25.12 port.
#
# The data connection uses the modem's native PCIe link through Quectel's
# out-of-tree pcie_mhi driver (kmod-pcie_mhi) and quectel-CM, the same QMI/
# QMAP stack GL's stock firmware runs, driven by the `qcm` netifd proto
# (lib/netifd/proto/qcm.sh). Mainline's MHI/MBIM stack was dropped: it
# wedged the modem's data plane under sustained load. gl-cellular-atd (this
# package) separately supplies richer per-cell/signal data and SIM controls
# via the modem's AT port, a parallel USB composition (ttyUSB0-3).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-cellular
PKG_VERSION:=1
PKG_RELEASE:=16

PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/gl-cellular
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet XE3000 cellular/modem management, reimplemented
  DEPENDS:= \
	+kmod-pcie_mhi +quectel-cm \
	+kmod-usb-serial-option +kmod-usb-acm \
	+lua-eco +lua-eco-termios +lua-eco-ubus +lua-eco-uci +lua-eco-log \
	+lua-cjson-lua5.4 +libubus-lua +libuci-lua +lua-cjson +gl-oui-rpc \
	+curl
endef

define Package/gl-cellular/description
  Cellular/modem management for the GL-XE3000's Quectel RM520N-GL over the
  pcie_mhi + quectel-CM QMI/QMAP data path. Adds AT-port-based signal/cell
  detail and SIM/band configuration (a separate USB path) to match GL's
  original GUI screens, plus persistent data-usage accounting and a
  watchdog that redials / power-cycles / PCIe-resets a hung modem.
endef

define Package/gl-cellular/conffiles
/etc/config/gl-cellular
endef

define Build/Compile
endef

define Package/gl-cellular/install
	$(CP) ./files/* $(1)/
	$(INSTALL_DIR) $(1)/usr/lib/lua/gloui
endef

define Package/gl-cellular/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/gl-cellular-atd enable
	/etc/init.d/gl-cellular-pcie-pm enable
	/etc/init.d/gl-cellular-boot-redial enable
}
exit 0
endef

$(eval $(call BuildPackage,gl-cellular))
