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
-- get_repeater_portal, scan, set_channel_prompt, set_config,
-- set_repeater_portal.

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

local PORTAL_STATE = "/tmp/gl-repeater-portal.json"

local function read_portal_state()
	local f = io.open(PORTAL_STATE, "r")
	if not f then
		return {
			detected = false, detecting = false, portal_url = "",
			bare_mode = false, status = "idle",
		}
	end
	local raw = f:read("*a")
	f:close()
	local ok, state = pcall(cjson.decode, raw)
	if ok and type(state) == "table" then return state end
	return { detected = false, detecting = false, portal_url = "", bare_mode = false }
end

local function write_portal_state(state)
	local tmp = PORTAL_STATE .. ".rpc"
	local f = io.open(tmp, "w")
	if not f then return end
	f:write(cjson.encode(state))
	f:close()
	os.rename(tmp, PORTAL_STATE)
end

-- gl-repeater-timeout persists a scheduled re-enable time across a manual
-- disconnect/reconfigure.  A portal/repeater action must clear that pending
-- retry or the watchdog can silently reconnect an aborted network later.
local function clear_retry_state()
	os.execute("rm -f /tmp/gl-repeater-retry-at /tmp/gl-repeater-fail-type /tmp/gl-repeater-eap-autofix-count /tmp/gl-repeater-retry-count")
end

local function set_portal_gate(enabled)
	local f = io.open("/proc/net/wifidog-ng/config", "w")
	if not f then return false end
	f:write("enabled=" .. (enabled and "1" or "0") .. "\n")
	f:close()
	return true
end

local function as_list(value)
	if type(value) == "table" then return value end
	if value == nil or value == "" then return {} end
	return { value }
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function dnsmasq_confdir(cursor)
	local section
	cursor:foreach("dhcp", "dnsmasq", function(candidate)
		if not section then section = candidate[".name"] end
	end)
	if not section then return nil end
	local directory = cursor:get("dhcp", section, "confdir")
	if not directory or directory == "" then
		directory = "/tmp/dnsmasq." .. section .. ".d"
	end
	return directory
end

local function repeater_dns(cursor)
	local conn = ubus.connect()
	local status
	if conn then
		status = conn:call("network.interface.repeater", "status", {})
		conn:close()
	end
	if status and type(status["dns-server"]) == "table" then
		return status["dns-server"]
	end
	return as_list(cursor:get("network", "repeater", "dns"))
end

