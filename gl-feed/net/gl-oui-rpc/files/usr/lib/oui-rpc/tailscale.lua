-- GL SDK4 Tailscale page adapter backed by OpenWrt's maintained Tailscale
-- package.  The GL frontend expects a small settings/status API; the actual
-- tunnel, authentication and WireGuard transport remain entirely upstream.

local cjson = require "cjson"
local ubus = require "ubus"
local uci = require "uci"

local function read_command(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	if not pipe then return nil end
	local data = pipe:read("*a")
	pipe:close()
	if data == "" then return nil end
	return data
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
end

local function status_json()
	local raw = read_command("/usr/sbin/tailscale status --json")
	if not raw then return nil end
	local ok, value = pcall(cjson.decode, raw)
	if ok and type(value) == "table" then return value end
	return nil
end

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function bool_value(cursor, option)
	return cursor:get("tailscale", "settings", option) == "1"
end

local function bool_arg(value, fallback)
	if value == nil then return fallback end
	return value == true
end

local function interface_status(name)
	local connected, conn = pcall(ubus.connect)
	if not connected or not conn then return nil end
	local ok, state = pcall(conn.call, conn,
		"network.interface." .. name, "status", {})
	conn:close()
	return ok and type(state) == "table" and state or nil
end

local function read_ipaddr(cursor, network)
	local raw = cursor:get("network", network, "ipaddr")
	if type(raw) == "table" then raw = raw[1] end
	if not raw then return nil, nil end
	local ip, prefix = raw:match("^([^/]+)/?(%d*)$")
	return ip or raw, tonumber(prefix)
end

local function ip_number(value)
	local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if not a or not b or not c or not d or a > 255 or b > 255 or
	   c > 255 or d > 255 then return nil end
	return a * 16777216 + b * 65536 + c * 256 + d
end

local function prefix_length(value)
	local numeric = tonumber(value)
	if numeric and numeric >= 0 and numeric <= 32 and numeric % 1 == 0 then
		return numeric
	end
	local mask = type(value) == "string" and ip_number(value)
	if not mask then return nil end
	local prefix, remainder = 0, mask
	while remainder >= 2147483648 do
		prefix = prefix + 1
		remainder = (remainder - 2147483648) * 2
	end
	return remainder == 0 and prefix or nil
end

local function network_prefix(ip, prefix)
	local address = ip and ip_number(ip)
	prefix = prefix_length(prefix)
	if not address or not prefix then return nil end
	local network = address - (address % (2 ^ (32 - prefix)))
	return string.format("%d.%d.%d.%d/%d",
		math.floor(network / 16777216) % 256,
		math.floor(network / 65536) % 256,
		math.floor(network / 256) % 256,
		network % 256, prefix)
end

local function interface_prefixes(name)
	local state = interface_status(name)
	local result, seen = {}, {}
	for _, address in ipairs(state and state["ipv4-address"] or {}) do
		local prefix = network_prefix(address.address, address.mask)
		if prefix and not seen[prefix] then
			seen[prefix] = true
			result[#result + 1] = prefix
		end
	end
	return result
end

local function lan_prefix(cursor)
	local ip, prefix = read_ipaddr(cursor, "lan")
	prefix = prefix or prefix_length(cursor:get("network", "lan", "netmask"))
	if not prefix then
		local state = interface_status("lan")
		local address = state and state["ipv4-address"] and state["ipv4-address"][1]
		if address then ip, prefix = address.address, address.mask end
	end
	return network_prefix(ip, prefix)
end

local function wan_prefixes(cursor)
	local result = interface_prefixes("wan")
	if #result > 0 then return result end
	local ip, prefix = read_ipaddr(cursor, "wan")
	prefix = prefix or prefix_length(cursor:get("network", "wan", "netmask"))
	local fallback = network_prefix(ip, prefix)
	if fallback then result[1] = fallback end
	return result
end

local function set_named_section(cursor, config, name, section_type, values)
	cursor:delete(config, name)
	cursor:set(config, name, section_type)
	for option, value in pairs(values or {}) do
		cursor:set(config, name, option,
			type(value) == "table" and value or tostring(value))
	end
end

local function configure_network(cursor)
	local changed = cursor:get("network", "tailscale") ~= "interface" or
		cursor:get("network", "tailscale", "proto") ~= "none" or
		cursor:get("network", "tailscale", "device") ~= "tailscale0"
	if not changed then return true end
	cursor:set("network", "tailscale", "interface")
	cursor:set("network", "tailscale", "proto", "none")
	cursor:set("network", "tailscale", "device", "tailscale0")
	cursor:commit("network")
	return command_ok("/etc/init.d/network reload")
end

local function configure_firewall(cursor, lan_enabled, wan_enabled, masq, run_exit_node)
	local zone_masq = masq or run_exit_node
	for _, section in ipairs({
		"gl_tailscale", "gl_tailscale_to_lan",
		"gl_tailscale_to_wan", "gl_lan_to_tailscale",
	}) do cursor:delete("firewall", section) end

	-- Merely enabling and authenticating Tailscale must not reload the
	-- router firewall.  Apart from being unnecessary, doing that while
	-- tailscaled is installing its own nftables chains can temporarily
	-- remove LAN access on some fw4 versions.  Only create a dedicated
	-- forwarding zone when the user explicitly enables a routing feature.
	if not (lan_enabled or wan_enabled or zone_masq or run_exit_node) then
		cursor:commit("firewall")
		return true
	end

	set_named_section(cursor, "firewall", "gl_tailscale", "zone", {
		name = "tailscale",
		input = "ACCEPT",
		output = "ACCEPT",
		forward = "ACCEPT",
		network = { "tailscale" },
		masq = zone_masq and "1" or "0",
		mtu_fix = "1",
	})
	if lan_enabled then
		set_named_section(cursor, "firewall", "gl_tailscale_to_lan",
			"forwarding", { src = "tailscale", dest = "lan" })
	end
	if wan_enabled or run_exit_node then
		set_named_section(cursor, "firewall", "gl_tailscale_to_wan",
			"forwarding", { src = "tailscale", dest = "wan" })
	end
	if masq then
		set_named_section(cursor, "firewall", "gl_lan_to_tailscale",
			"forwarding", { src = "lan", dest = "tailscale" })
	end
	cursor:commit("firewall")
	if not command_ok("/sbin/fw4 check") then return false end
	return command_ok("/etc/init.d/firewall reload")
end

local function apply_settings(cursor)
	local routes = {}
	local route_seen = {}
	local function add_route(prefix)
		if prefix and not route_seen[prefix] then
			route_seen[prefix] = true
			routes[#routes + 1] = prefix
		end
	end
	if bool_value(cursor, "lan_enabled") then
		add_route(lan_prefix(cursor))
	end
	if bool_value(cursor, "wan_enabled") then
		for _, prefix in ipairs(wan_prefixes(cursor)) do add_route(prefix) end
	end

	local exit_node = cursor:get("tailscale", "settings", "exit_node_ip") or ""
	local run_exit_node = bool_value(cursor, "run_exit_node")
	local masq = bool_value(cursor, "masq")
	local effective_masq = masq or run_exit_node
	local command = {
		"/usr/sbin/tailscale set",
		"--accept-dns=false",
		-- Importing tailnet subnet routes unconditionally can replace the
		-- directly-connected LAN route when a peer advertises an overlapping
		-- prefix (for example another 192.168.8.0/24 router).  That makes the
		-- admin UI and SSH appear to die immediately after binding.  The GL
		-- page has no "accept routes" control, so keep peer routes disabled;
		-- advertising this router's own selected subnets still works.
		"--accept-routes=false",
		"--advertise-routes=" .. shell_quote(table.concat(routes, ",")),
		"--advertise-exit-node=" .. (run_exit_node and "true" or "false"),
		"--exit-node=" .. shell_quote(exit_node),
		"--exit-node-allow-lan-access=" .. (exit_node ~= "" and "true" or "false"),
		"--snat-subnet-routes=" .. (effective_masq and "true" or "false"),
	}
	local tailscale_ok = command_ok(table.concat(command, " "))
	local network_ok = configure_network(cursor)
	local firewall_ok = configure_firewall(cursor, bool_value(cursor, "lan_enabled"),
		bool_value(cursor, "wan_enabled"), masq, run_exit_node)
	return tailscale_ok, network_ok and firewall_ok
end

local function exit_node_info(state)
	local result = { exit_node_list = {} }
	if type(state) ~= "table" or type(state.Peer) ~= "table" then return result end
	for _, peer in pairs(state.Peer) do
		if type(peer) == "table" and peer.ExitNodeOption and
		   type(peer.TailscaleIPs) == "table" and peer.TailscaleIPs[1] then
			local location = peer.DNSName or "Unknown location"
			if type(peer.Location) == "table" and peer.Location.Country then
				location = peer.Location.Country
				if peer.Location.City then location = location .. ", " .. peer.Location.City end
			else
				location = location:gsub("%.$", ""):gsub("%..*$", "")
			end
			local item = { ip = peer.TailscaleIPs[1], location = location }
			for _, tag in ipairs(peer.Tags or {}) do
				if tag == "tag:mullvad-exit-node" then item.provider = "mullvad" end
			end
			result.exit_node_list[#result.exit_node_list + 1] = item
		end
	end
	if type(state.ExitNodeStatus) == "table" and
	   type(state.ExitNodeStatus.TailscaleIPs) == "table" then
		result.exit_node_ip = state.ExitNodeStatus.TailscaleIPs[1]
	end
	return result
end

return {
	get_status = function()
		local state = status_json()
		local result = { status = 4, dns = {} }
		if not state then
			result.status = 1
			return result
		end
		local states = {
			NeedsLogin = 1, NeedsMachineAuth = 2, Running = 3,
			Starting = 4, NoState = 4, InUseOtherUser = 4,
		}
		result.status = states[state.BackendState] or 4
		local addresses = type(state.Self) == "table" and state.Self.TailscaleIPs or
			state.TailscaleIPs
		if type(addresses) == "table" then
			for _, address in ipairs(addresses) do
				if address:match("^%d+%.") then result.address_v4 = address break end
			end
		end
		if type(state.Self) == "table" and state.Self.UserID and
		   type(state.User) == "table" then
			for _, user in pairs(state.User) do
				if user.ID == state.Self.UserID then result.login_name = user.LoginName end
			end
		end
		local resolv = read_command("cat /tmp/resolv.conf.d/resolv.conf.auto")
		for address in (resolv or ""):gmatch("nameserver%s+(%d+%.%d+%.%d+%.%d+)") do
			result.dns[#result.dns + 1] = address
		end
		return result
	end,

	get_auth_url = function()
		local state = status_json()
		if state and state.AuthURL and state.AuthURL ~= "" then
			return { auth_url = state.AuthURL }
		end
		local output = read_command("/usr/sbin/tailscale login --timeout=3s 2>&1")
		local url = output and output:match("(https://login%.tailscale%.com/%S+)")
		return url and { auth_url = url } or
			{ err_code = 0, err_msg = "Failed to get device binding link" }
	end,

	get_config = function()
		local cursor = uci.cursor()
		return {
			enabled = bool_value(cursor, "enabled"),
			lan_enabled = bool_value(cursor, "lan_enabled"),
			wan_enabled = bool_value(cursor, "wan_enabled"),
			exit_node_ip = cursor:get("tailscale", "settings", "exit_node_ip") or "",
			masq = bool_value(cursor, "masq"),
			run_exit_node = bool_value(cursor, "run_exit_node"),
			lan_ip = lan_prefix(cursor),
		}
	end,

	get_exit_node_list = function()
		return exit_node_info(status_json())
	end,

	-- The real frontend (handleApply() in gl-sdk4-ui-tailscaleview) only
	-- sends the fields it actually changed - notably just {enabled:false}
	-- when disabling - not all five settings every time. Requiring every
	-- key on every call rejected that disable request outright, so the
	-- toggle silently failed to turn off and the next getConfig() reported
	-- back the still-enabled state, making the UI look like it "turned
	-- itself back on". Missing keys now fall back to the current value,
	-- same pattern as firewall.lua's set_wan_access.
	set_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		for _, key in ipairs({ "enabled", "lan_enabled", "wan_enabled",
			"masq", "run_exit_node" }) do
			if args[key] ~= nil and type(args[key]) ~= "boolean" then
				return { code = 1, message = key .. " must be boolean" }
			end
		end

		local enabled = bool_arg(args.enabled, bool_value(cursor, "enabled"))
		local lan_enabled = bool_arg(args.lan_enabled, bool_value(cursor, "lan_enabled"))
		local wan_enabled = bool_arg(args.wan_enabled, bool_value(cursor, "wan_enabled"))
		local masq = bool_arg(args.masq, bool_value(cursor, "masq"))
		local run_exit_node = bool_arg(args.run_exit_node, bool_value(cursor, "run_exit_node"))

		local exit_node = args.exit_node_ip
		if exit_node == nil then
			exit_node = cursor:get("tailscale", "settings", "exit_node_ip") or ""
		end
		if type(exit_node) ~= "string" or
		   (exit_node ~= "" and not ip_number(exit_node)) then
			return { code = 1, message = "invalid exit_node_ip" }
		end
		if run_exit_node and exit_node ~= "" then
			return { code = 1, message = "exit node conflict" }
		end

		cursor:set("tailscale", "settings", "enabled", enabled and "1" or "0")
		cursor:set("tailscale", "settings", "lan_enabled", lan_enabled and "1" or "0")
		cursor:set("tailscale", "settings", "wan_enabled", wan_enabled and "1" or "0")
		cursor:set("tailscale", "settings", "masq", masq and "1" or "0")
		cursor:set("tailscale", "settings", "run_exit_node", run_exit_node and "1" or "0")
		cursor:set("tailscale", "settings", "exit_node_ip", exit_node)
		cursor:commit("tailscale")

		if enabled then
			command_ok("/etc/init.d/tailscale enable")
			command_ok("/etc/init.d/tailscale start")
			local state = status_json()
			if not state or state.BackendState == "NeedsLogin" then
				command_ok("/usr/sbin/tailscale up --accept-dns=false --timeout=1s")
			end
			local tailscale_ok, routing_ok = apply_settings(cursor)
			if not tailscale_ok and state and state.BackendState == "Running" then
				return { code = 1, message = "failed to apply Tailscale settings" }
			end
			if not routing_ok then
				return { code = 1, message = "failed to apply Tailscale network or firewall settings" }
			end
		else
			command_ok("/usr/sbin/tailscale down")
			command_ok("/etc/init.d/tailscale stop")
			command_ok("/etc/init.d/tailscale disable")
			configure_firewall(cursor, false, false, false, false)
		end
		return {}
	end,

	logout = function()
		command_ok("/usr/sbin/tailscale logout")
		local cursor = uci.cursor()
		cursor:set("tailscale", "settings", "exit_node_ip", "")
		cursor:commit("tailscale")
		return {}
	end,
}
