-- "led" RPC object: status LED control.
--
-- Standard /sys/class/leds sysfs, GPIO-backed, using mainline's own DTS
-- `label` values (green:wifi2g etc), not GL-firmware's sysfs names.
-- Method set is just get_config/set_config, one bulk get/set.

local uci = require "uci"

local LEDS = {
	power = "green:power",
	wan = "green:wan",
	wifi2g = "green:wifi2g",
	wifi5g = "green:wifi5g",
	signal1 = "green:5g:led1",
	signal2 = "green:5g:led2",
	signal3 = "green:5g:led3",
	signal4 = "green:5g:led4",
}

local function led_path(name)
	local sysfs = LEDS[name]
	if not sysfs then return nil end
	return "/sys/class/leds/" .. sysfs
end

local function read_attr(name, attr)
	local path = led_path(name)
	if not path then return nil end
	local f = io.open(path .. "/" .. attr, "r")
	if not f then return nil end
	local v = f:read("*l")
	f:close()
	return v
end

local function write_attr(name, attr, value)
	local path = led_path(name)
	if not path then return false end
	local f = io.open(path .. "/" .. attr, "w")
	if not f then return false end
	f:write(value)
	f:close()
	return true
end

return {
	get_config = function(args)
		local cursor = uci.cursor()
		local leds = {}
		for name in pairs(LEDS) do
			local brightness = tonumber(read_attr(name, "brightness")) or 0
			leds[name] = { on = brightness > 0, brightness = brightness }
		end
		return {
			-- The Overview bundle reads/writes `led_enable`; the older
			-- internal `global_enabled` name left the switch looking on
			-- while every set request was silently ignored.
			led_enable = cursor:get("system", "gl_led", "led_enable") ~= "0",
			leds = leds,
		}
	end,

	-- args.led_enable (optional), args.leds = {name = {on}, ...}
	-- (optional, per-LED overrides).
	set_config = function(args)
		local cursor = uci.cursor()
		local enabled = args.led_enable
		if enabled == nil then enabled = args.global_enabled end
		if enabled ~= nil then
			cursor:set("system", "gl_led", "system")
			cursor:set("system", "gl_led", "led_enable", enabled and "1" or "0")
			cursor:commit("system")
		end

		if enabled == false then
			for name in pairs(LEDS) do
				write_attr(name, "trigger", "none")
				write_attr(name, "brightness", "0")
			end
			return {}
		end

		if enabled == true then
			-- Restore a useful default indication immediately instead of
			-- merely persisting the toggle while all LEDs remain dark.
			write_attr("power", "trigger", "default-on")
		end

		if type(args.leds) == "table" then
			for name, led in pairs(args.leds) do
				if LEDS[name] and led.on ~= nil then
					local max = tonumber(read_attr(name, "max_brightness")) or 1
					write_attr(name, "trigger", "none")
					write_attr(name, "brightness", led.on and tostring(max) or "0")
				end
			end
		end
		return {}
	end,
}
