-- "wifi" RPC object: WiFi radio/AP management.
--
-- Built against mainline mac80211/mt76 (kmod-mt7915e) + hostapd/wpad-full
-- + standard OpenWrt UCI wireless config, not GL's proprietary MediaTek
-- vendor SDK driver.
--
-- Two radios: a 2.4GHz and a 5GHz MT7915 phy, using stock OpenWrt's
-- generic 'radio0'/'radio1' section-naming convention rather than GL's
-- own 'mt798111'/'mt798112' names.
--
-- Coverage: per-radio primary AP (SSID/password/encryption/channel/
-- txpower/hidden/enable), guest network (isolated bridge + firewall
-- zone, per-radio SSID), IoT network (separate-VLAN pattern), MAC
-- filtering (allow/deny list), WPS toggle, client list, scan.
-- Repeater/WDS-client-mode config lives in the separate "repeater" RPC
-- object (gl-repeater package), not here.
--
-- Not yet covered: band steering, per-client bandwidth limits, mesh
-- (802.11s) config exposure - the underlying mainline scripting layer
-- supports these but no RPC surface is wired up yet.

local uci = require "uci"
local iwinfo = require "iwinfo"

local RADIOS = { "radio0", "radio1" }
local GUEST_NETWORK = "guest"
local GUEST_SUBNET = "192.168.9.1/24"
local IOT_NETWORK = "iot"
local IOT_SUBNET = "192.168.10.1/24"

-- phy0 (2.4GHz, radio0) supports channels 1-14, none DFS. phy1 (5GHz,
-- radio1) supports the full 36-165 range; 52-144 require DFS (radar
-- detection) per the standard worldwide regulatory convention.
local CHANNELS_2G = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }
local CHANNELS_5G = {
	{ ch = 36, dfs = false }, { ch = 40, dfs = false }, { ch = 44, dfs = false }, { ch = 48, dfs = false },
	{ ch = 52, dfs = true }, { ch = 56, dfs = true }, { ch = 60, dfs = true }, { ch = 64, dfs = true },
	{ ch = 100, dfs = true }, { ch = 104, dfs = true }, { ch = 108, dfs = true }, { ch = 112, dfs = true },
	{ ch = 116, dfs = true }, { ch = 120, dfs = true }, { ch = 124, dfs = true }, { ch = 128, dfs = true },
	{ ch = 132, dfs = true }, { ch = 136, dfs = true }, { ch = 140, dfs = true }, { ch = 144, dfs = true },
	{ ch = 149, dfs = false }, { ch = 153, dfs = false }, { ch = 157, dfs = false }, { ch = 161, dfs = false },
	{ ch = 165, dfs = false },
}

--- iface lookup ---

local function radio_iface(cursor, radio, network)
	network = network or "lan"
	local ifname = nil
	cursor:foreach("wireless", "wifi-iface", function(s)
		if s.device == radio and s.mode == "ap" and s.network == network then
			ifname = s[".name"]
		end
	end)
	return ifname
end

local function real_ifname(iface_section)
	-- The UCI section name and the kernel netdev name usually match for
	-- mac80211 (netifd creates e.g. "radio0" -> phy0-ap0 style names in
	-- some layouts) - use ubus network.wireless status as the source of
	-- truth rather than assuming, since this varies by driver/board.
	local ubus = require "ubus"
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

--- primary AP ---

