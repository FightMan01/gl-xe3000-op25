-- "network" RPC object: advanced network config, ARP, NAT. The MTK
-- HW-NAT hotplug hook is a separate, platform-level concern independent
-- of this object. WAN status itself is cable.get_status's job elsewhere
-- in this feed, not here.

local ubus = require "ubus"
local uci = require "uci"
local cjson = require "cjson"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

return {
	-- cable_enabled tracks whether the WAN-role port itself is
	-- administratively up (distinct from physical presence - a
	-- swapped-out port via set_port_config could be "enabled" with
	-- nothing plugged in). macclone_enabled reports that WAN MAC cloning
	-- is a capability of this port, not that a clone is currently active.
	check_wan_cable = function(args)
		local conn = ubus.connect()
		local cable_inserted = false
		if conn then
			local status = conn:call("network.interface.wan", "status", {})
			conn:close()
			local device = status and (status.l3_device or status.device)
			if device then
				local f = io.open("/sys/class/net/" .. device .. "/carrier", "r")
				if f then
					local v = f:read("*l")
					f:close()
					cable_inserted = v == "1"
				end
			end
		end
		local cursor = uci.cursor()
		local wan_disabled = cursor:get("network", "wan", "disabled") == "1"
		return {
			cable_enabled = not wan_disabled,
			cable_inserted = cable_inserted,
			macclone_enabled = true,
		}
	end,

	-- nat_enable mirrors the WAN zone's masquerade setting - a different
	-- toggle from get_netnat_config's hardware-NAT-acceleration `enable`
	-- below (software NAT on/off vs. HW-NAT-acceleration on/off).
	-- sip_enable (SIP ALG passthrough) isn't wired up here.
	get_advance_config = function(args)
		local cursor = uci.cursor()
		local nat_enable = cursor:get("firewall", "wan", "masq") ~= "0"
		return {
			mtu = tonumber((cursor:get("network", "wan", "mtu"))),
			nat_enable = nat_enable and 1 or 0,
			sip_enable = 0,
		}
	end,

	set_advance_config = function(args)
		local cursor = uci.cursor()
		if args.mtu then
			cursor:set("network", "wan", "mtu", tostring(math.floor(tonumber(args.mtu) or 1500)))
		end
		if args.nat_enable ~= nil then
			local wan_zone = nil
			cursor:foreach("firewall", "zone", function(s)
				if s.name == "wan" then wan_zone = s[".name"] end
			end)
			if wan_zone then
				cursor:set("firewall", wan_zone, "masq", (tonumber(args.nat_enable) == 1) and "1" or "0")
				cursor:commit("firewall")
			end
		end
		cursor:commit("network")
		os.execute("/etc/init.d/network reload >/dev/null 2>&1")
		return {}
	end,

	get_arp_list = function(args)
		local entries = {}
		local f = io.open("/proc/net/arp", "r")
		if f then
			f:read("*l") -- header
			for line in f:lines() do
				local ip, _, flags, mac, _, dev = line:match(
					"^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
				if ip and flags ~= "0x0" then
					table.insert(entries, { ip = ip, mac = mac, device = dev })
				end
			end
			f:close()
		end
		return { entries = as_array(entries) }
	end,

	-- IPv6 equivalent of get_arp_list. No fixed-format /proc/net table
	-- exists for IPv6 neighbors, so this shells out to a fixed
	-- `ip -6 neigh show` command and parses both possible line shapes
	-- (with/without a resolved lladdr).
	get_ipv6_neigh_list = function(args)
		local entries = {}
		local p = io.popen("ip -6 neigh show 2>/dev/null")
		if p then
			for line in p:lines() do
				local ip, dev, mac, state = line:match("^(%S+) dev (%S+) lladdr (%S+) (%S+)")
				if not ip then
					ip, dev, state = line:match("^(%S+) dev (%S+) (%S+)$")
				end
				if ip and state ~= "FAILED" then
					table.insert(entries, { ipaddr = ip, macaddr = mac, device = dev, state = state })
				end
			end
			p:close()
		end
		return { entries = entries }
	end,

	-- Used by the OpenVPN-server/WireGuard-server setup pages to ask "what
	-- address(es) can a remote client use to reach this router" - its own
	-- WAN IP, DDNS domain if any, and public-facing IP. pub_ip mirrors
	-- wan_ip since no external IP/STUN lookup is performed. domain is
	-- empty when DDNS isn't configured. No wg-server/ovpn-server backend
	-- exists yet, so nothing currently calls this in practice.
	get_available_address_list = function(args)
		local conn = ubus.connect()
		local wan_ip = nil
		if conn then
			local status = conn:call("network.interface.wan", "status", {})
			conn:close()
			local ipv4 = status and status["ipv4-address"] and status["ipv4-address"][1]
			wan_ip = ipv4 and ipv4.address
		end
		local wan_ips = wan_ip and { wan_ip } or {}
		return {
			wan_ip = as_array(wan_ips),
			pub_ip = as_array(wan_ips),
			domain = cjson.empty_array,
		}
	end,

	-- Hardware NAT / masquerade settings. MT7981's HW-NAT acceleration
	-- path is a platform-level concern separate from this RPC glue -
	-- toggling it here just flips the standard OpenWrt config knobs.
	-- conflict_features lists other features that can't run alongside
	-- this one (empty here since DPI/QoS/mptun don't exist on this
	-- port). actype mirrors hw_nat_enabled: 1 when hardware NAT
	-- acceleration is on, 0 otherwise. dpi_enabled/qos_enabled/
	-- wifi_reload are always false - none of those subsystems exist and
	-- toggling NAT here never requires a wifi reload.
	get_netnat_config = function(args)
		local cursor = uci.cursor()
		local defaults
		cursor:foreach("firewall", "defaults", function(s)
			if not defaults then defaults = s[".name"] end
		end)
		local enable = defaults
			and cursor:get("firewall", defaults, "flow_offloading") == "1"
			or false
		local hw_nat_enabled = defaults
			and cursor:get("firewall", defaults, "flow_offloading_hw") == "1"
			or false
		local actype = tonumber((cursor:get("gl-oui-rpc", "netnat", "actype")))
		if actype == nil then actype = hw_nat_enabled and 1 or (enable and 2 or 0) end
		return {
			enable = enable,
			hw_nat_enabled = hw_nat_enabled,
			actype = actype,
			dpi_enabled = false,
			qos_enabled = false,
			wifi_reload = false,
			conflict_features = cjson.empty_array,
			-- 0=Auto, 1=Hardware NAT, 2=Software NAT. The frontend
			-- builds the dropdown exclusively from this array.
			list = { 0, 1, 2 },
		}
	end,

	set_netnat_config = function(args)
		local cursor = uci.cursor()
		local defaults
		cursor:foreach("firewall", "defaults", function(s)
			if not defaults then defaults = s[".name"] end
		end)
		local enable = args.enable
		if defaults and enable ~= nil then
			cursor:set("firewall", defaults, "flow_offloading", enable and "1" or "0")
			local actype = tonumber(args.actype) or 0
			cursor:set(
				"firewall",
				defaults,
				"flow_offloading_hw",
				enable and actype ~= 2 and "1" or "0"
			)
			cursor:set("gl-oui-rpc", "netnat", "netnat")
			cursor:set("gl-oui-rpc", "netnat", "actype", tostring(actype))
			cursor:commit("gl-oui-rpc")
		end
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,
}
