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

_qcm_at() {
	# Quotes inside the AT command must be escaped for the JSON payload, or
	# ubus rejects it and commands like AT+QNWPREFCFG="..." never run.
	local cmd
	cmd="$(printf '%s' "$1" | sed 's/"/\\"/g')"
	ubus -t 8 call cellular.at command \
		"{\"cmd\":\"$cmd\",\"timeout\":6}" 2>/dev/null |
		jsonfilter -e '@.response' 2>/dev/null
}

# Release every stale modem-side PDP context that belongs to our APN, not just
# CID 1.
#
# The CID-1-only version of this existed because the modem auto-activates CID 1
# during boot even though QMI reports no call, and leaving it up makes
# StartNetwork fail with QMUX error 0x0e. But 0x0e is only the wrapper: the
# detail is in the call-end-reason TLVs, and the one that actually matters here
# is
#
#   call_end_reason 1 / type 6 / verbose 55
#     = QMI_WDS_VERBOSE_CALL_END_REASON_3GPP_MULTIPLE_CONNECTION_TO_SAME_PDN_
#       NOT_ALLOWED, i.e. 3GPP ESM cause 55 (TS 24.301): the network refused
#       the activation because a PDN connection for the same APN already
#       existed.
#
# That is what a data call which was never cleanly torn down leaves behind, and
# it recurs because a real SIM frequently has several contexts for one APN (a
# live IPv4v6 one plus stale or placeholder ones) - on the Telekom HU SIM in
# this modem's tray, the configured APN sits on CIDs well above 1. Sweeping
# only CID 1 therefore fixed the boot-time case and left the reconnect case
# failing exactly as before.
#
# Deliberately avoids `tr` character classes: this BusyBox's tr was built
# without CONFIG_FEATURE_TR_CLASSES, so `tr -d '[:space:]'` silently deletes
# the literal letters s,p,a,c,e instead of whitespace. Parse with parameter
# expansion instead (same note, same workaround as gl-cellular-boot-redial's
# pdp_cids_for_apn).
# _qcm_pdp_cids_for_apn <apn> <pdp-type>
_qcm_pdp_cids_for_apn() {
	local want_apn="$1" want_type="$2" resp line rest cid ptype apn exact other
	[ -n "$want_apn" ] || return 0
	resp="$(_qcm_at 'AT+CGDCONT?')"
	[ -n "$resp" ] || return 0

	exact=""
	other=""
	while IFS= read -r line; do
		case "$line" in
		'+CGDCONT:'*)
			rest="${line#*:}"
			rest="${rest# }"
			cid="${rest%%,*}"
			rest="${rest#*,}"
			ptype="${rest%%,*}"
			rest="${rest#*,}"
			apn="${rest%%,*}"
			ptype="${ptype#\"}"; ptype="${ptype%\"}"
			apn="${apn#\"}"; apn="${apn%\"}"
			[ "$apn" = "$want_apn" ] || continue
			case " $exact $other " in
			*" $cid "*) continue ;;
			esac
			if [ -z "$want_type" ] || [ "$ptype" = "$want_type" ]; then
				exact="$exact $cid"
			else
				other="$other $cid"
			fi
			;;
		esac
	done <<-EOF
		$resp
		EOF

	for cid in $exact $other; do echo "$cid"; done
}

# The PDP type token AT+CGDCONT uses, matching what we are about to dial.
# pdptype in any case, AT token out.
_qcm_at_ip_type() {
	case "$(echo "$1" | tr 'A-Z' 'a-z')" in
	ipv6) echo "IPV6" ;;
	ipv4|ip) echo "IP" ;;
	"") echo "" ;;
	*) echo "IPV4V6" ;;
	esac
}

