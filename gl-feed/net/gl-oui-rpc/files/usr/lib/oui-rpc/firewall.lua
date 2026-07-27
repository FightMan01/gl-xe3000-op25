-- "firewall" RPC object: port forwarding, DMZ, WAN access, custom rules,
-- zone ACL rules.
--
-- Built against fw4/nftables via its own UCI `config redirect`/`config
-- rule` abstraction rather than iptables. Method set matches the stock
-- GL.iNet UI. "acl" here means firewall zone/traffic ACL rules (who can
-- reach what) - a different concept from this feed's separate acl.lua
-- (admin-GUI user/group permissions).

local uci = require "uci"
local cjson = require "cjson"

-- See clients.lua's as_array() for the full explanation: lua-cjson can't
-- tell an empty array apart from an empty object, always emits "{}" for
-- a bare `{}` - breaks frontend .map()/.forEach() calls on fields that
-- are semantically arrays but happen to be empty right now (e.g. no port
-- forwards/custom rules/ACL rules configured yet).
local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local function bool_arg(value, fallback)
	if value == nil then return fallback end
	return value == true
end

local function valid_ip(value)
	if type(value) ~= "string" or #value < 2 or #value > 64 then return false end
	-- The Management Control frontend accepts a single IPv4 or IPv6
	-- address (not a shell expression or hostname). fw4 performs the final
	-- semantic validation; this deliberately narrow character check keeps
	-- malformed values out of UCI and command/config contexts.
	if value:find(":", 1, true) then
		return value:match("^[%x:%.]+$") ~= nil
	end
	local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return false end
	for _, octet in ipairs({ a, b, c, d }) do
		if tonumber(octet) > 255 then return false end
	end
	return true
end

local function wan_whitelist(cursor)
	local out = {}
	cursor:foreach("gl-oui-rpc", "wan_whitelist", function(s)
		if valid_ip(s.ipaddr) then
			table.insert(out, { name = s.name or "", ipaddr = s.ipaddr })
		end
	end)
	return out
end

local function set_sources(cursor, section, sources)
	if #sources > 0 then
		cursor:set("firewall", section, "src_ip", sources)
	end
end

local function forward_to_table(s)
	return {
		id = s[".name"],
		name = s.name,
		proto = s.proto,
		src = s.src,
		dest = s.dest,
		src_dport = s.src_dport,
		dest_ip = s.dest_ip,
		dest_port = s.dest_port,
		enabled = s.enabled ~= "0",
	}
end

local function rule_to_table(s)
	return {
		id = s[".name"],
		name = s.name,
		src = s.src,
		dest = s.dest,
		proto = s.proto,
		dest_port = s.dest_port,
		target = s.target,
		enabled = s.enabled ~= "0",
	}
end

