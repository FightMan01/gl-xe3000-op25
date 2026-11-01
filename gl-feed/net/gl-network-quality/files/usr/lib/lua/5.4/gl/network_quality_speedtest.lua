-- Speedtest backend for the network-quality page.
--
-- GL's shipped binary is a small C client for Cloudflare's speed endpoints,
-- linked against GL's own libguci/libgl-utils and their exact libubus ABI.
-- Those libraries do not exist on this port, so the same three measurements
-- are made with the firmware's stock curl: several short samples per
-- direction, an idle ping, and a ping taken while the downlink is busy for
-- the bufferbloat delta.

local M = {}

local SPEEDTEST_CURVE_SIZE = 10
local CURL_MAX_TIME = 4
local SAMPLES_PER_DIRECTION = 3
local TOP_N = 2
local DOWNLOAD_BYTES = 50000000
local DOWNLOAD_URL = "https://speed.cloudflare.com/__down?bytes=" .. DOWNLOAD_BYTES
local UPLOAD_URL = "https://speed.cloudflare.com/__up"
local PING_HOST = "speed.cloudflare.com"
local PING_FALLBACK_MS = 1000.0

local function round_to(value, digits)
	local factor = 10 ^ (digits or 0)
	if value >= 0 then
		return math.floor(value * factor + 0.5) / factor
	end
	return math.ceil(value * factor - 0.5) / factor
end

local function now(ctx)
	return ctx.time.now()
end

