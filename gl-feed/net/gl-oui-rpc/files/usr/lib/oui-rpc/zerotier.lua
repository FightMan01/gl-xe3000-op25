-- GL SDK4 ZeroTier page adapter backed by OpenWrt's upstream ZeroTier
-- package.  The GL page manages one network at a time.

local cjson = require "cjson"
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

local function first_network(cursor)
	local section
	cursor:foreach("zerotier", "network", function(s)
		if not section then section = s[".name"] end
	end)
	return section
end

local function bool_value(cursor, option)
	return cursor:get("zerotier", "global", option) == "1"
end

-- uci.cursor() only has add()/set(), no section() - these used to crash
-- the moment ZeroTier was actually enabled or a network id was set.
local function new_section(cursor, config, section_type, name, values)
	cursor:set(config, name, section_type)
	for option, value in pairs(values) do
		cursor:set(config, name, option, value)
	end
	return name
end

local function network_state()
	local raw = read_command("/usr/bin/zerotier-cli -j listnetworks")
	if not raw then return nil end
	local ok, value = pcall(cjson.decode, raw)
	if not ok or type(value) ~= "table" then return nil end
	return value[1]
end

local function configure_firewall(cursor, enabled, lan_enabled, wan_enabled)
	for _, section in ipairs({
		"gl_zerotier", "gl_zerotier_to_lan", "gl_zerotier_to_wan",
	}) do
		cursor:delete("firewall", section)
	end
	if enabled then
		new_section(cursor, "firewall", "zone", "gl_zerotier", {
			name = "zerotier",
			input = "ACCEPT",
			output = "ACCEPT",
			forward = "ACCEPT",
			device = "zt+",
			masq = wan_enabled and "1" or "0",
		})
		if lan_enabled then
			new_section(cursor, "firewall", "forwarding", "gl_zerotier_to_lan",
				{ src = "zerotier", dest = "lan" })
		end
		if wan_enabled then
			new_section(cursor, "firewall", "forwarding", "gl_zerotier_to_wan",
				{ src = "zerotier", dest = "wan" })
		end
	end
	cursor:commit("firewall")
	command_ok("/etc/init.d/firewall reload")
end

local function interface_ipv4(interface)
	if not interface or interface == "" then return "" end
	local output = read_command("ip -4 -o addr show dev " ..
		"'" .. interface:gsub("'", "'\\''") .. "'")
	return (output or ""):match("inet%s+(%d+%.%d+%.%d+%.%d+)/") or ""
end

local function logical_prefix(interface)
	local raw = read_command("/bin/ubus call network.interface." .. interface .. " status")
	if not raw then return "" end
	local ok, status = pcall(cjson.decode, raw)
	if not ok or type(status) ~= "table" then return "" end
	local addresses = status["ipv4-address"]
	if type(addresses) ~= "table" then return "" end
	for _, item in ipairs(addresses) do
		if type(item) == "table" and item.address and item.mask then
			return tostring(item.address) .. "/" .. tostring(item.mask)
		end
	end
	return ""
end

local function first_prefix(...)
	for _, interface in ipairs({...}) do
		local prefix = logical_prefix(interface)
		if prefix ~= "" then return prefix end
	end
	return ""
end

return {
	get_config = function()
		local cursor = uci.cursor()
		local section = first_network(cursor)
		return {
			id = section and (cursor:get("zerotier", section, "id") or "") or "",
			enabled = cursor:get("zerotier", "global", "enabled") == "1",
			lan_enabled = bool_value(cursor, "gl_lan_enabled"),
			wan_enabled = bool_value(cursor, "gl_wan_enabled"),
		}
	end,

	get_status = function()
		local cursor = uci.cursor()
		local state = network_state()
		if not state then
			return {
				status = cursor:get("zerotier", "global", "enabled") == "1" and 2 or 1,
			}
		end

		local status = tostring(state.status or ""):upper()
		local assigned = state.assignedAddresses
		local address = ""
		if type(assigned) == "table" then
			for _, value in ipairs(assigned) do
				if type(value) == "string" and value:match("^%d+%.") then
					address = value:match("^([^/]+)") or ""
					break
				end
			end
		end

		-- The stock GL page treats 0 as authorized/online, 1 as waiting
		-- for authorization and 2 as an unknown/not-found network.
		local code = 2
		if status == "OK" then code = 0
		elseif status == "ACCESS_DENIED" or status == "REQUESTING_CONFIGURATION" then
			code = 1
		end
		return {
			status = code,
			zerotier_ip = address ~= "" and address or
				interface_ipv4(state.portDeviceName),
			lan_ip = first_prefix("lan"),
			wan_ip = first_prefix("wan_4", "wan"),
			secondwan_ip = first_prefix("wanb_4", "wanb"),
			usbwan_ip = first_prefix("tethering_4", "tethering"),
			wwan_ip = first_prefix("repeater_4", "repeater"),
		}
	end,

	set_config = function(args)
		args = args or {}
		if type(args.enabled) ~= "boolean" then
			return { err_code = 1, err_msg = "enabled must be boolean" }
		end
		if args.enabled and
		   (type(args.id) ~= "string" or not args.id:match("^[a-fA-F0-9]{16}$")) then
			return { err_code = 1, err_msg = "invalid ZeroTier network ID" }
		end

		local cursor = uci.cursor()
		local section = first_network(cursor)
		if args.enabled then
			if not section then
				section = new_section(cursor, "zerotier", "network", "gl_network", {})
			end
			cursor:set("zerotier", section, "id", args.id:lower())
			cursor:set("zerotier", section, "allow_managed", "1")
			cursor:set("zerotier", section, "allow_global", "0")
			cursor:set("zerotier", section, "allow_default", "0")
			cursor:set("zerotier", section, "allow_dns", "0")
			cursor:set("zerotier", "global", "enabled", "1")
			cursor:set("zerotier", "global", "gl_lan_enabled",
				args.lan_enabled and "1" or "0")
			cursor:set("zerotier", "global", "gl_wan_enabled",
				args.wan_enabled and "1" or "0")
		else
			cursor:set("zerotier", "global", "enabled", "0")
		end
		cursor:commit("zerotier")

		configure_firewall(cursor, args.enabled,
			args.enabled and args.lan_enabled == true,
			args.enabled and args.wan_enabled == true)
		if args.enabled then
			command_ok("/etc/init.d/zerotier enable")
			command_ok("/etc/init.d/zerotier restart")
		else
			command_ok("/etc/init.d/zerotier stop")
			command_ok("/etc/init.d/zerotier disable")
		end
		return {}
	end,
}
