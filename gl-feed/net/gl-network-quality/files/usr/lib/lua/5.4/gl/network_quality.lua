local M = {}
local uci = require("eco.uci")
local time = require("eco.time")
local log = require("eco.log")
local cjson = require("cjson")
local sys = require("eco.sys")
local eco = require("eco")
local speedtest_lib = require("gl.network_quality_speedtest")
local HISTORY_SIZE = 30
local MINUTE_WINDOW = 60
local FIRST_MINUTE_WINDOW = 5
local REALTIME_RTT_WINDOW_SIZE = 60
local SNAPSHOT_PATH = "/var/run/network-quality.json"
local WEBSOCKET_EVENT = "network_quality.status"
local ETHERNET_PING_SCRIPT = "/usr/bin/network-quality-ethernet-ping"
local WAN_PING_SCRIPT = "/usr/bin/network-quality-wan-ping"
local DNS_LOOKUP_SCRIPT = "/usr/bin/network-quality-dns-lookup"
local RELIABILITY_EXP_DECAY = 0.7
local UBUS, STATE, calc_score, calc_packet_loss_percent, calc_reliability_status_label
local STATUS_UNKNOWN = -1
local STATUS_GOOD = 0
local STATUS_WARN = 1
local STATUS_BAD = 2

local function clamp(value, minv, maxv)
  if value < minv then
    return minv
  end
  if maxv < value then
    return maxv
  end
  return value
end

local function round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

local function round_to(value, digits)
  local factor = 10 ^ (digits or 0)
  if value >= 0 then
    return math.floor(value * factor + 0.5) / factor
  end
  return math.ceil(value * factor - 0.5) / factor
end

local function ping_timeout_ms()
  local timeout = STATE and STATE.config and STATE.config.ping_timeout or 1
  return math.max(1, tonumber(timeout) or 1) * 1000
end

local function dns_timeout_ms()
  local timeout = STATE and STATE.config and STATE.config.dns_timeout or 1
  return math.max(1, tonumber(timeout) or 1) * 1000
end

local function copy_array(arr)
  local out = {}
  for i = 1, #arr do
    out[i] = arr[i]
  end
  return out
end

