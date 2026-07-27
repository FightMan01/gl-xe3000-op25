-- "modem" RPC object: cellular modem management (Quectel RM520N-GL).
--
-- There is no separate "sim" or "sms" RPC object - every SIM/cell/
-- traffic/SMS method the UI calls lives on this "modem" object.
--
-- Method set: disconnect, get_cell_tower, get_debug_msg, get_esim_status,
-- get_modem_current_interface, get_operator_config, get_profile_list,
-- get_signals, get_sim_config, get_slot_config, get_slot_failover_config,
-- get_sms_list, get_traffic_config, remove_profile, remove_sms,
-- scan_cell_tower, scan_operator_list, send_at_command, send_sms,
-- set_apn_db_update, set_cell_tower, set_connect, set_operator_config,
-- set_profile, set_sim_config, set_sim_pin_code, set_slot_failover_config,
-- set_sms, set_traffic_config.
--
-- See get_serving_cell()'s own comment below for the 5G NSA field mapping
-- (the AT+QENG response splits across three separate lines in NSA mode,
-- unlike the single combined line LTE-only mode returns).
--
-- TODO: the main modem status card (IMEI, operator, network-generation
-- badge, connection state) isn't populated via any `/rpc` call at all -
-- menu.d/internet.json declares `"global_sockets": ["cellular.modems_info",
-- "cellular.modems_status", "cellular.sims_info", "cellular.sims_status",
-- "cellular.networks_info", "cellular.networks_status"]`, meaning that
-- data is pushed live over the WebSocket via ubus subscription forwarding
-- of a "cellular" ubus object with those six methods - not yet built.

local ubus = require "ubus"
local uci = require "uci"
local at = require "gloui.at"
local cjson = require "cjson"

-- cjson.empty_array: the vendored lua-cjson can't tell an empty plain Lua
-- table apart from an empty object (no integer keys either way), so it
-- always encodes `{}` for both - breaking frontend code that calls
-- .map()/.some()/.forEach() on a response field that's semantically an
-- array (results/profiles/messages/dns_servers here) but happens to be
-- empty right now (no scan results yet, no APN profiles configured, no
-- SMS received, no DNS servers assigned). Wrap any such table through this
-- before returning it (see clients.lua's identical as_array() for the
-- original pattern this was copied from).
local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local MODEM_MODEL = "RM520N-GL"

local function signal_quality(metric, value)
	if not value then return nil end
	local bands = {
		rsrp = { { -80, "Excellent" }, { -95, "Good" }, { -110, "Fair" } },
		rssi = { { -65, "Excellent" }, { -75, "Good" }, { -85, "Fair" } },
		rsrq = { { -10, "Excellent" }, { -15, "Good" }, { -20, "Fair" } },
		sinr = { { 12.5, "Excellent" }, { 10, "Good" }, { 7, "Fair" } },
	}
	local thresholds = bands[metric]
	if not thresholds then return nil end
	for _, t in ipairs(thresholds) do
		if value >= t[1] then return t[2] end
	end
	return "Poor"
end

-- Quectel AT+QENG bandwidth-code -> MHz (standard LTE/NR encoding).
local BANDWIDTH_MHZ = { [0] = 1.4, [1] = 3, [2] = 5, [3] = 10, [4] = 15, [5] = 20 }
local NR_BANDWIDTH_MHZ = {
	[0] = 5, [1] = 10, [2] = 15, [3] = 20, [4] = 25, [5] = 30,
	[6] = 40, [7] = 50, [8] = 60, [9] = 70, [10] = 80,
	[11] = 90, [12] = 100, [13] = 200, [14] = 400,
	[15] = 35, [16] = 45,
}

