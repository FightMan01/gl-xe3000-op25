-- "clients" RPC object: connected-device list (LAN + WiFi), combining DHCP
-- lease data with WiFi association info. Method set matches the stock
-- GL.iNet UI: clean_traffic, get_list, get_status, remove_offline,
-- set_cache_offline, set_info. MAC-based access control lives in
-- firewall.add_acl_rule instead, not here.

local uci = require "uci"
local cjson = require "cjson"

-- /etc survives reboots (it's on the overlay, unlike /tmp's tmpfs) - this
-- previously lived at /tmp/gl-oui-client-traffic.json, which meant both
-- accumulated traffic totals AND the offline-client history below were
-- silently wiped on every reboot. Now doubles as that history: each
-- entry also carries last-known ip/name/seen-time so a client that has
-- gone offline (dropped its DHCP lease / disassociated) still shows up
-- in the client list instead of just disappearing.
local CLIENT_STATE = "/etc/gl-oui-client-state.json"
local OFFLINE_RETENTION_SECONDS = 30 * 24 * 60 * 60

-- lua-cjson can't tell an empty array from an empty object - a bare {}
-- always encodes as "{}", never "[]", which breaks frontend .map() calls
-- on an empty client list. cjson.empty_array is a sentinel the patched
-- library (openwrt-patches/lua-cjson/) always encodes as "[]".
local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local function dhcp_leases()
	local leases = {}
	local f = io.open("/tmp/dhcp.leases", "r")
	if f then
		for line in f:lines() do
			local ts, mac, ip, name = line:match("^(%d+) (%S+) (%S+) (%S+)")
			if mac then
				leases[mac:lower()] = { ipaddr = ip, hostname = (name ~= "*" and name or nil), expires = tonumber(ts) }
			end
		end
		f:close()
	end
	return leases
end

local function wifi_client_macs()
	local by_mac = {}
	local ubus = require "ubus"
	local conn = ubus.connect()
	if conn then
		local status = conn:call("network.wireless", "status", {}) or {}
		for _, radio in pairs(status) do
			local band = radio.config and radio.config.band == "5g" and "5G" or "2G"
			for _, iface in ipairs(radio.interfaces or {}) do
				if iface.ifname and iface.config and iface.config.mode == "ap" then
					-- hostapd is authoritative for the AP a station is
					-- currently associated with. iwinfo can retain a
					-- just-pruned station briefly while DFS completes or a
					-- same-SSID client roams between bands, which caused a
					-- real 2.4 GHz client to be overwritten as "5G".
					local ap = conn:call("hostapd." .. iface.ifname, "get_clients", {}) or {}
					for mac, info in pairs(ap.clients or {}) do
						if info.assoc and info.authorized then
							by_mac[mac:lower()] = {
								network = iface.config.network,
								ssid = iface.config.ssid,
								signal = info.signal,
								band = band,
								-- hostapd counts from the AP's point of
								-- view: AP TX is client download and AP RX
								-- is client upload.
								rx_bytes = info.bytes and tonumber(info.bytes.tx) or 0,
								tx_bytes = info.bytes and tonumber(info.bytes.rx) or 0,
							}
						end
					end
				end
			end
		end
		conn:close()
	end
	return by_mac
end

local function load_client_state()
	local f = io.open(CLIENT_STATE, "r")
	if not f then return {} end
	local raw = f:read("*a")
	f:close()
	local ok, state = pcall(cjson.decode, raw)
	return ok and type(state) == "table" and state or {}
end

local function save_client_state(state)
	local f = io.open(CLIENT_STATE, "w")
	if not f then return end
	f:write(cjson.encode(state))
	f:close()
end

-- Return GL's client rx/tx (bytes per second) and cumulative totals, and
-- update each seen client's last-known ip/name/seen-time in `state` (the
-- caller commits it to disk once, after also folding in offline entries -
-- see build_client_list). When hostapd counters reset after roaming/
-- reassociation, the new counter is added to the accumulated total
-- instead of producing a negative spike.
local function update_traffic(state, wifi_macs, now)
	local values = {}
	for mac, wifi in pairs(wifi_macs) do
		local old = state[mac] or {}
		local raw_rx = tonumber(wifi.rx_bytes) or 0
		local raw_tx = tonumber(wifi.tx_bytes) or 0
		local delta_rx = old.raw_rx and
			(raw_rx >= old.raw_rx and raw_rx - old.raw_rx or raw_rx) or 0
		local delta_tx = old.raw_tx and
			(raw_tx >= old.raw_tx and raw_tx - old.raw_tx or raw_tx) or 0
		local elapsed = math.max(1, now - (tonumber(old.time) or now))
		local total_rx = (tonumber(old.total_rx) or raw_rx) + delta_rx
		local total_tx = (tonumber(old.total_tx) or raw_tx) + delta_tx
		state[mac] = old
		old.raw_rx, old.raw_tx = raw_rx, raw_tx
		old.total_rx, old.total_tx = total_rx, total_tx
		old.time = now
		values[mac] = {
			rx = math.floor(delta_rx / elapsed),
			tx = math.floor(delta_tx / elapsed),
			total_rx = tostring(math.floor(total_rx)),
			total_tx = tostring(math.floor(total_tx)),
		}
	end
	return values
