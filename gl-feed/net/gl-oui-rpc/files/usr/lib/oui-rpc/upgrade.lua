-- "upgrade" RPC object: firmware upgrade (router + cellular modem).
--
-- Router firmware wraps standard OpenWrt `sysupgrade`. The uploaded image
-- must be a standard OpenWrt 25.12 sysupgrade .bin for this target
-- (glinet_gl-xe3000).
--
-- Modem firmware follows stock GL's upgrade RPC and /usr/bin/upgrade_cellular
-- exactly (reproduced from the 4.10 firmware): the package is uploaded to
-- /tmp/upgrade_cellular/firmware.zip (or downloaded from GL's cellular feed),
-- unzipped, version-checked when it carries GL metadata, and flashed by
-- Quectel's QFirehose. "Online" router-firmware variants stay stubs: no
-- router update server is configured for this port.

local cjson = require "cjson"
local uci = require "uci"
local ubus = require "ubus"

-- The upgrade page's upload card writes here (stock gl-upload.d contract).
local UPLOAD_PATH = "/tmp/firmware.img"

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

-- --- Cellular modem firmware (stock GL upgrade RPC semantics) ---

-- Modem model (from AT+QGMR) -> GL's firmware family on its cellular feed.
local CELLULAR_INFO_LIST = {
	RM520NGL = { name = "rm520gl", firmware = "RM520GL" },
	EM160RGLAP = { name = "em160rglap", firmware = "EM160RGLAP" },
	EG120K = { name = "eg120k", firmware = "EG120K" },
}
local FIRMWARE_URL = "https://fw.gl-inet.com/cellular/"
local DOWNLOAD_URL = "https://dl.gl-inet.com/cellular/"
local UPGRADE_CELLULAR_TMP = "/tmp/upgrade_cellular"
local FIRMWARE_PATH = "/root/cellular_firmware"
local FIRMWARE_ZIP_PATH = UPGRADE_CELLULAR_TMP .. "/firmware.zip"
local UPGRADE_STATUS_PATH = UPGRADE_CELLULAR_TMP .. "/status"
local CELLULAR_FIRMWARE_SIZE = UPGRADE_CELLULAR_TMP .. "/size"

local function exists(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end

local function readfile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function writefile(path, data)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local function file_size(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local size = f:seek("end")
	f:close()
	return size
end

local function ensure_tmp_dir()
	if not exists(UPGRADE_CELLULAR_TMP) then
		os.execute("mkdir " .. UPGRADE_CELLULAR_TMP)
	end
end

local function decode(raw)
	if not raw or raw == "" then return nil end
	local ok, data = pcall(cjson.decode, raw)
	if ok and type(data) == "table" then return data end
	return nil
end

local function https_get(url)
	local p = io.popen("curl -Ls --connect-timeout 6 -m 30 '" .. url:gsub("'", "") .. "' 2>/dev/null")
	if not p then return nil end
	local body = p:read("*a")
	p:close()
	if body == "" or body:match("^%s*<") then return nil end
	return body
end

-- Stock's get_cur_cellular_version: AT+QGMR, mapped onto the GL feed name.
local function get_cur_cellular_version()
	local modem, firmware, name
	local conn = ubus.connect()
	local res = conn and conn:call("cellular.at", "command", { cmd = "AT+QGMR", timeout = 3 })
	if conn then conn:close() end
	local resp = res and res.response or ""
	for line in resp:gmatch("[^\r\n]+") do
		if not line:match("^AT") and line ~= "OK" and line:match("^%S+$") then
			modem = line
			break
		end
	end
	if modem then
		for key, info in pairs(CELLULAR_INFO_LIST) do
			if modem:find(key) then
				firmware, name = info.firmware, info.name
			end
		end
	end
	if not firmware then modem = nil end
	return { modem = modem, modem_firmware = firmware, name = name }
end

local function cellular_url()
	local url = uci.cursor():get("upgrade", "general", "cellular_url")
	if url == "" then return nil end
	return url
end

local function get_cellular_release_note(base, firmware, version)
	local url = cellular_url()
	if url then
		url = string.format("%s/metadata_%s", url, version)
	else
		url = string.format("%s%s/metadata_%s", base, firmware, version)
	end
	local meta = decode(https_get(url))
	if not meta then return "" end
	return meta.release_note
end

local function split(s, sep)
	local out = {}
	for piece in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = piece end
	return out
end

-- Stock's is_upgrade_valid: -1 different model/branch, 0 newer, 1 not newer.
local function is_upgrade_valid(cur, new)
	local p = "(%w+)R(%d+)A(%d+).+%.(%d+)$"
	local c1, c2, c3, c4 = cur:match(p)
	local n1, n2, n3, n4 = new:match(p)
	if c1 ~= nil and c1 == n1 and c2 == n2
			and string.byte(n4, 1) == string.byte(c4, 1) then
		if c3 < n3 or (n3 == c3 and c4 < n4) then
			return 0
		end
		return 1
	end
	return -1
end

-- Stock's get_last_version: newest applicable entry of list_sha256.txt
-- (sha256 size date version pkg type base, tab separated).
local function get_last_version(info)
	local url = cellular_url()
	if url then
		url = string.format("%s/list_sha256.txt", url)
	else
		url = string.format("%s%s/list_sha256.txt", DOWNLOAD_URL, info.modem_firmware)
	end
	local list = https_get(url)
	if not list then return nil end
	for _, row in ipairs(split(list, "\n")) do
		local f = split(row:gsub("[\n\r]", ""), "\t")
		local entry = {
			sha256sum = f[1], size = f[2], new_date = f[3], new_version = f[4],
			pkg = f[5], upgrade_type = f[6], base_version = f[7],
		}
		if entry.new_version and is_upgrade_valid(info.modem, entry.new_version) == 0
				and (entry.upgrade_type == "full"
					or (entry.upgrade_type == "diff" and entry.base_version == info.modem)) then
			return entry
		end
	end
	return nil
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

	-- --- Cellular modem firmware ---

	check_cellular_online = function(args)
		local info = get_cur_cellular_version()
		if not info.modem then
			return { err_code = "-2", err_msg = "get version fail, refresh and retry" }
		end
		local result = {
			current_version = info.modem:match("([^_]+)"),
			download_url = FIRMWARE_URL .. info.name,
		}
		local last = get_last_version(info)
		ensure_tmp_dir()
		if last then
			result.release_note = get_cellular_release_note(DOWNLOAD_URL, info.modem_firmware,
				last.new_version .. "_" .. last.upgrade_type)
			result.new_version = last.new_version:match("([^_]+)")
			result.new_version_date = os.date("%Y-%m-%d %H:%M:%S", tonumber(last.new_date))
			result.current_version = info.modem:match("([^_]+)")
		end
		return result
	end,

	upgrade_cellular_online = function(args)
		local info = get_cur_cellular_version()
		local base = cellular_url()
		if not info.modem then
			return { err_code = "-2", err_msg = "get version fail, refresh and retry" }
		end
		ensure_tmp_dir()
		local last = get_last_version(info)
		if not last then return {} end
		base = base or (DOWNLOAD_URL .. info.modem_firmware)
		local cmd = string.format("upgrade_cellular %s/%s %s %s %s >/dev/null 2>&1 &",
			base, last.pkg, last.sha256sum, last.size, last.upgrade_type)
		writefile(UPGRADE_STATUS_PATH, "1")
		os.execute(cmd)
		return {}
	end,

	upgrade_cellular_local = function(args)
		if exists(FIRMWARE_ZIP_PATH) then
			ensure_tmp_dir()
			writefile(UPGRADE_STATUS_PATH, "7")
			os.execute("upgrade_cellular local >/dev/null 2>&1 &")
			return {}
		end
		return { err_code = -2, err_msg = "no installation package found, please re-upload" }
	end,

	-- status: 1 = no GL metadata (plain Quectel package, accepted as a full
	-- upgrade), 0 = GL package valid for this modem, -1 = not usable.
	check_cellular_local = function(args)
		local result = {}
		local meta
		if not exists(FIRMWARE_ZIP_PATH) then
			return { err_code = -2, err_msg = "no installation package found, please re-upload" }
		end

		-- Unzip into /tmp only when it has room for twice the zip,
		-- otherwise onto the overlay, as stock does.
		local zip_size = file_size(FIRMWARE_ZIP_PATH) or 0
		local p = io.popen("df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}'")
		local free = p and (tonumber(p:read("*l") or "") or 0) * 1024 or 0
		if p then p:close() end
		local path
		if zip_size * 2 < free then
			path = UPGRADE_CELLULAR_TMP .. "/cellular_firmware"
		else
			path = FIRMWARE_PATH
		end
		os.execute(string.format("rm -rf %s; unzip -o %s -d %s; echo %s > %s/unzip_path",
			path, FIRMWARE_ZIP_PATH, path, path, UPGRADE_CELLULAR_TMP))

		if exists(path) then
			if exists(path .. "/metadata") then
				local raw = readfile(path .. "/metadata")
				if raw then
					meta = decode(raw)
					if not meta then
						result.status = -1
						return result
					end
					local info = get_cur_cellular_version()
					local valid = info.modem and meta.version and meta.version.new_version
						and is_upgrade_valid(info.modem, meta.version.new_version) or -1
					if valid >= 0 then
						if meta.upgrade_type == "diff" then
							result.status = (meta.version.base_version == info.modem) and 0 or -1
						else
							result.status = 0
						end
					else
						result.status = -1
					end
					result.date = meta.version and meta.version.date
					result.version = meta.version and meta.version.new_version
						and meta.version.new_version:match("([^_]+)")
					result.release_note = meta.release_note
				end
			else
				result.status = 1
			end
		else
			result.status = -1
		end

		writefile(UPGRADE_CELLULAR_TMP .. "/upgrade_type",
			(meta and meta.upgrade_type == "diff") and "diff" or "full")
		if meta and meta.upgrade_type == "diff" then
			os.execute("rm -rf " .. UPGRADE_CELLULAR_TMP .. "/cellular_firmware")
		end
		return result
	end,

	-- status codes are upgrade_cellular's (1 downloading ... 9 upgrade ok);
	-- percent is the download progress while status is 1.
	get_cellular_upgrade_status = function(args)
		local status = tonumber(readfile(UPGRADE_STATUS_PATH) or "") or 0
		local result = { status = status }
		if status == 1 then
			local total = tonumber(readfile(CELLULAR_FIRMWARE_SIZE) or "")
			local size = file_size(FIRMWARE_ZIP_PATH)
			if not total or not size or total == 0 then
				result.percent = 0
				return result
			end
			result.percent = size / total
		end
		return result
	end,

	reset_cellular_upgrade_status = function(args)
		os.execute("kill -9 $(ps | grep \"curl -Ls --connect-timeout 6\" | grep -v grep | awk '{print $1}');"
			.. "kill -9 `ps | grep upgrade_cellular | grep -v grep | awk '{print $1}'`;"
			.. "rm /tmp/upgrade_cellular/*")
		return {}
	end,
}
