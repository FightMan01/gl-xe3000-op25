-- "dns" RPC object: DNS mode + per-host overrides.

local uci = require "uci"

return {
	get_config = function(args)
		local cursor = uci.cursor()
		local servers = {}
		cursor:foreach("dhcp", "dnsmasq", function(s)
			for _, srv in ipairs(s.server or {}) do
				table.insert(servers, srv)
			end
		end)
		return { mode = (#servers > 0) and "custom" or "auto", servers = servers }
	end,

	set_config = function(args)
		local cursor = uci.cursor()
		cursor:foreach("dhcp", "dnsmasq", function(s)
			cursor:delete("dhcp", s[".name"], "server")
			if args.mode == "custom" and type(args.servers) == "table" then
				cursor:set("dhcp", s[".name"], "server", args.servers)
			end
		end)
		cursor:commit("dhcp")
		os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
		return {}
	end,

	get_info = function(args)
		local cursor = uci.cursor()
		return {
			local_domain = cursor:get("dhcp", "@dnsmasq[0]", "domain"),
			cache_size = tonumber((cursor:get("dhcp", "@dnsmasq[0]", "cachesize"))),
		}
	end,

	-- Per-host DNS overrides, backed by dnsmasq's UCI `config domain`
	-- sections (name+ip -> a static A record, same mechanism LuCI's own
	-- "Hostnames" tab uses).
	get_host = function(args)
		local cursor = uci.cursor()
		local hosts = {}
		cursor:foreach("dhcp", "domain", function(s)
			table.insert(hosts, { id = s[".name"], name = s.name, ip = s.ip })
		end)
		return { hosts = hosts }
	end,

	-- args.id (optional, edits existing), args.name, args.ip.
	set_host = function(args)
		if type(args.name) ~= "string" or type(args.ip) ~= "string" then
			return { code = 1, message = "missing name/ip" }
		end
		local cursor = uci.cursor()
		local id = args.id
		if not id or not cursor:get("dhcp", id) then
			id = cursor:add("dhcp", "domain")
		end
		cursor:set("dhcp", id, "name", args.name)
		cursor:set("dhcp", id, "ip", args.ip)
		cursor:commit("dhcp")
		os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
		return { id = id }
	end,
}
