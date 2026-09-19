-- "kmwan" RPC object: multi-WAN failover management. Object/method names
-- match the stock GL.iNet UI (get_status, get_config, set_config,
-- set_interface, get_sensitivity, set_sensitivity), backed by mwan3
-- (etc/uci-defaults/94-gl-oui-kmwan seeds it) instead of GL's closed
-- kmwan kernel module.
--
-- The GL frontend's contract (read from the shipped multiwan bundle) is:
--
--   get_config -> { mode, interfaces: [{interface, enabled, metric, weight,
--                    enable_check, track_method, track_mode, track_proto,
--                    enable_ssl, track_ipv4[], track_ipv6[]}] }
--   set_interface { interface, enable_check, track_proto, track_method,
--                    track_mode, enable_ssl, track_ipv4[], track_ipv6[] }
--   set_config   { mode, interfaces: [{interface, metric} | {interface, weight}] }
--   get_sensitivity -> { sensitivity: { level, val } }
--   set_sensitivity { sensitivity: { level, val } }
--
-- track_mode: 0 = low data, 1 = normal, 2 = strict (frontend's trackModes).
-- level:      "low" | "medium" | "high" | "custom"; val is the custom track
--             interval in seconds (frontend slider range 0.5 - 90).
--
-- This port keeps the GL-level tracking fields on the mwan3 interface
-- section under a `kmwan_` prefix (mwan3 ignores unknown options) and
-- translates them onto mwan3's own knobs:
--
--   enable_check=false  -> drop track_ip, so mwan3 marks the interface
--                          online whenever the underlying network interface
--                          is up (the UI's "physical state monitor"). The
--                          wanted IP list is still stored under
--                          kmwan_track_ipv4/6 so re-enabling restores it.
--   track_mode          -> scales the sensitivity interval and picks the
--                          up/down thresholds (low data checks rarely and is
--                          forgiving, strict checks often and is quick to
--                          flip). mwan3 has no event-driven mode, so low
--                          data is approximated by a long interval.

local uci = require "uci"
local cjson = require "cjson"
local ubus = require "ubus"

local RPC_CONFIG = "gl-oui-rpc"
local RPC_SECTION = "kmwan"

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
	low = 30,
	medium = 10,
	high = 3,
}

-- multiplier applied to the sensitivity interval, minimum interval, and the
-- up/down consecutive-check thresholds.
local TRACK_MODES = {
	[0] = { multiplier = 6, min_interval = 60, down = 5, up = 5 }, -- low data
	[1] = { multiplier = 1, min_interval = 1, down = 3, up = 3 }, -- normal
	[2] = { multiplier = 0.5, min_interval = 1, down = 2, up = 2 }, -- strict
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

-- os.execute (not io.popen) so the backgrounded reload doesn't leave the
-- shell's stdout pipe open and spew "Broken pipe" into the log.
local function restart_mwan3()
	os.execute("(flock -w 10 9; /etc/init.d/mwan3 restart) 9>/var/run/gl-net-reconfig.lock >/dev/null 2>&1 &")
end

local function as_list(value)
	if type(value) == "table" then
		local out = {}
		for _, v in ipairs(value) do
			v = tostring(v)
			if v ~= "" then out[#out + 1] = v end
		end
		return out
	elseif type(value) == "string" and value ~= "" then
		return { value }
	end
	return {}
end

local function set_list(cursor, config, section, option, list)
	if #list == 0 then
		cursor:delete(config, section, option)
	else
		cursor:set(config, section, option, list)
	end
end

local function filter_ips(value, want_ipv6)
	local out = {}
	if type(value) ~= "table" then return out end
	for _, ip in ipairs(value) do
		if type(ip) == "string" and ip ~= "" then
			local is_v6 = ip:find(":") ~= nil
			if is_v6 == want_ipv6 then out[#out + 1] = ip end
		end
	end
	return out
end

local function ensure_rpc_section(cursor)
	if not cursor:get(RPC_CONFIG, RPC_SECTION) then
		cursor:set(RPC_CONFIG, RPC_SECTION, RPC_SECTION)
	end
end

-- Effective base interval (seconds) from the global sensitivity setting.
local function sensitivity_base(cursor)
	local level = cursor:get(RPC_CONFIG, RPC_SECTION, "level") or "medium"
	if level == "custom" then
		return tonumber((cursor:get(RPC_CONFIG, RPC_SECTION, "sensitivity"))) or 10
	end
	return SENSITIVITY_PRESETS[level] or SENSITIVITY_PRESETS.medium
end

-- The GL-level tracking view of one member, with defaults for configs that
-- predate these options (fresh installs, or a config written by an older
-- build): default to Normal tracking with the mwan3 track_ip list.
local function member_tracking(cursor, m)
	local enable = cursor:get("mwan3", m.real, "kmwan_enable_check")
	local track_ipv4 = as_list(cursor:get("mwan3", m.real, "kmwan_track_ipv4"))
	local track_ipv6 = as_list(cursor:get("mwan3", m.real, "kmwan_track_ipv6"))
	if #track_ipv4 == 0 then
		local existing = as_list(cursor:get("mwan3", m.real, "track_ip"))
		track_ipv4 = #existing > 0 and existing or { "1.1.1.1", "8.8.8.8" }
	end
	return {
		enable_check = (enable == nil or enable == "") and true or (enable == "1"),
		track_mode = tonumber((cursor:get("mwan3", m.real, "kmwan_track_mode"))) or 1,
		track_proto = tonumber((cursor:get("mwan3", m.real, "kmwan_track_proto"))) or 0,
		track_method = tonumber((cursor:get("mwan3", m.real, "kmwan_track_method"))) or 0,
		enable_ssl = cursor:get("mwan3", m.real, "kmwan_enable_ssl") == "1",
		track_ipv4 = track_ipv4,
		track_ipv6 = track_ipv6,
	}
end

-- Push one member's GL-level tracking view onto mwan3.
local function apply_member_tracking(cursor, m)
	local t = member_tracking(cursor, m)

	local active = {}
	if t.enable_check then
		if t.track_proto == 0 or t.track_proto == 2 then
			for _, ip in ipairs(t.track_ipv4) do active[#active + 1] = ip end
		end
		if t.track_proto == 1 or t.track_proto == 2 then
			for _, ip in ipairs(t.track_ipv6) do active[#active + 1] = ip end
		end
	end

	cursor:set("mwan3", m.real, "family", (t.track_proto == 1) and "ipv6" or "ipv4")
	set_list(cursor, "mwan3", m.real, "track_ip", active)

	-- mwan3 only flushes conntrack on an interface transition if the
	-- interface has a flush_conntrack list containing that action. Without
	-- it, failover leaves every established flow bound to the old (dead)
	-- WAN forever. Keep it configured on every managed interface.
	cursor:set("mwan3", m.real, "flush_conntrack", { "ifup", "ifdown" })

	if not t.enable_check then
		return
	end

	cursor:set("mwan3", m.real, "track_method", "ping")
	local base = sensitivity_base(cursor)
	local mode = TRACK_MODES[t.track_mode] or TRACK_MODES[1]
	local interval = math.max(mode.min_interval,
		math.floor(base * mode.multiplier + 0.5))
	cursor:set("mwan3", m.real, "interval", tostring(interval))
	cursor:set("mwan3", m.real, "down", tostring(mode.down))
	cursor:set("mwan3", m.real, "up", tostring(mode.up))
	if not cursor:get("mwan3", m.real, "count") then
		cursor:set("mwan3", m.real, "count", "1")
	end
	if not cursor:get("mwan3", m.real, "timeout") then
		cursor:set("mwan3", m.real, "timeout", "2")
	end
	if not cursor:get("mwan3", m.real, "reliability") then
		cursor:set("mwan3", m.real, "reliability", "1")
	end
end

local function persist_member(cursor, m, args)
	local iface = m.real
	if args.enable_check ~= nil then
		cursor:set("mwan3", iface, "kmwan_enable_check", args.enable_check and "1" or "0")
	end
	if args.track_mode ~= nil then
		local mode = tonumber(args.track_mode)
		if mode and TRACK_MODES[mode] then
			cursor:set("mwan3", iface, "kmwan_track_mode", tostring(mode))
		end
	end
	if args.track_proto ~= nil then
		local proto = tonumber(args.track_proto)
		if proto == 0 or proto == 1 or proto == 2 then
			cursor:set("mwan3", iface, "kmwan_track_proto", tostring(proto))
		end
	end
	if args.track_method ~= nil then
		local method = tonumber(args.track_method)
		if method then cursor:set("mwan3", iface, "kmwan_track_method", tostring(method)) end
	end
	if args.enable_ssl ~= nil then
		cursor:set("mwan3", iface, "kmwan_enable_ssl", args.enable_ssl and "1" or "0")
	end
	if type(args.track_ipv4) == "table" then
		set_list(cursor, "mwan3", iface, "kmwan_track_ipv4", filter_ips(args.track_ipv4, false))
	end
	if type(args.track_ipv6) == "table" then
		set_list(cursor, "mwan3", iface, "kmwan_track_ipv6", filter_ips(args.track_ipv6, true))
	end
end

return {
	get_config = function(args)
		local cursor = uci.cursor()
		local interfaces = {}
		for _, m in ipairs(MEMBERS) do
			local t = member_tracking(cursor, m)
			table.insert(interfaces, {
				interface = m.frontend,
				enabled = cursor:get("mwan3", m.real, "enabled") ~= "0",
				metric = tonumber((cursor:get("mwan3", m.member, "metric"))) or 10,
				weight = tonumber((cursor:get("mwan3", m.member, "weight"))) or 1,
				enable_check = t.enable_check,
				enable_ssl = t.enable_ssl,
				track_method = t.track_method,
				track_mode = t.track_mode,
				track_proto = t.track_proto,
				track_ipv4 = as_array(t.track_ipv4),
				track_ipv6 = as_array(t.track_ipv6),
			})
		end
		local mode = tonumber((cursor:get(RPC_CONFIG, RPC_SECTION, "mode"))) or 0
		return {
			interfaces = as_array(interfaces),
			mode = mode,
		}
	end,

	set_config = function(args)
		if type(args.interfaces) ~= "table" then
			return { code = 1, message = "missing interfaces" }
		end
		local mode = tonumber(args.mode) or 0
		local cursor = uci.cursor()
		ensure_rpc_section(cursor)
		cursor:set(RPC_CONFIG, RPC_SECTION, "mode", tostring(mode))
		for _, entry in ipairs(args.interfaces) do
			local m = find_member(entry.interface)
			if m then
				if mode == 1 then
					-- Load balance: one shared metric tier, weights split
					-- traffic between the members.
					cursor:set("mwan3", m.member, "metric", "1")
					if entry.weight and tonumber(entry.weight) then
						cursor:set("mwan3", m.member, "weight",
							tostring(math.floor(tonumber(entry.weight))))
					end
				else
					-- Failover: metric is the priority tier.
					if entry.metric and tonumber(entry.metric) then
						cursor:set("mwan3", m.member, "metric",
							tostring(math.floor(tonumber(entry.metric))))
					end
					cursor:set("mwan3", m.member, "weight", "1")
				end
				if entry.enabled ~= nil then
					cursor:set("mwan3", m.real, "enabled", entry.enabled and "1" or "0")
				end
			end
		end
		cursor:commit(RPC_CONFIG)
		cursor:commit("mwan3")
		restart_mwan3()
		return {}
	end,

	set_interface = function(args)
		local m = find_member(args.interface)
		if not m then
			return { code = 1, message = "unknown interface" }
		end
		local cursor = uci.cursor()
		persist_member(cursor, m, args)
		apply_member_tracking(cursor, m)
		if args.metric and tonumber(args.metric) then
			cursor:set("mwan3", m.member, "metric", tostring(math.floor(tonumber(args.metric))))
		end
		if args.weight and tonumber(args.weight) then
			cursor:set("mwan3", m.member, "weight", tostring(math.floor(tonumber(args.weight))))
		end
		if args.enabled ~= nil then
			cursor:set("mwan3", m.real, "enabled", args.enabled and "1" or "0")
		end
		cursor:commit("mwan3")
		restart_mwan3()
		return {}
	end,

	-- {sensitivity:{val,level}} - val is the custom track interval in seconds
	-- (slider range 0.5-90), level is low/medium/high/custom.
	get_sensitivity = function(args)
		local cursor = uci.cursor()
		local level = cursor:get(RPC_CONFIG, RPC_SECTION, "level") or "medium"
		local val
		if level == "custom" then
			val = tonumber((cursor:get(RPC_CONFIG, RPC_SECTION, "sensitivity"))) or 10
		else
			val = SENSITIVITY_PRESETS[level] or SENSITIVITY_PRESETS.medium
		end
		return { sensitivity = { val = val, level = level } }
	end,

	set_sensitivity = function(args)
		local sens = args and args.sensitivity
		if type(sens) ~= "table" then
			return { code = 1, message = "missing sensitivity" }
		end
		local level = sens.level
		if level ~= "low" and level ~= "medium" and level ~= "high" and level ~= "custom" then
			return { code = 1, message = "invalid sensitivity level" }
		end
		local cursor = uci.cursor()
		ensure_rpc_section(cursor)
		cursor:set(RPC_CONFIG, RPC_SECTION, "level", level)
		if level == "custom" then
			local val = tonumber(sens.val)
			if not val or val < 0.5 or val > 90 then
				return { code = 1, message = "interval must be between 0.5 and 90 seconds" }
			end
			cursor:set(RPC_CONFIG, RPC_SECTION, "sensitivity", tostring(val))
		end
		cursor:commit(RPC_CONFIG)
		for _, m in ipairs(MEMBERS) do apply_member_tracking(cursor, m) end
		cursor:commit("mwan3")
		restart_mwan3()
		return {}
	end,

	-- interfaces is an array of {interface,status_v4,status_v6}.
	-- Frontend enum is 0=online, 1=offline, 2=error.
	get_status = function(args)
		local conn = ubus.connect()
		local mwan_status = conn and conn:call("mwan3", "status", {}) or {}
		local cursor = uci.cursor()
		local interfaces = {}
		for _, m in ipairs(MEMBERS) do
			local value
			local t = member_tracking(cursor, m)
			if t.enable_check then
				local info = mwan_status.interfaces and mwan_status.interfaces[m.real] or {}
				local state = info.status
				value = state == "online" and 0
					or (state == "offline" or state == "disabled"
						or state == "disconnecting") and 1 or 2
			else
				-- Not tracked: online whenever the network interface is up.
				local up = false
				if conn then
					local status = conn:call("network.interface." .. m.real, "status", {})
					up = type(status) == "table" and status.up == true
				end
				value = up and 0 or 1
			end
			table.insert(interfaces, {
				interface = m.frontend,
				status_v4 = value,
				status_v6 = value,
			})
		end
		if conn then conn:close() end
		return { interfaces = as_array(interfaces) }
	end,
}