return {
	get_port_forward_list = function(args)
		local cursor = uci.cursor()
		local out = {}
		cursor:foreach("firewall", "redirect", function(s)
			if s.target == "DNAT" and s[".name"] ~= "gl_dmz" then
				table.insert(out, forward_to_table(s))
			end
		end)
		return { res = as_array(out) }
	end,

	-- args: name, proto ('tcp'|'udp'|'tcp udp'), src_dport, dest_ip, dest_port
	add_port_forward = function(args)
		if not (args.dest_ip and args.dest_port and args.src_dport) then
			return { code = 1, message = "missing required fields" }
		end
		local cursor = uci.cursor()
		local name = cursor:add("firewall", "redirect")
		cursor:set("firewall", name, "name", args.name or ("Port Forward " .. args.src_dport))
		cursor:set("firewall", name, "target", "DNAT")
		cursor:set("firewall", name, "src", "wan")
		cursor:set("firewall", name, "dest", "lan")
		cursor:set("firewall", name, "proto", args.proto or "tcp udp")
		cursor:set("firewall", name, "src_dport", tostring(args.src_dport))
		cursor:set("firewall", name, "dest_ip", args.dest_ip)
		cursor:set("firewall", name, "dest_port", tostring(args.dest_port))
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return { id = name }
	end,

	-- Full edit (rename from the old, enable-only set_port_forward_enabled).
	set_port_forward = function(args)
		if not args.id then
			return { code = 1, message = "missing id" }
		end
		local cursor = uci.cursor()
		if not cursor:get("firewall", args.id) then
			return { code = 1, message = "unknown id" }
		end
		if args.name then cursor:set("firewall", args.id, "name", args.name) end
		if args.proto then cursor:set("firewall", args.id, "proto", args.proto) end
		if args.src_dport then cursor:set("firewall", args.id, "src_dport", tostring(args.src_dport)) end
		if args.dest_ip then cursor:set("firewall", args.id, "dest_ip", args.dest_ip) end
		if args.dest_port then cursor:set("firewall", args.id, "dest_port", tostring(args.dest_port)) end
		if args.enabled ~= nil then cursor:set("firewall", args.id, "enabled", args.enabled and "1" or "0") end
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	remove_port_forward = function(args)
		if not args.id then
			return { code = 1, message = "missing id" }
		end
		local cursor = uci.cursor()
		cursor:delete("firewall", args.id)
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	-- Not wired to a real ordering concept yet (fw4 evaluates redirect
	-- Reordering rewrite-in-place isn't a confirmed-safe operation with
	-- the available uci Lua binding (no exposed reorder method found, and
	-- a delete+recreate approach risks silently dropping fields if the
	-- binding's section-dump behavior isn't exactly what's assumed) -
	-- honest "not yet implemented" rather than a fake success or an
	-- untested risky rewrite of live firewall rules.
	order_port_forward = function(args)
		return { code = 1, message = "reordering not yet implemented" }
	end,

	get_dmz = function(args)
		local cursor = uci.cursor()
		local dmz_ip = nil
		cursor:foreach("firewall", "redirect", function(s)
			if s[".name"] == "gl_dmz" then dmz_ip = s.dest_ip end
		end)
		return { enabled = dmz_ip ~= nil, dest_ip = dmz_ip }
	end,

	set_dmz = function(args)
		local cursor = uci.cursor()
		cursor:delete("firewall", "gl_dmz")
		if args.enabled and args.dest_ip then
			cursor:set("firewall", "gl_dmz", "redirect")
			cursor:set("firewall", "gl_dmz", "name", "GL DMZ")
			cursor:set("firewall", "gl_dmz", "target", "DNAT")
			cursor:set("firewall", "gl_dmz", "src", "wan")
			cursor:set("firewall", "gl_dmz", "dest", "lan")
			cursor:set("firewall", "gl_dmz", "proto", "all")
			cursor:set("firewall", "gl_dmz", "dest_ip", args.dest_ip)
		end
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	-- Exact shape consumed by gl-sdk4-ui-management-control.
	get_wan_access = function(args)
		local cursor = uci.cursor()
		local whitelist = wan_whitelist(cursor)
		return {
			enable_ping = cursor:get("gl-oui-rpc", "wan_access", "enable_ping") ~= "0",
			enable_https = cursor:get("gl-oui-rpc", "wan_access", "enable_https") == "1",
			enable_ssh = cursor:get("gl-oui-rpc", "wan_access", "enable_ssh") == "1",
			enable_whitelist = cursor:get("gl-oui-rpc", "wan_access", "enable_whitelist") == "1",
			whitelist = as_array(whitelist),
		}
	end,

	-- Remote access is implemented as fw4 input rules on the actual ports
	-- configured by local-access.set_config. No DNAT is needed: nginx and
	-- dropbear already listen on those ports. If the optional whitelist is
	-- active, its source list is attached to every exposed service.
	set_wan_access = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if not cursor:get("gl-oui-rpc", "wan_access") then
			cursor:set("gl-oui-rpc", "wan_access", "wan_access")
		end

		local current = cursor:get_all("gl-oui-rpc", "wan_access") or {}
		local enable_ping = bool_arg(args.enable_ping, current.enable_ping ~= "0")
		local enable_https = bool_arg(args.enable_https, current.enable_https == "1")
		local enable_ssh = bool_arg(args.enable_ssh, current.enable_ssh == "1")
		local enable_whitelist = bool_arg(args.enable_whitelist,
			current.enable_whitelist == "1")

		local entries = args.whitelist
		if entries == nil then entries = wan_whitelist(cursor) end
		if type(entries) ~= "table" then
			return { code = 1, message = "invalid whitelist" }
		end
		local sources = {}
		local cleaned = {}
		for _, item in ipairs(entries) do
			if type(item) ~= "table" or not valid_ip(item.ipaddr) then
				return { code = 1, message = "invalid whitelist address" }
			end
			table.insert(sources, item.ipaddr)
			table.insert(cleaned, {
				name = type(item.name) == "string" and item.name:sub(1, 64) or "",
				ipaddr = item.ipaddr,
			})
		end
		if enable_whitelist and #sources == 0 then
			return { code = 1, message = "whitelist cannot be empty" }
		end
		local rule_sources = enable_whitelist and sources or {}

		cursor:delete("firewall", "gl_wan_ping_allow")
		cursor:delete("firewall", "gl_wan_ping_block")
		cursor:delete("firewall", "gl_remote_admin_accept")
		cursor:delete("firewall", "gl_remote_admin_redirect")
		cursor:delete("firewall", "gl_remote_admin_https")
		cursor:delete("firewall", "gl_remote_admin_ssh")

		-- The stock OpenWrt Allow-Ping rule otherwise wins before a later
		-- block/whitelist rule, so explicitly enable it only for unrestricted
		-- WAN ping and use our ordered allow-then-drop pair for whitelisting.
		local found_allow_ping = false
		cursor:foreach("firewall", "rule", function(s)
			if s.name == "Allow-Ping" then
				found_allow_ping = true
				cursor:set("firewall", s[".name"], "enabled",
					(enable_ping and not enable_whitelist) and "1" or "0")
			end
		end)
		if enable_ping and (enable_whitelist or not found_allow_ping) then
			cursor:set("firewall", "gl_wan_ping_allow", "rule")
			cursor:set("firewall", "gl_wan_ping_allow", "name", "GL WAN Ping")
			cursor:set("firewall", "gl_wan_ping_allow", "src", "wan")
			cursor:set("firewall", "gl_wan_ping_allow", "proto", "icmp")
			cursor:set("firewall", "gl_wan_ping_allow", "icmp_type", "echo-request")
			cursor:set("firewall", "gl_wan_ping_allow", "target", "ACCEPT")
			set_sources(cursor, "gl_wan_ping_allow", rule_sources)
		end
		if not enable_ping or enable_whitelist then
			cursor:set("firewall", "gl_wan_ping_block", "rule")
			cursor:set("firewall", "gl_wan_ping_block", "name", "Block WAN ping")
			cursor:set("firewall", "gl_wan_ping_block", "src", "wan")
			cursor:set("firewall", "gl_wan_ping_block", "proto", "icmp")
			cursor:set("firewall", "gl_wan_ping_block", "icmp_type", "echo-request")
			cursor:set("firewall", "gl_wan_ping_block", "target", "DROP")
		end

		-- libuci's Lua binding returns an additional status value; the
		-- extra parentheses collapse it before tonumber(), whose optional
		-- second parameter is otherwise interpreted as a numeric base.
		local https_port = tonumber((cursor:get("gl-oui-rpc", "main", "https_port"))) or 443
		local ssh_port = tonumber((cursor:get("dropbear", "main", "Port"))) or 22
		if enable_https then
			cursor:set("firewall", "gl_remote_admin_https", "rule")
			cursor:set("firewall", "gl_remote_admin_https", "name", "GL Remote HTTPS")
			cursor:set("firewall", "gl_remote_admin_https", "src", "wan")
			cursor:set("firewall", "gl_remote_admin_https", "proto", "tcp")
			cursor:set("firewall", "gl_remote_admin_https", "dest_port", tostring(https_port))
			cursor:set("firewall", "gl_remote_admin_https", "target", "ACCEPT")
			set_sources(cursor, "gl_remote_admin_https", rule_sources)
		end
		if enable_ssh and cursor:get("dropbear", "main", "enable") ~= "0" then
			cursor:set("firewall", "gl_remote_admin_ssh", "rule")
			cursor:set("firewall", "gl_remote_admin_ssh", "name", "GL Remote SSH")
			cursor:set("firewall", "gl_remote_admin_ssh", "src", "wan")
			cursor:set("firewall", "gl_remote_admin_ssh", "proto", "tcp")
			cursor:set("firewall", "gl_remote_admin_ssh", "dest_port", tostring(ssh_port))
			cursor:set("firewall", "gl_remote_admin_ssh", "target", "ACCEPT")
			set_sources(cursor, "gl_remote_admin_ssh", rule_sources)
		end
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")

		cursor:foreach("gl-oui-rpc", "wan_whitelist", function(s)
			cursor:delete("gl-oui-rpc", s[".name"])
		end)
		for _, item in ipairs(cleaned) do
			local section = cursor:add("gl-oui-rpc", "wan_whitelist")
			cursor:set("gl-oui-rpc", section, "name", item.name)
			cursor:set("gl-oui-rpc", section, "ipaddr", item.ipaddr)
		end
		cursor:set("gl-oui-rpc", "wan_access", "enable_ping", enable_ping and "1" or "0")
		cursor:set("gl-oui-rpc", "wan_access", "enable_https", enable_https and "1" or "0")
		cursor:set("gl-oui-rpc", "wan_access", "enable_ssh", enable_ssh and "1" or "0")
		cursor:set("gl-oui-rpc", "wan_access", "enable_whitelist",
			enable_whitelist and "1" or "0")
		cursor:commit("gl-oui-rpc")

		return {}
	end,

	-- Generic custom firewall rules (beyond port-forward/DMZ), backed by
	-- plain fw4 `config rule` sections tagged so this object only sees
	-- ones it created.
	get_rule_list = function(args)
		local cursor = uci.cursor()
		local out = {}
		cursor:foreach("firewall", "rule", function(s)
			if s.gl_custom == "1" then
				table.insert(out, rule_to_table(s))
			end
		end)
		return { res = as_array(out) }
	end,

	-- args: name, src, dest, proto, dest_port, target ('ACCEPT'|'DROP'|'REJECT')
	add_rule = function(args)
		if type(args.target) ~= "string" then
			return { code = 1, message = "missing target" }
		end
		local cursor = uci.cursor()
		local id = cursor:add("firewall", "rule")
		cursor:set("firewall", id, "gl_custom", "1")
		cursor:set("firewall", id, "name", args.name or "Custom Rule")
		cursor:set("firewall", id, "src", args.src or "lan")
		if args.dest then cursor:set("firewall", id, "dest", args.dest) end
		if args.proto then cursor:set("firewall", id, "proto", args.proto) end
		if args.dest_port then cursor:set("firewall", id, "dest_port", tostring(args.dest_port)) end
		cursor:set("firewall", id, "target", args.target)
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return { id = id }
	end,

	set_rule = function(args)
		if not args.id or not uci.cursor():get("firewall", args.id) then
			return { code = 1, message = "unknown id" }
		end
		local cursor = uci.cursor()
		if args.name then cursor:set("firewall", args.id, "name", args.name) end
		if args.src then cursor:set("firewall", args.id, "src", args.src) end
		if args.dest then cursor:set("firewall", args.id, "dest", args.dest) end
		if args.proto then cursor:set("firewall", args.id, "proto", args.proto) end
		if args.dest_port then cursor:set("firewall", args.id, "dest_port", tostring(args.dest_port)) end
		if args.target then cursor:set("firewall", args.id, "target", args.target) end
		if args.enabled ~= nil then cursor:set("firewall", args.id, "enabled", args.enabled and "1" or "0") end
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	remove_rule = function(args)
		if not args.id then
			return { code = 1, message = "missing id" }
		end
		local cursor = uci.cursor()
		cursor:delete("firewall", args.id)
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	-- {internals:[...], externals:[...]} - two flat arrays of zone name
	-- strings, both listing every zone. These back a rule's "from zone"
	-- vs "to zone" dropdowns rather than a real internal/external split.
	get_zone_list = function(args)
		local cursor = uci.cursor()
		local names = {}
		cursor:foreach("firewall", "zone", function(s)
			if s.name then table.insert(names, s.name) end
		end)
		return { internals = as_array(names), externals = as_array(names) }
	end,

	-- Zone/traffic ACL rules ("acl" here, distinct from this feed's
	-- separate admin-GUI acl.lua), backed by the same fw4 `config rule`
	-- mechanism as get_rule_list above but tagged differently so the two
	-- lists don't overlap.
	get_acl_zone_list = function(args)
		local cursor = uci.cursor()
		local names = {}
		cursor:foreach("firewall", "zone", function(s)
			if s.name then table.insert(names, s.name) end
		end)
		return { internals = as_array(names), externals = as_array(names) }
	end,

	-- Result is a bare array, not wrapped in {res:[...]} like this
	-- object's other list methods.
	get_acl_rule_list = function(args)
		local cursor = uci.cursor()
		local out = {}
		cursor:foreach("firewall", "rule", function(s)
			if s.gl_acl == "1" then
				table.insert(out, rule_to_table(s))
			end
		end)
		return as_array(out)
	end,

	add_acl_rule = function(args)
		if type(args.target) ~= "string" then
			return { code = 1, message = "missing target" }
		end
		local cursor = uci.cursor()
		local id = cursor:add("firewall", "rule")
		cursor:set("firewall", id, "gl_acl", "1")
		cursor:set("firewall", id, "name", args.name or "ACL Rule")
		cursor:set("firewall", id, "src", args.src or "lan")
		if args.dest then cursor:set("firewall", id, "dest", args.dest) end
		if args.proto then cursor:set("firewall", id, "proto", args.proto) end
		cursor:set("firewall", id, "target", args.target)
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return { id = id }
	end,

	edit_acl_rule = function(args)
		if not args.id or not uci.cursor():get("firewall", args.id) then
			return { code = 1, message = "unknown id" }
		end
		local cursor = uci.cursor()
		if args.name then cursor:set("firewall", args.id, "name", args.name) end
		if args.src then cursor:set("firewall", args.id, "src", args.src) end
		if args.dest then cursor:set("firewall", args.id, "dest", args.dest) end
		if args.proto then cursor:set("firewall", args.id, "proto", args.proto) end
		if args.target then cursor:set("firewall", args.id, "target", args.target) end
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	delete_acl_rule = function(args)
		if not args.id then
			return { code = 1, message = "missing id" }
		end
		local cursor = uci.cursor()
		cursor:delete("firewall", args.id)
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	-- Same caveat as order_port_forward above.
	order_acl_rule = function(args)
		return { code = 1, message = "reordering not yet implemented" }
	end,
}
