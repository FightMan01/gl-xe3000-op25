-- "network-quality" RPC object for the GL.iNet Network Quality page.
--
-- get_config/set_config manage /etc/config/network-quality; set_speedtest
-- forwards to the running network-quality ubus daemon. The page polls the
-- daemon's snapshot over the separate network_quality.status websocket topic.

local uci = require "uci"
local ubus = require "ubus"

local DEFAULT_TARGET = "google.com"
local TARGET_PATTERN = "^[%w%._:%-/]*$"

local DEFAULT_PRESETS = {
	{ name = "Baidu", value = "baidu.com" },
	{ name = "Tencent", value = "qq.com" },
	{ name = "Alibaba", value = "www.aliyun.com" },
	{ name = "Google", value = "google.com" },
	{ name = "Microsoft", value = "www.microsoft.com" },
	{ name = "Cloudflare", value = "cloudflare.com" },
}

local function has_screen()
	local f = io.open("/proc/gl-hw-info/screen", "r")
	if not f then
		return false
	end
	f:close()
	return true
end

local function ubus_call(object, method, params)
	local conn = ubus.connect()
	if not conn then
		return nil, "ubus connect failed"
	end
	local result, err = conn:call(object, method, params or {})
	conn:close()
	return result, err
end

local function preset_list(cursor)
	local list = {}
	local items = cursor:get("network-quality", "global", "preset_target")
	if type(items) ~= "table" then
		items = items and { items } or nil
	end
	if items then
		for _, item in ipairs(items) do
			local name, value = tostring(item):match("^([^=]+)=(.+)$")
			if name and value then
				list[#list + 1] = { name = name, value = value }
			end
		end
	end
	if #list == 0 then
		for _, item in ipairs(DEFAULT_PRESETS) do
			list[#list + 1] = { name = item.name, value = item.value }
		end
	end
	return list
end

return {
	get_config = function()
		local cursor = uci.cursor()
		return {
			enabled = cursor:get("network-quality", "global", "enabled") == "1",
			ethernet_ping_address = cursor:get("network-quality", "global", "ethernet_ping_address") or DEFAULT_TARGET,
			dns_probe_domain = cursor:get("network-quality", "global", "dns_probe_domain") or DEFAULT_TARGET,
			preset_targets = preset_list(cursor),
		}
	end,

	set_config = function(args)
		args = args or {}
		if args.enabled ~= nil and type(args.enabled) ~= "boolean" then
			return { code = 1, message = 'param "enabled" must be a boolean value' }
		end
		if args.ethernet_ping_address ~= nil and type(args.ethernet_ping_address) ~= "string" then
			return { code = 1, message = 'param "ethernet_ping_address" must be a string' }
		end
		if args.dns_probe_domain ~= nil and type(args.dns_probe_domain) ~= "string" then
			return { code = 1, message = 'param "dns_probe_domain" must be a string' }
		end
		if args.ethernet_ping_address and not args.ethernet_ping_address:match(TARGET_PATTERN) then
			return { code = 1, message = "invalid ethernet_ping_address" }
		end
		if args.dns_probe_domain and not args.dns_probe_domain:match(TARGET_PATTERN) then
			return { code = 1, message = "invalid dns_probe_domain" }
		end

		local cursor = uci.cursor()
		local was_enabled = cursor:get("network-quality", "global", "enabled") == "1"
		local enabled = args.enabled
		if enabled == nil then
			enabled = was_enabled
		end

		if args.ethernet_ping_address ~= nil then
			local value = args.ethernet_ping_address
			if value == "" then value = DEFAULT_TARGET end
			cursor:set("network-quality", "global", "ethernet_ping_address", value)
		end
		if args.dns_probe_domain ~= nil then
			local value = args.dns_probe_domain
			if value == "" then value = DEFAULT_TARGET end
			cursor:set("network-quality", "global", "dns_probe_domain", value)
		end
		cursor:set("network-quality", "global", "enabled", enabled and "1" or "0")
		cursor:commit("network-quality")

		if not enabled then
			-- Stop a running test before the daemon goes away so its curl
			-- children do not keep a metered link busy.
			ubus_call("network-quality", "set_speedtest", { enable = false })
			if not has_screen() then
				os.execute("/etc/init.d/network-quality stop >/dev/null 2>&1")
			end
			return {}
		end

		if not was_enabled then
			os.execute("/etc/init.d/network-quality start >/dev/null 2>&1")
		elseif has_screen() then
			os.execute("/etc/init.d/network-quality start >/dev/null 2>&1")
		end
		-- Applying new probe targets should not require a second page load.
		-- Ignore an early failure: the init script may still be spawning.
		ubus_call("network-quality", "reload_config", {})
		return {}
	end,

	snapshot = function()
		local result = ubus_call("network-quality", "snapshot", {})
		return result or {}
	end,

	set_speedtest = function(args)
		args = args or {}
		if type(args.enable) ~= "boolean" then
			return { code = 1, message = 'param "enable" must be a boolean value' }
		end
		local result, err = ubus_call("network-quality", "set_speedtest", { enable = args.enable })
		if not result then
			return { code = 1, message = err or "failed to set speedtest" }
		end
		if result.err_code and result.err_code ~= 0 then
			return { code = 1, message = result.err_msg or "failed to set speedtest" }
		end
		return {}
	end,
}
