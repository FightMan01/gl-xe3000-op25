-- "flow_statistics" RPC object: overview page traffic graph. Method set:
-- get_flow_statistics, get_statistics_rule, set_statistics_rule,
-- clear_statistics. get_app_flow_statistics/get_top_app_flow_statistics
-- need DPI/per-app traffic classification and aren't implemented here.
--
-- get_flow_statistics returns a bare array; its one entry ("all") is the
-- aggregate/total-traffic entry with {total, upload, download} fields
-- (cumulative byte counts) - no per-app breakdown without a DPI backend.

local ubus = require "ubus"
local uci = require "uci"

local function net_device(logical_iface)
	local conn = ubus.connect()
	if not conn then return nil end
	local status = conn:call("network.interface." .. logical_iface, "status", {})
	conn:close()
	return status and (status.l3_device or status.device)
end

local function read_num(devname, f)
	if not devname then return 0 end
	local fh = io.open("/sys/class/net/" .. devname .. "/statistics/" .. f, "r")
	if not fh then return 0 end
	local v = fh:read("*n")
	fh:close()
	return v or 0
end

-- Aggregate total across every configured WAN-facing interface (matches
-- what an "internet traffic" total should mean - not per-LAN-client,
-- which is `clients`'s job elsewhere in this feed).
local function total_wan_bytes()
	local rx, tx = 0, 0
	for _, logical in ipairs({ "wan", "wwan", "repeater" }) do
		local dev = net_device(logical)
		if dev then
			rx = rx + read_num(dev, "rx_bytes")
			tx = tx + read_num(dev, "tx_bytes")
		end
	end
	return rx, tx
end

return {
	get_flow_statistics = function(args)
		local rx, tx = total_wan_bytes()
		return {
			{
				name = "all",
				download = rx,
				upload = tx,
				total = rx + tx,
			},
		}
	end,

	-- type is a statistics-grouping mode - "app" (group by application) is
	-- the only one meaningful without a DPI backend.
	get_statistics_rule = function(args)
		local cursor = uci.cursor()
		return {
			enable = cursor:get("gl-oui-rpc", "flow_statistics", "enabled") == "1",
			time = cursor:get("gl-oui-rpc", "flow_statistics", "time") or "day",
			type = cursor:get("gl-oui-rpc", "flow_statistics", "type") or "app",
		}
	end,

	set_statistics_rule = function(args)
		local cursor = uci.cursor()
		if not cursor:get("gl-oui-rpc", "flow_statistics") then
			cursor:set("gl-oui-rpc", "flow_statistics", "flow_statistics")
		end
		cursor:set("gl-oui-rpc", "flow_statistics", "enabled", args.enable and "1" or "0")
		if args.time then
			cursor:set("gl-oui-rpc", "flow_statistics", "time", args.time)
		end
		if args.type then
			cursor:set("gl-oui-rpc", "flow_statistics", "type", args.type)
		end
		cursor:commit("gl-oui-rpc")
		return {}
	end,

	-- No persistent historical counter DB in this implementation (counters
	-- read live from /sys each call) - accepted as a no-op that just
	-- acknowledges the request rather than claiming a reset that doesn't
	-- really happen, since /sys interface counters can't be zeroed without
	-- resetting the interface itself.
	clear_statistics = function(args)
		return {}
	end,
}
