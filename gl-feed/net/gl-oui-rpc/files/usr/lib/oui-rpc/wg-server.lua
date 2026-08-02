-- GL SDK4 WireGuard server page compatibility adapter.
--
-- This uses OpenWrt's upstream wireguard netifd protocol and firewall4.
-- It deliberately ships uninitialised and stopped: generating server keys
-- or pressing Start in the GL UI is required before it exposes a UDP port.

local cjson = require "cjson"
local uci = require "uci"

local CONFIG = "gl_wgserver"
local SERVER = "main"
local IFACE = "wgserver"

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function command_output(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	if not pipe then return "" end
	local data = pipe:read("*a") or ""
	pipe:close()
	return (data:gsub("%s+$", ""))
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
end

local function bool(value)
	return value == true or value == 1 or value == "1"
end

local function key_pair()
	local private = command_output("wg genkey")
	if not private:match("^[A-Za-z0-9+/]+=?=?$") then return nil end
	local public = command_output("printf %s " .. shell_quote(private) .. " | wg pubkey")
	if not public:match("^[A-Za-z0-9+/]+=?=?$") then return nil end
	return private, public
end

local function public_key(private)
	if type(private) ~= "string" or private == "" then return nil end
	local public = command_output("printf %s " .. shell_quote(private) .. " | wg pubkey")
	if not public:match("^[A-Za-z0-9+/]+=?=?$") then return nil end
	return public
end

local function cursor_get(cursor, option, default)
	local value = cursor:get(CONFIG, SERVER, option)
	if value == nil or value == "" then return default end
	return value
end

local function server_config(cursor)
	return {
		initialization = cursor_get(cursor, "initialized", "0") == "1",
		address_v4 = cursor_get(cursor, "address_v4", "10.0.0.1/24"),
		address_v6 = cursor_get(cursor, "address_v6", ""),
		port = tonumber(cursor_get(cursor, "port", "51820")) or 51820,
		private_key = cursor_get(cursor, "private_key", ""),
		public_key = cursor_get(cursor, "public_key", ""),
		obfuscation = 0,
		amnezia = "",
	}
end

local function peer_sections(cursor)
	local peers = {}
	cursor:foreach(CONFIG, "peer", function(section)
		peers[#peers + 1] = section
	end)
	table.sort(peers, function(a, b)
		return tostring(a.peer_id or a[".name"]) < tostring(b.peer_id or b[".name"])
	end)
	return peers
end

local function peer_id()
	local seed = tostring(os.time()) .. tostring(math.random(100000, 999999))
	return command_output("printf %s " .. shell_quote(seed) ..
		" | sha256sum | cut -c1-16")
end

local function split_csv(value)
	local result = {}
	for item in tostring(value or ""):gmatch("[^,]+") do
		local cleaned = item:match("^%s*(.-)%s*$")
		if cleaned ~= "" then result[#result + 1] = cleaned end
	end
	return result
end

local function next_client_ipv4(cursor)
	local address = cursor_get(cursor, "address_v4", "10.0.0.1/24")
	local a, b, c = address:match("^(%d+)%.(%d+)%.(%d+)%.%d+")
	if not a then return "" end
	local used = {}
	for _, peer in ipairs(peer_sections(cursor)) do
		local last = tostring(peer.client_ip_v4 or ""):match("^%d+%.%d+%.%d+%.(%d+)")
		if last then used[tonumber(last)] = true end
	end
	for host = 2, 254 do
		if not used[host] then
			return string.format("%s.%s.%s.%d/32", a, b, c, host)
		end
	end
	return ""
end

local function next_client_ipv6(cursor)
	local address = cursor_get(cursor, "address_v6", "")
	local prefix = address:match("^([^/]+)/64$")
	if not prefix or prefix == "" then return "" end
	prefix = prefix:gsub("::.*$", "::")
	local used = {}
	for _, peer in ipairs(peer_sections(cursor)) do
		local host = tostring(peer.client_ip_v6 or ""):match("::(%x+)/128$")
		if host then used[tonumber(host, 16)] = true end
	end
	for host = 2, 65535 do
		if not used[host] then
			return prefix .. string.format("%x/128", host)
		end
	end
	return ""
end

local function delete_type(cursor, package, section_type)
	local names = {}
	cursor:foreach(package, section_type, function(section)
		names[#names + 1] = section[".name"]
	end)
	for _, name in ipairs(names) do cursor:delete(package, name) end
end

-- uci.cursor() has no section() method (add()/set() only) - the calls
-- below used to call a nonexistent method and would crash the moment
-- anyone actually pressed Start on the WireGuard Server page.
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

local function apply_runtime(cursor)
	local config = server_config(cursor)
	if not config.initialization or config.private_key == "" then
		return false, "WireGuard server is not initialized"
	end

	cursor:delete("network", IFACE)
	delete_type(cursor, "network", "wireguard_" .. IFACE)
	local stale_routes = {}
	for _, route_type in ipairs({ "route", "route6" }) do
		cursor:foreach("network", route_type, function(section)
			if tostring(section[".name"] or ""):match("^gl_wg_route_") then
				stale_routes[#stale_routes + 1] = section[".name"]
			end
		end)
	end
	for _, name in ipairs(stale_routes) do cursor:delete("network", name) end
	new_section(cursor, "network", "interface", IFACE, {
		proto = "wireguard",
		private_key = config.private_key,
		listen_port = tostring(config.port),
		mtu = tostring(tonumber(cursor_get(cursor, "mtu", "1420")) or 1420),
		addresses = as_array((function()
			local addresses = { config.address_v4 }
			if config.address_v6 ~= "" then addresses[#addresses + 1] = config.address_v6 end
			return addresses
		end)()),
	})

	for _, peer in ipairs(peer_sections(cursor)) do
		if cursor:get(CONFIG, peer[".name"], "enabled") ~= "0"
			and peer.public_key and peer.public_key ~= "" then
			local allowed = {}
			if peer.client_ip_v4 and peer.client_ip_v4 ~= "" then
				allowed[#allowed + 1] = peer.client_ip_v4
			end
			if peer.client_ip_v6 and peer.client_ip_v6 ~= "" then
				allowed[#allowed + 1] = peer.client_ip_v6
			end
			local values = {
				public_key = peer.public_key,
				allowed_ips = as_array(allowed),
				route_allowed_ips = "1",
				persistent_keepalive = tostring(tonumber(peer.persistent_keepalive) or 0),
				description = peer.name or peer.peer_id or "peer",
			}
			if bool(peer.presharedkey_enable) and peer.presharedkey
			and peer.presharedkey ~= "" then
				values.preshared_key = peer.presharedkey
			end
			new_anon_section(cursor, "network", "wireguard_" .. IFACE, values)
		end
	end
	cursor:foreach(CONFIG, "route", function(route)
		local id = tostring(route.rule_id or route[".name"]):gsub("[^%w_]", "")
		local version = tonumber(route.route_flag) == 6 and 6 or 4
		local values = {
			interface = IFACE,
			target = route.dest or "",
			gateway = route.gateway or "",
			metric = tostring(tonumber(route.metric) or 0),
			mtu = tostring(tonumber(route.mtu) or 0),
		}
		if route.scope and route.scope ~= "" then values.scope = route.scope end
		new_section(cursor, "network", version == 6 and "route6" or "route",
			"gl_wg_route_" .. id, values)
	end)
	cursor:commit("network")

	for _, name in ipairs({
		"gl_wgserver", "gl_wgserver_to_lan", "gl_wgserver_to_wan",
		"gl_wgserver_input",
	}) do
		cursor:delete("firewall", name)
	end
	new_section(cursor, "firewall", "zone", "gl_wgserver", {
		name = IFACE,
		network = IFACE,
		input = "ACCEPT",
		output = "ACCEPT",
		forward = cursor_get(cursor, "client_to_client", "0") == "1"
			and "ACCEPT" or "REJECT",
		masq = cursor_get(cursor, "masq", "1"),
	})
	if cursor_get(cursor, "local_access", "1") == "1" then
		new_section(cursor, "firewall", "forwarding", "gl_wgserver_to_lan",
			{ src = IFACE, dest = "lan" })
	end
	new_section(cursor, "firewall", "forwarding", "gl_wgserver_to_wan",
		{ src = IFACE, dest = "wan" })
	new_section(cursor, "firewall", "rule", "gl_wgserver_input", {
		name = "Allow-WireGuard-Server",
		src = "wan",
		proto = "udp",
		dest_port = tostring(config.port),
		target = "ACCEPT",
	})
	cursor:commit("firewall")
	command_ok("ubus call network reload")
	command_ok("/etc/init.d/firewall reload")
	return true
end

local function interface_status()
	local raw = command_output("ubus call network.interface." .. IFACE .. " status")
	local ok, status = pcall(cjson.decode, raw)
	if not ok or type(status) ~= "table" then return {} end
	return status
end

local function peer_by_id(cursor, id)
	for _, peer in ipairs(peer_sections(cursor)) do
		if tostring(peer.peer_id or "") == tostring(id or "") then
			return peer
		end
	end
	return nil
end

local function route_by_id(cursor, id)
	local found
	cursor:foreach(CONFIG, "route", function(route)
		if not found and tostring(route.rule_id or "") == tostring(id or "") then
			found = route
		end
	end)
	return found
end

local function route_result(route)
	return {
		rule_id = route.rule_id or "",
		dest = route.dest or "",
		gateway = route.gateway or "",
		metric = tonumber(route.metric) or 0,
		mtu = tonumber(route.mtu) or 0,
		scope = route.scope or "",
	}
end

local function write_route(cursor, section, args)
	local flag = tonumber(args.route_flag)
	if flag ~= 4 and flag ~= 6 then return nil, "invalid address family" end
	if type(args.dest) ~= "string" or args.dest == "" or args.dest:find("%s") then
		return nil, "invalid destination"
	end
	cursor:set(CONFIG, section, "route_flag", tostring(flag))
	cursor:set(CONFIG, section, "dest", args.dest)
	cursor:set(CONFIG, section, "gateway", args.gateway or "")
	cursor:set(CONFIG, section, "metric", tostring(tonumber(args.metric) or 0))
	cursor:set(CONFIG, section, "mtu", tostring(tonumber(args.mtu) or 0))
	cursor:set(CONFIG, section, "scope", args.scope or "")
	cursor:commit(CONFIG)
	return true
end

local function peer_result(peer)
	return {
		peer_id = peer.peer_id or "",
		name = peer.name or "",
		enabled = peer.enabled ~= "0",
		deprecated = false,
		allowed_ips = peer.allowed_ips or "0.0.0.0/0, ::/0",
		dns = peer.dns or "",
		mtu = tonumber(peer.mtu) or 0,
		persistent_keepalive = tonumber(peer.persistent_keepalive) or 0,
		presharedkey = peer.presharedkey or "",
		presharedkey_enable = peer.presharedkey_enable == "1",
	}
end

local function write_peer(cursor, section, args, is_new)
	if type(args.name) ~= "string" or args.name == "" or #args.name > 64 then
		return nil, "invalid peer name"
	end
	if is_new then
		local private, public = key_pair()
		if not private then return nil, "failed to generate peer key" end
		cursor:set(CONFIG, section, "peer_id", args.peer_id)
		cursor:set(CONFIG, section, "private_key", private)
		cursor:set(CONFIG, section, "public_key", public)
		cursor:set(CONFIG, section, "client_ip_v4", next_client_ipv4(cursor))
		cursor:set(CONFIG, section, "client_ip_v6", next_client_ipv6(cursor))
		cursor:set(CONFIG, section, "enabled", "1")
	end
	cursor:set(CONFIG, section, "name", args.name)
	cursor:set(CONFIG, section, "allowed_ips", args.allowed_ips or "0.0.0.0/0, ::/0")
	cursor:set(CONFIG, section, "dns", args.dns or "")
	cursor:set(CONFIG, section, "mtu", tostring(tonumber(args.mtu) or 0))
	cursor:set(CONFIG, section, "persistent_keepalive",
		tostring(tonumber(args.persistent_keepalive) or 0))
	cursor:set(CONFIG, section, "presharedkey_enable",
		bool(args.presharedkey_enable) and "1" or "0")
	if type(args.presharedkey) == "string" then
		cursor:set(CONFIG, section, "presharedkey", args.presharedkey)
	end
	if args.enabled ~= nil then
		cursor:set(CONFIG, section, "enabled", bool(args.enabled) and "1" or "0")
	end
	cursor:commit(CONFIG)
	return true
end

local function refresh_if_running(cursor)
	if cursor_get(cursor, "enabled", "0") == "1" then
		apply_runtime(cursor)
		command_ok("ifup " .. IFACE)
	end
end

return {
	generate_key = function()
		local private, public = key_pair()
		if not private then return { err_code = 1, err_msg = "wireguard-tools unavailable" } end
		local cursor = uci.cursor()
		cursor:set(CONFIG, SERVER, "private_key", private)
		cursor:set(CONFIG, SERVER, "public_key", public)
		cursor:set(CONFIG, SERVER, "initialized", "1")
		cursor:commit(CONFIG)
		return {}
	end,

	generate_publickey = function(args)
		local public = public_key(args and args.private_key)
		if not public then return { err_code = 1, err_msg = "invalid private key" } end
		return { public_key = public }
	end,

	get_config = function()
		local cursor = uci.cursor()
		return server_config(cursor)
	end,

	set_config = function(args)
		args = args or {}
		local port = tonumber(args.port)
		if not port or port < 1 or port > 65535 then
			return { err_code = 1, err_msg = "invalid listen port" }
		end
		if type(args.address_v4) ~= "string"
		or not args.address_v4:match("^%d+%.%d+%.%d+%.%d+/%d+$") then
			return { err_code = 1, err_msg = "invalid IPv4 address" }
		end
		local public = public_key(args.private_key)
		if not public then return { err_code = 1, err_msg = "invalid private key" } end
		local cursor = uci.cursor()
		cursor:set(CONFIG, SERVER, "address_v4", args.address_v4)
		cursor:set(CONFIG, SERVER, "address_v6", args.address_v6 or "")
		cursor:set(CONFIG, SERVER, "port", tostring(port))
		cursor:set(CONFIG, SERVER, "private_key", args.private_key)
		cursor:set(CONFIG, SERVER, "public_key", public)
		cursor:set(CONFIG, SERVER, "initialized", "1")
		cursor:commit(CONFIG)
		refresh_if_running(cursor)
		return {}
	end,

	get_peer_list = function()
		local cursor = uci.cursor()
		local peers = {}
		for _, peer in ipairs(peer_sections(cursor)) do
			peers[#peers + 1] = peer_result(peer)
		end
		return { peers = as_array(peers) }
	end,

	add_peer = function(args)
		args = args or {}
		local cursor = uci.cursor()
		args.peer_id = peer_id()
		local section = new_section(cursor, CONFIG, "peer", "p_" .. args.peer_id, {})
		local ok, err = write_peer(cursor, section, args, true)
		if not ok then
			cursor:delete(CONFIG, section)
			cursor:commit(CONFIG)
			return { err_code = 1, err_msg = err }
		end
		refresh_if_running(cursor)
		return { peer_id = args.peer_id }
	end,

	set_peer = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local peer = peer_by_id(cursor, args.peer_id)
		if not peer then return { err_code = 1, err_msg = "peer not found" } end
		local ok, err = write_peer(cursor, peer[".name"], args, false)
		if not ok then return { err_code = 1, err_msg = err } end
		refresh_if_running(cursor)
		return {}
	end,

	remove_peer = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if bool(args.all) then
			for _, peer in ipairs(peer_sections(cursor)) do
				cursor:delete(CONFIG, peer[".name"])
			end
		else
			local peer = peer_by_id(cursor, args.peer_id)
			if not peer then return { err_code = 1, err_msg = "peer not found" } end
			cursor:delete(CONFIG, peer[".name"])
		end
		cursor:commit(CONFIG)
		refresh_if_running(cursor)
		return {}
	end,

	generate_peer = function(args)
		local cursor = uci.cursor()
		local peer = peer_by_id(cursor, args and args.peer_id)
		if not peer then return { err_code = 1, err_msg = "peer not found" } end
		local config = server_config(cursor)
		local addresses = {}
		if peer.client_ip_v4 and peer.client_ip_v4 ~= "" then
			addresses[#addresses + 1] = peer.client_ip_v4
		end
		if peer.client_ip_v6 and peer.client_ip_v6 ~= "" then
			addresses[#addresses + 1] = peer.client_ip_v6
		end
		return {
			address = table.concat(addresses, ", "),
			allowed_ips = peer.allowed_ips or "0.0.0.0/0, ::/0",
			dns = peer.dns or "",
			end_point = "",
			listen_port = tostring(config.port),
			persistent_keepalive = tostring(tonumber(peer.persistent_keepalive) or 0),
			private_key = peer.private_key or "",
			public_key = config.public_key,
			mtu = tonumber(peer.mtu) > 0 and tonumber(peer.mtu)
				or tonumber(cursor_get(cursor, "mtu", "1420")) or 1420,
			presharedkey = bool(peer.presharedkey_enable)
				and (peer.presharedkey or "") or "",
			amnezia = "",
		}
	end,

	get_setting = function()
		local cursor = uci.cursor()
		return {
			mtu = tonumber(cursor_get(cursor, "mtu", "1420")) or 1420,
			local_access = cursor_get(cursor, "local_access", "1") == "1",
			masq = cursor_get(cursor, "masq", "1") == "1",
			client_to_client = cursor_get(cursor, "client_to_client", "0") == "1",
		}
	end,

	set_setting = function(args)
		args = args or {}
		local mtu = tonumber(args.mtu) or 0
		if mtu ~= 0 and (mtu < 68 or mtu > 65535) then
			return { err_code = 1, err_msg = "invalid MTU" }
		end
		local cursor = uci.cursor()
		cursor:set(CONFIG, SERVER, "mtu", tostring(mtu == 0 and 1420 or mtu))
		cursor:set(CONFIG, SERVER, "local_access", bool(args.local_access) and "1" or "0")
		cursor:set(CONFIG, SERVER, "masq", bool(args.masq) and "1" or "0")
		cursor:set(CONFIG, SERVER, "client_to_client",
			bool(args.client_to_client) and "1" or "0")
		cursor:commit(CONFIG)
		refresh_if_running(cursor)
		return {}
	end,

	start = function()
		local cursor = uci.cursor()
		local ok, err = apply_runtime(cursor)
		if not ok then return { err_code = 1, err_msg = err } end
		cursor:set(CONFIG, SERVER, "enabled", "1")
		cursor:commit(CONFIG)
		command_ok("ifup " .. IFACE)
		return {}
	end,

	stop = function()
		local cursor = uci.cursor()
		cursor:set(CONFIG, SERVER, "enabled", "0")
		cursor:commit(CONFIG)
		command_ok("ifdown " .. IFACE)
		return {}
	end,

	get_status = function()
		local cursor = uci.cursor()
		local status = interface_status()
		local running = status.up == true
		local live = {}
		local dump = command_output("wg show " .. IFACE .. " dump")
		local line_no = 0
		for line in dump:gmatch("[^\n]+") do
			line_no = line_no + 1
			if line_no > 1 then
				local fields = {}
				for field in line:gmatch("[^\t]+") do fields[#fields + 1] = field end
				if fields[1] then
					live[fields[1]] = {
						public_ip = fields[3] or "",
						latest_handshake = tonumber(fields[5]) or 0,
						rx_bytes = tonumber(fields[6]) or 0,
						tx_bytes = tonumber(fields[7]) or 0,
					}
				end
			end
		end
		local peers = {}
		local total_rx, total_tx = 0, 0
		for _, peer in ipairs(peer_sections(cursor)) do
			local state = live[peer.public_key or ""] or {}
			total_rx = total_rx + (state.rx_bytes or 0)
			total_tx = total_tx + (state.tx_bytes or 0)
			peers[#peers + 1] = {
				name = peer.name or "",
				private_ip = tostring(peer.client_ip_v4 or ""):gsub("/32$", ""),
				public_ip = state.public_ip or "",
				latest_handshake = state.latest_handshake or 0,
				rx_bytes = state.rx_bytes or 0,
				tx_bytes = state.tx_bytes or 0,
			}
		end
		return {
			server = {
				status = running and 1 or 0,
				tunnel_ip = cursor_get(cursor, "address_v4", "10.0.0.1/24"),
				rx_bytes = total_rx,
				tx_bytes = total_tx,
			},
			peers = as_array(peers),
		}
	end,

	get_route_list = function()
		local cursor = uci.cursor()
		local ipv4, ipv6 = {}, {}
		cursor:foreach(CONFIG, "route", function(route)
			local list = tonumber(route.route_flag) == 6 and ipv6 or ipv4
			list[#list + 1] = route_result(route)
		end)
		return {
			ipv4_route_rules = as_array(ipv4),
			ipv6_route_rules = as_array(ipv6),
		}
	end,

	add_route = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local id = peer_id()
		local section = new_section(cursor, CONFIG, "route", "r_" .. id,
			{ rule_id = id })
		local ok, err = write_route(cursor, section, args)
		if not ok then
			cursor:delete(CONFIG, section)
			cursor:commit(CONFIG)
			return { err_code = 1, err_msg = err }
		end
		refresh_if_running(cursor)
		return { rule_id = id }
	end,
	set_route = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local route = route_by_id(cursor, args.rule_id)
		if not route then return { err_code = 1, err_msg = "route not found" } end
		local ok, err = write_route(cursor, route[".name"], args)
		if not ok then return { err_code = 1, err_msg = err } end
		refresh_if_running(cursor)
		return {}
	end,
	remove_route = function(args)
		local cursor = uci.cursor()
		local route = route_by_id(cursor, args and args.rule_id)
		if not route then return { err_code = 1, err_msg = "route not found" } end
		cursor:delete(CONFIG, route[".name"])
		cursor:commit(CONFIG)
		refresh_if_running(cursor)
		return {}
	end,
}
