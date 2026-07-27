-- GL SDK4 Plugins page compatibility for OpenWrt snapshots using apk.
-- The stock GL frontend still speaks its historical "plugins" JSON-RPC
-- API, while current OpenWrt replaced opkg with apk.  This adapter exposes
-- apk package/repository operations in the exact shapes consumed by the
-- unchanged frontend.

local cjson = require "cjson"

local DISTFEEDS = "/etc/apk/repositories.d/distfeeds.list"
local CUSTOMFEEDS = "/etc/apk/repositories.d/customfeeds.list"
local UPDATE_STAMP = "/etc/gl-oui-apk-last-update"

local function as_array(t)
	if next(t) == nil then return cjson.empty_array end
	return t
end

local function read_lines(path)
	local out = {}
	local f = io.open(path, "r")
	if not f then return out end
	for line in f:lines() do
		local value = line:match("^%s*(.-)%s*$")
		if value ~= "" and not value:match("^#") then table.insert(out, value) end
	end
	f:close()
	return out
end

local function command(cmd)
	local f = io.popen(cmd .. " 2>&1")
	if not f then return false, "unable to start apk" end
	local output = f:read("*a")
	local ok, _, status = f:close()
	return ok == true or status == 0, output
end

local function valid_package(name)
	return type(name) == "string"
		and name:match("^[%w%+%._@%-]+$") ~= nil
		and #name <= 128
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function package_rows()
	local ok, output = command("apk list -a")
	local rows = {}
	for line in output:gmatch("[^\r\n]+") do
		local name, version, arch = line:match("^(.+)%-([0-9][^ ]*) ([^ ]+) ")
		if name then
			local installed = line:find("%[installed%]", 1, false) ~= nil
			local row = rows[name]
			if not row or installed then
				rows[name] = {
					name = name, version = version, arch = arch,
					installed = installed,
				}
			end
		end
	end
	-- apk list -a may not have repository indexes yet.  Always merge the
	-- local installed database so the page remains useful before Refresh.
	local _, installed_output = command("apk list --installed")
	for line in installed_output:gmatch("[^\r\n]+") do
		local name, version, arch = line:match("^(.+)%-([0-9][^ ]*) ([^ ]+) ")
		if name then
			rows[name] = rows[name] or { name = name, version = version, arch = arch }
			rows[name].installed = true
		end
	end
	return rows
end

local protected = {
	["apk-mbedtls"] = true, ["base-files"] = true, busybox = true,
	dropbear = true, firewall4 = true, fstools = true, kernel = true,
	["gl-cellular"] = true, ["gl-mcu"] = true, ["gl-oui-rpc"] = true,
	["gl-oui-www"] = true, ["gl-repeater"] = true, libc = true,
	["mwan3"] = true, netifd = true, nginx = true, procd = true,
	ubus = true, uci = true, ucode = true, uhttpd = true,
}

local function counts(rows)
	local all, installed, missing, updatable, reserve = 0, 0, 0, 0, 0
	for name, row in pairs(rows) do
		all = all + 1
		if row.installed then
			installed = installed + 1
			if protected[name] then reserve = reserve + 1 end
		else
			missing = missing + 1
		end
	end
	return all, installed, missing, updatable, reserve
end

local function latest_repository_time()
	local f = io.open(UPDATE_STAMP, "r")
	if not f then return 0 end
	local value = tonumber(f:read("*l") or "0") or 0
	f:close()
	return value
end

local function mark_repository_updated()
	local f = io.open(UPDATE_STAMP, "w")
	if not f then return end
	f:write(tostring(os.time()), "\n")
	f:close()
end

