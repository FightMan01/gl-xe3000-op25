-- GL SDK4 WireGuard client config adapter, used by the "VPN Client" pages
-- (vpn-client.lua wraps these configs into tunnels). Only the manual/custom
-- path is implemented here (a user pasting their own WireGuard peer
-- details) - GL's commercial-provider auto-provisioning (NordVPN, Mullvad,
-- Surfshark, ExpressVPN, ...) needs each vendor's own proprietary API and
-- isn't implementable without their credentials/protocol, so
-- get_recommend_config/get_third_config/clear_user_pass stay honest stubs
-- and check_config/confirm_config (the raw .conf file upload+parse wizard)
-- are not implemented - add_config/set_config's direct-field form covers
-- the same end result without needing the upload pipeline.

local cjson = require "cjson"
local uci = require "uci"

local CONFIG = "gl_wgclient"

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function bool(value)
	return value == true or value == 1 or value == "1"
end

local function command_output(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	if not pipe then return "" end
	local data = pipe:read("*a") or ""
	pipe:close()
	return (data:gsub("%s+$", ""))
end

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function public_key(private)
	if type(private) ~= "string" or private == "" then return nil end
	local public = command_output("printf %s " .. shell_quote(private) .. " | wg pubkey")
	if not public:match("^[A-Za-z0-9+/]+=?=?$") then return nil end
	return public
end

local function new_id()
	local seed = tostring(os.time()) .. tostring(math.random(100000, 999999))
	return command_output("printf %s " .. shell_quote(seed) .. " | sha256sum | cut -c1-16")
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

local function group_result(group)
	return {
		group_id = group.group_id or "",
		group_name = group.group_name or "",
		-- group_type 3 matches GL's own "FromApp" (manually supplied,
		-- non-vendor) group convention seen in real device UCI dumps.
		group_type = 3,
		auth_type = 1,
		procedure = 0,
		show = 0,
	}
end

