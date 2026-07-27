-- GL SDK4 NAS page compatibility adapter backed by OpenWrt's upstream
-- ksmbd-server package.
--
-- Deliberately conservative defaults:
--   * the service is disabled until the user enables Samba;
--   * no storage is shared automatically;
--   * only mounted directories below /mnt may be shared;
--   * SMB is LAN-only (the upstream service binds to the "lan" network).

local cjson = require "cjson"
local uci = require "uci"

local function array(value)
	if type(value) == "table" and next(value) == nil then
		return cjson.empty_array
	end
	return value
end

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function command_output(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	if not pipe then return "" end
	local data = pipe:read("*a") or ""
	pipe:close()
	return data
end

local function command_ok(command)
	local rc = os.execute(command .. " >/dev/null 2>&1")
	return rc == true or rc == 0
end

local function available()
	local function file_exists(path)
		local file = io.open(path, "rb")
		if not file then return false end
		file:close()
		return true
	end

	local release_file = io.open("/proc/sys/kernel/osrelease", "r")
	if not release_file then return false end
	local release = (release_file:read("*l") or ""):match("^%s*(.-)%s*$")
	release_file:close()
	if release == "" or not file_exists("/usr/sbin/ksmbd.mountd") then
		return false
	end

	local module = "/lib/modules/" .. release .. "/ksmbd.ko"
	return file_exists(module)
		or file_exists(module .. ".gz")
		or file_exists(module .. ".zst")
end

local function service_enabled()
	return command_ok("/etc/init.d/ksmbd enabled")
end

local function service_running()
	return command_output("pgrep -x ksmbd.mountd"):match("%d+") ~= nil
end

local function mounted_partitions()
	local result = {}
	local mounts = io.open("/proc/mounts", "r")
	if not mounts then return result end
	for line in mounts:lines() do
		local device, mountpoint, filesystem =
			line:match("^(%S+)%s+(%S+)%s+(%S+)")
		if device and mountpoint and filesystem
			and mountpoint:match("^/mnt/[^/]+$")
			and device:match("^/dev/") then
			local stat = command_output("df -k " .. shell_quote(mountpoint) .. " | tail -n 1")
			local total, free = stat:match("%S+%s+(%d+)%s+%d+%s+(%d+)")
			local info = command_output("block info " .. shell_quote(device))
			result[#result + 1] = {
				device = device,
				dev_name = device:match("([^/]+)$") or device,
				mountpoint = mountpoint,
				disk_name = mountpoint:match("([^/]+)$") or "",
				fs_type = (info:match('TYPE="([^"]+)"') or filesystem):upper(),
				uid = info:match('UUID="([^"]+)"') or "",
				label = info:match('LABEL="([^"]+)"') or "",
				total_len = math.floor((tonumber(total) or 0) / 1024),
				free_size = math.floor((tonumber(free) or 0) / 1024),
			}
		end
	end
	mounts:close()
	table.sort(result, function(a, b) return a.dev_name < b.dev_name end)
	return result
end

local function resolve_virtual_path(path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
		return nil
	end
	local first, rest = path:match("^/([^/]+)(.*)$")
	if not first or rest:find("%.%.", 1, true) then return nil end
	for _, part in ipairs(mounted_partitions()) do
		if first == part.disk_name then
			local candidate = part.mountpoint .. rest
			local canonical = command_output("readlink -f " .. shell_quote(candidate))
				:gsub("%s+$", "")
			if canonical == part.mountpoint
			or canonical:sub(1, #part.mountpoint + 1) == part.mountpoint .. "/" then
				return canonical, part, "/" .. first .. rest
			end
		end
	end
	return nil
end

local function virtual_path(real)
	for _, part in ipairs(mounted_partitions()) do
		if real == part.mountpoint then return "/" .. part.disk_name, part end
		if real:sub(1, #part.mountpoint + 1) == part.mountpoint .. "/" then
			return "/" .. part.disk_name .. real:sub(#part.mountpoint + 1), part
		end
	end
	return nil
end

local function valid_user(name)
	return type(name) == "string" and #name >= 1 and #name <= 32
		and name:match("^[%w_.%-]+$") ~= nil
end

local function valid_password(password)
	return type(password) == "string" and #password >= 1 and #password <= 128
		and not password:find("\0", 1, true)
end

local function normalize_proto(proto)
	-- Older SDK4 NAS bundles encode Samba as enum 1 while newer bundles send
	-- the literal string "samba".  Both forms describe the same service.
	if proto == nil or proto == "" or proto == "samba"
		or proto == 1 or proto == "1" then
		return "samba"
	end
	return tostring(proto)
end

local function reload_service()
	if service_enabled() then
		return command_ok("/etc/init.d/ksmbd restart")
	end
	return true
end

local function share_result(section)
	local real = section.path or ""
	local shown, disk = virtual_path(real)
	local users = {}
	for name in tostring(section.users or ""):gmatch("%S+") do
		users[#users + 1] = {
			name = name,
			readonly = tostring(section.write_list or ""):find(name, 1, true) and 0 or 1,
		}
	end
	local attr = command_output("stat -c '%Y %s' " .. shell_quote(real))
	local changed, length = attr:match("^(%d+)%s+(%d+)")
	local readonly = section.read_only == "yes"
	local public = section.guest_ok == "yes"
	return {
		n = shown or real,
		owner_readonly = readonly and 1 or 0,
		share_id = section[".name"],
		t = "d",
		share_time = tonumber(changed) or 0,
		d = tonumber(changed) or 0,
		l = tonumber(length) or 0,
		file_ok = shown and command_ok("test -d " .. shell_quote(real)) and 1 or 0,
		disk_uid = disk and disk.uid or "",
		protos = {
			{
				name = "samba",
				enable = 1,
				public = public and 1 or 0,
				public_readonly = readonly and 1 or 0,
				share_name = section.name or section[".name"],
				users = array(users),
			},
		},
	}
end

local function save_share(args, existing)
	args = args or {}
	args.proto = normalize_proto(args.proto)
	if args.proto ~= "samba" then
		return nil, "only Samba is supported"
	end
	local real, _, shown
	if existing then
		local cursor = uci.cursor()
		real = cursor:get("ksmbd", existing, "path")
		cursor:close()
		shown = real and virtual_path(real)
	else
		real, _, shown = resolve_virtual_path(args.file)
	end
	if not real or not shown or not command_ok("test -d " .. shell_quote(real)) then
		return nil, "share path must be an existing directory below /mnt"
	end

	local share_name = args.share_name or real:match("([^/]+)$") or "Storage"
	share_name = share_name:gsub("[^%w_.%-]", "_"):sub(1, 64)
	if share_name == "" then share_name = "Storage" end
	local cursor = uci.cursor()
	local section = existing
	if not section then
		-- Treat browser retries as updates.  The SDK may replay add_share
		-- after a slow service restart, and duplicate paths make ksmbd reject
		-- its generated configuration.
		cursor:foreach("ksmbd", "share", function(candidate)
			if not section and candidate.path == real then
				section = candidate[".name"]
			end
		end)
		if not section then section = cursor:add("ksmbd", "share") end
	end
	local changed = not existing and cursor:get("ksmbd", section, "name") == nil
	local function set_option(option, value)
		if cursor:get("ksmbd", section, option) ~= value then
			cursor:set("ksmbd", section, option, value)
			changed = true
		end
	end
	local function delete_option(option)
		if cursor:get("ksmbd", section, option) ~= nil then
			cursor:delete("ksmbd", section, option)
			changed = true
		end
	end

	set_option("name", share_name)
	set_option("path", real)
	set_option("browseable", "yes")
	set_option("read_only",
		tonumber(args.public_readonly or args.readonly) == 1 and "yes" or "no")
	set_option("guest_ok", tonumber(args.public) == 1 and "yes" or "no")
	set_option("create_mask", "0664")
	set_option("dir_mask", "0775")
	set_option("force_root", "1")

	local users, writable = {}, {}
	if type(args.users) == "table" then
		-- Some SDK4 builds send one object while newer builds send an array.
		local list = args.users.name and { args.users } or args.users
		for _, item in ipairs(list) do
			if type(item) == "table" and valid_user(item.name) then
				users[#users + 1] = item.name
				if tonumber(item.readonly) ~= 1 then writable[#writable + 1] = item.name end
			end
		end
	end
	if #users > 0 then
		set_option("users", table.concat(users, " "))
	else
		delete_option("users")
	end
	if #writable > 0 then
		set_option("write_list", table.concat(writable, " "))
	else
		delete_option("write_list")
	end
	if changed then cursor:commit("ksmbd") end
	cursor:close()
	-- The SDK can replay add_share after a slow response.  A hard KSMBD
	-- restart disconnects every active SMB client, so do not restart when
	-- the requested share is already identical to the persisted one.
	if changed and not reload_service() then return nil, "ksmbd failed to restart" end
	return section
end

return {
	get_status = function()
		if not available() then
			-- The stock page auto-starts NAS whenever enable is zero, but
			-- never clears its processing overlay when start returns an
			-- application-level error.  Report the compatibility adapter
			-- itself as initialized while exposing `supported = 0`; menu
			-- capability detection in system.get_info hides this page in
			-- normal navigation until the matching kernel module exists.
			return { enable = 1, supported = 0 }
		end
		return {
			enable = service_enabled() and service_running() and 1 or 0,
			supported = 1,
		}
	end,

	start = function(args)
		if not available() then
			return { err_code = 2, err_msg = "ksmbd is unavailable for the running kernel" }
		end
		local enable = not (args and (args.enable == false or tonumber(args.enable) == 0))
		if enable then
			command_ok("/etc/init.d/ksmbd enable")
			if not command_ok("/etc/init.d/ksmbd restart") then
				return { err_code = 2, err_msg = "ksmbd failed to start" }
			end
		else
			command_ok("/etc/init.d/ksmbd stop")
			command_ok("/etc/init.d/ksmbd disable")
		end
		return {}
	end,

	get_proto_config = function()
		return {
			res = {
				{
					name = "samba",
					enable = service_enabled() and 1 or 0,
					port = 445,
					wan_access = false,
					share_type = 1,
				},
			},
		}
	end,

	set_proto_config = function(args)
		args = args or {}
		-- SDK4 submits the complete service list as { protos = { ... } };
		-- older builds submit a single service object directly.
		if type(args.protos) == "table" then
			local first = args.protos[1]
			if not first and args.protos.name then first = args.protos end
			args = first or {}
		end
		if normalize_proto(args.name) ~= "samba" then
			return { err_code = 1, err_msg = "only Samba is supported" }
		end
		if args.wan_access == true or tonumber(args.wan_access) == 1 then
			return { err_code = 1, err_msg = "WAN SMB access is intentionally disabled" }
		end
		if args.enable == true or tonumber(args.enable) == 1 then
			command_ok("/etc/init.d/ksmbd enable")
			if not command_ok("/etc/init.d/ksmbd restart") then
				return { err_code = 2, err_msg = "ksmbd failed to start" }
			end
		else
			command_ok("/etc/init.d/ksmbd stop")
			command_ok("/etc/init.d/ksmbd disable")
		end
		return {}
	end,

	get_user_list = function()
		local cursor, list = uci.cursor(), {}
		cursor:foreach("gl-ksmbd-user", "user", function(section)
			list[#list + 1] = { name = section.name or section[".name"], password = "" }
		end)
		cursor:close()
		table.sort(list, function(a, b) return a.name < b.name end)
		return { list = array(list) }
	end,

	add_user = function(args)
		args = args or {}
		if not valid_user(args.name) or not valid_password(args.password) then
			return { err_code = 1, err_msg = "invalid user name or password" }
		end
		local cursor = uci.cursor()
		if cursor:get("gl-ksmbd-user", args.name) then
			cursor:close()
			return { err_code = 1, err_msg = "user already exists" }
		end
		if not command_ok("/usr/sbin/ksmbd.adduser --add --password " ..
			shell_quote(args.password) .. " " .. shell_quote(args.name)) then
			cursor:close()
			return { err_code = 2, err_msg = "unable to add SMB user" }
		end
		cursor:set("gl-ksmbd-user", args.name, "user")
		cursor:set("gl-ksmbd-user", args.name, "name", args.name)
		cursor:commit("gl-ksmbd-user")
		cursor:close()
		return {}
	end,

	set_user_pwd = function(args)
		args = args or {}
		if not valid_user(args.name) or not valid_password(args.password) then
			return { err_code = 1, err_msg = "invalid user name or password" }
		end
		if not command_ok("/usr/sbin/ksmbd.adduser --update --password " ..
			shell_quote(args.password) .. " " .. shell_quote(args.name)) then
			return { err_code = 2, err_msg = "unable to update SMB user" }
		end
		return {}
	end,

	remove_user = function(args)
		args = args or {}
		local cursor = uci.cursor()
		if args.all then
			cursor:foreach("gl-ksmbd-user", "user", function(section)
				command_ok("/usr/sbin/ksmbd.adduser --delete " ..
					shell_quote(section.name or section[".name"]))
				cursor:delete("gl-ksmbd-user", section[".name"])
			end)
		elseif valid_user(args.name) then
			command_ok("/usr/sbin/ksmbd.adduser --delete " .. shell_quote(args.name))
			cursor:delete("gl-ksmbd-user", args.name)
		else
			cursor:close()
			return { err_code = 1, err_msg = "invalid user name" }
		end
		cursor:commit("gl-ksmbd-user")
		cursor:close()
		return {}
	end,

	get_disk_list = function()
		local partitions, groups = mounted_partitions(), {}
		for _, part in ipairs(partitions) do
			local base = part.dev_name:gsub("p?%d+$", "")
			groups[base] = groups[base] or { part_num = 0, sd_card = 0, part = {} }
			local group = groups[base]
			group.part_num = group.part_num + 1
			group.part[#group.part + 1] = {
				dev_name = part.dev_name,
				disk_name = part.disk_name,
				fs_type = part.fs_type,
				uid = part.uid,
				label = part.label,
				total_len = part.total_len,
				free_size = part.free_size,
			}
		end
		local disks = {}
		for _, group in pairs(groups) do disks[#disks + 1] = group end
		return { disk_number = #disks, disk = array(disks) }
	end,

	eject_disk = function(args)
		local name = args and args.dev_name
		if type(name) ~= "string" or not name:match("^[%w_.%-]+$") then
			return { err_code = 1, err_msg = "invalid device" }
		end
		for _, part in ipairs(mounted_partitions()) do
			if part.dev_name == name then
				if command_ok("umount " .. shell_quote(part.mountpoint)) then return {} end
				return { err_code = 2, err_msg = "device is busy" }
			end
		end
		return { err_code = 1, err_msg = "device is not mounted" }
	end,

	get_file_list = function(args)
		local requested = args and args.path
		-- The SDK4 folder picker starts at an empty virtual path and expects
		-- one directory node per mounted partition.  Returning an empty list
		-- here leaves the modal completely blank, even though get_disk_list
		-- correctly shows the drives behind it.
		if requested == nil or requested == "" or requested == "/" then
			local files = {}
			for _, part in ipairs(mounted_partitions()) do
				files[#files + 1] = {
					n = "/" .. part.disk_name,
					d = 0,
					l = 0,
					t = "d",
					have_dir = 1,
					disk_uid = part.uid,
				}
			end
			return { files = array(files) }
		end

		local real, _, shown = resolve_virtual_path(requested)
		if not real or not command_ok("test -d " .. shell_quote(real)) then
			return { files = cjson.empty_array }
		end
		local files = {}
		local pipe = io.popen("find " .. shell_quote(real) ..
			" -mindepth 1 -maxdepth 1 -type d 2>/dev/null")
		if pipe then
			for child in pipe:lines() do
				local name = child:match("([^/]+)$")
				if name and name ~= "." and name ~= ".." then
					local stat = command_output("stat -c '%Y %s' " .. shell_quote(child))
					local changed, length = stat:match("^(%d+)%s+(%d+)")
					files[#files + 1] = {
						n = shown .. "/" .. name,
						d = tonumber(changed) or 0,
						l = tonumber(length) or 0,
						t = "d",
						have_dir = 1,
					}
				end
			end
			pipe:close()
		end
		return { files = array(files) }
	end,

	get_share_list = function()
		local cursor, shares = uci.cursor(), {}
		cursor:foreach("ksmbd", "share", function(section)
			shares[#shares + 1] = share_result(section)
		end)
		cursor:close()
		return { result_code = 0, share = array(shares) }
	end,

	add_share = function(args)
		local section, err = save_share(args, nil)
		return section and {} or { err_code = 1, err_msg = err }
	end,

	set_share = function(args)
		local id = args and args.share_id
		if type(id) ~= "string" or not id:match("^[%w_%-]+$") then
			return { err_code = 1, err_msg = "invalid share ID" }
		end
		local cursor = uci.cursor()
		local exists = cursor:get("ksmbd", id) ~= nil
		cursor:close()
		if not exists then return { err_code = 1, err_msg = "share not found" } end
		local section, err = save_share(args, id)
		return section and {} or { err_code = 1, err_msg = err }
	end,

	remove_share = function(args)
		local id = args and args.share_id
		if type(id) ~= "string" or not id:match("^[%w_%-]+$") then
			return { err_code = 1, err_msg = "invalid share ID" }
		end
		local cursor = uci.cursor()
		cursor:delete("ksmbd", id)
		cursor:commit("ksmbd")
		cursor:close()
		reload_service()
		return {}
	end,
}
