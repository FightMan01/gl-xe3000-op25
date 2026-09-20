#!/bin/sh
# netifd proto "qcm": Quectel pcie_mhi + quectel-CM QMI/QMAP data path for
# the RM520N-GL. Modelled on GL's stock qcm.sh (same proto name, same
# structure: netifd supervises the connection manager with proto_run_command
# and IP comes from dynamic <iface>_4/_6 children), minus its dependency on
# GL's closed cellular manager (lib/functions/modem.sh).
#
# quectel-CM runs with QCM_NO_DHCP4 so it does not configure IPv4 itself;
# the wwan_4 child runs netifd's dhcp proto on the QMAP netdev, where the
# modem answers DHCP with the address the QMI data call negotiated. IPv6
# (the modem does no DHCPv6) is applied by quectel-CM from QMI data, then
# mirrored into a static wwan_6 child so netifd knows about it.
#
# The parent interface's L3 device is the QMAP netdev rmnet_mhi0.1 (mux
# 0x81, pcie_mhi qmap_mode=1); rmnet_mhi0 is the carrier link CM brings up.

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_qcm_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string ifname
	proto_config_add_string apn
	proto_config_add_string pincode
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pdptype
	proto_config_add_string ipv6
	proto_config_add_int mtu
	proto_config_add_defaults
}

_qcm_dns() {
	# DNS servers quectel-CM tagged into resolv.conf for family $1 ("4"/"6"),
	# removing those lines so netifd is the only writer.
	local fam="$1" dev="$2"
	[ -f /etc/resolv.conf ] || return
	sed -n "s/^nameserver \([^ ]*\) # IPV$fam $dev\$/\1/p" /etc/resolv.conf
	sed -i "/# IPV$fam $dev\$/d" /etc/resolv.conf
}

proto_qcm_setup() {
	local interface="$1"
	local device ifname apn pincode auth username password pdptype ipv6 mtu
	local $PROTO_DEFAULT_OPTIONS
	json_get_vars device ifname apn pincode auth username password pdptype ipv6 mtu $PROTO_DEFAULT_OPTIONS

	device="${device:-/dev/mhi_QMI0}"
	ifname="${ifname:-rmnet_mhi0}"
	local qmapnet="${ifname}.1"

	# pcie_mhi autoloads early in boot but the MHI channels come up a few
	# seconds after the PCI probe.
	local i=0
	while [ ! -c "$device" ] || [ ! -e "/sys/class/net/$qmapnet" ]; do
		i=$((i + 1))
		[ "$i" -gt 40 ] && {
			echo "qcm[$$] $device / $qmapnet missing - is pcie_mhi loaded?"
			proto_notify_error "$interface" NO_DEVICE
			proto_set_available "$interface" 0
			return 1
		}
		sleep 1
	done

	# Like stock GL, never start the connection manager until the SIM is
	# READY. Starting it while the SIM is PIN-locked makes the modem refuse
	# the QMAP data-format request (QMUX 0x46) and every data call after it.
	# gl-cellular-sim-unlock enters the saved PIN if safe to do so.
	/usr/sbin/gl-cellular-sim-unlock
	case $? in
		0) ;;
		1) proto_notify_error "$interface" PIN_REQUIRED
		   proto_block_restart "$interface"; return 1 ;;
		2) proto_notify_error "$interface" PIN_FAILED
		   proto_block_restart "$interface"; return 1 ;;
		3) proto_notify_error "$interface" NO_SIM
		   proto_block_restart "$interface"; return 1 ;;
		*) proto_notify_error "$interface" AT_UNAVAILABLE
		   sleep 10; return 1 ;;
	esac

	local pdp="-4 -6"
	[ ! -e /proc/sys/net/ipv6 ] && ipv6=0
	pdptype=$(echo "$pdptype" | awk '{print tolower($0)}')
	[ "$ipv6" = 0 ] && pdptype="ipv4"
	case "$pdptype" in
		ipv4) pdp="-4" ;;
		ipv6) pdp="-6" ;;
	esac

	case "$auth" in
		pap|PAP) auth=1 ;;
		chap|CHAP) auth=2 ;;
		both|mschapv2|"pap chap"|BOTH) auth=3 ;;
		*) auth="" ;;
	esac
	[ -z "$username" ] && { password=""; auth=""; }

	[ -n "$mtu" ] && ip link set dev "$qmapnet" mtu "$mtu" 2>/dev/null

	# The modem announces its IPv6 router only via RA (no DHCPv6). Accept RA
	# for the default route but keep the QMI-assigned address rather than a
	# second SLAAC one; accept_ra=2 because this router forwards.
	echo 2 > "/proc/sys/net/ipv6/conf/$qmapnet/accept_ra" 2>/dev/null
	echo 0 > "/proc/sys/net/ipv6/conf/$qmapnet/autoconf" 2>/dev/null

	proto_run_command "$interface" env QCM_NO_DHCP4=1 /usr/sbin/quectel-CM \
		-i "$ifname" $pdp \
		${apn:+-s "$apn" ${username:+"$username" "$password" $auth}}

	proto_init_update "$qmapnet" 1
	proto_send_update "$interface"

	local zone="$(fw3 -q network "$interface" 2>/dev/null)"

	[ "$pdp" != "-6" ] && {
		json_init
		json_add_string name "${interface}_4"
		json_add_string ifname "@$interface"
		json_add_string proto "dhcp"
		proto_add_dynamic_defaults
		[ -n "$zone" ] && json_add_string zone "$zone"
		[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	[ "$pdp" != "-4" ] && {
		# CM applies the QMI-provided IPv6 address once the call is up.
		# Wait for it (the modem may still be attaching) then hand it to
		# netifd; give up quietly if it never shows so v4 still works.
		local n=0 a6=""
		while [ "$n" -lt 60 ]; do
			a6=$(ip -6 -o addr show dev "$qmapnet" scope global 2>/dev/null | awk '{print $4; exit}')
			[ -n "$a6" ] && break
			n=$((n + 1))
			sleep 1
		done
		if [ -n "$a6" ]; then
			local dns6=$(_qcm_dns 6 "$qmapnet")
			local gw6="" g=0
			while [ "$g" -lt 15 ]; do
				gw6=$(ip -6 route show default dev "$qmapnet" 2>/dev/null | awk '/ via /{print $3; exit}')
				[ -n "$gw6" ] && break
				g=$((g + 1))
				sleep 1
			done
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			json_add_string proto "static"
			json_add_array ip6addr; json_add_string "" "$a6"; json_close_array
			json_add_array ip6prefix; json_add_string "" "$a6"; json_close_array
			[ -n "$gw6" ] && json_add_string ip6gw "$gw6"
			[ "$peerdns" = 0 ] || {
				json_add_array dns
				for s in $dns6; do json_add_string "" "$s"; done
				json_close_array
			}
			proto_add_dynamic_defaults
			[ -n "$zone" ] && json_add_string zone "$zone"
			[ -n "$ip6table" ] && json_add_string ip6table "$ip6table"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
		else
			echo "qcm[$$] no IPv6 address on $qmapnet after 60s"
		fi
	}
}

proto_qcm_teardown() {
	local interface="$1"
	local ifname
	json_get_vars ifname
	ifname="${ifname:-rmnet_mhi0}"

	proto_kill_command "$interface"
	sed -i "/# IPV[46] ${ifname}\.1\$/d" /etc/resolv.conf 2>/dev/null
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qcm
}
