-- LuCI installation state used by the GL "Advanced Settings" page.
--
-- On this OpenWrt snapshot LuCI is an image package (managed by apk) and is
-- served by uhttpd on 8080/8443.  It is intentionally not installed and
-- removed dynamically like GL's older staged-ipk implementation.

local function installed()
	local f = io.open("/www/cgi-bin/luci", "r")
	if not f then
		return false
	end
	f:close()
	return true
end

return {
	get_status = function()
		-- Frontend enum: 0 not installed, 2 installed.
		return { status = installed() and 2 or 0 }
	end,

	install_luci = function()
		-- A missing LuCI requires rebuilding/installing the image package;
		-- report the current immutable image state without starting a bogus
		-- background ipk download.
		return { status = installed() and 2 or 0 }
	end,

	uninstall_luci = function()
		-- Keep the recovery/admin UI available.  The GL page will continue to
		-- report it as installed on its next status poll.
		return { status = installed() and 2 or 0 }
	end,
}
