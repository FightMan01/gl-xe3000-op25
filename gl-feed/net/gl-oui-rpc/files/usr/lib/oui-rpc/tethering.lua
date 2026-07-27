-- "tethering" RPC object: USB (phone) tethering. Uses stock USB-net
-- kernel drivers (kmod-usb-net-rndis for Android, kmod-usb-net-ipheth for
-- iPhone), wrapping a netifd "tethering" logical interface bound to
-- whichever usbN device the phone enumerates as.

local uci = require "uci"
local ubus = require "ubus"
local cjson = require "cjson"

return {
	-- devices is a list - the UI is a device-picker over possibly-multiple
	-- attached phones. status 0/1 mirrors not-connected/connected.
	get_status = function(args)
		local conn = ubus.connect()
		local devices = {}
		local connected = false
		if conn then
			local iface = conn:call("network.interface.tethering", "status", {})
			conn:close()
			if iface and iface.up == true then
				connected = true
				local ipv4 = iface["ipv4-address"] and iface["ipv4-address"][1]
				table.insert(devices, {
					device = iface.device,
					ipaddr = ipv4 and ipv4.address,
				})
			end
		end
		-- cjson.empty_array: devices is empty in the (common) no-phone-
		-- attached case - a bare empty Lua table would encode as "{}" and
		-- break the frontend's device-picker .map()/.forEach() over it.
		if next(devices) == nil then devices = cjson.empty_array end
		return { status = connected and 1 or 0, devices = devices }
	end,

	get_config = function(args)
		local cursor = uci.cursor()
		return {
			auto = cursor:get("network", "tethering", "auto") ~= "0",
		}
	end,

	-- args.device: the usbN network device to bind tethering to (the
	-- hotplug script, etc/hotplug.d/usb/20-gl-oui-tethering, already binds
	-- automatically on phone plug-in; this lets the UI explicitly
	-- (re)select among multiple attached devices).
	set_connect = function(args)
		local cursor = uci.cursor()
		if not cursor:get("network", "tethering") then
			cursor:set("network", "tethering", "interface")
		end
		if type(args.device) == "string" and args.device ~= "" then
			cursor:set("network", "tethering", "ifname", args.device)
		end
		cursor:set("network", "tethering", "auto", "1")
		cursor:commit("network")
		os.execute("ifup tethering >/dev/null 2>&1")
		return {}
	end,

	disconnect = function(args)
		local cursor = uci.cursor()
		cursor:set("network", "tethering", "auto", "0")
		cursor:commit("network")
		os.execute("ifdown tethering >/dev/null 2>&1")
		return {}
	end,
}