local function get_radio_config(cursor, radio)
	local iface = radio_iface(cursor, radio, "lan")
	local dev = {
		radio = radio,
		disabled = cursor:get("wireless", radio, "disabled") == "1",
		band = cursor:get("wireless", radio, "band"),
		-- Left unset, `iw reg get` reports "country 00: DFS-UNSET" - the
		-- kernel has no concrete DFS ruleset to run a Channel Availability
		-- Check against, so a DFS-channel 5GHz AP can hang in the "DFS"
		-- hostapd state indefinitely instead of reaching "ENABLED". Empty
		-- string (not nil) when unset, matching this port's other
		-- optional-string fields' convention.
		country = cursor:get("wireless", radio, "country") or "",
		channel = cursor:get("wireless", radio, "channel"),
		htmode = cursor:get("wireless", radio, "htmode"),
		-- Extra parens: cursor:get() can return a second value, which Lua
		-- would otherwise splice in as tonumber()'s 2nd (base) argument.
		txpower = tonumber((cursor:get("wireless", radio, "txpower"))),
		-- advanced radio params, exposed but optional (nil = driver
		-- default, not forced) - beacon/DTIM interval, RTS/fragmentation
		-- thresholds are standard hostapd knobs common to this class of
		-- GUI's "advanced WiFi" panel.
		beacon_int = tonumber((cursor:get("wireless", radio, "beacon_int"))),
		dtim_period = iface and tonumber((cursor:get("wireless", iface, "dtim_period"))),
		rts_threshold = tonumber((cursor:get("wireless", radio, "rts"))),
		frag_threshold = tonumber((cursor:get("wireless", radio, "frag"))),
	}
	if iface then
		dev.ssid = cursor:get("wireless", iface, "ssid")
		dev.encryption = cursor:get("wireless", iface, "encryption")
		dev.hidden = cursor:get("wireless", iface, "hidden") == "1"
		dev.iface_disabled = cursor:get("wireless", iface, "disabled") == "1"
		dev.wps = cursor:get("wireless", iface, "wps_pushbutton") == "1"
		dev.ifname = iface
		dev.macfilter = cursor:get("wireless", iface, "macfilter") or "disable"
		local maclist = {}
		for _, mac in ipairs(cursor:get("wireless", iface, "maclist") or {}) do
			table.insert(maclist, mac)
		end
		dev.maclist = maclist
	end
	return dev
end

local function set_radio_config(cursor, radio, args)
	if args.disabled ~= nil then
		cursor:set("wireless", radio, "disabled", args.disabled and "1" or "0")
	end
	if args.channel then
		cursor:set("wireless", radio, "channel", tostring(args.channel))
	end
	if args.txpower then
		-- GL uses the symbolic value "Max" for the driver's automatic
		-- regulatory maximum.  mac80211/netifd expects this option to be
		-- absent; writing the literal string makes netifd expose txpower
		-- as NaN, which in turn corrupts LuCI's JSON-RPC radio reply.
		if tostring(args.txpower):lower() == "max" then
			cursor:delete("wireless", radio, "txpower")
		else
			cursor:set("wireless", radio, "txpower", tostring(args.txpower))
		end
	end
	if args.htmode then
		-- get_config advertises bare widths ("20"/"40"/"80"/"160"/"auto"),
		-- but mac80211's UCI htmode option needs the mode-prefixed form
		-- ("HE20".."HE160") - both radios are HE (802.11ax, mt76/mt7915),
		-- not VHT/HT. "auto" means "let the driver pick", achieved by
		-- leaving htmode unset rather than writing the literal string.
		local width = tostring(args.htmode)
		if width == "auto" then
			cursor:delete("wireless", radio, "htmode")
		elseif width:match("^%d+$") then
			cursor:set("wireless", radio, "htmode", "HE" .. width)
		else
			cursor:set("wireless", radio, "htmode", width)
		end
	end
	if type(args.country) == "string" and args.country ~= "" then
		-- Regulatory domain is a single physical-hardware-wide concept,
		-- not per-band - mirrored to both radios so 2.4G/5G can't end up
		-- in an inconsistent split state.
		for _, r in ipairs(RADIOS) do
			cursor:set("wireless", r, "country", args.country:upper())
		end
	end
	if args.beacon_int then
		cursor:set("wireless", radio, "beacon_int", tostring(args.beacon_int))
	end
	if args.rts_threshold then
		cursor:set("wireless", radio, "rts", tostring(args.rts_threshold))
	end
	if args.frag_threshold then
		cursor:set("wireless", radio, "frag", tostring(args.frag_threshold))
	end

	local iface = radio_iface(cursor, radio, "lan")
	if iface and args.dtim_period then
		cursor:set("wireless", iface, "dtim_period", tostring(args.dtim_period))
	end
	if iface then
		if args.enabled ~= nil then
			cursor:set("wireless", iface, "disabled", args.enabled and "0" or "1")
		end
		if args.ssid then
			cursor:set("wireless", iface, "ssid", args.ssid)
		end
		-- `key` matches get_config's own ifaces[].key field name
		-- (official docs shape); `password` kept as a fallback alias
		-- since no live-captured set_config example with a password
		-- field exists to confirm which name the real frontend sends.
		local new_key = args.key or args.password
		if new_key then
			cursor:set("wireless", iface, "key", new_key)
			if not cursor:get("wireless", iface, "encryption")
				or cursor:get("wireless", iface, "encryption") == "none" then
				-- Sensible modern default rather than carrying forward an
				-- open network.
				cursor:set("wireless", iface, "encryption", "sae-mixed")
			end
		end
		if args.encryption then
			cursor:set("wireless", iface, "encryption", args.encryption)
		end
		if args.hidden ~= nil then
			cursor:set("wireless", iface, "hidden", args.hidden and "1" or "0")
		end
		if args.iface_disabled ~= nil then
			cursor:set("wireless", iface, "disabled", args.iface_disabled and "1" or "0")
		end
		if args.wps ~= nil then
			cursor:set("wireless", iface, "wps_pushbutton", args.wps and "1" or "0")
		end
	end
