#!/bin/sh
# Rebind protection stays on; only the pending portal's login host may
# resolve to a private address. Checks 91-gl-repeater-dns-rebind, then a real
# dnsmasq with the include gl-repeater-portal writes
# (tests/test_portal_rebind.py checks that it writes exactly this line).
set -eu
D=/feed/gl-repeater/files/etc/uci-defaults

fail() { echo "FAIL: $*"; uci -q show dhcp.@dnsmasq[0] || :; exit 1; }

cat > /etc/config/dhcp <<'EOF'
config dnsmasq
	option rebind_protection '0'
	option domainneeded '1'
EOF
sh "$D/91-gl-repeater-dns-rebind" || fail "exited non-zero"
[ "$(uci get dhcp.@dnsmasq[0].rebind_protection)" = 1 ] || fail "old global off not turned back on"
[ "$(uci get dhcp.@dnsmasq[0].gl_rebind_portal)" = 1 ] || fail "no marker"

# The user turns it off again on purpose: a re-run (sysupgrade) keeps that.
uci set dhcp.@dnsmasq[0].rebind_protection=0; uci commit dhcp
cp /etc/config/dhcp /tmp/dhcp.before
sh "$D/91-gl-repeater-dns-rebind"
cmp -s /etc/config/dhcp /tmp/dhcp.before || fail "a deliberate rebind_protection=0 was overridden"

# Fresh install (OpenWrt's default is on): stays on, gets the marker.
printf "config dnsmasq\n\toption rebind_protection '1'\n" > /etc/config/dhcp
sh "$D/91-gl-repeater-dns-rebind"
[ "$(uci get dhcp.@dnsmasq[0].rebind_protection)" = 1 ] || fail "fresh install turned off"

# Functional: a "portal" resolver answers private addresses for two names;
# the LAN resolver (rebind protection on) gets the exception for one.
dnsmasq --port=5353 --listen-address=127.0.0.2 --bind-interfaces --no-resolv --no-hosts \
	--address=/login.portal.test/192.168.50.1 --address=/other.test/192.168.50.2 \
	--pid-file=/tmp/portal-dns.pid
mkdir -p /tmp/lan.d
printf 'rebind-domain-ok=/login.portal.test/\n' > /tmp/lan.d/gl-repeater-portal-rebind.conf
dnsmasq --port=53 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
	--server=127.0.0.2#5353 --stop-dns-rebind --conf-dir=/tmp/lan.d --pid-file=/tmp/lan-dns.pid
sleep 1
nslookup login.portal.test 127.0.0.1 2>&1 | grep -q '192.168.50.1' || fail "allowed portal host did not resolve"
nslookup other.test 127.0.0.1 2>&1 | grep -q '192.168.50.2' && fail "rebind protection let another private answer through"
echo "dns-rebind: all checks passed"
