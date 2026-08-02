-- "edgerouter" RPC object: "avoid double-NAT" WAN static-IP conversion.
--
-- When this router sits behind another router/modem that's also doing
-- NAT, double-NAT breaks port forwarding and some peer-to-peer traffic.
-- The fix GL's UI offers here is: detect the DHCP lease the WAN port
-- already has, then let the user "freeze" those exact values (or edit
-- them) into a static WAN config, taking this router out of the upstream
-- router's DHCP pool so it can't collide with the upstream gateway's own
-- address range. It writes into the same network.wan UCI section
-- cable.lua's own set_config uses - this is a guided way to set the same
-- WAN static config, not a separate WAN.

local ubus = require "ubus"
local uci = require "uci"

local CONFIG = "gl_edgerouter"

-- CIDR-bits -> dotted netmask via a lookup table: LuaJIT's Lua 5.1 dialect
-- has no &/<</>> operators (same approach system.lua's get_status uses).
local CIDR_MASKS = {
	[8] = "255.0.0.0", [16] = "255.255.0.0", [24] = "255.255.255.0",
	[25] = "255.255.255.128", [26] = "255.255.255.192", [27] = "255.255.255.224",
	[28] = "255.255.255.240", [29] = "255.255.255.248", [30] = "255.255.255.252",
}

local function wan_status()
	local conn = ubus.connect()
	if not conn then return nil end
	local status = conn:call("network.interface.wan", "status", {})
	conn:close()
	return status
end

local function is_ipv4(value)
	if type(value) ~= "string" then return false end
	local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return false end
	for _, octet in ipairs({ a, b, c, d }) do
		if tonumber(octet) > 255 then return false end
	end
	return true
end

return {
	-- `detected` mirrors the frontend's own default (-1): 1 = a DHCP lease
	-- was found on WAN and its settings are in `suggest`, 0 = WAN is up but
	-- not DHCP (nothing to suggest), -1 = no usable WAN status yet.
	get_status = function(args)
		local status = wan_status()
		local ipv4 = status and status["ipv4-address"] and status["ipv4-address"][1]
		if not status or status.proto ~= "dhcp" or not status.up or not ipv4 then
			return { detected = (status and status.up) and 0 or -1 }
		end
		local dns = status["dns-server"] or {}
		return {
			detected = 1,
			suggest = {
				gateway = status.route and status.route[1] and status.route[1].nexthop or "",
				ip = ipv4.address or "",
				netmask = (ipv4.mask and CIDR_MASKS[ipv4.mask]) or "255.255.255.0",
				dns1 = dns[1] or "",
				dns2 = dns[2] or "",
			},
		}
	end,

	get_config = function(args)
		local cursor = uci.cursor()
		local enabled = cursor:get(CONFIG, "main", "enable") == "1"
		return {
			enable = enabled,
			gateway = cursor:get(CONFIG, "main", "gateway") or "",
			ip = cursor:get(CONFIG, "main", "ip") or "",
			netmask = cursor:get(CONFIG, "main", "netmask") or "",
			dns1 = cursor:get(CONFIG, "main", "dns1") or "",
			dns2 = cursor:get(CONFIG, "main", "dns2") or "",
			ignore = cursor:get(CONFIG, "main", "ignore") == "1",
		}
	end,

	set_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		cursor:set(CONFIG, "main", "settings")
		if args.ignore ~= nil then
			cursor:set(CONFIG, "main", "ignore", args.ignore and "1" or "0")
		end

		if args.enable then
			if not is_ipv4(args.ip) or not is_ipv4(args.netmask) or not is_ipv4(args.gateway) then
				return { err_code = 1, err_msg = "invalid IP/netmask/gateway" }
			end
			if args.dns1 and args.dns1 ~= "" and not is_ipv4(args.dns1) then
				return { err_code = 1, err_msg = "invalid dns1" }
			end
			if args.dns2 and args.dns2 ~= "" and not is_ipv4(args.dns2) then
				return { err_code = 1, err_msg = "invalid dns2" }
			end

			cursor:set(CONFIG, "main", "enable", "1")
			cursor:set(CONFIG, "main", "ip", args.ip)
			cursor:set(CONFIG, "main", "netmask", args.netmask)
			cursor:set(CONFIG, "main", "gateway", args.gateway)
			cursor:set(CONFIG, "main", "dns1", args.dns1 or "")
			cursor:set(CONFIG, "main", "dns2", args.dns2 or "")
			cursor:commit(CONFIG)

			local dns = {}
			if args.dns1 and args.dns1 ~= "" then dns[#dns + 1] = args.dns1 end
			if args.dns2 and args.dns2 ~= "" then dns[#dns + 1] = args.dns2 end
			cursor:set("network", "wan", "proto", "static")
			cursor:set("network", "wan", "ipaddr", args.ip)
			cursor:set("network", "wan", "netmask", args.netmask)
			cursor:set("network", "wan", "gateway", args.gateway)
			if #dns > 0 then
				cursor:set("network", "wan", "dns", dns)
			else
				cursor:delete("network", "wan", "dns")
			end
			cursor:commit("network")
			os.execute("ifup wan >/dev/null 2>&1")
		elseif args.enable == false then
			cursor:set(CONFIG, "main", "enable", "0")
			cursor:commit(CONFIG)

			cursor:set("network", "wan", "proto", "dhcp")
			cursor:delete("network", "wan", "ipaddr")
			cursor:delete("network", "wan", "netmask")
			cursor:delete("network", "wan", "gateway")
			cursor:delete("network", "wan", "dns")
			cursor:commit("network")
			os.execute("ifup wan >/dev/null 2>&1")
		else
			cursor:commit(CONFIG)
		end
		return {}
	end,
}
