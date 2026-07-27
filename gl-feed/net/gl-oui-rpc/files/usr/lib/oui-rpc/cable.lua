-- "cable" RPC object: WAN link/cable diagnostics and port role config.
-- Method set and field shapes match the stock GL.iNet UI/RPC.
--
-- XE3000 has 2 Ethernet ports, no DSA switch, one PHY per port.
-- board.d/02_network sets eth1=LAN, eth0=WAN by default
-- (ucidef_set_interfaces_lan_wan eth1 eth0).

local ubus = require "ubus"
local uci = require "uci"
local cjson = require "cjson"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local PORTS = { "eth0", "eth1" }
local DEFAULT_ROLE = { eth0 = "wan", eth1 = "lan" }

local function wan_l3_device()
	local conn = ubus.connect()
	if not conn then return nil end
	local status = conn:call("network.interface.wan", "status", {})
	conn:close()
	return status
end

local function link_state(devname)
	if not devname or devname == "" then return {} end
	local function read_line(f)
		local fh = io.open("/sys/class/net/" .. devname .. "/" .. f, "r")
		if not fh then return nil end
		local v = fh:read("*l")
		fh:close()
		return v
	end
	return {
		device = devname,
		link_up = read_line("carrier") == "1",
		speed_mbps = tonumber(read_line("speed")),
		duplex = read_line("duplex"),
	}
end

