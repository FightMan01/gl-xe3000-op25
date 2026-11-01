#!/bin/sh
# The stock 4.11 Ethernet Port view renders the MAC cell only for ports in
# WAN mode:
#
#   t.isWanMode(r.mode) ? t.wanMac(r.macaddr) : ""
#
# The backend has always returned the LAN MAC (cable.get_ports_config), so
# the blank cell is purely a frontend choice. This patches the installed
# view asset to render every port's MAC. GL's compiled UI is not in this
# repository, so this must be re-applied after a UI update.
#
# Usage (on the router): /path/to/patch-ethernet-port-mac.sh
# or:                    /path/to/patch-ethernet-port-mac.sh /path/to/view.gz

set -e

VIEW=${1:-/www/views/gl-sdk4-ui-ethernet-port.common.js.gz}
[ -f "$VIEW" ] || { echo "not found: $VIEW" >&2; exit 1; }

tmp="${VIEW}.new.$$"
cp -a "$VIEW" "$VIEW.bak"
gunzip -c "$VIEW.bak" |
	sed 's#t.isWanMode(r.mode)?t.wanMac(r.macaddr):""#t.wanMac(r.macaddr)#g' |
	gzip -9 -c > "$tmp"
mv "$tmp" "$VIEW"

count=$(gunzip -c "$VIEW" | grep -c 't.isWanMode(r.mode)?t.wanMac' || true)
if [ "$count" != "0" ]; then
	echo "patch did not apply cleanly (old expression still present)" >&2
	exit 1
fi
echo "patched $VIEW (backup: $VIEW.bak)"