end

--- MAC filtering ---

local function set_macfilter(cursor, radio, args)
	local iface = radio_iface(cursor, radio, "lan")
	if not iface then
		return false
	end
	if args.mode then
		-- 'disable' | 'allow' (whitelist) | 'deny' (blacklist), matching
		-- hostapd's own macfilter/macfilter=1|2 convention via UCI's
		-- macfilter='allow'/'deny'.
		cursor:set("wireless", iface, "macfilter", args.mode)
	end
	if type(args.maclist) == "table" then
		cursor:set("wireless", iface, "maclist", args.maclist)
	end
	return true
end

--- guest / iot isolated networks (shared helper - same pattern, different
--- subnet/zone name) ---

local function ensure_isolated_network(cursor, name, subnet)
	if not cursor:get("network", name) then
		cursor:set("network", name, "interface")
		cursor:set("network", name, "proto", "static")
		cursor:set("network", name, "type", "bridge")
		local ip, mask = subnet:match("^([%d%.]+)/(%d+)")
		cursor:set("network", name, "ipaddr", ip)
		cursor:set("network", name, "netmask", mask == "24" and "255.255.255.0" or mask)
		cursor:commit("network")
	end
	if not cursor:get("dhcp", name) then
		cursor:set("dhcp", name, "dhcp")
		cursor:set("dhcp", name, "interface", name)
		cursor:set("dhcp", name, "start", "100")
		cursor:set("dhcp", name, "limit", "150")
		cursor:set("dhcp", name, "leasetime", "12h")
		cursor:commit("dhcp")
	end
	local zone_exists = false
	cursor:foreach("firewall", "zone", function(s)
		if s.name == name then zone_exists = true end
	end)
	if not zone_exists then
		local zname = cursor:add("firewall", "zone")
		cursor:set("firewall", zname, "name", name)
		cursor:set("firewall", zname, "input", "REJECT")
		cursor:set("firewall", zname, "output", "ACCEPT")
		cursor:set("firewall", zname, "forward", "REJECT")
		cursor:set("firewall", zname, "network", { name })
		local fname = cursor:add("firewall", "forwarding")
		cursor:set("firewall", fname, "src", name)
		cursor:set("firewall", fname, "dest", "wan")
		cursor:commit("firewall")
	end
