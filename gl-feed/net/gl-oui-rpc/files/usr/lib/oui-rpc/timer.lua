-- "timer" RPC object: scheduled on/off actions. Covers get_reboot/
-- set_reboot, get_wifi/set_wifi, get_led/set_led, get_screen/set_screen -
-- all under this one "timer" object rather than per-feature objects.
--
-- The XE3000 has no OLED screen, but the shared "Timed Task" view calls
-- get_screen/set_screen unconditionally, so those are safe no-op stubs
-- (return disabled/empty) instead of leaving the page to break on an
-- unhandled call.
--
-- Backed by cron, one tagged crontab line pair per feature, rewritten
-- atomically on every set_* call.

local uci = require "uci"
local cjson = require "cjson"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local CRON_FILE = "/etc/crontabs/root"

local function parse_hhmm(s)
	if type(s) ~= "string" then return nil, nil end
	local h, m = s:match("^(%d%d?):(%d%d)$")
	h, m = tonumber(h), tonumber(m)
	if not h or not m or h > 23 or m > 59 then return nil, nil end
	return h, m
end

local function rewrite_cron_tag(tag, new_lines)
	local escaped_tag = "# " .. tag:gsub("%p", "%%%1") .. "$"
	local lines = {}
	local f = io.open(CRON_FILE, "r")
	if f then
		for line in f:lines() do
			if not line:match(escaped_tag) then
				table.insert(lines, line)
			end
		end
		f:close()
	end
	for _, line in ipairs(new_lines or {}) do
		table.insert(lines, line)
	end
	local out = io.open(CRON_FILE, "w")
	if not out then return false end
	for _, line in ipairs(lines) do
		out:write(line, "\n")
	end
	out:close()
	os.execute("/etc/init.d/cron restart >/dev/null 2>&1")
	return true
end

-- Schedule shape: {enable, week:[0-6,...], turnon_hour:"HH",
-- turnon_min:"MM", turnoff_hour:"HH", turnoff_min:"MM"}. week is
-- 0=Sunday..6=Saturday, default all 7 days. cmd_up/cmd_down are fixed
-- strings owned by this file, never derived from RPC args.
local function hhmm_string(h, m)
	if not h then return nil, nil end
	return string.format("%02d", h), string.format("%02d", m)
end

local function parse_week(week)
	if type(week) ~= "table" then return { "*" }, { 0, 1, 2, 3, 4, 5, 6 } end
	local dow_set, dow_nums = {}, {}
	for _, d in ipairs(week) do
		local n = tonumber(d)
		if n and n >= 0 and n <= 6 then
			table.insert(dow_set, tostring(math.floor(n)))
			table.insert(dow_nums, math.floor(n))
		end
	end
	if #dow_set == 0 then return { "*" }, { 0, 1, 2, 3, 4, 5, 6 } end
	return dow_set, dow_nums
end

local function get_onoff_schedule(section)
	local cursor = uci.cursor()
	-- Double parens around every cursor:get() call: :get() can return a
	-- second value on a miss, and an unparenthesized call splices both
	-- into tonumber()'s argument list, where the 2nd arg must be a
	-- numeric base. The extra parens truncate to one return value.
	local turnon_h, turnon_m = hhmm_string(tonumber((cursor:get("gl-oui-rpc", section, "turnon_hour"))),
		tonumber((cursor:get("gl-oui-rpc", section, "turnon_min"))) or 0)
	local turnoff_h, turnoff_m = hhmm_string(tonumber((cursor:get("gl-oui-rpc", section, "turnoff_hour"))),
		tonumber((cursor:get("gl-oui-rpc", section, "turnoff_min"))) or 0)
	local week_raw = cursor:get("gl-oui-rpc", section, "week")
	local week = {}
	if type(week_raw) == "table" then
		for _, d in ipairs(week_raw) do table.insert(week, tonumber(d)) end
	else
		week = { 0, 1, 2, 3, 4, 5, 6 }
	end
	return {
		enable = cursor:get("gl-oui-rpc", section, "enabled") == "1",
		week = as_array(week),
		turnon_hour = turnon_h or "07",
		turnon_min = turnon_m or "00",
		turnoff_hour = turnoff_h or "22",
		turnoff_min = turnoff_m or "00",
	}
end

local function set_onoff_schedule(section, tag, cmd_up, cmd_down, args)
	local cursor = uci.cursor()
	if not cursor:get("gl-oui-rpc", section) then
		cursor:set("gl-oui-rpc", section, section)
	end
	local enabled = args.enable and true or false
	cursor:set("gl-oui-rpc", section, "enabled", enabled and "1" or "0")

	local on_time = args.turnon_hour and (args.turnon_hour .. ":" .. (args.turnon_min or "00"))
	local off_time = args.turnoff_hour and (args.turnoff_hour .. ":" .. (args.turnoff_min or "00"))
	local on_h, on_m = parse_hhmm(on_time)
	local off_h, off_m = parse_hhmm(off_time)
	if enabled and not (on_h and off_h) then
		return { code = 1, message = "turnon_hour/turnon_min/turnoff_hour/turnoff_min required" }
	end
	if args.turnon_hour then cursor:set("gl-oui-rpc", section, "turnon_hour", tostring(on_h)) end
	if args.turnon_min then cursor:set("gl-oui-rpc", section, "turnon_min", tostring(on_m)) end
	if args.turnoff_hour then cursor:set("gl-oui-rpc", section, "turnoff_hour", tostring(off_h)) end
	if args.turnoff_min then cursor:set("gl-oui-rpc", section, "turnoff_min", tostring(off_m)) end

	local dow_set, dow_nums = parse_week(args.week)
	cursor:set("gl-oui-rpc", section, "week", dow_nums)
	cursor:commit("gl-oui-rpc")

	local new_lines = nil
	if enabled and on_h and off_h then
		local dow = table.concat(dow_set, ",")
		new_lines = {
			string.format("%d %d * * %s %s # %s", on_m, on_h, dow, cmd_up, tag),
			string.format("%d %d * * %s %s # %s", off_m, off_h, dow, cmd_down, tag),
		}
	end
	rewrite_cron_tag(tag, new_lines)
	return {}
