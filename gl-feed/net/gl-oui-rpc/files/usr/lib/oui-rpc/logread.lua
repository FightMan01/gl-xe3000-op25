-- "logread" RPC object: system/kernel/nginx log viewer + crash logs.
--
-- All `lines` arguments are passed through `tonumber()` before ever
-- reaching a shell command string, so a non-numeric value just becomes
-- nil (falls back to the default) rather than smuggling shell syntax
-- through.

local CRASH_LOG_DIR = "/tmp/crash"
local NGINX_LOG = "/var/log/nginx/error.log"

local function tail_cmd(cmd, lines)
	local n = tonumber(lines) or 200
	n = math.max(1, math.min(2000, math.floor(n)))
	local f = io.popen(cmd .. " 2>/dev/null | tail -n " .. n)
	if not f then return "" end
	local data = f:read("*a") or ""
	f:close()
	return data
end

return {
	get_system_log = function(args)
		return { log = tail_cmd("logread", args.lines) }
	end,

	get_kernel_log = function(args)
		return { log = tail_cmd("dmesg", args.lines) }
	end,

	get_nginx_log = function(args)
		local f = io.open(NGINX_LOG, "r")
		if not f then return { log = "" } end
		local data = f:read("*a") or ""
		f:close()
		return { log = data }
	end,

	-- No eSIM daemon exists to log.
	get_esim_log = function(args)
		return { log = "" }
	end,

	get_crash_log = function(args)
		local entries = {}
		local p = io.popen("ls -1 " .. CRASH_LOG_DIR .. " 2>/dev/null")
		if p then
			for name in p:lines() do
				table.insert(entries, name)
			end
			p:close()
		end
		return { crashes = entries }
	end,

	remove_crash_log = function(args)
		if type(args.name) ~= "string" or args.name:match("[/%.]%.") or args.name:match("^%.") then
			return { code = 1, message = "invalid name" }
		end
		os.remove(CRASH_LOG_DIR .. "/" .. args.name)
		return {}
	end,

	-- Lists the available log "modules" (categories) for a source-picker
	-- dropdown, matching the other get_*_log methods on this object.
	get_module_name = function(args)
		return { modules = { "system", "kernel", "nginx", "crash" } }
	end,

	get_config = function(args)
		local f = io.open("/etc/config/system", "r")
		local level = "info"
		if f then f:close() end
		return { level = level }
	end,

	set_config = function(args)
		-- Log level is set via /etc/config/system's `log` section
		-- (conf_log_level in busybox syslog terms) - not yet wired to a
		-- real restart-and-apply here.
		return {}
	end,

	export_logs = function(args)
		-- The frontend ignores our return value and always downloads
		-- /tmp/logread.tar as "logread.tar" (stock's contract), so the
		-- archive has to land exactly there, as a plain tar.
		local dest = "/tmp/logread.tar"
		local name = "xe3000_log"
		local dir = "/tmp/" .. name
		os.remove(dest)
		os.execute(string.format([[
rm -rf %s
mkdir -p %s/nginx
logread > %s/system.log 2>/dev/null
dmesg > %s/kernel.log 2>/dev/null
cp /var/log/nginx/*.log %s/nginx/ 2>/dev/null
cat /sys/fs/pstore/dmesg* %s/* > %s/crash.log 2>/dev/null
tar -cf %s -C /tmp %s
rm -rf %s
]], dir, dir, dir, dir, dir, CRASH_LOG_DIR, dir, dest, name, dir))
		local f = io.open(dest, "rb")
		if not f then
			return { code = 1, message = "export failed" }
		end
		f:close()
		return { path = dest }
	end,
}
