-- gl-oui-download: /download endpoint, reimplemented for the OpenWrt
-- 25.12 port. The vendored frontend's $downloadFile() submits a plain
-- POST form (sid/path/filename[/delete]) rather than calling /rpc for
-- file downloads (a JSON-RPC response can't carry a browser
-- Content-Disposition download) - see gl-port-runtime.js/app bundle's
-- $downloadFile for the exact client-side contract this mirrors.
--
-- `path` is client-supplied but session-gated the same way /rpc is; it's
-- additionally restricted to an explicit allowlist of directories this
-- port actually generates downloadable files into, so a valid session
-- can't be used to read arbitrary files off the router.

local ubus = require "ubus"

local ALLOWED_DIRS = {
	"/etc/openvpn/ovpn/",
}

local function call_gl_session(method, params)
	local conn = ubus.connect()
	if not conn then return nil, "ubus connect failed" end
	local res = conn:call("gl-session", method, params or {})
	conn:close()
	return res
end

local function path_allowed(path)
	for _, dir in ipairs(ALLOWED_DIRS) do
		if path:sub(1, #dir) == dir and not path:find("..", 1, true) then
			return true
		end
	end
	return false
end

ngx.req.read_body()
local args = ngx.req.get_post_args() or {}
local sid, path, filename = args.sid, args.path, args.filename

if type(sid) ~= "string" or type(path) ~= "string" or type(filename) ~= "string" then
	ngx.status = 400
	ngx.say("bad request")
	return
end

local sess = call_gl_session("session", { sid = sid })
if not sess or not sess.username then
	ngx.status = 403
	ngx.say("Access denied")
	return
end

if not path_allowed(path) then
	ngx.status = 403
	ngx.say("path not allowed")
	return
end

local file = io.open(path, "rb")
if not file then
	ngx.status = 404
	ngx.say("not found")
	return
end
local data = file:read("*a")
file:close()

ngx.header["Content-Type"] = "application/octet-stream"
ngx.header["Content-Disposition"] = 'attachment; filename="' .. filename:gsub('"', "") .. '"'
ngx.header["Content-Length"] = #data
ngx.print(data)

if args.delete == "1" then
	os.remove(path)
end
