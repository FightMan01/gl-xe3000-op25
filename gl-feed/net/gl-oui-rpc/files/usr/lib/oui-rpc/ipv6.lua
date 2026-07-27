-- "ipv6" RPC object: IPv6 mode/LAN configuration. Methods are get_ipv6/
-- set_ipv6. Data shape:
--   { enable, lan_mode: "native"|"relay"|"nat6"|"static",
--     lan_dns_mode: bool, lan_dns1, lan_dns2, lan_ip }
-- lan_mode meanings: native = standard routed IPv6, no masquerading;
-- nat6 = NAT66 via the wan zone's masq6; relay = odhcpd relay mode;
-- static = manually assigned LAN prefix. Only native/nat6 are wired to
-- real effect (a masq6 toggle) - relay/static are recorded but not
-- applied yet.

local uci = require "uci"

local function wan_zone_name(cursor)
	local name = nil
	cursor:foreach("firewall", "zone", function(s)
		for _, n in ipairs(s.network or {}) do
			if n == "wan" or n == "wan6" then name = s['.name'] end
		end
	end)
	return name
end

return {
	get_ipv6 = function(args)
		local cursor = uci.cursor()
		local disabled = cursor:get("network", "wan6", "auto") == "0"
		return {
			enable = not disabled,
			lan_mode = cursor:get("gl-oui-rpc", "ipv6", "lan_mode") or "nat6",
			lan_dns_mode = cursor:get("gl-oui-rpc", "ipv6", "lan_dns_mode") ~= "0",
			lan_dns1 = cursor:get("gl-oui-rpc", "ipv6", "lan_dns1"),
			lan_dns2 = cursor:get("gl-oui-rpc", "ipv6", "lan_dns2"),
			lan_ip = cursor:get("gl-oui-rpc", "ipv6", "lan_ip"),
		}
	end,

	set_ipv6 = function(args)
		local cursor = uci.cursor()
		cursor:set("gl-oui-rpc", "ipv6", "ipv6")
		if args.lan_mode then
			cursor:set("gl-oui-rpc", "ipv6", "lan_mode", args.lan_mode)
		end
		if args.lan_dns_mode ~= nil then
			cursor:set("gl-oui-rpc", "ipv6", "lan_dns_mode", args.lan_dns_mode and "1" or "0")
		end
		if args.lan_dns1 then
			cursor:set("gl-oui-rpc", "ipv6", "lan_dns1", args.lan_dns1)
		end
		if args.lan_dns2 then
			cursor:set("gl-oui-rpc", "ipv6", "lan_dns2", args.lan_dns2)
		end
		if args.lan_ip then
			cursor:set("gl-oui-rpc", "ipv6", "lan_ip", args.lan_ip)
		end
		cursor:commit("gl-oui-rpc")

		if cursor:get("network", "wan6") then
			cursor:set("network", "wan6", "auto", args.enable and "1" or "0")
			cursor:commit("network")
		end

		local zone = wan_zone_name(cursor)
		if zone and args.lan_mode then
			cursor:set("firewall", zone, "masq6", args.lan_mode == "nat6" and "1" or "0")
			cursor:commit("firewall")
		end

		os.execute("/etc/init.d/network reload >/dev/null 2>&1")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,
}
