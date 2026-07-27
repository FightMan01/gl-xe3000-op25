-- "acl" RPC object: user/group access-control management.
--
-- Backed by UCI (/etc/config/gl-oui-acl), not GL's original SQLite scheme
-- (removes the missing lsqlite3-lua5.4 package problem and the
-- SQL-injection class of bug entirely rather than just patching it).
--
-- Account->group mapping additionally needs an actual Linux user to exist
-- (for /etc/shadow-based auth in gl-ngx-session) - creating those is left to
-- standard `useradd`-equivalent tooling, not duplicated here.
--
-- Not confirmed reachable from the real frontend - the "acl-view" screen
-- that seems like the obvious match actually calls
-- firewall.get_acl_rule_list/add_acl_rule/etc. (zone/traffic ACLs) plus
-- network.get_arp_list, not this object. Left in place as harmless,
-- functioning backend code.

local uci = require "uci"

local function group_exists(cursor, name)
	local found = false
	cursor:foreach("gl-oui-acl", "group", function(s)
		if s[".name"] == name then found = true end
	end)
	return found
end

return {
	get_group_list = function(args)
		local cursor = uci.cursor()
		local groups = {}
		cursor:foreach("gl-oui-acl", "group", function(s)
			table.insert(groups, { name = s[".name"], label = s.label, acl = s.acl or {} })
		end)
		return { groups = groups }
	end,

	add_group = function(args)
		local cursor = uci.cursor()
		if type(args.name) ~= "string" or args.name == "" or args.name == "root" then
			return { code = 1, message = "invalid group name" }
		end
		cursor:set("gl-oui-acl", args.name, "group")
		cursor:set("gl-oui-acl", args.name, "label", args.label or args.name)
		if type(args.acl) == "table" then
			cursor:set("gl-oui-acl", args.name, "acl", args.acl)
		end
		cursor:commit("gl-oui-acl")
		return {}
	end,

	remove_group = function(args)
		local cursor = uci.cursor()
		cursor:delete("gl-oui-acl", args.name)
		cursor:commit("gl-oui-acl")
		return {}
	end,

	get_acl_list = function(args)
		local cursor = uci.cursor()
		local acl = {}
		cursor:foreach("gl-oui-acl", "group", function(s)
			if s[".name"] == args.group then acl = s.acl or {} end
		end)
		return { acl = acl }
	end,

	add_acl = function(args)
		local cursor = uci.cursor()
		if not group_exists(cursor, args.group) then
			return { code = 1, message = "no such group" }
		end
		local acl = {}
		cursor:foreach("gl-oui-acl", "group", function(s)
			if s[".name"] == args.group then acl = s.acl or {} end
		end)
		table.insert(acl, args.entry)
		cursor:set("gl-oui-acl", args.group, "acl", acl)
		cursor:commit("gl-oui-acl")
		return {}
	end,

	remove_acl = function(args)
		local cursor = uci.cursor()
		local acl = {}
		cursor:foreach("gl-oui-acl", "group", function(s)
			if s[".name"] == args.group then
				for _, e in ipairs(s.acl or {}) do
					if e ~= args.entry then table.insert(acl, e) end
				end
			end
		end)
		cursor:set("gl-oui-acl", args.group, "acl", acl)
		cursor:commit("gl-oui-acl")
		return {}
	end,

	get_user_list = function(args)
		local cursor = uci.cursor()
		local users = {}
		cursor:foreach("gl-oui-acl", "account", function(s)
			table.insert(users, { username = s.username, group = s.group })
		end)
		return { users = users }
	end,

	add_user = function(args)
		local cursor = uci.cursor()
		if not group_exists(cursor, args.group) then
			return { code = 1, message = "no such group" }
		end
		cursor:set("gl-oui-acl", args.username, "account")
		cursor:set("gl-oui-acl", args.username, "username", args.username)
		cursor:set("gl-oui-acl", args.username, "group", args.group)
		cursor:commit("gl-oui-acl")
		return {}
	end,

	remove_user = function(args)
		local cursor = uci.cursor()
		cursor:delete("gl-oui-acl", args.username)
		cursor:commit("gl-oui-acl")
		return {}
	end,
}
