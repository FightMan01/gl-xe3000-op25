-- "dpi" RPC object: despite the name, everything implemented here is
-- packet-content-inspection-free -
--   get_qos/set_qos - per-client (MAC) 3-tier priority bandwidth QoS
--   get_content_protection/set_content_protection - domain/IP blocklist
--   get_apps/get_dpi_stats - honest empty data (see below)
-- Real GL firmware's "dpi" object also does app-signature-based
-- classification (get_apps' app catalog would normally list real
-- app/category signatures, dpifeatures.json's whole page) - that needs a
-- proprietary, downloadable signature database this port has no access
-- to. get_apps returns an empty catalog (nothing to pick, not a fake
-- one) and content_protection's own app_list/category_list fields are
-- accepted and stored for API round-trip fidelity but have no
-- enforcement effect, same reason - only its domain_list field (plain
-- domains and IP/CIDR entries) is real, DNS/firewall-blockable content.
-- The dpifeatures page itself stays hidden via menu.d.

local cjson = require "cjson"
local uci = require "uci"

local QOS_CONFIG = "gl_qos"
local CP_CONFIG = "gl_contentprotection"
local IFB = "ifb-qos"
local LAN_IFACE = "br-lan"

local function as_array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
end

local function is_mac(value)
	return type(value) == "string" and value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local CP_DNSMASQ_DIR = "/tmp/dnsmasq.d"
local CP_DNSMASQ_FILE = CP_DNSMASQ_DIR .. "/gl-contentprotection.conf"
local CP_RULE_PREFIX = "GL-ContentProtection "

local function is_cidr_or_ip(value)
	if type(value) ~= "string" then return false end
	if value:match("^%d+%.%d+%.%d+%.%d+$") then return true end
	if value:match("^%d+%.%d+%.%d+%.%d+/%d+$") then return true end
	return value:match("^[%x:]+:[%x:]*$") ~= nil
end

local function is_domain(value)
	return type(value) == "string" and value:match("^[%w][%w%.%-]*%.[%a][%a]+$") ~= nil
end

local function ensure_dnsmasq_confdir(cursor)
	local has_confdir = false
	cursor:foreach("dhcp", "dnsmasq", function(s)
		if s.confdir == CP_DNSMASQ_DIR then has_confdir = true end
	end)
	if not has_confdir then
		cursor:foreach("dhcp", "dnsmasq", function(s)
			cursor:set("dhcp", s[".name"], "confdir", CP_DNSMASQ_DIR)
		end)
		cursor:commit("dhcp")
	end
	os.execute("mkdir -p " .. CP_DNSMASQ_DIR)
end

local function apply_content_protection(cursor)
	cursor:foreach("firewall", "rule", function(s)
		if type(s.name) == "string" and s.name:sub(1, #CP_RULE_PREFIX) == CP_RULE_PREFIX then
			cursor:delete("firewall", s[".name"])
		end
	end)
	cursor:commit("firewall")

	local enabled = cursor:get(CP_CONFIG, "main", "enable") == "1"
	local domains = enabled and (cursor:get(CP_CONFIG, "main", "domains") or {}) or {}
	local ips = enabled and (cursor:get(CP_CONFIG, "main", "ips") or {}) or {}

	ensure_dnsmasq_confdir(cursor)
	local lines = {}
	for _, domain in ipairs(domains) do
		lines[#lines + 1] = "address=/" .. domain .. "/0.0.0.0"
		lines[#lines + 1] = "address=/" .. domain .. "/::"
	end
	local file = io.open(CP_DNSMASQ_FILE, "w")
	if file then
		file:write(table.concat(lines, "\n"))
		if #lines > 0 then file:write("\n") end
		file:close()
	end

	for i, ip in ipairs(ips) do
		local id = cursor:add("firewall", "rule")
		cursor:set("firewall", id, "name", CP_RULE_PREFIX .. i)
		cursor:set("firewall", id, "src", "lan")
		cursor:set("firewall", id, "dest", "wan")
		cursor:set("firewall", id, "dest_ip", ip)
		cursor:set("firewall", id, "target", "REJECT")
	end
	cursor:commit("firewall")

	os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
end

local function mac_list(cursor, config, option)
	local out = {}
	for _, mac in ipairs(cursor:get(config, "main", option) or {}) do
		out[#out + 1] = mac:upper()
	end
	return out
end

local function teardown_qos()
	command_ok("tc qdisc del dev " .. LAN_IFACE .. " root")
	command_ok("tc qdisc del dev " .. LAN_IFACE .. " ingress")
	command_ok("tc qdisc del dev " .. IFB .. " root")
	command_ok("ip link set " .. IFB .. " down")
	command_ok("ip link del " .. IFB)
end

-- One HTB tree per direction: 1:10/1:20/1:30 = high/middle/low, guaranteed
-- a 50/30/20 split of the configured rate but free to borrow up to the
-- full rate when the other classes are idle (standard HTB borrowing) -
-- default (untagged) traffic lands in the low class, so it never starves
-- the classified clients but also never blocks them.
local function build_htb(dev, rate_kbit, macs_by_class, match_field)
	local total = math.max(rate_kbit, 16)
	command_ok(string.format("tc qdisc add dev %s root handle 1: htb default 30", dev))
	command_ok(string.format("tc class add dev %s parent 1: classid 1:1 htb rate %dkbit ceil %dkbit",
		dev, total, total))
	local shares = { ["1:10"] = 0.5, ["1:20"] = 0.3, ["1:30"] = 0.2 }
	for classid, share in pairs(shares) do
		local guaranteed = math.max(math.floor(total * share), 8)
		command_ok(string.format(
			"tc class add dev %s parent 1:1 classid %s htb rate %dkbit ceil %dkbit",
			dev, classid, guaranteed, total))
		command_ok(string.format("tc qdisc add dev %s parent %s fq_codel", dev, classid))
	end
	local classid_by_tier = { high = "1:10", middle = "1:20", low = "1:30" }
	local priority = 1
	for _, tier in ipairs({ "high", "middle", "low" }) do
		for _, mac in ipairs(macs_by_class[tier] or {}) do
			command_ok(string.format(
				"tc filter add dev %s parent 1:0 protocol ip prio %d u32 match ether %s %s flowid %s",
				dev, priority, match_field, mac, classid_by_tier[tier]))
			priority = priority + 1
		end
	end
end

local function apply_qos(cursor)
	teardown_qos()
	local enabled = cursor:get(QOS_CONFIG, "main", "enable") == "1"
	if not enabled then return true end

	local upload_kbit = math.floor((tonumber((cursor:get(QOS_CONFIG, "main", "upload"))) or 0) * 1000)
	local download_kbit = math.floor((tonumber((cursor:get(QOS_CONFIG, "main", "download"))) or 0) * 1000)
	if upload_kbit <= 0 or download_kbit <= 0 then
		return false, "invalid bandwidth"
	end

	local macs_by_class = {
		high = mac_list(cursor, QOS_CONFIG, "high"),
		middle = mac_list(cursor, QOS_CONFIG, "middle"),
		low = mac_list(cursor, QOS_CONFIG, "low"),
	}

	-- Download: packets egressing br-lan toward LAN clients - classify by
	-- destination MAC.
	build_htb(LAN_IFACE, download_kbit, macs_by_class, "dst")

	-- Upload: br-lan has no classful ingress qdisc, so ingress traffic is
	-- mirrored to an ifb pseudo-device and shaped as if it were egress
	-- there - classify by source MAC (the LAN client sending it).
	if not command_ok("ip link show " .. IFB) then
		command_ok("modprobe ifb numifbs=1")
		command_ok("ip link add " .. IFB .. " type ifb")
	end
	command_ok("ip link set " .. IFB .. " up")
	command_ok(string.format("tc qdisc add dev %s ingress", LAN_IFACE))
	command_ok(string.format(
		"tc filter add dev %s parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev %s",
		LAN_IFACE, IFB))
	build_htb(IFB, upload_kbit, macs_by_class, "src")
	return true
end

return {
	get_qos = function()
		local cursor = uci.cursor()
		return {
			enable = cursor:get(QOS_CONFIG, "main", "enable") == "1",
			upload = tonumber((cursor:get(QOS_CONFIG, "main", "upload"))) or 0,
			download = tonumber((cursor:get(QOS_CONFIG, "main", "download"))) or 0,
			mode = cursor:get(QOS_CONFIG, "main", "mode") or "0",
			high = as_array(mac_list(cursor, QOS_CONFIG, "high")),
			middle = as_array(mac_list(cursor, QOS_CONFIG, "middle")),
			low = as_array(mac_list(cursor, QOS_CONFIG, "low")),
		}
	end,

	set_qos = function(args)
		args = args or {}
		if type(args.enable) ~= "boolean" then
			return { err_code = 1, err_msg = "enable must be boolean" }
		end
		local cursor = uci.cursor()
		if args.enable then
			local sqm_on = false
			cursor:foreach("sqm", "queue", function(s)
				if s.enabled == "1" then sqm_on = true end
			end)
			if sqm_on then
				return {
					err_code = 1,
					err_msg = "the simple SQM shaper is already enabled - disable it first",
				}
			end
		end

		cursor:set(QOS_CONFIG, "main", "settings")
		cursor:set(QOS_CONFIG, "main", "enable", args.enable and "1" or "0")
		if args.upload then cursor:set(QOS_CONFIG, "main", "upload", tostring(tonumber(args.upload) or 0)) end
		if args.download then cursor:set(QOS_CONFIG, "main", "download", tostring(tonumber(args.download) or 0)) end
		if args.mode then cursor:set(QOS_CONFIG, "main", "mode", tostring(args.mode)) end
		for _, tier in ipairs({ "high", "middle", "low" }) do
			if type(args[tier]) == "table" then
				local macs = {}
				for _, mac in ipairs(args[tier]) do
					if not is_mac(mac) then
						return { err_code = 1, err_msg = "invalid MAC address: " .. tostring(mac) }
					end
					macs[#macs + 1] = mac:upper()
				end
				if #macs > 0 then
					cursor:set(QOS_CONFIG, "main", tier, macs)
				else
					cursor:delete(QOS_CONFIG, "main", tier)
				end
			end
		end
		cursor:commit(QOS_CONFIG)

		local ok, err = apply_qos(cursor)
		if not ok then return { err_code = 1, err_msg = err } end
		return {}
	end,

	get_content_protection = function()
		local cursor = uci.cursor()
		local domains = cursor:get(CP_CONFIG, "main", "domains") or {}
		local ips = cursor:get(CP_CONFIG, "main", "ips") or {}
		local combined = {}
		for _, domain in ipairs(domains) do combined[#combined + 1] = domain end
		for _, ip in ipairs(ips) do combined[#combined + 1] = ip end
		local app_list = cursor:get(CP_CONFIG, "main", "app_list")
		local category_list = cursor:get(CP_CONFIG, "main", "category_list")
		return {
			enable = cursor:get(CP_CONFIG, "main", "enable") == "1",
			domain_list = as_array(combined),
			app_list = app_list and cjson.decode(app_list) or cjson.empty_array,
			category_list = category_list and cjson.decode(category_list) or cjson.empty_array,
			blacklist = as_array(cursor:get(CP_CONFIG, "main", "blacklist") or {}),
		}
	end,

	set_content_protection = function(args)
		args = args or {}
		if type(args.enable) ~= "boolean" then
			return { err_code = 1, err_msg = "enable must be boolean" }
		end
		local cursor = uci.cursor()
		cursor:set(CP_CONFIG, "main", "settings")
		cursor:set(CP_CONFIG, "main", "enable", args.enable and "1" or "0")

		local domains, ips = {}, {}
		if type(args.domain_list) == "table" then
			for _, entry in ipairs(args.domain_list) do
				entry = tostring(entry):match("^%s*(.-)%s*$")
				if is_domain(entry) then
					domains[#domains + 1] = entry:lower()
				elseif is_cidr_or_ip(entry) then
					ips[#ips + 1] = entry
				elseif entry ~= "" then
					return { err_code = 1, err_msg = "invalid entry: " .. entry }
				end
			end
		end
		if #domains > 0 then cursor:set(CP_CONFIG, "main", "domains", domains)
		else cursor:delete(CP_CONFIG, "main", "domains") end
		if #ips > 0 then cursor:set(CP_CONFIG, "main", "ips", ips)
		else cursor:delete(CP_CONFIG, "main", "ips") end

		-- app_list/category_list/blacklist round-trip only - see header.
		if args.app_list ~= nil then
			cursor:set(CP_CONFIG, "main", "app_list", cjson.encode(args.app_list))
		end
		if args.category_list ~= nil then
			cursor:set(CP_CONFIG, "main", "category_list", cjson.encode(args.category_list))
		end
		if type(args.blacklist) == "table" then
			if #args.blacklist > 0 then cursor:set(CP_CONFIG, "main", "blacklist", args.blacklist)
			else cursor:delete(CP_CONFIG, "main", "blacklist") end
		end
		cursor:commit(CP_CONFIG)

		apply_content_protection(cursor)
		return {}
	end,

	get_apps = function()
		return cjson.empty_array
	end,

	get_dpi_stats = function()
		return { content_protection_all = 0, content_protection_day = 0 }
	end,
}
