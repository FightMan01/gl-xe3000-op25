#!/bin/sh
# Multi-WAN members must not carry flush_conntrack (a whole-table flush in
# mwan3), on a fresh install and after the migration of an older config.
set -eu
D=/feed/gl-oui-rpc/files/etc/uci-defaults
cp /feed/mwan3-nft/files/etc/config/mwan3 /etc/config/mwan3
touch /etc/config/network

fail() { echo "FAIL: $*"; uci show mwan3 | grep flush_conntrack || :; exit 1; }

# Fresh install: the seeding scripts, then the migration, in uci-defaults order.
for s in 94-gl-oui-kmwan 94-gl-oui-kmwan-conntrack 94-gl-oui-kmwan-v6 94-gl-oui-tethering-v6; do
	sh "$D/$s" >/dev/null 2>&1 || fail "$s exited non-zero"
done
for i in wan wwan_4 wwan_6 repeater tethering tethering6; do
	[ "$(uci -q get mwan3.$i)" = interface ] || fail "fresh: mwan3.$i missing"
done
uci -q show mwan3 | grep -q flush_conntrack && fail "fresh install still has flush_conntrack"

# Upgrade: every member carries the old default; two members were set up
# differently by the user and keep their value.
for i in wan wwan_4 wwan_6 repeater tethering tethering6; do
	uci -q delete mwan3.$i.flush_conntrack || :
	uci add_list mwan3.$i.flush_conntrack=ifdown
	uci add_list mwan3.$i.flush_conntrack=ifup
done
uci -q delete mwan3.repeater.flush_conntrack
uci add_list mwan3.repeater.flush_conntrack=ifdown
uci set mwan3.mine=interface
uci add_list mwan3.mine.flush_conntrack=ifup
uci add_list mwan3.mine.flush_conntrack=ifdown
uci commit mwan3

sh "$D/94-gl-oui-kmwan-conntrack" || fail "migration exited non-zero"
for i in wan wwan_4 wwan_6 tethering tethering6; do
	[ -z "$(uci -q get mwan3.$i.flush_conntrack)" ] || fail "upgrade: $i kept the old default"
done
[ "$(uci -q get mwan3.repeater.flush_conntrack)" = ifdown ] || fail "upgrade: user's repeater value lost"
[ "$(uci -q get mwan3.mine.flush_conntrack)" = "ifup ifdown" ] || fail "upgrade: an interface it does not own was changed"

# Idempotent: a second run changes nothing.
cp /etc/config/mwan3 /tmp/mwan3.before
sh "$D/94-gl-oui-kmwan-conntrack" || fail "second run exited non-zero"
cmp -s /etc/config/mwan3 /tmp/mwan3.before || fail "second run changed the config"
[ -z "$(uci changes mwan3)" ] || fail "second run left uncommitted changes"
echo "kmwan-conntrack: all checks passed"
