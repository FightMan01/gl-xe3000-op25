-- Read-only GL-XE3000 manufacturing identity reader.
--
-- Verified against the original XE3000 device tree's factory_data node:
--   0x10: device DDNS / cloud ID (16-byte field)
--   0x20: backup device credential (16-byte field; deliberately private)
--   0x30: device serial number (16-byte field)
--   0x40: default WiFi password (not returned by this identity module)
--   0x88: two-letter regulatory country
--
-- Values are strictly validated before use. This module never writes the
-- factory partition.

local M = {}

local FACTORY_PATHS = {
	"/sys/bus/nvmem/devices/mmcblk0p3/nvmem",
	"/dev/mmcblk0p3",
}

local function read_at(offset, length)
	for _, path in ipairs(FACTORY_PATHS) do
		local f = io.open(path, "rb")
		if f then
			local ok = f:seek("set", offset)
			local value = ok and f:read(length) or nil
			f:close()
			if value and #value == length then return value end
		end
	end
	return nil
end

local function exact(offset, length, pattern)
	local value = read_at(offset, length)
	if value and value:match(pattern) then return value end
	return nil
end

local function terminated(offset, length, pattern)
	local value = read_at(offset, length)
	if not value then return nil end
	value = value:match("^([^%z\255]*)") or ""
	if value:match(pattern) then return value end
	return nil
end

function M.get()
	local country = exact(0x88, 2, "^[A-Z][A-Z]$")
	local ddns = terminated(0x10, 16, "^[A-Za-z0-9]+$")
	return {
		country = country or "HU",
		device_id = ddns,
		serial = terminated(0x30, 16, "^[A-Za-z0-9]+$"),
		ddns = ddns,
		source = country and "factory" or "fallback",
	}
end

return M
