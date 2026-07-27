-- GL SDK4 AdGuard Home page adapter using OpenWrt's maintained AdGuard Home
-- package.  AdGuard listens on 3053 for DNS and 3000 for its own settings
-- UI; dnsmasq remains the router-facing resolver unless direct client
-- handling is explicitly selected in the GL page.

local uci = require "uci"

local function first_section(cursor, config, stype)
	local result
	cursor:foreach(config, stype, function(s)
		if not result then result = s[".name"] end
	end)
	return result
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
end

local function backup_dnsmasq(cursor, section)
	if cursor:get("dhcp", section, "gl_agh_backed_up") == "1" then return end
	local servers = cursor:get_list("dhcp", section, "server") or {}
	cursor:delete("dhcp", section, "gl_agh_server_backup")
	for _, server in ipairs(servers) do
		cursor:add_list("dhcp", section, "gl_agh_server_backup", server)
	end
	cursor:set("dhcp", section, "gl_agh_noresolv_backup",
		cursor:get("dhcp", section, "noresolv") or "")
	cursor:set("dhcp", section, "gl_agh_cachesize_backup",
		cursor:get("dhcp", section, "cachesize") or "")
	cursor:set("dhcp", section, "gl_agh_backed_up", "1")
end

local function enable_dnsmasq_upstream(cursor, section)
	backup_dnsmasq(cursor, section)
	cursor:delete("dhcp", section, "server")
	cursor:add_list("dhcp", section, "server", "127.0.0.1#3053")
	cursor:set("dhcp", section, "noresolv", "1")
end

local function restore_dnsmasq(cursor, section)
	if cursor:get("dhcp", section, "gl_agh_backed_up") ~= "1" then return end
	local servers = cursor:get_list("dhcp", section, "gl_agh_server_backup") or {}
	cursor:delete("dhcp", section, "server")
	for _, server in ipairs(servers) do cursor:add_list("dhcp", section, "server", server) end
	for option, backup in pairs({
		noresolv = "gl_agh_noresolv_backup",
		cachesize = "gl_agh_cachesize_backup",
	}) do
		local value = cursor:get("dhcp", section, backup)
		if value and value ~= "" then cursor:set("dhcp", section, option, value)
		else cursor:delete("dhcp", section, option) end
	end
	for _, option in ipairs({
		"gl_agh_server_backup", "gl_agh_noresolv_backup",
		"gl_agh_cachesize_backup", "gl_agh_backed_up",
	}) do cursor:delete("dhcp", section, option) end
end

local function configure_direct_dns(cursor, enabled)
	for _, section in ipairs({ "gl_agh_dns_udp", "gl_agh_dns_tcp" }) do
		cursor:delete("firewall", section)
	end
	if enabled then
		local lan_ip = cursor:get("network", "lan", "ipaddr") or "192.168.8.1"
		for _, proto in ipairs({ "udp", "tcp" }) do
			cursor:section("firewall", "redirect", "gl_agh_dns_" .. proto, {
				name = "AdGuard Home direct DNS " .. proto:upper(),
				src = "lan",
				proto = proto,
				src_dport = "53",
				dest_ip = lan_ip,
				dest_port = "3053",
				target = "DNAT",
			})
		end
	end
	cursor:commit("firewall")
	command_ok("/etc/init.d/firewall reload")
end

return {
	get_config = function()
		local cursor = uci.cursor()
		return {
			enabled = cursor:get("adguardhome", "config", "enabled") == "1",
			dns_enabled = cursor:get("adguardhome", "config", "dns_enabled") == "1",
		}
	end,

	set_config = function(args)
		args = args or {}
		if type(args.enabled) ~= "boolean" then
			return { code = 1, message = "enabled must be boolean" }
		end
		if args.enabled and type(args.dns_enabled) ~= "boolean" then
			return { code = 1, message = "dns_enabled must be boolean" }
		end

		local cursor = uci.cursor()
		local dnsmasq = first_section(cursor, "dhcp", "dnsmasq")
		if not dnsmasq then return { err_code = -1, err_msg = "dnsmasq not found" } end

		if args.enabled then
			cursor:set("adguardhome", "config", "enabled", "1")
			cursor:set("adguardhome", "config", "dns_enabled",
				args.dns_enabled and "1" or "0")
			cursor:commit("adguardhome")
			enable_dnsmasq_upstream(cursor, dnsmasq)
			cursor:commit("dhcp")
			command_ok("/etc/init.d/adguardhome enable")
			command_ok("/etc/init.d/adguardhome restart")
			configure_direct_dns(cursor, args.dns_enabled)
		else
			cursor:set("adguardhome", "config", "enabled", "0")
			cursor:set("adguardhome", "config", "dns_enabled", "0")
			cursor:commit("adguardhome")
			restore_dnsmasq(cursor, dnsmasq)
			cursor:commit("dhcp")
			configure_direct_dns(cursor, false)
			command_ok("/etc/init.d/adguardhome stop")
			command_ok("/etc/init.d/adguardhome disable")
		end
		command_ok("/etc/init.d/dnsmasq restart")
		return {}
	end,
}
