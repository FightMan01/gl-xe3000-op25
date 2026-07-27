-- Client allowlist/blocklist backend used by gl-sdk4-ui-clients.

local uci = require "uci"
local cjson = require "cjson"

local SECTION = "black_white_list"
local RULE_PREFIX = "GL-UI Access "

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local function list(cursor, option)
	local value = cursor:get("gl-oui-rpc", SECTION, option) or {}
	if type(value) == "string" then value = { value } end
	local out, seen = {}, {}
	for _, mac in ipairs(value) do
		mac = tostring(mac):upper()
		if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and not seen[mac] then
			seen[mac] = true
			table.insert(out, mac)
		end
	end
	return out
end

local function add_rule(cursor, suffix, mac, dest, target)
	local id = cursor:add("firewall", "rule")
	cursor:set("firewall", id, "name", RULE_PREFIX .. suffix)
	cursor:set("firewall", id, "src", "lan")
	if mac then cursor:set("firewall", id, "src_mac", mac) end
	if dest then cursor:set("firewall", id, "dest", dest) end
	cursor:set("firewall", id, "target", target)
end

local function apply_firewall(cursor)
	cursor:foreach("firewall", "rule", function(s)
		if type(s.name) == "string" and s.name:sub(1, #RULE_PREFIX) == RULE_PREFIX then
			cursor:delete("firewall", s[".name"])
		end
	end)

	local mode = cursor:get("gl-oui-rpc", SECTION, "mode") or "black"
	local macs = list(cursor, mode == "white" and "white_mac" or "black_mac")
	if mode == "white" then
		for i, mac in ipairs(macs) do
			add_rule(cursor, "allow input " .. i, mac, nil, "ACCEPT")
			add_rule(cursor, "allow forward " .. i, mac, "wan", "ACCEPT")
		end
		add_rule(cursor, "reject other input", nil, nil, "REJECT")
		add_rule(cursor, "reject other forward", nil, "wan", "REJECT")
	else
		for i, mac in ipairs(macs) do
			add_rule(cursor, "block input " .. i, mac, nil, "REJECT")
			add_rule(cursor, "block forward " .. i, mac, "wan", "REJECT")
		end
	end
	cursor:commit("firewall")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
end

local function save(cursor, mode, macs)
	cursor:set("gl-oui-rpc", SECTION, SECTION)
	cursor:set("gl-oui-rpc", SECTION, "mode", mode)
	local option = mode == "white" and "white_mac" or "black_mac"
	if #macs > 0 then
		-- libuci-lua's cursor does not provide add_list(); assigning a
		-- Lua array is the supported way to persist a UCI list.
		cursor:set("gl-oui-rpc", SECTION, option, macs)
	else
		cursor:delete("gl-oui-rpc", SECTION, option)
	end
	cursor:commit("gl-oui-rpc")
	apply_firewall(cursor)
end

return {
	get_config = function(args)
		local cursor = uci.cursor()
		return {
			mode = cursor:get("gl-oui-rpc", SECTION, "mode") or "black",
			black_mac = as_array(list(cursor, "black_mac")),
			white_mac = as_array(list(cursor, "white_mac")),
		}
	end,

	set_config = function(args)
		if args.mode ~= "black" and args.mode ~= "white" then
			return { code = 1, message = "invalid mode" }
		end
		local macs = type(args.mac) == "table" and args.mac or {}
		local cursor = uci.cursor()
		save(cursor, args.mode, macs)
		return {}
	end,

	set_single_mac = function(args)
		if args.mode ~= "black" and args.mode ~= "white" then
			return { code = 1, message = "invalid mode" }
		end
		if type(args.mac) ~= "string" then
			return { code = 1, message = "missing mac" }
		end
		local cursor = uci.cursor()
		local macs = list(cursor, args.mode == "white" and "white_mac" or "black_mac")
		local wanted = args.mac:upper()
		local out = {}
		for _, mac in ipairs(macs) do
			if mac ~= wanted then table.insert(out, mac) end
		end
		if args.operate == "add" then table.insert(out, wanted) end
		save(cursor, args.mode, out)
		return {}
	end,
}
