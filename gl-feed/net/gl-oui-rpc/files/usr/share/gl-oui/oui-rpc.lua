-- gl-oui-rpc: /rpc endpoint dispatcher, reimplemented for the OpenWrt 25.12 port.
--
-- Runs inside an nginx worker via content_by_lua_file (nginx-mod-lua / LuaJIT).
-- Wire protocol matches GL's original exactly, so the vendored, unmodified
-- GL frontend bundle (package gl-oui-www) works against this without any
-- changes:
--
--   POST /rpc  {"id": <any>, "method": "challenge"|"login"|"logout"|"alive"|"call", "params": {...}}
--   -> {"jsonrpc":"2.0","id":..,"result":...} | {"jsonrpc":"2.0","id":..,"error":{"code":..,"message":..}}
--
-- "call" params is a positional array: [sid, object, method, args]. object.method
-- is dispatched by loading /usr/lib/oui-rpc/<object>.lua, which must return
-- a table of functions keyed by method name (these RPC object files are
-- pure Lua source, not bytecode - GL's own glc/.so dlopen bridge is
-- dropped entirely).
--
-- challenge/login/logout proxy straight to the gl-session ubus object,
-- implemented by the separate gl-ngx-session daemon (runs under eco, not
-- in the nginx worker).

-- Use the patched base module, not cjson.safe: the safe wrapper has a
-- separate module table and does not reliably preserve the shared
-- cjson.empty_array sentinel. Losing that identity serializes [] fields
-- (client IPv6, ACL lists, etc.) as {}, then the GL UI crashes on `.map`.
local cjson = require "cjson"
local ubus = require "ubus"
local uci = require "uci"

local ERROR_PARSE          = -32700
local ERROR_INVALID_REQ    = -32600
local ERROR_METHOD_NOT_FOUND = -32601
local ERROR_INVALID_PARAMS = -32602
local ERROR_INTERNAL       = -32603
local ERROR_ACCESS         = -32000
local ERROR_NOT_FOUND      = -32001
local ERROR_SESSION_LIMIT  = -32002
local ERROR_LOGIN_FAIL_LIMIT = -32003

local RPC_OBJECT_DIR = "/usr/lib/oui-rpc/"

local function reply(id, result)
	ngx.say(cjson.encode({ jsonrpc = "2.0", id = id, result = result }))
end

local function reply_error(id, code, message, data)
	ngx.say(cjson.encode({
		jsonrpc = "2.0",
		id = id,
		error = { code = code, message = message or "error", data = data },
	}))
end

-- /etc/config/gl-oui-rpc declares these sections as `config no_auth 'ui'`
-- - a named section where "ui" is the section name (`.name`), not an
-- `option object 'ui'` field. Must check `s['.name']`, matching what the
-- config file's own section-naming expresses.
local function is_no_auth(cursor, object, method)
	local allowed = false
	cursor:foreach("gl-oui-rpc", "no_auth", function(s)
		if s['.name'] == object then
			for _, m in ipairs(s.method or {}) do
				if m == method then
					allowed = true
				end
			end
		end
	end)
	return allowed
end

-- ACL entries are "object.method:perm" or "*.*:perm", perm containing 'r'/'w'.
-- 'root' always has unconditional access, matching GL's original behavior.
local function acl_allows(cursor, aclgroup, object, method)
	if aclgroup == "root" then
		return true
	end
	local allowed = false
	cursor:foreach("gl-oui-acl", "group", function(s)
		if s[".name"] == aclgroup then
			for _, entry in ipairs(s.acl or {}) do
				local pattern, _ = entry:match("^([^:]+):(.*)$")
				if pattern == "*.*" or pattern == (object .. "." .. method) or pattern == (object .. ".*") then
					allowed = true
				end
			end
		end
	end)
	return allowed
end

local function call_gl_session(method, params)
	local conn = ubus.connect()
	if not conn then
		return nil, "ubus connect failed"
	end
	local res = conn:call("gl-session", method, params or {})
	conn:close()
	return res
end

local function rpc_challenge(id, params)
	local res, err = call_gl_session("challenge", { username = params.username })
	if not res then
		return reply_error(id, ERROR_INTERNAL, err)
	end
	if res.code ~= 0 then
		return reply_error(id, ERROR_LOGIN_FAIL_LIMIT, res.message or "login temporarily locked")
	end
	reply(id, res.data)
end

local function rpc_login(id, params)
	local res, err = call_gl_session("login", { username = params.username, hash = params.hash })
	if not res then
		return reply_error(id, ERROR_INTERNAL, err)
	end
	if res.code ~= 0 then
		return reply_error(id, ERROR_ACCESS, res.message or "login failed")
	end
	-- Deliberately NOT HttpOnly: the vendored frontend reads its own
	-- session id back out of this cookie via plain JS
	-- (window.$getCookie("Admin-Token")), used throughout the app shell
	-- to know which sid to send on every subsequent "call". An HttpOnly
	-- cookie would make the SPA perceive no session at all even though
	-- login succeeded server-side.
	ngx.header["Set-Cookie"] = "Admin-Token=" .. res.data.sid .. "; Path=/"
	reply(id, res.data)