local function push_curve_point(state, field, value)
	local key = field .. "_list"
	local points = state[key]
	if type(points) ~= "table" then
		points = {}
		state[key] = points
	end
	if #points >= SPEEDTEST_CURVE_SIZE then
		table.remove(points, 1)
	end
	points[#points + 1] = round_to(tonumber(value) or 0, 3)
end

local function reset(state)
	local generation = tonumber(state.speedtest and state.speedtest.generation) or 0
	state.speedtest = M.fresh_state()
	state.speedtest.generation = generation
end

local function fail(state, push_snapshot, log, reason)
	state.speedtest.state = "failed"
	state.speedtest.pids = {}
	push_snapshot()
	log.err("speedtest failed:", reason or "unknown error")
end

local function remember_pid(ctx, pid)
	if not pid then
		return
	end
	local pids = ctx.state.speedtest.pids
	if type(pids) ~= "table" then
		pids = {}
		ctx.state.speedtest.pids = pids
	end
	pids[#pids + 1] = pid
end

local function forget_pid(ctx, pid)
	local pids = ctx.state.speedtest.pids
	if type(pids) ~= "table" then
		return
	end
	for i = #pids, 1, -1 do
		if pids[i] == pid then
			table.remove(pids, i)
		end
	end
end

local function read_all(proc, timeout)
	if not proc then
		return ""
	end
	-- eco.reader:read("*a") returns as soon as one pipe buffer is ready on
	-- this lua-eco release, which truncated curl's -w output to its first
	-- byte. Read complete lines until EOF instead.
	local parts = {}
	for _ = 1, 512 do
		local line, err, partial = proc:read_stdout("*l", timeout)
		if line then
			parts[#parts + 1] = line
		elseif partial and "" ~= partial then
			parts[#parts + 1] = partial
			break
		else
			_ = err
			break
		end
	end
	proc:wait(1)
	proc:close()
	return table.concat(parts, "\n")
end

local function wait_process(proc, timeout)
	if not proc then
		return
	end
	proc:wait(timeout)
	proc:close()
end

local function spawn(ctx, ...)
	local proc, err = ctx.sys.exec(...)
	if not proc then
		return nil, err
	end
	remember_pid(ctx, proc.pid)
	return proc
end

local function parse_speed(value)
	value = tonumber(value)
	if not value or value <= 0 then
		return 0
	end
	return round_to(value * 8 / 1000000, 3)
end

local function parse_ping_avg(output)
	local avg = tostring(output or ""):match("round%-trip min/avg/max = [%d%.]+/([%d%.]+)/[%d%.]+")
	if avg then
		return tonumber(avg)
	end
	local sum, count = 0, 0
	for value in tostring(output or ""):gmatch("time=([%d%.]+)") do
		sum = sum + (tonumber(value) or 0)
		count = count + 1
	end
	if count > 0 then
		return sum / count
	end
	return nil
end

local function ping_once(ctx, timeout)
	local proc = spawn(ctx, "ping", "-c", "4", "-W", "1", PING_HOST)
	if not proc then
		return nil
	end
	local out = read_all(proc, timeout)
	forget_pid(ctx, proc.pid)
	return parse_ping_avg(out)
end

local function read_number_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local value = f:read("*l")
	f:close()
	os.remove(path)
	return tonumber(value)
end

local function wait_or_kill(ctx, proc, timeout)
	if not proc then
		return
	end
	local pid, status = proc:wait(timeout)
	if not pid then
		pcall(function()
			proc:kill()
		end)
		proc:wait(2)
	end
	proc:close()
end

local function download_sample(ctx, path)
	path = path or os.tmpname()
	local cmd = string.format(
		"curl -sS -L -o /dev/null --connect-timeout 8 --max-time %d " ..
		"-w '%%{speed_download}' '%s' > '%s' 2>/dev/null",
		CURL_MAX_TIME, DOWNLOAD_URL, path)
	local proc, err = spawn(ctx, "/bin/sh", "-c", cmd)
	if not proc then
		return nil, err
	end
	wait_or_kill(ctx, proc, CURL_MAX_TIME + 10)
	forget_pid(ctx, proc.pid)
	return read_number_file(path)
end

local function upload_sample(ctx)
	local path = os.tmpname()
	local cmd = string.format(
		"dd if=/dev/zero bs=1M count=32 2>/dev/null | " ..
		"curl -sS -o /dev/null --connect-timeout 8 --max-time %d " ..
		"-w '%%{speed_upload}' --data-binary @- '%s' > '%s' 2>/dev/null",
		CURL_MAX_TIME, UPLOAD_URL, path)
	local proc, err = spawn(ctx, "/bin/sh", "-c", cmd)
	if not proc then
		return nil, err
	end
	wait_or_kill(ctx, proc, CURL_MAX_TIME + 10)
	forget_pid(ctx, proc.pid)
	return read_number_file(path)
end

local function cancelled(ctx, generation)
	return ctx.state.speedtest.cancelled
		or ctx.state.speedtest.generation ~= generation
end

local function finish_stage(ctx, field, samples)
	local values = {}
	for _, value in ipairs(samples) do
		if value and value > 0 then
			values[#values + 1] = value
		end
	end
	if #values == 0 then
		return 0
	end
	table.sort(values, function(a, b) return a > b end)
	local n = math.min(TOP_N, #values)
	local sum = 0
	for i = 1, n do
		sum = sum + values[i]
	end
	return round_to(sum / n, 3)
end

local function run_test(ctx, generation)
	local state = ctx.state.speedtest
	local log = ctx.log

	log.info("speedtest start")
	if not ctx.command_exists or not ctx.command_exists("curl") then
		fail(ctx.state, ctx.push_snapshot, log, "curl not found")
		return
	end

	local idle = ping_once(ctx, 12)
	if cancelled(ctx, generation) then
		return
	end
	if idle then
		state.ping = round_to(idle, 3)
		ctx.push_snapshot()
		log.debug("speedtest idle ping=", state.ping)
	else
		state.ping = PING_FALLBACK_MS
	end

	local download_samples = {}
	local loaded
	for i = 1, SAMPLES_PER_DIRECTION do
		if cancelled(ctx, generation) then
			return
		end
		local value, err
		if 1 == i then
			-- The first sample doubles as the loaded-latency window: the
			-- ping runs while the downlink is busy, which is what the
			-- bufferbloat grade is supposed to describe.
			local path = os.tmpname()
			local cmd = string.format(
				"curl -sS -L -o /dev/null --connect-timeout 8 --max-time %d " ..
				"-w '%%{speed_download}' '%s' > '%s' 2>/dev/null",
				CURL_MAX_TIME, DOWNLOAD_URL, path)
			local proc, spawn_err = spawn(ctx, "/bin/sh", "-c", cmd)
			local ping_proc = spawn(ctx, "ping", "-c", "4", "-W", "1", PING_HOST)
			if not proc then
				value, err = nil, spawn_err
			else
				wait_or_kill(ctx, proc, CURL_MAX_TIME + 10)
				forget_pid(ctx, proc.pid)
				value = read_number_file(path)
				if ping_proc then
					local ping_out = read_all(ping_proc, 8)
					forget_pid(ctx, ping_proc.pid)
					loaded = parse_ping_avg(ping_out)
				end
			end
		else
			value, err = download_sample(ctx)
		end
		if err then
			log.err("speedtest download error:", err)
			fail(ctx.state, ctx.push_snapshot, log, err)
			return
		end
		if cancelled(ctx, generation) then
			return
		end
		local mbps = parse_speed(value)
		download_samples[#download_samples + 1] = mbps
		state.download = mbps
		push_curve_point(state, "download", mbps)
		ctx.push_snapshot()
	end

	if cancelled(ctx, generation) then
		return
	end
	local download = finish_stage(ctx, "download", download_samples)
	state.download = download
	state.download_done = true
	ctx.push_snapshot()

	local upload_samples = {}
	for i = 1, SAMPLES_PER_DIRECTION do
		if cancelled(ctx, generation) then
			return
		end
		local value, err = upload_sample(ctx)
		if err then
			log.err("speedtest upload error:", err)
			fail(ctx.state, ctx.push_snapshot, log, err)
			return
		end
		if cancelled(ctx, generation) then
			return
		end
		local mbps = parse_speed(value)
		upload_samples[#upload_samples + 1] = mbps
		state.upload = mbps
		push_curve_point(state, "upload", mbps)
		ctx.push_snapshot()
	end

	if cancelled(ctx, generation) then
		return
	end
	local upload = finish_stage(ctx, "upload", upload_samples)
	state.upload = upload
	state.upload_done = true

	if idle and loaded then
		local delta = math.max(0, loaded - idle)
		if delta < 5 then
			state.bufferbloat = "A+"
		elseif delta < 30 then
			state.bufferbloat = "A"
		elseif delta < 60 then
			state.bufferbloat = "B"
		elseif delta < 200 then
			state.bufferbloat = "C"
		elseif delta < 400 then
			state.bufferbloat = "D"
		else
			state.bufferbloat = "F"
		end
		log.info("speedtest bufferbloat, idle=", idle, " loaded=", loaded,
			" delta=", delta, " grade=", state.bufferbloat)
	else
		state.bufferbloat = ""
	end

	state.state = "success"
	state.pids = {}
	ctx.push_snapshot()
	log.info("speedtest success, down=", state.download, " up=", state.upload)
end

function M.fresh_state()
	return {
		state = "idle",
		download = 0,
		upload = 0,
		download_list = {},
		upload_list = {},
		download_done = false,
		upload_done = false,
		ping = 0,
		bufferbloat = "",
		enabled = false,
		cancelled = false,
		generation = 0,
		pids = {}
	}
end

function M.start(ctx)
	if not ctx.state.speedtest.enabled then
		return false, "speedtest is disabled"
	end
	if "running" == ctx.state.speedtest.state then
		return false, "speedtest is already running"
	end
	reset(ctx.state)
	ctx.state.speedtest.enabled = true
	ctx.state.speedtest.cancelled = false
	ctx.state.speedtest.generation = (tonumber(ctx.state.speedtest.generation) or 0) + 1
	ctx.state.speedtest.state = "running"
	ctx.push_snapshot()
	local generation = ctx.state.speedtest.generation
	ctx.eco.run(function()
		run_test(ctx, generation)
	end)
	return true
end

local function kill_pid(ctx, pid)
	if not pid or pid <= 0 then
		return
	end
	pcall(function()
		ctx.sys.kill(pid, ctx.sys.SIGTERM or 15)
		ctx.time.sleep(0.2)
		ctx.sys.kill(pid, ctx.sys.SIGKILL or 9)
	end)
end

function M.set_enabled(ctx, enable)
	enable = enable and true or false
	if not enable then
		local generation = (tonumber(ctx.state.speedtest.generation) or 0) + 1
		ctx.state.speedtest.cancelled = true
		ctx.state.speedtest.generation = generation
		local pids = ctx.state.speedtest.pids or {}
		for i = 1, #pids do
			kill_pid(ctx, pids[i])
		end
		-- Also catch a child that was spawned between the snapshot and the
		-- stopped-list check. The pattern is narrow enough not to touch
		-- anything but this daemon's own curl/ping children.
		pcall(function()
			local proc = ctx.sys.exec("/bin/sh", "-c",
				"for p in $(pgrep -f 'speed\\.cloudflare\\.com' 2>/dev/null); do kill -9 $p 2>/dev/null; done")
			if proc then
				proc:wait(2)
				proc:close()
			end
		end)
		ctx.state.speedtest = M.fresh_state()
		ctx.state.speedtest.generation = generation
		ctx.push_snapshot()
		ctx.log.info("speedtest disabled")
		return true
	end
	ctx.state.speedtest.enabled = true
	ctx.state.speedtest.cancelled = false
	ctx.log.info("speedtest enabled")
	return M.start(ctx)
end

return M