end

local function get_isolated_iface_config(cursor, radio, network)
	local iface = radio_iface(cursor, radio, network)
	if not iface then
		return { enabled = false }
	end
	return {
		enabled = cursor:get("wireless", iface, "disabled") ~= "1",
		ssid = cursor:get("wireless", iface, "ssid"),
		encryption = cursor:get("wireless", iface, "encryption"),
		ifname = iface,
	}
end

local function set_isolated_iface_config(cursor, radio, network, subnet, args)
	if args.enabled == false then
		local iface = radio_iface(cursor, radio, network)
		if iface then
			cursor:set("wireless", iface, "disabled", "1")
		end
		return
	end

	ensure_isolated_network(cursor, network, subnet)

	local iface = radio_iface(cursor, radio, network)
	if not iface then
		iface = cursor:add("wireless", "wifi-iface")
		cursor:set("wireless", iface, "device", radio)
		cursor:set("wireless", iface, "mode", "ap")
		cursor:set("wireless", iface, "network", network)
		cursor:set("wireless", iface, "isolate", "1")
	end
	cursor:set("wireless", iface, "disabled", "0")
	if args.ssid then
		cursor:set("wireless", iface, "ssid", args.ssid)
	end
	if args.password then
		cursor:set("wireless", iface, "key", args.password)
		cursor:set("wireless", iface, "encryption", args.encryption or "sae-mixed")
	elseif args.encryption then
		cursor:set("wireless", iface, "encryption", args.encryption)
	end
end

