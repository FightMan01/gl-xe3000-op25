-- GL SDK4 OpenVPN Server page adapter using OpenWrt's maintained
-- openvpn-openssl package, driven directly (native openvpn UCI config
-- generated at apply-time), not through netifd - openvpn isn't a netifd
-- protocol here, its tun device is attached to the firewall by device
-- name, same as any other non-netifd interface.
--
-- Real GL firmware's client_auth=1 mode is username/password (not
-- per-client certificates): one shared CA-signed server cert, one shared
-- client cert embedded in the exported .ovpn bundle, and OpenVPN's
-- auth-user-pass-verify script gate for per-user login. That matches
-- what add_user/remove_user/get_user_list actually manage here - a user
-- list, not a certificate list. TAP (bridged) mode needs a materially
-- different, riskier network topology (bridging the tunnel into br-lan)
-- and is out of scope for this pass; set_config rejects mode="tap" with
-- a clear error rather than silently only doing tun.

local cjson = require "cjson"
local uci = require "uci"

local CONFIG = "gl_ovpnserver"
local IFACE = "ovpnserver"
local CERT_DIR = "/etc/openvpn/gl-ovpnserver"
local EXPORT_DIR = "/etc/openvpn/ovpn"
local EXPORT_FILE = EXPORT_DIR .. "/client.ovpn"
local AUTH_SCRIPT = "/usr/lib/gl-oui-rpc/ovpnserver-auth.sh"

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
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

