-- Unique, collision-resistant IDs for UCI sections created by the RPC layer.
--
-- The old pattern (os.time() .. math.random(100000,999999), piped through
-- sha256sum) looks random but is not: nginx-mod-lua evaluates every /rpc
-- request in a fresh Lua VM, so math.random() is re-seeded identically and
-- os.time() only has one-second resolution. Two sections created in the same
-- second - exactly what happens when the GUI adds a group and its first peer
-- together - therefore produced the *same* id. On a real device that made a
-- WireGuard client's peer_id collide with its group_id, so the peer could not
-- be told apart from the group it belonged to.
--
-- /proc/sys/kernel/random/uuid is backed by the kernel CSPRNG and is the
-- entropy source the rest of the system already relies on.

local M = {}

local function read_uuid()
	local f = io.open("/proc/sys/kernel/random/uuid", "r")
	if not f then return nil end
	local value = f:read("*l")
	f:close()
	return value and value:match("^[0-9a-f%-]+$") and value or nil
end

-- Hex id, `len` chars (default 16). Falls back to time+random only if the
-- kernel uuid source is unavailable, which should never happen on Linux.
function M.new(len)
	len = tonumber(len) or 16
	local uuid = read_uuid()
	if uuid then
		return (uuid:gsub("%-", "")):sub(1, len)
	end
	local seed = tostring(os.time()) .. tostring(math.random(100000, 999999))
	local pipe = io.popen("printf %s '" .. seed .. "' | sha256sum | cut -c1-" .. len)
	if not pipe then return seed:sub(1, len) end
	local out = (pipe:read("*a") or ""):gsub("%s+$", "")
	pipe:close()
	return out
end

return M
