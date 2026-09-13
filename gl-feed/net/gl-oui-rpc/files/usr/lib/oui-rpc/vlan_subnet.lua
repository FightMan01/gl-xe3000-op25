-- "vlan_subnet" RPC object: native 802.1q VLAN subnet management.
--
-- This is a faithful port of GL's own wire contract (method names, input/
-- output field names, error codes, display-name-based addressing) reverse
-- engineered directly from their real vlan_subnet.lua source (~5300 lines,
-- plain Lua, extracted from firmware v4.10.0's squashfs - not compiled, no
-- decompilation needed) and cross-checked against a live GL-BE14000's real
-- get_subnets response. The *internal* implementation is intentionally
-- simplified for the GL-XE3000's actual hardware: exactly two physical
-- Ethernet ports (eth0 wan, eth1 lan), no built-in switch, no DSA
-- lan1..lan4 (confirmed against the live device: `ip -br link` shows only
-- eth0/eth1). So there is none of GL's multi-switch-chip/eth_ports_config_
-- map/libcable port-tagging abstraction here - a "custom VLAN subnet" on
-- this hardware means a tagged 802.1q sub-interface on the single eth1
-- trunk (for a downstream managed switch/AP), using netifd's native
-- `type '8021q'` device config directly.
--
-- Also intentionally NOT ported (separate subsystems this build doesn't
-- have, orthogonal to VLAN mechanics itself): gl-mesh config-renew
-- notification, gl-session client-alias sync, parental_control restart
-- hooks, eQoS restart scheduling, VPN-client source-interface rebinding,
-- TAP-S2S blocking, migrate_to_subnet/migrate_from_subnet (no legacy
-- single-bridge mode to migrate from on a fresh port), netmode_to_ap/
-- netmode_to_router, get_client_view (redundant with the "clients"
-- object), get_vpn_interfaces.
--
-- WiFi-SSID-per-custom-VLAN is also out of scope: wifi.lua's guest/iot
-- handling is tied to two fixed, pre-provisioned SSID sections, and
-- extending that to arbitrary custom networks is a separate, larger
-- change. Custom subnets from this object are wired-only; lan/guest/iot
-- keep their existing WiFi assignment untouched.

local uci = require "uci"
local cjson = require "cjson"
local bit = require "bit"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

-- Error codes match GL's real vlan_subnet.lua exactly, so a future full
-- frontend port (or anyone scripting against this API) gets identical
-- semantics regardless of which GL router answers.
local ERR_INVALID_PARAMS        = -1
local ERR_NO_VIRTUAL_WAN        = -5
local ERR_WAN_IP_CONFLICT       = -7
local ERR_LAN_IP_CONFLICT       = -8
local ERR_GUEST_IP_CONFLICT     = -9
local ERR_IOT_IP_CONFLICT       = -11
local ERR_VLAN_ID_OUT_OF_RANGE  = -12
local ERR_VLAN_ID_CONFLICT      = -13
local ERR_SUBNET_CONFLICT       = -14
local ERR_DHCP_INVALID          = -15
local ERR_DELETE_FIXED_SUBNET   = -17
local ERR_SUBNET_LIMIT_EXCEEDED = -18
local ERR_DISPLAY_NAME_CONFLICT = -19
local ERR_SUBNET_NOT_FOUND      = -20
local ERR_STATIC_BIND_SUBNET_SELECTOR  = -21
local ERR_STATIC_BIND_IP_NOT_IN_SUBNET = -22
local ERR_STATIC_BIND_GATEWAY_IP       = -23

local function rpc_error(code, msg, extra)
	local result = { err_code = code, err_msg = msg }
	if extra then for k, v in pairs(extra) do result[k] = v end end
	return result
end

local FIXED_SUBNETS = { "lan", "guest", "iot" }
local VLAN_ID_MIN = 9
local VLAN_ID_MAX = 4000
local MAX_CUSTOM_SUBNETS = 16

local DISPLAY_NAME_MAP = { lan = "main", guest = "guest", iot = "iot" }
local NETWORK_MAP = { main = "lan", guest = "guest", iot = "iot" }

local DEFAULT_GATEWAY = {
	lan = "192.168.8.1", guest = "192.168.9.1", iot = "192.168.10.1",
}

local function is_fixed_subnet(network)
	for _, n in ipairs(FIXED_SUBNETS) do
		if n == network then return true end
	end
	return false
end

local function is_custom_name(network)
	return type(network) == "string" and network:match("^vlan%d+$") ~= nil
end

local function vlan_id_of(network)
	local vid = network and network:match("^vlan(%d+)$")
	return vid and tonumber(vid)
end

-- --- bit-math IP helpers -------------------------------------------------
--
-- The RPC layer runs under nginx's embedded LuaJIT 2.1 (confirmed against
-- the live device: `nginx -V` links lua-nginx-module, no standalone Lua
-- 5.3+ interpreter exists on the box) - LuaJIT is Lua 5.1 syntax, so no
-- native `&`/`|`/`~`/`<<`/`//`; use the bit.* library like GL's own
-- vlan_subnet.lua does, normalizing results to unsigned 32-bit since
-- bit.* returns signed ints.

local function to_u32(n)
	if n < 0 then return n + 4294967296 end
	return n
end

local function band32(a, b)
	return to_u32(bit.band(a, b))
end

local function ip_to_number(ip)
	local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return a * 16777216 + b * 65536 + c * 256 + d
end

local function number_to_ip(n)
	if not n then return nil end
	local d = n % 256; n = math.floor((n - d) / 256)
	local c = n % 256; n = math.floor((n - c) / 256)
	local b = n % 256; n = math.floor((n - b) / 256)
	local a = n % 256
	return string.format("%d.%d.%d.%d", a, b, c, d)
end

local function is_private_ip(ip)
	local n = ip_to_number(ip)
	if not n then return false end
	local a = math.floor(n / 16777216)
	local b = math.floor(n / 65536) % 256
	if a == 10 then return true end
	if a == 172 and b >= 16 and b <= 31 then return true end
	if a == 192 and b == 168 then return true end
	return false
end

-- GL's "validate_gateway": valid IPv4 AND private.
local function validate_gateway(ip)
	return ip_to_number(ip) ~= nil and is_private_ip(ip)
end

