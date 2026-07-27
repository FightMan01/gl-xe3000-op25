-- "ui" RPC object: app-shell bootstrap (menu, language, first-run wizard).
-- Method set: get_menu_list, get_remote_langs, set_inited_internet,
-- set_lang, update_langs. get_menu_list is load-bearing for the whole
-- app-shell navigation - the frontend does not read
-- /usr/share/oui/menu.d/*.json directly, so this reads and merges those
-- same files server-side.
--
-- Runs inside the nginx worker (LuaJIT), loaded via dofile/loadfile by
-- oui-rpc.lua - see /etc/config/gl-oui-rpc's no_auth 'ui' section for
-- which of these are reachable pre-login. Pre-login calls (before a
-- session exists) pass an empty session id rather than omitting it.

local uci = require "uci"
local cjson = require "cjson"
local ubus = require "ubus"
-- Keep factory identity/country hot-reloadable with the RPC object.
local factory = dofile("/usr/lib/lua/gloui/factory.lua")

local MENU_DIR = "/usr/share/oui/menu.d"
local I18N_DIR = "/www/i18n"

-- This port only ever runs in router mode (no AP-only/WDS/mesh-agent/
-- relay system-mode switching implemented - repeater is a feature of
-- router mode here, not a distinct system mode). menu.d entries'
-- show_mode/hidden_mode lists are filtered against this fixed value;
-- revisit if a real netmode object is ever added.
local CURRENT_MODE = "router"

local LANGS = {
	{ id = 1, value = "en", label = "English" },
	{ id = 2, value = "zh-cn", label = "简体中文" },
	{ id = 3, value = "zh-tw", label = "繁體中文" },
	{ id = 4, value = "ja", label = "日本語" },
	{ id = 5, value = "de", label = "Deutsch" },
	{ id = 6, value = "es", label = "Español" },
	{ id = 7, value = "it", label = "Italiano" },
}

-- Finds the AP wifi-iface bound to a given radio on the "lan" network -
-- same lookup wifi.lua's own radio_iface() does. Duplicated here since
-- RPC object files are independently dofile()'d, not shared modules.
local function radio_iface(cursor, radio)
	local iface = nil
	cursor:foreach("wireless", "wifi-iface", function(s)
		if s.device == radio and s.mode == "ap" and s.network == "lan" then
			iface = s[".name"]
		end
	end)
	return iface
end

-- Same empty-vs-locked/no-password /etc/shadow convention as oui-rpc.lua's
-- root_password_is_set() (duplicated here for the same reason as
-- radio_iface above): empty field means no password set yet.
local function root_password_is_set()
	local f = io.open("/etc/shadow", "r")
	if not f then return true end
	for line in f:lines() do
		local user, enc = line:match("^([^:]+):([^:]*):")
		if user == "root" then
			f:close()
			return enc ~= ""
		end
	end
	f:close()
	return true
end

return {
	get_lang = function(args)
		local cursor = uci.cursor()
		local lang = cursor:get("gl-oui-rpc", "main", "lang") or "en"
		return { lang = lang, list = LANGS }
	end,

	-- App-shell root bootstrap check, separate from and in addition to
	-- oui-rpc.lua's `alive` method (which only gates the login page).
	-- This gates the whole app shell on every load: `initialized` false
	-- routes straight to the first-run wizard, same meaning as
	-- root_password_is_set().
	--
	-- time_info's fields (api_extra/reboot/init/upgrade) match the Vuex
	-- `specificTime` getter read throughout the app shell to size various
	-- post-action wait timers. inited_internet reuses this file's own UCI
	-- flag (set by set_inited_internet/init).
	check_initialized = function(args)
		local cursor = uci.cursor()
		local mac = nil
		local mf = io.open("/sys/class/net/eth1/address", "r")
		if mf then
			mac = (mf:read("*l") or ""):upper()
			mf:close()
		end
		local release = (function()
			local f = io.open("/etc/openwrt_release", "r")
			if not f then return "" end
			local data = f:read("*a")
			f:close()
			return data
		end)()
		return {
			initialized = root_password_is_set(),
			hostname = (function()
				local p = io.popen("uname -n")
				if not p then return "OpenWrt" end
				local n = p:read("*l")
				p:close()
				return n or "OpenWrt"
			end)(),
			model = "xe3000",
			mac = mac,
			firmware_version = release:match("DISTRIB_RELEASE='([^']+)'") or "unknown",
			security_rule = tonumber((cursor:get("gl-oui-rpc", "main", "security_rule"))) or 1,
			-- The frontend's destructuring default ({firmware_category:i=
			-- "2c"}) only fires on undefined, not on an empty string, so
			-- this must never be "".
			firmware_category = "2c",
			support_screen_init = false,
			partner = "",
			environment_support = false,
			inited_agent = false,
			vpn_wizard_done = false,
			inited_internet = cursor:get("gl-oui-rpc", "main", "inited_internet") == "1",
			time_info = { api_extra = 15, reboot = 120, init = 10, upgrade = 240 },
		}
	end,

	-- On failure the caller retries indefinitely, so a broken
	-- implementation here can make the whole first-boot wizard hang
	-- rather than show one broken widget.
	--
	-- Response is `{ locales: [ <dict>, <dict>, ... ] }` - an array of
	-- flat key/value translation dictionaries merged together
	-- client-side. Built here by reading every shipped
	-- gl-sdk4-ui-*.<locale>.json file for the requested locale.
	load_locales = function(args)
		local locale = args.locale
		-- Sanitize before use in a shell glob (io.popen) - args.locale is
		-- client-controlled input, this is a command-injection boundary.
		if type(locale) ~= "string" or not locale:match("^[%a][%a%-]*$") then
			locale = "en"
		end
		local locales = {}
		local p = io.popen("ls " .. I18N_DIR .. "/*." .. locale .. ".json 2>/dev/null")
		if p then
			for path in p:lines() do
				local f = io.open(path, "r")
				if f then
					local data = f:read("*a")
					f:close()
					local ok, decoded = pcall(cjson.decode, data)
					if ok and type(decoded) == "table" then
						table.insert(locales, decoded)
					end
				end
			end
			p:close()
		end
		return { locales = locales }
	end,

	-- Response is completely flat: both level:1 top-level items
	-- (internet/wireless/clients/...) and level:2 child items
	-- (acl-view/bridge/dnsview/...) are their own top-level array
	-- elements. Each level:2 entry carries its own parent/parent_icon/
	-- parent_index/parent_title fields directly - there is no
	-- server-built parent node and no `children` key anywhere. level:0
	-- entries are included too, for client-side route registration
	-- without a sidebar entry.
	--
	-- This is a near-verbatim passthrough of menu.d's own already-flat
	-- records: no tree-building, no synthesized titles, no level
	-- filtering - just the mode-visibility fields (show_mode/hidden_mode)
	-- those files already carry.
	get_menu_list = function(args)
		local entries = {}
		local p = io.popen("ls " .. MENU_DIR .. "/*.json 2>/dev/null")
		if p then
			for path in p:lines() do
				local f = io.open(path, "r")
				if f then
					local data = f:read("*a")
					f:close()
					local ok, entry = pcall(cjson.decode, data)
					if ok and type(entry) == "table" then
						table.insert(entries, entry)
					end
				end
			end
			p:close()
		end

		local function mode_allowed(entry)
			if entry.show_mode then
				local ok = false
				for _, m in ipairs(entry.show_mode) do
					if m == CURRENT_MODE then ok = true end
				end
				if not ok then return false end
			end
			if entry.hidden_mode then
				for _, m in ipairs(entry.hidden_mode) do
					if m == CURRENT_MODE then return false end
				end
			end
			return true
		end

		local menus = {}
		for _, entry in ipairs(entries) do
			if mode_allowed(entry) then
				table.insert(menus, entry)
			end
		end

		-- Defensive cjson.empty_array guard (see get_remote_langs below) -
		-- MENU_DIR should never actually be empty in practice, but if it
		-- ever were, an empty `menus` must still serialize as "[]", not
		-- "{}", since the app-shell bootstrap does `menus.length` /
		-- iterates it directly.
		if next(menus) == nil then menus = cjson.empty_array end
		return { menus = menus }
	end,

	-- Available downloadable language packs - no remote update source
	-- wired up, so this stays a stub (empty list, feature disabled).
	-- Shape combines the pack list with an auto-update-schedule
	-- sub-object, flattened into one result:
	--   { list:[{id,label,value}, ...], enable, hour, min, week, status }
	get_remote_langs = function(args)
		return {
			-- cjson.empty_array: an empty plain Lua table has no integer
			-- keys, so the vendored lua-cjson encodes it as "{}" not "[]" -
			-- breaks any frontend code calling .map/.some/.forEach on this
			-- (see the patched-cjson sentinel note, clients.lua's as_array
			-- for the fuller explanation).
			list = cjson.empty_array,
			enable = false,
			hour = "00",
			min = "00",
			week = { 0, 1, 2, 3, 4, 5, 6 },
			status = 0,
		}
	end,

	set_lang = function(args)
		if type(args.lang) ~= "string" then
			return { code = 1, message = "missing lang" }
		end
		local cursor = uci.cursor()
		cursor:set("gl-oui-rpc", "main", "main")
		cursor:set("gl-oui-rpc", "main", "lang", args.lang)
		cursor:commit("gl-oui-rpc")
		-- Frontend reads this back to sync its own lang state rather than
		-- trusting its own request echo.
		return { lang = args.lang }
	end,

	-- Marks the setup-wizard's "internet configured" step done - a plain
	-- UCI flag, no other side effect.
	set_inited_internet = function(args)
		local cursor = uci.cursor()
		cursor:set("gl-oui-rpc", "main", "main")
		cursor:set("gl-oui-rpc", "main", "inited_internet", "1")
		cursor:commit("gl-oui-rpc")
		return {}
	end,

	update_langs = function(args)
		return { code = 1, message = "no remote language update source configured" }
	end,

	-- Pre-fills the welcome/first-boot wizard's WiFi step. Only 2.4G/5G
	-- are real on this hardware (two MT7915 radios, no 6G/MLO) - 6g/mlo
	-- fields are always reported disabled/absent.
	--
	-- ht160support gates the wizard's 160MHz toggle entirely client-side;
	-- phy1 (radio1, 5GHz) supports HE160, phy0 (2.4GHz) never supports
	-- 160MHz channels per the 802.11 spec, so this is unconditionally
	-- true for this device rather than read per-radio.
	get_wifi_config_init = function(args)
		local cursor = uci.cursor()
		local if2g = radio_iface(cursor, "radio0")
		local if5g = radio_iface(cursor, "radio1")
		local out = {
			enabled_wifi = cursor:get("wireless", "radio0", "disabled") ~= "1",
			enabled_wifi_5g = cursor:get("wireless", "radio1", "disabled") ~= "1",
			enabled_wifi_6g = false,
			enabled_wifi_mlo = false,
			ht160support = true,
			mlo_support = false,
		}
		if if2g then
			out.ssid = cursor:get("wireless", if2g, "ssid")
			out.password_wifi = cursor:get("wireless", if2g, "key")
		end
		if if5g then
			out.ssid_5g = cursor:get("wireless", if5g, "ssid")
			out.password_wifi_5g = cursor:get("wireless", if5g, "key")
		end
		return out
	end,

	-- Single combined "finish first-time setup" call: password, language,
	-- timezone, and (optionally) WiFi setup in one request. setUpWifi's
	-- fields match get_wifi_config_init's response shape
	-- (ssid/password_wifi[_5g]/enabled_wifi[_5g]) - only those are
	-- applied. htmode_160 toggles radio1 between HE80/HE160.
	--
	-- Reconfiguring WiFi here will drop the caller's own WiFi connection,
	-- same as any router's first-run wizard - the frontend expects this
	-- and polls http://192.168.8.1 afterward rather than assuming the
	-- connection survives.
	--
	-- After changing the root password, any session opened with the old
	-- credentials keeps looking valid-shaped client-side (cookie present)
	-- while being unrecognized server-side, since gl-ngx-session's
	-- session table doesn't survive a password change automatically.
	-- Explicitly clearing all sessions here makes that cookie
	-- unambiguously invalid client-side too, forcing a clean login
	-- instead of a stuck retry loop.
	init = function(args)
		local cursor = uci.cursor()
		local country = factory.get().country

		if type(args.password) == "string" and #args.password > 0 then
			local f = io.popen("passwd root", "w")
			if f then
				f:write(args.password, "\n", args.password, "\n")
				f:close()
			end
			local conn = ubus.connect()
			if conn then
				conn:call("gl-session", "clear_session", {})
				conn:close()
			end
		end

		if type(args.lang) == "string" then
			cursor:set("gl-oui-rpc", "main", "main")
			cursor:set("gl-oui-rpc", "main", "lang", args.lang)
		end
		if type(args.timezone) == "string" then
			cursor:set("system", "@system[0]", "timezone", args.timezone)
		end
		if type(args.zonename) == "string" then
			cursor:set("system", "@system[0]", "zonename", args.zonename)
		end
		cursor:commit("system")

		local if2g = radio_iface(cursor, "radio0")
		local if5g = radio_iface(cursor, "radio1")
		if args.enabled_wifi ~= nil then
			cursor:set("wireless", "radio0", "disabled", args.enabled_wifi and "0" or "1")
		end
		if args.enabled_wifi_5g ~= nil then
			cursor:set("wireless", "radio1", "disabled", args.enabled_wifi_5g and "0" or "1")
		end
		if if2g then
			if type(args.ssid) == "string" then cursor:set("wireless", if2g, "ssid", args.ssid) end
			if type(args.password_wifi) == "string" then cursor:set("wireless", if2g, "key", args.password_wifi) end
		end
		if if5g then
			if type(args.ssid_5g) == "string" then cursor:set("wireless", if5g, "ssid", args.ssid_5g) end
			if type(args.password_wifi_5g) == "string" then cursor:set("wireless", if5g, "key", args.password_wifi_5g) end
		end
		-- mac80211 expects the real htmode value ("HE160"/"HE80"), not a
		-- bare "160"/"80".
		if args.htmode_160 ~= nil then
			cursor:set("wireless", "radio1", "htmode", args.htmode_160 and "HE160" or "HE80")
		end
		cursor:set("wireless", "radio0", "country", country)
		cursor:set("wireless", "radio1", "country", country)
		cursor:commit("wireless")

		cursor:set("gl-oui-rpc", "main", "main")
		cursor:set("gl-oui-rpc", "main", "inited_internet", "1")
		cursor:commit("gl-oui-rpc")

		os.execute("/etc/init.d/system reload >/dev/null 2>&1")
		os.execute("wifi reload >/dev/null 2>&1 &")

		return {}
	end,
}