local function read_file(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local data = file:read("*a")
	file:close()
	return data
end

local function file_exists(path)
	local file = io.open(path, "r")
	if file then file:close(); return true end
	return false
end

local function vpn_get(cursor, option, default)
	local value = cursor:get(CONFIG, "vpn", option)
	if value == nil or value == "" then return default end
	return value
end

local function bool(value)
	return value == true or value == 1 or value == "1"
end

local function sha256(value)
	return (command_output("printf %s " .. shell_quote(value) .. " | sha256sum | cut -d' ' -f1"))
end

local function new_id()
	return command_output("printf %s%s " .. shell_quote(os.time()) .. " " ..
		shell_quote(math.random(100000, 999999)) .. " | sha256sum | cut -c1-12")
end

local function user_sections(cursor)
	local users = {}
	cursor:foreach(CONFIG, "user", function(s)
		users[#users + 1] = s
	end)
	return users
end

local function user_by_name(cursor, username)
	for _, user in ipairs(user_sections(cursor)) do
		if user.username == username then return user end
	end
	return nil
end

local function vpn_config(cursor)
	return {
		mode = vpn_get(cursor, "dev_type", "tun"),
		subnetv4 = vpn_get(cursor, "subnetv4", "10.8.0.0"),
		mask = vpn_get(cursor, "mask", "255.255.255.0"),
		subnetv6 = vpn_get(cursor, "subnetv6", ""),
		start = vpn_get(cursor, "start", "10.8.0.2"),
		["end"] = vpn_get(cursor, "end", "10.8.0.100"),
		proto = vpn_get(cursor, "proto", "udp"),
		port = tonumber((cursor:get(CONFIG, "vpn", "port"))) or 1194,
		client_auth = vpn_get(cursor, "client_auth", "1") == "1" and 1 or 0,
		cert = vpn_get(cursor, "cert", ""),
		key = vpn_get(cursor, "key", ""),
		auth = vpn_get(cursor, "auth", "SHA256"),
		cipher = vpn_get(cursor, "cipher", "AES-256-GCM"),
		lzo = vpn_get(cursor, "comp", "") == "lzo",
		dh = vpn_get(cursor, "dh", ""),
		ca = vpn_get(cursor, "ca", ""),
		hmac = vpn_get(cursor, "hmac", "0") == "1",
		ta = vpn_get(cursor, "ta", ""),
		client_to_client = vpn_get(cursor, "client_to_client", "0") == "1",
		verb = vpn_get(cursor, "verb", "3"),
		tap_address = vpn_get(cursor, "tap_address", ""),
		tap_mask = vpn_get(cursor, "tap_mask", ""),
	}
end

local function initialized(cursor)
	return file_exists(CERT_DIR .. "/ca.crt")
		and file_exists(CERT_DIR .. "/server.crt")
		and file_exists(CERT_DIR .. "/server.key")
end

local function apply_runtime(cursor)
	if not initialized(cursor) then
		return false, "OpenVPN server certificate is not generated yet"
	end
	if vpn_get(cursor, "dev_type", "tun") ~= "tun" then
		return false, "TAP (bridged) mode is not supported on this build"
	end

	local config = vpn_config(cursor)
	local client_auth = cursor:get(CONFIG, "vpn", "client_auth") == "1"

	cursor:delete("openvpn", IFACE)
	cursor:set("openvpn", IFACE, "openvpn")
	cursor:set("openvpn", IFACE, "enabled", "1")
	cursor:set("openvpn", IFACE, "port", tostring(config.port))
	cursor:set("openvpn", IFACE, "proto", config.proto)
	cursor:set("openvpn", IFACE, "dev", IFACE)
	cursor:set("openvpn", IFACE, "dev_type", "tun")
	cursor:set("openvpn", IFACE, "ca", CERT_DIR .. "/ca.crt")
	cursor:set("openvpn", IFACE, "cert", CERT_DIR .. "/server.crt")
	cursor:set("openvpn", IFACE, "key", CERT_DIR .. "/server.key")
	cursor:set("openvpn", IFACE, "dh", "none")
	cursor:set("openvpn", IFACE, "cipher", config.cipher)
	cursor:set("openvpn", IFACE, "auth", config.auth)
	cursor:set("openvpn", IFACE, "server", config.subnetv4 .. " " .. config.mask)
	if config.subnetv6 ~= "" then
		cursor:set("openvpn", IFACE, "server_ipv6", config.subnetv6)
	end
	cursor:set("openvpn", IFACE, "ifconfig_pool_persist", "/tmp/openvpn-" .. IFACE .. "-ipp.txt")
	cursor:set("openvpn", IFACE, "keepalive", "10 120")
	cursor:set("openvpn", IFACE, "persist_key", "1")
	cursor:set("openvpn", IFACE, "persist_tun", "1")
	cursor:set("openvpn", IFACE, "user", "nobody")
	cursor:set("openvpn", IFACE, "status", "/tmp/openvpn-" .. IFACE .. ".log")
	cursor:set("openvpn", IFACE, "verb", config.verb)
	cursor:set("openvpn", IFACE, "topology", "subnet")
	-- One shared server cert covers every exported client bundle -
	-- required so more than one real device can connect at once.
	cursor:set("openvpn", IFACE, "duplicate_cn", "1")
	if config.lzo then cursor:set("openvpn", IFACE, "compress", "lzo") end
	if config.client_to_client then cursor:set("openvpn", IFACE, "client_to_client", "1") end
	if config.hmac and config.ta ~= "" and file_exists(config.ta) then
		cursor:set("openvpn", IFACE, "tls_auth", config.ta .. " 0")
	end
	if client_auth then
		cursor:set("openvpn", IFACE, "client_cert_not_required", "1")
		cursor:set("openvpn", IFACE, "username_as_common_name", "1")
		cursor:set("openvpn", IFACE, "auth_user_pass_verify", AUTH_SCRIPT .. " via-env")
		cursor:set("openvpn", IFACE, "script_security", "2")
	end
	cursor:commit("openvpn")

	for _, name in ipairs({
		"gl_ovpnserver", "gl_ovpnserver_to_lan", "gl_ovpnserver_to_wan",
		"gl_ovpnserver_input",
	}) do
		cursor:delete("firewall", name)
	end
	local access = cursor:get(CONFIG, "global", "access") or "DROP"
	cursor:set("firewall", "gl_ovpnserver", "zone")
	cursor:set("firewall", "gl_ovpnserver", "name", IFACE)
	cursor:set("firewall", "gl_ovpnserver", "device", IFACE)
	cursor:set("firewall", "gl_ovpnserver", "input", access == "ACCEPT" and "ACCEPT" or "REJECT")
	cursor:set("firewall", "gl_ovpnserver", "output", "ACCEPT")
	cursor:set("firewall", "gl_ovpnserver", "forward", "REJECT")
	cursor:set("firewall", "gl_ovpnserver", "masq", cursor:get(CONFIG, "global", "masq") == "0" and "0" or "1")
	cursor:set("firewall", "gl_ovpnserver_to_lan", "forwarding")
	cursor:set("firewall", "gl_ovpnserver_to_lan", "src", IFACE)
	cursor:set("firewall", "gl_ovpnserver_to_lan", "dest", "lan")
	cursor:set("firewall", "gl_ovpnserver_to_wan", "forwarding")
	cursor:set("firewall", "gl_ovpnserver_to_wan", "src", IFACE)
	cursor:set("firewall", "gl_ovpnserver_to_wan", "dest", "wan")
	cursor:set("firewall", "gl_ovpnserver_input", "rule")
	cursor:set("firewall", "gl_ovpnserver_input", "name", "Allow-OpenVPN-Server")
	cursor:set("firewall", "gl_ovpnserver_input", "src", "wan")
	cursor:set("firewall", "gl_ovpnserver_input", "proto", config.proto)
	cursor:set("firewall", "gl_ovpnserver_input", "dest_port", tostring(config.port))
	cursor:set("firewall", "gl_ovpnserver_input", "target", "ACCEPT")
	cursor:commit("firewall")

	command_ok("/etc/init.d/firewall reload")
	return true
end

local function refresh_if_running(cursor)
	if cursor:get(CONFIG, "global", "enable") == "1" then
		local ok, err = apply_runtime(cursor)
		if ok then command_ok("/etc/init.d/openvpn restart") end
		return ok, err
	end
	return true
end

return {
	get_config = function()
		local cursor = uci.cursor()
		return vpn_config(cursor)
	end,

	set_config = function(args)
		args = args or {}
		if args.mode == "tap" then
			return { err_code = 1, err_msg = "TAP (bridged) mode is not supported on this build" }
		end
		if type(args.subnetv4) ~= "string" or not args.subnetv4:match("^%d+%.%d+%.%d+%.%d+$") then
			return { err_code = 1, err_msg = "invalid subnetv4" }
		end
		if type(args.mask) ~= "string" or not args.mask:match("^%d+%.%d+%.%d+%.%d+$") then
			return { err_code = 1, err_msg = "invalid mask" }
		end
		local port = tonumber(args.port)
		if not port or port < 1 or port > 65535 then
			return { err_code = 1, err_msg = "invalid port" }
		end
		if args.proto ~= "udp" and args.proto ~= "tcp" then
			return { err_code = 1, err_msg = "invalid proto" }
		end

		local cursor = uci.cursor()
		if not cursor:get(CONFIG, "vpn") then cursor:set(CONFIG, "vpn", "service") end
		cursor:set(CONFIG, "vpn", "dev_type", "tun")
		cursor:set(CONFIG, "vpn", "subnetv4", args.subnetv4)
		cursor:set(CONFIG, "vpn", "mask", args.mask)
		cursor:set(CONFIG, "vpn", "subnetv6", args.subnetv6 or "")
		cursor:set(CONFIG, "vpn", "start", args.start or "")
		cursor:set(CONFIG, "vpn", "end", args["end"] or "")
		cursor:set(CONFIG, "vpn", "proto", args.proto)
		cursor:set(CONFIG, "vpn", "port", tostring(port))
		cursor:set(CONFIG, "vpn", "client_auth", bool(args.client_auth) and "1" or "0")
		cursor:set(CONFIG, "vpn", "auth", args.auth or "SHA256")
		cursor:set(CONFIG, "vpn", "cipher", args.cipher or "AES-256-GCM")
		cursor:set(CONFIG, "vpn", "comp", bool(args.lzo) and "lzo" or "")
		cursor:set(CONFIG, "vpn", "hmac", bool(args.hmac) and "1" or "0")
		if type(args.ta) == "string" then cursor:set(CONFIG, "vpn", "ta", args.ta) end
		cursor:set(CONFIG, "vpn", "client_to_client", bool(args.client_to_client) and "1" or "0")
		cursor:set(CONFIG, "vpn", "verb", tostring(args.verb or "3"))
		cursor:commit(CONFIG)

		local ok, err = refresh_if_running(cursor)
		if not ok then return { err_code = 1, err_msg = err } end
		return {}
	end,

	get_setting = function()
		local cursor = uci.cursor()
		return {
			enable = cursor:get(CONFIG, "global", "enable") == "1",
			access = cursor:get(CONFIG, "global", "access") or "DROP",
			access_scope = tonumber((cursor:get(CONFIG, "vpn", "access_scope"))) or 1,
			masq = cursor:get(CONFIG, "global", "masq") ~= "0",
		}
	end,

	set_setting = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if not cursor:get(CONFIG, "global") then cursor:set(CONFIG, "global", "general") end
		if args.enable ~= nil then
			if bool(args.enable) and not initialized(cursor) then
				return { err_code = 1, err_msg = "generate a certificate first" }
			end
			cursor:set(CONFIG, "global", "enable", bool(args.enable) and "1" or "0")
		end
		if args.access == "ACCEPT" or args.access == "DROP" then
			cursor:set(CONFIG, "global", "access", args.access)
		end
		cursor:set(CONFIG, "global", "masq", bool(args.masq) and "1" or "0")
		if not cursor:get(CONFIG, "vpn") then cursor:set(CONFIG, "vpn", "service") end
		if args.access_scope then
			cursor:set(CONFIG, "vpn", "access_scope", tostring(tonumber(args.access_scope) or 1))
		end
		cursor:commit(CONFIG)

		if cursor:get(CONFIG, "global", "enable") == "1" then
			local ok, err = apply_runtime(cursor)
			if not ok then return { err_code = 1, err_msg = err } end
			command_ok("/etc/init.d/openvpn restart")
		else
			cursor:delete("openvpn", IFACE)
			cursor:commit("openvpn")
			command_ok("/etc/init.d/openvpn restart")
		end
		return {}
	end,

	-- Self-signed CA + server cert, ECDSA P-256, `dh none` (modern
	-- OpenVPN/OpenSSL negotiate ECDHE without a slow classic dhparam
	-- generation step - meaningful on embedded ARM hardware).
	generate_certificate = function()
		command_ok("mkdir -p " .. CERT_DIR)
		local host = command_output("uname -n")
		if host == "" then host = "GL-XE3000" end

		local function write_ext(name, key_usage)
			local file = io.open(CERT_DIR .. "/" .. name, "w")
			if not file then return false end
			file:write("extendedKeyUsage=" .. key_usage .. "\n")
			file:close()
			return true
		end

		local ok = command_ok("openssl ecparam -name prime256v1 -genkey -noout -out " ..
			CERT_DIR .. "/ca.key")
		ok = ok and command_ok(string.format(
			"openssl req -x509 -new -key %s/ca.key -sha256 -days 3650 -subj '/CN=%s VPN CA' -out %s/ca.crt",
			CERT_DIR, host, CERT_DIR))
		ok = ok and command_ok("openssl ecparam -name prime256v1 -genkey -noout -out " ..
			CERT_DIR .. "/server.key")
		ok = ok and command_ok(string.format(
			"openssl req -new -key %s/server.key -subj '/CN=%s' -out %s/server.csr",
			CERT_DIR, host, CERT_DIR))
		ok = ok and write_ext("server.ext", "serverAuth")
		ok = ok and command_ok(string.format(
			"openssl x509 -req -in %s/server.csr -CA %s/ca.crt -CAkey %s/ca.key -CAcreateserial " ..
			"-out %s/server.crt -days 3650 -sha256 -extfile %s/server.ext",
			CERT_DIR, CERT_DIR, CERT_DIR, CERT_DIR, CERT_DIR))
		-- Shared client identity for the exported bundle, signed by the
		-- same CA - only needed when client_auth=0 (no username/password).
		ok = ok and command_ok("openssl ecparam -name prime256v1 -genkey -noout -out " ..
			CERT_DIR .. "/client.key")
		ok = ok and command_ok(string.format(
			"openssl req -new -key %s/client.key -subj '/CN=%s client' -out %s/client.csr",
			CERT_DIR, host, CERT_DIR))
		ok = ok and write_ext("client.ext", "clientAuth")
		ok = ok and command_ok(string.format(
			"openssl x509 -req -in %s/client.csr -CA %s/ca.crt -CAkey %s/ca.key -CAcreateserial " ..
			"-out %s/client.crt -days 3650 -sha256 -extfile %s/client.ext",
			CERT_DIR, CERT_DIR, CERT_DIR, CERT_DIR, CERT_DIR))
		command_ok("rm -f " .. CERT_DIR .. "/server.csr " .. CERT_DIR .. "/client.csr")

		if not ok or not initialized(uci.cursor()) then
			return { err_code = 1, err_msg = "certificate generation failed - is openssl-util installed?" }
		end
		return {}
	end,

	get_user_list = function()
		local cursor = uci.cursor()
		local users = {}
		for _, user in ipairs(user_sections(cursor)) do
			users[#users + 1] = { username = user.username or "" }
		end
		return { users = as_array(users) }
	end,

	add_user = function(args)
		args = args or {}
		if type(args.username) ~= "string" or args.username == ""
			or not args.username:match("^[%w_%-%.]+$") then
			return { err_code = 1, err_msg = "invalid username" }
		end
		if type(args.password) ~= "string" or #args.password < 4 then
			return { err_code = 1, err_msg = "password too short" }
		end
		local cursor = uci.cursor()
		if user_by_name(cursor, args.username) then
			return { err_code = 1, err_msg = "user already exists" }
		end
		local id = "u_" .. new_id()
		cursor:set(CONFIG, id, "user")
		cursor:set(CONFIG, id, "username", args.username)
		cursor:set(CONFIG, id, "password_hash", sha256(args.password))
		cursor:commit(CONFIG)
		return {}
	end,

	remove_user = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local user = user_by_name(cursor, args.username)
		if not user then return { err_code = 1, err_msg = "user not found" } end
		cursor:delete(CONFIG, user[".name"])
		cursor:commit(CONFIG)
		return {}
	end,

	-- Writes the downloadable client bundle to disk; the frontend then
	-- fetches it via a separate plain POST to /download (oui-download.lua)
	-- - RPC responses can't carry a browser file download.
	export_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if not initialized(cursor) then
			return { err_code = 1, err_msg = "generate a certificate first" }
		end
		local address = (type(args.address) == "table" and args.address[1]) or args.address
		if type(address) ~= "string" or address == "" then
			return { err_code = 1, err_msg = "missing address" }
		end
		local config = vpn_config(cursor)
		local client_auth = cursor:get(CONFIG, "vpn", "client_auth") == "1"

		local lines = {
			"client",
			"dev tun",
			"proto " .. config.proto,
			"remote " .. address .. " " .. tostring(config.port),
			"resolv-retry infinite",
			"nobind",
			"persist-key",
			"persist-tun",
			"remote-cert-tls server",
			"cipher " .. config.cipher,
			"auth " .. config.auth,
			"verb 3",
		}
		if client_auth then
			lines[#lines + 1] = "auth-user-pass"
		end
		lines[#lines + 1] = "<ca>"
		lines[#lines + 1] = (read_file(CERT_DIR .. "/ca.crt") or ""):gsub("%s+$", "")
		lines[#lines + 1] = "</ca>"
		if not client_auth then
			lines[#lines + 1] = "<cert>"
			lines[#lines + 1] = (read_file(CERT_DIR .. "/client.crt") or ""):gsub("%s+$", "")
			lines[#lines + 1] = "</cert>"
			lines[#lines + 1] = "<key>"
			lines[#lines + 1] = (read_file(CERT_DIR .. "/client.key") or ""):gsub("%s+$", "")
			lines[#lines + 1] = "</key>"
		end

		command_ok("mkdir -p " .. EXPORT_DIR)
		local file = io.open(EXPORT_FILE, "w")
		if not file then
			return { err_code = 1, err_msg = "failed to write export file" }
		end
		file:write(table.concat(lines, "\n") .. "\n")
		file:close()
		return {}
	end,
}