# _qcm_deactivate_pdp <apn> <lower-cased pdptype>
_qcm_deactivate_pdp() {
	local want_apn="$1" want_type cids cid active
	want_type="$(_qcm_at_ip_type "$2")"
	active="$(_qcm_at 'AT+CGACT?')"
	[ -n "$active" ] || return 0

	cids="$(_qcm_pdp_cids_for_apn "$want_apn" "$want_type")"

	for cid in $cids; do
		case "$active" in
		*"+CGACT: $cid,1"*)
			logger -t gl-cellular \
				"deactivating stale modem PDP context CID $cid (APN $want_apn) before QMI dial"
			# Right after a handover the modem can refuse this for a few
			# seconds; dialling with the context still up only earns ESM
			# cause 55 again, so give it a couple more tries first.
			local try=0
			while :; do
				case "$(_qcm_at "AT+CGACT=0,$cid")" in
				*OK*) sleep 1; break ;;
				esac
				try=$((try + 1))
				[ "$try" -ge 3 ] && {
					logger -p daemon.err -t gl-cellular \
						"could not deactivate modem PDP context CID $cid"
					break
				}
				sleep 3
			done
			;;
		esac
	done

	# No APN match at all (empty AT+CGDCONT?, or our APN was never
	# programmed into a context) still leaves the boot-time auto-activation
	# that this whole dance started for: fall back to CID 1 alone, which
	# is what the previous version of this always did.
	[ -n "$cids" ] && return 0
	case "$active" in
	*'+CGACT: 1,1'*)
		logger -t gl-cellular \
			"deactivating modem default PDP context CID 1 before QMI dial"
		case "$(_qcm_at 'AT+CGACT=0,1')" in
		*OK*) sleep 1 ;;
		*) logger -p daemon.err -t gl-cellular \
			"could not deactivate modem PDP context CID 1"
		   proto_notify_error "$interface" MODEM_PDP
		   proto_block_restart "$interface"
		   return 1 ;;
		esac
		;;
	esac
	return 0
}

_qcm_deactivate_pdp "$apn" "$pdptype" || return 1

# QMI over PCIe requires the modem's PCIe personality, not its MBIM
# personality. QCFG is non-volatile; repair a stale setting left by an older
# configuration before the connection manager negotiates WDA/QMAP.
local pcie_mbim
pcie_mbim=$(ubus -t 5 call cellular.at command \
	'{"cmd":"AT+QCFG=\\"pcie_mbim\\"","timeout":5}' 2>/dev/null |
	jsonfilter -e '@.response' 2>/dev/null)