end

-- total_rx/total_tx are cumulative byte counters returned as strings to
-- avoid JS double-precision loss above 2^53. WiFi rx/tx come from hostapd;
-- wired per-client accounting has no backend yet so it stays at zero
-- rather than being faked.
--
-- "Offline cache": every client this ever sees gets a row in the
-- persistent state file (last-known ip/name/iface + cumulative traffic,
-- keyed by mac). Currently-live clients (dhcp lease or wifi association)
-- are reported online=true and their row is refreshed; anything else in
-- the state file is reported online=false using its last-known values,
-- instead of just disappearing the moment its lease expires. That's what
-- get_status's `auto_remove_offline` (UCI: gl-oui-rpc.clients.cache_offline)
-- governs: whether stale offline rows get pruned automatically, versus
-- only via an explicit remove_offline call.
local function build_client_list()
	local leases = dhcp_leases()
	local wifi_macs = wifi_client_macs()
	local seen = {}
	local out = {}
	local now = os.time()
	local state = load_client_state()
	local traffic = update_traffic(state, wifi_macs, now)
	local access_cursor = uci.cursor()
	local access_mode = access_cursor:get("gl-oui-rpc", "black_white_list", "mode") or "black"
	local access_list = access_cursor:get(
		"gl-oui-rpc",
		"black_white_list",
		access_mode == "white" and "white_mac" or "black_mac"
	) or {}
	if type(access_list) == "string" then access_list = { access_list } end
	local access_macs = {}
	for _, mac in ipairs(access_list) do access_macs[mac:lower()] = true end
	local function is_blocked(mac)
		return (access_mode == "white" and not access_macs[mac])
			or (access_mode == "black" and access_macs[mac] == true)
	end

	local function client_info(mac)
		local cursor = uci.cursor()
		local name = nil
		cursor:foreach("gl-oui-rpc", "client_info", function(s)
			if s.macaddr and s.macaddr:lower() == mac then name = s.name end
		end)
		return name
	end

	for mac, lease in pairs(leases) do
		local wifi = wifi_macs[mac]
		local custom_name = client_info(mac)
		local display_name = custom_name or lease.hostname or ""
		local counters = traffic[mac] or {
			rx = 0, tx = 0, total_rx = "0", total_tx = "0",
		}
		table.insert(out, {
			mac = mac,
			ip = lease.ipaddr,
			name = display_name,
			alias = custom_name or "",
			iface = wifi and wifi.band or "cable",
			type = wifi and 1 or 2,
			online = true,
			blocked = is_blocked(mac),
			remote = false,
			rx = counters.rx,
			tx = counters.tx,
			total_rx = counters.total_rx,
			total_tx = counters.total_tx,
			total_rx_init = "0",
			total_tx_init = "0",
			limit_rx = 0,
			limit_tx = 0,
			online_time = now,
			last_update_rate = now,
			ipv6 = as_array({}),
		})
		seen[mac] = true
		local row = state[mac] or {}
		state[mac] = row
		row.ip, row.name, row.iface = lease.ipaddr, display_name, (wifi and wifi.band or "cable")
		row.first_seen = row.first_seen or now
		row.last_seen = now
	end

	for mac, wifi in pairs(wifi_macs) do
		if not seen[mac] then
			local custom_name = client_info(mac)
			local counters = traffic[mac] or {
				rx = 0, tx = 0, total_rx = "0", total_tx = "0",
			}
			table.insert(out, {
				mac = mac,
				ip = "",
				name = custom_name or "",
				alias = custom_name or "",
				iface = wifi.band,
				type = 1,
				online = true,
				blocked = is_blocked(mac),
				remote = false,
				rx = counters.rx,
				tx = counters.tx,
				total_rx = counters.total_rx,
				total_tx = counters.total_tx,
				total_rx_init = "0",
				total_tx_init = "0",
				limit_rx = 0,
				limit_tx = 0,
				online_time = now,
				last_update_rate = now,
				ipv6 = as_array({}),
			})
			seen[mac] = true
			local row = state[mac] or {}
			state[mac] = row
			row.ip, row.name, row.iface = "", custom_name or "", wifi.band
			row.first_seen = row.first_seen or now
			row.last_seen = now
		end
	end

	local auto_remove_offline = access_cursor:get("gl-oui-rpc", "clients", "cache_offline") == "1"
	for mac, row in pairs(state) do
		if not seen[mac] then
			if auto_remove_offline and row.last_seen
				and now - row.last_seen > OFFLINE_RETENTION_SECONDS then
				state[mac] = nil
			else
				local custom_name = client_info(mac)
				table.insert(out, {
					mac = mac,
					ip = row.ip or "",
					name = custom_name or row.name or "",
					alias = custom_name or "",
					iface = row.iface or "cable",
					type = row.iface == "cable" and 2 or 1,
					online = false,
					blocked = is_blocked(mac),
					remote = false,
					rx = 0,
					tx = 0,
					total_rx = tostring(math.floor(tonumber(row.total_rx) or 0)),
					total_tx = tostring(math.floor(tonumber(row.total_tx) or 0)),
					total_rx_init = "0",
					total_tx_init = "0",
					limit_rx = 0,
					limit_tx = 0,
					online_time = row.last_seen or 0,
					last_update_rate = row.last_seen or 0,
					ipv6 = as_array({}),
				})
			end
		end
	end

	save_client_state(state)
	return out
