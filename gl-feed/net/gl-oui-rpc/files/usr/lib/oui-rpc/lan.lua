-- "lan" RPC object: LAN/Guest/IoT IP+DHCP configuration.
--
-- Thin wrapper over stock /etc/config/network + /etc/config/dhcp. Also
-- covers the guest/iot networks' IP+DHCP settings (their SSID/password
-- stays on the "wifi" object; this is only the IP/DHCP side). Default
-- LAN IP 192.168.8.1 is set in board.d, this object only edits it.
--
-- get_config_list returns `interfaces`, each entry
-- {interface, ip, protocol, netmask, start, end} - `ip` is a plain
-- address string and start/end are full DHCP-range IP addresses (this
-- file converts to/from UCI's own offset-based start/limit pair).
-- set_config takes interface/ip/start/end/netmask. Static binds are
-- keyed by MAC end-to-end: add_static_bind/set_static_bind take
-- {name,mac,ip}; get_static_bind_list returns
-- {static_bind_list:[{name,mac,ip}]}; remove_static_bind takes
-- {mode,mac}.

local uci = require "uci"
local cjson = require "cjson"

-- See clients.lua's as_array() for the full explanation: lua-cjson can't
-- tell an empty array apart from an empty object, always emits "{}" for
-- a bare `{}` - breaks frontend .map()/.forEach() calls on fields that
-- are semantically arrays but happen to be empty right now.
local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local NETWORKS = { "lan", "guest", "iot" }

local function valid_network(n)
	for _, x in ipairs(NETWORKS) do
		if x == n then return true end
	end
	return false
end

-- network.<net>.ipaddr can be a plain string OR a UCI list (CIDR form,
-- e.g. `add_list network.lan.ipaddr='192.168.8.1/24'` - see 90-gl-oui-
-- lan-ip's header note) - normalize to a single bare "a.b.c.d" string
-- either way, and separately recover a prefix-length int if the CIDR
-- form was used (nil otherwise, caller falls back to network.<net>.netmask).
local function read_ipaddr(cursor, network)
	local raw = cursor:get("network", network, "ipaddr")
	if type(raw) == "table" then
		raw = raw[1]
	end
	if not raw then return nil, nil end
	local ip, prefix = raw:match("^([^/]+)/?(%d*)$")
	return ip or raw, tonumber(prefix)
end

local function prefix_to_netmask(prefix)
	if not prefix then return nil end
	local bits = { 0, 0, 0, 0 }
	for i = 1, 4 do
		local n = math.min(8, math.max(0, prefix - (i - 1) * 8))
		bits[i] = 256 - 2 ^ (8 - n)
		if n == 0 then bits[i] = 0 end
	end
	return string.format("%d.%d.%d.%d", bits[1], bits[2], bits[3], bits[4])
end

local function ip_prefix3(ip)
	return ip and ip:match("^(%d+%.%d+%.%d+)%.")
end

local function read_network_config(cursor, network)
	local ip = read_ipaddr(cursor, network)
	local netmask = cursor:get("network", network, "netmask") or prefix_to_netmask(select(2, read_ipaddr(cursor, network))) or "255.255.255.0"
	local start_off = tonumber((cursor:get("dhcp", network, "start"))) or 100
	local limit = tonumber((cursor:get("dhcp", network, "limit"))) or 150
	local prefix3 = ip_prefix3(ip)
	local start_ip, end_ip
	if prefix3 then
		start_ip = prefix3 .. "." .. start_off
		end_ip = prefix3 .. "." .. (start_off + limit - 1)
	end
	return {
		interface = network,
		ip = ip,
		protocol = cursor:get("network", network, "proto") or "static",
		netmask = netmask,
		start = start_ip,
		["end"] = end_ip,
	}
end

return {
	get_config_list = function(args)
		local cursor = uci.cursor()
		local list = {}
		for _, n in ipairs(NETWORKS) do
			if cursor:get("network", n) then
				table.insert(list, read_network_config(cursor, n))
			end
		end
		return { interfaces = list }
	end,

	set_config = function(args)
		local network = args.interface or "lan"
		if not valid_network(network) then
			return { code = 1, message = "unknown interface" }
		end
		local cursor = uci.cursor()
		if not cursor:get("network", network) and network ~= "lan" then
			return { code = 1, message = network .. " network is not configured (enable it via wifi guest/iot config first)" }
		end

		if args.ip then
			cursor:delete("network", network, "ipaddr")
			cursor:set("network", network, "ipaddr", args.ip)
		end
		if args.netmask then cursor:set("network", network, "netmask", args.netmask) end
		cursor:commit("network")

		-- start/end are full IP addresses on the wire; UCI's dhcp config
		-- wants an offset-based start + limit pair within the subnet.
		if args.start or args["end"] then
			local prefix3 = ip_prefix3(args.ip) or ip_prefix3(select(1, read_ipaddr(cursor, network)))
			local start_off = args.start and prefix3 and tonumber(args.start:match("%.(%d+)$"))
			local end_off = args["end"] and prefix3 and tonumber(args["end"]:match("%.(%d+)$"))
			if start_off then
				cursor:set("dhcp", network, "start", tostring(start_off))
			end
			if start_off and end_off and end_off >= start_off then
				cursor:set("dhcp", network, "limit", tostring(end_off - start_off + 1))
			end
		end
		cursor:commit("dhcp")

		os.execute("/etc/init.d/network reload >/dev/null 2>&1")
		os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
		return {}
	end,

	get_wan_info = function(args)
		local ubus = require "ubus"
		local conn = ubus.connect()
		if not conn then return {} end
		local status = conn:call("network.interface.wan", "status", {})
		conn:close()
		local ipv4 = status and status["ipv4-address"] and status["ipv4-address"][1]
		return {
			connected = status and status.up == true or false,
			ipaddr = ipv4 and ipv4.address,
		}
	end,

	-- Static DHCP bindings (matches dnsmasq's dhcp-host directives via
	-- UCI's dhcp.@host[] list) - keyed by MAC address end-to-end per the
	-- official API docs, not an internal UCI section id.
	get_static_bind_list = function(args)
		local cursor = uci.cursor()
		local binds = {}
		cursor:foreach("dhcp", "host", function(s)
			if s.mac and s.ip then
				table.insert(binds, { name = s.name, mac = s.mac, ip = s.ip })
			end
		end)
		return { static_bind_list = as_array(binds) }
	end,

	add_static_bind = function(args)
		if type(args.mac) ~= "string" or type(args.ip) ~= "string" then
			return { code = 1, message = "missing mac/ip" }
		end
		if not args.mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
			return { code = 1, message = "invalid mac" }
		end
		local cursor = uci.cursor()
		local id = cursor:add("dhcp", "host")
		cursor:set("dhcp", id, "mac", args.mac)
		cursor:set("dhcp", id, "ip", args.ip)
		if args.name then cursor:set("dhcp", id, "name", args.name) end
		cursor:commit("dhcp")
		os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
		return {}
	end,

	-- Keyed by mac (matches the entry to update), not an internal id.
	set_static_bind = function(args)
		if type(args.mac) ~= "string" then
			return { code = 1, message = "missing mac" }
		end
		local cursor = uci.cursor()
		local target = nil
		cursor:foreach("dhcp", "host", function(s)
			if s.mac == args.mac then target = s['.name'] end
		end)
		if not target then
			return { code = 1, message = "unknown mac" }
		end
		if args.ip then cursor:set("dhcp", target, "ip", args.ip) end
		if args.name then cursor:set("dhcp", target, "name", args.name) end
		cursor:commit("dhcp")
		os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
		return {}
	end,

	-- `mode`'s exact meaning isn't documented beyond one example (0) -
	-- accepted and ignored rather than guessed at; removal is always by
	-- mac, which is the only unambiguous identifier the docs confirm.
	remove_static_bind = function(args)
		if type(args.mac) ~= "string" then
			return { code = 1, message = "missing mac" }
		end
		local cursor = uci.cursor()
		local target = nil
		cursor:foreach("dhcp", "host", function(s)
			if s.mac == args.mac then target = s['.name'] end
		end)
		if target then
			cursor:delete("dhcp", target)
			cursor:commit("dhcp")
			os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
		end
		return {}
	end,
}
