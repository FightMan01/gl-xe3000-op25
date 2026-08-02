-- GL SDK4 uses this underscore-named object (distinct from the hyphenated
-- "ovpn-client") for exactly one call: the config-rename dialog. Everything
-- else client-config-related (upload/import, vendor auto-provisioning)
-- lives on "ovpn-client" - see that file's header for what's out of scope.
--
-- No real client configs can exist yet (no upload pipeline), so this
-- always reports "not found" rather than silently pretending to rename
-- something that isn't there.

return {
	set_config_name = function()
		return { err_code = 1, err_msg = "config not found" }
	end,
}
