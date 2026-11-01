#
# gl-network-quality: continuous latency/DNS/loss monitor and speedtest for
# the GL.iNet Network Quality page.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-network-quality
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/gl-network-quality
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet Network Quality monitor and speedtest
  URL:=https://github.com/gl-xe3000-op25
  DEPENDS:= \
	+gl-oui-rpc \
	+lua-eco +lua-eco-ubus +lua-eco-uci +lua-eco-log \
	+lua-cjson +curl
endef

define Package/gl-network-quality/conffiles
/etc/config/network-quality
endef

define Package/gl-network-quality/description
  Backend for the GL.iNet Network Quality page: a ubus daemon that probes
  the active WAN gateway, internet target and DNS resolvers once a second,
  keeps a 30-minute reliability history, samples the WAN counters, and
  drives the Cloudflare speedtest with the stock curl client.
endef

define Build/Compile
endef

define Package/gl-network-quality/install
	$(CP) ./files/* $(1)/
endef

define Package/gl-network-quality/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/network-quality enable
	/etc/init.d/network-quality start
}
exit 0
endef

$(eval $(call BuildPackage,gl-network-quality))
