-- "repeater" RPC object: WiFi repeater / travel-router uplink. GL's
-- internal name for this feature; the menu/view is called "bridge" mode.
--
-- STA-uplink + double-NAT, not WDS/4addr - eduroam-class enterprise APs
-- never support WDS. Supports WPA2/3-Personal and WPA2-Enterprise
-- (PEAP/TTLS/TLS) upstream networks via wpad-full.
--
-- Config lives in a dedicated "repeater" wifi-iface (mode 'sta') on
-- whichever radio the caller picks - either radio can run STA+AP
-- concurrently in mac80211.
--
-- Method set: connect, disconnect, enter_bare_mode, exit_bare_mode,
-- get_channel_prompt, get_config, get_saved_ap_list, remove_saved_ap,
-- scan, set_channel_prompt, set_config.

local uci = require "uci"
local ubus = require "ubus"
local iwinfo = require "iwinfo"
local cjson = require "cjson"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local function read_trim(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local v = f:read("*l")
	f:close()
	if not v or v == "" then return nil end
	return v
end

local RADIOS = { "radio0", "radio1" }

local function radio_for_band(cursor, wanted_band)
	if wanted_band ~= "2g" and wanted_band ~= "5g" then return nil end
	for _, radio in ipairs(RADIOS) do
		if cursor:get("wireless", radio, "band") == wanted_band then
			return radio
		end
	end
	return nil
end

local function repeater_iface(cursor)
	local ifname = nil
	cursor:foreach("wireless", "wifi-iface", function(s)
		if s.mode == "sta" and s.network == "repeater" then
			ifname = s[".name"]
		end
	end)
	return ifname
end

local function real_ifname(iface_section)
	local conn = ubus.connect()
	if not conn then return iface_section end
	local status = conn:call("network.wireless", "status", {})
	conn:close()
	if not status then return iface_section end
	for _, radio_status in pairs(status) do
		for _, iface in ipairs(radio_status.interfaces or {}) do
			if iface.section == iface_section then
				return iface.ifname or iface_section
			end
		end
	end
	return iface_section
end

local function scan_results(args)
	local cursor = uci.cursor()
	local out, seen = {}, {}
	for _, radio in ipairs(RADIOS) do
		if not args.radio or args.radio == radio then
			local scan_iface = nil
			cursor:foreach("wireless", "wifi-iface", function(s)
				if s.device == radio and s.mode == "ap" and not scan_iface then
					scan_iface = s[".name"]
				end
			end)
			if scan_iface then
				local dev = real_ifname(scan_iface)
				local t = iwinfo.type(dev)
				local ok, results = false, nil
				if t then
					ok, results = pcall(function() return iwinfo[t].scanlist(dev) end)
				end
				if ok and results then
					for _, ap in ipairs(results) do
						local bssid = ap.bssid and ap.bssid:lower()
						if bssid and not seen[bssid] then
							seen[bssid] = true
							local channel = tonumber(ap.channel) or 0
							table.insert(out, {
								ssid = ap.ssid or "",
								bssid = ap.bssid,
								channel = channel,
								signal = ap.signal,
								-- The bridge UI inspects the complete iwinfo
								-- encryption object, including description and
								-- auth_suites, to expose its 802.1X form.
								encryption = ap.encryption or {},
								band = channel <= 14 and "2g" or "5g",
								dfs = channel >= 52 and channel <= 144,
							})
						end
					end
				end
			end
		end
	end
	return out
end

local function choose_radio(args)
	for _, radio in ipairs(RADIOS) do
		if args.radio == radio then return radio end
	end

	local cursor = uci.cursor()
	local locked_radio = radio_for_band(cursor,
		cursor:get("gl-repeater", "settings", "lock_band"))
	if locked_radio then return locked_radio end

	local channel = tonumber(args.channel)
	if not channel and (args.bssid or args.ssid) then
		for _, ap in ipairs(scan_results({})) do
			if (args.bssid and ap.bssid
					and args.bssid:lower() == ap.bssid:lower())
				or (not args.bssid and args.ssid == ap.ssid) then
				channel = ap.channel
				break
			end
		end
	end

	local wanted_band = channel and channel <= 14 and "2g" or "5g"
	for _, radio in ipairs(RADIOS) do
		if cursor:get("wireless", radio, "band") == wanted_band then return radio end
	end
	return RADIOS[1]
end

local function apply_config(args)
	if type(args.ssid) ~= "string" then
		return { code = 1, message = "missing ssid" }
	end
	local radio = choose_radio(args)
	local cursor = uci.cursor()
	local iface = repeater_iface(cursor)
	if not iface then
		iface = cursor:add("wireless", "wifi-iface")
		cursor:set("wireless", iface, "network", "repeater")
		cursor:set("wireless", iface, "mode", "sta")
	end

	cursor:set("wireless", iface, "device", radio)
	cursor:set("wireless", iface, "ssid", args.ssid)
	cursor:set("wireless", iface, "disabled", "0")
	if args.bssid and args.bssid:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		cursor:set("wireless", iface, "bssid", args.bssid)
	else
		cursor:delete("wireless", iface, "bssid")
	end

	local secret = args.key or args.password
	local enterprise = args.identity ~= nil or args.eap_type ~= nil
	if enterprise then
		cursor:set("wireless", iface, "encryption", "wpa2")
		cursor:set("wireless", iface, "eap_type", (args.eap_type or "peap"):lower())
		cursor:set("wireless", iface, "auth", args.auth or "MSCHAPV2")
		cursor:set("wireless", iface, "identity", args.identity or "")
		cursor:set("wireless", iface, "password", secret or "")
		if args.anonymous_identity then
			cursor:set("wireless", iface, "anonymous_identity", args.anonymous_identity)
		else
			cursor:delete("wireless", iface, "anonymous_identity")
		end
		if args.ca_cert then cursor:set("wireless", iface, "ca_cert", args.ca_cert) end
		cursor:delete("wireless", iface, "key")
	elseif secret and secret ~= "" then
		cursor:set("wireless", iface, "encryption", "sae-mixed")
		cursor:set("wireless", iface, "key", secret)
		cursor:delete("wireless", iface, "eap_type")
		cursor:delete("wireless", iface, "identity")
		cursor:delete("wireless", iface, "password")
	else
		cursor:set("wireless", iface, "encryption", "none")
		cursor:delete("wireless", iface, "key")
		cursor:delete("wireless", iface, "eap_type")
	end
	cursor:commit("wireless")

	if args.protocol then
		cursor:set("network", "repeater", "proto",
			args.protocol == "static" and "static" or "dhcp")
		if args.protocol == "static" then
			if args.ipaddr then cursor:set("network", "repeater", "ipaddr", args.ipaddr) end
			if args.netmask then cursor:set("network", "repeater", "netmask", args.netmask) end
			if args.gateway then cursor:set("network", "repeater", "gateway", args.gateway) end
			if args.dns then cursor:set("network", "repeater", "dns", args.dns) end
		end
		cursor:commit("network")
	end

	local already_saved = false
	cursor:foreach("gl-repeater", "saved_ap", function(s)
		if s.ssid == args.ssid then already_saved = true end
	end)
	if not already_saved then
		local saved = cursor:add("gl-repeater", "saved_ap")
		cursor:set("gl-repeater", saved, "ssid", args.ssid)
		cursor:set("gl-repeater", saved, "radio", radio)
		cursor:commit("gl-repeater")
	end

	os.execute("wifi reload >/dev/null 2>&1")
	return {}
end

return {
	scan = function(args)
		args = args or {}
		if not args.radio and args.all_band ~= true then
			local cursor = uci.cursor()
			args.radio = radio_for_band(cursor,
				cursor:get("gl-repeater", "settings", "lock_band"))
		end
		return { res = as_array(scan_results(args)) }
	end,

	-- dfs_support mirrors wifi.lua's 5G-radio DFS-channel support
	-- (radio1 supports the 52-144 DFS range). macaddr reports the
	-- repeater STA interface's real MAC once configured, else the
	-- primary radio's own MAC. auto/smart_reconnect are always true -
	-- this port always attempts to stay connected to a configured
	-- upstream AP, there's no separate toggle for either yet.
	get_config = function(args)
		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		local mac = nil
		local mf = io.open("/sys/class/net/eth1/address", "r")
		if mf then
			mac = (mf:read("*l") or ""):lower()
			mf:close()
		end
		if not iface then
			return {
				configured = false,
				dfs_support = true,
				macaddr = mac,
				auto = cursor:get("gl-repeater", "settings", "auto") ~= "0",
				smart_reconnect = true,
				lock_band = cursor:get("gl-repeater", "settings", "lock_band") or "",
			}
		end
		return {
			configured = true,
			dfs_support = true,
			macaddr = mac,
			auto = cursor:get("gl-repeater", "settings", "auto") ~= "0",
			smart_reconnect = true,
			lock_band = cursor:get("gl-repeater", "settings", "lock_band") or "",
			radio = cursor:get("wireless", iface, "device"),
			ssid = cursor:get("wireless", iface, "ssid"),
			encryption = cursor:get("wireless", iface, "encryption"),
			eap_type = cursor:get("wireless", iface, "eap_type"),
			identity = cursor:get("wireless", iface, "identity"),
			disabled = cursor:get("wireless", iface, "disabled") == "1",
		}
	end,

	-- args: radio, ssid, and either:
	--   password              (WPA2/3-Personal), or
	--   eap_type, identity, anonymous_identity, password, ca_cert
	--                         (WPA2-Enterprise - PEAP/TTLS/TLS)
	set_config = function(args)
		args = args or {}
		if args.ssid ~= nil then return apply_config(args) end

		local lock_band = args.lock_band or ""
		if lock_band ~= "" and lock_band ~= "2g" and lock_band ~= "5g" then
			return { code = 1, message = "invalid lock_band" }
		end

		local cursor = uci.cursor()
		cursor:set("gl-repeater", "settings", "settings")
		cursor:set("gl-repeater", "settings", "auto", args.auto == false and "0" or "1")
		cursor:set("gl-repeater", "settings", "lock_band", lock_band)
		cursor:commit("gl-repeater")

		-- If a configured STA currently uses the other radio, move it to
		-- the selected band immediately.  Keep SSID/credentials, but drop
		-- a band-specific BSSID lock so a dual-band/mesh SSID can roam to
		-- an AP on the requested band.
		local iface = repeater_iface(cursor)
		local wanted_radio = radio_for_band(cursor, lock_band)
		if iface and wanted_radio
			and cursor:get("wireless", iface, "device") ~= wanted_radio then
			cursor:set("wireless", iface, "device", wanted_radio)
			cursor:delete("wireless", iface, "bssid")
			cursor:set("wireless", iface, "disabled", "0")
			cursor:commit("wireless")
			os.execute("wifi reload >/dev/null 2>&1")
		end
		return {}
	end,

	disconnect = function(args)
		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		if iface then
			cursor:set("wireless", iface, "disabled", "1")
			cursor:commit("wireless")
			os.execute("wifi reload >/dev/null 2>&1")
		end
		return {}
	end,

	-- Re-enable an already-configured (but disabled) repeater uplink -
	-- distinct from set_config, which creates/replaces the config itself.
	connect = function(args)
		if args and args.ssid then return apply_config(args) end
		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		if not iface then
			return { code = 1, message = "no repeater configured" }
		end
		cursor:set("wireless", iface, "disabled", "0")
		cursor:commit("wireless")
		os.execute("wifi reload >/dev/null 2>&1")
		return {}
	end,

	-- Saved upstream-AP history (distinct from the live single "current"
	-- config in get_config/set_config) - a simple UCI list, appended to
	-- on every successful set_config. manual/auto_portal/disguise are
	-- always false and protocol always "dhcp" - this port doesn't track
	-- a manually-added-vs-auto-detected flag, a captive-portal auto-login
	-- flag, or per-network protocol overrides.
	get_saved_ap_list = function(args)
		local cursor = uci.cursor()
		local saved = {}
		cursor:foreach("gl-repeater", "saved_ap", function(s)
			table.insert(saved, {
				id = s[".name"], ssid = s.ssid, radio = s.radio,
				manual = false, auto_portal = false, disguise = false,
				protocol = "dhcp",
				macaddr = { mode = "default", update = "none" },
			})
		end)
		return { res = as_array(saved) }
	end,

	remove_saved_ap = function(args)
		if not args.id then
			return { code = 1, message = "missing id" }
		end
		local cursor = uci.cursor()
		cursor:delete("gl-repeater", args.id)
		cursor:commit("gl-repeater")
		return {}
	end,

	-- "Bare mode": temporarily drop the repeater's own AP-side WiFi so a
	-- laptop can plug in directly via ethernet during setup, avoiding a
	-- double-hop through the very uplink being configured. NOT YET WIRED
	-- to real AP-radio disable/restore logic - recorded as an honest
	-- "not yet supported" no-op rather than a fake success, since getting
	-- this wrong could strand a WiFi-only management session.
	enter_bare_mode = function(args)
		return { code = 1, message = "bare mode not yet supported" }
	end,

	exit_bare_mode = function(args)
		return {}
	end,

	-- Channel-conflict warning: if the repeater's own AP and the chosen
	-- upstream network would need to share a channel/radio, the real UI
	-- shows a confirmation prompt before applying. popup_prompt_en/
	-- chan_prompt_en are feature-enabled flags, both always true - actual
	-- conflict detection isn't implemented yet (mt76 auto-negotiates
	-- channel to match the STA uplink in practice).
	get_channel_prompt = function(args)
		return { popup_prompt_en = true, chan_prompt_en = true }
	end,

	set_channel_prompt = function(args)
		return {}
	end,

	-- state is an int enum (0=idle, 1=connecting, 2=connected,
	-- 3=retrying), state_s its string label. fail_type is "not-found" while
	-- gl-repeater-timeout is backing off an upstream network it couldn't
	-- reach, matching the fail_type the stock UI already knows how to
	-- render. portal_info is a fixed "no captive portal pending" stub -
	-- this port has no captive-portal-login flow. connected/ssid/ipaddr/
	-- signal are extra fields beyond the minimal real shape.
	get_status = function(args)
		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		local portal_info = { auth_mode = 0, username = "", password = "", voucher = "" }
		if not iface then
			return { connected = false, state = 0, state_s = "idle", portal_info = portal_info }
		end

		local conn = ubus.connect()
		local net_status = nil
		if conn then
			net_status = conn:call("network.interface.repeater", "status", {})
			conn:close()
		end

		local dev = real_ifname(iface)
		local t = iwinfo.type(dev)
		local radio_info = {}
		if t then
			local ok, info = pcall(function() return iwinfo[t].info(dev) end)
			if ok and type(info) == "table" then radio_info = info end
			-- libiwinfo's Lua binding does not expose `info()` uniformly
			-- across all backends/releases.  Its scalar getters are stable,
			-- so fill any missing fields from those as well.
			for _, key in ipairs({ "ssid", "bssid", "channel", "signal" }) do
				if radio_info[key] == nil and type(iwinfo[t][key]) == "function" then
					local value_ok, value = pcall(function()
						return iwinfo[t][key](dev)
					end)
					if value_ok then radio_info[key] = value end
				end
			end
			-- In client mode nl80211's generic info/bssid getter reports
			-- the STA interface's own address on this mt76 release.  The
			-- association list contains the actual AP peer/BSSID.
			if type(iwinfo[t].assoclist) == "function" then
				local assoc_ok, stations = pcall(function()
					return iwinfo[t].assoclist(dev)
				end)
				if assoc_ok and type(stations) == "table" then
					for station_key, station in pairs(stations) do
						local peer = type(station) == "table"
							and (station.mac or station.bssid) or nil
						if not peer and type(station_key) == "string"
							and station_key:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
							peer = station_key
						end
						if peer then
							radio_info.bssid = peer:upper()
							if type(station) == "table" and station.signal then
								radio_info.signal = station.signal
							end
							break
						end
					end
				end
			end
		end

		local ipv4_address = net_status and net_status["ipv4-address"]
			and net_status["ipv4-address"][1]
			and net_status["ipv4-address"][1].address or nil
		local gateway = ""
		for _, route in ipairs(net_status and net_status.route or {}) do
			if tonumber(route.mask) == 0 and route.nexthop then
				gateway = route.nexthop
				break
			end
		end
		local dns = net_status and net_status["dns-server"] or {}
		local admin_disabled = cursor:get("wireless", iface, "disabled") == "1"
		-- gl-repeater-timeout also flips this same "disabled" flag while it
		-- backs off an upstream network it couldn't find, so a pending
		-- retry (retry-at in the future) reads as "retrying", not "idle".
		local retry_at = tonumber(read_trim("/tmp/gl-repeater-retry-at"))
		local backing_off = admin_disabled and retry_at ~= nil and retry_at > os.time()
		local disabled = admin_disabled and not backing_off
		local connected = not disabled and net_status and net_status.up == true
			and ipv4_address ~= nil or false
		local fail_type = backing_off and read_trim("/tmp/gl-repeater-fail-type") or nil
		local state
		if disabled then
			state = 0
		elseif connected then
			state = 2
		elseif net_status and (net_status.pending == true or net_status.up == true) then
			state = 1
		else
			-- A configured/enabled STA which is neither pending nor up is
			-- in the retry state, not disabled.
			state = 3
		end

		local channel = tonumber(radio_info.channel)
		local band = channel and (channel <= 14 and "2g" or "5g") or nil
		local ssid = radio_info.ssid or cursor:get("wireless", iface, "ssid")
		local macaddr = nil
		local mac_file = io.open("/sys/class/net/" .. dev .. "/address", "r")
		if mac_file then
			macaddr = mac_file:read("*l")
			mac_file:close()
		end
		local config = {
			ssid = cursor:get("wireless", iface, "ssid"),
			bssid = cursor:get("wireless", iface, "bssid"),
			protocol = cursor:get("network", "repeater", "proto") or "dhcp",
			identity = cursor:get("wireless", iface, "identity"),
			auto_portal = false,
			disguise = false,
		}

		return {
			connected = connected,
			state = state,
			state_s = state == 2 and "connected"
				or state == 1 and "connecting"
				or state == 3 and "retrying" or "idle",
			fail_type = fail_type,
			portal_info = portal_info,
			config = config,
			ssid = ssid,
			bssid = radio_info.bssid,
			macaddr = macaddr,
			channel = channel,
			band = band,
			dfs = channel and channel >= 52 and channel <= 144 or false,
			signal = radio_info.signal,
			ipv4 = {
				ip = ipv4_address or "",
				gateway = gateway,
				dns = as_array(dns),
			},
		}
	end,
}
