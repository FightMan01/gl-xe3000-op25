#
# gl-cloud: GoodCloud client and Cloud/Account page backend.
#
# Clean-room reimplementation of the wire protocol the stock 4.11 firmware
# uses for GoodCloud: device authentication against the GL API, MQTT over
# mutual TLS with the factory device certificate, the registration/attribute/
# command/event topics, and the local `cloud`/`rtty` RPC objects the web UI
# calls. No GL bytecode or closed source is shipped.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-cloud
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/gl-cloud
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet GoodCloud client and Cloud page backend
  URL:=https://github.com/gl-xe3000-op25
  DEPENDS:= \
	+gl-oui-rpc \
	+lua-eco +lua-eco-log +lua-eco-http +lua-eco-mqtt +lua-eco-ssl \
	+lua-eco-sha256 +lua-eco-hmac +lua-eco-dns +lua-eco-ubus \
	+libuci-lua +lua-cjson-lua5.4 +rtty-openssl
endef

define Package/gl-cloud/conffiles
/etc/config/gl-cloud
endef

define Package/gl-cloud/description
  GoodCloud support for the GL.iNet SDK4-style UI: a lua-eco daemon that
  authenticates the router with the factory identity, connects to the
  GoodCloud MQTT broker using the device certificate, publishes the router
  registration and answers cloud attribute/command/event requests, plus the
  `cloud` and `rtty` RPC objects used by the Cloud/Account pages.
endef

define Build/Compile
endef

define Package/gl-cloud/install
	$(CP) ./files/* $(1)/
endef

define Package/gl-cloud/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	[ -x /etc/init.d/gl-cloud ] && /etc/init.d/gl-cloud enable
	[ -x /etc/init.d/rtty ] && /etc/init.d/rtty enable
}
exit 0
endef

$(eval $(call BuildPackage,gl-cloud))