local function padded_array(arr, size, fill)
  local out = {}
  local missing = size - #arr
  local idx = 1
  while missing >= idx do
    out[#out + 1] = fill
    idx = idx + 1
  end
  for i = 1, #arr do
    out[#out + 1] = arr[i]
  end
  return out
end

local function speedtest_curve_array(arr, size, fill, done)
  local out = {}
  local start = math.max(1, #arr - size + 1)
  local fallback = round_to(tonumber(fill) or 0, 3)
  for i = start, #arr do
    out[#out + 1] = round_to(tonumber(arr[i]) or 0, 3)
  end
  while size > #out do
    if done then
      out[#out + 1] = fallback
    else
      out[#out + 1] = -1
    end
  end
  return out
end

local function shell_quote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function exec_capture(command)
  local wrapped = string.format("{ %s; __rc=$?; printf '\\n__RC:%%s\\n' \"$__rc\"; }", command)
  local handle = io.popen(wrapped, "r")
  if not handle then
    return "", 127
  end
  local output = handle:read("*a") or ""
  handle:close()
  local body, rc = output:match([[
^(.*)
__RC:(%-?%d+)
?$]])
  if not rc then
    return output, 1
  end
  return body, tonumber(rc)
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function read_first_line(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local line = f:read("*l")
  f:close()
  return line
end

local function get_device_country_code()
  return read_first_line("/proc/gl-hw-info/country_code") or ""
end

local function read_preset_targets(c)
  local items = c:get("network-quality", "global", "preset_target") or {}
  if type(items) ~= "table" then
    items = { items }
  end
  local result = {}
  for _, item in ipairs(items) do
    local name, value = tostring(item):match("^([^=]+)=(.+)$")
    if name and value then
      result[name] = value
    end
  end
  return result
end

local function load_config()
  local c = uci.cursor()
  local preset = read_preset_targets(c)
  local country = get_device_country_code()
  local target = "CN" == country and (preset.baidu or "baidu.com") or preset.google or "google.com"
  local cfg = {
    enabled = c:get("network-quality", "global", "enabled") == "1",
    log = c:get("network-quality", "global", "log") or "INFO",
    ethernet_ping_address = c:get("network-quality", "global", "ethernet_ping_address") or target,
    dns_probe_domain = c:get("network-quality", "global", "dns_probe_domain") or target,
    ping_interval = tonumber(c:get("network-quality", "global", "ping_interval") or "1") or 1,
    dns_interval = tonumber(c:get("network-quality", "global", "dns_interval") or "3") or 3,
    minute_window = MINUTE_WINDOW,
    dns_timeout = tonumber(c:get("network-quality", "global", "dns_timeout") or "3") or 3,
    ping_timeout = tonumber(c:get("network-quality", "global", "ping_timeout") or "1") or 1,
    speedtest_download_bytes = tonumber(c:get("network-quality", "global", "speedtest_download_bytes") or "1073741824") or 1073741824,
    speedtest_download_interval = tonumber(c:get("network-quality", "global", "speedtest_download_interval") or "0.2") or 0.2,
    speedtest_download_concurrency = tonumber(c:get("network-quality", "global", "speedtest_download_concurrency") or "4") or 4,
    speedtest_upload_bytes = tonumber(c:get("network-quality", "global", "speedtest_upload_bytes") or "1073741824") or 1073741824,
    speedtest_upload_interval = tonumber(c:get("network-quality", "global", "speedtest_upload_interval") or "0.5") or 0.5,
    speedtest_upload_concurrency = tonumber(c:get("network-quality", "global", "speedtest_upload_concurrency") or "2") or 2,
    country_code = country
  }
  log.debug("load config:", cjson.encode({
    enabled = cfg.enabled,
    log = cfg.log,
    ethernet_ping_address = cfg.ethernet_ping_address,
    dns_probe_domain = cfg.dns_probe_domain,
    ping_interval = cfg.ping_interval,
    dns_interval = cfg.dns_interval
  }))
  return cfg
end

local function apply_log_level(level)
  level = tostring(level or "INFO"):upper()
  if type(log[level]) ~= "number" then
    log.err("invalid log level:", level)
    return
  end
  log.set_level(log[level])
  log.info("set log level:", level)
end

local function fresh_minute()
  return {
    internet_rtts = {},
    success_count = 0,
    fail_count = 0
  }
end

local function fresh_state(config)
  return {
    config = config or load_config(),
    current = {
      wan_gateway_latency = -1,
      internet_latency = -1,
      dns_lookup_latency = -1,
      typical = -1,
      worst = -1,
      jitter = 0,
      upload_rate_current = 0,
      download_rate_current = 0,
      total_rate_current = 0,
      responsiveness_score = 0,
      reliability_score = 0,
      score = 0
    },
    history = {
      reliability_status = {},
      reliability_packet_loss = {},
      upload_rate_realtime = {},
      download_rate_realtime = {},
      online_points = {},
      loss_percent_points = {}
    },
    realtime = {
      internet_rtts = {}
    },
    resolved = {ethernet_target_ip = nil, dns_target_ip = nil},
    minute = fresh_minute(),
    rate_last = {},
    speedtest = speedtest_lib.fresh_state(),
    workers_started = false,
    bootstrap_minute_pending = true
  }
end

local function save_snapshot(snapshot)
  local f = io.open(SNAPSHOT_PATH, "w")
  if not f then
    return
  end
  f:write(cjson.encode(snapshot))
  f:close()
end

local function display_number(value, digits)
  local n = tonumber(value)
  if nil == n then
    return value
  end
  return round_to(n, digits or 0)
end

local function snapshot_payload()
  return {
    score = STATE.current.score,
    responsiveness = {
      score = STATE.current.responsiveness_score,
      wan_gateway_latency = STATE.current.wan_gateway_latency,
      internet_latency = STATE.current.internet_latency,
      dns_lookup_latency = STATE.current.dns_lookup_latency,
      typical_latency = STATE.current.typical,
      worst_latency = STATE.current.worst,
      jitter_latency = STATE.current.jitter
    },
    rate = {
      download_current = STATE.current.download_rate_current,
      upload_current = STATE.current.upload_rate_current,
      total_current = STATE.current.total_rate_current,
      download_list = padded_array(STATE.history.download_rate_realtime, HISTORY_SIZE, 0),
      upload_list = padded_array(STATE.history.upload_rate_realtime, HISTORY_SIZE, 0)
    },
    reliability = {
      score = STATE.current.reliability_score,
      status = padded_array(STATE.history.reliability_status, HISTORY_SIZE, STATUS_UNKNOWN),
      packet_loss = padded_array(STATE.history.reliability_packet_loss, HISTORY_SIZE, STATUS_UNKNOWN),
      status_label = calc_reliability_status_label(),
      packet_loss_percent = display_number(calc_packet_loss_percent(), 2)
    },
    speedtest = {
      state = STATE.speedtest.state,
      download = display_number(STATE.speedtest.download, 3),
      upload = display_number(STATE.speedtest.upload, 3),
      download_list = speedtest_curve_array(STATE.speedtest.download_list or {}, 10, STATE.speedtest.download, STATE.speedtest.download_done),
      upload_list = speedtest_curve_array(STATE.speedtest.upload_list or {}, 10, STATE.speedtest.upload, STATE.speedtest.upload_done),
      ping = display_number(STATE.speedtest.ping, 3),
      bufferbloat = STATE.speedtest.bufferbloat
    }
  }
end

local function push_snapshot()
  if not UBUS or not STATE then
    return
  end
  local payload = snapshot_payload()
  save_snapshot(payload)
  pcall(function()
    UBUS:call("gl-session", "notify", { name = WEBSOCKET_EVENT, data = payload })
  end)
end

local function push_window(arr, value)
  if #arr >= HISTORY_SIZE then
    table.remove(arr, 1)
  end
  arr[#arr + 1] = value
end

local function push_window_limit(arr, value, limit)
  if limit <= #arr then
    table.remove(arr, 1)
  end
  arr[#arr + 1] = value
end

local function sort_copy(arr)
  local t = copy_array(arr)
  table.sort(t)
  return t
end

local function calc_median(arr)
  if 0 == #arr then
    return -1
  end
  local t = sort_copy(arr)
  if 1 == #t then
    return round(t[1])
  end
  if 2 == #t then
    return round((t[1] + t[2]) / 2)
  end
  local mid = math.floor(#t / 2) + 1
  if 1 == #t % 2 then
    return round(t[mid])
  end
  return round((t[mid - 1] + t[mid]) / 2)
end

local function calc_second_worst(arr)
  if 0 == #arr then
    return -1
  end
  local t = sort_copy(arr)
  if 1 == #t then
    return round(t[1])
  end
  if 2 == #t then
    return round(t[2])
  end
  return round(t[#t - 1])
end

local function calc_avg_abs_delta(arr)
  if #arr < 2 then
    if 0 == #arr then
      return 0
    end
    return 0
  end
  local filtered = arr
  if #arr >= 3 then
    local max_index = 1
    for i = 2, #arr do
      if arr[i] > arr[max_index] then
        max_index = i
      end
    end
    filtered = {}
    for i = 1, #arr do
      if i ~= max_index then
        filtered[#filtered + 1] = arr[i]
      end
    end
  end
  local deltas = {}
  for i = 2, #filtered do
    deltas[#deltas + 1] = math.abs(filtered[i] - filtered[i - 1])
  end
  if #deltas <= 1 then
    return round(deltas[1] or 0)
  end
  local sum = 0
  for i = 1, #deltas do
    sum = sum + deltas[i]
  end
  return round(sum / #deltas)
end

local function calc_loss_percent(success_count, fail_count)
  local total = success_count + fail_count
  if total <= 0 then
    return 100
  end
  return fail_count / total * 100
end

local function calc_online_ratio(success_count, fail_count)
  local total = success_count + fail_count
  if total <= 0 then
    return 0
  end
  return success_count / total
end

local function interpolate_anchors(value, anchors)
  if value <= anchors[1][1] then
    return anchors[1][2]
  end
  if value >= anchors[#anchors][1] then
    return anchors[#anchors][2]
  end
  for i = 1, #anchors - 1 do
    local x1 = anchors[i][1]
    local y1 = anchors[i][2]
    local x2 = anchors[i + 1][1]
    local y2 = anchors[i + 1][2]
    if value >= x1 and value <= x2 then
      local ratio = (value - x1) / (x2 - x1)
      return y1 + ratio * (y2 - y1)
    end
  end
  return anchors[#anchors][2]
end

local function score_latency(latency)
  if not latency or latency < 0 then
    return 0
  end
  local anchors = {
    {20, 100},
    {50, 90},
    {100, 75},
    {200, 50},
    {400, 20},
    {800, 0}
  }
  return clamp(round(interpolate_anchors(latency, anchors)), 0, 100)
end

local function score_jitter(jitter)
  local anchors = {
    {2, 100},
    {10, 85},
    {30, 60},
    {60, 35},
    {120, 10},
    {250, 0}
  }
  return clamp(round(interpolate_anchors(jitter, anchors)), 0, 100)
end

local function score_dns(latency)
  if not latency or latency < 0 then
    return 0
  end
  local anchors = {
    {20, 100},
    {50, 85},
    {100, 65},
    {200, 35},
    {400, 10},
    {800, 0}
  }
  return clamp(round(interpolate_anchors(latency, anchors)), 0, 100)
end

local function loss_penalty(loss_percent)
  local anchors = {
    {0, 0},
    {0.5, 4},
    {1, 8},
    {5, 10},
    {15, 20},
    {30, 30},
    {50, 45},
    {100, 70}
  }
  return interpolate_anchors(loss_percent, anchors)
end

local function calc_responsiveness()
  local s_lat = score_latency(STATE.current.internet_latency)
  local s_jit = score_jitter(STATE.current.jitter)
  local s_dns = score_dns(STATE.current.dns_lookup_latency)
  local score = round(0.5 * s_lat + 0.25 * s_jit + 0.25 * s_dns)
  log.debug("responsiveness detail:", " latency=", STATE.current.internet_latency, " jitter=", STATE.current.jitter, " dns=", STATE.current.dns_lookup_latency, " s_lat=", s_lat, " s_jit=", s_jit, " s_dns=", s_dns, " result=", score)
  return score
end

local function refresh_realtime_scores()
  STATE.current.responsiveness_score = calc_responsiveness()
  STATE.current.score = calc_score()
end

local function average(arr)
  if 0 == #arr then
    return 0
  end
  local sum = 0
  for i = 1, #arr do
    sum = sum + arr[i]
  end
  return round(sum / #arr)
end

local function weighted_exponential_average(arr, decay)
  local point_count = #arr
  local total_weight = 0
  local weighted_sum = 0
  local weight = 1
  if point_count <= 0 then
    return 0
  end
  for i = point_count, 1, -1 do
    local value = tonumber(arr[i]) or 0
    weighted_sum = weighted_sum + value * weight
    total_weight = total_weight + weight
    weight = weight * decay
  end
  if total_weight <= 0 then
    return 0
  end
  return weighted_sum / total_weight
end

local function calc_reliability_base_score()
  if #STATE.history.online_points <= 0 then
    return 0
  end
  return weighted_exponential_average(STATE.history.online_points, RELIABILITY_EXP_DECAY) * 100
end

local function calc_reliability()
  local point_count = #STATE.history.online_points
  if point_count <= 0 then
    log.debug("reliability detail: no history points")
    return 0
  end
  local base_score = calc_reliability_base_score()
  local p = weighted_exponential_average(STATE.history.loss_percent_points, RELIABILITY_EXP_DECAY)
  local penalty = loss_penalty(p)
  local reliability = base_score - penalty
  local result = clamp(round(reliability), 0, 100)
  log.debug("reliability detail:", " points=", point_count, " decay=", string.format("%.2f", RELIABILITY_EXP_DECAY), " base_score=", string.format("%.2f", base_score), " weighted_loss=", string.format("%.2f", p), " loss_penalty=", string.format("%.2f", penalty), " result=", result)
  return result
end

function calc_packet_loss_percent()
  if #STATE.history.loss_percent_points <= 0 then
    return 0
  end
  return round_to(weighted_exponential_average(STATE.history.loss_percent_points, RELIABILITY_EXP_DECAY), 2)
end

function calc_reliability_status_label()
  local base_score = calc_reliability_base_score()
  if base_score < 50 then
    return "Failing"
  end
  if base_score < 80 then
    return "Unstable"
  end
  if base_score < 90 then
    return "Variable"
  end
  if base_score < 97 then
    return "Stable"
  end
  return "Responsive"
end

local function ubus_gl_session_call(module, func, params)
  if not UBUS then
    return nil
  end
  local ok, res = pcall(function()
    return UBUS:call("gl-session", "call", {
      module = module,
      func = func,
      params = params or {}
    })
  end)
  if not ok or not res then
    return nil
  end
  return res.result
end

function calc_score()
  if #STATE.history.online_points <= 0 then
    log.debug("score detail:", " resp=", STATE.current.responsiveness_score, " reli=", STATE.current.reliability_score, " reliability_ready=0", " result=", STATE.current.responsiveness_score)
    return STATE.current.responsiveness_score
  end
  local weighted_resp = STATE.current.responsiveness_score * 0.6
  local weighted_reli = STATE.current.reliability_score * 0.4
  local score = round(weighted_resp + weighted_reli)
  log.debug("score detail:", " resp=", STATE.current.responsiveness_score, " reli=", STATE.current.reliability_score, " reliability_ready=1", " weighted_resp=", string.format("%.2f", weighted_resp), " weighted_reli=", string.format("%.2f", weighted_reli), " result=", score)
  return score
end

local function read_nameservers_from_resolv(path)
  local nameservers = {}
  if not file_exists(path) then
    return nameservers
  end
  for line in io.lines(path) do
    local ns = line:match("nameserver%s+(%S+)")
    if ns then
      nameservers[#nameservers + 1] = ns
    end
  end
  return nameservers
end

local function normalize_upstream_target(value)
  if not value or "" == value then
    return nil
  end
  value = tostring(value)
  value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
  value = value:gsub("/+$", "")
  value = value:gsub("#%d+$", "")
  local rest = value:match("^[%a%d+%-%.]+://(.+)$")
  if rest then
    rest = rest:gsub("/.*$", "")
    local bracketed = rest:match("^%[([^%]]+)%]")
    if bracketed then
      return bracketed
    end
    if rest:match("^[^:]+:%d+$") then
      return rest:match("^([^:]+):%d+$")
    end
    return rest
  end
  local bracketed = value:match("^%[([^%]]+)%]:%d+$")
  if bracketed then
    return bracketed
  end
  if value:match("^%d+%.%d+%.%d+%.%d+:%d+$") then
    return value:match("^([^:]+):%d+$")
  end
  return value
end

local function read_dnsproxy_upstreams(path)
  local upstreams = {}
  if not file_exists(path) then
    return upstreams
  end
  local in_upstream = false
  for line in io.lines(path) do
    if line:match("^upstream:?") or line:match("^upstream_dns:") then
      in_upstream = true
    elseif in_upstream and line:match("^%S") then
      in_upstream = false
    end
    if in_upstream then
      local value = line:match("^%s*%-%s*(%S+)")
      if value then
        value = normalize_upstream_target(value)
        if value then
          upstreams[#upstreams + 1] = value
        end
      end
    end
  end
  return upstreams
end

local function read_manual_dns_list()
  local c = uci.cursor()
  local mode = c:get("gl-dns-v2", "@dns[0]", "mode") or "auto"
  if "manual" == mode then
    return c:get("gl-dns-v2", "@dns[0]", "manual_list") or {}
  end
  if "proxy" == mode then
    local raw = c:get("gl-dns-v2", "@dns[0]", "proxy_list") or {}
    local list = {}
    for _, item in ipairs(raw) do
      local host = normalize_upstream_target(item)
      if host then
        list[#list + 1] = host
      end
    end
    return list
  end
  return {}
end

local function read_astrowarp_dns_list()
  local c = uci.cursor()
  local enabled = c:get("mptun", "global", "enable")
  if "1" ~= enabled then
    return {}
  end
  local server = c:get("mptun", "global", "dns")
  if not server or "" == server then
    return {}
  end
  return {
    normalize_upstream_target(server) or server
  }
end

local function read_adg_dns_list()
  -- AdGuard Home has its own upstream list, but querying its RPC adapter
  -- from here would require gl-session's generic call proxy. Its resolvers
  -- are not the path the router's own DNS probes take when it is off, and
  -- when it is on dnsmasq forwards to it anyway; the per-interface
  -- resolvers remain the honest thing to measure.
  return {}
end

local function read_vpn_dns_list()
  return {}
end

local function get_dns_candidates()
  local aw = read_astrowarp_dns_list()
  if #aw > 0 then
    log.debug("dns candidates source=astrowarp count=", #aw)
    return aw
  end
  local adg = read_adg_dns_list()
  if #adg > 0 then
    log.debug("dns candidates source=adg count=", #adg)
    return adg
  end
  local vpn = read_vpn_dns_list()
  if #vpn > 0 then
    log.debug("dns candidates source=vpn count=", #vpn)
    return vpn
  end
  local c = uci.cursor()
  local mode = c:get("gl-dns-v2", "@dns[0]", "mode") or "auto"
  if "manual" == mode or "proxy" == mode then
    local manual = read_manual_dns_list()
    if #manual > 0 then
      log.debug("dns candidates source=", mode, " count=", #manual)
      return manual
    end
  end
  if "secure" == mode then
    local secure = read_dnsproxy_upstreams("/etc/dnsproxy/dnsproxy.yaml")
    if #secure > 0 then
      log.debug("dns candidates source=secure count=", #secure)
      return secure
    end
  end
  local auto = read_nameservers_from_resolv("/tmp/resolv.conf.d/resolv.conf.auto")
  if #auto > 0 then
    log.debug("dns candidates source=auto count=", #auto)
    return auto
  end
  -- No per-interface resolvers (e.g. WAN down or a resolver managed by a
  -- package we do not model): probe the local resolver rather than leaving
  -- the DNS card stuck at its initial value forever.
  auto = read_nameservers_from_resolv("/etc/resolv.conf")
  if #auto > 0 then
    log.debug("dns candidates source=resolv count=", #auto)
    return auto
  end
  log.debug("dns candidates source=localhost count=1")
  return { "127.0.0.1" }
end

local function is_ip_literal(value)
  value = tostring(value or "")
  if value:match("^%d+%.%d+%.%d+%.%d+$") then
    return true
  end
  if value:find(":", 1, true) then
    return true
  end
  return false
end

local function parse_default_route_entries(output)
  local concrete_defaults = {}
  local nexthops = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local gateway, ifname, weight = line:match("^%s*nexthop%s+via%s+([^%s]+)%s+dev%s+([^%s]+)%s+weight%s+(%d+)")
    if gateway and ifname then
      nexthops[#nexthops + 1] = {
        gateway = gateway,
        ifname = ifname,
        weight = tonumber(weight) or 0
      }
    else
      gateway, ifname = line:match("^default%s+via%s+([^%s]+)%s+dev%s+([^%s]+)")
      if gateway and ifname then
        concrete_defaults[#concrete_defaults + 1] = {gateway = gateway, ifname = ifname}
      end
    end
  end
  return concrete_defaults, nexthops
end

local function select_default_route_entry()
  local output, _ = exec_capture("ip route show default")
  local concrete_defaults, nexthops = parse_default_route_entries(output)
  if #concrete_defaults > 0 then
    return concrete_defaults[1]
  end
  if 0 == #nexthops then
    return nil
  end
  table.sort(nexthops, function(a, b)
    if a.weight == b.weight then
      return false
    end
    return a.weight > b.weight
  end)
  return nexthops[1]
end

local function resolve_route_target_ip()
  if STATE and STATE.resolved then
    if is_ip_literal(STATE.resolved.ethernet_target_ip) then
      return STATE.resolved.ethernet_target_ip
    end
    if is_ip_literal(STATE.resolved.dns_target_ip) then
      return STATE.resolved.dns_target_ip
    end
  end
  return nil
end

local function route_get_entry(target_ip)
  if not target_ip or "" == target_ip then
    return nil
  end
  local output, rc = exec_capture("ip route get " .. shell_quote(target_ip) .. " 2>/dev/null | head -n1")
  if 0 ~= rc then
    return nil
  end
  local line = tostring(output or ""):match("([^\r\n]+)")
  if not line or "" == line then
    return nil
  end
  local gateway = line:match("%svia%s+([^%s]+)")
  local ifname = line:match("%sdev%s+([^%s]+)")
  if not gateway or not ifname then
    return nil
  end
  return {gateway = gateway, ifname = ifname}
end

local function check_probe_scripts()
  local scripts = {
    ETHERNET_PING_SCRIPT,
    WAN_PING_SCRIPT,
    DNS_LOOKUP_SCRIPT
  }
  for _, path in ipairs(scripts) do
    if file_exists(path) then
      log.info("probe script ready:", path)
    else
      log.err("probe script missing:", path)
    end
  end
end

local function default_route_gateway()
  local entry = select_default_route_entry()
  return entry and entry.gateway or nil
end

local function default_route_ifname()
  local entry = select_default_route_entry()
  return entry and entry.ifname or nil
end

local function get_interface_status(iface)
  if not iface or "" == iface or not UBUS then
    return nil
  end
  local ok, res = pcall(function()
    return UBUS:call("network.interface." .. iface, "status", {})
  end)
  if not ok or type(res) ~= "table" then
    return nil
  end
  return res
end

local function get_runtime_ifname(iface)
  local status = get_interface_status(iface)
  if not status then
    return nil
  end
  return status.l3_device or status.device or status.ifname or iface
end

local function get_interface_gateway(ifname)
  if not ifname or "" == ifname then
    return nil
  end
  local res = get_interface_status(ifname)
  if not res then
    return nil
  end
  if type(res.route) == "table" then
    for _, route in ipairs(res.route) do
      if route.nexthop and "" ~= route.nexthop then
        return route.nexthop
      end
    end
  end
  return nil
end

local function get_kmwan_mode(cfg)
  if cfg and cfg.mode ~= nil then
    return tonumber(cfg.mode) or 0
  end
  local c = uci.cursor()
  -- This port keeps GL's multi-WAN mode in gl-oui-rpc.kmwan, next to the
  -- rest of the kmwan adapter state. Accept the older /etc/config/kmwan
  -- spelling too, so an installation migrated from an earlier build keeps
  -- its balance/failover choice.
  if "1" == tostring(c:get("gl-oui-rpc", "kmwan", "mode") or "") then
    return 1
  end
  if "balance" == c:get("kmwan", "global", "mode") then
    return 1
  end
  return 0
end

local function resolve_failover_target(cfg)
  -- mwan3 has already picked the active member and installed its default
  -- route. Probe that route rather than re-deriving the member list here;
  -- it is the same path real traffic takes, and it keeps working even if
  -- gl-session does not expose the kmwan adapter.
  local entry = select_default_route_entry()
  return {
    use_ifname = false,
    ifname = entry and entry.ifname or "",
    gateway = entry and entry.gateway or nil
  }
end

local function resolve_wan_probe_target(cfg)
  local mode = get_kmwan_mode(cfg)
  if 1 == mode then
    local target_ip = resolve_route_target_ip()
    local route_entry = route_get_entry(target_ip)
    if route_entry then
      return {
        use_ifname = true,
        ifname = route_entry.ifname or "",
        gateway = route_entry.gateway
      }, mode
    end
    return {
      use_ifname = false,
      ifname = default_route_ifname() or "",
      gateway = default_route_gateway()
    }, mode
  end
  return resolve_failover_target(cfg), mode
end

local function parse_probe_script_result(output)
  local status, latency, reason = tostring(output or ""):match("^%s*([01])%s+([%-%d%.]+)%s*(.-)%s*$")
  return tonumber(status), tonumber(latency), reason
end

local function probe_result_ip(reason)
  local candidate = tostring(reason or ""):match("^([%w%._:]+)$")
  if candidate and is_ip_literal(candidate) then
    return candidate
  end
  return nil
end

local function compute_latency_stats_from_samples(samples)
  if 0 == #samples then
    return -1, -1, 0
  end
  local typical = calc_median(samples)
  local worst = calc_second_worst(samples)
  local jitter = calc_avg_abs_delta(samples)
  return typical, worst, jitter
end

local function compute_minute_latency_stats()
  if 0 == #STATE.minute.internet_rtts and 0 == STATE.minute.fail_count then
    return -1, -1, 0
  end
  if 0 == #STATE.minute.internet_rtts and STATE.minute.fail_count > 0 then
    local timeout_ms = ping_timeout_ms()
    return timeout_ms, timeout_ms, timeout_ms
  end
  local typical, worst, jitter = compute_latency_stats_from_samples(STATE.minute.internet_rtts)
  if typical < 0 then
    typical = ping_timeout_ms()
  end
  if worst < 0 then
    worst = ping_timeout_ms()
  end
  if jitter < 0 then
    jitter = ping_timeout_ms()
  end
  return typical, worst, jitter
end

local function update_realtime_latency_stats()
  local typical, worst, jitter = compute_latency_stats_from_samples(STATE.realtime.internet_rtts)
  if typical == ping_timeout_ms() and worst == ping_timeout_ms() then
    jitter = ping_timeout_ms()
  end
  STATE.current.typical = typical
  STATE.current.worst = worst
  STATE.current.jitter = jitter
  refresh_realtime_scores()
end

local function read_stream(read_method, timeout)
  local parts = {}
  for _ = 1, 512 do
    local line, _, partial = read_method("*l", timeout)
    if line then
      parts[#parts + 1] = line
    elseif partial and "" ~= partial then
      parts[#parts + 1] = partial
      break
    else
      break
    end
  end
  return table.concat(parts, "\n")
end

local function run_probe_script(args, timeout)
  local p, err = sys.exec(table.unpack(args))
  if not p then
    return "", nil, err
  end
  local output = read_stream(function(fmt, t) return p:read_stdout(fmt, t) end, timeout)
  local stderr = read_stream(function(fmt, t) return p:read_stderr(fmt, t) end, timeout)
  local ok = p:wait(timeout)
  p:close()
  if not ok then
    return output or "", nil, stderr and "" ~= stderr and stderr or "timeout"
  end
  if not output or "" == output then
    return "", 0, stderr and "" ~= stderr and stderr or "empty stdout"
  end
  return output, 0, nil
end

local function probe_ethernet_ping()
  local cycle_seconds = math.max(1, STATE.config.ping_interval)
  if not STATE.config.enabled then
    return
  end
  local output, _, err = run_probe_script({
    ETHERNET_PING_SCRIPT,
    STATE.config.ethernet_ping_address,
    tostring(math.max(1, math.min(STATE.config.ping_timeout, cycle_seconds))),
    tostring(cycle_seconds * 1000)
  }, cycle_seconds + STATE.config.ping_timeout + 3)
  local status, latency, reason = parse_probe_script_result(output)
  if not err and 0 == status and latency then
    local resolved_ip = probe_result_ip(reason)
    if resolved_ip then
      STATE.resolved.ethernet_target_ip = resolved_ip
    end
    STATE.current.internet_latency = round(latency)
    push_window_limit(STATE.realtime.internet_rtts, STATE.current.internet_latency, REALTIME_RTT_WINDOW_SIZE)
    STATE.minute.internet_rtts[#STATE.minute.internet_rtts + 1] = STATE.current.internet_latency
    STATE.minute.success_count = STATE.minute.success_count + 1
    update_realtime_latency_stats()
    log.debug("ethernet probe ok, target=", STATE.config.ethernet_ping_address, " latency=", STATE.current.internet_latency, " typical=", STATE.current.typical, " worst=", STATE.current.worst, " jitter=", STATE.current.jitter, " realtime_sample_count=", #STATE.realtime.internet_rtts, " minute_success_sample_count=", #STATE.minute.internet_rtts, " success_count=", STATE.minute.success_count, " fail_count=", STATE.minute.fail_count)
  else
    STATE.current.internet_latency = ping_timeout_ms()
    push_window_limit(STATE.realtime.internet_rtts, STATE.current.internet_latency, REALTIME_RTT_WINDOW_SIZE)
    STATE.minute.fail_count = STATE.minute.fail_count + 1
    update_realtime_latency_stats()
    log.debug("ethernet probe fail, target=", STATE.config.ethernet_ping_address, " reason=", reason or "", " err=", err or "", " typical=", STATE.current.typical, " worst=", STATE.current.worst, " jitter=", STATE.current.jitter, " realtime_sample_count=", #STATE.realtime.internet_rtts, " success_count=", STATE.minute.success_count, " fail_count=", STATE.minute.fail_count)
  end
end

local function probe_wan_ping()
  local cycle_seconds = math.max(1, STATE.config.ping_interval)
  if not STATE.config.enabled then
    return
  end
  local target, mode = resolve_wan_probe_target()
  if not target.gateway or target.gateway == "" then
    STATE.current.wan_gateway_latency = ping_timeout_ms()
    if 1 == mode then
      log.debug("wan target balance unresolved, ifname=", target.ifname or "", " gateway=")
    else
      log.debug("wan target failover unresolved, ifname=", target.ifname or "", " gateway=")
    end
    return
  end
  local ifname = target.use_ifname and target.ifname and "" ~= target.ifname and target.ifname or "-"
  if 1 == mode then
    log.debug("wan target balance, ifname=", ifname, " gateway=", target.gateway)
  else
    log.debug("wan target failover, ifname=", ifname, " gateway=", target.gateway)
  end
  local output, _, err = run_probe_script({
    WAN_PING_SCRIPT,
    ifname,
    target.gateway,
    tostring(math.max(1, math.min(STATE.config.ping_timeout, cycle_seconds))),
    tostring(cycle_seconds * 1000)
  }, cycle_seconds + STATE.config.ping_timeout + 3)
  local status, latency, reason = parse_probe_script_result(output)
  if not err and 0 == status and latency then
    STATE.current.wan_gateway_latency = round(latency)
    log.debug("wan probe ok, ifname=", target.ifname or "", " gateway=", target.gateway, " latency=", STATE.current.wan_gateway_latency)
  else
    STATE.current.wan_gateway_latency = ping_timeout_ms()
    log.debug("wan probe fail, ifname=", target.ifname or "", " gateway=", target.gateway or "", " reason=", reason or "", " err=", err or "")
  end
end

local function probe_dns_lookup()
  if not STATE.config.enabled then
    return
  end
  local candidates = get_dns_candidates()
  local best
  for _, server in ipairs(candidates) do
    local output, _, err = run_probe_script({
      DNS_LOOKUP_SCRIPT,
      server,
      STATE.config.dns_probe_domain,
      tostring(math.max(1, STATE.config.dns_timeout)),
      tostring(math.max(1, STATE.config.dns_interval) * 1000)
    }, STATE.config.dns_interval + STATE.config.dns_timeout + 3)
    local status, latency, reason = parse_probe_script_result(output)
    if not err and 0 == status and latency then
      local resolved_ip = probe_result_ip(reason)
      if resolved_ip then
        STATE.resolved.dns_target_ip = resolved_ip
      end
      if not best or best > latency then
        best = latency
      end
      log.debug("dns probe ok, server=", server, " latency=", latency)
    else
      log.debug("dns probe fail, server=", server, " reason=", reason or "", " err=", err or "")
    end
  end
  if best then
    STATE.current.dns_lookup_latency = round(best)
    refresh_realtime_scores()
    log.debug("dns probe best latency=", STATE.current.dns_lookup_latency)
  else
    STATE.current.dns_lookup_latency = dns_timeout_ms()
    refresh_realtime_scores()
    log.debug("dns probe all failed")
  end
end

local function get_balance_rate_targets()
  local output, _ = exec_capture("ip route show default")
  local concrete_defaults, nexthops = parse_default_route_entries(output)
  local targets = {}
  local seen = {}
  local function add(ifname)
    if ifname and "" ~= ifname and not seen[ifname] then
      seen[ifname] = true
      targets[#targets + 1] = ifname
    end
  end
  for _, entry in ipairs(nexthops) do
    add(entry.ifname)
  end
  for _, entry in ipairs(concrete_defaults) do
    add(entry.ifname)
  end
  if 0 == #targets then
    add(default_route_ifname())
  end
  return targets
end

local function get_rate_targets()
  if 1 == get_kmwan_mode() then
    return get_balance_rate_targets()
  end
  local ifname = default_route_ifname()
  return ifname and { ifname } or {}
end

local function read_uint(path)
  local line = read_first_line(path)
  return line and tonumber(line) or nil
end

local function sample_rate()
  if not STATE.config.enabled then
    STATE.current.upload_rate_current = 0
    STATE.current.download_rate_current = 0
    STATE.current.total_rate_current = 0
    return
  end
  local ifnames = get_rate_targets()
  if type(ifnames) ~= "table" or 0 == #ifnames then
    STATE.current.upload_rate_current = 0
    STATE.current.download_rate_current = 0
    STATE.current.total_rate_current = 0
    push_window(STATE.history.upload_rate_realtime, 0)
    push_window(STATE.history.download_rate_realtime, 0)
    return
  end
  local now = time.now()
  local desired = {}
  local total_down = 0
  local total_up = 0
  local contributing = 0
  for _, ifname in ipairs(ifnames) do
    if ifname and "" ~= ifname then
      desired[ifname] = true
      local rx = read_uint("/sys/class/net/" .. ifname .. "/statistics/rx_bytes")
      local tx = read_uint("/sys/class/net/" .. ifname .. "/statistics/tx_bytes")
      if rx and tx then
        local last = STATE.rate_last[ifname]
        if not last or 0 == last.ts then
          STATE.rate_last[ifname] = {
            rx = rx,
            tx = tx,
            ts = now
          }
        else
          local delta_t = now - last.ts
          if delta_t > 0 then
            total_down = total_down + math.max(0, rx - last.rx) / delta_t
            total_up = total_up + math.max(0, tx - last.tx) / delta_t
            contributing = contributing + 1
          end
          last.rx = rx
          last.tx = tx
          last.ts = now
        end
      end
    end
  end
  for ifname, _ in pairs(STATE.rate_last) do
    if not desired[ifname] then
      STATE.rate_last[ifname] = nil
    end
  end
  if 0 == contributing then
    STATE.current.upload_rate_current = 0
    STATE.current.download_rate_current = 0
    STATE.current.total_rate_current = 0
    push_window(STATE.history.upload_rate_realtime, 0)
    push_window(STATE.history.download_rate_realtime, 0)
    return
  end
  local total = total_up + total_down
  STATE.current.upload_rate_current = round(total_up)
  STATE.current.download_rate_current = round(total_down)
  STATE.current.total_rate_current = round(total)
  push_window(STATE.history.upload_rate_realtime, STATE.current.upload_rate_current)
  push_window(STATE.history.download_rate_realtime, STATE.current.download_rate_current)
end

local function map_status_code(typical, jitter, loss_percent, success_count, fail_count)
  local online_ratio = calc_online_ratio(success_count, fail_count)
  _ = loss_percent
  if online_ratio < 0.8 then
    return STATUS_BAD
  end
  if online_ratio >= 0.95 and typical <= 100 and jitter <= 10 then
    return STATUS_GOOD
  end
  return STATUS_WARN
end

local function map_loss_code(loss_percent)
  if loss_percent < 0.5 then
    return STATUS_GOOD
  end
  if loss_percent < 5 then
    return STATUS_WARN
  end
  return STATUS_BAD
end

local function reset_minute()
  STATE.minute = fresh_minute()
end

local function command_exists(cmd)
  local output, rc = exec_capture("command -v " .. shell_quote(cmd))
  return 0 == rc and output and output:match("%S") ~= nil
end

local function flush_minute_bucket()
  if not STATE.config.enabled then
    reset_minute()
    return
  end
  local minute_typical, minute_worst, minute_jitter = compute_minute_latency_stats()
  local loss_percent = calc_loss_percent(STATE.minute.success_count, STATE.minute.fail_count)
  local status_code = map_status_code(minute_typical, minute_jitter, loss_percent, STATE.minute.success_count, STATE.minute.fail_count)
  local loss_code = map_loss_code(loss_percent)
  local online_ratio = calc_online_ratio(STATE.minute.success_count, STATE.minute.fail_count)
  local status_reason, loss_reason
  if online_ratio < 0.8 then
    status_reason = "online_ratio_lt_0.80"
  elseif online_ratio >= 0.95 then
    status_reason = "online_ratio_ge_0.95"
  else
    status_reason = "online_ratio_warn_range"
  end
  if loss_percent < 0.5 then
    loss_reason = "loss_lt_0.5"
  elseif loss_percent < 5 then
    loss_reason = "loss_lt_5"
  else
    loss_reason = "loss_ge_5"
  end
  push_window(STATE.history.reliability_status, status_code)
  push_window(STATE.history.reliability_packet_loss, loss_code)
  push_window(STATE.history.online_points, online_ratio)
  push_window(STATE.history.loss_percent_points, loss_percent)
  STATE.current.reliability_score = calc_reliability()
  refresh_realtime_scores()
  log.debug("minute flush:", " sample_count=", STATE.minute.success_count + STATE.minute.fail_count, " success=", STATE.minute.success_count, " fail=", STATE.minute.fail_count, " minute_typical=", minute_typical, " minute_worst=", minute_worst, " minute_jitter=", minute_jitter, " realtime_typical=", STATE.current.typical, " realtime_worst=", STATE.current.worst, " realtime_jitter=", STATE.current.jitter, " loss=", string.format("%.2f", loss_percent), " loss_threshold_good_lt=", "0.5", " loss_threshold_warn_lt=", "5", " status_code=", status_code, " status_reason=", status_reason, " loss_code=", loss_code, " loss_reason=", loss_reason, " online_ratio=", string.format("%.3f", online_ratio), " resp=", STATE.current.responsiveness_score, " reli=", STATE.current.reliability_score, " score=", STATE.current.score, " history_points=", #STATE.history.reliability_status)
  STATE.bootstrap_minute_pending = false
  reset_minute()
end

function M.init(con)
  UBUS = con
  STATE = fresh_state(load_config())
  apply_log_level(STATE.config.log)
  log.info("network-quality init, enabled=", STATE.config.enabled and 1 or 0)
  check_probe_scripts()
  save_snapshot(snapshot_payload())
end

function M.reload_config()
  local cfg = load_config()
  if cfg.enabled then
    STATE.config = cfg
  else
    STATE = fresh_state(cfg)
  end
  apply_log_level(STATE.config.log)
  log.info("reload config, enabled=", STATE.config.enabled and 1 or 0)
  save_snapshot(snapshot_payload())
end

function M.snapshot()
  if not STATE then
    STATE = fresh_state(load_config())
  end
  return snapshot_payload()
end

function M.start_speedtest()
  if not STATE then
    STATE = fresh_state(load_config())
  end
  return speedtest_lib.start({
    state = STATE,
    log = log,
    time = time,
    sys = sys,
    eco = eco,
    push_snapshot = push_snapshot,
    file_exists = file_exists,
    command_exists = command_exists,
    copy_array = copy_array,
    average = average
  })
end

function M.set_speedtest(enable)
  if not STATE then
    STATE = fresh_state(load_config())
  end
  return speedtest_lib.set_enabled({
    state = STATE,
    log = log,
    push_snapshot = push_snapshot,
    eco = eco,
    time = time,
    sys = sys,
    file_exists = file_exists,
    command_exists = command_exists,
    copy_array = copy_array,
    average = average
  }, enable)
end

local function worker_ethernet()
  while true do
    local start = time.now()
    probe_ethernet_ping()
    local wait = math.max(0, math.max(1, STATE.config.ping_interval) - (time.now() - start))
    if wait > 0 then
      time.sleep(wait)
    end
  end
end

local function worker_wan()
  while true do
    local start = time.now()
    probe_wan_ping()
    local wait = math.max(0, math.max(1, STATE.config.ping_interval) - (time.now() - start))
    if wait > 0 then
      time.sleep(wait)
    end
  end
end

local function worker_dns()
  while true do
    local start = time.now()
    probe_dns_lookup()
    local wait = math.max(0, math.max(1, STATE.config.dns_interval) - (time.now() - start))
    if wait > 0 then
      time.sleep(wait)
    end
  end
end

local function worker_rate()
  while true do
    sample_rate()
    time.sleep(2)
  end
end

local function worker_minute()
  while true do
    local wait = STATE.bootstrap_minute_pending and FIRST_MINUTE_WINDOW or math.max(10, STATE.config.minute_window)
    time.sleep(wait)
    flush_minute_bucket()
  end
end

local function worker_push()
  while true do
    push_snapshot()
    time.sleep(1)
  end
end

function M.start()
  if STATE.workers_started then
    return
  end
  STATE.workers_started = true
  eco.run(worker_ethernet)
  eco.run(worker_wan)
  eco.run(worker_dns)
  eco.run(worker_rate)
  eco.run(worker_minute)
  eco.run(worker_push)
end

return M