return {
	-- ipv4.ip is CIDR-suffixed (e.g. "37.191.18.218/20"). status/mode are
	-- small integer enums: status 0=down/1=up, mode 0=primary cable.
	-- XE3000 has no second WAN port or USB-WAN uplink, so secondwan/usbwan
	-- are fixed "not present" stubs.
	get_status = function(args)
		local status = wan_l3_device()
		local ipv4 = status and status["ipv4-address"] and status["ipv4-address"][1]
		local cursor = uci.cursor()
		local device = status and (status.l3_device or status.device)
			or cursor:get("network", "wan", "device") or "eth0"
		local link = link_state(device)
		local connected = status and status.up == true or false
		local ip_cidr = nil
		if ipv4 and ipv4.address then
			ip_cidr = ipv4.address .. (ipv4.mask and ("/" .. tostring(ipv4.mask)) or "")
		end
		return {
			protocol = status and status.proto or "dhcp",
			-- Frontend enum: 1=connected, 2=link present/connecting,
			-- 3=no WAN cable. Returning 0 for an unplugged port makes
			-- CableItem render its half-empty protocol/button layout.
			status = connected and 1 or (link.link_up and 2 or 3),
			mode = 0,
			ipv4 = {
				ip = ip_cidr,
				gateway = status and status.route and status.route[1] and status.route[1].nexthop,
				dns = as_array(status and status["dns-server"] or {}),
			},
			secondwan = { status = 0, mode = 1, protocol = "" },
			usbwan = { err_code = -4, err_msg = "Unsupported features!" },
		}
	end,

	get_config = function(args)
		local cursor = uci.cursor()
		return {
			protocol = cursor:get("network", "wan", "proto") or "dhcp",
			ipaddr = cursor:get("network", "wan", "ipaddr"),
			netmask = cursor:get("network", "wan", "netmask"),
			gateway = cursor:get("network", "wan", "gateway"),
			username = cursor:get("network", "wan", "username"),
			mtu = cursor:get("network", "wan", "mtu"),
		}
	end,

	-- args.proto: "dhcp" | "static" | "pppoe" (standard netifd protocols).
	set_config = function(args)
		local cursor = uci.cursor()
		local proto = args.protocol or args.proto
		if proto and proto ~= "dhcp" and proto ~= "static" and proto ~= "pppoe" then
			return { code = 1, message = "unsupported proto" }
		end
		if proto then cursor:set("network", "wan", "proto", proto) end
		if args.ipaddr then cursor:set("network", "wan", "ipaddr", args.ipaddr) end
		if args.netmask then cursor:set("network", "wan", "netmask", args.netmask) end
		if args.gateway then cursor:set("network", "wan", "gateway", args.gateway) end
		if args.username then cursor:set("network", "wan", "username", args.username) end
		if args.password then cursor:set("network", "wan", "password", args.password) end
		if args.mtu then cursor:set("network", "wan", "mtu", tostring(math.floor(tonumber(args.mtu) or 1500))) end
		cursor:commit("network")
		os.execute("ifup wan >/dev/null 2>&1")
		return {}
	end,

	-- Role comes from network.lan/wan's own `device` option. support_wan
	-- is "1" on both ports since either physical port can become the WAN
	-- port here (set_port_config swaps the pair below).
	get_ports_config = function(args)
		local cursor = uci.cursor()
		local lan_dev = cursor:get("network", "lan", "device")
		local wan_dev = cursor:get("network", "wan", "device")
		local NAMES = { eth0 = "wan", eth1 = "lan1" }
		local SILK = { eth0 = "WAN", eth1 = "LAN1" }
		local ports = {}
		for _, p in ipairs(PORTS) do
			local role = (p == lan_dev) and "lan" or (p == wan_dev) and "wan" or DEFAULT_ROLE[p]
			local mac = nil
			local mf = io.open("/sys/class/net/" .. p .. "/address", "r")
			if mf then
				mac = (mf:read("*l") or ""):upper()
				mf:close()
			end
			table.insert(ports, {
				name = NAMES[p] or p,
				mode = role,
				default_mode = DEFAULT_ROLE[p],
				support_wan = "1",
				port_orientation = "up",
				silk = SILK[p] or p:upper(),
				port_group = (role == "wan") and "1" or "2",
				macaddr = { macaddr = mac, defmacaddr = mac, mode = "default", update = "none" },
			})
		end
		return { ports = ports }
	end,

	-- args.port, args.role ("wan"|"lan"). Only one WAN port and one LAN
	-- port exist, so reassigning one means swapping both ports' `device`
	-- assignments between network.lan and network.wan.
	set_port_config = function(args)
		if type(args.port) ~= "string" or (args.role ~= "wan" and args.role ~= "lan") then
			return { code = 1, message = "invalid port/role" }
		end
		local other_port = nil
		for _, p in ipairs(PORTS) do
			if p == args.port then
				-- found
			else
				other_port = other_port or p
			end
		end
		if not other_port then
			return { code = 1, message = "unknown port" }
		end

		local cursor = uci.cursor()
		local other_role = (args.role == "lan") and "wan" or "lan"
		cursor:set("network", args.role, "device", args.port)
		cursor:set("network", other_role, "device", other_port)
		cursor:commit("network")
		os.execute("/etc/init.d/network restart >/dev/null 2>&1")
		return {}
	end,

	-- speed is omitted entirely (not 0/nil) when the link is down. No
	-- VLAN/802.1Q UI here, every port is untagged on VLAN 1 ("Standard").
	get_ports_status = function(args)
		local cursor = uci.cursor()
		local lan_dev = cursor:get("network", "lan", "device")
		local wan_dev = cursor:get("network", "wan", "device")
		local NAMES = { eth0 = "wan", eth1 = "lan1" }
		local ports = {}
		for _, p in ipairs(PORTS) do
			local role = (p == lan_dev) and "lan" or (p == wan_dev) and "wan" or DEFAULT_ROLE[p]
			local link = link_state(p)
			local entry = {
				name = NAMES[p] or p,
				mode = role,
				duplex = link.duplex or "unknown",
				pvid = 1,
				vlan_mode = "Standard",
			}
			if link.link_up and link.speed_mbps then
				entry.speed = link.speed_mbps
			end
			table.insert(ports, entry)
		end
		return { ports = ports }
	end,

	-- Cable-plugged-in / connection-type auto-detect, used by the
	-- setup-wizard flow.
	init_status = function(args)
		local status = wan_l3_device()
		local device = status and (status.l3_device or status.device)
		local link = link_state(device)
		local cursor = uci.cursor()
		return {
			wan = link.link_up or false,
			proto = cursor:get("network", "wan", "proto") or "dhcp",
			internet = status and status.up == true or false,
			lan = true, -- LAN is always statically configured on this device
		}
	end,

	-- Reports "dhcp" if a lease was already obtained, otherwise "unknown"
	-- rather than actively re-probing PPPoE discovery and disrupting an
	-- existing connection.
	wan_proto_detect = function(args)
		local status = wan_l3_device()
		if status and status.proto == "dhcp" and status.up then
			return { proto = "dhcp" }
		end
		return { proto = "unknown" }
	end,
}
