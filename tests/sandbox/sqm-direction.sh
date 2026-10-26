#!/bin/sh
# 98-gl-sqm-direction swaps a br-lan queue written by the old SQM page once,
# and leaves marked queues and queues on other devices alone.
set -eu
D=/feed/gl-oui-rpc/files/etc/uci-defaults

fail() { echo "FAIL: $*"; uci show sqm; exit 1; }

# Old page: entered upload 10, download 100 (Mbit/s), stored unswapped.
cat > /etc/config/sqm <<'EOF'
config queue 'eth1'
	option enabled '1'
	option interface 'br-lan'
	option upload '10000'
	option download '100000'
EOF
sh "$D/98-gl-sqm-direction" || fail "exited non-zero"
[ "$(uci get sqm.eth1.upload)" = 100000 ] || fail "egress not set to the page's download"
[ "$(uci get sqm.eth1.download)" = 10000 ] || fail "ingress not set to the page's upload"
[ "$(uci get sqm.eth1.gl_lan_swap)" = 1 ] || fail "no marker"

cp /etc/config/sqm /tmp/sqm.before
sh "$D/98-gl-sqm-direction" || fail "second run exited non-zero"
cmp -s /etc/config/sqm /tmp/sqm.before || fail "second run swapped again"

# Written by the new page (marked): untouched.
cat > /etc/config/sqm <<'EOF'
config queue 'gl'
	option interface 'br-lan'
	option upload '100000'
	option download '10000'
	option gl_lan_swap '1'
EOF
cp /etc/config/sqm /tmp/sqm.before
sh "$D/98-gl-sqm-direction"
cmp -s /etc/config/sqm /tmp/sqm.before || fail "a marked queue was changed"

# A queue on a WAN device (sqm-scripts' own default): untouched.
cat > /etc/config/sqm <<'EOF'
config queue 'eth1'
	option interface 'eth1'
	option upload '10000'
	option download '85000'
EOF
cp /etc/config/sqm /tmp/sqm.before
sh "$D/98-gl-sqm-direction"
cmp -s /etc/config/sqm /tmp/sqm.before || fail "a non-br-lan queue was changed"

# Fresh install: the seed is marked, so the migration leaves it as is.
rm /etc/config/sqm; touch /etc/config/sqm
sh "$D/98-gl-sqm-default" >/dev/null 2>&1 || :
sh "$D/98-gl-sqm-direction"
[ "$(uci get sqm.gl.gl_lan_swap)" = 1 ] || fail "seeded queue not marked"
echo "sqm-direction: all checks passed"
