-- "dns" RPC object for the GL.iNet 4.11 DNS page.
--
-- get_config/set_config cover the three modes the page exposes:
--   auto   - use the resolvers handed out by the active WAN interfaces
--   manual - dnsmasq forwards to a user-supplied static server list
--   secure - dnsproxy/dnscrypt-proxy sits in front of dnsmasq
--
-- get_wan_config/get_vpn_dns feed the two informational cards. The 4.11
-- page polls them every ten seconds, so they must stay cheap: both only
-- read /tmp/resolv.conf.d and UCI, never touch the network.
--
-- The provider catalogue is the same JSON currently shipped under
-- /etc/dnsproxy/provider by GL's own package. get_info merges those files
-- into the array the page's provider picker expects.

local uci = require "uci"
local cjson = require "cjson"

local PROVIDER_DIR = "/etc/dnsproxy/provider/"
local PROVIDER_ORDER = {
	"controld", "nextdns", "quad9", "cleanbrowsing",
	"cloudflare", "adguard_dns", "google_dns", "opendns", "manual",
}
local SECURE_PROTOCOLS = {
	dot = true, doh = true, doq = true, odoh = true, dnscrypt = true,
}
local MANUAL_PROTOCOLS = { dot = true, doh = true, doq = true }
local DNSPROXY_CONFIG = "/etc/dnsproxy/dnsproxy.yaml"
local DNSCRYPT_CONFIG = "/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
local HOSTS_FILE = "/etc/hosts"
local MAX_HOSTS_CONTENT_LEN = 65535

local function as_array(value)
	if type(value) ~= "table" or next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function as_bool(value)
	return value == "1" or value == 1 or value == true
end

local function as_list(value)
	if type(value) == "table" then
		return value
	end
	if value == nil or value == "" then
		return {}
	end
	return { value }
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file(path, data)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local function service_exists(name)
	local f = io.open("/etc/init.d/" .. name, "r")
	if f then f:close() return true end
	return false
end

local function command_exists(name)
	local p = io.popen("command -v " .. name .. " 2>/dev/null")
	if not p then return false end
	local out = p:read("*l")
	p:close()
	return out ~= nil and out ~= ""
end

local function run(command)
	os.execute(command .. " >/dev/null 2>&1")
end

local function first_section(cursor, config, stype)
	local section
	cursor:foreach(config, stype, function(s)
		if not section then section = s[".name"] end
	end)
	return section
end

local function dnsmasq_section(cursor)
	local section = first_section(cursor, "dhcp", "dnsmasq")
	if not section then
		section = "dnsmasq"
	end
	return section
end

local function gl_dns_section(cursor)
	local section
	cursor:foreach("gl-dns-v2", "dns", function(s)
		if not section then section = s[".name"] end
	end)
	if not section then
		section = "dns"
		cursor:set("gl-dns-v2", section, "dns")
	end
	return section
end

local function normalize_manual_server(value)
	value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then return nil end
	local ip, port = value:match("^([^#]+)#(.+)$")
	if ip then
		if not (ip:match("^%d+%.%d+%.%d+%.%d+$") or ip:find(":", 1, true)) then
			return nil, "invalid manual dns ip: " .. ip
		end
		if not port:match("^%d+$") or tonumber(port) < 1 or tonumber(port) > 65535 then
			return nil, "invalid manual dns port: " .. port
		end
		return ip .. "#" .. port
	end
	if not (value:match("^%d+%.%d+%.%d+%.%d+$") or value:find(":", 1, true)) then
		return nil, "invalid manual dns format: " .. value
	end
	return value
end

local function read_provider(name)
	local data = read_file(PROVIDER_DIR .. name)
	if not data then return nil end
	local ok, decoded = pcall(cjson.decode, data)
	if not ok or type(decoded) ~= "table" then return nil end
	return decoded
end

