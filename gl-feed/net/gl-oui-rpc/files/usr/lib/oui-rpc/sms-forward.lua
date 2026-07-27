-- SMS forwarding settings compatibility object used by the SMS page.
-- The snapshot port does not ship GL's proprietary forwarding daemon, but
-- the UI still requires these three methods to mount.  Persist the complete
-- configuration so it survives reboot and is ready for a forwarding worker.

local cjson = require "cjson"

local CONFIG = "/etc/gl-oui/sms-forward.json"

local function empty_array()
	return cjson.empty_array
end

local function defaults()
	return {
		single_sim = { enable = false, phone_numbers = empty_array() },
		dual_sim = {
			sim1 = { enable = false, phone_numbers = empty_array() },
			sim2 = { enable = false, phone_numbers = empty_array() },
		},
		email = {
			enable = false,
			emails = empty_array(),
			account = "",
			password = "",
			encryption = 0,
			smtp = "",
			subject = "GL-XE3000",
		},
	}
end

local function load_config()
	local f = io.open(CONFIG, "r")
	if not f then return defaults() end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(cjson.decode, content or "")
	if not ok or type(data) ~= "table" then return defaults() end
	local d = defaults()
	data.single_sim = data.single_sim or d.single_sim
	data.dual_sim = data.dual_sim or d.dual_sim
	data.dual_sim.sim1 = data.dual_sim.sim1 or d.dual_sim.sim1
	data.dual_sim.sim2 = data.dual_sim.sim2 or d.dual_sim.sim2
	data.email = data.email or d.email
	data.single_sim.phone_numbers = data.single_sim.phone_numbers or empty_array()
	data.dual_sim.sim1.phone_numbers = data.dual_sim.sim1.phone_numbers or empty_array()
	data.dual_sim.sim2.phone_numbers = data.dual_sim.sim2.phone_numbers or empty_array()
	data.email.emails = data.email.emails or empty_array()
	return data
end

local function save_config(data)
	os.execute("mkdir -p /etc/gl-oui")
	local path = CONFIG .. ".new"
	local f = io.open(path, "w")
	if not f then return false end
	f:write(cjson.encode(data))
	f:close()
	return os.rename(path, CONFIG)
end

local function normalize_numbers(numbers)
	local out = {}
	for _, item in ipairs(type(numbers) == "table" and numbers or {}) do
		if type(item) == "table" and type(item.phone_number) == "string" then
			local country = tostring(item.country_code or ""):gsub("[^%d+]", "")
			local number = item.phone_number:gsub("[^%d]", "")
			if number ~= "" then
				table.insert(out, {
					country_code = country,
					phone_number = number,
					full_number = (country .. number):gsub("[^%d+]", ""),
				})
			end
		end
	end
	return #out == 0 and empty_array() or out
end

return {
	get_config = function(args)
		local mode = args and args.modem_mode or "single"
		local config = load_config()
		local phone
		if mode == "dual" then
			phone = {
				modem_mode = "dual",
				sim1 = config.dual_sim.sim1,
				sim2 = config.dual_sim.sim2,
			}
		else
			phone = {
				modem_mode = "single",
				enable = config.single_sim.enable == true,
				phone_numbers = config.single_sim.phone_numbers,
			}
		end
		return { err_code = 0, phone = phone, email = config.email }
	end,

	set_phone_number = function(args)
		args = args or {}
		local config = load_config()
		if args.modem_mode == "dual" then
			config.dual_sim.sim1.enable = args.sim1 and args.sim1.enable == true
			config.dual_sim.sim1.phone_numbers =
				normalize_numbers(args.sim1 and args.sim1.phone_numbers)
			config.dual_sim.sim2.enable = args.sim2 and args.sim2.enable == true
			config.dual_sim.sim2.phone_numbers =
				normalize_numbers(args.sim2 and args.sim2.phone_numbers)
		else
			config.single_sim.enable = args.enable == true
			config.single_sim.phone_numbers = normalize_numbers(args.phone_numbers)
		end
		if not save_config(config) then
			return { err_code = -4, err_msg = "configuration save failed" }
		end
		return { err_code = 0 }
	end,

	set_email = function(args)
		args = args or {}
		local config = load_config()
		config.email = {
			enable = args.enable == true,
			emails = type(args.emails) == "table" and args.emails or empty_array(),
			account = tostring(args.account or ""),
			password = tostring(args.password or ""),
			encryption = tonumber(args.encryption) or 0,
			smtp = tostring(args.smtp or ""),
			subject = tostring(args.subject or "GL-XE3000"),
		}
		if not save_config(config) then
			return { err_code = -4, err_msg = "configuration save failed" }
		end
		return { err_code = 0 }
	end,
}