local function prefix_to_netmask(prefix)
	prefix = tonumber(prefix)
	if not prefix or prefix < 1 or prefix > 32 then return nil end
	local mask = prefix == 32 and 0xFFFFFFFF or to_u32(bit.bnot(2 ^ (32 - prefix) - 1))
	return number_to_ip(mask)
end

local function network_overlap(ip1, mask1, ip2, mask2)
	local n1, n2 = ip_to_number(ip1), ip_to_number(ip2)
	local m1, m2 = ip_to_number(mask1), ip_to_number(mask2)
	if not (n1 and n2 and m1 and m2) then return false end
	local common = m1 < m2 and m1 or m2
	return band32(n1, common) == band32(n2, common)
end

local function validate_netmask(netmask)
	local n = ip_to_number(netmask)
	if not n or n == 0 then return false end
	local inv = to_u32(bit.bnot(n))
	return band32(inv, inv + 1) == 0
end

local function dhcp_offset_to_ips(gateway, netmask, start, limit)
	local gw_n, nm_n = ip_to_number(gateway), ip_to_number(netmask)
	if not gw_n or not nm_n or not start or not limit then return nil, nil end
	local net_addr = band32(gw_n, nm_n)
	return number_to_ip(net_addr + start), number_to_ip(net_addr + start + limit - 1)
end

local function ip_to_dhcp_offset(ip, gateway, netmask)
	local ip_n, gw_n, nm_n = ip_to_number(ip), ip_to_number(gateway), ip_to_number(netmask)
	if not (ip_n and gw_n and nm_n) then return nil end
	local offset = ip_n - band32(gw_n, nm_n)
	if offset < 1 then return nil end
	return offset
end

-- --- UCI helpers ----------------------------------------------------------

