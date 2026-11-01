-- "upnp" RPC object for the 4.11 UPnP page, backed by OpenWrt's
-- miniupnpd-nftables package. The page only exposes the IGD/NAT-PMP
-- switches; the upstream daemon owns the actual rules.

local uci = require "uci"

local CONFIG = "upnpd"
local SECTION = "config"
local LEASE_FILE = "/var/run/miniupnpd.leases"

local function section(cursor)
	local found
	cursor:foreach(CONFIG, "upnpd", function(s)
		if not found then found = s[".name"] end
	end)
	return found or SECTION
end

local function bool(cursor, option, default)
	local value = cursor:get(CONFIG, section(cursor), option)
	if value == nil then return default end
	return value == "1"
end

local function number(value, default)
	value = tonumber(value)
	if not value then return default end
	return value
end

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ipv4(value)
	local a, b, c, d = tostring(value or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	for _, n in ipairs({ a, b, c, d }) do
		n = tonumber(n)
		if n > 255 then return nil end
	end
	return value
end

local function mapping_list()
	local list = {}
	local f = io.open(LEASE_FILE, "r")
	if not f then return list end
	for line in f:lines() do
		-- miniupnpd lease lines are protocol:internal-client:internal-port:
		-- external-client:external-port:timestamp:description
		local protocol, client, iport, _external_client, eport, timestamp, description =
			line:match("^([^:]+):([^:]+):([^:]+):([^:]*):([^:]+):([^:]*):?(.*)$")
		if protocol and client then
			list[#list + 1] = {
				protocol = protocol,
				client = client,
				internal_port = tonumber(iport) or 0,
				external_port = tonumber(eport) or 0,
				description = description or "",
				timestamp = tonumber(timestamp) or 0,
			}
		end
	end
	f:close()
	return list
end

return {
	get_config = function()
		local cursor = uci.cursor()
		return {
			enabled = bool(cursor, "enabled", false),
			enable_upnp = bool(cursor, "enable_upnp", true),
			enable_natpmp = bool(cursor, "enable_natpmp", true),
			secure_mode = bool(cursor, "secure_mode", true),
			internal_iface = cursor:get(CONFIG, section(cursor), "internal_iface") or "br-lan",
			external_iface = cursor:get(CONFIG, section(cursor), "external_iface") or "wan",
			port = number(cursor:get(CONFIG, section(cursor), "port"), 5000),
			upnp_lease_file = cursor:get(CONFIG, section(cursor), "upnp_lease_file") or LEASE_FILE,
			policy_mode = cursor:get(CONFIG, section(cursor), "policy_mode") or "0",
		}
	end,

	set_config = function(args)
		args = args or {}
		for _, key in ipairs({ "enabled", "enable_upnp", "enable_natpmp", "secure_mode" }) do
			if args[key] ~= nil and type(args[key]) ~= "boolean" then
				return { code = 1, message = "invalid " .. key }
			end
		end
		if args.internal_iface ~= nil and type(args.internal_iface) ~= "string" then
			return { code = 1, message = "invalid internal_iface" }
		end
		if args.external_iface ~= nil and type(args.external_iface) ~= "string" then
			return { code = 1, message = "invalid external_iface" }
		end
		local port = args.port
		if port ~= nil then
			port = tonumber(port)
			if not port or port < 1 or port > 65535 then
				return { code = 1, message = "invalid port" }
			end
		end

		local cursor = uci.cursor()
		local name = section(cursor)
		if not cursor:get(CONFIG, name) then
			cursor:set(CONFIG, name, "upnpd")
		end
		if args.enabled ~= nil then
			cursor:set(CONFIG, name, "enabled", args.enabled and "1" or "0")
		end
		if args.enable_upnp ~= nil then
			cursor:set(CONFIG, name, "enable_upnp", args.enable_upnp and "1" or "0")
		end
		if args.enable_natpmp ~= nil then
			cursor:set(CONFIG, name, "enable_natpmp", args.enable_natpmp and "1" or "0")
		end
		if args.secure_mode ~= nil then
			cursor:set(CONFIG, name, "secure_mode", args.secure_mode and "1" or "0")
		end
		if args.internal_iface ~= nil then
			cursor:set(CONFIG, name, "internal_iface", trim(args.internal_iface))
		end
		if args.external_iface ~= nil then
			cursor:set(CONFIG, name, "external_iface", trim(args.external_iface))
		end
		if port then
			cursor:set(CONFIG, name, "port", tostring(port))
		end
		cursor:commit(CONFIG)
		os.execute("/etc/init.d/miniupnpd restart >/dev/null 2>&1")
		return {}
	end,

	get_mapping_list = function()
		return { mappings = mapping_list() }
	end,

	delete_mapping = function(args)
		args = args or {}
		local protocol = trim(args.protocol):upper()
		local port = tonumber(args.external_port)
		if protocol ~= "TCP" and protocol ~= "UDP" then
			return { code = 1, message = "invalid protocol" }
		end
		if not port or port < 1 or port > 65535 then
			return { code = 1, message = "invalid external_port" }
		end
		-- upnpc talks to the local IGD; ignore its exit status because the
		-- page only needs the mapping to disappear from the refreshed list.
		os.execute(string.format(
			"upnpc -d %d %s >/dev/null 2>&1", port, protocol))
		return {}
	end,
}
