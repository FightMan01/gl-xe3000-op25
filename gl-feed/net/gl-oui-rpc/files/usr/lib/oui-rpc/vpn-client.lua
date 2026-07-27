-- Compatibility surface used by the always-visible Clients page even when
-- the optional VPN Client/Profile views are hidden.  This port currently has
-- no client tunnels, so report honest empty collections instead of making
-- the page poll a nonexistent RPC object every five seconds.

local cjson = require "cjson"

local function empty_array()
	return cjson.empty_array
end

return {
	get_vpn_using_status = function()
		return empty_array()
	end,

	get_tunnel = function()
		return { tunnels = empty_array() }
	end,

	get_connection_methods = function()
		return empty_array()
	end,

	check_domain_online = function()
		return { online = false }
	end,

	-- The Clients page can call this only after selecting a real tunnel.
	-- Keep the method present but reject invented state explicitly.
	set_single_mac = function()
		return {
			err_code = 1,
			err_msg = "VPN client tunnels are not configured",
		}
	end,
}
