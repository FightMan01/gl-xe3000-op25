# gl-xe3000-op25

GL.iNet GL-XE3000 backend packages, rebuilt to run on stock OpenWrt 25.x instead of GL's own SDK4 firmware.

The XE3000 normally ships with a customized OpenWrt build wired to GL's closed SDK4 stack: a SQLite-backed session daemon, a proprietary MediaTek wifi driver, a closed cellular management daemon, and so on. This repo replaces all of that with packages built against plain, mainline OpenWrt: hostapd/wpad-full instead of GL's wifi driver, mac80211/mt76, mwan3 for multi-WAN, netifd's `mbim` proto for the modem, and a from-scratch `/rpc` + `/ws` backend that speaks the exact same wire protocol GL's own frontend expects.

GL's actual GUI (the compiled Vue.js frontend, package `gl-oui-www` in the original firmware) is **not** included here - that's GL's compiled output, not something to redistribute. Pull those files off your own router's official firmware (or GL's downloads page) and drop them in `/www` alongside these packages. Everything in this repo is what serves and drives that GUI, not the GUI itself.

## What's here

- **gl-oui-rpc** - the `/rpc` and `/ws` handlers, the session/login daemon, and most per-page backends (wifi, LAN/guest/IoT, firewall, multi-WAN, system status, clients, scheduled tasks, DNS, IPv6, USB, tailscale, and more)
- **gl-oui-runtime** - a small vanilla-JS file that keeps the Internet/Multi-WAN status cards live without needing a page refresh (this is original code, not vendored from GL)
- **gl-cellular** - RM520N-GL modem management over its AT port (SIM/APN config, band locking, cell tower scanning, SMS), plus the PCIe/MHI wiring for the actual data connection
- **gl-mcu** - the onboard battery/MCU controller daemon (UART, JSON wire protocol with GL's byte-substitution framing)
- **gl-repeater** - WiFi repeater/bridge mode uplink, using a STA interface + double-NAT so it also works against WPA2/3-Enterprise networks (eduroam and the like), which WDS-based repeating never does
- **openwrt-patches** - the handful of kernel/package patches this needs: the MHI PCI ID for the modem, turning off PCIe port power management (stops a reset loop on this hardware), an mbim data-interface fix, and a small lua-cjson patch so an empty list serializes as `[]` instead of `{}`
- **build-config** - misc build-time package config (ksmbd)

## Building

Add `gl-feed/net/*` to your OpenWrt package feed, apply the patches in `openwrt-patches/` against the matching kernel/package sources, then select the packages under `make menuconfig` (Network section) and build as usual.

## Status

Day-to-day this runs wifi, LAN/guest/IoT networks, the firewall, multi-WAN failover, the cellular modem (LTE and 5G NSA), repeater mode, USB tethering, and the battery/MCU controller. A few things are honestly stubbed rather than faked: eSIM, remote APN database updates, DPI-based per-app traffic stats, and OLED screen scheduling (this device has no screen).

Tested on a physical XE3000. Issues and pull requests welcome.
