-- "tethering" RPC object: USB (phone) tethering. Uses stock USB-net
-- kernel drivers (kmod-usb-net-rndis for Android, kmod-usb-net-ipheth for
-- iPhone), wrapping a netifd "tethering" logical interface bound to
-- whichever usbN device the phone enumerates as.

local uci = require "uci"
local ubus = require "ubus"
local cjson = require "cjson"

local DRIVER_TYPE = {
	ipheth = 1,
	rndis_host = 0, cdc_ether = 0, cdc_ncm = 0, cdc_eem = 0,
}

-- cjson.empty_array: a bare empty Lua table would encode as "{}" and break
-- the frontend's .map()/.forEach() over the list.
local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local function read_line(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local v = fh:read("*l")
	fh:close()
	return v
end

local function phone_devices(current)
	local devices = {}
	local p = io.popen("for d in /sys/class/net/*; do echo \"${d##*/} $(readlink $d/device/driver)\"; done 2>/dev/null")
	if not p then return devices end
	for line in p:lines() do
		local name, driver = line:match("^(%S+) .-([^/]+)$")
		if name and DRIVER_TYPE[driver] then
			table.insert(devices, {
				device = name,
				type = DRIVER_TYPE[driver],
				manufacturer = read_line("/sys/class/net/" .. name .. "/device/../manufacturer"),
				use = name == current,
			})
		end
	end
	p:close()
	return devices
end

local function default_gateway(status, target)
	for _, r in ipairs(status.route or {}) do
		if r.target == target and r.mask == 0 then return r.nexthop end
	end
end

local function addr_info(status, key, target)
	if not status or status.up ~= true then return nil end
	local a = status[key] and status[key][1]
	if not a then return nil end
	return {
		ip = a.address .. (a.mask and ("/" .. a.mask) or ""),
		gateway = default_gateway(status, target),
		dns = as_array(status["dns-server"] or {}),
	}
end

return {
	-- Same shape as stock: status 0 = not connected, 1 = connected,
	-- 2 = connecting; devices lists every attached phone netdev with
	-- type 0 = Android, 1 = iOS, and use = bound to the tethering interface.
	-- The card fills its info rows from ipv4/ipv6 {ip, gateway, dns}.
	get_status = function(args)
		local cursor = uci.cursor()
		local current = cursor:get("network", "tethering", "device")
		local auto = cursor:get("network", "tethering", "auto") ~= "0"
		local devices = phone_devices(current)

		local iface, iface6
		local conn = ubus.connect()
		if conn then
			iface = conn:call("network.interface.tethering", "status", {})
			iface6 = conn:call("network.interface.tethering6", "status", {})
			conn:close()
		end

		local present = false
		for _, d in ipairs(devices) do
			if d.use then present = true end
		end

		local status = 0
		if iface and iface.up == true then
			status = 1
		elseif auto and present then
			status = 2
		end

		return {
			status = status,
			devices = as_array(devices),
			ipv4 = addr_info(iface, "ipv4-address", "0.0.0.0"),
			ipv6 = addr_info(iface6, "ipv6-address", "::"),
		}
	end,

	get_config = function(args)
		local cursor = uci.cursor()
		return {
			auto = cursor:get("network", "tethering", "auto") ~= "0",
			device = cursor:get("network", "tethering", "device") or "",
			mtu = tonumber((cursor:get("network", "tethering", "mtu"))),
		}
	end,

	-- args.device: the usbN network device to bind tethering to (the
	-- hotplug script, etc/hotplug.d/net/20-gl-oui-tethering, already binds
	-- automatically on phone plug-in; this lets the UI explicitly
	-- (re)select among multiple attached devices).
	set_connect = function(args)
		local cursor = uci.cursor()
		if not cursor:get("network", "tethering") then
			cursor:set("network", "tethering", "interface")
		end
		if type(args.device) == "string" and args.device ~= "" then
			cursor:set("network", "tethering", "device", args.device)
		end
		cursor:set("network", "tethering", "auto", "1")
		if cursor:get("network", "tethering6") then
			cursor:set("network", "tethering6", "auto", "1")
		end
		cursor:commit("network")
		os.execute("ifup tethering >/dev/null 2>&1; ifup tethering6 >/dev/null 2>&1")
		return {}
	end,

	disconnect = function(args)
		local cursor = uci.cursor()
		cursor:set("network", "tethering", "auto", "0")
		if cursor:get("network", "tethering6") then
			cursor:set("network", "tethering6", "auto", "0")
		end
		cursor:commit("network")
		os.execute("ifdown tethering6 >/dev/null 2>&1; ifdown tethering >/dev/null 2>&1")
		return {}
	end,
}
