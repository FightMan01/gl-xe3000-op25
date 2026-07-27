-- GL SDK4 SQM page adapter backed by OpenWrt's maintained sqm-scripts.
-- The stock frontend exposes one aggregate router shaper and expects only
-- {enable, upload, download, qdisc}; GL's own XE3000 firmware implements
-- that queue on br-lan, so it applies regardless of which Multi-WAN uplink
-- is currently selected.

local uci = require "uci"

local function first_queue(cursor)
	local section
	cursor:foreach("sqm", "queue", function(s)
		if not section then section = s[".name"] end
	end)
	return section
end

local function bandwidth_mbps(value)
	value = tonumber(value)
	if not value or value < 0 or value > 100000000 then return nil end
	return value
end

local function disable_flow_offloading(cursor)
	local defaults
	cursor:foreach("firewall", "defaults", function(s)
		if not defaults then defaults = s[".name"] end
	end)
	if defaults then
		cursor:set("firewall", defaults, "flow_offloading", "0")
		cursor:set("firewall", defaults, "flow_offloading_hw", "0")
		cursor:commit("firewall")
		os.execute("/etc/init.d/firewall reload >/dev/null 2>&1")
	end
end

return {
	get_config = function(args)
		local cursor = uci.cursor()
		local section = first_queue(cursor)
		if not section then
			return { enable = false, upload = 0, download = 0, qdisc = "cake" }
		end
		return {
			enable = cursor:get("sqm", section, "enabled") == "1",
			-- sqm-scripts stores kbit/s; GL's page displays and submits
			-- Mbit/s (and calculates the adjacent MB/s hint from it).
			upload = (tonumber((cursor:get("sqm", section, "upload"))) or 0) / 1000,
			download = (tonumber((cursor:get("sqm", section, "download"))) or 0) / 1000,
			qdisc = cursor:get("sqm", section, "qdisc") or "cake",
		}
	end,

	set_config = function(args)
		args = args or {}
		if type(args.enable) ~= "boolean" then
			return { code = 1, message = "enable must be boolean" }
		end
		if args.qdisc ~= "cake" and args.qdisc ~= "fq_codel" then
			return { code = 1, message = "qdisc error" }
		end
		local upload = bandwidth_mbps(args.upload)
		local download = bandwidth_mbps(args.download)
		if not upload or not download or (args.enable and (upload == 0 or download == 0)) then
			return { code = 1, message = "invalid bandwidth" }
		end

		local cursor = uci.cursor()
		local section = first_queue(cursor)
		if not section then
			section = "gl"
			cursor:set("sqm", section, "queue")
		end
		cursor:set("sqm", section, "interface", "br-lan")
		cursor:set("sqm", section, "enabled", args.enable and "1" or "0")
		cursor:set("sqm", section, "qdisc", args.qdisc)
		cursor:set("sqm", section, "script",
			args.qdisc == "cake" and "piece_of_cake.qos" or "simple.qos")
		cursor:set("sqm", section, "upload", tostring(math.floor(upload * 1000)))
		cursor:set("sqm", section, "download", tostring(math.floor(download * 1000)))
		cursor:set("sqm", section, "qdisc_advanced", "0")
		cursor:set("sqm", section, "ingress_ecn", "ECN")
		cursor:set("sqm", section, "egress_ecn", "ECN")
		cursor:set("sqm", section, "qdisc_really_really_advanced", "0")
		cursor:set("sqm", section, "itarget", "auto")
		cursor:set("sqm", section, "etarget", "auto")
		cursor:set("sqm", section, "linklayer", "none")
		cursor:commit("sqm")

		if args.enable then disable_flow_offloading(cursor) end
		os.execute("/etc/init.d/sqm restart >/dev/null 2>&1")
		return {}
	end,
}
