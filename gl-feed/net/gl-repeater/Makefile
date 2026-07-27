#
# gl-repeater: WiFi repeater / travel-router uplink, reimplemented for the
# GL-XE3000 OpenWrt 25.12 port. STA-uplink + double-NAT against mainline
# mac80211/mt76, not WDS/4addr - see the uci-defaults file for why (eduroam-
# class enterprise APs never support WDS). Depends on wpad-full for
# WPA2/3-Enterprise upstream support.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-repeater
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/gl-repeater
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet XE3000 WiFi repeater/uplink, reimplemented
  DEPENDS:=wpad-openssl +libiwinfo-lua +libubus-lua +libuci-lua +gl-oui-rpc
endef

define Package/gl-repeater/description
  WiFi repeater (STA-uplink) for the GL-XE3000: joins an upstream WiFi
  network (WPA2/3-Personal or WPA2-Enterprise/eduroam-style via wpad-full)
  and NATs the router's own LAN/WiFi clients through it.
endef

define Build/Compile
endef

define Package/gl-repeater/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,gl-repeater))
