-- "upgrade" RPC object: firmware upgrade (router + cellular modem).
--
-- Router firmware wraps standard OpenWrt `sysupgrade`. The uploaded image
-- must be a standard OpenWrt 25.12 sysupgrade .bin for this target
-- (glinet_gl-xe3000).
--
-- Modem firmware upgrade (Quectel QDL/firehose flashing over a dedicated
-- USB interface) is a materially different, high-risk operation from
-- router sysupgrade and out of scope here - the cellular_* methods are
-- "not supported" stubs, not fake successes. "Online" (remote
-- update-server) variants are also stubs: no update server/feed is
-- configured for this port.

local cjson = require "cjson"

local UPLOAD_PATH = "/tmp/firmware.bin"

local function read_release_desc()
	local release = io.open("/etc/openwrt_release", "r")
	local ver = "unknown"
	if release then
		local data = release:read("*a")
		release:close()
		ver = data:match("DISTRIB_DESCRIPTION='([^']+)'") or ver
	end
	return ver
end

return {
	-- upgrade_enable: sysupgrade works on this port. prompt: no proactive
	-- "new version available" nag since no update server/feed exists.
	-- Firmware version itself comes from ui.check_initialized/
	-- system.get_info, not here.
	get_config = function(args)
		return { upgrade_enable = true, prompt = false }
	end,

	set_config = function(args)
		-- Upgrade preferences (e.g. auto-check-for-updates) - no update
		-- server configured yet, recorded only.
		return {}
	end,

	-- status is a small integer enum: 5 = no image uploaded, 0 = valid
	-- (passed sysupgrade -T), 1 = failed sysupgrade's checks - the two
	-- states this port can actually detect. sha256 is the real digest of
	-- the uploaded image, empty when none uploaded.
	check_firmware_local = function(args)
		local f = io.open(UPLOAD_PATH, "rb")
		if not f then
			return { sha256 = "", status = 5 }
		end
		f:close()
		local sha256 = ""
		local p = io.popen("sha256sum " .. UPLOAD_PATH .. " 2>/dev/null")
		if p then
			local line = p:read("*l")
			p:close()
			sha256 = line and line:match("^(%x+)") or ""
		end
		local ok = os.execute("sysupgrade -T " .. UPLOAD_PATH .. " >/dev/null 2>&1")
		if ok == true or ok == 0 then
			return { sha256 = sha256, status = 0 }
		end
		return { sha256 = sha256, status = 1 }
	end,

	-- args.keep_settings (default true). Actual file upload happens via
	-- the /upload HTTP endpoint (oui-upload.lua) directly to UPLOAD_PATH -
	-- this method only validates + triggers the flash.
	upgrade_local = function(args)
		local keep_settings = args.keep_settings
		if keep_settings == nil then keep_settings = true end

		local check = os.execute("sysupgrade -T " .. UPLOAD_PATH .. " >/dev/null 2>&1")
		if not (check == true or check == 0) then
			return { code = 1, message = "image validation failed" }
		end

		local cmd = "sysupgrade " .. (keep_settings and "" or "-n ") .. UPLOAD_PATH
		-- Detached: sysupgrade kills most userspace processes (including
		-- this nginx worker) partway through, so this call never returns
		-- a normal RPC response - the frontend polls connectivity/reboot
		-- instead, matching standard OpenWrt upgrade UX.
		os.execute(cmd .. " >/tmp/sysupgrade.log 2>&1 &")
		return { code = 0 }
	end,

	-- --- Online (remote update server) - not configured, honest stubs ---

	check_firmware_online = function(args)
		return { available = false, message = "no update server configured" }
	end,

	-- Result is a bare array (a step/progress-log, empty when idle). No
	-- update server is configured, so this always reports the empty case.
	get_online_upgrade_status = function(args)
		return cjson.empty_array
	end,

	upgrade_online = function(args)
		return { code = 1, message = "no update server configured" }
	end,

	upgrade_online_cancel = function(args)
		return {}
	end,

	-- --- Cellular modem firmware - not supported, honest stubs ---

	-- err_code -99 marks "this feature doesn't exist here at all", kept
	-- distinct from a "no package uploaded yet" code since that's a
	-- different condition than out-of-scope.
	check_cellular_local = function(args)
		return { err_code = -99, err_msg = "modem firmware upgrade not supported" }
	end,

	check_cellular_online = function(args)
		return { err_code = -99, err_msg = "modem firmware upgrade not supported" }
	end,

	-- status is a number (idle/in-progress/error enum), 0 = idle - the
	-- frontend's home-page poll treats any other shape as "upgrade in
	-- progress" and pops a permanent "Modem Upgrading" modal.
	get_cellular_upgrade_status = function(args)
		return { status = 0 }
	end,

	reset_cellular_upgrade_status = function(args)
		return {}
	end,
}
