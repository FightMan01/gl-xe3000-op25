#
# gl-cellular: cellular/modem management for the GL-XE3000's Quectel
# RM520N-GL, reimplemented for the OpenWrt 25.12 port.
#
# The data connection uses the modem's native PCIe/MHI link, not USB/QMI.
# The modem enumerates as PCI ID 17cb:0308, which mainline Linux's own
# drivers/bus/mhi/host/pci_generic.c already recognizes (as "qcom-sdx65m")
# with no driver patching needed - just enabling these normally-off kmods.
# Connection lifecycle is owned entirely by netifd's in-tree `mbim` proto
# (package umbim) talking to /dev/wwan0mbim0 - no custom
# connection-management daemon. gl-cellular-atd (this package) separately
# supplies richer per-cell/signal data and SIM controls via the modem's
# AT port, a distinct, parallel USB composition (ttyUSB0-3) unaffected by
# which path (PCIe or USB) carries the actual data connection.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-cellular
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/gl-cellular
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet XE3000 cellular/modem management, reimplemented
  DEPENDS:= \
	+umbim +luci-proto-mbim +kmod-mhi-bus +kmod-mhi-net +kmod-mhi-pci-generic +kmod-mhi-wwan-ctrl +kmod-mhi-wwan-mbim \
	+kmod-usb-serial-option +kmod-usb-acm \
	+lua-eco +lua-eco-termios +lua-eco-ubus +lua-eco-uci +lua-eco-log \
	+lua-cjson-lua5.4 +libubus-lua +libuci-lua +lua-cjson +gl-oui-rpc
endef

define Package/gl-cellular/description
  Cellular/modem management for the GL-XE3000's Quectel RM520N-GL, using
  its native PCIe/MHI data path (mainline mhi_pci_generic + mhi_wwan_mbim +
  netifd's mbim proto) rather than USB/QMI, for full-speed throughput. This
  package adds AT-port-based signal/cell detail and SIM/band configuration
  (a separate, parallel USB path) to match GL's original GUI screens, plus
  persistent data-usage accounting.
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
