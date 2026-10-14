-- APN suggestions for the SIM's home network, from the same database the
-- stock firmware ships (apns-full-conf-<version>.json.gz). A database
-- fetched by gl-cellular-apn-db-update takes precedence over the one in the
-- UI package.

local cjson = require "cjson"

local M = {}

local UPDATED_DIR = "/etc/gl-cellular/apn-db"
local BUNDLED_DIR = "/www/js"
local MAX_APNS = 8

-- Names the modem uses for its own bearers; never offered for data.
local RESERVED = { ims = true, sos = true, emergency = true, mms = true, xcap = true }

local cache = { path = nil, imsi = nil, list = nil }

local function first_file(dir)
	local p = io.popen("ls -1 " .. dir .. "/apns-full-conf-*.json.gz 2>/dev/null | tail -n 1")
	if not p then return nil end
	local path = p:read("*l")
	p:close()
	if path and path ~= "" then return path end
	return nil
end

function M.db_path()
	return first_file(UPDATED_DIR) or first_file(BUNDLED_DIR)
end

local function load_db(path)
	local p = io.popen("gzip -dc '" .. path .. "' 2>/dev/null")
	if not p then return nil end
	local raw = p:read("*a")
	p:close()
	if not raw or raw == "" then return nil end
	local ok, db = pcall(cjson.decode, raw)
	if ok and type(db) == "table" and type(db.apns) == "table" then return db end
	return nil
end

local function wants_data(entry)
	local apn = entry["-apn"]
	if type(apn) ~= "string" or apn == "" or RESERVED[apn:lower()] then
		return false
	end
	local types = entry["-type"]
	if type(types) ~= "string" or types == "" then return true end
	return types:find("default", 1, true) ~= nil or types:find("ia", 1, true) ~= nil
end

-- imsi: the SIM's IMSI (MCC + MNC + MSIN). The MNC is two or three digits
-- depending on the country, so both are tried against the database.
-- Returns an array of APN names, most specific first (possibly empty).
function M.lookup(imsi)
	if type(imsi) ~= "string" or not imsi:match("^%d%d%d%d%d") then
		return {}
	end
	local path = M.db_path()
	if not path then return {} end
	if cache.path == path and cache.imsi == imsi then return cache.list end

	local out = {}
	local db = load_db(path)
	if db then
		local mcc, mnc2, mnc3 = imsi:sub(1, 3), imsi:sub(4, 5), imsi:sub(4, 6)
		local seen = {}
		for _, e in ipairs(db.apns) do
			if e["-mcc"] == mcc and wants_data(e) then
				local mnc = e["-mnc"]
				if (mnc == mnc2 or mnc == mnc3) and not seen[e["-apn"]] then
					seen[e["-apn"]] = true
					out[#out + 1] = e["-apn"]
					if #out >= MAX_APNS then break end
				end
			end
		end
	end
	cache.path, cache.imsi, cache.list = path, imsi, out
	collectgarbage()
	return out
end

return M