-- LTE-only mode: ONE combined "+QENG:" line -
--   "servingcell",<state>,"LTE",<duplex>,<mcc>,<mnc>,<cellid>,<pcid>,
--   <earfcn>,<band>,<ul_bw>,<dl_bw>,<tac>,<rsrp>,<rsrq>,<rssi>,<sinr>,<srxlev>
--   (fields[3]=="LTE") - rat@3, duplex@4, cellid@7, band@10, ul_bw@11,
--   dl_bw@12, rsrp@14, rsrq@15, rssi@16, sinr@17.
--
-- 5G NSA mode: the SAME command instead returns THREE SEPARATE "+QENG:"
-- lines, e.g.:
--   +QENG: "servingcell","NOCONN"                                  (state only, no RAT)
--   +QENG: "LTE","FDD",216,30,30603,256,1500,3,5,5,4BB,-82,-9,-52,19,15,-190,-
--   +QENG: "NR5G-NSA",216,30,954,-91,14,-10,638784,78,12,1
-- The LTE line here has no "servingcell"/state prefix of its own, so its
-- field indices are shifted down by 2 versus the LTE-only case: rat@1,
-- duplex@2, cellid@5, band@8, ul_bw@9, dl_bw@10, rsrp@12, rsrq@13,
-- rssi@14, sinr@15. The NR5G-NSA line's fields are Quectel's documented
-- order: mcc@2, mnc@3, pci@4, rsrp@5, sinr@6, rsrq@7, arfcn@8, band@9,
-- bandwidth-code@10, scs@11 - bandwidth-code's exact MHz mapping for NR
-- isn't confirmed, so nr.bandwidth_code is reported raw.
local function get_serving_cell()
	local resp = at.command('AT+QENG="servingcell"', 3)
	local lines = at.all_matches(resp, "+QENG")
	if #lines == 0 then
		return nil
	end

	-- Single combined line (LTE-only mode): fields[3] is the RAT.
	if #lines == 1 and lines[1][3] then
		local fields = lines[1]
		local rat = fields[3]
		if rat == "LTE" then
			local duplex, cellid, band, ul_bw, dl_bw, rsrp, rsrq, rssi, sinr =
				fields[4], fields[7], fields[10], fields[11], fields[12],
				fields[14], fields[15], fields[16], fields[17]
			rsrp, rsrq, rssi, sinr = tonumber(rsrp), tonumber(rsrq), tonumber(rssi), tonumber(sinr)
			return {
				mode = "LTE " .. (duplex or ""),
				network_type = "LTE",
				mcc = tonumber(fields[5]), mnc = tonumber(fields[6]),
				pci = tonumber(fields[8]), freq = tonumber(fields[9]),
				tac = fields[13],
				band = band,
				ul_bandwidth = BANDWIDTH_MHZ[tonumber(ul_bw)] and (BANDWIDTH_MHZ[tonumber(ul_bw)] .. "MHz"),
				dl_bandwidth = BANDWIDTH_MHZ[tonumber(dl_bw)] and (BANDWIDTH_MHZ[tonumber(dl_bw)] .. "MHz"),
				rsrp = rsrp, rsrp_quality = signal_quality("rsrp", rsrp),
				rssi = rssi, rssi_quality = signal_quality("rssi", rssi),
				rsrq = rsrq, rsrq_quality = signal_quality("rsrq", rsrq),
				sinr = sinr, sinr_quality = signal_quality("sinr", sinr),
				cell_id = cellid,
			}
		end
		return { mode = rat }
	end

	-- Multi-line (5G NSA/SA mode): find the LTE-anchor line and the
	-- NR5G-* secondary line among the returned lines (first line is just
	-- the state marker and is skipped).
	local result = nil
	for _, fields in ipairs(lines) do
		if fields[1] == "LTE" then
			local duplex, cellid, band, ul_bw, dl_bw, rsrp, rsrq, rssi, sinr =
				fields[2], fields[5], fields[8], fields[9], fields[10],
				fields[12], fields[13], fields[14], fields[15]
			rsrp, rsrq, rssi, sinr = tonumber(rsrp), tonumber(rsrq), tonumber(rssi), tonumber(sinr)
			result = result or {}
			result.mode = "5G NSA (LTE " .. (duplex or "") .. " anchor)"
			result.network_type = "LTE"
			result.mcc = tonumber(fields[3]); result.mnc = tonumber(fields[4])
			result.pci = tonumber(fields[6]); result.freq = tonumber(fields[7])
			result.tac = fields[11]
			result.band = band
			result.ul_bandwidth = BANDWIDTH_MHZ[tonumber(ul_bw)] and (BANDWIDTH_MHZ[tonumber(ul_bw)] .. "MHz")
			result.dl_bandwidth = BANDWIDTH_MHZ[tonumber(dl_bw)] and (BANDWIDTH_MHZ[tonumber(dl_bw)] .. "MHz")
			result.rsrp = rsrp; result.rsrp_quality = signal_quality("rsrp", rsrp)
			result.rssi = rssi; result.rssi_quality = signal_quality("rssi", rssi)
			result.rsrq = rsrq; result.rsrq_quality = signal_quality("rsrq", rsrq)
			result.sinr = sinr; result.sinr_quality = signal_quality("sinr", sinr)
			result.cell_id = cellid
		elseif fields[1] == "NR5G-NSA" or fields[1] == "NR5G-SA" then
			local pci, rsrp, sinr, rsrq, arfcn, band, bw_code =
				fields[4], fields[5], fields[6], fields[7], fields[8], fields[9], fields[10]
			rsrp, sinr, rsrq = tonumber(rsrp), tonumber(sinr), tonumber(rsrq)
			result = result or {}
			if fields[1] == "NR5G-SA" then result.mode = "5G SA" end
			result.nr = {
				network_type = "NR5G",
				mcc = tonumber(fields[2]), mnc = tonumber(fields[3]),
				pci = tonumber(pci), freq = tonumber(arfcn),
				scs = tonumber(fields[11]),
				band = band and ("n" .. band),
				cell_id = pci,
				bandwidth_code = bw_code,
				dl_bandwidth = NR_BANDWIDTH_MHZ[tonumber(bw_code)]
					and (NR_BANDWIDTH_MHZ[tonumber(bw_code)] .. "MHz"),
				rsrp = rsrp, rsrp_quality = signal_quality("rsrp", rsrp),
				rsrq = rsrq, rsrq_quality = signal_quality("rsrq", rsrq),
				sinr = sinr, sinr_quality = signal_quality("sinr", sinr),
			}
		end
	end
	return result
end

local function wwan_status()
	local conn = ubus.connect()
	if not conn then return nil end
	local status = conn:call("network.interface.wwan", "status", {})
	conn:close()
	return status
end

local function wwan_net_info()
	local status = wwan_status()
	if not status then return {} end
	local ipv4 = status["ipv4-address"] and status["ipv4-address"][1]
	local dns = {}
	for _, d in ipairs(status["dns-server"] or {}) do
		table.insert(dns, d)
	end
	return { ipaddr = ipv4 and ipv4.address, dns_servers = as_array(dns) }
end

local function get_imei()
	local resp = at.command("AT+CGSN", 2)
	if not resp then return nil end
	return resp:match("(%d+)")
end

local function operator_and_network_type()
	local cops = at.command("AT+COPS?", 3)
	local cops_fields = at.csv_fields(cops, "+COPS")
	local operator = cops_fields and cops_fields[3]

	local qnwinfo = at.command("AT+QNWINFO", 2)
	local nwinfo_fields = at.csv_fields(qnwinfo, "+QNWINFO")
	local act = nwinfo_fields and nwinfo_fields[1]

	local badge = "Unknown"
	if act then
		if act:match("NR5G") then badge = "5G"
		elseif act:match("LTE") then badge = "4G"
		elseif act then badge = "3G" end
	end
	return operator, badge
end

-- SMS: text-mode AT commands (AT+CMGF=1, +CMGL/+CMGS/+CMGD) - uqmi has no
-- message-service support, and text-mode AT SMS is the most portable/
-- well-documented path across modem vendors.
local function ensure_text_mode()
	at.command("AT+CMGF=1", 2)
end

local function parse_message_list(resp)
	local messages = {}
	if not resp then return messages end
	local STATUS = {
		["REC UNREAD"] = 0,
		["REC READ"] = 1,
		["STO SENT"] = 2,
		["STO UNSENT"] = 5,
	}
	local lines = {}
	for line in resp:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	local i = 1
	while i <= #lines do
		local idx, stat, sender, timestamp = lines[i]:match(
			'^%+CMGL:%s*(%d+),"([^"]*)","([^"]*)",[^,]*,"([^"]*)"')
		if idx then
			local yy, mm, dd, clock = timestamp:match("^(%d%d)/(%d%d)/(%d%d),(%d%d:%d%d:%d%d)")
			local date = timestamp
			if yy then
				date = string.format("20%s-%s-%s %s", yy, mm, dd, clock)
			end
			table.insert(messages, {
				-- The SMS view uses `name` as the stable deletion/read
				-- handle and numeric status enums:
				-- 0 unread, 1 read, 2 sent, 5 send failed/unsent.
				name = tostring(idx),
				id = tonumber(idx),
				status = STATUS[stat] or 5,
				phone_number = sender,
				sender = "",
				date = date,
				timestamp = timestamp,
				body = lines[i + 1] or "",
				bus = "mhi0",
				slot = 1,
			})
			i = i + 2
		else
			i = i + 1
		end
	end
	return messages
end

-- AT+QNWPREFCFG="lte_band"/"nr5g_band"/"nsa_nr5g_band" takes a plain
-- colon-separated list of enabled band numbers (e.g.
-- "1:2:3:4:5:7:8:12:...:71"), not a hex bitmask. Full band lists here
-- are used to restore "no mask" (every band enabled) when the user
-- disables band-mask mode.
local ALL_LTE_BANDS = "1:2:3:4:5:7:8:12:13:14:17:18:19:20:25:26:28:29:30:32:34:38:39:40:41:42:43:46:48:66:71"
local ALL_NR_BANDS = "1:2:3:5:7:8:12:13:14:18:20:25:26:28:29:30:38:40:41:48:66:70:71:75:76:77:78:79"

