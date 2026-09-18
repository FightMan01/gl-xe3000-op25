-- PWM fan status and thermal-threshold control for the XE3000.

local uci = require "uci"

local CPU_TEMP = "/sys/class/thermal/thermal_zone0/temp"
local FAN_DEFAULT = 85

-- The threshold is applied by gl-fan-set-threshold, which rewrites the
-- whole fan cooling curve.  It can't be done here by writing a single
-- trip: the fan actually starts on the *lowest* active trip (the DTS
-- default is 60 C), not on trip_point_3.

local function find_pwmfan_hwmon()
	local base = "/sys/class/hwmon/"
	local p = io.popen("ls " .. base .. " 2>/dev/null")
	if not p then return nil end
	for entry in p:lines() do
		local f = io.open(base .. entry .. "/name", "r")
		if f then
			local name = f:read("*l")
			f:close()
			if name == "pwmfan" then
				p:close()
				return base .. entry .. "/"
			end
		end
	end
	p:close()
	return nil
end

local function read_number(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local n = tonumber(f:read("*l"))
	f:close()
	return n
end

local function write_number(path, n)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(tostring(math.floor(n)))
	f:close()
	return true
end

return {
	get_status = function(args)
		local dir = find_pwmfan_hwmon()
		return {
			present = dir ~= nil,
			speed = dir and (read_number(dir .. "fan1_input") or 0) or 0,
			pwm = dir and (read_number(dir .. "pwm1") or 0) or 0,
		}
	end,

	get_config = function(args)
		local cursor = uci.cursor()
		local configured = cursor:get("gl-oui-rpc", "fan", "temperature")
		local threshold = tonumber(configured) or FAN_DEFAULT
		return {
			temperature = threshold,
			warn_temperature = math.floor((read_number(CPU_TEMP) or 0) / 1000),
		}
	end,

	set_config = function(args)
		local threshold = tonumber(args.temperature)
		if not threshold or threshold < 69 or threshold > 91 then
			return { code = 1, err_code = 1, err_msg = "invalid temperature" }
		end
		local ok = os.execute(
			"/usr/sbin/gl-fan-set-threshold " .. tostring(math.floor(threshold)))
		if ok == nil or ok == false or (type(ok) == "number" and ok ~= 0) then
			return { code = 2, err_code = 2, err_msg = "fan threshold is not writable" }
		end
		local cursor = uci.cursor()
		cursor:set("gl-oui-rpc", "fan", "fan")
		cursor:set("gl-oui-rpc", "fan", "temperature", tostring(threshold))
		cursor:commit("gl-oui-rpc")
		return {}
	end,

	-- Retain the lower-level control method for callers outside the
	-- current GL overview page.
	set_status = function(args)
		local dir = find_pwmfan_hwmon()
		if not dir then
			return { code = 1, message = "no fan hardware detected" }
		end
		if args.mode == "manual" and type(args.pwm) == "number" then
			write_number(dir .. "pwm1_enable", 1)
			write_number(dir .. "pwm1", math.max(0, math.min(255, args.pwm)))
		elseif args.mode == "off" then
			write_number(dir .. "pwm1_enable", 1)
			write_number(dir .. "pwm1", 0)
		elseif args.mode == "auto" then
			write_number(dir .. "pwm1_enable", 2)
		end
		return {}
	end,
}