end

return {
	get_list = function(args)
		local out = build_client_list()
		return { clients = as_array(out) }
	end,

	get_status = function(args)
		local out = build_client_list()
		local cable_total, wireless_total = 0, 0
		for _, c in ipairs(out) do
			if c.online then
				if c.iface == "cable" then cable_total = cable_total + 1 else wireless_total = wireless_total + 1 end
			end
		end
		local cursor = uci.cursor()
		return {
			wireless_total = wireless_total,
			cable_total = cable_total,
			auto_remove_offline = cursor:get("gl-oui-rpc", "clients", "cache_offline") == "1",
		}
	end,

	-- Resets accumulated traffic counters only - offline-client identity
	-- (ip/name/last-seen) stays, since that's a separate concern from
	-- traffic accounting and shares this file only as an implementation
	-- detail.
	clean_traffic = function(args)
		local state = load_client_state()
		for _, row in pairs(state) do
			row.raw_rx, row.raw_tx, row.total_rx, row.total_tx = nil, nil, nil, nil
		end
		save_client_state(state)
		return {}
	end,

	-- "Offline cache" - GL keeps previously-seen-but-currently-offline
	-- clients visible (with a custom name/note) rather than dropping them
	-- the moment their DHCP lease expires. `auto_remove_offline` (stored
	-- as cache_offline, see build_client_list) governs automatic pruning;
	-- this just flips that toggle.
	set_cache_offline = function(args)
		local cursor = uci.cursor()
		cursor:set("gl-oui-rpc", "clients", "clients")
		cursor:set("gl-oui-rpc", "clients", "cache_offline", args.auto_remove_offline and "1" or "0")
		cursor:commit("gl-oui-rpc")
		return {}
	end,

	remove_offline = function(args)
		if not args.macaddr then
			return { code = 1, message = "missing macaddr" }
		end
		local mac = args.macaddr:lower()
		local state = load_client_state()
		state[mac] = nil
		save_client_state(state)
		-- Still clear any legacy offline_client UCI sections from before
		-- this moved to the state file, so an old record can't reappear.
		local cursor = uci.cursor()
		cursor:foreach("gl-oui-rpc", "offline_client", function(s)
			if s.macaddr and s.macaddr:lower() == mac then
				cursor:delete("gl-oui-rpc", s[".name"])
			end
		end)
		cursor:commit("gl-oui-rpc")
		return {}
	end,

	-- Sets a custom display name/note for a client, keyed by MAC.
	set_info = function(args)
		if type(args.macaddr) ~= "string" then
			return { code = 1, message = "missing macaddr" }
		end
		local cursor = uci.cursor()
		local mac = args.macaddr:lower()
		local id = nil
		cursor:foreach("gl-oui-rpc", "client_info", function(s)
			if s.macaddr and s.macaddr:lower() == mac then id = s[".name"] end
		end)
		if not id then
			id = cursor:add("gl-oui-rpc", "client_info")
			cursor:set("gl-oui-rpc", id, "macaddr", args.macaddr)
		end
		if args.name then cursor:set("gl-oui-rpc", id, "name", args.name) end
		cursor:commit("gl-oui-rpc")
		return {}
	end,
}
