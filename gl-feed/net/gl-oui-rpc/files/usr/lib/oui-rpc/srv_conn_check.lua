-- Connectivity diagnostics used by the GL VPN-server pages.
--
-- A router cannot prove inbound reachability from inside its own WAN without
-- a cooperating Internet probe.  Report the locally observable endpoint and
-- only mark it verified when it is a globally routable address and the
-- corresponding server interface is up.  This avoids the misleading
-- "reachable" result official cloud-assisted firmware can otherwise show on
-- CGNAT connections.

local cjson = require "cjson"
local uci = require "uci"

local function command_output(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	if not pipe then return "" end
	local output = pipe:read("*a") or ""
	pipe:close()
	return output:gsub("%s+$", "")
end

local function interface_status(name)
	local raw = command_output("ubus call network.interface." .. name .. " status")
	local ok, value = pcall(cjson.decode, raw)
	if not ok or type(value) ~= "table" then return {} end
	return value
end

local function first_active_wan()
	for _, name in ipairs({ "wan", "wwan_4", "repeater", "tethering" }) do
		local status = interface_status(name)
		if status.up == true then
			local ipv4 = status["ipv4-address"] and status["ipv4-address"][1]
			local ipv6 = status["ipv6-address"] and status["ipv6-address"][1]
			if ipv4 or ipv6 then return name, status, ipv4, ipv6 end
		end
	end
	return "", {}, nil, nil
end

local function public_ipv4(address)
	if type(address) ~= "string" then return false end
	local a, b = address:match("^(%d+)%.(%d+)")
	a, b = tonumber(a), tonumber(b)
	if not a or not b then return false end
	if a == 10 or a == 127 or a == 0 then return false end
	if a == 100 and b >= 64 and b <= 127 then return false end
	if a == 169 and b == 254 then return false end
	if a == 172 and b >= 16 and b <= 31 then return false end
	if a == 192 and b == 168 then return false end
	if a >= 224 then return false end
	return true
end

local function public_ipv6(address)
	if type(address) ~= "string" or address == "" then return false end
	if address:match("^::1$") then return false end        -- loopback
	if address:lower():match("^fe80:") then return false end -- link-local
	if address:lower():match("^f[cd]") then return false end -- ULA fc00::/7
	return true
end

local function gateway(status)
	for _, route in ipairs(status.route or {}) do
		if route.target == "0.0.0.0" and route.nexthop then return route.nexthop end
		if route.target == "::" and route.nexthop then return route.nexthop end
	end
	return ""
end

-- Per-server port/protocol/driver, read from UCI. The real GL firmware gets
-- these from the same two configs before handing the port to its external
-- prober.
local function vpn_config(interface)
	local cursor = uci.cursor()
	if interface == "wgserver" then
		return tonumber(cursor:get("gl_wgserver", "main", "port")) or 51820, "udp"
	end
	local port = tonumber(cursor:get("gl_ovpnserver", "vpn", "port")) or 1194
	local proto = cursor:get("gl_ovpnserver", "vpn", "proto") or "udp"
	if proto ~= "tcp" then proto = "udp" end
	return port, proto
end

return {
	server_connectivity_check = function(args)
		args = args or {}
		local interface = tostring(args.interface or "")
		if interface ~= "wgserver" and interface ~= "ovpnserver" then
			return { err_code = 1, err_msg = "unsupported VPN server" }
		end

		local wan_name, wan, ipv4, ipv6 = first_active_wan()
		local server = interface_status(interface)
		local port, protocol = vpn_config(interface)
		local v4 = ipv4 and ipv4.address or ""
		local v6 = ipv6 and ipv6.address or ""
		local up = server.up == true

		-- dev_info keys MUST stay exactly the set the frontend has labels
		-- for (internal_ip/external_ip/internal_port/external_port/protocol).
		-- It renders one row per key and looks the label up in a fixed map,
		-- so any extra key (this used to also carry `interface`) showed up as
		-- a row with an empty label and a bare value like "wwan_4".
		return {
			ipv4 = { ip = v4, verified = up and public_ipv4(v4) },
			ipv6 = { ip = v6, verified = up and public_ipv6(v6) },
			gateway = gateway(wan),
			dev_info = {
				internal_ip = v4,
				external_ip = v4,
				internal_port = port,
				external_port = port,
				protocol = protocol,
			},
		}
	end,
}

