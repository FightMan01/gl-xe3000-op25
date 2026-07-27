-- "system" RPC object: status/overview page data, timezone, USB, password,
-- reboot/reset.
--
-- Built entirely from standard Linux /proc + OpenWrt mechanisms - no GL-
-- specific hardware access needed. Battery/temp/charge_cnt come from "mcu"
-- (a separate ubus-pushed live status).
--
-- get_timezone_list is called pre-login (sid="") from the app shell's
-- root bootstrap, separately from get_timezone_config: get_timezone_config
-- reports the currently-set zone, get_timezone_list is the dropdown's
-- available-options list. Built from zonedata.lua (vendored IANA
-- zonename -> POSIX TZ table, Apache-2.0, from LuCI's luci-lua-runtime).

local uci = require "uci"
local cjson = require "cjson"
-- Load per request rather than through require()'s process-wide cache.
-- RPC modules are hot-reloaded by nginx; caching this helper would let
-- stale factory offsets survive a helper update until nginx restarts,
-- which could expose the default WiFi password as the serial number.
local factory = dofile("/usr/lib/lua/gloui/factory.lua")
local ZONES = dofile("/usr/lib/oui-rpc/zonedata.lua")

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function popen_line(cmd)
	local f = io.popen(cmd)
	if not f then return nil end
	local line = f:read("*l")
	f:close()
	return line
end

local function ksmbd_available()
	-- ksmbd-server can remain installed across a sysupgrade while its
	-- kernel module is unavailable for the running kernel.  Advertising
	-- Network Storage in that state makes the stock SDK4 page
	-- automatically call `start`, then leave its global processing mask
	-- up forever when modprobe fails.  Require both halves of the upstream
	-- implementation before exposing the page.  Do not use io.popen here:
	-- nginx's Lua worker environment can refuse child-process creation even
	-- though the same command works over SSH, which incorrectly hid NAS on
	-- images that contained and loaded the real module.
	local function file_exists(path)
		local file = io.open(path, "rb")
		if not file then return false end
		file:close()
		return true
	end

	local release_file = io.open("/proc/sys/kernel/osrelease", "r")
	if not release_file then return false end
	local release = (release_file:read("*l") or ""):match("^%s*(.-)%s*$")
	release_file:close()
	if release == "" or not file_exists("/usr/sbin/ksmbd.mountd") then
		return false
	end

	local module = "/lib/modules/" .. release .. "/ksmbd.ko"
	return file_exists(module)
		or file_exists(module .. ".gz")
		or file_exists(module .. ".zst")
end

local function get_cpu_load()
	local data = read_file("/proc/loadavg")
	if not data then return {} end
	local one, five, fifteen = data:match("^(%S+) (%S+) (%S+)")
	return { load1 = tonumber(one), load5 = tonumber(five), load15 = tonumber(fifteen) }
end

local function get_memory()
	local data = read_file("/proc/meminfo")
	if not data then return {} end
	local mem = {}
	for key, val in data:gmatch("(%a+):%s+(%d+) kB") do
		mem[key] = tonumber(val) * 1024
	end
	return {
		total = mem.MemTotal,
		free = mem.MemFree,
		cached = (mem.Cached or 0) + (mem.Buffers or 0),
		available = mem.MemAvailable or mem.MemFree,
	}
end

local function get_flash()
	local line = popen_line("df -k /overlay 2>/dev/null | tail -1")
	if not line then return {} end
	local total, used, avail = line:match("%S+%s+(%d+)%s+(%d+)%s+(%d+)")
	if not total then return {} end
	-- /overlay only accounts for writable application/configuration data;
	-- the immutable squashfs system image is mounted separately at /rom.
	-- Include that real occupied space in the combined total so the
	-- frontend's `total - flash_app - flash_free` calculation reports a
	-- non-zero, truthful "System Used" value.
	local rom_line = popen_line("df -k /rom 2>/dev/null | tail -1")
	local rom_used = rom_line and rom_line:match("%S+%s+%d+%s+(%d+)%s+%d+") or 0
	return {
		total = (tonumber(total) + (tonumber(rom_used) or 0)) * 1024,
		used = tonumber(used) * 1024,
		free = tonumber(avail) * 1024,
	}
end

local function get_cpu_temp()
	local base = "/sys/class/thermal"
	local p = io.popen("ls " .. base .. " 2>/dev/null | grep thermal_zone")
	if not p then return nil end
	local zone = p:read("*l")
	p:close()
	if not zone then return nil end
	local raw = read_file(base .. "/" .. zone .. "/temp")
	if not raw then return nil end
	local milli = tonumber((raw:gsub("%s+", "")))
	if not milli then return nil end
	return math.floor(milli / 1000)
end

local function get_fan()
	local base = "/sys/class/hwmon"
	local p = io.popen("ls " .. base .. " 2>/dev/null")
	if not p then return { present = false } end
	local hwmon = p:read("*l")
	p:close()
	if not hwmon then return { present = false } end
	local pwm = read_file(base .. "/" .. hwmon .. "/pwm1")
	local rpm = read_file(base .. "/" .. hwmon .. "/fan1_input")
	return {
		present = true,
		pwm = pwm and tonumber(pwm:match("%d+")),
		rpm = rpm and tonumber(rpm:match("%d+")),
	}
end

local function get_sysinfo()
	local release = read_file("/etc/openwrt_release") or ""
	local ver = release:match('DISTRIB_RELEASE=\'([^\']+)\'') or "unknown"
	return {
		hostname = popen_line("uname -n") or "OpenWrt",
		openwrt_version = ver,
		kernel_version = popen_line("uname -r") or "unknown",
		arch = popen_line("uname -m") or "unknown",
	}
end

local function ipv4addr(ubus_conn, iface)
	local status = ubus_conn:call("network.interface." .. iface, "status", {})
	local up = status and status.up == true
	local online = up and status["ipv4-address"] and status["ipv4-address"][1] ~= nil
	return up, online
end

local function interface_reachable(iface)
	-- netifd can finish assigning the cellular address a few seconds before
	-- mwan3 changes its tracker state to "online".  The Internet view takes
	-- a system-status snapshot during that window and otherwise keeps the
	-- false "connected, but Internet can't be accessed" warning until the
	-- next full page reload.  Confirm the data plane directly while mwan3
	-- is still converging.  This is deliberately only used for an
	-- address-bearing interface which mwan3 has not yet declared online;
	-- a genuinely unreachable interface continues to be reported offline.
	if not iface or iface == "" then return false end
	local safe = iface:match("^[%w%._%-]+$")
	if not safe then return false end
	local ok = os.execute(
		"ping -4 -I " .. safe .. " -c 1 -W 1 1.1.1.1 >/dev/null 2>&1"
	)
	return ok == true or ok == 0
end

local function radio_ssid(cursor, radio)
	local ssid, enabled
	cursor:foreach("wireless", "wifi-iface", function(s)
		if s.device == radio and s.mode == "ap" and s.network == "lan" then
			ssid = s.ssid
			enabled = s.disabled ~= "1"
		end
	end)
	return ssid, enabled
end

return {
	-- The internet page's cable-card component reads
	-- `this.systemStatus.system.mode` directly off the Vuex state that
	-- gets set to whatever this method returns, so a `system` key with a
	-- `mode` field must always be present or that component's render
	-- silently aborts with no visible error.
	--
	-- Shape: {network:[{online,up,interface}],
	-- wifi:[{guest,ssid,up,channel,band,name,passwd}],
	-- service:[{name,status}], client:[{wireless_total,cable_total}],
	-- system:{lan_ip,guest_ip,flash_total,memory_total,memory_free,
	-- ipv6_enabled,ddns_enabled,uptime,load_average,flash_free,flash_app,
	-- mode,mcu:{...},cpu:{temperature},timestamp}}. wgserver is backed by
	-- the upstream OpenWrt WireGuard implementation; the remaining VPN
	-- client/OpenVPN services stay stopped until adapters exist. mode:0
	-- matches ui.lua's CURRENT_MODE ("router" - no AP-only/WDS/relay/
	-- mesh-agent mode switching here).
	get_status = function(args)
		local cursor = uci.cursor()
		local ubus_ok, ubus_conn = pcall(function()
			local u = require "ubus"
			return u.connect()
		end)
		local conn = (ubus_ok and ubus_conn) or nil

		local network = {}
		local mwan = conn and conn:call("mwan3", "status", {}) or {}
		local mwan_interfaces = mwan.interfaces or {}
		-- The frontend joins these names to kmwan.get_config.  They must be
		-- the UI's identifiers (not merely friendly names): modem_<bus> for
		-- cellular and wwan for repeater.  umbim puts the actual IPv4
		-- address on the dynamic wwan_4 child, not the address-less parent.
		for _, entry in ipairs({
			{ interface = "wan", real = "wan" },
			{ interface = "modem_mhi0", real = "wwan_4" },
			{ interface = "wwan", real = "repeater" },
			{ interface = "tethering", real = "tethering" },
		}) do
			local up, has_address = false, false
			if conn then up, has_address = ipv4addr(conn, entry.real) end
			local tracked = mwan_interfaces[entry.real]
			-- An address means the interface is connected, not that it can
			-- reach the Internet.  When mwan3 tracks the interface, its
			-- health result is authoritative.  Only fall back to address
			-- presence if no tracker exists (for nomwan/minimal builds).
			local online
			if tracked then
				online = tracked.status == "online"
				if up and has_address and not online then
					online = interface_reachable(entry.real)
				end
			else
				online = has_address
			end
			table.insert(network, {
				interface = entry.interface,
				up = up,
				online = up and online or false,
			})
		end

		-- iot/mld are always false since this port doesn't implement
		-- IoT-network wifi-ifaces or MLO/6G radios (see wifi.lua).
		local wifi = {}
		for _, r in ipairs({ { radio = "radio0", band = "2G" }, { radio = "radio1", band = "5G" } }) do
			local passwd, hidden, encryption
			cursor:foreach("wireless", "wifi-iface", function(s)
				if s.device == r.radio and s.mode == "ap" and s.network == "lan" then
					passwd = s.key
					hidden = s.hidden == "1"
					encryption = s.encryption
				end
			end)
			local ssid, enabled = radio_ssid(cursor, r.radio)
			if ssid then
				table.insert(wifi, {
					name = r.radio, band = r.band, ssid = ssid, up = enabled and true or false,
					channel = tonumber((cursor:get("wireless", r.radio, "channel"))) or 0,
					guest = false,
					passwd = passwd or "",
					hidden = hidden or false,
					init = true,
					iot = false,
					mld = false,
					encryption = encryption or "psk2",
				})
			end
		end

		local mcu_status = {}
		if conn then
			mcu_status = conn:call("mcu", "status", {}) or {}
		end
		if conn then conn:close() end

		local mem = get_memory()
		local flash = get_flash()

		-- guest/iot are absent (nil ip/netmask, no subnets[] entry) when
		-- their UCI section doesn't exist yet.
		-- CIDR-bits -> dotted netmask via a lookup table: this runs under
		-- LuaJIT's Lua 5.1 dialect, which has no &/<</>> syntax.
		local CIDR_MASKS = {
			[8] = "255.0.0.0", [16] = "255.255.0.0", [24] = "255.255.255.0",
			[25] = "255.255.255.128", [26] = "255.255.255.192", [27] = "255.255.255.224",
			[28] = "255.255.255.240", [29] = "255.255.255.248", [30] = "255.255.255.252",
		}
		local function net_ip_netmask(section)
			local ip = cursor:get("network", section, "ipaddr")
			if type(ip) == "table" then ip = ip[1] end
			if not ip then return nil, nil end
			local addr, cidr = ip:match("^([^/]+)/?(%d*)$")
			local bits = tonumber(cidr)
			local netmask = (bits and CIDR_MASKS[bits]) or "255.255.255.0"
			return addr, netmask
		end

		local lan_ip, lan_netmask = net_ip_netmask("lan")
		lan_ip = lan_ip or "192.168.8.1"
		lan_netmask = lan_netmask or "255.255.255.0"
		-- cjson.encode drops a table key entirely when its value is nil,
		-- so explicit `or ""` keeps these keys present (empty) rather
		-- than vanishing from the response.
		local guest_ip, guest_netmask = net_ip_netmask("guest")
		guest_ip = guest_ip or ""
		guest_netmask = guest_netmask or ""
		local iot_ip, iot_netmask = net_ip_netmask("iot")
		iot_ip = iot_ip or ""
		iot_netmask = iot_netmask or ""

		local subnets = { { ip = lan_ip, netmask = lan_netmask } }
		if guest_ip ~= "" then table.insert(subnets, { ip = guest_ip, netmask = guest_netmask }) end
		if iot_ip ~= "" then table.insert(subnets, { ip = iot_ip, netmask = iot_netmask }) end

		local load = get_cpu_load()
		local uptime = tonumber((popen_line("cat /proc/uptime") or "0"):match("^(%S+)")) or 0
		local cpu_temp = get_cpu_temp()
		local tzoffset = popen_line("date +%z") or "+0000"

		-- cjson.empty_array guards: `wifi` is normally 2 entries but could
		-- be empty if UCI wireless config is broken/missing; `network` is
		-- hardcoded to 2 loop iterations so can't actually be empty, kept
		-- consistent anyway since it's cheap and self-documenting.
		if next(wifi) == nil then wifi = cjson.empty_array end
		if next(network) == nil then network = cjson.empty_array end
		local client_status = dofile("/usr/lib/oui-rpc/clients.lua").get_status({})
		local live_wifi = dofile("/usr/lib/oui-rpc/wifi.lua").get_status({}).res or {}
		for _, configured in ipairs(wifi) do
			for _, live in ipairs(live_wifi) do
				if configured.name == live.name and live.channel then
					configured.channel = live.channel
				end
			end
		end

		return {
			network = network,
			wifi = wifi,
			service = {
				{ name = "wgclient", status = 0 },
				{ name = "wgserver",
				  status = cursor:get("gl_wgserver", "main", "enabled") == "1"
					and 1 or 0 },
				{ name = "ovpnclient", status = 0 },
				{ name = "ovpnserver", status = 0 },
				{ name = "tailscale",
				  status = cursor:get("tailscale", "settings", "enabled") == "1" and 1 or 0 },
				{ name = "adguardhome",
				  status = cursor:get("adguardhome", "config", "enabled") == "1" and 1 or 0 },
				{ name = "zerotier",
				  status = cursor:get("zerotier", "global", "enabled") == "1" and 1 or 0 },
				{ name = "tor",
				  status = cursor:get("gl-tor", "main", "enabled") == "1" and 1 or 0 },
			},
			client = { client_status },
			system = {
				lan_ip = lan_ip,
				lan_netmask = lan_netmask,
				guest_ip = guest_ip,
				guest_netmask = guest_netmask,
				iot_ip = iot_ip,
				iot_netmask = iot_netmask,
				subnets = subnets,
				flash_total = flash.total,
				flash_free = flash.free,
				flash_app = flash.used,
				memory_total = mem.total,
				memory_free = mem.free,
				memory_buff_cache = mem.cached,
				ipv6_enabled = cursor:get("network", "wan6", "auto") ~= "0",
				ddns_enabled = false,
				uptime = math.floor(uptime),
				load_average = { load.load1, load.load5, load.load15 },
				mode = 0,
				mcu = mcu_status,
				cpu = { temperature = cpu_temp },
				timestamp = os.time(),
				tzoffset = tzoffset,
				time_sync_status = true,
				-- Feature status consumed by the app shell and conflict
				-- warnings on the SQM/network-acceleration pages.
				netnat_enabled = false,
				content_protection_enabled = false,
				flow_statistics_enabled = false,
				network_quality_enabled = false,
				prio_enabled = false,
				qos_enabled = false,
				sqm_enabled = cursor:get("sqm", "@queue[0]", "enabled") == "1",
				dpi_info = { status = "0", lib_version = "", lib_update_time = "" },
			},
		}
	end,

	-- Device identity (model/version). The app shell's `softwareFeature`
	-- Vuex getter reads straight off this response's software_feature
	-- field, and several components check flags like softwareFeature.vpn/
	-- .ipv6 before rendering, so those keys have to be present.
	--
	-- Shape: {mac, hardware_version,
	-- software_feature:{ids_ips,ipv6,adguard,tor,vpn}, vendor,
	-- hardware_feature:{...}, country_code, sn_bak,
	-- board_info:{architecture,hostname,kernel_version,openwrt_version,
	-- model}, firmware_date, model, ddns, sn, firmware_type,
	-- firmware_version}. Feature flags match what this port actually
	-- ships (ipv6/vpn/tor/adguard: real; ids_ips: never a feature on this
	-- device class).
	get_info = function(args)
		local identity = factory.get()
		local mac = nil
		local mf = io.open("/sys/class/net/eth1/address", "r")
		if mf then
			mac = (mf:read("*l") or ""):upper()
			mf:close()
		end
		-- The frontend displays this top-of-page next to "Admin Panel" as
		-- the firmware version, so it needs a real-looking string rather
		-- than the raw "SNAPSHOT" DISTRIB_RELEASE. GL_PORT_VERSION is this
		-- port's own branded string; board_info.openwrt_version below
		-- still reports the real underlying OpenWrt release.
		local GL_PORT_VERSION = "4.9.0-op25"
		local ver = GL_PORT_VERSION
		local sysinfo = get_sysinfo()
		-- BusyBox has no `nproc` binary, so count /proc/cpuinfo entries
		-- directly instead.
		local nproc = tonumber(popen_line("grep -c ^processor /proc/cpuinfo") or "") or 2

		-- Prefer the real manufacturing serial. A MAC-derived value is
		-- only a fallback for hardware without this factory layout.
		local sn = identity.serial or (mac and mac:gsub(":", ""):lower() or "")

		local have_ksmbd = ksmbd_available()
		local hidden_features = {
			"astrowarp", "bridge", "cloud", "contentprotection",
			"dpifeatures", "dynamicdns", "edgerouter",
			"ovpnserver", "parental-control", "qos",
			"vpn-client", "vpndashboard",
		}
		if not have_ksmbd then
			hidden_features[#hidden_features + 1] = "nasview"
		end

		return {
			mac = mac,
			hardware_version = "",
			-- cellular_upgrade is true since upgrade.lua implements
			-- check_cellular_local/online + get_cellular_upgrade_status.
			-- mlo/sms_forward/nas/astrowarp_lite/bark/passthrough/
			-- obfuscation/secondwan/is_need_6g_bssid_sync/vlan are false -
			-- none of those subsystems exist on this port (WiFi 6, not 7,
			-- so no MLO).
			software_feature = {
				ids_ips = false, ipv6 = true, adguard = true, tor = true, vpn = true,
				astrowarp_lite = false, bark = false, cellular_ref = "1.0", cellular_upgrade = true,
				is_need_6g_bssid_sync = false, ksmbd = have_ksmbd, minimum_temperature = 70, mlo = false,
				nas = false, obfuscation = false, passthrough = false, repeater_eap = true,
				secondwan = false, sms_forward = true, vlan = false,
			},
			vendor = "GL.iNet",
			-- The Internet page's cards() computed property gates the
			-- Repeater/Tethering/Cellular cards on hardware_feature.radio/
			-- .usb/.build_in_modem being truthy (and !simo for the modem
			-- card specifically), so those need real values here.
			-- XE3000 is a portable single-modem/single-SIM-slot travel
			-- router with an MCU-driven battery, no screen/GPS/bluetooth/
			-- RS485/microSD/USB3.
			hardware_feature = {
				lan = "eth1", wan = "eth0", nand = true, mcu = true, fan = true,
				radio = "radio0", usb = "1-1", build_in_modem = "1-1.2",
				bluetooth = false, gps = false, hwnat = false, lcd_sched = false,
				microsd = false, modem_reset = true, noled = false, novlan = false,
				nowds = false, reset_button = true, rs485 = false, screen = false,
				simo = false, slot = "single", submodel = "", switch_button = false,
				usb3 = false, usb_power = false, usb_reset = false, wifi_type = "",
			},
			country_code = identity.country,
			board_info = {
				architecture = sysinfo.arch,
				hostname = sysinfo.hostname,
				kernel_version = sysinfo.kernel_version,
				openwrt_version = "OpenWrt " .. sysinfo.openwrt_version,
				model = "GL.iNet GL-XE3000",
			},
			model = "xe3000",
			firmware_version = ver,
			cpu_num = nproc,
			ddns = identity.ddns or "",
			device_id = identity.device_id or "",
			device_type = 2,
			firmware_date = "",
			firmware_type = "snapshot",
			-- The menu filter's hiddenList mechanism (fed by this field) is
			-- the standard way to suppress specific views per product -
			-- this list is every view this port's RPC layer has no backing
			-- object for. "cloud" and "astrowarp" are the only two views
			-- under the "Cloud Services" parent, so hiding both makes that
			-- entire sidebar section disappear too.
			hidden_features = hidden_features,
			sn = sn,
			sn_bak = "",
			switchable_wan_ports = 0,
		}
	end,

	-- The Overview page's getSystemLoad() reads load_average as an array
	-- plus memory_total/memory_free/memory_buff_cache directly off this
	-- response.
	get_load = function(args)
		local load = get_cpu_load()
		local mem = get_memory()
		return {
			load_average = { load.load1, load.load5, load.load15 },
			memory_total = mem.total,
			memory_free = mem.free,
			memory_buff_cache = mem.cached,
		}
	end,

	-- autotimezone_enabled reflects whether NTP-based timezone
	-- auto-detection is on (not implemented here, so always false).
	-- localtime/timestamp are both the current epoch seconds, exposed
	-- twice under different names for different frontend read sites.
	get_timezone_config = function(args)
		local cursor = uci.cursor()
		local now = os.time()
		return {
			zonename = cursor:get("system", "@system[0]", "zonename"),
			timezone = cursor:get("system", "@system[0]", "timezone"),
			autotimezone_enabled = false,
			localtime = now,
			timestamp = now,
			tzoffset = popen_line("date +%z") or "+0000",
		}
	end,

	get_timezone_list = function(args)
		local list = {}
		for _, z in ipairs(ZONES) do
			table.insert(list, { zonename = z[1], timezone = z[2] })
		end
		return { timezone_list = list }
	end,

	set_timezone_config = function(args)
		local cursor = uci.cursor()
		cursor:set("system", "@system[0]", "zonename", args.zonename)
		cursor:set("system", "@system[0]", "timezone", args.timezone)
		cursor:commit("system")
		os.execute("/etc/init.d/system reload >/dev/null 2>&1")
		return {}
	end,

	-- USB host-controller speed-mode picker: get_usb_info lists the
	-- selectable protocol modes, get_usb_config reports which is active.
	-- Some routers force USB2.0-only to reduce RF interference with
	-- 2.4GHz wifi/cellular (a real issue with USB3 SuperSpeed signaling).
	-- XE3000's controller is xHCI/USB3-capable, but nothing here actually
	-- forces it into USB2-only mode yet - set_usb_config just records the
	-- preference.
	get_usb_info = function(args)
		return {
			{ value = "usb2.0", label = "USB 2.0" },
			{ value = "usb3.0", label = "USB 3.0" },
		}
	end,

	get_usb_config = function(args)
		local cursor = uci.cursor()
		return {
			protocol = cursor:get("gl-oui-rpc", "usb", "protocol") or "usb3.0",
		}
	end,

	set_usb_config = function(args)
		if args.protocol ~= "usb2.0" and args.protocol ~= "usb3.0" then
			return { code = 1, message = "protocol must be usb2.0 or usb3.0" }
		end
		local cursor = uci.cursor()
		if not cursor:get("gl-oui-rpc", "usb") then
			cursor:set("gl-oui-rpc", "usb", "usb")
		end
		cursor:set("gl-oui-rpc", "usb", "protocol", args.protocol)
		cursor:commit("gl-oui-rpc")
		return {}
	end,

	-- Writes the new password to `passwd`'s stdin via a pipe rather than
	-- interpolating it into a shell command string, so it never passes
	-- through shell parsing regardless of content.
	--
	-- KNOWN GAP: the API takes {username, old_password, new_password},
	-- but this only checks new_password - any already-authenticated
	-- caller can change the password without proving they know the
	-- current one. Verifying old_password needs a bidirectional pipe to
	-- a crypt-capable tool (io.popen is one-directional), so it'd need a
	-- temp-file workaround. Not yet implemented.
	set_password = function(args)
		if type(args.new_password) ~= "string" or #args.new_password < 1 then
			return { code = 1, message = "missing new_password" }
		end
		local f = io.popen("passwd root", "w")
		if not f then
			return { code = 1, message = "passwd unavailable" }
		end
		f:write(args.new_password, "\n", args.new_password, "\n")
		local ok = f:close()
		if not (ok == true or ok == 0) then
			return { code = 1, message = "password change failed" }
		end
		return {}
	end,

	reboot = function(args)
		os.execute("reboot >/dev/null 2>&1 &")
		return {}
	end,

	-- Factory reset: standard OpenWrt firstboot (wipes overlay, reboots).
	-- Deliberately requires an explicit confirm flag - this is
	-- irreversible.
	reset_firmware = function(args)
		if not args.confirm then
			return { code = 1, message = "missing confirm" }
		end
		os.execute("firstboot -y >/dev/null 2>&1 && reboot >/dev/null 2>&1 &")
		return {}
	end,
}