local function get_all_custom_networks(c)
	local names = {}
	c:foreach("network", "interface", function(s)
		if is_custom_name(s[".name"]) then names[#names + 1] = s[".name"] end
	end)
	table.sort(names)
	return names
end

local function get_all_subnet_networks(c)
	local all = {}
	for _, n in ipairs(FIXED_SUBNETS) do
		if c:get("network", n) then all[#all + 1] = n end
	end
	for _, n in ipairs(get_all_custom_networks(c)) do all[#all + 1] = n end
	return all
end

local function count_custom_subnets(c)
	return #get_all_custom_networks(c)
end

local function get_display_name(c, network)
	if not network then return nil end
	if DISPLAY_NAME_MAP[network] then
		return c:get("network", network, "display_name") or DISPLAY_NAME_MAP[network]
	end
	return c:get("network", network, "display_name") or network
end

local function display_name_exists(c, display_name, exclude_network)
	for _, net in ipairs(get_all_subnet_networks(c)) do
		if net ~= exclude_network and get_display_name(c, net) == display_name then
			return true
		end
	end
	return false
end

-- Resolves a display_name (what the API calls subnets by) back to the
-- internal UCI network name ("main" -> "lan", a custom subnet's own
-- display_name -> "vlanN", ...).
local function resolve_display_name_to_network(c, display_name)
	if not display_name or display_name == "" then return nil end
	if NETWORK_MAP[display_name] then return NETWORK_MAP[display_name] end
	for _, net in ipairs(get_all_subnet_networks(c)) do
		if get_display_name(c, net) == display_name then return net end
	end
	return nil
end

local function get_vlan_id_for_network(c, network)
	if network == "lan" then return 1 end
	if network == "guest" then return tonumber((c:get("network", "guest", "vlan_id"))) or 9 end
	if network == "iot" then return tonumber((c:get("network", "iot", "vlan_id"))) or 10 end
	return vlan_id_of(network)
end

local function check_vlan_id_range(vlan_id)
	return type(vlan_id) == "number" and vlan_id == math.floor(vlan_id)
		and vlan_id >= VLAN_ID_MIN and vlan_id <= VLAN_ID_MAX
end

local function check_vlan_id_conflict(c, vlan_id, exclude_network)
	for _, net in ipairs(get_all_subnet_networks(c)) do
		if net ~= exclude_network and get_vlan_id_for_network(c, net) == vlan_id then
			return true
		end
	end
	return false
end

-- Same logical-WAN list as kmwan/lan.lua's own multi-WAN awareness:
-- wan/wwan/tethering/repeater plus any cellular modem_* interface.
local function build_wan_logical_interface_list(c)
	local wan_array = { "wan", "wwan", "tethering", "repeater" }
	c:foreach("network", "interface", function(s)
		local name = s[".name"]
		if name:sub(1, 6) == "modem_" then
			wan_array[#wan_array + 1] = name
		end
	end)
	return wan_array
end

local function subnet_conflict_rpc_error(c, conflict_network)
	if conflict_network == "wan" then return rpc_error(ERR_WAN_IP_CONFLICT, "conflict with wan ip") end
	if conflict_network == "lan" then return rpc_error(ERR_LAN_IP_CONFLICT, "conflict with lan ip") end
	if conflict_network == "guest" then return rpc_error(ERR_GUEST_IP_CONFLICT, "conflict with guest ip") end
	if conflict_network == "iot" then return rpc_error(ERR_IOT_IP_CONFLICT, "conflict with iot ip") end
	if conflict_network and conflict_network ~= "" then
		return rpc_error(ERR_SUBNET_CONFLICT, "conflict with " .. tostring(conflict_network))
	end
	return rpc_error(ERR_SUBNET_CONFLICT, "subnet conflict")
end

local function check_subnet_conflict(c, gateway, netmask, exclude_network)
	if not gateway or not netmask then return false end
	for _, net in ipairs(get_all_subnet_networks(c)) do
		if net ~= exclude_network and c:get("network", net, "disabled") ~= "1" then
			local other_gw = c:get("network", net, "ipaddr")
			local other_nm = c:get("network", net, "netmask") or "255.255.255.0"
			if other_gw and other_gw ~= "" and network_overlap(gateway, netmask, other_gw, other_nm) then
				return true, net
			end
		end
	end

	local ok, ubus = pcall(require, "ubus")
	if ok then
		local conn = ubus.connect()
		if conn then
			for _, wan_iface in ipairs(build_wan_logical_interface_list(c)) do
				local status = conn:call("network.interface." .. wan_iface, "status", {}) or {}
				local addr = status["ipv4-address"] and status["ipv4-address"][1]
				if addr and addr.address then
					local wan_mask = prefix_to_netmask(addr.mask) or "255.255.255.0"
					if network_overlap(gateway, netmask, addr.address, wan_mask) then
						conn:close()
						return true, "wan"
					end
				end
			end
			conn:close()
		end
	end
	return false
end

local function rpc_dhcp_field_present(v)
	if v == nil then return false end
	if type(v) == "string" and v:match("^%s*$") then return false end
	return true
end

-- Parses a DHCP range from either dhcp_start_ip+dhcp_end_ip or
-- dhcp_start+dhcp_limit (mutually exclusive). Returns nil, nil, nil when
-- no DHCP params were sent at all (caller keeps existing/default).
local function parse_dhcp_range_params(params, gateway, netmask)
	local has_ip_range = rpc_dhcp_field_present(params.dhcp_start_ip) or rpc_dhcp_field_present(params.dhcp_end_ip)
	local has_offset_range = rpc_dhcp_field_present(params.dhcp_start) or rpc_dhcp_field_present(params.dhcp_limit)
	if has_ip_range and has_offset_range then
		return nil, nil, "cannot mix dhcp_start_ip/dhcp_end_ip with dhcp_start/dhcp_limit"
	end
	if not (has_ip_range or has_offset_range) then return nil, nil, nil end
	if not gateway or not validate_gateway(gateway) then
		return nil, nil, "interface IP (gateway) required for DHCP pool"
	end

	if has_ip_range then
		if not (params.dhcp_start_ip and params.dhcp_end_ip) then
			return nil, nil, "both dhcp_start_ip and dhcp_end_ip are required"
		end
		local start = ip_to_dhcp_offset(params.dhcp_start_ip, gateway, netmask)
		local end_off = ip_to_dhcp_offset(params.dhcp_end_ip, gateway, netmask)
		if not start or not end_off or end_off < start then
			return nil, nil, "invalid dhcp range"
		end
		return start, end_off - start + 1, nil
	end

	local start = tonumber(params.dhcp_start)
	local limit = tonumber(params.dhcp_limit)
	if not start or not limit or start < 1 or limit < 1 then
		return nil, nil, "invalid dhcp_start or dhcp_limit"
	end
	return math.floor(start), math.floor(limit), nil
end

local function find_dhcp_section(c, network)
	if c:get("dhcp", network) then return network end
	local found = nil
	c:foreach("dhcp", "dhcp", function(s)
		if s.interface == network then found = s[".name"] end
	end)
	return found
end

-- DNS (option 6) / gateway (option 3) / LPR (option 9) live in dhcp's
-- dhcp_option list, same encoding GL's own lan.get_dhcp_option uses.
local function get_dhcp_options(c, network)
	local dhcp_sid = find_dhcp_section(c, network)
	if not dhcp_sid then return {}, {}, "" end
	local dns, lpr, dhcp_gateway = {}, {}, ""
	local opts = c:get("dhcp", dhcp_sid, "dhcp_option") or {}
	if type(opts) == "string" then opts = { opts } end
	for _, v in ipairs(opts) do
		local gw = v:match("^3,(.+)$")
		if gw then dhcp_gateway = gw end
		local dns_str = v:match("^6,(.+)$")
		if dns_str then for addr in dns_str:gmatch("[^,]+") do dns[#dns + 1] = addr end end
	end
	local force = c:get("dhcp", dhcp_sid, "dhcp_option_force") or {}
	if type(force) == "string" then force = { force } end
	for _, v in ipairs(force) do
		local lpr_str = v:match("^9,(.+)$")
		if lpr_str then for addr in lpr_str:gmatch("[^,]+") do lpr[#lpr + 1] = addr end end
	end
	return dns, lpr, dhcp_gateway
end

local function set_dhcp_option_list(c, dhcp_sid, option_field, prefix, value)
	local existing = c:get("dhcp", dhcp_sid, option_field) or {}
	if type(existing) == "string" then existing = { existing } end
	local kept = {}
	for _, v in ipairs(existing) do
		if not v:match("^" .. prefix .. ",") then kept[#kept + 1] = v end
	end
	if value and value ~= "" then kept[#kept + 1] = prefix .. "," .. value end
	if #kept > 0 then
		c:set("dhcp", dhcp_sid, option_field, kept)
	else
		c:delete("dhcp", dhcp_sid, option_field)
	end
end

-- Writes/updates a subnet's DHCP config; creates the section if missing.
-- cfg fields left nil are not touched (dns/lpr/dhcp_gateway included).
local function set_dhcp_config(c, network, cfg)
	local dhcp_sid = find_dhcp_section(c, network)
	if not dhcp_sid then
		c:set("dhcp", network, "dhcp")
		c:set("dhcp", network, "interface", network)
		dhcp_sid = network
	end
	if cfg.dhcp_enable ~= nil then
		if cfg.dhcp_enable then c:delete("dhcp", dhcp_sid, "ignore") else c:set("dhcp", dhcp_sid, "ignore", "1") end
	end
	if cfg.dhcp_start ~= nil then c:set("dhcp", dhcp_sid, "start", tostring(cfg.dhcp_start)) end
	if cfg.dhcp_limit ~= nil then c:set("dhcp", dhcp_sid, "limit", tostring(cfg.dhcp_limit)) end
	if cfg.leasetime ~= nil then c:set("dhcp", dhcp_sid, "leasetime", cfg.leasetime) end
	if cfg.dhcp_gateway ~= nil then set_dhcp_option_list(c, dhcp_sid, "dhcp_option", "3", cfg.dhcp_gateway) end
	if cfg.dns ~= nil then
		if type(cfg.dns) ~= "table" then return "invalid dns" end
		local valid = {}
		for _, addr in ipairs(cfg.dns) do
			if type(addr) == "string" and addr ~= "" then
				if not ip_to_number(addr) then return "invalid dns" end
				valid[#valid + 1] = addr
			end
		end
		set_dhcp_option_list(c, dhcp_sid, "dhcp_option", "6", #valid > 0 and table.concat(valid, ",") or nil)
	end
	if cfg.lpr ~= nil then
		if type(cfg.lpr) ~= "table" then return "invalid lpr" end
		local valid = {}
		for _, addr in ipairs(cfg.lpr) do
			if type(addr) == "string" and addr ~= "" then
				if not ip_to_number(addr) then return "invalid lpr" end
				valid[#valid + 1] = addr
			end
		end
		set_dhcp_option_list(c, dhcp_sid, "dhcp_option_force", "9", #valid > 0 and table.concat(valid, ",") or nil)
	end
	return nil
end

local function normalize_leasetime(val)
	if val == nil then return nil end
	if type(val) == "string" and val:match("^%d+[smhd]$") then return val end
	local num = tonumber(val)
	if not num or num <= 0 then return "12h" end
	if num >= 60 and num % 60 == 0 then return tostring(num / 60) .. "h" end
	return tostring(num) .. "m"
end

-- --- wired/wifi iface reporting (XE3000-specific; see file header) ------

local function get_wired_link_state(ifname)
	local f = io.open("/sys/class/net/" .. ifname .. "/operstate", "r")
	if not f then return "down" end
	local state = f:read("*l")
	f:close()
	return state == "up" and "up" or "down"
end

local function bridge_has_wired_port(bridge)
	if not bridge then return false end
	local f = io.popen("ls /sys/class/net/" .. bridge .. "/brif 2>/dev/null")
	if not f then return false end
	local found = nil
	for name in f:lines() do
		if name:match("^eth1") then found = name end
	end
	f:close()
	return found
end

local function get_bridge_for(network)
	if network == "lan" then return "br-lan" end
	if network == "guest" then return "br-guest" end
	if network == "iot" then return "br-iot" end
	local vid = vlan_id_of(network)
	return vid and ("br-vlan" .. vid) or nil
end

-- ifaces shape ({name, conn_type, state[, port_group]}) matches GL's real
-- API exactly; port_group is omitted since this hardware has no port
-- groups (single LAN trunk, no switch chip).
local function get_ifaces(c, network)
	local ifaces = {}
	local bridge = get_bridge_for(network)
	local wired_port = bridge_has_wired_port(bridge)
	if wired_port then
		ifaces[#ifaces + 1] = {
			name = network == "lan" and "LAN" or ("LAN (VLAN " .. tostring(get_vlan_id_for_network(c, network)) .. ")"),
			conn_type = "wired",
			state = get_wired_link_state(wired_port),
		}
	end
	local has_wifi, any_enabled = false, false
	c:foreach("wireless", "wifi-iface", function(s)
		if s.network == network then
			has_wifi = true
			if s.disabled ~= "1" then any_enabled = true end
		end
	end)
	if has_wifi then
		local wifi_name = network == "lan" and "Main" or (network:sub(1, 1):upper() .. network:sub(2))
		ifaces[#ifaces + 1] = {
			name = wifi_name,
			conn_type = "wifi",
			state = any_enabled and "up" or "down",
		}
	end
	return ifaces
end

-- --- isolate / wan_access_mode (simplified real implementations) --------
--
-- GL's real versions go through a whole separate gl-black_white_list UCI
-- config + firewall rule generator this build doesn't have. These do the
-- same job with plain UCI/firewall primitives already used elsewhere in
-- this port:
--   isolate         -> hostapd client isolation on the subnet's wifi-ifaces
--   wan_access_mode -> 0 full access (default forwarding to wan),
--                      1 block private WAN destinations (extra reject rule
--                        ahead of the forwarding rule),
--                      2 fully cut off (remove the forwarding-to-wan rule)

local function get_isolate_state(c, network)
	local isolated = false
	c:foreach("wireless", "wifi-iface", function(s)
		if s.network == network and s.isolate == "1" then isolated = true end
	end)
	return isolated
end

local function set_isolate_state(c, network, isolate)
	c:foreach("wireless", "wifi-iface", function(s)
		if s.network == network then
			if isolate then c:set("wireless", s[".name"], "isolate", "1")
			else c:delete("wireless", s[".name"], "isolate") end
		end
	end)
end

-- Finds an existing forwarding/rule section matching src==network by
-- content rather than by name: the "to wan" forwarding for lan/guest/iot
-- already exists as an anonymous @forwarding[N] section from board setup
-- (not one this file created), so managing this by assumed section name
-- would misdetect/orphan those.
local function find_section_by_src(c, section_type, network, dest)
	local found = nil
	c:foreach("firewall", section_type, function(s)
		if not found and s.src == network and (dest == nil or s.dest == dest) then
			found = s[".name"]
		end
	end)
	return found
end

local function get_wan_access_mode_state(c, network)
	if network == "lan" then return 0 end
	if find_section_by_src(c, "rule", network, "wan") then return 1 end
	if not find_section_by_src(c, "forwarding", network, "wan") then return 2 end
	return 0
end

local function set_wan_access_mode(c, network, mode)
	mode = mode or 0
	local block_id = find_section_by_src(c, "rule", network, "wan") or ("gl_" .. network .. "_block_private")
	local fwd_id = find_section_by_src(c, "forwarding", network, "wan") or ("gl_" .. network .. "_to_wan")

	if mode == 2 then
		c:delete("firewall", fwd_id)
		c:delete("firewall", block_id)
		return
	end

	c:set("firewall", fwd_id, "forwarding")
	c:set("firewall", fwd_id, "src", network)
	c:set("firewall", fwd_id, "dest", "wan")

	if mode == 1 then
		c:set("firewall", block_id, "rule")
		c:set("firewall", block_id, "name", "Block-" .. network .. "-private-wan")
		c:set("firewall", block_id, "src", network)
		c:set("firewall", block_id, "dest", "wan")
		c:set("firewall", block_id, "dest_ip", { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16" })
		c:set("firewall", block_id, "target", "REJECT")
	else
		c:delete("firewall", block_id)
	end
end

-- --- subnet_info: the get_subnets() row shape, field-for-field matching
-- GL's real get_subnet_info (name, ip, gateway/option-3, dhcp_start/limit
-- AND dhcp_start_ip/end_ip together, wan_access_mode, isolate, dns, lpr,
-- ifaces - not the "gateway"/"dhcp"-nested shape an earlier version of
-- this file made up).

local function get_subnet_info(c, network)
	local raw_ip = c:get("network", network, "ipaddr")
	if type(raw_ip) == "table" then raw_ip = raw_ip[1] end
	local ip, cidr_prefix = "", nil
	if type(raw_ip) == "string" then
		local bare, prefix = raw_ip:match("^([^/]+)/?(%d*)$")
		ip = bare or raw_ip
		cidr_prefix = prefix ~= "" and prefix or nil
	end
	local netmask = c:get("network", network, "netmask")
		or (cidr_prefix and prefix_to_netmask(cidr_prefix)) or "255.255.255.0"
	local display_name = get_display_name(c, network)
	local vlan_id = get_vlan_id_for_network(c, network) or 0

	local enabled = network == "lan" or c:get("network", network, "disabled") ~= "1"

	local dhcp_sid = find_dhcp_section(c, network)
	local dhcp_enable, dhcp_start, dhcp_limit, leasetime = true, 100, 150, "12h"
	local dns, lpr, dhcp_gateway = {}, {}, ""
	if dhcp_sid then
		dhcp_enable = c:get("dhcp", dhcp_sid, "ignore") ~= "1"
		dhcp_start = tonumber((c:get("dhcp", dhcp_sid, "start"))) or 100
		dhcp_limit = tonumber((c:get("dhcp", dhcp_sid, "limit"))) or 150
		leasetime = c:get("dhcp", dhcp_sid, "leasetime") or "12h"
		dns, lpr, dhcp_gateway = get_dhcp_options(c, network)
	end
	local dhcp_start_ip, dhcp_end_ip
	if ip ~= "" then
		dhcp_start_ip, dhcp_end_ip = dhcp_offset_to_ips(ip, netmask, dhcp_start, dhcp_limit)
	end

	return {
		display_name = display_name,
		name = display_name,
		network = network,
		enabled = enabled,
		vlan_id = vlan_id,
		ip = ip,
		gateway = dhcp_gateway,
		netmask = netmask,
		dhcp_enable = dhcp_enable,
		dhcp_start_ip = dhcp_start_ip,
		dhcp_end_ip = dhcp_end_ip,
		dhcp_start = dhcp_start,
		dhcp_limit = dhcp_limit,
		leasetime = leasetime,
		wan_access_mode = get_wan_access_mode_state(c, network),
		isolate = get_isolate_state(c, network),
		dns = as_array(dns),
		lpr = as_array(lpr),
		ifaces = as_array(get_ifaces(c, network)),
	}
end

-- --- static bind (address reservation) helpers ---------------------------

local function validate_static_bind_name(name)
	if name == nil then return true end
	if type(name) ~= "string" or #name > 256 then return false end
	return not (name:find('"', 1, true) or name:find(",", 1, true))
end

local function validate_static_bind_hostname(hostname)
	if hostname == nil or hostname == "" then return true end
	if type(hostname) ~= "string" or #hostname > 63 then return false end
	if hostname:match("^%d+$") then return false end
	return hostname:match("^[a-zA-Z0-9][a-zA-Z0-9%-]*[a-zA-Z0-9]$") ~= nil
end

local function resolve_network_by_ip(c, ip)
	local ip_n = ip_to_number(ip)
	if not ip_n then return nil end
	local matched, count = nil, 0
	for _, net in ipairs(get_all_subnet_networks(c)) do
		local gw = c:get("network", net, "ipaddr")
		local nm = c:get("network", net, "netmask") or "255.255.255.0"
		if type(gw) == "table" then gw = gw[1] end
		if type(gw) == "string" then gw = gw:match("^([^/]+)") end
		local gw_n, nm_n = gw and ip_to_number(gw), ip_to_number(nm)
		if gw_n and nm_n and band32(gw_n, nm_n) == band32(ip_n, nm_n) then
			matched, count = net, count + 1
		end
	end
	return count == 1 and matched or nil
end

-- --- RPC methods -----------------------------------------------------------

local M = {}

M.get_subnets = function(args)
	local c = uci.cursor()
	local subnets = {}
	for _, n in ipairs(FIXED_SUBNETS) do
		if c:get("network", n) then subnets[#subnets + 1] = get_subnet_info(c, n) end
	end
	for _, n in ipairs(get_all_custom_networks(c)) do
		subnets[#subnets + 1] = get_subnet_info(c, n)
	end
	return { subnets = as_array(subnets) }
end

M.list_all = function(args)
	local c = uci.cursor()
	local list = {}
	for _, n in ipairs(get_all_subnet_networks(c)) do
		list[#list + 1] = { display_name = get_display_name(c, n), vlan_id = get_vlan_id_for_network(c, n) or 0 }
	end
	return as_array(list)
end

M.vlan_id_exists = function(args)
	local vlan_id = tonumber(args.vlan_id)
	if not vlan_id then return false end
	local c = uci.cursor()
	return check_vlan_id_conflict(c, vlan_id)
end

M.set_fixed_subnet = function(args)
	local display_name = args.display_name or args.name
	local network = NETWORK_MAP[display_name]
	if not network then
		return rpc_error(ERR_INVALID_PARAMS, "invalid display_name")
	end
	local c = uci.cursor()
	if not c:get("network", network) then
		return rpc_error(ERR_SUBNET_NOT_FOUND, network .. " network is not configured")
	end

	local current = get_subnet_info(c, network)
	local new_ip = rpc_dhcp_field_present(args.ip) and args.ip or current.ip
	local new_netmask = args.netmask or current.netmask

	if args.ip ~= nil or args.netmask ~= nil then
		if new_ip ~= "" and not validate_gateway(new_ip) then
			return rpc_error(ERR_INVALID_PARAMS, "ip must be a private IPv4 address")
		end
		if not validate_netmask(new_netmask) then
			return rpc_error(ERR_INVALID_PARAMS, "invalid netmask")
		end
		if new_ip ~= "" then
			local conflict, with = check_subnet_conflict(c, new_ip, new_netmask, network)
			if conflict then return subnet_conflict_rpc_error(c, with) end
		end
		if args.ip ~= nil then
			c:delete("network", network, "ipaddr")
			if new_ip ~= "" then c:set("network", network, "ipaddr", new_ip) end
		end
		if args.netmask then c:set("network", network, "netmask", args.netmask) end
	end

	if args.display_name and args.display_name ~= display_name then
		if display_name_exists(c, args.display_name, network) then
			return rpc_error(ERR_DISPLAY_NAME_CONFLICT, "display_name conflict")
		end
		c:set("network", network, "display_name", args.display_name)
	end

	-- lan can never be disabled - that would strand the router's own
	-- management access.
	if args.enabled ~= nil and network ~= "lan" then
		c:set("network", network, "disabled", args.enabled and "0" or "1")
	end
	c:commit("network")

	if args.wan_access_mode ~= nil then set_wan_access_mode(c, network, tonumber(args.wan_access_mode)) end
	local isolate_req = args.isolate
	if isolate_req == nil then isolate_req = args.ap_isolate end
	if isolate_req ~= nil then set_isolate_state(c, network, isolate_req == true) end
	c:commit("firewall")
	c:commit("wireless")

	local gw_for_dhcp = new_ip ~= "" and new_ip or current.ip
	local parsed_start, parsed_limit, parsed_err = parse_dhcp_range_params(args, gw_for_dhcp, new_netmask)
	if parsed_err then return rpc_error(ERR_DHCP_INVALID, parsed_err) end
	local dhcp_err = set_dhcp_config(c, network, {
		dhcp_enable = args.dhcp_enable,
		dhcp_start = parsed_start,
		dhcp_limit = parsed_limit,
		leasetime = normalize_leasetime(args.leasetime),
		dns = args.dns,
		lpr = args.lpr,
	})
	if dhcp_err then return rpc_error(ERR_INVALID_PARAMS, dhcp_err) end
	c:commit("dhcp")

	os.execute("/etc/init.d/network reload >/dev/null 2>&1")
	os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
	os.execute("wifi reload >/dev/null 2>&1")
	return {}
end

M.add_custom_subnet = function(args)
	local c = uci.cursor()
	if count_custom_subnets(c) >= MAX_CUSTOM_SUBNETS then
		return rpc_error(ERR_SUBNET_LIMIT_EXCEEDED, "max " .. MAX_CUSTOM_SUBNETS .. " custom subnets")
	end

	local vlan_id = tonumber(args.vlan_id)
	if not vlan_id or not check_vlan_id_range(vlan_id) then
		return rpc_error(ERR_VLAN_ID_OUT_OF_RANGE, "vlan_id must be " .. VLAN_ID_MIN .. "-" .. VLAN_ID_MAX)
	end
	if check_vlan_id_conflict(c, vlan_id) then
		return rpc_error(ERR_VLAN_ID_CONFLICT, "vlan_id conflict")
	end

	if rpc_dhcp_field_present(args.ip) and rpc_dhcp_field_present(args.gateway) and args.ip ~= args.gateway then
		return rpc_error(ERR_INVALID_PARAMS, "ip and gateway conflict for interface address")
	end
	local iface_ip = rpc_dhcp_field_present(args.ip) and args.ip
		or rpc_dhcp_field_present(args.gateway) and args.gateway or nil
	local has_l3 = iface_ip ~= nil
	if has_l3 and not validate_gateway(iface_ip) then
		return rpc_error(ERR_INVALID_PARAMS, "invalid ip or gateway")
	end
	if not has_l3 and args.dhcp_enable == true then
		return rpc_error(ERR_DHCP_INVALID, "DHCP requires interface IP (gateway)")
	end

	local netmask = args.netmask or "255.255.255.0"
	if has_l3 and not validate_netmask(netmask) then
		return rpc_error(ERR_INVALID_PARAMS, "invalid netmask")
	end

	local network = "vlan" .. vlan_id
	if has_l3 then
		local conflict, with = check_subnet_conflict(c, iface_ip, netmask, network)
		if conflict then return subnet_conflict_rpc_error(c, with) end
	end

	local display_name = args.display_name or args.name or network
	if #tostring(display_name) > 32 then
		return rpc_error(ERR_INVALID_PARAMS, "display_name length must be less than 32")
	end
	if display_name_exists(c, display_name) then
		return rpc_error(ERR_DISPLAY_NAME_CONFLICT, "display_name conflict")
	end

	local dhcp_start, dhcp_limit = 100, 150
	if args.dhcp_enable ~= false then
		local parsed_start, parsed_limit, parsed_err = parse_dhcp_range_params(args, has_l3 and iface_ip or "", netmask)
		if parsed_err then return rpc_error(ERR_DHCP_INVALID, parsed_err) end
		if parsed_start and parsed_limit then dhcp_start, dhcp_limit = parsed_start, parsed_limit end
	end
	local leasetime = normalize_leasetime(args.leasetime) or "12h"

	-- UCI section identifiers can't contain "." or "-" (confirmed live:
	-- `c:set("network", "eth1.999", "device")` returns ok with no error
	-- but silently writes nothing - libuci rejects the section name and
	-- the Lua binding doesn't surface it). The actual device name
	-- ("eth1.999"/"br-vlan999", what netifd and `ip link` see) goes in
	-- the "name" *option* instead, which has no such restriction.
	local ethdev, bridge = "eth1." .. vlan_id, "br-vlan" .. vlan_id
	local ethdev_sid, bridge_sid = "vlan" .. vlan_id .. "_dev", "vlan" .. vlan_id .. "_br"
	c:set("network", ethdev_sid, "device")
	c:set("network", ethdev_sid, "name", ethdev)
	c:set("network", ethdev_sid, "type", "8021q")
	c:set("network", ethdev_sid, "ifname", "eth1")
	c:set("network", ethdev_sid, "vid", tostring(vlan_id))
	c:set("network", bridge_sid, "device")
	c:set("network", bridge_sid, "name", bridge)
	c:set("network", bridge_sid, "type", "bridge")
	c:set("network", bridge_sid, "ports", { ethdev })

	c:set("network", network, "interface")
	c:set("network", network, "device", bridge)
	if has_l3 then
		c:set("network", network, "proto", "static")
		c:set("network", network, "ipaddr", iface_ip)
		c:set("network", network, "netmask", netmask)
	else
		c:set("network", network, "proto", "none")
	end
	c:set("network", network, "display_name", display_name)
	if args.enabled == false then c:set("network", network, "disabled", "1") end
	c:commit("network")

	local dhcp_err = set_dhcp_config(c, network, {
		dhcp_enable = has_l3 and (args.dhcp_enable ~= false) or false,
		dhcp_start = dhcp_start, dhcp_limit = dhcp_limit,
		leasetime = leasetime, dns = args.dns, lpr = args.lpr,
	})
	if dhcp_err then return rpc_error(ERR_INVALID_PARAMS, dhcp_err) end
	c:commit("dhcp")

	set_wan_access_mode(c, network, tonumber(args.wan_access_mode) or 0)
	c:commit("firewall")

	local isolate_req = args.isolate
	if isolate_req == nil then isolate_req = args.ap_isolate end
	if isolate_req == true then set_isolate_state(c, network, true); c:commit("wireless") end

	os.execute("/etc/init.d/network reload >/dev/null 2>&1")
	os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
	return {}
end

M.update_custom_subnet = function(args)
	local c = uci.cursor()
	local network = resolve_display_name_to_network(c, args.name)
	if not network or not is_custom_name(network) then
		return rpc_error(ERR_SUBNET_NOT_FOUND, "subnet not found")
	end
	if args.vlan_id ~= nil and tonumber(args.vlan_id) ~= vlan_id_of(network) then
		-- Real GL re-creates the subnet under the new VLAN ID; changing
		-- the trunk tag/bridge/network name live is high-risk to do
		-- blind on someone's working router, so this is refused for now
		-- rather than attempted - remove and re-add instead.
		return rpc_error(ERR_INVALID_PARAMS, "changing vlan_id is not supported yet - remove and re-add the subnet")
	end

	local current = get_subnet_info(c, network)
	local new_ip = rpc_dhcp_field_present(args.ip) and args.ip
		or rpc_dhcp_field_present(args.gateway) and args.gateway or current.ip
	local new_netmask = args.netmask or current.netmask
	if args.ip ~= nil or args.gateway ~= nil or args.netmask ~= nil then
		if new_ip ~= "" and not validate_gateway(new_ip) then
			return rpc_error(ERR_INVALID_PARAMS, "invalid ip or gateway")
		end
		if new_ip ~= "" and not validate_netmask(new_netmask) then
			return rpc_error(ERR_INVALID_PARAMS, "invalid netmask")
		end
		if new_ip ~= "" then
			local conflict, with = check_subnet_conflict(c, new_ip, new_netmask, network)
			if conflict then return subnet_conflict_rpc_error(c, with) end
		end
		if new_ip == "" then
			c:set("network", network, "proto", "none")
			c:delete("network", network, "ipaddr")
			c:delete("network", network, "netmask")
		else
			c:set("network", network, "proto", "static")
			c:set("network", network, "ipaddr", new_ip)
			c:set("network", network, "netmask", new_netmask)
		end
	end

	if args.display_name and args.display_name ~= current.display_name then
		if display_name_exists(c, args.display_name, network) then
			return rpc_error(ERR_DISPLAY_NAME_CONFLICT, "display_name conflict")
		end
		c:set("network", network, "display_name", args.display_name)
	end
	if args.enabled ~= nil then
		c:set("network", network, "disabled", args.enabled and "0" or "1")
	end
	c:commit("network")

	if args.wan_access_mode ~= nil then set_wan_access_mode(c, network, tonumber(args.wan_access_mode)) end
	c:commit("firewall")
	local isolate_req = args.isolate
	if isolate_req == nil then isolate_req = args.ap_isolate end
	if isolate_req ~= nil then set_isolate_state(c, network, isolate_req == true); c:commit("wireless") end

	local parsed_start, parsed_limit, parsed_err = parse_dhcp_range_params(args, new_ip, new_netmask)
	if parsed_err then return rpc_error(ERR_DHCP_INVALID, parsed_err) end
	local dhcp_err = set_dhcp_config(c, network, {
		dhcp_enable = args.dhcp_enable,
		dhcp_start = parsed_start, dhcp_limit = parsed_limit,
		leasetime = normalize_leasetime(args.leasetime),
		dns = args.dns, lpr = args.lpr,
	})
	if dhcp_err then return rpc_error(ERR_INVALID_PARAMS, dhcp_err) end
	c:commit("dhcp")

	os.execute("/etc/init.d/network reload >/dev/null 2>&1")
	os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
	return {}
end

M.remove_custom_subnet = function(args)
	if not args.name then return rpc_error(ERR_INVALID_PARAMS, "name required") end
	local c = uci.cursor()
	local network = resolve_display_name_to_network(c, args.name)
	if not network then return rpc_error(ERR_SUBNET_NOT_FOUND, "subnet not found") end
	if is_fixed_subnet(network) then
		return rpc_error(ERR_DELETE_FIXED_SUBNET, "fixed subnet cannot be deleted")
	end

	local vlan_id = vlan_id_of(network)
	local ethdev = "eth1." .. vlan_id
	local ethdev_sid, bridge_sid = "vlan" .. vlan_id .. "_dev", "vlan" .. vlan_id .. "_br"
	local fwd_id, block_id = "gl_" .. network .. "_to_wan", "gl_" .. network .. "_block_private"

	c:delete("network", network)
	c:delete("network", bridge_sid)
	c:delete("network", ethdev_sid)
	c:commit("network")
	c:delete("dhcp", network)
	c:commit("dhcp")
	c:delete("firewall", fwd_id)
	c:delete("firewall", block_id)
	c:commit("firewall")

	os.execute("ip link del " .. ethdev .. " >/dev/null 2>&1")
	os.execute("/etc/init.d/network reload >/dev/null 2>&1")
	os.execute("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
	return {}
end

M.add_static_bind = function(args)
	local c = uci.cursor()
	local mac, ip = args.mac, args.ip
	local one_click = args.one_click
	local hostname_raw = args.hostname
	if hostname_raw == nil then hostname_raw = args.host_name end
	local hostname_present = hostname_raw ~= nil
	local input_hostname = hostname_present and hostname_raw or ""
	local name = args.name or ""

	if type(mac) ~= "string" or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return rpc_error(ERR_INVALID_PARAMS, "invalid mac")
	end
	if type(ip) ~= "string" or not ip_to_number(ip) then
		return rpc_error(ERR_INVALID_PARAMS, "invalid ip")
	end
	if not validate_static_bind_name(name) then
		return rpc_error(ERR_INVALID_PARAMS, "invalid name")
	end
	if not one_click and hostname_present and not validate_static_bind_hostname(input_hostname) then
		return rpc_error(ERR_INVALID_PARAMS, "invalid hostname")
	end
	mac = mac:upper()

	local network
	if args.display_name and args.display_name ~= "" then
		network = resolve_display_name_to_network(c, args.display_name)
	else
		network = resolve_network_by_ip(c, ip)
	end
	if not network then
		return rpc_error(ERR_STATIC_BIND_SUBNET_SELECTOR, "invalid or missing subnet selector")
	end

	local gw = c:get("network", network, "ipaddr")
	local nm = c:get("network", network, "netmask")
	if type(gw) == "table" then gw = gw[1] end
	if type(gw) == "string" then gw = gw:match("^([^/]+)") end
	if gw and nm then
		local gw_n, nm_n, ip_n = ip_to_number(gw), ip_to_number(nm), ip_to_number(ip)
		if gw_n and nm_n and ip_n then
			if band32(gw_n, nm_n) ~= band32(ip_n, nm_n) then
				return rpc_error(ERR_STATIC_BIND_IP_NOT_IN_SUBNET, "IP not in subnet")
			end
			if ip_n == gw_n then
				return rpc_error(ERR_STATIC_BIND_GATEWAY_IP, "cannot bind gateway IP")
			end
		end
	end

	local old_hostname, conflict, conflict_mac, to_delete = nil, false, "", {}
	c:foreach("dhcp", "host", function(s)
		if type(s.mac) == "table" then return end
		local s_mac = type(s.mac) == "string" and s.mac:upper() or nil
		if s_mac == mac then
			old_hostname = old_hostname or s.name
			to_delete[#to_delete + 1] = s[".name"]
		elseif s.ip == ip and (s.network or "lan") == network then
			old_hostname = old_hostname or s.name
			to_delete[#to_delete + 1] = s[".name"]
		end
		if not one_click and hostname_present and input_hostname ~= "" and s.name == input_hostname then
			conflict, conflict_mac = true, s_mac or ""
		end
	end)
	if not one_click and hostname_present and input_hostname ~= "" and conflict and conflict_mac ~= mac then
		return rpc_error(ERR_INVALID_PARAMS, "hostname already exists")
	end
	for _, sid in ipairs(to_delete) do c:delete("dhcp", sid) end

	local sid = c:add("dhcp", "host")
	c:set("dhcp", sid, "mac", mac)
	c:set("dhcp", sid, "ip", ip)
	c:set("dhcp", sid, "network", network)
	if name ~= "" then c:set("dhcp", sid, "tag", name) end
	if not one_click then
		local final_hostname = hostname_present and (input_hostname ~= "" and input_hostname or nil) or old_hostname
		if final_hostname and final_hostname ~= "" then c:set("dhcp", sid, "name", final_hostname) end
	end
	c:commit("dhcp")
	os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	return {}
end

M.set_static_bind = function(args) return M.add_static_bind(args) end

M.get_static_bind_list = function(args)
	args = args or {}
	local c = uci.cursor()
	local filter_net = args.display_name and resolve_display_name_to_network(c, args.display_name) or nil
	local res = {}
	c:foreach("dhcp", "host", function(s)
		if type(s.mac) == "table" or type(s.tag) == "table" then return end
		local host_net = s.network or "lan"
		if filter_net and host_net ~= filter_net then return end
		res[#res + 1] = {
			mac = s.mac,
			ip = s.ip,
			name = (s.tag and s.tag ~= "") and s.tag or nil,
			hostname = (s.name and s.name ~= "") and s.name or nil,
			display_name = get_display_name(c, host_net),
		}
	end)
	return { static_bind_list = as_array(res) }
end

M.remove_static_bind = function(args)
	local c = uci.cursor()
	local mode = args.mode
	if mode ~= 0 and mode ~= 1 then
		return rpc_error(ERR_INVALID_PARAMS, "mode must be 0 or 1")
	end
	local to_delete = {}
	if mode == 0 then
		local mac = args.mac
		if type(mac) ~= "string" or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
			return rpc_error(ERR_INVALID_PARAMS, "invalid mac")
		end
		mac = mac:upper()
		c:foreach("dhcp", "host", function(s)
			if type(s.mac) == "string" and s.mac:upper() == mac then to_delete[#to_delete + 1] = s[".name"] end
		end)
	else
		local filter_net = args.display_name and resolve_display_name_to_network(c, args.display_name) or nil
		c:foreach("dhcp", "host", function(s)
			if type(s.mac) == "table" or type(s.tag) == "table" then return end
			local host_net = s.network or "lan"
			if filter_net and host_net ~= filter_net then return end
			to_delete[#to_delete + 1] = s[".name"]
		end)
	end
	for _, sid in ipairs(to_delete) do c:delete("dhcp", sid) end
	c:commit("dhcp")
	os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	return {}
end

-- Simple ipcalc: network address, broadcast, prefix length - the fields
-- GL's real "oui.network".ipcalc() returns that this feature actually
-- reads (NETWORK/PREFIX/BROADCAST).
local function ipcalc(cidr)
	local ip, prefix = cidr:match("^([^/]+)/(%d+)$")
	local ip_n, prefix_n = ip and ip_to_number(ip), tonumber(prefix)
	if not ip_n or not prefix_n then return {} end
	local mask = prefix_to_netmask(prefix_n)
	local mask_n = ip_to_number(mask)
	local net_n = band32(ip_n, mask_n)
	local bcast_n = to_u32(bit.bor(net_n, to_u32(bit.bnot(mask_n))))
	return { NETWORK = number_to_ip(net_n), PREFIX = tostring(prefix_n), BROADCAST = number_to_ip(bcast_n) }
end

M.get_wan_info = function(args)
	local ok, ubus = pcall(require, "ubus")
	if not ok then return rpc_error(ERR_NO_VIRTUAL_WAN, "this device doesn't have the virtual WAN port") end
	local conn = ubus.connect()
	if not conn then return rpc_error(ERR_NO_VIRTUAL_WAN, "this device doesn't have the virtual WAN port") end

	local c = uci.cursor()
	local wan_info = {}
	for _, iface in ipairs(build_wan_logical_interface_list(c)) do
		local status = conn:call("network.interface." .. iface, "status", {}) or {}
		local addr = status["ipv4-address"] and status["ipv4-address"][1]
		if addr and addr.address and addr.mask then
			wan_info[#wan_info + 1] = { interface = iface, info = ipcalc(addr.address .. "/" .. addr.mask) }
		end
	end
	conn:close()
	if #wan_info == 0 then
		return rpc_error(ERR_NO_VIRTUAL_WAN, "this device doesn't have the virtual WAN port")
	end
	return { wan_info = as_array(wan_info) }
end

return M
