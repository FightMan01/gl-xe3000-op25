#
# gl-oui-runtime: browser-side Vuex live-refresh glue for the GL SDK4 GUI
# port, plus a fallback restore page for routers that don't have the GL
# frontend installed yet. This is original code written for this port,
# unlike gl-oui-www (GL's own compiled frontend bundle, not redistributed
# here - install it yourself from your device's official firmware, or
# restore a backup made with tools/backup-gl-ui.sh through this package's
# restore-ui.html page).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-oui-runtime
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/gl-oui-runtime
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GL SDK4 GUI port - browser-side live-refresh glue
  DEPENDS:=+gl-oui-rpc
endef

define Package/gl-oui-runtime/description
  Small vanilla-JS file that keeps the GL SDK4 GUI's Internet/Multi-WAN
  cards live after page load, and doubles as a session keepalive while the
  admin page is open. Requires gl_home.html (installed by gl-oui-www) to
  reference /js/gl-port-runtime.js - this package's postinst adds that
  script tag if it's missing.

  Also installs restore-ui.html, a fallback page nginx serves at / until
  gl_home.html exists, letting a freshly-flashed router accept a GL UI
  backup tarball (see tools/backup-gl-ui.sh) through the browser instead
  of scp/ssh. Only usable before a root password is set.
endef

define Build/Compile
endef

define Package/gl-oui-runtime/install
	$(CP) ./files/* $(1)/
endef

define Package/gl-oui-runtime/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
html="$${IPKG_INSTROOT}/www/gl_home.html"
if [ -f "$$html" ] && ! grep -q 'gl-port-runtime.js' "$$html"; then
	sed -i 's#</body>#<script src="/js/gl-port-runtime.js"></script></body>#' "$$html"
fi
exit 0
endef

$(eval $(call BuildPackage,gl-oui-runtime))
