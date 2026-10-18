#!/bin/sh
# Called by /etc/init.d/packet_steering in place of packet-steering.uc.
#
# QMAP mux children (rmnet_mhi0.N) are fed by the parent's rx_handler, which
# already runs on the CPU that rmnet_mhi0's RPS picked. Steering the child as
# well bounces every downlink packet back to the CPU taking the MHI interrupt,
# so routing and NAT end up on the same core as the modem and the Ethernet
# NAPI. Leave the children unsteered.

flows=$(uci -q get network.@globals[0].steering_flows)
[ "${flows:-0}" -gt 0 ] && set -- -l "$flows" "$@"

/usr/libexec/network/packet-steering.uc "$@"

for q in /sys/class/net/rmnet_mhi*.*/queues/rx-*/rps_cpus; do
	[ -e "$q" ] && echo 0 > "$q"
done
exit 0
