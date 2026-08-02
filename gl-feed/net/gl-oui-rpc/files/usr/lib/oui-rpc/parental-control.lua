-- "parental-control" RPC object: per-profile ("group") client blocking on
-- a weekday/time schedule ("downtime"), backed by firewall4's native
-- weekdays/start_time/stop_time rule options - no packet inspection
-- needed for this part.
--
-- Real GL firmware's parental control also supports per-app/category
-- blocking (each group's app_list/category_list, fed by get_app_list's
-- catalog) - that needs the same proprietary DPI signature database this
-- port doesn't have access to (see dpi.lua's header for the fuller
-- explanation). Those fields are accepted and stored for API round-trip
-- fidelity but have no enforcement effect; get_app_list honestly returns
-- an empty catalog rather than fake app data.

local cjson = require "cjson"
local uci = require "uci"

local CONFIG = "gl_parentalcontrol"
local RULE_PREFIX = "GL-ParentalControl "

local WEEKDAY_NAMES = { "mon", "tue", "wed", "thu", "fri", "sat", "sun" }

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function is_mac(value)
	return type(value) == "string" and value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function is_time(value)
	if type(value) ~= "string" then return false end
	local hour, minute = value:match("^(%d%d):(%d%d)$")
	if not hour then return false end
	hour, minute = tonumber(hour), tonumber(minute)
	return hour >= 0 and hour <= 23 and minute >= 0 and minute <= 59
end

local function new_id()
	local pipe = io.popen("printf %s%s '" .. os.time() .. "' '" ..
		math.random(100000, 999999) .. "' | sha256sum | cut -c1-16 2>/dev/null")
	if not pipe then return tostring(os.time()) end
	local id = (pipe:read("*a") or ""):gsub("%s+$", "")
	pipe:close()
	return id ~= "" and id or tostring(os.time())
end

