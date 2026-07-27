-- "kmwan" RPC object: multi-WAN failover management. Object/method names
-- match the stock GL.iNet UI (get_status, get_config, set_config,
-- set_interface, get_sensitivity, set_sensitivity), backed by mwan3
-- (etc/uci-defaults/94-gl-oui-kmwan seeds it) instead of GL's closed
-- kmwan kernel module.
--
-- get_config's response shape: `{ interfaces: [{interface, metric,
-- weight, ...}], mode }`.
--
-- set_sensitivity accepts a single 0-2 preset (relaxed/normal/aggressive)
-- mapped onto mwan3's ping interval/down/up thresholds, applied uniformly
-- to every tracked interface.

local uci = require "uci"
local cjson = require "cjson"
local ubus = require "ubus"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

-- Real mwan3/network interface name -> frontend-facing identifier.
-- umbim creates `wwan_4` as the actual IPv4 interface holding the address
-- and routes; the parent `wwan` protocol interface has no L3 addresses.
-- mwan3 must therefore track wwan_4 (tracking the parent produces empty
-- policy tables and rejects marked DNS/HTTP traffic). It is still exposed
-- to the frontend as "modem".
local MEMBERS = {
	{ real = "wan", member = "wan_m1_w1", frontend = "wan" },
	-- These are the identifiers used by the shipped Internet page:
	-- modem cards look up modem_<bus>, while the repeater card looks up
	-- wwan.  Returning the friendly names "modem"/"repeater" prevented
	-- interfaceConfig from reaching either card, so the stock
	-- "connected but no Internet" warning could never render.
	{ real = "wwan_4", member = "wwan4_m2_w1", frontend = "modem_mhi0" },
	{ real = "repeater", member = "repeater_m3_w1", frontend = "wwan" },
	{ real = "tethering", member = "tethering_m4_w1", frontend = "tethering" },
}

local SENSITIVITY_PRESETS = {
	[0] = { interval = 15, down = 5, up = 5 }, -- relaxed
	[1] = { interval = 10, down = 3, up = 3 }, -- normal (matches uci-defaults seed)
	[2] = { interval = 5, down = 2, up = 2 }, -- aggressive
}

local function find_member(frontend_name)
	for _, m in ipairs(MEMBERS) do
		if m.frontend == frontend_name then return m end
	end
	-- Accept identifiers emitted by earlier builds so an already-open UI
	-- can still save its Multi-WAN form during a rolling live update.
	if frontend_name == "modem" then return MEMBERS[2] end
	if frontend_name == "repeater" then return MEMBERS[3] end
	return nil
end

local function run(cmd)
	local f = io.popen(cmd .. " 2>&1")
	if not f then return "" end
	local out = f:read("*a") or ""
	f:close()
	return out
end

return {
	-- metric/weight default to sane values instead of vanishing from the
	-- response when unset in UCI (cjson drops a table key entirely when
	-- its value is nil).
	get_config = function(args)
		local cursor = uci.cursor()
		local interfaces = {}
		local metrics = {}
		for _, m in ipairs(MEMBERS) do
			local metric = tonumber((cursor:get("mwan3", m.member, "metric"))) or 10
			local weight = tonumber((cursor:get("mwan3", m.member, "weight"))) or 1
			metrics[metric] = (metrics[metric] or 0) + 1
			local track_ipv4 = cursor:get("mwan3", m.real, "track_ip")
			if type(track_ipv4) ~= "table" then track_ipv4 = { "1.1.1.1", "8.8.8.8" } end
			table.insert(interfaces, {
				interface = m.frontend,
				enabled = cursor:get("mwan3", m.real, "enabled") == "1",
				metric = metric,
				weight = weight,
				enable_check = true,
				enable_ssl = false,
				track_method = 0,
				track_mode = 0,
				track_proto = 0,
				track_ipv4 = as_array(track_ipv4),
				track_ipv6 = as_array({}),
			})
		end
		local distinct = 0
		for _ in pairs(metrics) do distinct = distinct + 1 end
		return {
			interfaces = as_array(interfaces),
			mode = (distinct <= 1) and 1 or 0, -- best-evidence: 0=failover, 1=balance
		}
	end,

	set_config = function(args)
		if type(args.interfaces) ~= "table" then
			return { code = 1, message = "missing interfaces" }
		end
		local cursor = uci.cursor()
		for _, entry in ipairs(args.interfaces) do
			local m = find_member(entry.interface)
			if m then
				if entry.metric then
					cursor:set("mwan3", m.member, "metric", tostring(math.floor(tonumber(entry.metric) or 1)))
				end
				if entry.weight then
					cursor:set("mwan3", m.member, "weight", tostring(math.floor(tonumber(entry.weight) or 1)))
				end
				if entry.enabled ~= nil then
					cursor:set("mwan3", m.real, "enabled", entry.enabled and "1" or "0")
				end
			end
		end
		cursor:commit("mwan3")
		os.execute("/etc/init.d/mwan3 restart >/dev/null 2>&1 &")
		return {}
	end,

	set_interface = function(args)
		local m = find_member(args.interface)
		if not m then
			return { code = 1, message = "unknown interface" }
		end
		local cursor = uci.cursor()
		if args.metric then
			cursor:set("mwan3", m.member, "metric", tostring(math.floor(tonumber(args.metric) or 1)))
		end
		if args.weight then
			cursor:set("mwan3", m.member, "weight", tostring(math.floor(tonumber(args.weight) or 1)))
		end
		if args.enabled ~= nil then
			cursor:set("mwan3", m.real, "enabled", args.enabled and "1" or "0")
		end
		cursor:commit("mwan3")
		os.execute("/etc/init.d/mwan3 restart >/dev/null 2>&1 &")
		return {}
	end,

	-- {sensitivity:{val,level}} - val is 0/1/2 (relaxed/normal/aggressive),
	-- level is the matching low/medium/high label.
	get_sensitivity = function(args)
		local cursor = uci.cursor()
		local val = tonumber((cursor:get("gl-oui-rpc", "kmwan", "sensitivity"))) or 1
		local LEVEL_NAMES = { [0] = "low", [1] = "medium", [2] = "high" }
		return {
			sensitivity = { val = val, level = LEVEL_NAMES[val] or "medium" },
		}
	end,

	set_sensitivity = function(args)
		local sens_arg = args.sensitivity
		if type(sens_arg) == "table" then sens_arg = sens_arg.val end
		local level = tonumber(sens_arg)
		local preset = level and SENSITIVITY_PRESETS[math.floor(level)]
		if not preset then
			return { code = 1, message = "sensitivity must be 0, 1, or 2" }
		end
		local cursor = uci.cursor()
		if not cursor:get("gl-oui-rpc", "kmwan") then
			cursor:set("gl-oui-rpc", "kmwan", "kmwan")
		end
		cursor:set("gl-oui-rpc", "kmwan", "sensitivity", tostring(math.floor(level)))
		cursor:commit("gl-oui-rpc")

		for _, m in ipairs(MEMBERS) do
			cursor:set("mwan3", m.real, "interval", tostring(preset.interval))
			cursor:set("mwan3", m.real, "down", tostring(preset.down))
			cursor:set("mwan3", m.real, "up", tostring(preset.up))
		end
		cursor:commit("mwan3")
		os.execute("/etc/init.d/mwan3 restart >/dev/null 2>&1 &")
		return {}
	end,

	-- interfaces is an array of {interface,status_v4,status_v6}.
	-- status_v4/status_v6 mirror the same overall per-interface state -
	-- mwan3 isn't tracked separately per address family here.
	get_status = function(args)
		local conn = ubus.connect()
		local mwan_status = conn and conn:call("mwan3", "status", {}) or {}
		if conn then conn:close() end
		local interfaces = {}
		for _, m in ipairs(MEMBERS) do
			local info = mwan_status.interfaces and mwan_status.interfaces[m.real] or {}
			local state = info.status
			-- Frontend enum is 0=online, 1=offline, 2=error (confirmed
			-- from interfaceItemStatus in the shipped Multi-WAN bundle).
			local value = state == "online" and 0
				or (state == "offline" or state == "disabled"
					or state == "disconnecting") and 1 or 2
			table.insert(interfaces, {
				interface = m.frontend,
				status_v4 = value,
				status_v6 = value,
			})
		end
		return { interfaces = as_array(interfaces) }
	end,
}
