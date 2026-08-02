-- "vpn-client" RPC object: the tunnel/group orchestration layer the real
-- GL frontend uses to wrap one or more underlying configs (from wg-client
-- / ovpn-client) into a named, connectable "Tunnel". Only WireGuard
-- tunnels are implemented - see wg-client.lua's header for why the
-- commercial-provider catalog (NordVPN/Mullvad/...) and OpenVPN's
-- upload-and-parse config flow are out of scope. Only one tunnel can be
-- brought up at a time on this hardware (single WAN-replacing client
-- tunnel), matching the real travel-router use case of "route this
-- router's traffic through my VPN provider".
--
-- Shapes (from/via/configs/group_id/id_list/tunnel_id) are taken directly
-- from the real frontend's minified RPC call sites, not guessed.

local cjson = require "cjson"
local uci = require "uci"

local CONFIG = "gl_vpnclient"
local WGCLIENT_CONFIG = "gl_wgclient"

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
end

local function command_output(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	if not pipe then return "" end
	local data = pipe:read("*a") or ""
	pipe:close()
	return (data:gsub("%s+$", ""))
end

local function new_id()
	local seed = tostring(os.time()) .. tostring(math.random(100000, 999999))
	return command_output("printf %s '" .. seed .. "' | sha256sum | cut -c1-16")
end

local function new_section(cursor, config, section_type, name, values)
	cursor:set(config, name, section_type)
	for option, value in pairs(values) do
		cursor:set(config, name, option, value)
	end
	return name
end

local function new_anon_section(cursor, config, section_type, values)
	local name = cursor:add(config, section_type)
	for option, value in pairs(values) do
		cursor:set(config, name, option, value)
	end
	return name
end

local function tunnel_sections(cursor)
	local tunnels = {}
	cursor:foreach(CONFIG, "tunnel", function(section)
		tunnels[#tunnels + 1] = section
	end)
	table.sort(tunnels, function(a, b)
		return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
	end)
	return tunnels
end

local function tunnel_by_id(cursor, id)
	for _, tunnel in ipairs(tunnel_sections(cursor)) do
		if tostring(tunnel.tunnel_id or "") == tostring(id or "") then
			return tunnel
		end
	end
	return nil
end

local function wg_peer(cursor, group_id, peer_id)
	local found
	cursor:foreach(WGCLIENT_CONFIG, "peer", function(section)
		if not found and tostring(section.group_id or "") == tostring(group_id or "")
			and tostring(section.peer_id or "") == tostring(peer_id or "") then
			found = section
		end
	end)
	return found
end

local function iface_name(tunnel_id)
	return "vpnc" .. tostring(tunnel_id):sub(1, 8)
end

local function teardown(cursor, tunnel_id)
	local iface = iface_name(tunnel_id)
	command_ok("ifdown " .. iface)
	cursor:delete("network", iface)
	local peer_sections = {}
	cursor:foreach("network", "wireguard_" .. iface, function(s)
		peer_sections[#peer_sections + 1] = s[".name"]
	end)
	for _, name in ipairs(peer_sections) do cursor:delete("network", name) end
	cursor:delete("firewall", "gl_vpnc_" .. iface)
	cursor:delete("firewall", "gl_vpnc_" .. iface .. "_fwd")
	cursor:commit("network")
	cursor:commit("firewall")
end

local function teardown_all_except(cursor, keep_tunnel_id)
	for _, tunnel in ipairs(tunnel_sections(cursor)) do
		if tunnel.tunnel_id ~= keep_tunnel_id then
			teardown(cursor, tunnel.tunnel_id)
		end
	end
end

-- Brings the given tunnel's WireGuard interface up as the client's
-- replacement default route (allowed_ips containing 0.0.0.0/0 makes
-- netifd's own wireguard proto install the default route, the same way
-- `wg-quick` does - no manual route/metric juggling needed here).
local function apply_runtime(cursor, tunnel)
	if tunnel.tunnel_type ~= "wireguard" then
		return false, "only wireguard tunnels can be started on this build"
	end
	local peer = wg_peer(cursor, tunnel.group_id, tunnel.ref_id)
	if not peer then return false, "referenced config no longer exists" end

	teardown_all_except(cursor, tunnel.tunnel_id)

	local iface = iface_name(tunnel.tunnel_id)
	local addresses = {}
	if peer.address_v4 and peer.address_v4 ~= "" then addresses[#addresses + 1] = peer.address_v4 end
	if peer.address_v6 and peer.address_v6 ~= "" then addresses[#addresses + 1] = peer.address_v6 end

	local host, port = tostring(peer.end_point or ""):match("^([^:]+):(%d+)$")
	if not host then return false, "invalid endpoint" end

	new_section(cursor, "network", "interface", iface, {
		proto = "wireguard",
		private_key = peer.private_key,
		addresses = as_array(addresses),
	})
	local values = {
		public_key = peer.public_key,
		endpoint_host = host,
		endpoint_port = port,
		allowed_ips = as_array(cjson.decode(peer.allowed_ips_json or "[]")),
		route_allowed_ips = "1",
		persistent_keepalive = tostring(tonumber(peer.persistent_keepalive) or 25),
	}
	if peer.presharedkey_enable == "1" and peer.preshared_key and peer.preshared_key ~= "" then
		values.preshared_key = peer.preshared_key
	end
	new_anon_section(cursor, "network", "wireguard_" .. iface, values)
	cursor:commit("network")

	new_section(cursor, "firewall", "zone", "gl_vpnc_" .. iface, {
		name = iface,
		network = iface,
		input = "REJECT",
		output = "ACCEPT",
		forward = "REJECT",
		masq = "1",
	})
	new_section(cursor, "firewall", "forwarding", "gl_vpnc_" .. iface .. "_fwd", {
		src = "lan",
		dest = iface,
	})
	cursor:commit("firewall")

	command_ok("ubus call network reload")
	command_ok("/etc/init.d/firewall reload")
	command_ok("ifup " .. iface)
	return true
end

local function tunnel_result(tunnel)
	return {
		tunnel_id = tunnel.tunnel_id or "",
		name = tunnel.name or "",
		enabled = tunnel.enabled == "1",
		from = { type = "default" },
		to = { type = "default" },
		via = {
			type = tunnel.tunnel_type or "wireguard",
			configs = { { group_id = tunnel.group_id or "", id_list = { tunnel.ref_id or "" } } },
		},
	}
end

return {
	get_tunnel = function()
		local cursor = uci.cursor()
		local tunnels = {}
		for _, tunnel in ipairs(tunnel_sections(cursor)) do
			tunnels[#tunnels + 1] = tunnel_result(tunnel)
		end
		local default_enabled = cursor:get(CONFIG, "settings", "default_enabled") ~= "0"
		return {
			tunnels = as_array(tunnels),
			default_tunnels = { { enabled = default_enabled } },
		}
	end,

	add_tunnel = function(args)
		args = args or {}
		local via = args.via or {}
		if via.type ~= "wireguard" then
			return { err_code = 1, err_msg = "only wireguard tunnels are supported on this build" }
		end
		local first_config = (via.configs or {})[1] or {}
		local ref_id = (first_config.id_list or {})[1]
		if type(first_config.group_id) ~= "string" or type(ref_id) ~= "string" then
			return { err_code = 1, err_msg = "missing config reference" }
		end
		local cursor = uci.cursor()
		if not wg_peer(cursor, first_config.group_id, ref_id) then
			return { err_code = 1, err_msg = "referenced config not found" }
		end

		local tunnel_id = new_id()
		local order = #tunnel_sections(cursor)
		new_section(cursor, CONFIG, "tunnel", "t_" .. tunnel_id, {
			tunnel_id = tunnel_id,
			name = type(args.name) == "string" and args.name or "Tunnel",
			tunnel_type = "wireguard",
			group_id = first_config.group_id,
			ref_id = ref_id,
			enabled = args.enabled and "1" or "0",
			order = tostring(order),
		})
		cursor:commit(CONFIG)

		if args.enabled then
			local tunnel = tunnel_by_id(cursor, tunnel_id)
			local ok, err = apply_runtime(cursor, tunnel)
			if not ok then return { err_code = 1, err_msg = err } end
		end
		return { tunnel_id = tunnel_id }
	end,

	set_tunnel = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local tunnel = tunnel_by_id(cursor, args.tunnel_id)
		if not tunnel then return { err_code = 1, err_msg = "tunnel not found" } end

		local via = args.via
		if via then
			if via.type ~= "wireguard" then
				return { err_code = 1, err_msg = "only wireguard tunnels are supported on this build" }
			end
			local first_config = (via.configs or {})[1] or {}
			local ref_id = (first_config.id_list or {})[1]
			if type(first_config.group_id) == "string" and type(ref_id) == "string" then
				cursor:set(CONFIG, tunnel[".name"], "group_id", first_config.group_id)
				cursor:set(CONFIG, tunnel[".name"], "ref_id", ref_id)
			end
		end
		if args.enabled ~= nil then
			cursor:set(CONFIG, tunnel[".name"], "enabled", args.enabled and "1" or "0")
		end
		cursor:commit(CONFIG)

		tunnel = tunnel_by_id(cursor, args.tunnel_id)
		if tunnel.enabled == "1" then
			local ok, err = apply_runtime(cursor, tunnel)
			if not ok then return { err_code = 1, err_msg = err } end
		else
			teardown(cursor, tunnel.tunnel_id)
		end
		return {}
	end,

	stop = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local tunnel = tunnel_by_id(cursor, args.tunnel_id)
		if not tunnel then return { err_code = 1, err_msg = "tunnel not found" } end
		cursor:set(CONFIG, tunnel[".name"], "enabled", "0")
		cursor:commit(CONFIG)
		teardown(cursor, tunnel.tunnel_id)
		return {}
	end,

	remove_tunnel = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local tunnel = tunnel_by_id(cursor, args.tunnel_id)
		if not tunnel then return { err_code = 1, err_msg = "tunnel not found" } end
		teardown(cursor, tunnel.tunnel_id)
		cursor:delete(CONFIG, tunnel[".name"])
		cursor:commit(CONFIG)
		return {}
	end,

	order_tunnel = function(args)
		args = args or {}
		local cursor = uci.cursor()
		for index, tunnel_id in ipairs(args.id_list or {}) do
			local tunnel = tunnel_by_id(cursor, tunnel_id)
			if tunnel then
				cursor:set(CONFIG, tunnel[".name"], "order", tostring(index))
			end
		end
		cursor:commit(CONFIG)
		return {}
	end,

	-- Real semantics unconfirmed beyond "a global fallback-routing toggle
	-- independent of any single tunnel" (get_tunnel's own default_tunnels
	-- wrapper is read the same way regardless of which/how many tunnels
	-- exist) - persisted honestly, no traffic-killswitch behavior wired
	-- since that wasn't evidenced.
	set_default_tunnel = function(args)
		args = args or {}
		local cursor = uci.cursor()
		cursor:set(CONFIG, "settings", "settings")
		cursor:set(CONFIG, "settings", "default_enabled", args.enabled and "1" or "0")
		cursor:commit(CONFIG)
		return {}
	end,

	set_options = function(args)
		return {}
	end,

	set_tap_s2s = function()
		return { err_code = 1, err_msg = "TAP site-to-site mode is not supported on this build" }
	end,

	get_all_config_list = function()
		local cursor = uci.cursor()
		local groups = {}
		cursor:foreach(WGCLIENT_CONFIG, "group", function(group)
			local configs = {}
			cursor:foreach(WGCLIENT_CONFIG, "peer", function(peer)
				if peer.group_id == group.group_id then
					configs[#configs + 1] = {
						peer_id = peer.peer_id or "",
						name = peer.name or "",
					}
				end
			end)
			groups[#groups + 1] = {
				group_id = group.group_id or "",
				group_name = group.group_name or "",
				group_type = 3,
				type = "wireguard",
				configs = as_array(configs),
			}
		end)
		return { groups = as_array(groups) }
	end,

	get_connection_methods = function()
		return {
			connection_methods = {
				{ type = "wireguard", group_type = 3, auth_type = 1, procedure = 0 },
			},
		}
	end,

	get_vpn_using_status = function()
		return cjson.empty_array
	end,

	check_domain_online = function()
		return { online = false }
	end,

	set_single_mac = function()
		return {
			err_code = 1,
			err_msg = "per-client VPN routing is not configured",
		}
	end,
}
