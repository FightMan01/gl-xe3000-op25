-- GL SDK4 OpenVPN client group adapter for the "VPN Client Profile" ->
-- OpenVPN tab. Only group management is implemented (real, UCI-backed);
-- actually importing a .ovpn file needs a multipart file-upload endpoint
-- this port doesn't have yet (nginx has no /upload route at all - the
-- firmware-upload page has the same pre-existing gap), so check_config/
-- confirm_config report an honest "not supported yet" instead of a hard
-- "no such method" crash. get_config_list always returns no clients as a
-- result - there is no way to add one until the upload pipeline exists.
--
-- The frontend's own rename dialog calls the separate underscore-named
-- "ovpn_client" object's set_config_name - see ovpn_client.lua.

local cjson = require "cjson"
local uci = require "uci"

local CONFIG = "gl_ovpnclient"

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
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

return {
	get_group_list = function()
		local cursor = uci.cursor()
		local groups = {}
		for _, group in ipairs(group_sections(cursor)) do
			groups[#groups + 1] = {
				group_id = group.group_id or "",
				group_name = group.group_name or "",
				group_type = 3,
				auth_type = 1,
				procedure = 0,
				show = 0,
			}
		end
		return { groups = as_array(groups) }
	end,

	add_group = function(args)
		args = args or {}
		if type(args.group_name) ~= "string" or args.group_name == "" then
			return { err_code = 1, err_msg = "invalid group name" }
		end
		local cursor = uci.cursor()
		local group_id = new_id()
		new_section(cursor, CONFIG, "group", "g_" .. group_id, {
			group_id = group_id,
			group_name = args.group_name,
		})
		cursor:commit(CONFIG)
		return { group_id = group_id, group_name = args.group_name }
	end,

	set_group = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local group = group_by_id(cursor, args.group_id)
		if not group then return { err_code = 1, err_msg = "group not found" } end
		if type(args.group_name) == "string" and args.group_name ~= "" then
			cursor:set(CONFIG, group[".name"], "group_name", args.group_name)
			cursor:commit(CONFIG)
		end
		return {}
	end,

	remove_group = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local group = group_by_id(cursor, args.group_id)
		if not group then return { err_code = 1, err_msg = "group not found" } end
		cursor:delete(CONFIG, group[".name"])
		cursor:commit(CONFIG)
		return {}
	end,

	get_config_list = function()
		return { clients = cjson.empty_array }
	end,

	clear_config_list = function()
		return {}
	end,

	clear_user_pass = function()
		return {}
	end,

	get_recommend_config = function()
		return { configs = cjson.empty_array }
	end,

	get_third_config = function()
		return { err_code = 1, err_msg = "third-party config import is not supported" }
	end,

	check_config = function()
		return { err_code = 1, err_msg = "config file upload is not supported yet" }
	end,

	confirm_config = function()
		return { err_code = 1, err_msg = "config file upload is not supported yet" }
	end,
}
