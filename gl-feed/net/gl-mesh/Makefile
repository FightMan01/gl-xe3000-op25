#
# gl-mesh: GL.iNet EasyMesh page backend on top of upstream prplmesh.
#
# Everything is derived from the live UCI/ubus state (front-haul BSS names,
# SSID/key/encryption, LAN bridge). The page starts prplmesh only when the
# user enables mesh, and refuses while repeater/STA mode is active.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-mesh
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/gl-mesh
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL.iNet EasyMesh page backend (prplmesh)
  URL:=https://github.com/gl-xe3000-op25
  DEPENDS:=+gl-oui-rpc +prplmesh +libuci-lua +lua-cjson
endef

define Package/gl-mesh/conffiles
/etc/config/gl-mesh
endef

define Package/gl-mesh/description
  Backend for the GL.iNet 4.11 Mesh page. Uses the upstream prplmesh
  controller/agent and autoconfigures its radios, BSS credentials and LAN
  bridge from the running UCI configuration. Repeater/STA mode is detected
  and blocks mesh startup so the two do not fight over the station side.
endef

define Build/Compile
endef

define Package/gl-mesh/install
	$(CP) ./files/* $(1)/
endef

define Package/gl-mesh/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/gl-mesh enable
}
exit 0
endef

$(eval $(call BuildPackage,gl-mesh))
