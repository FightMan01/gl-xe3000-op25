-- "igmp" RPC object: IGMP snooping/multicast passthrough toggle.
-- Minimal by design - no kernel module, no config beyond this.

local uci = require "uci"

return {
	-- version is the IGMP protocol version to snoop for. Not independently
	-- configurable here, always reported/accepted as 3 (stock
	-- igmpproxy/mcproxy default).
	get_config = function(args)
		local cursor = uci.cursor()
		return {
			enable = cursor:get("network", "lan", "igmp_snooping") ~= "0",
			version = 3,
		}
	end,

	set_config = function(args)
		local cursor = uci.cursor()
		local enable = args.enable
		if enable == nil then enable = args.snooping end
		cursor:set("network", "lan", "igmp_snooping", enable and "1" or "0")
		cursor:commit("network")
		os.execute("/etc/init.d/network reload >/dev/null 2>&1")
		return {}
	end,
}