end

return {
	-- Shape: {wifi:[{band,enable,func,guest,week,turnon_hour,turnon_min,
	-- turnoff_hour,turnoff_min}, ...], wifi_func_2g, wifi_func_5g,
	-- wifi_func_6g, wifi_func_mld} - a per-band array. Only 2G/5G entries
	-- are returned since this hardware has no 6G radio or MLO/MLD
	-- interface. func is always "turn_onoff" (the only schedule action
	-- implemented); guest is always 0 since there's no separate
	-- guest-network schedule yet.
	--
	-- TODO: real firmware also supports a guest:1 variant per band (a
	-- separate schedule for the guest SSID) and a "power_switch" func
	-- type (switch_hour/switch_min/switch_power/restore_hour/restore_min/
	-- restore_power - a scheduled TX-power step-down). Neither is
	-- implemented; requires a guest wifi-iface to exist first.
	get_wifi = function(args)
		local w2g = get_onoff_schedule("wifi_schedule_2g")
		local w5g = get_onoff_schedule("wifi_schedule_5g")
		w2g.band = "2G"
		w2g.func = "turn_onoff"
		w2g.guest = 0
		w5g.band = "5G"
		w5g.func = "turn_onoff"
		w5g.guest = 0
		return {
			wifi = as_array({ w2g, w5g }),
			wifi_func_2g = "turn_onoff",
			wifi_func_5g = "turn_onoff",
		}
	end,

	-- args: {band:"2G"|"5G", ...same fields as get_wifi's per-entry shape}.
	set_wifi = function(args)
		if args.band ~= "2G" and args.band ~= "5G" then
			return { code = 1, message = "missing/invalid band (2G or 5G)" }
		end
		local section = (args.band == "5G") and "wifi_schedule_5g" or "wifi_schedule_2g"
		local tag = (args.band == "5G") and "gl-wifi-schedule-5g" or "gl-wifi-schedule-2g"
		local radio = (args.band == "5G") and "radio1" or "radio0"
		return set_onoff_schedule(section, tag, "wifi up " .. radio, "wifi down " .. radio, args)
	end,

	-- Fields: {enable, week, hour, min} - a single time-of-day, not a
	-- turnon/turnoff pair, since a reboot is a one-shot daily action.
	get_reboot = function(args)
		local cursor = uci.cursor()
		local hour = cursor:get("gl-oui-rpc", "reboot_schedule", "hour")
		local min = cursor:get("gl-oui-rpc", "reboot_schedule", "min")
		local week_raw = cursor:get("gl-oui-rpc", "reboot_schedule", "week")
		local week = {}
		if type(week_raw) == "table" then
			for _, d in ipairs(week_raw) do table.insert(week, tonumber(d)) end
		else
			week = { 0, 1, 2, 3, 4, 5, 6 }
		end
		return {
			enable = cursor:get("gl-oui-rpc", "reboot_schedule", "enabled") == "1",
			week = as_array(week),
			hour = hour or "03",
			min = min or "00",
		}
	end,

	set_reboot = function(args)
		local cursor = uci.cursor()
		if not cursor:get("gl-oui-rpc", "reboot_schedule") then
			cursor:set("gl-oui-rpc", "reboot_schedule", "reboot_schedule")
		end

		local enabled = args.enable and true or false
		cursor:set("gl-oui-rpc", "reboot_schedule", "enabled", enabled and "1" or "0")

		local dow_set, dow_nums = parse_week(args.week)
		cursor:set("gl-oui-rpc", "reboot_schedule", "week", dow_nums)

		local time = args.hour and (args.hour .. ":" .. (args.min or "00"))
		local h, m = parse_hhmm(time)
		if enabled and not h then
			return { code = 1, message = "hour/min required (as HH/MM strings)" }
		end
		if args.hour then cursor:set("gl-oui-rpc", "reboot_schedule", "hour", tostring(h)) end
		if args.min then cursor:set("gl-oui-rpc", "reboot_schedule", "min", tostring(m)) end
		cursor:commit("gl-oui-rpc")

		local new_lines = nil
		if enabled and h then
			new_lines = {
				string.format("%d %d * * %s reboot # %s", m, h, table.concat(dow_set, ","), "gl-reboot-schedule"),
			}
		end
		rewrite_cron_tag("gl-reboot-schedule", new_lines)
		return {}
	end,

	get_led = function(args)
		return get_onoff_schedule("led_schedule")
	end,

	set_led = function(args)
		-- "up"/"down" here mean the LED subsystem, not the network -
		-- reuses /etc/init.d/led's own enable/stop verbs.
		return set_onoff_schedule("led_schedule", "gl-led-schedule",
			"/etc/init.d/led start", "/etc/init.d/led stop", args)
	end,

	-- No OLED screen on this hardware - safe stub so the shared
	-- "Timed Task" view doesn't error, not a real schedule. Matches the
	-- same shape as get_led; `supported` is always false here.
	get_screen = function(args)
		local sched = get_onoff_schedule("screen_schedule")
		sched.supported = false
		return sched
	end,

	set_screen = function(args)
		return { code = 1, message = "no display on this device" }
	end,
}
