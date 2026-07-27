# gl-xe3000-op25

GL.iNet GL-XE3000 backend packages, rebuilt to run on stock OpenWrt 25.x instead of GL's own SDK4 firmware.

The XE3000 normally ships with a customized OpenWrt build wired to GL's closed SDK4 stack: a SQLite-backed session daemon, a proprietary MediaTek wifi driver, a closed cellular management daemon, and so on. This repo replaces all of that with packages built against plain, mainline OpenWrt: hostapd/wpad-full instead of GL's wifi driver, mac80211/mt76, mwan3 for multi-WAN, netifd's `mbim` proto for the modem, and a from-scratch `/rpc` + `/ws` backend that speaks the exact same wire protocol GL's own frontend expects.

GL's actual GUI (the compiled Vue.js frontend, package `gl-oui-www` in the original firmware) is **not** included here - that's GL's compiled output, not something to redistribute. Everything in this repo is what serves and drives that GUI, not the GUI itself. You have two ways to get the GUI onto a router running this port:

- Pull the files off your own router's official firmware (or GL's downloads page) and drop them in `/www` and `/usr/share/oui/menu.d` yourself, or
- back them up before you flash and restore them afterward through the browser - see [Flashing](#flashing) below.

## What's here

- **gl-oui-rpc** - the `/rpc` and `/ws` handlers, the session/login daemon, and most per-page backends (wifi, LAN/guest/IoT, firewall, multi-WAN, system status, clients, scheduled tasks, DNS, IPv6, USB, tailscale, and more)
- **gl-oui-runtime** - a small vanilla-JS file that keeps the Internet/Multi-WAN status cards live without needing a page refresh, plus a fallback restore page for getting the GL GUI back after flashing (both original code, not vendored from GL)
- **gl-cellular** - RM520N-GL modem management over its AT port (SIM/APN config, band locking, cell tower scanning, SMS), plus the PCIe/MHI wiring for the actual data connection
- **gl-mcu** - the onboard battery/MCU controller daemon (UART, JSON wire protocol with GL's byte-substitution framing)
- **gl-repeater** - WiFi repeater/bridge mode uplink, using a STA interface + double-NAT so it also works against WPA2/3-Enterprise networks (eduroam and the like), which WDS-based repeating never does
- **openwrt-patches** - the handful of kernel/package patches this needs: the MHI PCI ID for the modem, turning off PCIe port power management (stops a reset loop on this hardware), an mbim data-interface fix, and a small lua-cjson patch so an empty list serializes as `[]` instead of `{}`
- **build-config** - misc build-time package config (ksmbd)
- **tools/backup-gl-ui.sh** - pulls the GL GUI files off a router that's still on stock firmware, so you can restore them after flashing

## Flashing

### Device ID mismatch - this is expected, not a sign something's wrong

GL.iNet's own firmware identifies this hardware as `glinet,xe3000-emmc`. Mainline OpenWrt's device profile for the same board is `glinet,gl-xe3000` - same hardware, just a different vendor/mainline naming convention (the X3000 has the identical mismatch: `glinet,x3000-emmc` vs `glinet,gl-x3000`). Because of that, going from GL's firmware straight to an OpenWrt sysupgrade image will fail its board-name check, and LuCI's web upload can't get around it at all.

To flash over SSH from GL's stock firmware, use the force flag:

```
sysupgrade -F -v -n /openwrt-mediatek-filogic-glinet_gl-xe3000-squashfs-sysupgrade.bin
```

You'll see `Device glinet,xe3000-emmc not supported by this image. Supported devices: glinet,gl-xe3000`, then `-F` overrides it. Use the **sysupgrade** image, not the factory one. `-n` skips trying to carry over GL's config, which uses a completely different schema anyway. If you'd rather avoid the board-name check entirely, GL's U-Boot also has a web recovery page (hold reset while powering on) that takes the same sysupgrade image with no check at all.

If your router's U-Boot is old enough to predate GL's official OpenWrt support for this board, update it to a current GL firmware release first - the mainline OpenWrt image assumes a reasonably current U-Boot.

Sources: [openwrt/openwrt PR #14142](https://github.com/openwrt/openwrt/pull/14142), [OpenWrt forum - GL-X3000 support thread](https://forum.openwrt.org/t/gl-inet-gl-x3000-spitz-ax-support/162143/87), [GL.iNet forum - OpenWrt on XE3000](https://forum.gl-inet.com/t/howto-openwrt-24-10-2-on-xe3000/60994)

### Trying it without building anything

1. While the router is still on GL's stock firmware, back up the GUI files:
   ```
   scp tools/backup-gl-ui.sh root@192.168.8.1:/tmp/
   ssh root@192.168.8.1 /tmp/backup-gl-ui.sh
   scp root@192.168.8.1:/tmp/gl-ui-backup.tar.gz .
   ```
2. Flash a build of this port using the force-flash steps above.
3. Visit the router's IP in a browser. Since the GL GUI isn't installed yet, you'll land on a plain "Restore GL UI" page instead - upload `gl-ui-backup.tar.gz` there and it unpacks itself into place. (This page only works before you've set an admin password - it's a one-time bootstrap step, not a standing feature.)

## Building from source

You'll need a real OpenWrt source checkout, not just the SDK - the kernel patches under `openwrt-patches/mediatek-filogic/` touch `target/linux`, which the SDK doesn't build.

1. Clone OpenWrt and check out a tree with GL-XE3000 device support (mainline picked this up as `glinet_gl-xe3000` in `target/linux/mediatek/image/filogic.mk`):
   ```
   git clone https://github.com/openwrt/openwrt.git
   cd openwrt
   ```
2. Point a feed at this repo's `gl-feed` directory:
   ```
   echo "src-link gl_feed /absolute/path/to/gl-xe3000-op25/gl-feed" >> feeds.conf.default
   ./scripts/feeds update -a
   ./scripts/feeds install -a
   ```
3. Apply the kernel patches - copy both files into whichever `target/linux/mediatek/patches-*/` directory matches your tree's kernel version:
   ```
   cp openwrt-patches/mediatek-filogic/*.patch target/linux/mediatek/patches-6.18/
   ```
4. Apply the `umbim` and `lua-cjson` patches against those packages' own `patches/` directories (wherever your feeds checked them out, typically under `feeds/packages/net/umbim/patches/` and `feeds/packages/utils/lua-cjson/patches/`).
5. `make menuconfig` - Target System: MediaTek Ralink/Filogic, Subtarget: filogic, Target Profile: GL.iNet GL-XE3000. Under Network, select `gl-oui-rpc`, `gl-oui-runtime`, `gl-cellular`, `gl-mcu`, `gl-repeater`, plus `mwan3` and `wpad-full` if they aren't already pulled in as dependencies.
6. `make -j$(nproc) V=s`

The resulting `*-sysupgrade.bin` under `bin/targets/mediatek/filogic/` is what you flash per the [Flashing](#flashing) section above.

## Status

Day-to-day this runs wifi, LAN/guest/IoT networks, the firewall, multi-WAN failover, the cellular modem (LTE and 5G NSA), repeater mode, USB tethering, and the battery/MCU controller. A few things are honestly stubbed rather than faked: eSIM, remote APN database updates, DPI-based per-app traffic stats, and OLED screen scheduling (this device has no screen).

Tested on a physical XE3000. Issues and pull requests welcome.
