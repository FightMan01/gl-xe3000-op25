-- /ws endpoint - live push (status page updates: modem card, SIM info,
-- battery/MCU).
--
-- Protocol matches GL's own real `/usr/share/gl-ngx/oui-ws.lua`: requires
-- a `?sid=` query param (or loopback), validated via gl-session's
-- `session` ubus method. Client sends `{"cmd":"subscribe"|"unsubscribe",
-- "name":"<object>.<method>"}`; server pushes `{"name":...,"data":...}`
-- frames.
--
-- Uses vendored lua-resty-websocket (resty/websocket/{server,protocol}.lua,
-- BSD-licensed, unmodified upstream openresty/lua-resty-websocket) since
-- OpenWrt's nginx feed doesn't package it - matches what GL themselves did.
--
-- Differs from GL's implementation in one deliberate way: GL fans pushes
-- out via a Unix-socket proxy to gl-ngx-session's ubus `notify` method, so
-- any process can trigger an immediate push to all subscribed clients.
-- Replicating that needs a registry of live connections shared across
-- nginx worker processes, more complex than the actual requirement calls
-- for. Instead, each connection here polls its subscribed ubus
-- object/methods directly on a short timer (POLL_INTERVAL_MS) and pushes
-- on every tick - a few seconds of latency instead of instant push, much
-- simpler, and gl-ngx-session's own `notify` stays a no-op stub.
--
-- The six `cellular.*` topics come directly from the vendored frontend's
-- menu.d/internet.json `global_sockets` field. The `mcu.status` topic
-- matches gl-mcu's own ubus object "mcu" method "status" and the
-- "object.method" naming convention every other topic uses, though it
-- isn't independently confirmed against a literal string in the
-- frontend. Update TOPICS below if a real capture shows a different
-- string.

local server = require "resty.websocket.server"
-- Use the same patched cjson module as the RPC dispatcher.  The separate
-- cjson.safe module does not share our cjson.empty_array sentinel and could
-- silently return nil while encoding cable.status, leaving the Ethernet
-- card in its empty first-render state.
local cjson = require "cjson"
local ubus = require "ubus"

local POLL_INTERVAL_MS = 2000

