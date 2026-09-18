-- nginx 404 handler used by wifidog-ng.
--
-- A client whose HTTP/HTTPS flow was intercepted by the kernel module arrives
-- here with the original external path.  Redirect it to the local GL UI so
-- the browser can display the repeater portal state and the user can open the
-- detected upstream portal from the router's normal management page.

local ubus = require "ubus"

local function lan_address()
	local conn = ubus.connect()
	if not conn then return nil end
	local status = conn:call("network.interface.lan", "status", {})
	conn:close()
	if not status or status.up ~= true then return nil end
	local address = status["ipv4-address"]
		and status["ipv4-address"][1]
		and status["ipv4-address"][1].address
	return address
end

local address = lan_address()
if not address then
	return ngx.exit(ngx.HTTP_NOT_FOUND)
end

local scheme = ngx.var.scheme == "https" and "https" or "http"
local port = tonumber(ngx.var.server_port)
local url = scheme .. "://" .. address
if port and ((scheme == "http" and port ~= 80)
		or (scheme == "https" and port ~= 443)) then
	url = url .. ":" .. port
end

return ngx.redirect(url)
