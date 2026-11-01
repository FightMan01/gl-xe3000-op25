-- "rtty" RPC object: remote SSH/Web access requested by GoodCloud.
--
-- GoodCloud sends a command over MQTT with a host/port/token; the daemon
-- forwards it here with `ubus call gl-cloud ...`, and this object starts the
-- upstream rtty client (package rtty-openssl) under procd. rtty itself writes
-- its connection state to /var/run/rtty, which is what the cloud page shows.

local ubus = require "ubus"
local uci = require "uci"

local CA_PATH = "/tmp/ca.crt"
local CONFIG_PATH = "/tmp/rtty.ini"
local BIN = "/usr/sbin/rtty"

local function access(path)
	local f = io.open(path, "r")
	if not f then return false end
	f:close()
	return true
end

local function readfile(path)
	local f = io.open(path, "r")
	if not f then return "" end
	local data = f:read("*l") or ""
	f:close()
	return (data:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ubus_call(object, method, params)
	local ok, conn = pcall(ubus.connect)
	if not ok or not conn then return nil end
	local called, result = pcall(conn.call, conn, object, method, params or {})
	conn:close()
	if not called then return nil end
	return result
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

local function device_id()
	local value = readfile("/proc/gl-hw-info/device_ddns")
	if value == "" then
		local f = io.open("/dev/mmcblk0p3", "rb")
		if f then
			f:seek("set", 0x10)
			value = (f:read(16) or ""):gsub("%z", ""):gsub("\255", "")
			f:close()
		end
	end
	return value
end

local function http_timeout()
	local value = uci.cursor():get("rtty", "general", "http_timeout")
	return tonumber(value) or 180
end

local function supports_ini()
	local pipe = io.popen(BIN .. " --help 2>&1")
	if not pipe then return false end
	local help = pipe:read("*a") or ""
	pipe:close()
	return help:find("%-%-conf[=%s]") ~= nil
end

local function write_config(data)
	local path = CONFIG_PATH .. ".new"
	local f = io.open(path, "w")
	if not f then return false end
	local ok = f:write(data)
	f:close()
	if not ok then
		os.remove(path)
		return false
	end
	return os.rename(path, CONFIG_PATH) ~= nil
end

local function service_running()
	local list = ubus_call("service", "list", { name = "rtty" })
	local instance = list and list.rtty and list.rtty.instances and
		list.rtty.instances.instance1
	return instance and instance.running and true or false
end

local function fetch_ca()
	if access(CA_PATH) then return true end
	local host = country() == "CN" and "ca.gl-inet.cn" or "ca.gl-inet.com"
	os.execute(string.format(
		"curl -fsS --max-time 10 -o %s https://%s/goodcloud/ca.crt " ..
		">/dev/null 2>&1", CA_PATH, host))
	return access(CA_PATH)
end

local function safe_value(value)
	if type(value) ~= "string" then return false end
	return not (value:find("[%z\r\n]") or value:find("^%s") or
		value:find("%s$") or value:find("%s;"))
end

return {
	get_config = function()
		local cursor = uci.cursor()
		return {
			ssh_enabled = cursor:get("rtty", "general", "ssh_en") == "1",
			web_enabled = cursor:get("rtty", "general", "web_en") == "1",
		}
	end,

	set_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if not cursor:get("rtty", "general") then
			cursor:set("rtty", "general", "general")
		end
		cursor:set("rtty", "general", "ssh_en", args.ssh_enable and "1" or "0")
		cursor:set("rtty", "general", "web_en", args.web_enable and "1" or "0")
		cursor:commit("rtty")
		ubus_call("gl-cloud", "alive")
		return {
			ssh_enabled = args.ssh_enable == true,
			web_enabled = args.web_enable == true,
		}
	end,

	run = function(args)
		args = args or {}
		local host = args.host
		local port = tonumber(args.port)
		local token = args.token
		local ssl = args.ssl == true

		if type(host) ~= "string" or not port then
			return { err_code = 1, err_msg = "invalid rtty parameters" }
		end
		if not safe_value(host) or (token ~= nil and not safe_value(token)) then
			return { err_code = 1, err_msg = "invalid rtty parameters" }
		end
		if service_running() then return nil end

		local id = device_id()
		if id == "" or id:find("[^%w_-]") then
			return { err_code = 1, err_msg = "no valid ddns" }
		end
		if not fetch_ca() then
			return { err_code = 3, err_msg = "failed to get ca certificate" }
		end

		local command
		if supports_ini() then
			local config = {
				"[rtty]",
				"id=" .. id,
				"host=" .. host,
				"port=" .. tostring(port),
				"http-timeout=" .. tostring(http_timeout()),
			}
			if token and token ~= "" then
				config[#config + 1] = "token=" .. token
			end
			config[#config + 1] = "[ssl]"
			config[#config + 1] = "enabled=" .. tostring(ssl)
			config[#config + 1] = "cacert=" .. CA_PATH
			if not write_config(table.concat(config, "\n") .. "\n") then
				return { err_code = 4, err_msg = "failed to write rtty config" }
			end
			command = { BIN, "--conf", CONFIG_PATH }
		else
			command = { BIN, "-I", id, "-h", host, "-p", tostring(port),
				"--http-timeout", tostring(http_timeout()) }
			if token and token ~= "" then
				command[#command + 1] = "-t"
				command[#command + 1] = token
			end
			if ssl then
				command[#command + 1] = "-s"
			end
			command[#command + 1] = "-C"
			command[#command + 1] = CA_PATH
		end

		ubus_call("service", "delete", { name = "rtty" })
		ubus_call("service", "add", {
			name = "rtty",
			instances = {
				instance1 = { command = command },
			},
		})
		for _ = 1, 10 do
			if service_running() then
				local f = io.open("/tmp/rtty-host-port", "w")
				if f then
					f:write(host .. tostring(port) .. tostring(ssl))
					f:close()
				end
				return nil
			end
			ngx.sleep(0.5)
		end
		return { err_code = 2, err_msg = "connect failed" }
	end,

	stop = function()
		ubus_call("service", "delete", { name = "rtty" })
		os.remove("/var/run/rtty")
		return {}
	end,
}