end

local function rpc_logout(id, params)
	call_gl_session("logout", { sid = params.sid })
	reply(id, {})
end

-- On a genuinely fresh device, the real GUI does not show the login form
-- at all - it routes straight to the setup wizard. The login page's own
-- route guard only makes a no-auth `alive` call, using its result as
-- `t ? r() : r({name:"internet"})` (render the login form if truthy,
-- otherwise redirect to the wizard). So "alive" here means "has this
-- device completed initial setup" (a password has been set), not "is
-- there a valid session" - checked via the same /etc/shadow
-- empty-password convention used in gl-ngx-session's read_shadow_entry
-- (empty enc field = OpenWrt's own "no password configured" state, not
-- "locked").
local function root_password_is_set()
	local f = io.open("/etc/shadow", "r")
	if not f then return true end -- fail safe: assume initialized rather than loop-redirect forever
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

local function rpc_alive(id, params)
	reply(id, { alive = root_password_is_set() })
end

local function rpc_call(id, params)
	local sid, object, method, args = params[1], params[2], params[3], params[4]

	if type(object) ~= "string" or not object:match("^[%a_][%w%-_]*$")
		or type(method) ~= "string" or not method:match("^[%a_][%w%-_]*$") then
		return reply_error(id, ERROR_INVALID_PARAMS, "invalid object/method")
	end

	local cursor = uci.cursor()
	-- Uninitialized device (no password set): the setup wizard needs full
	-- RPC access (modem/wifi/cable/lan/etc.) with no session at all, since
	-- none can exist yet - matches rpc_alive's same root_password_is_set()
	-- check and the observed real behavior (wizard opens directly, no
	-- login). Once a real password exists, this bypass stops applying and
	-- every object/method goes back through normal session+ACL checks -
	-- this is intentionally NOT a permanent broad allowlist, only active
	-- during the narrow pre-setup window.
	local no_auth = is_no_auth(cursor, object, method) or not root_password_is_set()

	local aclgroup = nil
	if not no_auth then
		local sess, err = call_gl_session("session", { sid = sid })
		if not sess or not sess.username then
			-- The message string here is load-bearing, not just
			-- human-readable text: the frontend's global response
			-- interceptor does a literal string match on "Access denied"
			-- to recognize a session-rejected error, clear the stale
			-- cookie, and auto-redirect to /login. Any other message
			-- falls through to a generic "unknown" error type that
			-- several call sites just retry forever instead of handling,
			-- hanging the UI. Must be this exact string.
			return reply_error(id, ERROR_ACCESS, "Access denied")
		end
		aclgroup = sess.aclgroup or "guest"
		if not acl_allows(cursor, aclgroup, object, method) then
			return reply_error(id, ERROR_ACCESS, "Access denied")
		end
	end

	local script = RPC_OBJECT_DIR .. object .. ".lua"
	local f = io.open(script, "r")
	if not f then
		return reply_error(id, ERROR_NOT_FOUND, "no such object: " .. object)
	end
	f:close()

	local chunk, load_err = loadfile(script)
	if not chunk then
		ngx.log(ngx.ERR, "rpc load error for ", script, ": ", load_err)
		return reply_error(id, ERROR_INTERNAL, "failed to load rpc object")
	end

	local ok, handlers = pcall(chunk)
	if not ok or type(handlers) ~= "table" then
		ngx.log(ngx.ERR, "rpc exec error for ", script, ": ", tostring(handlers))
		return reply_error(id, ERROR_INTERNAL, "failed to init rpc object")
	end

	local fn = handlers[method]
	if type(fn) ~= "function" then
		return reply_error(id, ERROR_METHOD_NOT_FOUND, "no such method: " .. method)
	end

	local call_ok, result_or_err = pcall(fn, args or {})
	if not call_ok then
		ngx.log(ngx.ERR, "rpc handler error ", object, ".", method, ": ", tostring(result_or_err))
		return reply_error(id, ERROR_INTERNAL, "internal error")
	end

	reply(id, result_or_err)
end

local METHODS = {
	challenge = rpc_challenge,
	login = rpc_login,
	logout = rpc_logout,
	alive = rpc_alive,
	call = rpc_call,
}

-- entry point

ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body then
	ngx.status = 400
	return reply_error(nil, ERROR_PARSE, "empty request body")
end

local req, decode_err = cjson.decode(body)
if not req then
	ngx.status = 400
	return reply_error(nil, ERROR_PARSE, "invalid json: " .. tostring(decode_err))
end

local handler = METHODS[req.method]
if not handler then
	return reply_error(req.id, ERROR_METHOD_NOT_FOUND, "unknown method: " .. tostring(req.method))
end

handler(req.id, req.params or {})
