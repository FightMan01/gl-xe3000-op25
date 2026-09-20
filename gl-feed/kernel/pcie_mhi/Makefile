#
# Copyright (C) 2015 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=pcie_mhi
PKG_VERSION:=1.3.8
PKG_RELEASE:=2

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/pcie_mhi
  SUBMENU:=WWAN Support
  TITLE:=Quectel PCIe/MHI driver (QMI/QMAP data path)
  FILES:=$(PKG_BUILD_DIR)/pcie_mhi.ko
  AUTOLOAD:=$(call AutoLoad,90,pcie_mhi,1)
endef

define KernelPackage/pcie_mhi/description
  Quectel's out-of-tree PCIe/MHI driver (Quectel_Linux_PCIE_MHI_Driver
  V1.3.8, GPLv2), the same driver GL's stock firmware uses for the RM520N-GL.
  Exposes /dev/mhi_QMI0 (QMI control) and rmnet_mhi0/rmnet_mhi0.1 (QMAP
  data). Self-contained: does not use the mainline mhi bus, so no
  kmod-mhi-* package may be installed alongside it - mainline
  mhi-pci-generic matches the same PCI ID and would race it for the device.
endef

MAKE_OPTS:= \
	ARCH="$(LINUX_KARCH)" \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	CXXFLAGS="$(TARGET_CXXFLAGS)" \
	M="$(PKG_BUILD_DIR)" \
	$(EXTRA_KCONFIG)

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(MAKE_OPTS) \
		modules
endef

$(eval $(call KernelPackage,pcie_mhi))
