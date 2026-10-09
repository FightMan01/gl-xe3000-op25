-- gl-oui-upload: /upload endpoint, reimplemented for the OpenWrt 25.12
-- port. The vendored frontend's gl-upload-card posts multipart/form-data
-- with the fields sid, size, path and file, in that order (stock GL's
-- oui-upload.lua contract), then calls the matching check_* RPC.
--
-- The body is streamed straight to disk through the request socket: a
-- modem firmware zip is far larger than anything worth buffering, and
-- there is no resty.upload on this image. Because sid and path arrive
-- before the file, both are checked before a single file byte is
-- accepted. Only the exact destinations below can be written, mirroring
-- stock's /usr/share/gl-upload.d allowlist for the upgrade pages.

local ubus = require "ubus"

local ALLOWED_PATHS = {
	["/tmp/firmware.img"] = true,
	["/tmp/upgrade_cellular/firmware.zip"] = true,
}

local CHUNK = 65536

local function fail(status, msg)
	ngx.status = status
	ngx.say(msg)
	return ngx.exit(status)
end

local function session_valid(sid)
	local conn = ubus.connect()
	if not conn then return false end
	local res = conn:call("gl-session", "session", { sid = sid })
	conn:close()
	return res and res.username ~= nil
end

-- Free bytes on the filesystem holding dir (df -k: 1K blocks).
local function free_bytes(dir)
	local p = io.popen("df -k " .. dir .. " 2>/dev/null | awk 'NR==2 {print $4}'")
	if not p then return nil end
	local kb = tonumber(p:read("*l") or "")
	p:close()
	return kb and kb * 1024
end

local content_type = ngx.var.content_type or ""
local boundary = content_type:match("boundary=\"?([^\";]+)\"?")
if not boundary then
	return fail(400, "bad request")
end

local sock, err = ngx.req.socket()
if not sock then
	return fail(400, "no request body: " .. tostring(err))
end
sock:settimeout(60000)

local delimiter = "\r\n--" .. boundary
local read_headers = sock:receiveuntil("\r\n\r\n")

-- The body opens with "--boundary\r\n" (no leading CRLF).
local first = sock:receive("*l")
if not first or first ~= "--" .. boundary then
	return fail(400, "bad multipart body")
end

local fields = {}
local written_path, temp_path

while true do
	local headers = read_headers()
	if not headers then
		return fail(400, "bad multipart headers")
	end
	local name = headers:match('[Nn]ame="([^"]*)"')
	local read_part = sock:receiveuntil(delimiter)

	if name == "file" then
		local path, sid, size = fields.path, fields.sid, tonumber(fields.size)
		if type(sid) ~= "string" or not session_valid(sid) then
			return fail(403, "Access denied")
		end
		if type(path) ~= "string" or not ALLOWED_PATHS[path] or path:find("..", 1, true) then
			return fail(403, "path not allowed")
		end
		local dir = path:match("^(.*)/[^/]+$")
		os.execute("mkdir -p " .. dir)
		local free = free_bytes(dir)
		if size and free and size >= free then
			-- The upload card shows its "not enough memory" message on 507.
			return fail(507, "insufficient storage")
		end

		temp_path = path .. ".part"
		local out = io.open(temp_path, "wb")
		if not out then
			return fail(500, "cannot open destination")
		end
		while true do
			local data, rerr = read_part(CHUNK)
			if data then
				if not out:write(data) then
					out:close()
					os.remove(temp_path)
					return fail(507, "insufficient storage")
				end
			elseif rerr then
				out:close()
				os.remove(temp_path)
				return fail(400, "upload interrupted: " .. tostring(rerr))
			else
				break
			end
		end
		out:close()
		written_path = path
	else
		local chunks = {}
		while true do
			local data, rerr = read_part(4096)
			if data then
				chunks[#chunks + 1] = data
			elseif rerr then
				return fail(400, "bad multipart field")
			else
				break
			end
		end
		if name then fields[name] = table.concat(chunks) end
	end

	-- After a delimiter: "--" closes the body, CRLF starts the next part.
	local tail = sock:receive(2)
	if tail == "--" then break end
	if tail ~= "\r\n" then
		if temp_path then os.remove(temp_path) end
		return fail(400, "bad multipart delimiter")
	end
end

if not written_path then
	return fail(400, "no file in request")
end

-- Only now replace any previous upload with the complete file.
os.rename(temp_path, written_path)
ngx.say("ok")