return {
	get_repository_status = function()
		local rows = package_rows()
		local all, installed, missing, updatable, reserve = counts(rows)
		local updated = latest_repository_time()
		return {
			count_all = all,
			count_installed = installed,
			count_not_installed = missing,
			count_updatable = updatable,
			count_reserve = reserve,
			status = updated > 0 and 2 or 0,
			time_last_update = updated,
			time_current = os.time(),
		}
	end,

	update_repository = function()
		local ok, output = command("apk update")
		-- apk returns nonzero if any one feed is unavailable even when all
		-- other indexes were refreshed and it reports a usable package
		-- count. Treat that partial refresh as success; a total network/
		-- repository failure does not contain this completion line.
		if not ok and not output:match("%d+ distinct packages available") then
			return { err_code = -2, err_msg = output }
		end
		mark_repository_updated()
		return { info = output }
	end,

	get_list = function(args)
		args = args or {}
		local rows = package_rows()
		local packages = {}
		local wanted_status = tonumber(args.status) or 4
		local search = tostring(args.search_condition or ""):lower()
		local initial = tostring(args.search_initials or ""):lower()
		for name, row in pairs(rows) do
			local status = row.installed and (protected[name] and 3 or 1) or 0
			local matches_status = wanted_status == 4 or wanted_status == status
				or (wanted_status == 1 and row.installed)
				or (wanted_status == 3 and protected[name])
			local lname = name:lower()
			if matches_status
				and (search == "" or lname:find(search, 1, true))
				and (initial == "" or lname:sub(1, 1) == initial) then
				table.insert(packages, {
					name = name,
					version = row.version or "",
					status = status,
					uninstallable = row.installed and not protected[name],
					size = 0,
				})
			end
		end
		table.sort(packages, function(a, b) return a.name < b.name end)
		local count = #packages
		local limit = math.max(1, math.min(100, tonumber(args.limit) or 8))
		local page = math.max(1, tonumber(args.page) or 1)
		local first = (page - 1) * limit + 1
		local paged = {}
		for i = first, math.min(count, first + limit - 1) do
			table.insert(paged, packages[i])
		end
		local result = { packages = as_array(paged) }
		if search ~= "" or initial ~= "" then result.count_search = count end
		return result
	end,

	get_package_info = function(args)
		if not valid_package(args and args.name) then
			return { err_code = 1, err_msg = "invalid package name" }
		end
		local ok, output = command("apk info -a " .. shell_quote(args.name))
		-- apk may return nonzero when one unrelated repository cache is
		-- unavailable even though it successfully printed this package.
		if not ok and not output:match("\n?" .. args.name:gsub("([^%w])", "%%%1")
			.. "%-[^\n]+ description:") then
			return { err_code = 2, err_msg = output }
		end
		return { info = output }
	end,

	install_package = function(args)
		local names = args and args.name
		if type(names) == "string" then names = { names } end
		if type(names) ~= "table" or #names == 0 then
			return { err_code = 1, err_msg = "missing package name" }
		end
		local quoted = {}
		for _, name in ipairs(names) do
			if not valid_package(name) then
				return { err_code = 1, err_msg = "invalid package name" }
			end
			table.insert(quoted, shell_quote(name))
		end
		local ok, output = command("apk add " .. table.concat(quoted, " "))
		-- Like `apk update`, add can return nonzero for an unrelated broken
		-- feed after successfully committing the requested packages. Its
		-- final `OK: ... packages` line is the authoritative transaction
		-- result.
		local committed = output:match("^OK:%s+[%d%.]+%s+[%w]+%s+in%s+%d+%s+packages%s*$")
			or output:match("\nOK:%s+[%d%.]+%s+[%w]+%s+in%s+%d+%s+packages%s*$")
		if not ok and not committed then
			return { err_code = 2, err_msg = output }
		end
		return { info = output }
	end,

	remove_package = function(args)
		if not valid_package(args and args.name) then
			return { err_code = 1, err_msg = "invalid package name" }
		end
		if protected[args.name] then
			return { err_code = 3, err_msg = "system package cannot be removed" }
		end
		local force = args.force and " --force-broken-world" or ""
		local ok, output = command("apk del" .. force .. " " .. shell_quote(args.name))
		if not ok then return { err_code = 2, err_msg = output } end
		return { info = output }
	end,

	get_config = function()
		local source = {}
		for i, url in ipairs(read_lines(DISTFEEDS)) do
			table.insert(source, { name = "dist" .. i, url = url, system = true })
		end
		for i, url in ipairs(read_lines(CUSTOMFEEDS)) do
			table.insert(source, { name = "custom" .. i, url = url, system = false })
		end
		return { source = as_array(source) }
	end,

	set_config = function(args)
		local sources = args and args.source
		if type(sources) ~= "table" then
			return { err_code = 1, err_msg = "invalid sources" }
		end
		local lines = {}
		for _, source in ipairs(sources) do
			local url = source.url
			if type(url) ~= "string" or #url > 1024
				or not url:match("^https?://[^%s]+$") then
				return { err_code = 1, err_msg = "invalid repository URL" }
			end
			table.insert(lines, url)
		end
		local f = io.open(CUSTOMFEEDS, "w")
		if not f then return { err_code = 2, err_msg = "cannot write repositories" } end
		f:write(table.concat(lines, "\n"))
		if #lines > 0 then f:write("\n") end
		f:close()
		return { err_code = 0 }
	end,
}