-- During portal login LAN clients must use the DNS learned by the repeater
-- uplink.  Otherwise a stale VPN/AdGuard/custom dnsmasq server can prevent
-- the URL supplied by the upstream captive network from resolving.  Use a
-- tmpfs dnsmasq include instead of changing /etc/config/dhcp, so leaving
-- portal mode (or rebooting) automatically restores the normal resolver.
-- Idempotent: only reload dnsmasq when the include actually changes, so a
-- disconnect (or any other path that calls restore with nothing pending)
-- doesn't bounce the resolver for nothing.
local function set_portal_dns(cursor, dns)
	local directory = dnsmasq_confdir(cursor)
	if not directory then return false end
	local path = directory .. "/gl-repeater-portal.conf"
	local servers = as_list(dns)
	if #servers == 0 then
		return false
	end

	local lines = { "no-resolv" }
	local valid = 0
	for _, server in ipairs(servers) do
		server = tostring(server)
		if server:match("^[%x%.:]+$") then
			lines[#lines + 1] = "server=" .. server
			valid = valid + 1
		end
	end
	if valid == 0 then return false end
	local content = table.concat(lines, "\n") .. "\n"

	local existing = io.open(path, "r")
	if existing then
		local current = existing:read("*a")
		existing:close()
		if current == content then return true end
	end

	os.execute("mkdir -p " .. shell_quote(directory) .. " >/dev/null 2>&1")
	local temp = path .. ".new"
	local file = io.open(temp, "w")
	if not file then return false end
	file:write(content)
	file:close()
	os.rename(temp, path)
	os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	return true
end

local function restore_portal_dns(cursor)
	local directory = dnsmasq_confdir(cursor)
	if not directory then return false end
	local path = directory .. "/gl-repeater-portal.conf"
	os.remove(path .. ".new")
	local existing = io.open(path, "r")
	if not existing then return false end
	existing:close()
	os.remove(path)
	os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	return true
end

local function bool_value(value)
	return value == true or value == 1 or value == "1" or value == "true"
end

local function portal_info(cursor, section)
	local function get(option, fallback)
		local value = section and section[option]
		if value == nil then
			value = cursor:get("gl-repeater", "settings", option)
		end
		return value == nil and fallback or value
	end

	local raw_mode = get("portal_auth_mode", "0")
	local mode = tonumber(raw_mode) or 0
	return {
		auth_mode_raw = tostring(raw_mode),
		auth_mode = mode,
		one_click = bool_value(get("portal_one_click", "0")),
		username = get("portal_username", "") or "",
		password = get("portal_password", "") or "",
		voucher = get("portal_voucher", "") or "",
	}
end

local function current_saved(cursor, iface)
	local ssid = iface and cursor:get("wireless", iface, "ssid")
	local found
	cursor:foreach("gl-repeater", "saved_ap", function(section)
		if (iface and section.iface == iface)
			or (ssid and section.ssid == ssid and not found) then
			found = section
		end
	end)
	return found
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
	-- A new uplink invalidates any DNS snapshot taken for the previous portal.
	restore_portal_dns(cursor)
	local iface = repeater_iface(cursor)
	if not iface then
		iface = cursor:add("wireless", "wifi-iface")
		cursor:set("wireless", iface, "network", "repeater")
		cursor:set("wireless", iface, "mode", "sta")
	end

	-- Does this payload actually carry credentials? The saved-network list
	-- only sends the SSID (plus remember), so without this check a plain
	-- reconnect would fall through to the "no secret" branch and rewrite the
	-- uplink as an OPEN network, dropping the EAP/personal config - which is
	-- why a saved WPA2-Enterprise network had to be deleted and re-added.
	local provided = args.identity ~= nil or args.eap_type ~= nil
		or args.auth ~= nil or args.key ~= nil or args.password ~= nil
		or args.encryption ~= nil

	-- The saved record for this SSID (the section name, not the section
	-- table - cursor:set() needs a name and used to be handed the table,
	-- which made every save of an already-known network throw an "internal
	-- error" *after* the open-config commit above had already gone through).
	local saved_section
	cursor:foreach("gl-repeater", "saved_ap", function(s)
		if not saved_section and (s.ssid == args.ssid or s.iface == iface) then
			saved_section = s[".name"]
		end
	end)

	-- Recover the previously-used security so a bare reconnect keeps it.
	local function prior_security()
		local cfg, sec = nil, nil
		if saved_section then cfg, sec = "gl-repeater", saved_section end
		if cursor:get("wireless", iface, "ssid") == args.ssid then
			-- Prefer the live uplink when it is already this SSID: on the
			-- first save after this change the saved_ap has no stored
			-- security yet, but the iface does.
			cfg, sec = "wireless", iface
		end
		if not cfg then return {} end
		return {
			encryption = cursor:get(cfg, sec, "encryption"),
			eap_type = cursor:get(cfg, sec, "eap_type"),
			auth = cursor:get(cfg, sec, "auth"),
			identity = cursor:get(cfg, sec, "identity"),
			anonymous_identity = cursor:get(cfg, sec, "anonymous_identity"),
			ca_cert = cursor:get(cfg, sec, "ca_cert"),
			key = cursor:get(cfg, sec, "key"),
			password = cursor:get(cfg, sec, "password"),
		}
	end
	if not provided then
		local prior = prior_security()
		for _, field in ipairs({ "encryption", "eap_type", "auth", "identity",
			"anonymous_identity", "ca_cert", "key", "password" }) do
			if prior[field] ~= nil and prior[field] ~= "" then
				args[field] = prior[field]
			end
		end
		-- Still nothing: it genuinely is an open network.
		if args.encryption == nil then args.encryption = "none" end
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
		or (args.auth ~= nil and args.auth ~= "")
	if enterprise then
		cursor:set("wireless", iface, "encryption", "wpa2")
		local eap_type = (args.eap_type or "peap"):lower()
		-- hostapd/wpa_supplicant want the inner ("phase2") method here, e.g.
		-- MSCHAPV2. "EAP-MSCHAPV2" is not a valid auth value and silently
		-- fails the handshake - both PEAP and TTLS tunnel MSCHAPV2 by
		-- default, so accept any explicit value except that one.
		local auth = args.auth
		if not auth or auth == "" or auth == "EAP-MSCHAPV2" then
			auth = "MSCHAPV2"
		end
		cursor:set("wireless", iface, "eap_type", eap_type)
		cursor:set("wireless", iface, "auth", auth)
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
		cursor:delete("wireless", iface, "identity")
		cursor:delete("wireless", iface, "password")
	end
	cursor:commit("wireless")

	if args.protocol then
		cursor:set("network", "repeater", "proto",
			args.protocol == "static" and "static" or "dhcp")
		if args.protocol == "static" then
			if args.ipaddr or args.ip then
				cursor:set("network", "repeater", "ipaddr", args.ipaddr or args.ip)
			end
			if args.netmask then cursor:set("network", "repeater", "netmask", args.netmask) end
			if args.gateway then cursor:set("network", "repeater", "gateway", args.gateway) end
			if args.dns then cursor:set("network", "repeater", "dns", args.dns) end
		end
		cursor:commit("network")
	end

	local auto_portal = args.auto_portal
	if auto_portal == nil then
		auto_portal = cursor:get("gl-repeater", "settings", "auto_portal") == "1"
	else
		auto_portal = bool_value(auto_portal)
	end
	cursor:set("gl-repeater", "settings", "settings")
	cursor:set("gl-repeater", "settings", "auto_portal", auto_portal and "1" or "0")

	if not saved_section then
		saved_section = cursor:add("gl-repeater", "saved_ap")
	end
	cursor:set("gl-repeater", saved_section, "ssid", args.ssid)
	cursor:set("gl-repeater", saved_section, "radio", radio)
	cursor:set("gl-repeater", saved_section, "iface", iface)
	cursor:set("gl-repeater", saved_section, "auto_portal", auto_portal and "1" or "0")
	cursor:set("gl-repeater", saved_section, "protocol", args.protocol or
		(cursor:get("network", "repeater", "proto") or "dhcp"))

	-- Persist the security per saved network (the uplink iface is a single
	-- shared section that the next network overwrites, so the saved record
	-- cannot just point at it).
	for _, field in ipairs({ "encryption", "eap_type", "auth", "identity",
		"anonymous_identity", "ca_cert", "password", "key" }) do
		local value = cursor:get("wireless", iface, field)
		if value and value ~= "" then
			cursor:set("gl-repeater", saved_section, field, value)
		else
			cursor:delete("gl-repeater", saved_section, field)
		end
	end

	-- Saved portal credentials are optional.  Keep existing credentials when a
	-- normal WiFi join does not carry portal fields, but accept both spellings
	-- seen in the GL frontend/backend boundary.
	local supplied_portal = args.portal_info or args.portalInfo
	if type(supplied_portal) == "table" then
		local fields = {
			{ "auth_mode", "portal_auth_mode" },
			{ "one_click", "portal_one_click" },
			{ "username", "portal_username" },
			{ "password", "portal_password" },
			{ "voucher", "portal_voucher" },
		}
		for _, field in ipairs(fields) do
			local value = supplied_portal[field[1]]
			if value ~= nil then
				cursor:set("gl-repeater", saved_section, field[2],
					(field[1] == "one_click" and bool_value(value) and "1" or
					 field[1] == "one_click" and "0" or tostring(value)))
			end
		end
	end
	cursor:commit("gl-repeater")

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
			auth = cursor:get("wireless", iface, "auth"),
			anonymous_identity = cursor:get("wireless", iface, "anonymous_identity"),
			ca_cert = cursor:get("wireless", iface, "ca_cert"),
			identity = cursor:get("wireless", iface, "identity"),
			key = cursor:get("wireless", iface, "key")
				or cursor:get("wireless", iface, "password"),
			auto_portal = cursor:get("gl-repeater", "settings", "auto_portal") == "1",
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
		clear_retry_state()
		local cursor = uci.cursor()
		restore_portal_dns(cursor)
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
		clear_retry_state()
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

	-- Captive-portal credentials are a separate part of the original GL
	-- repeater API.  Keep them in the gl-repeater settings section for the
	-- currently selected uplink; saved_ap sections get a copy below.
	get_repeater_portal = function(args)
		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		local info = portal_info(cursor, current_saved(cursor, iface))
		return { res = info, portal_info = info }
	end,

	set_repeater_portal = function(args)
		args = args or {}
		local auth_mode = tonumber(args.auth_mode or 0)
		if not auth_mode or auth_mode < 0 or auth_mode > 4
			or auth_mode ~= math.floor(auth_mode) then
			return { code = 1, message = "invalid auth_mode" }
		end
		if args.one_click ~= nil and type(args.one_click) ~= "boolean"
			and type(args.one_click) ~= "number" and type(args.one_click) ~= "string" then
			return { code = 1, message = "invalid one_click" }
		end
		for _, name in ipairs({ "username", "password", "voucher" }) do
			if args[name] ~= nil and type(args[name]) ~= "string" then
				return { code = 1, message = "invalid " .. name }
			end
		end

		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		local saved = current_saved(cursor, iface)
		local old_info = portal_info(cursor, saved)
		local values = {
			portal_auth_mode = tostring(auth_mode),
			portal_one_click = args.one_click == nil and (old_info.one_click and "1" or "0")
				or (bool_value(args.one_click) and "1" or "0"),
			portal_username = args.username == nil and old_info.username or args.username,
			portal_password = args.password == nil and old_info.password or args.password,
			portal_voucher = args.voucher == nil and old_info.voucher or args.voucher,
		}
		for name, value in pairs(values) do
			cursor:set("gl-repeater", "settings", name, value)
			if saved then cursor:set("gl-repeater", saved, name, value) end
		end
		if args.save_config ~= false then
			cursor:commit("gl-repeater")
		end
		return {}
	end,

	-- Saved upstream-AP history (distinct from the live single "current"
	-- config in get_config/set_config).  The stock UI consumes portal_info
	-- from this list when the user opens a saved network for editing.
	get_saved_ap_list = function(args)
		local cursor = uci.cursor()
		local saved = {}
		cursor:foreach("gl-repeater", "saved_ap", function(s)
			-- Per-network security written by apply_config. Fall back to the
			-- shared uplink iface for records created before that existed.
			local function field(name)
				local value = cursor:get("gl-repeater", s[".name"], name)
				if (value == nil or value == "") and s.iface then
					value = cursor:get("wireless", s.iface, name)
				end
				return value
			end
			local password = field("password")
			table.insert(saved, {
				id = s[".name"], ssid = s.ssid, radio = s.radio,
				key = field("key") or password,
				identity = field("identity"), password = password,
				encryption = field("encryption"),
				eap_type = field("eap_type"), auth = field("auth"),
				anonymous_identity = field("anonymous_identity"),
				ca_cert = field("ca_cert"),
				manual = s.manual == "1", auto_portal = s.auto_portal == "1",
				disguise = s.disguise == "1",
				protocol = s.protocol or "dhcp",
				macaddr = { mode = "default", update = "none" },
				portal_info = portal_info(cursor, s),
			})
		end)
		return { res = as_array(saved) }
	end,

	remove_saved_ap = function(args)
		args = args or {}
		local cursor = uci.cursor()
		local id = args.id
		if not id and args.ssid then
			cursor:foreach("gl-repeater", "saved_ap", function(s)
				if s.ssid == args.ssid then id = s[".name"] end
			end)
		end
		if not id then return { code = 1, message = "missing id or ssid" } end
		cursor:delete("gl-repeater", id)
		cursor:commit("gl-repeater")
		return {}
	end,

	-- "Bare mode" is the stock portal-login mode, not an AP-radio mode in this
	-- STA/double-NAT port.  Disable the LAN captive gate so a LAN client can
	-- reach the upstream portal directly; leaving the management AP alive is
	-- essential because the stock UI immediately opens the portal URL in a
	-- browser connected to that AP.
	enter_bare_mode = function(args)
		local cursor = uci.cursor()
		set_portal_dns(cursor, repeater_dns(cursor))
		set_portal_gate(false)
		local state = read_portal_state()
		state.bare_mode = true
		state.auto_bare_mode = false
		state.updated = os.time()
		write_portal_state(state)
		return {}
	end,

	exit_bare_mode = function(args)
		-- This port leaves the wifidog gate disabled after authentication.  The
		-- original firmware repopulates a private allow-list here; enabling an
		-- empty allow-list on mainline would cut off every LAN client.
		local cursor = uci.cursor()
		restore_portal_dns(cursor)
		set_portal_gate(false)
		local state = read_portal_state()
		state.bare_mode = false
		state.auto_bare_mode = false
		state.updated = os.time()
		write_portal_state(state)
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
	-- 3=retrying), state_s its string label.  The stock Internet page consumes
	-- portal, portal_url, bare_mode and auto_portal directly from this result
	-- and subscribes to it as repeater.status over the websocket.
	get_status = function(args)
		local cursor = uci.cursor()
		local iface = repeater_iface(cursor)
		local saved = current_saved(cursor, iface)
		local current_portal_info = portal_info(cursor, saved)
		local portal_state = read_portal_state()
		local auto_portal = cursor:get("gl-repeater", "settings", "auto_portal") == "1"
		if not iface then
			return {
				connected = false, state = 0, state_s = "idle",
				portal = portal_state.detected == true,
				portal_url = portal_state.portal_url or "",
				portal_detecting = portal_state.detecting == true,
				portal_status = portal_state.status or "idle",
				bare_mode = portal_state.bare_mode == true,
				auto_portal = auto_portal,
				portal_info = current_portal_info,
			}
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
			key = cursor:get("wireless", iface, "key")
				or cursor:get("wireless", iface, "password"),
			identity = cursor:get("wireless", iface, "identity"),
			auto_portal = auto_portal,
			disguise = false,
		}

		return {
			connected = connected,
			state = state,
			state_s = state == 2 and "connected"
				or state == 1 and "connecting"
			or state == 3 and "retrying" or "idle",
			fail_type = fail_type,
			portal = portal_state.detected == true,
			portal_url = portal_state.portal_url or "",
			portal_detecting = portal_state.detecting == true,
			portal_status = portal_state.status or "idle",
			bare_mode = portal_state.bare_mode == true,
			auto_portal = auto_portal,
			portal_info = current_portal_info,
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