local function empty_array_if_needed(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

-- Ubus reconstructs tables and therefore loses cjson.empty_array's identity.
-- Restore array semantics for the known array-valued cellular fields before
-- serializing the WebSocket frame.
local function normalize_topic(name, data)
	if name == "cellular.sims_info" and type(data.sims) == "table" then
		for _, sim in ipairs(data.sims) do
			sim.apn_list = empty_array_if_needed(sim.apn_list or {})
		end
	elseif name == "cellular.networks_info" and type(data.networks) == "table" then
		for _, network in ipairs(data.networks) do
			if type(network.ipv4) == "table" then
				network.ipv4.dns = empty_array_if_needed(network.ipv4.dns or {})
			end
		end
	end
	return data
end

local TOPICS = {
	-- cable.status is implemented by an RPC module, exactly like GL's
	-- stock cable websocket adapter (its bytecode loads cable.lua and
	-- calls get_status). It is not a standalone ubus daemon.
	["cable.status"] = { kind = "rpc", path = "/usr/lib/oui-rpc/cable.lua", method = "get_status" },
	-- Like cable.status, repeater.status is provided by our RPC adapter,
	-- not by a long-running ubus daemon.  Pointing this at a nonexistent
	-- `repeater` ubus object meant the Internet page never received live
	-- state changes and kept rendering its initial "disabled" card even
	-- after netifd had associated and obtained a DHCP lease.
	["repeater.status"] = { kind = "rpc", path = "/usr/lib/oui-rpc/repeater.lua", method = "get_status" },
	["cellular.modems_info"] = { "cellular", "modems_info" },
	["cellular.modems_status"] = { "cellular", "modems_status" },
	["cellular.sims_info"] = { "cellular", "sims_info" },
	["cellular.sims_status"] = { "cellular", "sims_status" },
	["cellular.networks_info"] = { "cellular", "networks_info" },
	["cellular.networks_status"] = { "cellular", "networks_status" },
	["mcu.status"] = { "mcu", "status" },
	["vpnclient.status"] = { kind = "rpc", path = "/usr/lib/oui-rpc/vpn-client.lua", method = "get_status" },
}

-- The Internet page also subscribes to "cloud.status" unconditionally on
-- load. GL's cloud/GoodCloud binding isn't implemented here, so there's
-- no ubus call to make for it - handled as a static literal instead of a
-- TOPICS table lookup, so subscribing gets an honest "not bound" answer
-- rather than being silently ignored forever.
local STATIC_TOPICS = {
	["cloud.status"] = { bound = false },
}

local function is_loopback()
	local addr = ngx.var.remote_addr
	return addr == "127.0.0.1" or addr == "::1"
end

local args = ngx.req.get_uri_args()
local sid = args.sid

if not sid and not is_loopback() then
	return ngx.exit(ngx.HTTP_FORBIDDEN)
end

if sid then
	local conn = ubus.connect()
	if not conn then
		return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
	end
	local res = conn:call("gl-session", "session", { sid = sid })
	conn:close()
	if not res or not res.username then
		return ngx.exit(ngx.HTTP_FORBIDDEN)
	end
end

local wb, err = server:new({
	timeout = POLL_INTERVAL_MS,
	max_payload_len = 65535,
})
if not wb then
	ngx.log(ngx.ERR, "ws handshake failed: ", err)
	return ngx.exit(444)
end

local subscribed = {}

local function push_topic(name)
	local data
	if STATIC_TOPICS[name] then
		data = STATIC_TOPICS[name]
	else
		local t = TOPICS[name]
		if not t then return end
		if t.kind == "rpc" then
			local ok, mod = pcall(dofile, t.path)
			if ok and type(mod) == "table" and type(mod[t.method]) == "function" then
				local call_ok, result = pcall(mod[t.method], {})
				if call_ok then
					data = result
				else
					ngx.log(ngx.ERR, "ws RPC topic ", name, " failed: ", result)
				end
			elseif not ok then
				ngx.log(ngx.ERR, "ws RPC module ", name, " failed: ", mod)
			end
		else
			local object = t.object or t[1]
			local method = t.method or t[2]
			local conn = ubus.connect()
			if not conn then return end
			data = conn:call(object, method, {})
			conn:close()
		end
	end
	if data then
		data = normalize_topic(name, data)
		local ok, payload = pcall(cjson.encode, { name = name, data = data })
		if ok and payload then
			-- lua-cjson's cjson and cjson.safe modules each initialise a
			-- separate empty-array sentinel in the same Lua registry. A
			-- worker which previously loaded both can therefore lose the
			-- sentinel identity even after normalize_topic(). These two
			-- substitutions are deliberately restricted to known array
			-- field names in cellular frames.
			if name == "cellular.sims_info" then
				payload = payload:gsub('"apn_list":{}', '"apn_list":[]')
			elseif name == "cellular.networks_info" then
				payload = payload:gsub('"dns":{}', '"dns":[]')
			end
			local _, send_err = wb:send_text(payload)
			if send_err then
				ngx.log(ngx.WARN, "ws send failed: ", send_err)
			end
		else
			ngx.log(ngx.ERR, "ws encode topic ", name, " failed: ", payload)
		end
	end
end

while true do
	local data, typ, frame_err = wb:recv_frame()

	if wb.fatal then
		ngx.log(ngx.ERR, "ws fatal: ", frame_err)
		break
	end

	if not data then
		-- resty/websocket's protocol.lua never returns the bare string
		-- "timeout" - on a cosocket read timeout it returns "failed to
		-- receive the first 2 bytes: timeout" (server.lua's own
		-- self.fatal check matches on the ": timeout" substring, so this
		-- file's check does the same rather than an exact match, which
		-- would close the connection on every POLL_INTERVAL_MS tick).
		if frame_err and frame_err:find(": timeout", 1, true) then
			-- WebSocket status traffic is genuine authenticated activity.
			-- Without touching the session here, a user who stays on the
			-- Internet dashboard (which updates exclusively over this
			-- socket) is logged out after the five-minute RPC timeout even
			-- though the page is active the whole time.
			if sid then
				local conn = ubus.connect()
				if conn then
					conn:call("gl-session", "touch", { sid = sid })
					conn:close()
				end
			end
			for name in pairs(subscribed) do
				push_topic(name)
			end
		else
			break
		end
	elseif typ == "close" then
		wb:send_close()
		break
	elseif typ == "ping" then
		wb:send_pong()
	elseif typ == "text" then
		local msg = cjson.decode(data)
		if type(msg) == "table" and type(msg.name) == "string"
			and (TOPICS[msg.name] or STATIC_TOPICS[msg.name]) then
			if msg.cmd == "subscribe" then
				subscribed[msg.name] = true
				push_topic(msg.name)
			elseif msg.cmd == "unsubscribe" then
				subscribed[msg.name] = nil
			end
		end
	end
end

wb:send_close()
