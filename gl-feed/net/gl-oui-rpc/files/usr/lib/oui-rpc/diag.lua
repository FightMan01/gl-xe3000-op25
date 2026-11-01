-- "diag" RPC object: the small network-diagnosis surface GoodCloud uses for
-- its latency test (base.rpc -> diag.ping) and the local UI can use.
--
-- Addresses are validated before they reach the shell. The allowed
-- character sets are exactly the IPv4/domain sets below, so no shell
-- metacharacter can be injected through `addr`.

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function valid_ipv4(ip)
	if not ip:match("^%d+%.%d+%.%d+%.%d+$") then return false end
	for octet in ip:gmatch("%d+") do
		local n = tonumber(octet)
		if n > 255 then return false end
	end
	return true
end

local function valid_domain(domain)
	if #domain < 1 or #domain > 253 then return false end
	if domain:find("[^%w%-%.]") then return false end
	if domain:sub(1, 1) == "." or domain:sub(-1) == "." then return false end
	if domain:find("%.%.") then return false end
	local labels = 0
	for label in domain:gmatch("[^%.]+") do
		labels = labels + 1
		local len = #label
		if len < 1 or len > 63 then return false end
		if label:find("^%-") or label:find("%-$") then return false end
		if not label:find("^[%w][%w%-]*$") then return false end
	end
	return labels >= 2
end

local function run(command)
	local pipe = io.popen(command .. " 2>&1")
	if not pipe then return "" end
	local output = pipe:read("*a") or ""
	pipe:close()
	return trim(output)
end

return {
	ping = function(args)
		args = args or {}
		local addr = trim(args.addr)
		if not valid_ipv4(addr) and not valid_domain(addr) then
			return { ping_result = "ip address is not correct" }
		end
		local output = run("ping -c4 " .. addr)
		if output == "" then output = "destination host unreachable" end
		return { ping_result = output .. "\n" }
	end,

	traceroute = function(args)
		local addr = address(args)
		if not valid_ipv4(addr) and not valid_domain(addr) then
			return { trace_result = "ip address is not correct" }
		end
		local output = run("traceroute -4 -q 1 -w 1 -n " .. addr)
		if output == "" then output = "destination host unreachable" end
		return { trace_result = output .. "\n" }
	end,
}
