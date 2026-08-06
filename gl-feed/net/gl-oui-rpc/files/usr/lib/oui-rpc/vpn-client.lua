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

local function interface_status(iface)
	local ok, ubus = pcall(require, "ubus")
	if not ok then return {} end
	local conn = ubus.connect()
	if not conn then return {} end
	local status = conn:call("network.interface." .. iface, "status", {}) or {}
	conn:close()
	return status
end

local function wireguard_handshake(iface)
	local latest = 0
	for line in command_output("wg show " .. iface .. " latest-handshakes"):gmatch("[^\n]+") do
		local timestamp = tonumber(line:match("^%S+%s+(%d+)$")) or 0
		if timestamp > latest then latest = timestamp end
	end
	return latest
end

local function wireguard_transfer(iface)
	local rx_bytes, tx_bytes = 0, 0
	for line in command_output("wg show " .. iface .. " transfer"):gmatch("[^\n]+") do
		local rx, tx = line:match("^%S+%s+(%d+)%s+(%d+)$")
		rx_bytes = rx_bytes + (tonumber(rx) or 0)
		tx_bytes = tx_bytes + (tonumber(tx) or 0)
	end
	return rx_bytes, tx_bytes
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
	cursor:delete("firewall", "gl_vpnc_" .. iface .. "_lan_fwd")
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

	teardown(cursor, tunnel.tunnel_id)
	teardown_all_except(cursor, tunnel.tunnel_id)

	local iface = iface_name(tunnel.tunnel_id)
	local addresses = {}
	if peer.address_v4 and peer.address_v4 ~= "" then addresses[#addresses + 1] = peer.address_v4 end
	if peer.address_v6 and peer.address_v6 ~= "" then addresses[#addresses + 1] = peer.address_v6 end

	local host, port = tostring(peer.end_point or ""):match("^%[(.-)%]:(%d+)$")
	if not host then host, port = tostring(peer.end_point or ""):match("^([^:]+):(%d+)$") end
	if not host then return false, "invalid endpoint" end
	port = tonumber(port)
	if not port or port < 1 or port > 65535 then return false, "invalid endpoint port" end

	local interface_values = {
		proto = "wireguard",
		private_key = peer.private_key,
		addresses = as_array(addresses),
	}
	local mtu = tonumber(tunnel.mtu) or tonumber(peer.mtu) or 0
	if mtu > 0 then interface_values.mtu = tostring(mtu) end
	local listen_port = tonumber(peer.listen_port) or 0
	if listen_port > 0 and listen_port <= 65535 then
		interface_values.listen_port = tostring(listen_port)
	end
	if peer.dns and peer.dns ~= "" then
		local dns = {}
		for server in tostring(peer.dns):gmatch("[^,%s]+") do dns[#dns + 1] = server end
		if #dns > 0 then interface_values.dns = as_array(dns) end
	end
	new_section(cursor, "network", "interface", iface, interface_values)
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

	local local_access = tunnel.local_access == "1"
	local zone_name = "gl_vpnc_" .. iface
	new_section(cursor, "firewall", "zone", zone_name, {
		name = iface,
		network = iface,
		input = local_access and "ACCEPT" or "REJECT",
		output = "ACCEPT",
		forward = "REJECT",
		masq = tunnel.masq == "0" and "0" or "1",
	})
	new_section(cursor, "firewall", "forwarding", "gl_vpnc_" .. iface .. "_fwd", {
		src = "lan",
		dest = iface,
	})
	if local_access then
		new_section(cursor, "firewall", "forwarding", "gl_vpnc_" .. iface .. "_lan_fwd", {
			src = iface,
			dest = "lan",
		})
	end
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
		killswitch = tunnel.killswitch == "1",
		options = {
			mtu = tonumber(tunnel.mtu) or 0,
			local_access = tunnel.local_access == "1",
			masq = tunnel.masq ~= "0",
			service_policy = tunnel.service_policy == "1",
			killswitch = tunnel.killswitch == "1",
		},
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
			masq = "1",
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
			if type(first_config.group_id) ~= "string" or type(ref_id) ~= "string"
				or not wg_peer(cursor, first_config.group_id, ref_id) then
				return { err_code = 1, err_msg = "referenced config not found" }
			end
			cursor:set(CONFIG, tunnel[".name"], "group_id", first_config.group_id)
			cursor:set(CONFIG, tunnel[".name"], "ref_id", ref_id)
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
		args = args or {}
		local cursor = uci.cursor()
		local tunnel = tunnel_by_id(cursor, args.tunnel_id)
		if not tunnel then return { err_code = 1, err_msg = "tunnel not found" } end

		local mtu = tonumber(args.mtu) or 0
		if mtu ~= 0 and (mtu < 68 or mtu > 65535) then
			return { err_code = 1, err_msg = "invalid MTU" }
		end
		if args.killswitch == true or args.service_policy == true then
			return { err_code = 1, err_msg = "kill switch options are not supported on this build" }
		end

		cursor:set(CONFIG, tunnel[".name"], "mtu", tostring(mtu))
		cursor:set(CONFIG, tunnel[".name"], "local_access", args.local_access and "1" or "0")
		cursor:set(CONFIG, tunnel[".name"], "masq", args.masq == false and "0" or "1")
		cursor:set(CONFIG, tunnel[".name"], "service_policy", "0")
		cursor:set(CONFIG, tunnel[".name"], "killswitch", "0")
		cursor:commit(CONFIG)

		tunnel = tunnel_by_id(cursor, args.tunnel_id)
		if tunnel.enabled == "1" then
			local ok, err = apply_runtime(cursor, tunnel)
			if not ok then return { err_code = 1, err_msg = err } end
		end
		return {}
	end,

	set_tap_s2s = function()
		return { err_code = 1, err_msg = "TAP site-to-site mode is not supported on this build" }
	end,

	get_all_config_list = function()
		local cursor = uci.cursor()
		local wireguard = {}
		cursor:foreach(WGCLIENT_CONFIG, "group", function(group)
			local peers = {}
			cursor:foreach(WGCLIENT_CONFIG, "peer", function(peer)
				if peer.group_id == group.group_id then
					local allowed_ips = {}
					local decoded = cjson.decode(peer.allowed_ips_json or "[]")
					for _, ip in ipairs(decoded or {}) do
						allowed_ips[#allowed_ips + 1] = { ip = ip }
					end
					peers[#peers + 1] = {
						peer_id = peer.peer_id or "",
						name = peer.name or "",
						group_id = peer.group_id or "",
						address_v4 = peer.address_v4 or "",
						address_v6 = peer.address_v6 or "",
						private_key = peer.private_key or "",
						public_key = peer.public_key or "",
						end_point = peer.end_point or "",
						allowed_ips = as_array(allowed_ips),
						dns = peer.dns or "",
						mtu = tonumber(peer.mtu),
						listen_port = tonumber(peer.listen_port),
						persistent_keepalive = tonumber(peer.persistent_keepalive),
						presharedkey_enable = peer.presharedkey_enable == "1",
						preshared_key = peer.preshared_key or "",
					}
				end
			end)
			wireguard[#wireguard + 1] = {
				group_id = group.group_id or "",
				group_name = group.group_name or "",
				group_type = 3,
				auth_type = 1,
				procedure = 0,
				show = 0,
				peers = as_array(peers),
			}
		end)

		local openvpn = {}
		cursor:foreach("gl_ovpnclient", "group", function(group)
			openvpn[#openvpn + 1] = {
				group_id = group.group_id or "",
				group_name = group.group_name or "",
				group_type = 3,
				auth_type = 1,
				procedure = 0,
				show = 0,
				clients = cjson.empty_array,
			}
		end)
		return { configs = { openvpn = as_array(openvpn), wireguard = as_array(wireguard) } }
	end,

	get_status = function()
		local cursor = uci.cursor()
		local status_list = {}
		for _, tunnel in ipairs(tunnel_sections(cursor)) do
			local iface = iface_name(tunnel.tunnel_id)
			local status = 0
			local rx_bytes, tx_bytes = 0, 0
			local peer = wg_peer(cursor, tunnel.group_id, tunnel.ref_id)
			if tunnel.enabled == "1" and tunnel.tunnel_type == "wireguard" then
				local interface = interface_status(iface)
				local handshake = wireguard_handshake(iface)
				if interface.up and handshake > 0 and os.time() - handshake < 180 then
					status = 1
				elseif interface.up then
					status = 2
				end
				rx_bytes, tx_bytes = wireguard_transfer(iface)
			end
			local endpoint = peer and peer.end_point or ""
			local host, port = tostring(endpoint):match("^%[(.-)%]:(%d+)$")
			if not host then host, port = tostring(endpoint):match("^([^:]+):(%d+)$") end
			status_list[#status_list + 1] = {
				tunnel_id = tunnel.tunnel_id or "",
				type = tunnel.tunnel_type or "wireguard",
				group_id = tunnel.group_id or "",
				peer_id = tunnel.ref_id or "",
				status = status,
				domain = host and { host } or cjson.empty_array,
				port = tonumber(port),
				rx_bytes = rx_bytes,
				tx_bytes = tx_bytes,
			}
		end
		return { status_list = as_array(status_list) }
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
