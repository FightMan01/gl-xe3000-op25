-- "screen" RPC object: device physical-screen lock status. Some GL
-- models show a PIN-unlock prompt on a physical OLED/e-ink screen during
-- setup; the XE3000 has no physical display, so this is a stub, always
-- unlocked.

return {
	get_lock_status = function(args)
		return { locked = false }
	end,
}
