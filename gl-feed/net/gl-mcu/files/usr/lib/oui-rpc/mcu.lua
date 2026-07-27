-- "mcu" RPC object: thin proxy onto the gl-mcu daemon's ubus object.
-- Runs inside the nginx worker (LuaJIT), loaded via loadfile by oui-rpc.lua.

local ubus = require "ubus"

local function call(method, args)
	local conn = ubus.connect()
	if not conn then
		return nil, "ubus connect failed"
	end
	local res = conn:call("mcu", method, args or {})
	conn:close()
	return res
end

return {
	status = function(args) return call("status") end,
	get_warning = function(args) return call("get_warning") end,
	set_warning = function(args) return call("set_warning", args) end,
	reset_button = function(args) return call("reset_button") end,
	system_reboot = function(args) return call("system_reboot") end,
	version = function(args) return call("version") end,
}
