#
# Copyright (C) 2015 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

# 1.3.8 is Quectel's last publicly mirrored release of the driver. What builds
# here is 1.3.8 with this port's own data-path fixes applied on top; they live
# in src/ like the rest of the vendored tree, so `git log`/`git diff` on
# gl-feed/kernel/pcie_mhi is the reviewable delta against stock. They are
# called out in the description below because each one is a behavioural fix to
# a bug that produced a data call which came up, completed a DHCP lease, and
# then carried nothing.
#
# A newer Quectel build exists (V1.4, sources dated 2025-08-11, and it ships a
# User Guide that V1.3.8 never had), but Quectel only releases it through a
# support ticket, so it cannot be built from a feed. Ask for it - and expect
# to re-audit these fixes against it, since V1.4 rewrote mhi_main.c and
# mhi_pm.c heavily.
PKG_VERSION:=1.3.8
PKG_RELEASE:=3

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
  V1.3.8, GPLv2), the same driver GL's stock firmware uses for the RM520N-GL,
  plus data-path robustness fixes needed to run it as a router's uplink
  rather than as a desktop modem:
   - hold a runtime PM reference while the QMAP interface is enabled, and only
     permit the M3 autosuspend from M2. Defensive: runtime PM is never
     allowed on this device (probe leaves the PCI core's forbid in place and
     gl-cellular-pcie-pm writes power/control=on), so this only matters if
     someone writes power/control=auto
   - never let the receive-buffer top-up give up: it only retried on -ENOMEM
     and gave up on -EIO, after which the DL ring stayed short of TREs forever
     and the modem had nowhere to put data
   - honour QMAP flow control (it was a "//TODO return 0" that ACKed the modem
     without stopping anything), with mainline rmnet's semantics and a
     bounded 5s stop
   - the debugfs channel reset wakes the TX queues afterwards, so a queue
     that was stopped when the reset ran does not stay stopped
   - release/acquire ordering on the ring rp, so the producer cannot reuse a
     slot before the consumer has finished reading it
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
