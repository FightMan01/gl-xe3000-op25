-- "mesh" RPC object for the GL.iNet 4.11 EasyMesh page.
--
-- The mesh engine is OpenWrt's upstream prplmesh package (the same prpl
-- Foundation implementation GL's firmware is built on). Everything this
-- module writes is derived from the running UCI/ubus state: the front-haul
-- BSS interfaces, their SSID/key/encryption, the LAN bridge and the radio
-- mapping. There are no board-specific interface names or credentials here.
--
-- Mesh and repeater both want the station side of a radio. Starting both is
-- a configuration error, so set_config refuses while a STA interface or the
-- repeater service is active. The boot guard in /etc/init.d/gl-mesh applies
-- the same rule before prplmesh starts.

local uci = require "uci"
local cjson = require "cjson"
local ubus = require "ubus"

local MESH_CONFIG = "gl-mesh"
local MESH_SECTION = "base"
local PRPL_CONFIG = "prplmesh"
local PRPL_SECTION = "config"

local function as_array(value)
	if type(value) ~= "table" or next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function first_line(path)
	local data = read_file(path)
	return data and data:match("^([^\n]+)") or nil
end

local function ubus_call(object, method, params)
	local conn = ubus.connect()
	if not conn then return nil end
	local result = conn:call(object, method, params or {})
	conn:close()
	return result
end

local function wireless_status()
	return ubus_call("network.wireless", "status", {})
end

local function lan_status()
	return ubus_call("network.interface.lan", "status", {})
end

local function list_contains(value, needle)
	if type(value) == "table" then
		for _, item in ipairs(value) do
			if item == needle then return true end
		end
		return false
	end
	return value == needle
end

local function radio_band(status, radio)
	return status and status[radio] and status[radio].config and status[radio].config.band or nil
end

local function collect_aps(status)
	local aps = {}
	for radio, info in pairs(status or {}) do
		for _, iface in ipairs(info.interfaces or {}) do
			local cfg = iface.config or {}
			if cfg.mode == "ap" and not cfg.disabled and not info.disabled then
				local on_lan = list_contains(cfg.network, "lan")
				-- Guest/IoT APs are valid EasyMesh VAPs, but steering them
				-- without the traffic-separation rules is worse than
				-- leaving them out. Main LAN front-haul is the safe set.
				if on_lan then
					aps[#aps + 1] = {
						radio = radio,
						section = iface.section,
						ifname = iface.ifname,
						ssid = cfg.ssid,
						key = cfg.key,
						encryption = cfg.encryption,
						band = radio_band(status, radio),
					}
				end
			end
		end
	end
	table.sort(aps, function(a, b)
		if a.band == b.band then return a.ifname < b.ifname end
		if a.band == "2g" then return true end
		if b.band == "2g" then return false end
		return tostring(a.band) < tostring(b.band)
	end)
	return aps
end

local function main_ap(aps)
	for _, ap in ipairs(aps) do
		if ap.ssid and ap.ssid ~= "" then return ap end
	end
	return aps[1]
end

local function lan_device()
	local status = lan_status()
	return status and (status.l3_device or status.device) or "br-lan"
end

local function lan_ip()
	local status = lan_status()
	local addr = status and status["ipv4-address"] and status["ipv4-address"][1]
	return addr and addr.address or nil
end

local function device_mac(ifname)
	local mac = first_line("/sys/class/net/" .. tostring(ifname or "") .. "/address")
	if mac then return mac:upper() end
	return nil
end

local function hostname()
	local cursor = uci.cursor()
	return cursor:get("system", "@system[0]", "hostname") or first_line("/proc/sys/kernel/hostname") or "OpenWrt"
end

local function uptime()
	local value = tonumber((first_line("/proc/uptime") or ""):match("^([%d%.]+)"))
	return value and math.floor(value) or 0
end

local function repeater_active(cursor, status)
	if cursor:get("gl-repeater", "@repeater[0]", "enabled") == "1" then
		return true
	end
	if cursor:get("gl-repeater", "global", "enabled") == "1" then
		return true
	end
	for _, info in pairs(status or {}) do
		for _, iface in ipairs(info.interfaces or {}) do
			local cfg = iface.config or {}
			if cfg.mode == "sta" and not cfg.disabled and not info.disabled then
				return true
			end
		end
	end
	return false