local function peer_sections(cursor, group_id)
	local peers = {}
	cursor:foreach(CONFIG, "peer", function(section)
		if not group_id or tostring(section.group_id or "") == tostring(group_id) then
			peers[#peers + 1] = section
		end
	end)
	return peers
end

local function peer_by_id(cursor, id)
	local found
	cursor:foreach(CONFIG, "peer", function(section)
		if not found and tostring(section.peer_id or "") == tostring(id or "") then
			found = section
		end
	end)
	return found
end

local function allowed_ips_result(value)
	local out = {}
	for _, ip in ipairs(cjson.decode(value or "[]")) do
		out[#out + 1] = { ip = ip }
	end
	return as_array(out)
end

local function peer_result(peer)
	return {
		peer_id = peer.peer_id or "",
		group_id = peer.group_id or "",
		name = peer.name or "",
		address_v4 = peer.address_v4 or "",
		address_v6 = peer.address_v6 or "",
		private_key = peer.private_key or "",
		public_key = peer.public_key or "",
		end_point = peer.end_point or "",
		allowed_ips = allowed_ips_result(peer.allowed_ips_json),
		dns = peer.dns or "",
		mtu = tonumber(peer.mtu),
		listen_port = tonumber(peer.listen_port),
		persistent_keepalive = tonumber(peer.persistent_keepalive),
		presharedkey_enable = peer.presharedkey_enable == "1",
		preshared_key = peer.preshared_key or "",
	}
end

local function write_peer(cursor, section, args)
	if type(args.name) ~= "string" or args.name == "" then
		return nil, "invalid config name"
	end
	if type(args.private_key) ~= "string" or args.private_key == "" then
		return nil, "missing private key"
	end
	if type(args.end_point) ~= "string" or args.end_point == "" then
		return nil, "missing endpoint"
	end
	if type(args.public_key) ~= "string" or args.public_key == "" then
		return nil, "missing server public key"
	end
	if (type(args.address_v4) ~= "string" or args.address_v4 == "")
		and (type(args.address_v6) ~= "string" or args.address_v6 == "") then
		return nil, "missing tunnel address"
	end
	local ips = {}
	if type(args.allowed_ips) == "table" then
		for _, entry in ipairs(args.allowed_ips) do
			if type(entry) == "table" and type(entry.ip) == "string" and entry.ip ~= "" then
				ips[#ips + 1] = entry.ip
			end
		end
	end
	if #ips == 0 then ips = { "0.0.0.0/0", "::/0" } end

	cursor:set(CONFIG, section, "name", args.name)
	cursor:set(CONFIG, section, "group_id", args.group_id or "")
	cursor:set(CONFIG, section, "address_v4", args.address_v4 or "")
	cursor:set(CONFIG, section, "address_v6", args.address_v6 or "")
	cursor:set(CONFIG, section, "private_key", args.private_key)
	cursor:set(CONFIG, section, "public_key", args.public_key)
	cursor:set(CONFIG, section, "end_point", args.end_point)
	cursor:set(CONFIG, section, "allowed_ips_json", cjson.encode(ips))
	cursor:set(CONFIG, section, "dns", args.dns or "")
	cursor:set(CONFIG, section, "mtu", tostring(tonumber(args.mtu) or 0))
	cursor:set(CONFIG, section, "listen_port", tostring(tonumber(args.listen_port) or 0))
	cursor:set(CONFIG, section, "persistent_keepalive",
		tostring(tonumber(args.persistent_keepalive) or 25))
	cursor:set(CONFIG, section, "presharedkey_enable",
		bool(args.presharedkey_enable) and "1" or "0")
	if type(args.preshared_key) == "string" then
		cursor:set(CONFIG, section, "preshared_key", args.preshared_key)
	end
	cursor:commit(CONFIG)
	return true
end

return {
	get_group_list = function()
		local cursor = uci.cursor()
		local groups = {}
		for _, group in ipairs(group_sections(cursor)) do
			groups[#groups + 1] = group_result(group)
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
		for _, peer in ipairs(peer_sections(cursor, args.group_id)) do
			cursor:delete(CONFIG, peer[".name"])
		end
		cursor:delete(CONFIG, group[".name"])
		cursor:commit(CONFIG)
		return {}
	end,

	get_config_list = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local peers = {}
		for _, peer in ipairs(peer_sections(cursor, args.group_id)) do
			peers[#peers + 1] = peer_result(peer)
		end
		return { peers = as_array(peers), auth_type = 1, public_key = "" }
	end,

	add_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if type(args.group_id) ~= "string" or not group_by_id(cursor, args.group_id) then
			return { err_code = 1, err_msg = "group not found" }
		end
		local peer_id = new_id()
		local section = new_section(cursor, CONFIG, "peer", "p_" .. peer_id, { peer_id = peer_id })
		local ok, err = write_peer(cursor, section, args)
		if not ok then
			cursor:delete(CONFIG, section)
			cursor:commit(CONFIG)
			return { err_code = 1, err_msg = err }
		end
		return { peer_id = peer_id }
	end,

	set_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local peer = peer_by_id(cursor, args.peer_id)
		if not peer then return { err_code = 1, err_msg = "config not found" } end
		local ok, err = write_peer(cursor, peer[".name"], args)
		if not ok then return { err_code = 1, err_msg = err } end
		return {}
	end,

	clear_config_list = function(args)
		args = args or {}
		local cursor = uci.cursor()
		for _, peer in ipairs(peer_sections(cursor, args.group_id)) do
			cursor:delete(CONFIG, peer[".name"])
		end
		cursor:commit(CONFIG)
		return {}
	end,

	generate_key = function()
		local private = command_output("wg genkey")
		if not private:match("^[A-Za-z0-9+/]+=?=?$") then
			return { err_code = 1, err_msg = "wireguard-tools unavailable" }
		end
		local public = public_key(private)
		if not public then return { err_code = 1, err_msg = "key generation failed" } end
		return { private_key = private, public_key = public }
	end,

	generate_publickey = function(args)
		local public = public_key(args and args.private_key)
		if not public then return { err_code = 1, err_msg = "invalid private key" } end
		return { public_key = public }
	end,

	-- Commercial-provider auto-provisioning is out of scope (see header) -
	-- report an empty, honestly-unsupported catalog rather than a fake one.
	get_recommend_config = function()
		return { configs = cjson.empty_array }
	end,

	get_third_config = function()
		return { err_code = 1, err_msg = "third-party config import is not supported" }
	end,

	check_config = function()
		return { err_code = 1, err_msg = "config file upload is not supported, use add_config" }
	end,

	confirm_config = function()
		return { err_code = 1, err_msg = "config file upload is not supported, use add_config" }
	end,

	clear_user_pass = function()
		return {}
	end,
}
