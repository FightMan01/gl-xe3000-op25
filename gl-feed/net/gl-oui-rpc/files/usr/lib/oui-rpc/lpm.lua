-- "lpm" RPC object: low-power/"sleep" mode status. This device has no
-- battery/sleep hardware state beyond what "mcu" already reports
-- (charge/temperature) - stub, never actually sleeping.

return {
	get_status = function(args)
		return { sleeping = false }
	end,
}
