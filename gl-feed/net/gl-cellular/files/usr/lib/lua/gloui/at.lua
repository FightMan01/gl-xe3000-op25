-- AT-command helper for the nginx-lua RPC objects (runs under LuaJIT, so it
-- proxies to the gl-cellular-atd daemon over ubus rather than opening the
-- serial port directly - matches the gl-mcu/mcu.lua split).

local ubus = require "ubus"
local cjson = require "cjson"

local M = {}

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.command(cmd, timeout, options)
	timeout = tonumber(timeout) or 5
	options = options or {}

	-- lua-ubus' synchronous call has its own relatively short, fixed reply
	-- deadline.  That is fine for normal AT queries, but it expires before
	-- commands such as a full AT+COPS=? carrier scan (often 1-3 minutes) or
	-- a manual carrier registration can finish.  The browser deliberately
	-- allows ten minutes for the operator scan, so use ubus(1)'s explicit
	-- per-call timeout for long operations and keep the fast in-process path
	-- for the frequent status polling commands.
	if timeout > 20 then
		local payload = cjson.encode({ cmd = cmd, timeout = math.floor(timeout) })
		local ubus_timeout = math.floor(timeout) + 10
		local ngx_api = rawget(_G, "ngx")

		-- io.popen() would preserve the extended ubus timeout but block the
		-- entire single nginx worker until the modem scan returned.  Launch
		-- the ubus client as a background process instead and yield the
		-- request coroutine with ngx.sleep(); other tabs and WebSocket/RPC
		-- traffic remain responsive throughout the multi-minute scan.
		if ngx_api and type(ngx_api.sleep) == "function" then
			local nonce = string.format("%d-%d-%d",
				ngx_api.worker.pid(), math.floor(ngx_api.now() * 1000),
				math.random(100000, 999999))
			local base = "/tmp/gl-at-long-" .. nonce
			local output_path = base .. ".out"
			local done_path = base .. ".done"
			local post_command = options.redial_wwan
				and "/sbin/ifup wwan >/dev/null 2>&1"
				or ":"
			local command = string.format(
				"( /bin/ubus -S -t %d call cellular.at command %s > %s 2>/dev/null; status=$?; %s; echo $status > %s ) &",
				ubus_timeout, shell_quote(payload),
				shell_quote(output_path), post_command, shell_quote(done_path))
			if os.execute(command) ~= 0 then
				return nil, "failed to start ubus client"
			end

			local deadline = ngx_api.now() + ubus_timeout + 2
			local done
			repeat
				local marker = io.open(done_path, "r")
				if marker then
					done = marker:read("*l")
					marker:close()
					break
				end
				ngx_api.sleep(0.25)
			until ngx_api.now() >= deadline

			local output = ""
			local response = io.open(output_path, "r")
			if response then
				output = response:read("*a") or ""
				response:close()
			end
			os.remove(output_path)
			os.remove(done_path)
			if done ~= "0" or output == "" then
				return nil, "no response"
			end
			local decoded_ok, res = pcall(cjson.decode, output)
			if not decoded_ok or type(res) ~= "table" then
				return nil, "invalid response"
			end
			return res.response
		end

		-- Non-nginx callers do not have a request event loop to yield to.
		local command = string.format(
			"/bin/ubus -S -t %d call cellular.at command %s 2>/dev/null",
			ubus_timeout, shell_quote(payload))
		local pipe = io.popen(command, "r")
		if not pipe then return nil, "failed to start ubus client" end
		local output = pipe:read("*a")
		local ok = pipe:close()
		if options.redial_wwan then
			os.execute("/sbin/ifup wwan >/dev/null 2>&1")
		end
		if not ok or output == "" then return nil, "no response" end
		local decoded_ok, res = pcall(cjson.decode, output)
		if not decoded_ok or type(res) ~= "table" then
			return nil, "invalid response"
		end
		return res.response
	end

	local conn = ubus.connect()
	if not conn then
		return nil, "ubus connect failed"
	end
	local res = conn:call("cellular.at", "command", { cmd = cmd, timeout = timeout })
	conn:close()
	if not res then
		return nil, "no response"
	end
	return res.response
end

-- Splits "a,"b,c",d" into {"a", "b,c", "d"} - handles quoted fields
-- (which may themselves contain commas) since naive gmatch("[^,]*") both
-- mishandles quoted commas AND produces spurious empty-string matches
-- between real ones (a well-known Lua gmatch gotcha with zero-width
-- patterns).
local function split_csv(s)
	local fields = {}
	local pos = 1
	local len = #s
	while pos <= len + 1 do
		if s:sub(pos, pos) == '"' then
			local close = s:find('"', pos + 1) or len
			table.insert(fields, s:sub(pos + 1, close - 1))
			pos = close + 2 -- skip closing quote + following comma
		else
			local nextcomma = s:find(',', pos) or (len + 1)
			table.insert(fields, s:sub(pos, nextcomma - 1))
			pos = nextcomma + 1
		end
	end
	return fields
end

--- Parse "+CMD: field1,field2,..." style single-line AT responses into an
--- array, e.g. M.csv_fields(resp, "+QENG") extracts the CSV payload after
--- the first line matching "+QENG:".
function M.csv_fields(resp, prefix)
	if not resp then return nil end
	for line in resp:gmatch("[^\r\n]+") do
		local payload = line:match("^" .. prefix .. ":%s*(.+)$")
		if payload then
			return split_csv(payload)
		end
	end
	return nil
end

--- Like csv_fields, but returns EVERY matching line's field array, not just
--- the first. Needed because AT+QENG="servingcell" is not always a single
--- line - in 5G NSA mode the modem splits its response across three
--- separate "+QENG:" lines. See modem.lua's get_serving_cell().
function M.all_matches(resp, prefix)
	local out = {}
	if not resp then return out end
	for line in resp:gmatch("[^\r\n]+") do
		local payload = line:match("^" .. prefix .. ":%s*(.+)$")
		if payload then
			table.insert(out, split_csv(payload))
		end
	end
	return out
end

return M