local function split_band_list(raw)
	local bands = {}
	for band in raw:gmatch("%d+") do table.insert(bands, tonumber(band)) end
	return bands
end

local function allowed_after_blocking(all_raw, blocked)
	local deny, allowed = {}, {}
	for _, band in ipairs(blocked or {}) do deny[tonumber(band)] = true end
	for _, band in ipairs(split_band_list(all_raw)) do
		if not deny[band] then table.insert(allowed, band) end
	end
	return allowed
end

-- `bands` is a list of band numbers (as returned by UCI, so strings) -
-- strictly validated as plain positive integers before ever reaching the
-- AT command string, since this is spliced directly into one.
local function build_band_list(bands)
	local nums = {}
	for _, b in ipairs(bands) do
		local n = tonumber(b)
		if not n or n ~= math.floor(n) or n < 1 or n > 999 then
			return nil
		end
		table.insert(nums, tostring(math.floor(n)))
	end
	if #nums == 0 then return nil end
	return table.concat(nums, ":")
end

local function apply_band_mask(kind, list)
	local resp = at.command('AT+QNWPREFCFG="' .. kind .. '",' .. list, 5)
	return resp and resp:match("OK") ~= nil
end

local function read_band_list(kind)
	local fields = at.csv_fields(at.command('AT+QNWPREFCFG="' .. kind .. '"', 3), "+QNWPREFCFG")
	local raw = fields and fields[2]
	if not raw then return nil end
	local bands = {}
	for b in raw:gmatch("%d+") do
		table.insert(bands, tonumber(b))
	end
	return bands
end

local function access_technology_name(act)
	act = tonumber(act)
	if not act then return "Unknown" end
	-- 3GPP/Quectel COPS AcT values: 7 is E-UTRAN; newer Quectel
	-- firmware reports NR access using values above the LTE range.
	if act >= 10 then return "5G" end
	if act == 7 then return "4G" end
	if act == 2 or act == 4 or act == 5 or act == 6 then return "3G" end
	return "2G"
end

local function tower_strength(rsrp)
	rsrp = tonumber(rsrp)
	if not rsrp then return 0 end
	if rsrp >= -80 then return 5 end
	if rsrp >= -90 then return 4 end
	if rsrp >= -100 then return 3 end
	if rsrp >= -110 then return 2 end
	if rsrp >= -120 then return 1 end
	return 0
end

local function tower_country(mcc)
	return tonumber(mcc) == 216 and "Hungary" or nil
end

local function tower_operator()
	local fields = at.csv_fields(at.command("AT+COPS?", 3), "+COPS")
	return fields and fields[3] or nil
end

local function tower_record(source, operator)
	if not source or not source.network_type or not source.freq or not source.pci then
		return nil
	end
	local band = source.band
	if source.network_type == "NR5G" and band then
		band = tostring(band):gsub("^n", "")
	end
	return {
		network_type = source.network_type,
		carrier = operator,
		country = tower_country(source.mcc),
		mcc = tonumber(source.mcc),
		mnc = tonumber(source.mnc),
		cellid = source.cellid or source.cell_id or tostring(source.pci),
		band = tonumber(band) or band,
		bandwidth = source.bandwidth,
		scs = tonumber(source.scs),
		tac = source.tac,
		pci = tonumber(source.pci),
		rsrp = tonumber(source.rsrp),
		rsrq = tonumber(source.rsrq),
		srxlev = tonumber(source.srxlev),
		squal = tonumber(source.squal),
		freq = tonumber(source.freq),
		strength = tower_strength(source.rsrp),
	}
end

local function valid_uint(value, maximum)
	local number = tonumber(value)
	if not number or number ~= math.floor(number) or number < 0
		or (maximum and number > maximum) then
		return nil
	end
	return math.floor(number)
end

local function tower_section(slot)
	return "tower_slot" .. tostring(tonumber(slot) == 2 and 2 or 1)
end

local TOWER_OPTIONS = {
	"network_type", "carrier", "country", "mcc", "mnc", "cellid", "band",
	"bandwidth", "scs", "tac", "pci", "rsrp", "rsrq", "srxlev", "squal",
	"freq", "strength",
}

local function stored_tower(cursor, slot)
	local section = tower_section(slot)
	if cursor:get("gl-cellular", section) ~= "tower_lock" then return {} end
	local result = {}
	for _, option in ipairs(TOWER_OPTIONS) do
		local value = cursor:get("gl-cellular", section, option)
		if value ~= nil then result[option] = value end
	end
	for _, option in ipairs({
		"mcc", "mnc", "band", "scs", "pci", "rsrp", "rsrq", "srxlev",
		"squal", "freq", "strength",
	}) do
		if result[option] ~= nil then
			result[option] = tonumber(result[option])
			-- OpenWrt's Lua UCI binding exposes negative integer-looking
			-- options as uint32 on this target. Convert signal metrics back
			-- to their signed dBm/dB values before JSON serialization.
			if (option == "rsrp" or option == "rsrq" or option == "srxlev"
				or option == "squal") and result[option]
				and result[option] > 2147483647 then
				result[option] = result[option] - 4294967296
			end
		end
	end
	return result
end

local function modem_lock_state()
	local four = at.csv_fields(at.command('AT+QNWLOCK="common/4g"', 3), "+QNWLOCK")
	local five = at.csv_fields(at.command('AT+QNWLOCK="common/5g"', 3), "+QNWLOCK")
	if five and tonumber(five[2]) and tonumber(five[2]) ~= 0 then
		return {
			network_type = "NR5G", pci = tonumber(five[2]),
			freq = tonumber(five[3]), scs = tonumber(five[4]),
			band = tonumber(tostring(five[5] or ""):match("%d+")),
		}
	end
	if four and tonumber(four[2]) == 1 then
		return {
			network_type = "LTE", freq = tonumber(four[3]),
			pci = tonumber(four[4]),
		}
	end
	return nil
end

