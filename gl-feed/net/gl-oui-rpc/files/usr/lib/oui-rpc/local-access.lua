-- "local-access" RPC object: which LAN clients/subnets can reach the admin
-- GUI. Implemented as an nginx allow/deny list generated into a separate
-- include file, reloaded on change.

local uci = require "uci"
local LISTEN_FILE = "/etc/gl-oui-listen.conf"

-- Under /etc (persisted, overlay-backed), not /var (tmpfs) - see the nginx
-- config's comment for why: avoids an `include` failure on a missing file
-- at boot, before this object has ever run.
local INCLUDE_FILE = "/etc/gl-oui-access.conf"

local function regenerate(cursor)
	local lines = {}
	local restricted = cursor:get("gl-oui-rpc", "main", "local_access_restricted") == "1"
	if restricted then
		cursor:foreach("gl-oui-rpc", "allowed_subnet", function(s)
			if s.subnet then
				table.insert(lines, "allow " .. s.subnet .. ";")
			end
		end)
		table.insert(lines, "deny all;")
	end
	local f = io.open(INCLUDE_FILE, "w")
	if f then
		f:write(table.concat(lines, "\n"))
		f:close()
	end
end

local function option_number(cursor, package, section, option, default)
	return tonumber(cursor:get(package, section, option) or "") or default
end

local function option_bool(cursor, package, section, option, default)
	local value = cursor:get(package, section, option)
	if value == nil then return default end
	return value == "1"
end

local function valid_port(value)
	value = tonumber(value)
	return value and value >= 1 and value <= 65535 and math.floor(value) == value
end

local function command_succeeded(status)
	-- Lua 5.1 returns numeric 0, while newer Lua returns boolean true plus
	-- exit details. The firmware's nginx Lua module uses the former.
	return status == true or status == 0
end

local function write_listeners(http_port, https_port, redirect_https)
	local tmp = LISTEN_FILE .. ".new"
	local f = io.open(tmp, "w")
	if not f then return false, "cannot write nginx listener config" end
	f:write("listen ", http_port, " default_server;\n")
	f:write("listen [::]:", http_port, " default_server;\n")
	f:write("listen ", https_port, " ssl;\n")
	f:write("listen [::]:", https_port, " ssl;\n")
	f:write("ssl_certificate /etc/gl-oui.crt;\n")
	f:write("ssl_certificate_key /etc/gl-oui.key;\n")
	if redirect_https then
		local suffix = https_port == 443 and "" or (":" .. tostring(https_port))
		f:write("if ($scheme = http) { return 301 https://$host", suffix, "$request_uri; }\n")
	end
	f:close()
	return true
end

return {
	get_config = function(args)
		local cursor = uci.cursor()
		local subnets = {}
		cursor:foreach("gl-oui-rpc", "allowed_subnet", function(s)
			table.insert(subnets, s.subnet)
		end)
		return {
			restricted = cursor:get("gl-oui-rpc", "main", "local_access_restricted") == "1",
			subnets = subnets,
			http_port = option_number(cursor, "gl-oui-rpc", "main", "http_port", 80),
			https_port = option_number(cursor, "gl-oui-rpc", "main", "https_port", 443),
			redirect_https = option_bool(cursor, "gl-oui-rpc", "main", "redirect_https", false),
			luci_http_port = option_number(cursor, "gl-oui-rpc", "main", "luci_http_port", 8080),
			luci_https_port = option_number(cursor, "gl-oui-rpc", "main", "luci_https_port", 8443),
			luci_redirect_https = option_bool(cursor, "uhttpd", "main", "redirect_https", false),
			ssh_port = option_number(cursor, "dropbear", "main", "Port", 22),
			ssh_enabled = option_bool(cursor, "dropbear", "main", "enable", true),
			session_timeout = option_number(cursor, "gl-oui-rpc", "main", "session_timeout", 300),
		}
	end,

	set_config = function(args)
		local cursor = uci.cursor()
		local http_port = tonumber(args.http_port) or 80
		local https_port = tonumber(args.https_port) or 443
		local luci_http_port = tonumber(args.luci_http_port) or 8080
		local luci_https_port = tonumber(args.luci_https_port) or 8443
		local ssh_port = tonumber(args.ssh_port) or 22
		local ports = { http_port, https_port, luci_http_port, luci_https_port, ssh_port }
		local seen = {}
		for _, port in ipairs(ports) do
			if not valid_port(port) or seen[port] then
				return { err_code = -1, err_msg = "invalid or conflicting port" }
			end
			seen[port] = true
		end

		local ok, err = write_listeners(http_port, https_port, args.redirect_https == true)
		if not ok then return { err_code = -1, err_msg = err } end

		-- nginx can only validate the generated include at its real path.
		-- Keep the previous file in memory, test the candidate, and restore
		-- it on failure so a rejected port change cannot break the admin UI
		-- on the next reload or reboot.
		local previous
		local old = io.open(LISTEN_FILE, "r")
		if old then previous = old:read("*a"); old:close() end
		os.rename(LISTEN_FILE .. ".new", LISTEN_FILE)
		if not command_succeeded(os.execute(
			"/usr/sbin/nginx -t -c /etc/nginx/uci.conf >/dev/null 2>&1")) then
			local restore = io.open(LISTEN_FILE, "w")
			if restore then
				restore:write(previous or
					"listen 80 default_server;\nlisten [::]:80 default_server;\n")
				restore:close()
			end
			return { err_code = -1, err_msg = "nginx rejected the requested ports" }
		end

		cursor:set("gl-oui-rpc", "main", "http_port", tostring(http_port))
		cursor:set("gl-oui-rpc", "main", "https_port", tostring(https_port))
		cursor:set("gl-oui-rpc", "main", "redirect_https", args.redirect_https and "1" or "0")
		cursor:set("gl-oui-rpc", "main", "luci_http_port", tostring(luci_http_port))
		cursor:set("gl-oui-rpc", "main", "luci_https_port", tostring(luci_https_port))
		if args.session_timeout then
			cursor:set("gl-oui-rpc", "main", "session_timeout",
				tostring(math.max(60, math.min(10800, tonumber(args.session_timeout) or 300))))
		end
		cursor:commit("gl-oui-rpc")

		cursor:delete("uhttpd", "main", "listen_http")
		cursor:delete("uhttpd", "main", "listen_https")
		cursor:set("uhttpd", "main", "listen_http",
			{ "0.0.0.0:" .. luci_http_port, "[::]:" .. luci_http_port })
		cursor:set("uhttpd", "main", "listen_https",
			{ "0.0.0.0:" .. luci_https_port, "[::]:" .. luci_https_port })
		cursor:set("uhttpd", "main", "redirect_https", args.luci_redirect_https and "1" or "0")
		cursor:commit("uhttpd")

		cursor:set("dropbear", "main", "Port", tostring(ssh_port))
		cursor:set("dropbear", "main", "enable", args.ssh_enabled and "1" or "0")
		cursor:commit("dropbear")

		os.execute("/etc/init.d/uhttpd restart >/dev/null 2>&1")
		os.execute("/etc/init.d/nginx reload >/dev/null 2>&1")
		os.execute("/etc/init.d/dropbear restart >/dev/null 2>&1")
		return {}
	end,
}