local function group_sections(cursor)
	local groups = {}
	cursor:foreach(CONFIG, "group", function(section)
		groups[#groups + 1] = section
	end)
	return groups
end

local function group_by_id(cursor, id)
	for _, group in ipairs(group_sections(cursor)) do
		if tostring(group.group_id or "") == tostring(id or "") then
			return group
		end
	end
	return nil
end

local function group_result(group)
	local schedules_ok, schedules = pcall(cjson.decode, group.schedules or "[]")
	return {
		group_id = group.group_id or "",
		name = group.name or "",
		macs = as_array(group.macs or {}),
		schedules_days = group.schedules_days or "everyday",
		schedules = as_array(schedules_ok and schedules or {}),
		app_list = as_array(group.app_list or {}),
		category_list = as_array(group.category_list or {}),
		blacklist = as_array(group.blacklist or {}),
	}
end

-- Validates and normalizes {week,enabled,begin,end} entries; week is
-- ISO-8601 (1=Monday..7=Sunday), matching the frontend's own default
-- "customize" sample order (7,1,2,3,4,5,6 = Sun then Mon..Sat).
local function normalize_schedules(raw)
	if type(raw) ~= "table" then return nil, "invalid schedules" end
	local out = {}
	for _, entry in ipairs(raw) do
		local week = tonumber(entry.week)
		if type(entry) ~= "table" or not week or week < 0 or week > 7
			or not is_time(entry.begin) or not is_time(entry["end"]) then
			return nil, "invalid schedule entry"
		end
		out[#out + 1] = {
			week = week,
			enabled = entry.enabled ~= false,
			["begin"] = entry.begin,
			["end"] = entry["end"],
		}
	end
	return out
end

local function write_group(cursor, section, args)
	if type(args.name) ~= "string" or args.name == "" or #args.name > 64 then
		return nil, "invalid group name"
	end
	local macs = {}
	if type(args.macs) == "table" then
		for _, mac in ipairs(args.macs) do
			if not is_mac(mac) then return nil, "invalid MAC address: " .. tostring(mac) end
			macs[#macs + 1] = mac:upper()
		end
	end
	local schedules, err = normalize_schedules(args.schedules or {})
	if not schedules then return nil, err end

	cursor:set(CONFIG, section, "name", args.name)
	if #macs > 0 then cursor:set(CONFIG, section, "macs", macs)
	else cursor:delete(CONFIG, section, "macs") end
	cursor:set(CONFIG, section, "schedules_days",
		args.schedules_days == "customize" and "customize" or "everyday")
	cursor:set(CONFIG, section, "schedules", cjson.encode(schedules))
	if args.app_list ~= nil then
		local list = {}
		for _, app in ipairs(type(args.app_list) == "table" and args.app_list or {}) do
			list[#list + 1] = tostring(app)
		end
		if #list > 0 then cursor:set(CONFIG, section, "app_list", list)
		else cursor:delete(CONFIG, section, "app_list") end
	end
	if args.category_list ~= nil then
		local list = {}
		for _, cat in ipairs(type(args.category_list) == "table" and args.category_list or {}) do
			list[#list + 1] = tostring(cat)
		end
		if #list > 0 then cursor:set(CONFIG, section, "category_list", list)
		else cursor:delete(CONFIG, section, "category_list") end
	end
	if type(args.blacklist) == "table" then
		if #args.blacklist > 0 then cursor:set(CONFIG, section, "blacklist", args.blacklist)
		else cursor:delete(CONFIG, section, "blacklist") end
	end
	return true
end

local function apply_firewall(cursor)
	cursor:foreach("firewall", "rule", function(s)
		if type(s.name) == "string" and s.name:sub(1, #RULE_PREFIX) == RULE_PREFIX then
			cursor:delete("firewall", s[".name"])
		end
	end)
	cursor:commit("firewall")

	local enabled = cursor:get(CONFIG, "main", "enable") == "1"
	if enabled then
		local rule_index = 0
		for _, group in ipairs(group_sections(cursor)) do
			local macs = group.macs or {}
			local ok, schedules = pcall(cjson.decode, group.schedules or "[]")
			if ok and #macs > 0 then
				-- One rule per unique (begin,end) time range, covering every
				-- enabled weekday that shares it - "everyday" covers all 7
				-- with the first schedule entry's own times.
				local ranges = {}
				local days = group.schedules_days == "everyday"
					and { 1, 2, 3, 4, 5, 6, 7 } or nil
				for _, entry in ipairs(schedules) do
					if entry.enabled ~= false then
						local key = entry.begin .. "-" .. entry["end"]
						ranges[key] = ranges[key] or { begin_time = entry.begin,
							end_time = entry["end"], weeks = {} }
						local weeks = days or { entry.week }
						for _, week in ipairs(weeks) do
							ranges[key].weeks[week] = true
						end
						if days then break end
					end
				end
				for _, range in pairs(ranges) do
					local weekdays = {}
					for week = 1, 7 do
						if range.weeks[week] then weekdays[#weekdays + 1] = WEEKDAY_NAMES[week] end
					end
					if #weekdays > 0 then
						for _, mac in ipairs(macs) do
							rule_index = rule_index + 1
							local id = cursor:add("firewall", "rule")
							cursor:set("firewall", id, "name", RULE_PREFIX .. rule_index)
							cursor:set("firewall", id, "src", "lan")
							cursor:set("firewall", id, "src_mac", mac)
							cursor:set("firewall", id, "dest", "wan")
							cursor:set("firewall", id, "target", "REJECT")
							cursor:set("firewall", id, "weekdays", table.concat(weekdays, " "))
							cursor:set("firewall", id, "start_time", range.begin_time .. ":00")
							cursor:set("firewall", id, "stop_time", range.end_time .. ":00")
						end
					end
				end
			end
		end
	end
	cursor:commit("firewall")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
end

return {
	get_config = function()
		local cursor = uci.cursor()
		local groups = {}
		for _, group in ipairs(group_sections(cursor)) do
			groups[#groups + 1] = group_result(group)
		end
		return {
			enable = cursor:get(CONFIG, "main", "enable") == "1",
			init = true,
			groups = as_array(groups),
		}
	end,

	set_config = function(args)
		args = args or {}
		if type(args.enable) ~= "boolean" then
			return { err_code = 1, err_msg = "enable must be boolean" }
		end
		local cursor = uci.cursor()
		cursor:set(CONFIG, "main", "settings")
		cursor:set(CONFIG, "main", "enable", args.enable and "1" or "0")
		cursor:commit(CONFIG)
		apply_firewall(cursor)
		return {}
	end,

	add_group = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local group_id = new_id()
		local section = "g_" .. group_id
		cursor:set(CONFIG, section, "group")
		cursor:set(CONFIG, section, "group_id", group_id)
		local ok, err = write_group(cursor, section, args)
		if not ok then
			cursor:delete(CONFIG, section)
			cursor:commit(CONFIG)
			return { err_code = 1, err_msg = err }
		end
		cursor:commit(CONFIG)
		apply_firewall(cursor)
		return group_result(group_by_id(cursor, group_id))
	end,

	set_group = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local group = group_by_id(cursor, args.group_id)
		if not group then return { err_code = 1, err_msg = "group not found" } end
		local ok, err = write_group(cursor, group[".name"], args)
		if not ok then return { err_code = 1, err_msg = err } end
		cursor:commit(CONFIG)
		apply_firewall(cursor)
		return {}
	end,

	remove_group = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local group = group_by_id(cursor, args.group_id)
		if not group then return { err_code = 1, err_msg = "group not found" } end
		cursor:delete(CONFIG, group[".name"])
		cursor:commit(CONFIG)
		apply_firewall(cursor)
		return {}
	end,

	get_app_list = function()
		return cjson.empty_array
	end,
}
