#
# quectel-CM: Quectel QConnectManager V1.6.8 userspace QMI/QMAP connection
# manager. Drives the RM520N-GL's PCIe/MHI QMI data path (paired with the
# kmod-pcie_mhi kernel driver) instead of mainline MBIM, which wedges under
# sustained load on this modem. Vendored from QuectelWB/q_drivers with two
# changes: QCM_NO_DHCP4 env var (skip CM's own IPv4 config so netifd's dhcp
# proto owns it) and Makefile.am listed the nonexistent MPQMUX.c instead of QCQMUX.c (the
# OpenWrt package below doesn't use the autotools build, but the fix keeps
# ./src buildable standalone too).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=quectel-cm
PKG_VERSION:=1.6.8
PKG_RELEASE:=2

PKG_LICENSE:=Quectel-Software-License
PKG_LICENSE_FILES:=src/NOTICE

include $(INCLUDE_DIR)/package.mk

define Package/quectel-cm
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN Support
  TITLE:=Quectel QConnectManager (QMI/QMAP connection manager)
  DEPENDS:=+kmod-pcie_mhi
endef

define Package/quectel-cm/description
  Quectel's quectel-CM userspace connection manager, built from
  QConnectManager_Linux_V1.6.8 (only quectel-CM is shipped, no proxies). Drives the QMI/QMAP data path over the
  pcie_mhi kernel driver for the RM520N-GL modem on the GL-XE3000.
endef

QL_CM_SRC = \
	QmiWwanCM.c GobiNetCM.c main.c QCQMUX.c QMIThread.c util.c \
	qmap_bridge_mode.c mbim-cm.c device.c atc.c atchannel.c at_tok.c \
	udhcpc.c

TARGET_CFLAGS += -Wno-error

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/*.c ./src/*.h $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) \
		$(addprefix $(PKG_BUILD_DIR)/,$(QL_CM_SRC)) \
		-o $(PKG_BUILD_DIR)/quectel-CM \
		$(TARGET_LDFLAGS) -lpthread
endef

define Package/quectel-cm/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/quectel-CM $(1)/usr/sbin/quectel-CM
endef

$(eval $(call BuildPackage,quectel-cm))