local function provider_catalogue(cursor)
	local providers = {}
	for _, name in ipairs(PROVIDER_ORDER) do
		if name == "nextdns" then
			providers[#providers + 1] = {
				provider = "nextdns",
				sup_proto = { "dot", "doh", "doq" },
			}
		elseif name == "manual" then
			local section = gl_dns_section(cursor)
			local secure = as_list(cursor:get("gl-dns-v2", section, "secure_manual_list"))
			providers[#providers + 1] = {
				provider = "manual",
				proto_manual = cursor:get("gl-dns-v2", section, "proto_manual") or "",
				secure_manual_list = as_array(secure),
				sup_proto = { "dot", "doh", "doq", "odoh", "dnscrypt" },
			}
		else
			local provider = read_provider(name)
			if provider then
				providers[#providers + 1] = provider
			end
		end
	end
	return providers
end

local function provider_server(provider_name, server_name)
	local provider = read_provider(provider_name)
	if not provider then return nil end
	for _, server in ipairs(provider.server_list or {}) do
		if server.name == server_name then
			return server
		end
	end
	return nil
end

local function resolv_path(cursor)
	local section = dnsmasq_section(cursor)
	return cursor:get("dhcp", section, "resolvfile")
		or "/tmp/resolv.conf.d/resolv.conf.auto"
end

local function map_wan_iface(iface)
	-- The 4.11 page groups by its own interface families (wan/wwan/modem/
	-- tethering). OpenWrt's qcm proto exposes the cellular child as
	-- wwan_4/wwan_6, which the page would otherwise ignore.
	if iface:match("^wwan") or iface:match("^rmnet") then
		return iface:match("6$") and "modem6" or "modem"
	end
	return iface
end

local function parse_resolv_by_interface(path)
	local result = {}
	local current
	local f = io.open(path, "r")
	if not f then return result end
	for line in f:lines() do
		local iface = line:match("^#%s*Interface%s+(%S+)")
		if iface then
			current = map_wan_iface(iface)
			result[current] = result[current] or {}
		elseif current then
			local server = line:match("^%s*nameserver%s+(%S+)")
			if server then
				result[current][#result[current] + 1] = server
			end
		end
	end
	f:close()
	return result
end

local function secure_upstreams(cursor, args)
	local provider = args.provider
	local proto = args.proto
	if not provider or not SECURE_PROTOCOLS[proto] then
		return nil, "invalid provider or protocol"
	end
	if provider == "nextdns" then
		local id = tostring(args.nextdns_id or "")
		if not id:match("^[a-zA-Z0-9_-]+$") then
			return nil, "Invalid Resolver ID"
		end
		if proto == "doh" then
			return { "https://dns.nextdns.io/" .. id }
		elseif proto == "doq" then
			return { "quic://" .. id .. ".dns.nextdns.io" }
		end
		return { "tls://" .. id .. ".dns.nextdns.io" }
	end
	if provider == "controld" then
		local id = tostring(args.controld_id or "")
		if id == "" then id = "p0" end
		if not id:match("^[a-zA-Z0-9_-]+$") then
			return nil, "Invalid Resolver ID"
		end
		if proto == "doh" then
			return { "https://dns.controld.com/" .. id }
		elseif proto == "doq" then
			return { "quic://" .. id .. ".dns.controld.com" }
		end
		return { "tls://" .. id .. ".dns.controld.com" }
	end
	if provider == "manual" then
		local list = as_list(args.secure_manual_list)
		if #list == 0 then
			return nil, "secure manual list is empty"
		end
		local urls = {}
		for _, value in ipairs(list) do
			value = tostring(value)
			if SECURE_PROTOCOLS[proto] and not value:find("[%c%s]") then
				urls[#urls + 1] = value
			else
				return nil, "invalid secure manual entry"
			end
		end
		return urls
	end
	local names = as_list(args.servers_list)
	if #names == 0 then
		return nil, "servers_list is empty"
	end
	local urls = {}
	for _, name in ipairs(names) do
		local server = provider_server(provider, name)
		if not server then
			return nil, "secure servers not found"
		end
		local url = (proto == "doh" and server.url_doh)
			or (proto == "doq" and server.url_doq)
			or server.url_dot
		if not url then
			return nil, "protocol not supported"
		end
		urls[#urls + 1] = url
	end
	return urls
end

local function configure_dnsproxy(cursor, urls)
	-- OpenWrt's dnsproxy package is driven by UCI, not GL's YAML file:
	-- /etc/init.d/dnsproxy translates these lists into --upstream/--listen
	-- arguments. Keep the section names it expects.
	cursor:set("dnsproxy", "global", "dnsproxy")
	cursor:set("dnsproxy", "global", "enabled", "1")
	cursor:set("dnsproxy", "global", "listen_addr", { "127.0.0.1" })
	cursor:set("dnsproxy", "global", "listen_port", { "5453" })
	cursor:set("dnsproxy", "servers", "dnsproxy")
	cursor:set("dnsproxy", "servers", "upstream", urls)
	cursor:set("dnsproxy", "servers", "bootstrap", { "8.8.8.8:53", "1.1.1.1:53" })
	return cursor:commit("dnsproxy")
end

local function stop_dnsproxy(cursor)
	if not service_exists("dnsproxy") then return end
	cursor:set("dnsproxy", "global", "dnsproxy")
	cursor:set("dnsproxy", "global", "enabled", "0")
	cursor:commit("dnsproxy")
	run("/etc/init.d/dnsproxy stop")
end

local function apply_auto(cursor)
	local section = dnsmasq_section(cursor)
	cursor:delete("dhcp", section, "server")
	cursor:delete("dhcp", section, "noresolv")
	cursor:delete("dhcp", section, "boguspriv")
	cursor:delete("dhcp", section, "cachesize")
	stop_dnsproxy(cursor)
	if service_exists("dnscrypt-proxy") then run("/etc/init.d/dnscrypt-proxy stop") end
	run("ln -sf " .. resolv_path(cursor) .. " /tmp/resolv.conf")
end

local function apply_manual(cursor, servers)
	local section = dnsmasq_section(cursor)
	cursor:delete("dhcp", section, "server")
	cursor:delete("dhcp", section, "boguspriv")
	cursor:delete("dhcp", section, "cachesize")
	cursor:set("dhcp", section, "server", servers)
	cursor:set("dhcp", section, "noresolv", "1")
	stop_dnsproxy(cursor)
	if service_exists("dnscrypt-proxy") then run("/etc/init.d/dnscrypt-proxy stop") end
end

local function apply_secure(cursor, urls)
	local section = dnsmasq_section(cursor)
	if not command_exists("dnsproxy") or not service_exists("dnsproxy") then
		return false, "dnsproxy is not installed"
	end
	if not configure_dnsproxy(cursor, urls) then
		return false, "cannot write dnsproxy configuration"
	end
	cursor:delete("dhcp", section, "boguspriv")
	cursor:delete("dhcp", section, "cachesize")
	cursor:set("dhcp", section, "server", { "127.0.0.1#5453" })
	cursor:set("dhcp", section, "noresolv", "1")
	return true
end

local function restart_dnsmasq()
	if service_exists("dnsmasq") then
		run("/etc/init.d/dnsmasq restart")
	end
end

return {
	get_config = function()
		local cursor = uci.cursor()
		local section = gl_dns_section(cursor)
		local ds = dnsmasq_section(cursor)
		local mode = cursor:get("gl-dns-v2", section, "mode") or "auto"
		return {
			mode = mode,
			manual_enable = as_bool(cursor:get("gl-dns-v2", section, "manual_enable")),
			manual_type = cursor:get("gl-dns-v2", section, "manual_type") or "manual",
			manual_list = as_array(as_list(cursor:get("gl-dns-v2", section, "manual_list"))),
			manual_local_dns = as_bool(cursor:get("gl-dns-v2", section, "manual_local_dns")),
			override_vpn = as_bool(cursor:get("gl-dns-v2", section, "override_vpn")),
			force_dns = as_bool(cursor:get("gl-dns-v2", section, "force_dns")),
			provider = cursor:get("gl-dns-v2", section, "provider") or "",
			proto = cursor:get("gl-dns-v2", section, "proto") or "",
			proto_manual = cursor:get("gl-dns-v2", section, "proto_manual") or "",
			servers_list = as_array(as_list(cursor:get("gl-dns-v2", section, "servers_list"))),
			secure_manual_list = as_array(as_list(cursor:get("gl-dns-v2", section, "secure_manual_list"))),
			proxy_list = as_array(as_list(cursor:get("gl-dns-v2", section, "proxy_list"))),
			nextdns_id = cursor:get("gl-dns-v2", section, "nextdns_id") or "",
			controld_id = cursor:get("gl-dns-v2", section, "controld_id") or "",
			controld_type = tonumber((cursor:get("gl-dns-v2", section, "controld_type"))) or 1,
			rebind_protection = cursor:get("dhcp", ds, "rebind_protection") ~= "0",
		}
	end,

	set_config = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local section = gl_dns_section(cursor)
		local ds = dnsmasq_section(cursor)

		for _, key in ipairs({ "force_dns", "override_vpn", "rebind_protection", "manual_local_dns" }) do
			if args[key] ~= nil and type(args[key]) ~= "boolean" then
				return { code = -5, message = "invalid " .. key }
			end
		end

		local mode = args.mode or cursor:get("gl-dns-v2", section, "mode") or "auto"
		if mode ~= "auto" and mode ~= "manual" and mode ~= "secure" then
			return { code = -5, message = "invalid mode" }
		end

		local adguard = first_section(cursor, "adguardhome", "config")
		if adguard and cursor:get("adguardhome", adguard, "enabled") == "1" and mode ~= "auto" then
			return { code = -4, message = "Dns Busy. Occupied by adguardhome" }
		end

		local manual_servers = {}
		if mode == "manual" then
			for _, value in ipairs(as_list(args.manual_list)) do
				local server, err = normalize_manual_server(value)
				if not server then return { code = -5, message = err } end
				manual_servers[#manual_servers + 1] = server
			end
			if #manual_servers == 0 then
				return { code = -5, message = "manual_list is empty" }
			end
		end

		local secure_urls
		if mode == "secure" then
			local provider = args.provider or cursor:get("gl-dns-v2", section, "provider")
			local proto = args.proto or cursor:get("gl-dns-v2", section, "proto")
			local merged = {
				provider = provider,
				proto = proto,
				nextdns_id = args.nextdns_id or cursor:get("gl-dns-v2", section, "nextdns_id"),
				controld_id = args.controld_id or cursor:get("gl-dns-v2", section, "controld_id"),
				servers_list = args.servers_list or cursor:get("gl-dns-v2", section, "servers_list"),
				secure_manual_list = args.secure_manual_list or cursor:get("gl-dns-v2", section, "secure_manual_list"),
			}
			local err
			secure_urls, err = secure_upstreams(cursor, merged)
			if not secure_urls then
				return { code = -5, message = err or "invalid secure configuration" }
			end
		end

		cursor:set("gl-dns-v2", section, "mode", mode)
		cursor:set("gl-dns-v2", section, "manual_enable", (mode == "auto") and "0" or "1")
		cursor:set("gl-dns-v2", section, "manual_type", (mode == "secure") and "secure" or "manual")
		if mode == "manual" then
			cursor:set("gl-dns-v2", section, "manual_list", manual_servers)
		end
		if args.provider ~= nil then cursor:set("gl-dns-v2", section, "provider", args.provider) end
		if args.proto ~= nil then cursor:set("gl-dns-v2", section, "proto", args.proto) end
		if args.proto_manual ~= nil then cursor:set("gl-dns-v2", section, "proto_manual", args.proto_manual) end
		if args.nextdns_id ~= nil then cursor:set("gl-dns-v2", section, "nextdns_id", args.nextdns_id) end
		if args.controld_id ~= nil then cursor:set("gl-dns-v2", section, "controld_id", args.controld_id) end
		if args.controld_type ~= nil then cursor:set("gl-dns-v2", section, "controld_type", tostring(args.controld_type)) end
		if args.servers_list ~= nil then cursor:set("gl-dns-v2", section, "servers_list", args.servers_list) end
		if args.secure_manual_list ~= nil then cursor:set("gl-dns-v2", section, "secure_manual_list", args.secure_manual_list) end
		cursor:set("gl-dns-v2", section, "manual_local_dns",
			(args.manual_local_dns ~= nil) and (args.manual_local_dns and "1" or "0")
			or (cursor:get("gl-dns-v2", section, "manual_local_dns") or "0"))
		cursor:set("gl-dns-v2", section, "override_vpn",
			(args.override_vpn ~= nil) and (args.override_vpn and "1" or "0")
			or (cursor:get("gl-dns-v2", section, "override_vpn") or "0"))
		cursor:set("gl-dns-v2", section, "force_dns",
			(args.force_dns ~= nil) and (args.force_dns and "1" or "0")
			or (cursor:get("gl-dns-v2", section, "force_dns") or "0"))
		if args.rebind_protection ~= nil then
			cursor:set("dhcp", ds, "rebind_protection", args.rebind_protection and "1" or "0")
		end
		if args.manual_local_dns ~= nil then
			if args.manual_local_dns then
				cursor:set("dhcp", ds, "localuse", "1")
			else
				cursor:delete("dhcp", ds, "localuse")
			end
		end

		if mode == "auto" then
			apply_auto(cursor)
		elseif mode == "manual" then
			apply_manual(cursor, manual_servers)
		else
			local ok, err = apply_secure(cursor, secure_urls)
			if not ok then
				cursor:commit("dhcp")
				cursor:commit("gl-dns-v2")
				return { code = -4, message = err }
			end
		end

		cursor:commit("gl-dns-v2")
		cursor:commit("dhcp")
		if mode == "secure" and service_exists("dnsproxy") then
			run("/etc/init.d/dnsproxy restart")
		end
		restart_dnsmasq()
		run("nginx -s reload")
		return {}
	end,

	get_info = function()
		return provider_catalogue(uci.cursor())
	end,

	get_wan_config = function()
		local cursor = uci.cursor()
		local by_iface = parse_resolv_by_interface(resolv_path(cursor))
		local list = {}
		for iface, servers in pairs(by_iface) do
			list[#list + 1] = { interface = iface, dns = servers }
		end
		table.sort(list, function(a, b) return a.interface < b.interface end)
		return { wan_dns = as_array(list) }
	end,

	get_vpn_dns = function()
		-- VPN DNS is exposed only when a tunnel advertises its own resolver.
		-- The current port keeps client tunnels in UCI and does not create a
		-- per-tunnel resolv file, so report the honest empty state instead of
		-- inventing a list. The page renders its "no VPN tunnel" card.
		return { vpn_dns = cjson.empty_array }
	end,

	get_host = function()
		local content = read_file(HOSTS_FILE)
		if content == nil then content = "" end
		return { content = content }
	end,

	set_host = function(args)
		args = args or {}
		local content = args.content
		if type(content) ~= "string" then
			return { code = -5, message = "invalid hosts content" }
		end
		if #content > MAX_HOSTS_CONTENT_LEN then
			return { code = -5, message = "hosts content is too long" }
		end
		if not write_file(HOSTS_FILE, content) then
			return { code = -1, message = "cannot write /etc/hosts" }
		end
		restart_dnsmasq()
		return {}
	end,
}