case "$pcie_mbim" in
	*'+QCFG: "pcie_mbim",1'*)
		logger -t gl-cellular "correcting modem pcie_mbim=1 to QMI mode"
		local pcie_set
		pcie_set=$(ubus -t 5 call cellular.at command \
			'{"cmd":"AT+QCFG=\\"pcie_mbim\\",0","timeout":5}' 2>/dev/null |
			jsonfilter -e '@.response' 2>/dev/null)
		case "$pcie_set" in
			*OK*) logger -t gl-cellular "modem pcie_mbim set to 0; reboot required to apply PCIe personality" ;;
			*) logger -p daemon.err -t gl-cellular "could not set modem pcie_mbim=0"; proto_notify_error "$interface" MODEM_CONFIG; proto_block_restart "$interface"; return 1 ;;
		esac
		;;
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

	# Stock sets the QMAP netdev MTU unconditionally rather than only when
	# configured, so a value inherited from an older configuration cannot
	# leave the vnd at a size the modem's aggregation will not honour. The
	# driver derives its own ceiling as mru (15KB) minus the two QMAP
	# headers, so anything up to 1500 is accepted without a modem-side
	# renegotiation.
	ip link set dev "$qmapnet" mtu "${mtu:-1500}" 2>/dev/null

	# The modem announces its IPv6 router only via RA (no DHCPv6). Accept RA
	# for the default route but keep the QMI-assigned address rather than a
	# second SLAAC one; accept_ra=2 because this router forwards.
	echo 2 > "/proc/sys/net/ipv6/conf/$qmapnet/accept_ra" 2>/dev/null
	echo 0 > "/proc/sys/net/ipv6/conf/$qmapnet/autoconf" 2>/dev/null

	# Carrier-rejection cause reporting. AT+QNETRC=7 makes the modem emit a
	# +QNETRC URC carrying the EMM/ESM/5GMM reject cause whenever the
	# network refuses a registration or an activation. This is the only
	# place the *network's* reason for a refusal is ever exposed - QMI's
	# call-end-reason says "no service" (CM_NO_SERVICE, verbose 2001) or
	# "already have this PDN" (ESM 54, verbose 55) but never why. Persisted
	# in NVM, so it is set once here rather than on every dial.
	_qcm_at 'AT+QNETRC=7' >/dev/null

	# Same reason GL's own cellular manager issues AT+QCAINFO=1 at modem
	# bring-up (its ensure_quectel_qcainfo_enabled, Quectel-only): it turns
	# on the modem's carrier-aggregation parameter reporting, which is what
	# the signal/RF readings in the UI are built from.
	_qcm_at 'AT+QCAINFO=1' >/dev/null

	# Don't dial into no service. A QMI data call against a modem that is
	# not attached cannot succeed, and attempting one anyway burns an
	# attempt in quectel-CM's 5/10/20/40/60s back-off ladder while
	# returning the generic call_end_reason 3 / type 3 / verbose 2001
	# (CM_NO_SERVICE) - which says nothing about the actual cause. Wait
	# briefly for the radio, then log why it is not there and let netifd
	# retry: the difference between "no coverage, will attach on its own"
	# and "attached but the bearer was refused" is the single most useful
	# thing a field log can contain here, and it is otherwise invisible.
	#
	# The RAT preference goes first: mode_pref is live, and a modem left on
	# a mode with no coverage here could otherwise never attach, so would
	# never get past this gate to have it corrected.
	/usr/sbin/gl-cellular-rat apply

	local waited=0 attach nosvc=/var/run/gl-cellular-qcm-nosvc
	attach="$(_qcm_at 'AT+CGATT?' | grep '^+CGATT:' | grep -oE '[0-9]+' | head -n1)"
	while [ "$waited" -lt 15 ] && [ "$attach" != "1" ]; do
		sleep 3
		waited=$((waited + 3))
		attach="$(_qcm_at 'AT+CGATT?' | grep '^+CGATT:' | grep -oE '[0-9]+' | head -n1)"
	done
	if [ "$attach" != "1" ]; then
		# netifd re-runs setup straight away, so in a long dead zone this
		# would log every ~20s: once per no-service episode is enough.
		[ -e "$nosvc" ] || {
			: > "$nosvc"
			logger -p daemon.warn -t gl-cellular \
				"not attached after ${waited}s; not dialling. cereg=[$(_qcm_at 'AT+CEREG?' | tr -d '\r\n')] cops=[$(_qcm_at 'AT+COPS?' | tr -d '\r\n')] netrc=[$(_qcm_at 'AT+QNETRC?' | tr -d '\r\n')]"
		}
		proto_notify_error "$interface" NO_SERVICE
		return 1
	fi
	rm -f "$nosvc"

	proto_run_command "$interface" env QCM_NO_DHCP4=1 QCM_EXIT_ON_PDN_CONFLICT=1 /usr/sbin/quectel-CM \
		-i "$ifname" $pdp \
		${apn:+-s "$apn" ${username:+"$username" "$password" $auth}}

	proto_init_update "$qmapnet" 1
	proto_send_update "$interface"

	# Bring the QMAP carrier up explicitly, as stock's qcm.sh does
	# (`(sleep 3; echo "0x1" > $(find /sys/devices/ -name link_state)) &`,
	# cleared to 0x0 in teardown).
	#
	# On the pcie_mhi driver this attribute is a pure software carrier flag:
	# link_state_store() only calls netif_carrier_on()/off() on rmnet_mhi0 and
	# rmnet_mhi0.1, and both netdevs are registered with carrier OFF - so
	# nothing brings the QMAP vnd up except this write. quectel-CM does it
	# too, from the first statement of udhcpc_start(), which is reached even
	# with QCM_NO_DHCP4 set - but that couples the carrier to a DHCP code
	# path this configuration deliberately bypasses. Doing it here costs
	# nothing, is idempotent, and removes the dependency.
	#
	# Only while a quectel-CM is running: a teardown inside the 3s must not
	# be followed by this raising the carrier on a vnd with no session.
	(
		sleep 3
		[ -w "/sys/class/net/$ifname/link_state" ] || exit 0
		pidof quectel-CM >/dev/null || exit 0
		echo "0x1" > "/sys/class/net/$ifname/link_state" 2>/dev/null
	) &

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
	# Stock also drops the QMAP carrier on teardown, and it matters for the
	# same reason it is raised on setup: rmnet_mhi0.1's carrier is derived
	# from rmnet_mhi0's, so leaving it set across a teardown reports a live
	# carrier on a vnd with no session behind it.
	[ -w "/sys/class/net/$ifname/link_state" ] &&
		echo "0x0" > "/sys/class/net/$ifname/link_state" 2>/dev/null
	sed -i "/# IPV[46] ${ifname}\.1\$/d" /etc/resolv.conf 2>/dev/null
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qcm
}