return {
	-- Response key is `res` (not `radios`), one entry per radio shaped:
	--   {"band":"5G","ifaces":[{"enabled","ssid","encryption","name",
	--     "guest","hidden","key"}],"channels":[{"dfs","channel"}],
	--     "device","hwmode","txpower","channel","hwmodes","htmode",
	--     "htmodes","encryptions","ready"}
	-- `ifaces` is an array - the primary AP and any guest AP on the same
	-- radio are just two entries in the same list (guest:false/true
	-- distinguishes them), not two calls to two different RPC objects.
	-- get_guest_config/set_guest_config below are kept as harmless extra
	-- methods, unused by the real frontend.
	get_config = function(args)
		local cursor = uci.cursor()
		local res = {}
		for _, radio in ipairs(RADIOS) do
			local band = cursor:get("wireless", radio, "band")
			local is5g = band == "5g"
			local uci_htmode = cursor:get("wireless", radio, "htmode") or "auto"
			-- The GL UI speaks in bare channel widths while mac80211 UCI
			-- stores mode-prefixed values (HE20/HE40/HE80/HE160).
			local htmode = uci_htmode == "auto"
				and "auto"
				or (uci_htmode:match("(%d+)$") or uci_htmode)
			local channel = tonumber((cursor:get("wireless", radio, "channel"))) or 0
			local txpower = cursor:get("wireless", radio, "txpower") or "Max"
			local hwmode = is5g and "11ac/ax" or "11n/ax"

			local ifaces = {}
			cursor:foreach("wireless", "wifi-iface", function(s)
				if s.device == radio and s.mode == "ap" then
					table.insert(ifaces, {
						enabled = s.disabled ~= "1",
						ssid = s.ssid,
						encryption = s.encryption or "none",
						name = s['.name'],
						guest = s.network == "guest",
						iot = s.network == IOT_NETWORK,
						-- v4.10's WifiCard deliberately hides entries
						-- without this flag. Omitting it produced an empty
						-- "Main Network" card despite valid radio data.
						init = true,
						random_bssid = s.random_bssid == "1",
						hidden = s.hidden == "1",
						key = s.key,
					})
				end
			end)

			local channels = {}
			if is5g then
				for _, c in ipairs(CHANNELS_5G) do
					table.insert(channels, { channel = c.ch, dfs = c.dfs, psc = false })
				end
			else
				for _, c in ipairs(CHANNELS_2G) do
					table.insert(channels, { channel = c, dfs = false, psc = false })
				end
			end

			table.insert(res, {
				band = is5g and "5G" or "2G",
				ifaces = ifaces,
				channels = channels,
				device = radio,
				hwmode = hwmode,
				txpower = txpower,
				channel = channel,
				hwmodes = is5g and { "11ac/ax", "11n/ac/ax", "11a/n/ac/ax" } or { "11n/ax", "11g/n/ax", "11b/g/n/ax" },
				htmode = htmode,
				-- Current v4.10 UI expects a map from every advertised
				-- hardware mode to its maximum width, plus an auto flag.
				-- The older flat ["20","40",...] API example makes its
				-- width-list computation evaluate to NaN.
				htmodes = is5g
					and {
						["11ac/ax"] = 160,
						["11n/ac/ax"] = 160,
						["11a/n/ac/ax"] = 160,
						auto = true,
					}
					or {
						["11n/ax"] = 40,
						["11g/n/ax"] = 40,
						["11b/g/n/ax"] = 40,
						auto = true,
					},
				encryptions = { "none", "psk2", "psk-mixed", "sae", "sae-mixed" },
				ready = true,
			})
		end
		return { res = res, dfs_support = true, bandmode = {} }
	end,

	-- Shape: {"device":"radio0","channel":1} for radio-level edits from the
	-- Advanced panel, or {"iface_name":"guest2g","enabled":true} for the
	-- wifi-card quick-toggle switch - that switch only ever emits
	-- iface_name/enabled/init, never device, so device is derived from the
	-- interface's own UCI section when the caller didn't supply one.
	set_config = function(args)
		local cursor = uci.cursor()
		local iface = type(args.iface_name) == "string"
			and cursor:get("wireless", args.iface_name)
			and args.iface_name
			or nil

		local device = args.device
		if type(device) ~= "string" and iface then
			device = cursor:get("wireless", iface, "device")
		end
		if type(device) ~= "string" then
			return { code = 1, message = "missing device" }
		end
		local found = false
		for _, r in ipairs(RADIOS) do
			if r == device then found = true end
		end
		if not found then
			return { code = 1, message = "unknown device" }
		end
		local network = iface and cursor:get("wireless", iface, "network") or "lan"

		if network == GUEST_NETWORK or network == IOT_NETWORK then
			if args.enabled == true then
				ensure_isolated_network(
					cursor,
					network,
					network == GUEST_NETWORK and GUEST_SUBNET or IOT_SUBNET
				)
			end
			if args.enabled ~= nil then
				cursor:set("wireless", iface, "disabled", args.enabled and "0" or "1")
			end
			if args.ssid then cursor:set("wireless", iface, "ssid", args.ssid) end
			if args.encryption then
				cursor:set("wireless", iface, "encryption", args.encryption)
			end
			local key = args.key or args.password
			if key then cursor:set("wireless", iface, "key", key) end
			if args.hidden ~= nil then
				cursor:set("wireless", iface, "hidden", args.hidden and "1" or "0")
			end
			if args.random_bssid ~= nil then
				cursor:set(
					"wireless",
					iface,
					"random_bssid",
					args.random_bssid and "1" or "0"
				)
			end
		else
			set_radio_config(cursor, device, args)
		end
		cursor:commit("wireless")
		os.execute("wifi reload >/dev/null 2>&1")
		if network == GUEST_NETWORK or network == IOT_NETWORK then
			os.execute("/etc/init.d/network reload >/dev/null 2>&1")
			os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
			os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		end
		return {}
	end,

	-- Shape: {"device":"radio0","txpower":"Max"} - a dedicated method,
	-- separate from the general set_config, though both end up setting
	-- the same UCI option.
	set_txpower = function(args)
		if type(args.device) ~= "string" or args.txpower == nil then
			return { code = 1, message = "missing device/txpower" }
		end
		local cursor = uci.cursor()
		if tostring(args.txpower):lower() == "max" then
			cursor:delete("wireless", args.device, "txpower")
		else
			cursor:set("wireless", args.device, "txpower", tostring(args.txpower))
		end
		cursor:commit("wireless")
		os.execute("wifi reload >/dev/null 2>&1")
		return {}
	end,

	set_macfilter = function(args)
		if type(args.radio) ~= "string" then
			return { code = 1, message = "missing radio" }
		end
		local cursor = uci.cursor()
		if not set_macfilter(cursor, args.radio, args) then
			return { code = 1, message = "no AP interface on that radio" }
		end
		cursor:commit("wireless")
		os.execute("wifi reload >/dev/null 2>&1")
		return {}
	end,

	get_guest_config = function(args)
		local cursor = uci.cursor()
		local radios = {}
		for _, radio in ipairs(RADIOS) do
			radios[radio] = get_isolated_iface_config(cursor, radio, GUEST_NETWORK)
		end
		return { radios = radios }
	end,

	set_guest_config = function(args)
		if type(args.radio) ~= "string" then
			return { code = 1, message = "missing radio" }
		end
		local cursor = uci.cursor()
		set_isolated_iface_config(cursor, args.radio, GUEST_NETWORK, GUEST_SUBNET, args)
		cursor:commit("wireless")
		os.execute("wifi reload >/dev/null 2>&1")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	get_iot_config = function(args)
		local cursor = uci.cursor()
		local radios = {}
		for _, radio in ipairs(RADIOS) do
			radios[radio] = get_isolated_iface_config(cursor, radio, IOT_NETWORK)
		end
		return { radios = radios }
	end,

	set_iot_config = function(args)
		if type(args.radio) ~= "string" then
			return { code = 1, message = "missing radio" }
		end
		local cursor = uci.cursor()
		set_isolated_iface_config(cursor, args.radio, IOT_NETWORK, IOT_SUBNET, args)
		cursor:commit("wireless")
		os.execute("wifi reload >/dev/null 2>&1")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
		return {}
	end,

	-- Shape: {"res":[{"name":"radio0","state":"ready","channel":49},
	-- {"name":"radio1","state":"starting"}]} - channel is nil rather than
	-- 0 for a not-yet-ready radio. bitrate/client_count are extra fields
	-- the overview-page status widgets rely on.
	get_status = function(args)
		local res = {}
		local cursor = uci.cursor()
		local wireless_status = {}
		local ubus = require "ubus"
		local conn = ubus.connect()
		if conn then
			wireless_status = conn:call("network.wireless", "status", {}) or {}
			conn:close()
		end
		for _, radio in ipairs(RADIOS) do
			local iface = radio_iface(cursor, radio, "lan")
			local disabled = cursor:get("wireless", radio, "disabled") == "1"
			local live = wireless_status[radio] or {}
			local state
			if disabled or live.disabled then
				state = "disabled"
			elseif live.retry_setup_failed then
				state = "conflict"
			elseif live.pending then
				state = cursor:get("wireless", radio, "band") == "5g"
					and "cac"
					or "starting"
			elseif live.up == false then
				state = "starting"
			else
				state = "ready"
			end
			local entry = {
				name = radio,
				state = state,
			}
			if not disabled then
				entry.channel = tonumber((cursor:get("wireless", radio, "channel")))
			end
			if iface then
				local dev = real_ifname(iface)
				local t = iwinfo.type(dev)
				-- netifd may already report the radio as up while hostapd is
				-- still performing DFS CAC.  The unchanged GL frontend only
				-- renders its warning when this method returns "cac", so use
				-- hostapd's authoritative per-BSS DFS state as well as
				-- netifd's earlier "pending" phase.
				if cursor:get("wireless", radio, "band") == "5g" then
					local hostapd_conn = ubus.connect()
					if hostapd_conn then
						local hostapd_status = hostapd_conn:call(
							"hostapd." .. dev, "get_status", {}) or {}
						hostapd_conn:close()
						local dfs = hostapd_status.dfs or {}
						if dfs.cac_active == true
							or tonumber(dfs.cac_seconds_left or 0) > 0
							or hostapd_status.status == "DFS" then
							state = "cac"
							entry.state = state
						end
					end
				end
				if t then
					local ok_channel, actual_channel = pcall(
						function() return iwinfo[t].channel(dev) end
					)
					if ok_channel and tonumber(actual_channel) then
						entry.channel = tonumber(actual_channel)
					end
					entry.bitrate = iwinfo[t].bitrate and iwinfo[t].bitrate(dev)
					local ok, clients = pcall(function() return iwinfo[t].assoclist(dev) end)
					local count = 0
					if ok and clients then
						for _ in pairs(clients) do count = count + 1 end
					end
					entry.client_count = count
				end
			end
			-- During the short gap between netifd declaring a 5 GHz radio
			-- "up" and hostapd publishing its DFS object, iwinfo reports
			-- channel 0.  Treat that as CAC/starting rather than "ready";
			-- otherwise the warning disappears exactly during this first
			-- (and most visible) part of the DFS wait.
			if cursor:get("wireless", radio, "band") == "5g"
				and not disabled
				and (not entry.channel or entry.channel == 0)
				and entry.state == "ready" then
				entry.state = "cac"
			end
			table.insert(res, entry)
		end
		return { res = res }
	end,

	get_clients = function(args)
		if type(args.radio) ~= "string" then
			return { code = 1, message = "missing radio" }
		end
		local cursor = uci.cursor()
		local iface = radio_iface(cursor, args.radio, "lan")
		if not iface then
			return { clients = {} }
		end
		local dev = real_ifname(iface)
		local t = iwinfo.type(dev)
		if not t then
			return { clients = {} }
		end
		local ok, assoclist = pcall(function() return iwinfo[t].assoclist(dev) end)
		local out = {}
		if ok and assoclist then
			for mac, info in pairs(assoclist) do
				table.insert(out, {
					macaddr = mac,
					signal = info.signal,
					noise = info.noise,
					rx_rate = info.rx and info.rx.rate,
					tx_rate = info.tx and info.tx.rate,
				})
			end
		end
		return { clients = out }
	end,

	scan = function(args)
		if type(args.radio) ~= "string" then
			return { code = 1, message = "missing radio" }
		end
		local cursor = uci.cursor()
		local iface = radio_iface(cursor, args.radio, "lan")
		if not iface then
			return { results = {} }
		end
		local dev = real_ifname(iface)
		local t = iwinfo.type(dev)
		if not t then
			return { results = {} }
		end
		local ok, results = pcall(function() return iwinfo[t].scanlist(dev) end)
		if not ok or not results then
			return { results = {} }
		end
		local out = {}
		for _, ap in ipairs(results) do
			table.insert(out, {
				ssid = ap.ssid,
				bssid = ap.bssid,
				channel = ap.channel,
				signal = ap.signal,
				encryption = ap.encryption and ap.encryption.description,
			})
		end
		return { results = out }
	end,

	-- Part of a separate "usage-environment" modal dialog (mode 1..N), not
	-- called on the main wireless page's initial load. "Environment"
	-- appears to be an interference-profile hint (e.g. dense-AP vs
	-- open-space tuning); reports a neutral/default profile.
	get_environment_config = function(args)
		return { mode = 1 }
	end,

	set_environment_config = function(args)
		return {}
	end,

	-- MLO (802.11be Multi-Link Operation) - this hardware's two MT7915
	-- radios are Wi-Fi 6/ax generation, not Wi-Fi 7/be, so MLO is
	-- genuinely unsupported rather than unimplemented.
	get_mlo_config = function(args)
		return { enabled = false, supported = false }
	end,

	set_mlo_config = function(args)
		return { code = 1, message = "MLO not supported on this hardware" }
	end,

}
