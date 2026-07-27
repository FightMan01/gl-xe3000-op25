#
# gl-oui-rpc: reimplemented GL SDK4 GUI backend (session/auth/RPC dispatch),
# for a 1:1 GUI port of the GL-XE3000 GUI onto vanilla OpenWrt 25.12.
#
# Clean-room reimplementation of GL's oui-httpd wire protocol/behavior,
# not a transplant of GL's own closed-source code.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-oui-rpc
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/gl-oui-rpc
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet SDK4 GUI - backend (session/RPC), reimplemented
  URL:=https://github.com/zhaojh329/lua-eco
  DEPENDS:= \
	nginx-ssl +nginx-mod-lua +nginx-mod-lua-resty-core +nginx-mod-lua-resty-lrucache \
	+lua-eco +lua-eco-ubus +lua-eco-uci +lua-eco-sha256 +lua-eco-log \
	+libubus-lua +libuci-lua +lua-cjson +libiwinfo-lua \
	+kmod-mt7915e +kmod-mt7981-firmware +mt7981-wo-firmware wpad-openssl \
	+mwan3 +px5g-mbedtls +sqm-scripts +tailscale +adguardhome +zerotier +tor \
	+ksmbd-server +avahi-nodbus-daemon +ksmbd-avahi-service +wireguard-tools
endef

define Package/gl-oui-rpc/conffiles
/etc/config/gl-oui-rpc
/etc/config/gl-oui-acl
/etc/config/gl_wgserver
/etc/gl-oui-access.conf
/etc/gl-oui-listen.conf
endef

define Package/gl-oui-rpc/description
  Backend for the GL.iNet SDK4-style GUI: an nginx+lua-mod-lua /rpc dispatcher
  (oui-rpc.lua) plus a separate ubus session/auth daemon (gl-ngx-session,
  running under lua-eco), reimplementing the wire protocol GL's original
  closed firmware used so the vendored, unmodified GL frontend bundle
  (package gl-oui-www) works against it unmodified.
endef

define Build/Compile
endef

define Package/gl-oui-rpc/install
	$(CP) ./files/* $(1)/
	$(INSTALL_DIR) $(1)/usr/lib/oui-rpc
endef

define Package/gl-oui-rpc/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/gl-ngx-session enable
	/etc/init.d/gl-internet-led enable
	/etc/init.d/sqm enable
	/etc/init.d/tailscale disable
	/etc/init.d/adguardhome disable
}
exit 0
endef

$(eval $(call BuildPackage,gl-oui-rpc))
