-- "cloud" RPC object for the GL.iNet 4.11 Account/Cloud pages.
--
-- The heavy lifting (authentication, MQTT, cloud commands) lives in the
-- gl-cloud daemon. This object is the local, session-authenticated view of
-- that state: UCI binding fields, daemon connection status, and the three
-- actions the UI performs (enable, fetch bind URL, unbind).

local ubus = require "ubus"
local uci = require "uci"

local CFG = "gl-cloud"
local SEC = "@cloud[0]"

local CLOUD_URL = {
	["gslb.gl-inet.cn"] = "https://cloud.gl-inet.cn",
	["gslb-cn.goodcloud.xyz"] = "https://cloud.gl-inet.cn",
	["gslb-eu.goodcloud.xyz"] = "https://www.goodcloud.xyz",
}

local function readfile(path)
	local f = io.open(path, "r")
	if not f then return "" end
	local data = f:read("*l")
	f:close()
	return (data or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function ucall(object, method, params)
	local ok, conn = pcall(ubus.connect)
	if not ok or not conn then return nil end
	local called, result = pcall(conn.call, conn, object, method, params or {})
	conn:close()
	if not called then return nil end
	return result
end

local function connected()
	local status = ucall("gl-cloud", "status")
	return type(status) == "table" and tonumber(status.connected) or 0
end

local function country()
	local value = readfile("/proc/gl-hw-info/country_code")
	if value == "" then
		local f = io.open("/dev/mmcblk0p3", "rb")
		if f then
			f:seek("set", 0x88)
			value = (f:read(2) or ""):gsub("%z", ""):gsub("%s+$", "")
			f:close()
		end
	end
	return value
end

local function ensure_server(cursor)
	local server = cursor:get(CFG, SEC, "server")
	if server and server ~= "" then return server end
	server = country() == "CN" and "gslb.gl-inet.cn" or "gslb-eu.goodcloud.xyz"
	cursor:set(CFG, SEC, "server", server)
	return server
end

local API_URL = {
	["gslb.gl-inet.cn"] = "https://api.gl-inet.cn",
	["gslb-cn.goodcloud.xyz"] = "https://api.gl-inet.cn",
	["gslb-eu.goodcloud.xyz"] = "https://api.goodcloud.xyz",
}

local function api_base(cursor)
	local custom = cursor:get(CFG, SEC, "srv_api")
	if custom and custom ~= "" then return custom end
	return API_URL[ensure_server(cursor)] or "https://api.goodcloud.xyz"
end

local function notify_status(cursor)
	ucall("gl-session", "notify", {
		name = "cloud.status",
		data = {
			cloud_enable = cursor:get(CFG, SEC, "enable") == "1",
			username = cursor:get(CFG, SEC, "username") or "",
			email = cursor:get(CFG, SEC, "email") or "",
			bindtime = cursor:get(CFG, SEC, "bindtime") or "",
			bindtype = cursor:get(CFG, SEC, "bindtype") or "",
		},
	})
end

local function stop_daemon()
	os.execute("/etc/init.d/gl-cloud stop >/dev/null 2>&1")
	ucall("service", "delete", { name = "rtty" })
	os.execute("/etc/init.d/rtty stop >/dev/null 2>&1")
end

local function start_daemon()
	-- The daemon re-authenticates and reconnects on its own; do not hold the
	-- RPC (and the UI spinner) open while that happens.
	os.execute("/etc/init.d/gl-cloud restart >/dev/null 2>&1 &")
end

local function wait_connected(tries)
	for _ = 1, tries do
		if connected() > 0 then return true end
		ngx.sleep(1)
	end
	return false
end

return {
	get_config = function()
		local cursor = uci.cursor()
		local token = cursor:get(CFG, SEC, "token") or ""
		local cloud_url = cursor:get(CFG, SEC, "srv_url")
		if not cloud_url or cloud_url == "" then
			cloud_url = CLOUD_URL[ensure_server(cursor)] or
				(country() == "CN" and "https://cloud.gl-inet.cn" or
				"https://www.goodcloud.xyz")
		end
		local up = connected()
		local token_status = 0
		if token == "invalid" then
			token_status = 2
		elseif up > 0 then
			token_status = 1
		end
		return {
			cloud_enable = cursor:get(CFG, SEC, "enable") == "1",
			rtty_ssh = cursor:get("rtty", "general", "ssh_en") == "1",
			rtty_web = cursor:get("rtty", "general", "web_en") == "1",
			username = cursor:get(CFG, SEC, "username") or "",
			email = cursor:get(CFG, SEC, "email") or "",
			bindtime = cursor:get(CFG, SEC, "bindtime") or "",
			bindtype = cursor:get(CFG, SEC, "bindtype") or "",
			token_invalid = token == "invalid",
			token_status = token_status,
			cloud_url = cloud_url,
			aw_url = cursor:get(CFG, SEC, "aw_url") or "https://my.astrowarp.net",
			aw_api_url = cursor:get(CFG, SEC, "aw_api_url") or
				"https://goodpas-api.gl-inet.com",
		}
	end,

	set_config = function(args)
		args = args or {}
		local cursor = uci.cursor()

		if type(args.cloud_enable) == "boolean" then
			cursor:set(CFG, SEC, "enable", args.cloud_enable and "1" or "0")
		end
		if type(args.rtty_ssh) == "boolean" then
			if not cursor:get("rtty", "general") then
				cursor:set("rtty", "general", "general")
			end
			cursor:set("rtty", "general", "ssh_en", args.rtty_ssh and "1" or "0")
		end
		if type(args.rtty_web) == "boolean" then
			if not cursor:get("rtty", "general") then
				cursor:set("rtty", "general", "general")
			end
			cursor:set("rtty", "general", "web_en", args.rtty_web and "1" or "0")
		end

		ensure_server(cursor)
		local enabled = cursor:get(CFG, SEC, "enable") == "1"
		if not enabled then
			-- Stock drops the binding time when the service is switched off,
			-- but keeps the account name so the page can show it again.
			cursor:delete(CFG, SEC, "bindtime")
		end
		cursor:commit(CFG)
		cursor:commit("rtty")
		os.execute("sync")

		notify_status(cursor)
		if enabled then
			start_daemon()
		else
			stop_daemon()
		end
		return {}
	end,

	get_bind_url = function()
		local cursor = uci.cursor()
		local bindtime = cursor:get(CFG, SEC, "bindtime") or ""
		local resp = ucall("gl-cloud", "bind_url")
		if not resp then
			ngx.sleep(1)
			resp = ucall("gl-cloud", "bind_url")
		end
		if not resp then
			return { err_code = -1, err_msg = "get bind url failed" }
		end
		local url = resp.url or ""
		if resp.err or url == "" then
			return { err_code = resp.err_code or -1, err_msg = resp.err or
				"get bind url failed" }
		end
		local isbind = bindtime == "" and 0 or 1
		local result = {}
		if resp.err_code == 1 then
			result.rebind = true
			isbind = 1
		end
		result.url = string.format("%s&isbind=%d", url, isbind)
		return result
	end,

	bind_info = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if (args.bindtime or "") == "" then
			os.execute("/etc/init.d/rtty stop >/dev/null 2>&1")
		end
		cursor:set(CFG, SEC, "username", args.username or "")
		cursor:set(CFG, SEC, "email", args.email or "")
		cursor:set(CFG, SEC, "bindtime", args.bindtime or "")
		cursor:set(CFG, SEC, "bindtype", args.bindtype or args.bindType or "")
		cursor:commit(CFG)
		os.execute("sync")
		notify_status(cursor)
		return {}
	end,

	bind_device = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local url = args.url
		if type(url) ~= "string" or url == "" then
			url = api_base(cursor)
			if args.org_id then
				url = url .. "/cloud-api/cloud/v2/sdk/device/bind/org"
			elseif args.var_id then
				url = url .. "/cloud-api/cloud/v2/sdk/device/bind/inventory"
			else
				url = url .. "/cloud-api/cloud/v2/sdk/device/bind/self"
			end
		end
		local ret = ucall("gl-cloud", "bind", {
			url = url,
			token = args.token or "",
			id = args.org_id or args.var_id or args.id or "",
		})
		if ret and ret.err then
			return { err_code = ret.code or -1, err_msg = ret.err }
		end
		if not wait_connected(10) then
			return { err_code = -10, err_msg = "mqtt disconnect" }
		end
		return {}
	end,

	rebind = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local ret = ucall("gl-cloud", "rebind", {
			url = api_base(cursor),
			token = args.token or "",
		})
		if ret and ret.err then
			return { err_code = ret.code or -1, err_msg = ret.err }
		end
		if connected() == 0 then
			ucall("gl-cloud", "reconnect")
			if not wait_connected(10) then
				return { err_code = -10, err_msg = "mqtt disconnect" }
			end
		end
		ucall("gl-cloud", "alive")
		return {}
	end,

	unbind = function()
		local cursor = uci.cursor()
		local ret = ucall("gl-cloud", "unbind") or {}
		if ret.code ~= 0 and ret.code ~= -1 then
			return { err_code = -1, err_msg = "unbind fail" }
		end
		cursor:delete(CFG, SEC, "username")
		cursor:delete(CFG, SEC, "email")
		cursor:delete(CFG, SEC, "bindtime")
		cursor:delete(CFG, SEC, "bindtype")
		-- Without AstroWarp there is nothing else keeping the cloud client
		-- alive after an unbind, so switch it off like stock does.
		cursor:set(CFG, SEC, "enable", "0")
		cursor:commit(CFG)
		os.execute("sync")
		stop_daemon()
		notify_status(cursor)
		return {}
	end,

	notify_module_detached = function()
		local cursor = uci.cursor()
		if (cursor:get(CFG, SEC, "bindtime") or "") ~= "" then
			return { disabled = false }
		end
		cursor:set(CFG, SEC, "enable", "0")
		cursor:commit(CFG)
		os.execute("sync")
		stop_daemon()
		notify_status(cursor)
		return { disabled = true }
	end,
}