end

local function mode_enabled(encryption)
	encryption = tostring(encryption or "")
	if encryption == "sae" then return "WPA3-Personal" end
	if encryption == "sae-mixed" then return "WPA2-Personal" end
	if encryption == "owe" then return "OWE" end
	if encryption == "none" then return "None" end
	return "WPA2-Personal"
end

local function management_mode(mode)
	if mode == "agent" then
		return "Multi-AP-Agent"
	end
	-- The controller also runs the local agent so this router's own radios
	-- are represented in the topology.
	return "Multi-AP-Controller-and-Agent"
end

local function ensure_section(cursor, config, section, stype)
	if not cursor:get(config, section) then
		cursor:set(config, section, stype)
	end
end

local function configure_mesh(cursor, mode, aps, status)
	local main = main_ap(aps)
	if not main or not main.ssid or main.ssid == "" then
		return nil, "no LAN front-haul AP with an SSID found"
	end
	local bridge = lan_device()

	ensure_section(cursor, MESH_CONFIG, MESH_SECTION, "base")
	cursor:set(MESH_CONFIG, MESH_SECTION, "enabled", "1")
	cursor:set(MESH_CONFIG, MESH_SECTION, "mode", mode)

	ensure_section(cursor, PRPL_CONFIG, PRPL_SECTION, "prplmesh")
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "enabled", "1")
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "management_mode", management_mode(mode))
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "ssid", main.ssid)
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "key_passphrase", main.key or "")
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "mode_enabled", mode_enabled(main.encryption))
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "backhaul_wire_iface", bridge)
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "use_explicit_bss_profiles", "0")

	local ifnames = {}
	for _, ap in ipairs(aps) do
		ifnames[#ifnames + 1] = ap.ifname

		local radio_section = ap.radio
		ensure_section(cursor, PRPL_CONFIG, radio_section, "wifi-device")
		cursor:set(PRPL_CONFIG, radio_section, "hostap_iface", ap.ifname)
		cursor:set(PRPL_CONFIG, radio_section, "hostap_iface_steer_vaps", ap.ifname)
		cursor:set(PRPL_CONFIG, radio_section, "wireless_section", ap.section)
		cursor:set(PRPL_CONFIG, radio_section, "wireless_device", ap.radio)

		-- hostapd Multi-AP IE. Both values are derived from the existing
		-- front-haul BSS; the backhaul SSID/key are the same credentials.
		cursor:set("wireless", ap.section, "multi_ap", "1")
		if main.key and main.key ~= "" then
			cursor:set("wireless", ap.section, "multi_ap_backhaul_ssid", main.ssid)
			cursor:set("wireless", ap.section, "multi_ap_backhaul_key", main.key)
		end
	end
	cursor:set(PRPL_CONFIG, PRPL_SECTION, "mandatory_interfaces", table.concat(ifnames, ","))
	return true
end

local function mesh_config(cursor)
	local enabled = cursor:get(MESH_CONFIG, MESH_SECTION, "enabled") == "1"
	local mode = cursor:get(MESH_CONFIG, MESH_SECTION, "mode") or "controller"
	return {
		enabled = enabled,
		mode = mode,
	}
end

local function connection_status()
	local cursor = uci.cursor()
	local cfg = mesh_config(cursor)
	local running = false
	local pid = first_line("/var/run/prplmesh.pid")
	if pid and pid ~= "" then
		running = true
	end
	if not running then
		local p = io.popen("pgrep -f '/usr/libexec/prplmesh/bin/beerocks_controller' 2>/dev/null")
		if p then
			running = p:read("*l") ~= nil
			p:close()
		end
	end
	return {
		status = (cfg.enabled and running) and "connected" or "waiting",
		enabled = cfg.enabled,
		mode = cfg.mode,
		type = uplink_type(),
	}
end

local function uplink_type()
	local route = first_line("/proc/net/route")
	-- /proc/net/route does not carry the device name; use the default
	-- route's ifindex through iproute2 in a single cheap call.
	local output = first_line((function()
		local p = io.popen("ip route show default 2>/dev/null | head -n1")
		if not p then return "" end
		local line = p:read("*l") or ""
		p:close()
		return line
	end)()) or ""
	local dev = output:match("%sdev%s+([^%s]+)")
	if dev and (dev:match("^eth") or dev:match("^br")) then
		return "Ethernet"
	end
	return "WiFi"
end

local function local_topology()
	local ifname = lan_device()
	local mac = device_mac(ifname)
	local status = lan_status()
	return {
		mac = mac,
		node_name = hostname(),
		model = "xe3000",
		online = true,
		ip = lan_ip(),
		uptime = uptime(),
		connection = uplink_type(),
		son_nodes = cjson.empty_array,
		clients = cjson.empty_array,
	}
end

return {
	get_config = function()
		return mesh_config(uci.cursor())
	end,

	set_config = function(args)
		args = args or {}
		if args.enabled ~= nil and type(args.enabled) ~= "boolean" then
			return { code = 1, message = "invalid enabled" }
		end
		local mode = args.mode
		if mode ~= nil and mode ~= "controller" and mode ~= "agent" then
			return { code = 1, message = "invalid mode" }
		end
		local cursor = uci.cursor()
		local status = wireless_status()
		local aps = collect_aps(status)

		if args.enabled == false then
			ensure_section(cursor, MESH_CONFIG, MESH_SECTION, "base")
			cursor:set(MESH_CONFIG, MESH_SECTION, "enabled", "0")
			ensure_section(cursor, PRPL_CONFIG, PRPL_SECTION, "prplmesh")
			cursor:set(PRPL_CONFIG, PRPL_SECTION, "enabled", "0")
			cursor:commit(MESH_CONFIG)
			cursor:commit(PRPL_CONFIG)
			os.execute("/etc/init.d/prplmesh stop >/dev/null 2>&1")
			return {}
		end

		if #aps == 0 then
			return { code = 1, message = "no LAN front-haul AP found" }
		end

		if repeater_active(cursor, status) then
			return {
				code = 20026021,
				message = "Repeater/STA mode is active; disable it before enabling mesh",
			}
		end

		local ok, err = configure_mesh(cursor, mode or "controller", aps, status)
		if not ok then
			return { code = 1, message = err }
		end
		cursor:commit(MESH_CONFIG)
		cursor:commit(PRPL_CONFIG)
		cursor:commit("wireless")
		-- Both hostapd and the mesh daemons need to see the new Multi-AP
		-- BSS settings. Do it after the RPC response so the page can poll
		-- /ping.svg while Wi-Fi restarts instead of timing the call out.
		os.execute("(wifi reload; /etc/init.d/prplmesh restart) >/dev/null 2>&1 &")
		return {}
	end,

	get_connection_status = function()
		return { connection = connection_status() }
	end,

	get_status = function()
		local connection = connection_status()
		return {
			connection = connection,
			pairing_status = "",
			onbd_code = { remain = 0, code = "" },
			upgrade_status = {},
		}
	end,

	get_topology = function()
		return local_topology()
	end,

	query_firmware_versions = function()
		return { versions = cjson.empty_array }
	end,

	trigger_onbd_scan = function()
		return { code = 1, message = "onboarding scan is not available in this build" }
	end,

	get_onbd_scan_status = function()
		return { status = "failed", nodes = cjson.empty_array }
	end,

	add_nodes = function()
		return { code = 1, message = "onboarding is not available in this build" }
	end,

	reboot_nodes = function()
		return { code = 1, message = "remote node reboot is not available in this build" }
	end,

	remove_nodes = function()
		return { code = 1, message = "remote node removal is not available in this build" }
	end,

	reset_nodes = function()
		return { code = 1, message = "remote node reset is not available in this build" }
	end,

	set_node_name = function()
		return { code = 1, message = "remote node naming is not available in this build" }
	end,

	get_wps_status = function()
		return { status = 0 }
	end,

	enable_wps = function()
		return { code = 1, message = "WPS onboarding is not available in this build" }
	end,

	get_pairing_status = function()
		return { pairing_status = "" }
	end,

	get_onbd_code = function()
		return { remain = 0, code = "" }
	end,

	refresh_onboard_code = function()
		return { remain = 0, code = "" }
	end,

	set_onboard_code = function()
		return {}
	end,

	get_lan_status = function()
		return { ip = lan_ip(), device = lan_device(), mac = device_mac(lan_device()) }
	end,

	upgrade_start_req = function()
		return { code = 1, message = "remote firmware upgrade is not available in this build" }
	end,
}
