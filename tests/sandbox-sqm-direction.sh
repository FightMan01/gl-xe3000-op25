#!/bin/sh
# Which way does each sqm-scripts rate shape when the queue sits on br-lan?
#
#   tests/sandbox-sqm-direction.sh <openwrt-25.12.x-x86-64-rootfs.tar.gz>
#
# Needs docker with --privileged (network namespaces, a bridge, tc) and
# network access once, for `apk add` from the official 25.12 feeds. Nothing
# runs on a router.
#
#  1. Runs the real /usr/lib/sqm/run.sh for an sqm queue on br-lan with
#     upload=5000 / download=50000 (kbit/s), with tc and ip replaced by a
#     logger, and prints which device each rate lands on.
#  2. Puts that same egress shaper (HTB at the upload rate; this kernel has
#     no cake, fq_codel or ifb) on a real br-lan and measures, with iperf3,
#     router -> LAN client (what a LAN client downloads) and LAN client ->
#     router (what it uploads).
set -eu

ROOTFS="$1"
IMAGE=gl-uci-defaults-test:$(shasum -a 256 "$ROOTFS" | cut -c1-12)
docker image inspect "$IMAGE" >/dev/null 2>&1 ||
	docker import --platform linux/amd64 "$ROOTFS" "$IMAGE" >/dev/null

docker run --rm --platform linux/amd64 --privileged "$IMAGE" /bin/sh -c '
set -e
mkdir -p /var/lock /tmp/run /var/run/sqm
apk update >/dev/null 2>&1
apk add sqm-scripts tc-full ip-full iperf3 >/dev/null 2>&1

cat > /etc/config/sqm <<EOF
config queue gl
	option enabled 1
	option interface br-lan
	option script simple.qos
	option qdisc fq_codel
	option upload 5000
	option download 50000
	option linklayer none
	option qdisc_advanced 0
EOF

echo "== 1. what sqm-scripts asks tc for (upload=5000, download=50000)"
mkdir -p /tmp/shim
for t in tc ip; do
	printf "#!/bin/sh\necho \"%s \$*\" >> /tmp/shim.log\n[ \"\$1\" = -V ] && echo \"tc utility, iproute2-6\"\nexit 0\n" "$t" > /tmp/shim/$t
	chmod 755 /tmp/shim/$t
done
ip link add br-lan type bridge; ip link set br-lan up
PATH=/tmp/shim:$PATH SQM_DEBUG=0 /usr/lib/sqm/run.sh start br-lan >/dev/null 2>&1 || :
grep -E "(qdisc|class) (add|replace)|mirred|ifb" /tmp/shim.log | grep -E "rate|mirred|type ifb" |
	sed "s/^/   /" | sort -u

echo "== 2. HTB at the upload rate on br-lan egress, measured both ways"
ip netns add client
ip link add lan0 type veth peer name c0
ip link set c0 netns client
ip link set lan0 master br-lan; ip link set lan0 up
ip addr add 192.168.9.1/24 dev br-lan
ip -n client addr add 192.168.9.2/24 dev c0; ip -n client link set c0 up; ip -n client link set lo up
tc qdisc add dev br-lan root handle 1: htb default 10
tc class add dev br-lan parent 1: classid 1:10 htb rate 5000kbit ceil 5000kbit
iperf3 -s -D -B 192.168.9.1 >/dev/null
sleep 1
down=$(ip netns exec client iperf3 -c 192.168.9.1 -R -t 4 -f m | awk "/receiver/ {print \$7}")
up=$(ip netns exec client iperf3 -c 192.168.9.1 -t 4 -f m | awk "/receiver/ {print \$7}")
echo "   LAN client download (router -> client): ${down} Mbit/s"
echo "   LAN client upload   (client -> router): ${up} Mbit/s"
'