return {
	get_modem_info = function(args)
		return { imei = get_imei(), model = MODEM_MODEL }
	end,

	info = function(args)
		local operator, network_type = operator_and_network_type()
		local cursor = uci.cursor()
		return {
			model = MODEM_MODEL,
			imei = get_imei(),
			operator = operator,
			network_type = network_type,
			active_slot = tonumber(cursor:get("gl-cellular", "state", "active_slot") or "1"),
		}
	end,

	status = function(args)
		local status = wwan_status()
		local operator, network_type = operator_and_network_type()
		return {
			connected = status and status.up == true,
			device = status and status.device,
			ipaddr = status and status["ipv4-address"] and status["ipv4-address"][1]
				and status["ipv4-address"][1].address,
			operator = operator,
			network_type = network_type,
		}
	end,

	set_connect = function(args)
		local cursor = uci.cursor()
		if args.apn then cursor:set("network", "wwan", "apn", args.apn) end
		if args.auth then cursor:set("network", "wwan", "auth", args.auth) end
		if args.username then cursor:set("network", "wwan", "username", args.username) end
		if args.password then cursor:set("network", "wwan", "password", args.password) end
		cursor:commit("network")
		cursor:set("gl-cellular", "state", "dial_enabled", "1")
		cursor:commit("gl-cellular")
		os.execute("ifup wwan >/dev/null 2>&1")
		return {}
	end,

	disconnect = function(args)
		local cursor = uci.cursor()
		cursor:set("gl-cellular", "state", "dial_enabled", "0")
		cursor:commit("gl-cellular")
		os.execute("ifdown wwan >/dev/null 2>&1")
		return {}
	end,

	-- Detect modem presence via actual AT-port responsiveness rather than
	-- whether the wwan data interface is up - those are different
	-- conditions, and gating presence on data-up made the Internet page's
	-- cellular card show "No Modem device found" even while the built-in
	-- RM520N-GL responded fine to AT commands.
	get_modem_current_interface = function(args)
		if get_imei() then
			-- The Internet card derives this identifier from the modem bus:
			-- mhi0 -> modem_mhi0.  Keep it identical here so the Multi-WAN
			-- config is not filtered out and its offline warning can reach
			-- the card.
			return { interfaces = { "modem_mhi0" } }
		end
		return { interfaces = cjson.empty_array }
	end,

	set_airplane_mode = function(args)
		local resp = at.command("AT+CFUN=" .. (args.enable and "0" or "1"), 8)
		if not resp or not resp:match("OK") then
			return { code = 1, message = "modem rejected AT+CFUN" }
		end
		return {}
	end,

	-- --- SIM config (formerly sim.lua's get_config/set_config) ---

	get_sim_config = function(args)
		local cursor = uci.cursor()
		local mask_enabled = cursor:get("gl-cellular", "state", "band_mask_enabled") == "1"
		-- Keep the user's selections, not the modem's resulting allow-list.
		-- In Block mode these are intentionally opposite sets.
		local lte_bands = cursor:get("gl-cellular", "state", "lte_bands") or {}
		local nr_bands = cursor:get("gl-cellular", "state", "nr_bands") or {}
		local sa_bands = cursor:get("gl-cellular", "state", "sa_bands") or {}
		local pdptype = (cursor:get("network", "wwan", "pdptype") or "ip"):lower()
		local ip_type = ({ ip = 1, ipv4 = 1, ipv6 = 2, ipv4v6 = 0 })[pdptype] or 1
		local filter_mode = cursor:get("gl-cellular", "state", "band_mask_mode") or "block"
		return {
			apn = cursor:get("network", "wwan", "apn"),
			ip_type = ip_type,
			network_mode = (cursor:get("network", "wwan", "modes") or "auto"):upper(),
			roaming = cursor:get("gl-cellular", "state", "roaming_enabled") ~= "0",
			protocol = cursor:get("network", "wwan", "proto") or "mbim",
			auth = (cursor:get("network", "wwan", "auth") or "none"):upper(),
			username = cursor:get("network", "wwan", "username") or "",
			password = cursor:get("network", "wwan", "password") or "",
			ttl = cursor:get("gl-cellular", "state", "ttl"),
			hl = cursor:get("gl-cellular", "state", "ttl_ipv6"),
			mtu = cursor:get("network", "wwan", "mtu"),
			band_enable = mask_enabled,
			band_filter_mode = filter_mode == "only" and 0 or 1,
			band_list = {
				LTE = as_array(lte_bands),
				["NR-NSA"] = as_array(nr_bands),
				["NR-SA"] = as_array(sa_bands),
			},
		}
	end,

	-- args.data={apn, ip_type, network_type, roaming_enabled, auth,
	--   username, password, ttl, ttl_ipv6, mtu, band_mask_enabled,
	--   band_mask_mode, lte_bands, nr_bands}
	set_sim_config = function(args)
		local data = args.data or args
		local cursor = uci.cursor()
		local ip_types = { [0] = "ipv4v6", [1] = "ipv4", [2] = "ipv6" }
		local ip_type = ip_types[tonumber(data.ip_type)] or data.ip_type
		local roaming = data.roaming
		if roaming == nil then roaming = data.roaming_enabled end
		local mask_enabled = data.band_enable
		if mask_enabled == nil then mask_enabled = data.band_mask_enabled end
		local band_list = type(data.band_list) == "table" and data.band_list or {}
		local lte_bands = data.lte_bands or band_list.LTE
		local nr_bands = data.nr_bands or band_list["NR-NSA"]
		local sa_bands = data.sa_bands or band_list["NR-SA"]
		local filter_mode = data.band_filter_mode
		if filter_mode == nil then filter_mode = data.band_mask_mode end

		if data.apn then cursor:set("network", "wwan", "apn", data.apn) end
		if ip_type then cursor:set("network", "wwan", "pdptype", tostring(ip_type):lower()) end
		if data.network_type then
			cursor:set("network", "wwan", "modes", tostring(data.network_type):lower())
		end
		if data.protocol == "mbim" then
			cursor:set("network", "wwan", "proto", "mbim")
		end
		if data.auth then
			local auth = tostring(data.auth):lower()
			if auth == "none" then
				cursor:delete("network", "wwan", "auth")
			else
				cursor:set("network", "wwan", "auth", auth)
			end
		end
		if data.username then cursor:set("network", "wwan", "username", data.username) end
		if data.password then cursor:set("network", "wwan", "password", data.password) end
		if tonumber(data.mtu) and tonumber(data.mtu) > 0 then
			cursor:set("network", "wwan", "mtu", tostring(data.mtu))
		elseif data.mtu ~= nil then
			cursor:delete("network", "wwan", "mtu")
		end
		cursor:commit("network")

		if roaming ~= nil then
			cursor:set("gl-cellular", "state", "roaming_enabled", roaming and "1" or "0")
		end
		if tonumber(data.ttl) and tonumber(data.ttl) > 0 then
			cursor:set("gl-cellular", "state", "ttl", tostring(data.ttl))
		elseif data.ttl ~= nil then
			cursor:delete("gl-cellular", "state", "ttl")
		end
		local ttl_ipv6 = data.hl
		if ttl_ipv6 == nil then ttl_ipv6 = data.ttl_ipv6 end
		if tonumber(ttl_ipv6) and tonumber(ttl_ipv6) > 0 then
			cursor:set("gl-cellular", "state", "ttl_ipv6", tostring(ttl_ipv6))
		elseif ttl_ipv6 ~= nil then
			cursor:delete("gl-cellular", "state", "ttl_ipv6")
		end
		if mask_enabled ~= nil then
			cursor:set("gl-cellular", "state", "band_mask_enabled", mask_enabled and "1" or "0")
		end
		if filter_mode ~= nil then
			cursor:set("gl-cellular", "state", "band_mask_mode",
				tonumber(filter_mode) == 0 and "only" or "block")
		end
		if type(lte_bands) == "table" then
			if #lte_bands > 0 then
				cursor:set("gl-cellular", "state", "lte_bands", lte_bands)
			else
				cursor:delete("gl-cellular", "state", "lte_bands")
			end
		end
		if type(nr_bands) == "table" then
			if #nr_bands > 0 then
				cursor:set("gl-cellular", "state", "nr_bands", nr_bands)
			else
				cursor:delete("gl-cellular", "state", "nr_bands")
			end
		end
		if type(sa_bands) == "table" then
			if #sa_bands > 0 then
				cursor:set("gl-cellular", "state", "sa_bands", sa_bands)
			else
				cursor:delete("gl-cellular", "state", "sa_bands")
			end
		end
		cursor:commit("gl-cellular")

		-- GL's "5G" choice is 5G-priority, not NR-only. NSA requires an
		-- LTE anchor, so NR5G:LTE is the correct Quectel preference.
		if data.network_mode then
			local pref = ({
				AUTO = "AUTO",
				NR5G = "NR5G:LTE",
				LTE = "LTE",
			})[tostring(data.network_mode):upper()]
			if pref then
				local resp = at.command('AT+QNWPREFCFG="mode_pref",' .. pref, 8)
				if not (resp and resp:match("OK")) then
					return { code = 1, message = "modem rejected network mode" }
				end
			end
		end

		-- If band masking is enabled, apply the selected LTE and 5G-NSA
		-- bands; if just disabled, restore every band ("no mask") rather
		-- than leaving a stale restrictive list active with masking
		-- nominally "off".
		if mask_enabled == nil then
			mask_enabled = cursor:get("gl-cellular", "state", "band_mask_enabled") == "1"
		end
		if mask_enabled then
			lte_bands = type(lte_bands) == "table" and lte_bands
				or cursor:get("gl-cellular", "state", "lte_bands")
			nr_bands = type(nr_bands) == "table" and nr_bands
				or cursor:get("gl-cellular", "state", "nr_bands")
			sa_bands = type(sa_bands) == "table" and sa_bands
				or cursor:get("gl-cellular", "state", "sa_bands")
			local block_mode = tonumber(filter_mode) == 1
				or filter_mode == "block"
			local apply_lte = block_mode
				and allowed_after_blocking(ALL_LTE_BANDS, lte_bands) or lte_bands
			local apply_nsa = block_mode
				and allowed_after_blocking(ALL_NR_BANDS, nr_bands) or nr_bands
			local apply_sa = block_mode
				and allowed_after_blocking(ALL_NR_BANDS, sa_bands) or sa_bands
			if apply_lte and #apply_lte > 0 then
				local list = build_band_list(apply_lte)
				if not list or not apply_band_mask("lte_band", list) then
					return { code = 1, message = "modem rejected LTE band mask" }
				end
			end
			if apply_nsa and #apply_nsa > 0 then
				local list = build_band_list(apply_nsa)
				if not list or not apply_band_mask("nsa_nr5g_band", list) then
					return { code = 1, message = "modem rejected 5G NSA band mask" }
				end
			end
			if apply_sa and #apply_sa > 0 then
				local list = build_band_list(apply_sa)
				if not list or not apply_band_mask("nr5g_band", list) then
					return { code = 1, message = "modem rejected 5G SA band mask" }
				end
			end
		elseif mask_enabled == false then
			apply_band_mask("lte_band", ALL_LTE_BANDS)
			apply_band_mask("nsa_nr5g_band", ALL_NR_BANDS)
			apply_band_mask("nr5g_band", ALL_NR_BANDS)
		end

		-- "Changing the configuration will result in redialing" (matches
		-- the warning banner in the supplied screenshot).  A bare ifup does
		-- not disconnect an already-activated MBIM session.  The old bearer
		-- then remains cosmetically up with an address but silently drops
		-- every packet.  Tear it down first so the new APN/IP profile always
		-- receives a fresh MBIM activation and gateway.
		os.execute("(ifdown wwan >/dev/null 2>&1; sleep 2; ifup wwan >/dev/null 2>&1) &")
		return {}
	end,

	set_sim_pin_code = function(args)
		-- SIM PINs are always numeric (3GPP TS 22.030) - validating this
		-- strictly also closes the AT-command-injection risk a naive
		-- quote-stripping approach would leave open.
		local pin = tostring(args.pin_code or args.pin or "")
		if not pin:match("^%d%d%d%d+$") then
			return { code = 1, message = "invalid pin_code" }
		end
		local resp = at.command('AT+CPIN="' .. pin .. '"', 5)
		if not (resp and resp:match("OK")) then
			return { code = 1, message = "PIN verification failed" }
		end

		-- Persist so the SIM auto-unlocks on every future connection
		-- attempt, including after reboot. netifd's `mbim` proto already
		-- applies a `pincode` option automatically - just seed it.
		local cursor = uci.cursor()
		cursor:set("network", "wwan", "pincode", pin)
		cursor:commit("network")
		return {}
	end,

	-- --- Cell tower / signal (formerly sim.lua's get_cell_info, split to
	-- match the real frontend's two separate methods) ---

	get_cell_tower = function(args)
		local cursor = uci.cursor()
		local tower = stored_tower(cursor, 1)
		local actual = modem_lock_state()
		if actual then
			for key, value in pairs(actual) do tower[key] = value end
			tower.cellid = tower.cellid or tostring(actual.pci)
		elseif next(tower) ~= nil then
			-- Never claim a stale persisted lock after the modem has reset
			-- or somebody unlocked it with an AT command outside this UI.
			tower = {}
		end
		return { slot1 = tower, slot2 = {} }
	end,

	get_signals = function(args)
		-- This method belongs to the Historical Signal page, not the
		-- current-signal detail drawer. The frontend requires a threshold
		-- map plus a time-ordered sample array and otherwise renders a
		-- completely blank page.
		local conn = ubus.connect()
		local history = conn and conn:call("cellular", "signals_history", {
			time = math.max(10, math.min(1800, tonumber(args.time) or 180)),
		}) or nil
		if conn then conn:close() end
		return {
			level = history and history.level or {},
			signals = as_array(history and history.signals or {}),
		}
	end,

	scan_cell_tower = function(args)
		local serving = get_serving_cell()
		local operator = tower_operator()
		local towers, seen = {}, {}
		local function add(source)
			local tower = tower_record(source, operator)
			if not tower then return end
			local key = tower.network_type .. ":" .. tower.freq .. ":" .. tower.pci
			if seen[key] then return end
			seen[key] = true
			table.insert(towers, tower)
		end

		if serving then
			serving.cellid = serving.cell_id
			serving.bandwidth = serving.dl_bandwidth
			add(serving)
			if serving.nr then
				serving.nr.cellid = serving.nr.cell_id
				serving.nr.bandwidth = serving.nr.dl_bandwidth
				serving.nr.tac = serving.tac
				add(serving.nr)
			end
		end

		-- QENG neighbourcell is a quick read-only measurement on RM520N;
		-- unlike COPS=?, it neither deregisters the modem nor blocks data.
		local response = at.command('AT+QENG="neighbourcell"', 8)
		for _, fields in ipairs(at.all_matches(response, "+QENG")) do
			local kind = fields[1] or ""
			if kind:match("^neighbourcell") and fields[2] == "LTE" then
				add({
					network_type = "LTE",
					mcc = serving and serving.mcc,
					mnc = serving and serving.mnc,
					tac = serving and serving.tac,
					band = serving and serving.band,
					freq = tonumber(fields[3]),
					pci = tonumber(fields[4]),
					rsrq = tonumber(fields[5]),
					rsrp = tonumber(fields[6]),
					rssi = tonumber(fields[7]),
				})
			elseif kind:match("^neighbourcell") and fields[2]
				and fields[2]:match("^NR5G") then
				add({
					network_type = "NR5G",
					mcc = serving and serving.mcc,
					mnc = serving and serving.mnc,
					tac = serving and serving.tac,
					freq = tonumber(fields[3]),
					pci = tonumber(fields[4]),
					rsrq = tonumber(fields[5]),
					rsrp = tonumber(fields[6]),
					band = tonumber(fields[8]),
					scs = tonumber(fields[9]),
				})
			end
		end
		table.sort(towers, function(a, b)
			return (a.strength or 0) > (b.strength or 0)
		end)
		return { towers = as_array(towers) }
	end,

	set_cell_tower = function(args)
		local slot = tonumber(args.slot) == 2 and 2 or 1
		if slot ~= 1 then
			return { code = 1, message = "this device has only SIM slot 1" }
		end
		local cursor = uci.cursor()
		local section = tower_section(slot)
		local lock = args.lock == true or args.lock == 1
			or tostring(args.lock):lower() == "true"

		if not lock then
			local four = at.command('AT+QNWLOCK="common/4g",0', 8)
			local five = at.command('AT+QNWLOCK="common/5g",0', 8)
			if not ((four and four:match("OK")) or (five and five:match("OK"))) then
				return { code = 1, message = "modem rejected tower unlock" }
			end
			cursor:delete("gl-cellular", section)
			cursor:commit("gl-cellular")
			local mode = (cursor:get("network", "wwan", "modes") or "auto"):lower()
			local preference = mode == "lte" and "LTE"
				or (mode == "nr5g" and "NR5G:LTE" or "AUTO")
			-- LTE tower locking disables NR5G at the modem.  Always undo
			-- that side effect when unlocking; changing mode_pref alone
			-- does not clear nr5g_disable_mode on RM520N firmware.
			at.command('AT+QNWPREFCFG="nr5g_disable_mode",0', 8)
			at.command('AT+QNWPREFCFG="mode_pref",' .. preference, 8)
			os.execute("(ifdown wwan >/dev/null 2>&1; sleep 1; ifup wwan >/dev/null 2>&1) &")
			return {}
		end

		if tonumber(cursor:get("gl-cellular", "state", "operator_mode") or "0") ~= 0 then
			return { code = 1, message = "unlock the mobile operator before locking a tower" }
		end
		local network_type = tostring(args.network_type or ""):upper()
		local pci = valid_uint(args.pci, 1007)
		local freq = valid_uint(args.freq, 4000000)
		if not pci or not freq then
			return { code = 1, message = "tower is missing a valid frequency or PCI" }
		end

		local response
		if network_type == "LTE" then
			at.command('AT+QNWPREFCFG="mode_pref",LTE:NR5G', 8)
			at.command('AT+QNWPREFCFG="nr5g_disable_mode",1', 8)
			response = at.command(string.format(
				'AT+QNWLOCK="common/4g",1,%d,%d', freq, pci), 8)
		elseif network_type == "NR5G" then
			local scs = valid_uint(args.scs, 4)
			local band = valid_uint(tostring(args.band or ""):match("%d+"), 999)
			if not scs or not band then
				return { code = 1, message = "5G tower is missing SCS or band" }
			end
			-- Telekom's n78 service here is NSA, so the LTE anchor must
			-- remain permitted while preferring/locking the NR cell.
			at.command('AT+QNWPREFCFG="nr5g_disable_mode",0', 8)
			at.command('AT+QNWPREFCFG="mode_pref",NR5G:LTE', 8)
			response = at.command(string.format(
				'AT+QNWLOCK="common/5g",%d,%d,%d,%d',
				pci, freq, scs, band), 8)
		else
			return { code = 1, message = "tower network type must be LTE or NR5G" }
		end
		if not (response and response:match("OK")) then
			return { code = 1, message = "modem rejected tower lock" }
		end

		cursor:set("gl-cellular", section, "tower_lock")
		for _, option in ipairs(TOWER_OPTIONS) do
			local value = args[option]
			if value ~= nil and tostring(value) ~= "" then
				cursor:set("gl-cellular", section, option, tostring(value))
			end
		end
		cursor:set("gl-cellular", section, "network_type", network_type)
		cursor:set("gl-cellular", section, "pci", tostring(pci))
		cursor:set("gl-cellular", section, "freq", tostring(freq))
		cursor:commit("gl-cellular")
		os.execute("(ifdown wwan >/dev/null 2>&1; sleep 1; ifup wwan >/dev/null 2>&1) &")
		return {}
	end,

	-- --- Dual-SIM slot ---
	--
	-- AT+QDSIM is not supported on this modem/firmware (returns plain
	-- ERROR). AT+QUIMSLOT is the real, working command on the RM520N-GL,
	-- both for reading (get_slot_config) and switching (AT+QUIMSLOT=<slot>).

	get_slot_config = function(args)
		local fields = at.csv_fields(at.command("AT+QUIMSLOT?", 2), "+QUIMSLOT")
		local slot = fields and tonumber(fields[1])
		if not slot then
			local cursor = uci.cursor()
			slot = tonumber(cursor:get("gl-cellular", "state", "active_slot") or "1")
		end
		return { active_slot = slot }
	end,

	-- Device only has one physical SIM slot config path (active_slot,
	-- the same UCI value set_slot_failover_config persists), so this
	-- reports that rather than inventing a multi-slot priority scheme.
	get_slot_failover_config = function(args)
		local cursor = uci.cursor()
		local slot = tonumber(cursor:get("gl-cellular", "state", "active_slot") or "1")
		return { enabled = false, slot = slot, slot_priority = { slot } }
	end,

	set_slot_failover_config = function(args)
		local slot = args.slot or (args.slot_priority and args.slot_priority[1])
		if not tonumber(slot) then
			return { code = 1, message = "missing/invalid slot" }
		end
		local resp = at.command("AT+QUIMSLOT=" .. tostring(math.floor(tonumber(slot))), 5)
		if not resp or not resp:match("OK") then
			return { code = 1, message = "modem rejected slot switch (AT+QUIMSLOT)" }
		end
		local cursor = uci.cursor()
		cursor:set("gl-cellular", "state", "active_slot", tostring(math.floor(tonumber(slot))))
		cursor:commit("gl-cellular")
		os.execute("ifup wwan >/dev/null 2>&1")
		return {}
	end,

	-- --- Operator selection ---

	get_operator_config = function(args)
		local cursor = uci.cursor()
		local mode = tonumber(cursor:get("gl-cellular", "state", "operator_mode") or "0")
		-- The operator drawer's selectable values are only Manual (1) and
		-- Manual-Auto (4). For an unlocked/automatic slot it expects an
		-- empty object, then initializes the form to Manual itself; exposing
		-- COPS mode 0 here renders a raw, invalid "0" option.
		local slot1 = cjson.empty_array
		if mode ~= 0 then
			slot1 = { mode = mode }
			slot1.plmn = cursor:get("gl-cellular", "state", "operator_mcc_mnc")
			slot1.long_opername = cursor:get("gl-cellular", "state", "operator_name") or slot1.plmn
			slot1.network_type = cursor:get("gl-cellular", "state", "operator_network_type") or "4G"
			slot1.act = tonumber(cursor:get("gl-cellular", "state", "operator_act") or "")
		end
		return { slot1 = slot1, slot2 = cjson.empty_array }
	end,

	set_operator_config = function(args)
		local cursor = uci.cursor()
		local mode = tonumber(args.mode)
		if mode == 0 then
			local resp = at.command("AT+COPS=0", 60)
			if not (resp and resp:match("OK")) then
				return { code = 1, message = "modem rejected automatic carrier selection" }
			end
			cursor:set("gl-cellular", "state", "operator_mode", "0")
		elseif mode == 1 or mode == 4 then
			local plmn = tostring(args.plmn or args.operator or "")
			if not plmn:match("^%d%d%d%d%d%d?$") then
				return { code = 1, message = "invalid PLMN (expected MCC+MNC digits)" }
			end
			local act = tonumber(args.act)
			local command = string.format('AT+COPS=%d,2,"%s"', mode, plmn)
			if act then command = command .. "," .. tostring(math.floor(act)) end
			local resp = at.command(command, 120)
			if not (resp and resp:match("OK")) then
				return { code = 1, message = "modem rejected carrier lock" }
			end
			cursor:set("gl-cellular", "state", "operator_mode", tostring(mode))
			cursor:set("gl-cellular", "state", "operator_mcc_mnc", plmn)
			cursor:set("gl-cellular", "state", "operator_name",
				tostring(args.long_opername or args.name or plmn))
			cursor:set("gl-cellular", "state", "operator_network_type",
				tostring(args.network_type or access_technology_name(act)))
			if act then cursor:set("gl-cellular", "state", "operator_act", tostring(act)) end
		else
			return { code = 1, message = "invalid carrier selection mode" }
		end
		cursor:commit("gl-cellular")
		return {}
	end,

	-- AT+COPS=? is slow (it can take several minutes scanning all bands) -
	-- the frontend deliberately permits ten minutes for this request and
	-- gloui.at uses ubus(1)'s extended timeout for long commands.
	-- Response format per 3GPP TS
	-- 27.007: +COPS: (<stat>,"<long>","<short>","<numeric>"[,<AcT>])(...)...
	-- - each parenthesized group is one operator; <stat> is 0=unknown,
	-- 1=available, 2=current, 3=forbidden.
	scan_operator_list = function(args)
		local cursor = uci.cursor()
		local redial = cursor:get("gl-cellular", "state", "dial_enabled") ~= "0"
		-- A COPS scan temporarily takes the modem out of packet service.
		-- Stop the MBIM interface cleanly first, then have the independent
		-- long-command worker always redial it after the scan—even if the
		-- browser closes the drawer/request before the scan completes.
		if redial then
			os.execute("/sbin/ifdown wwan >/dev/null 2>&1")
		end
		local resp = at.command("AT+COPS=?", 300, { redial_wwan = redial })
		if not resp and redial then
			os.execute("/sbin/ifup wwan >/dev/null 2>&1")
		end
		local results = {}
		local STAT_NAME = { [0] = "unknown", [1] = "available", [2] = "current", [3] = "forbidden" }
		if resp then
			for stat, long_name, short_name, numeric, act in
				resp:gmatch('%((%d),"([^"]*)","([^"]*)","([^"]*)",?(%d*)%)') do
				table.insert(results, {
					status = STAT_NAME[tonumber(stat)] or "unknown",
					long_opername = long_name ~= "" and long_name or short_name,
					short_opername = short_name,
					plmn = numeric,
					network_type = access_technology_name(act),
					act = act ~= "" and tonumber(act) or nil,
				})
			end
		end
		return { operators = as_array(results) }
	end,

	-- --- APN profiles ---

	get_profile_list = function(args)
		local cursor = uci.cursor()
		local profiles = {}
		cursor:foreach("gl-cellular", "apn_profile", function(s)
			table.insert(profiles, {
				id = s[".name"], name = s.name, apn = s.apn,
				auth = s.auth, username = s.username, ip_type = s.ip_type,
			})
		end)
		return { profiles = as_array(profiles) }
	end,

	set_profile = function(args)
		if type(args.name) ~= "string" or args.name == "" then
			return { code = 1, message = "missing name" }
		end
		local cursor = uci.cursor()
		local id = args.id
		if not id or not cursor:get("gl-cellular", id) then
			id = cursor:add("gl-cellular", "apn_profile")
		end
		cursor:set("gl-cellular", id, "name", args.name)
		if args.apn then cursor:set("gl-cellular", id, "apn", args.apn) end
		if args.auth then cursor:set("gl-cellular", id, "auth", args.auth) end
		if args.username then cursor:set("gl-cellular", id, "username", args.username) end
		if args.ip_type then cursor:set("gl-cellular", id, "ip_type", args.ip_type) end
		cursor:commit("gl-cellular")
		return { id = id }
	end,

	remove_profile = function(args)
		if not args.id then
			return { code = 1, message = "missing id" }
		end
		local cursor = uci.cursor()
		cursor:delete("gl-cellular", args.id)
		cursor:commit("gl-cellular")
		return {}
	end,

	-- APN database update - no remote update source/signing story defined
	-- yet, so this acknowledges the request without claiming a real
	-- update happened.
	set_apn_db_update = function(args)
		return { code = 0, note = "APN database update not yet implemented" }
	end,

	-- --- Data usage / traffic accounting ---

	get_traffic_config = function(args)
		local cursor = uci.cursor()
		local total = tostring(tonumber(cursor:get("gl-cellular", "state", "data_used_bytes") or "0") or 0)
		local limit_enabled = cursor:get("gl-cellular", "state", "data_limit_enabled") == "1"
		local limit_bytes = tostring(tonumber(cursor:get("gl-cellular", "state", "data_limit_bytes") or "0") or 0)
		return {
			save_to_flash = cursor:get("gl-cellular", "state", "save_traffic") == "1",
			traffic = {
				{ slot = 1, type = 0, traffic_total = total },
			},
			limit = {
				{
					slot = 1, type = 0, enable = limit_enabled,
					threshold = limit_bytes,
					reset_period = cursor:get("gl-cellular", "state", "data_reset_period") or "month",
					month_day = cursor:get("gl-cellular", "state", "data_reset_day") or "1",
					hour = cursor:get("gl-cellular", "state", "data_reset_hour") or "0",
				},
			},
		}
	end,

	set_traffic_config = function(args)
		local cursor = uci.cursor()
		if args.save_to_flash ~= nil then
			cursor:set("gl-cellular", "state", "save_traffic", args.save_to_flash and "1" or "0")
		end
		local traffic = type(args.traffic) == "table" and args.traffic[1]
		if traffic and traffic.traffic_total ~= nil then
			cursor:set("gl-cellular", "state", "data_used_bytes",
				tostring(math.floor(tonumber(traffic.traffic_total) or 0)))
		end
		local limit = type(args.limit) == "table" and args.limit[1]
		if limit then
			cursor:set("gl-cellular", "state", "data_limit_enabled", limit.enable and "1" or "0")
			if limit.threshold ~= nil then
				cursor:set("gl-cellular", "state", "data_limit_bytes",
					tostring(math.floor(tonumber(limit.threshold) or 0)))
			end
			if limit.reset_period then
				cursor:set("gl-cellular", "state", "data_reset_period", tostring(limit.reset_period))
			end
			local reset_day = limit.month_day or limit.week_day or limit.year_day
			if reset_day then cursor:set("gl-cellular", "state", "data_reset_day", tostring(reset_day)) end
			if limit.hour then cursor:set("gl-cellular", "state", "data_reset_hour", tostring(limit.hour)) end
		end
		cursor:commit("gl-cellular")

		return {}
	end,

	-- --- SMS (formerly sms.lua) ---

	get_sms_list = function(args)
		ensure_text_mode()
		local resp = at.command('AT+CMGL="ALL"', 5)
		return { list = as_array(parse_message_list(resp)) }
	end,

	send_sms = function(args)
		if type(args.phone_number) ~= "string" or type(args.body) ~= "string" then
			return { code = 1, message = "missing phone_number/body" }
		end
		-- Defense in depth against AT command injection via an embedded
		-- CR smuggling a second command.
		if not args.phone_number:match("^[%w%+%(%)%-]+$") then
			return { code = 1, message = "invalid phone_number" }
		end
		if args.body:match("[\r\n\26]") then
			return { code = 1, message = "body must not contain control characters" }
		end
		ensure_text_mode()
		local conn = ubus.connect()
		if not conn then
			return { code = 1, message = "ubus connect failed" }
		end
		local res = conn:call("cellular.at", "command", {
			cmd = string.format('AT+CMGS="%s"\r%s\26', args.phone_number, args.body),
			timeout = 10,
		})
		conn:close()
		if res and res.response and res.response:match("+CMGS:") then
			return {}
		end
		return { code = 1, message = "send failed" }
	end,

	remove_sms = function(args)
		ensure_text_mode()
		local messages = parse_message_list(at.command('AT+CMGL="ALL"', 5))
		local targets = {}
		local scope = tonumber(args.scope) or 10
		for _, msg in ipairs(messages) do
			if (scope == 10 and tostring(args.name or args.id or "") == msg.name)
				or (scope == 1 and msg.status == 1)
				or (scope == 12 and (msg.status == 0 or msg.status == 1))
				or (scope == 13 and msg.status >= 2) then
				table.insert(targets, msg.id)
			end
		end
		if scope == 10 and #targets == 0 then
			return { code = 1, message = "message not found" }
		end
		for _, id in ipairs(targets) do
			local resp = at.command("AT+CMGD=" .. tostring(id), 3)
			if not (resp and resp:match("OK")) then
				return { code = 1, message = "delete failed" }
			end
		end
		return {}
	end,

	-- Mark one received SMS, or every received SMS, as read. SMS
	-- forwarding is a separate `sms-forward` object in the real UI.
	set_sms = function(args)
		ensure_text_mode()
		local messages = parse_message_list(at.command('AT+CMGL="ALL"', 5))
		local targets = {}
		if tonumber(args.status) == 6 then
			for _, msg in ipairs(messages) do
				if msg.status == 0 then table.insert(targets, msg.id) end
			end
		elseif args.name then
			table.insert(targets, tonumber(args.name))
		else
			return { code = 1, message = "missing name/status" }
		end
		for _, id in ipairs(targets) do
			local resp = at.command("AT+CMGR=" .. tostring(id), 3)
			if not resp then
				return { code = 1, message = "mark read failed" }
			end
		end
		return {}
	end,

	-- --- Advanced / debug ---

	-- Raw AT command console. Deliberately NOT restricted to a command
	-- allowlist (the real GL feature is an open AT console for advanced
	-- users) - but timeout is capped and the command is passed through
	-- gl-cellular-atd's own serial-write path (a single line write, same
	-- injection surface as every other AT call in this file: the caller
	-- IS the "second command" here, by design, unlike send_sms/
	-- set_sim_pin_code where injection would let one field smuggle in an
	-- unintended second command).
	send_at_command = function(args)
		if type(args.command) ~= "string" or args.command == "" then
			return { code = 1, message = "missing command" }
		end
		local timeout = math.max(1, math.min(30, tonumber(args.timeout) or 5))
		local resp = at.command(args.command, timeout)
		return { response = resp or "" }
	end,

	get_debug_msg = function(args)
		-- No persistent AT-command transcript log kept yet - returns the
		-- modem's own basic AT responsiveness as a minimal diagnostic
		-- rather than a fabricated log.
		local resp = at.command("ATI", 3)
		return { log = resp or "" }
	end,

	-- eSIM/MVAS deferred to a later iteration.
	get_esim_status = function(args)
		return { supported = false }
	end,

	-- --- Internal/administrative helpers ---

	update_modem_info = function(args)
		local resp = at.command("AT", 3)
		return { code = (resp and resp:match("OK")) and 0 or 1 }
	end,

	clean_switch_count = function(args)
		local cursor = uci.cursor()
		cursor:set("gl-cellular", "state", "switch_count", "0")
		cursor:commit("gl-cellular")
		return {}
	end,
}
