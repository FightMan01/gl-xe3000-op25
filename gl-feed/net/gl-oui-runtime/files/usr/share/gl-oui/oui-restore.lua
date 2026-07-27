-- One-time GL UI restore endpoint for a freshly-flashed router. Accepts
-- the tarball produced by tools/backup-gl-ui.sh and unpacks it into
-- place so the vendor GL frontend shows up without needing scp/ssh.
--
-- Gated the same way the first-boot setup wizard already is elsewhere in
-- this feed: only usable before a root password is set. Once a password
-- exists, this refuses and points at the manual scp/ssh route instead -
-- there's no reason for an unauthenticated file-write endpoint to keep
-- existing on an already-configured router.

local function root_password_is_set()
	local f = io.open("/etc/shadow", "r")
	if not f then return true end
	for line in f:lines() do
		local user, enc = line:match("^([^:]+):([^:]*):")
		if user == "root" then
			f:close()
			return enc ~= ""
		end
	end
	f:close()
	return true
end

local function fail(status, msg)
	ngx.status = status
	ngx.header["Content-Type"] = "text/plain"
	ngx.say(msg)
	return ngx.exit(ngx.HTTP_OK)
end

if root_password_is_set() then
	return fail(403, "A password is already set on this router - " ..
		"restore the GL UI over scp/ssh instead (see the README).")
end

ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body then
	local body_file = ngx.req.get_body_file()
	if not body_file then return fail(400, "no upload received") end
	local f = io.open(body_file, "rb")
	if not f then return fail(500, "could not read uploaded file") end
	body = f:read("*a")
	f:close()
end

local content_type = ngx.var.content_type or ""
local boundary = content_type:match('boundary="?([^";]+)"?')
if not boundary then return fail(400, "expected multipart/form-data") end

local marker = "--" .. boundary
local part_start = body:find(marker, 1, true)
if not part_start then return fail(400, "malformed upload") end
local headers_end = body:find("\r\n\r\n", part_start, true)
if not headers_end then return fail(400, "malformed upload") end
local data_start = headers_end + 4
local next_marker = body:find("\r\n" .. marker, data_start, true)
if not next_marker then return fail(400, "malformed upload") end
local file_data = body:sub(data_start, next_marker - 1)

local tmp = "/tmp/gl-ui-restore.tar.gz"
local out = io.open(tmp, "wb")
if not out then return fail(500, "could not write temp file") end
out:write(file_data)
out:close()

-- Check the archive's own file listing before extracting anything: it
-- must contain exactly the two directories backup-gl-ui.sh packages, and
-- none of its entries may try to escape via "..".
local listing = {}
local p = io.popen("tar -tzf " .. tmp .. " 2>/dev/null")
if p then
	for line in p:lines() do table.insert(listing, line) end
	p:close()
end

local has_www, has_menu, has_traversal = false, false, false
for _, entry in ipairs(listing) do
	if entry:find("..", 1, true) then has_traversal = true end
	if entry == "www/" or entry:match("^www/") then has_www = true end
	if entry:match("^usr/share/oui/menu%.d/") then has_menu = true end
end

if has_traversal or not has_www or not has_menu or #listing == 0 then
	os.remove(tmp)
	return fail(400, "doesn't look like a GL UI backup " ..
		"(expected a www/ and usr/share/oui/menu.d/ tree)")
end

os.execute("tar -xzf " .. tmp .. " -C / www usr/share/oui/menu.d")
os.remove(tmp)

ngx.header["Content-Type"] = "text/plain"
ngx.say("Restored. Reload this page.")
