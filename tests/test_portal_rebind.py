#!/usr/bin/env python3
"""gl-repeater-portal's per-host rebind exception, offline.

Loads the real detector up to its main loop under the host's lua, with the
eco modules, uci and os.execute stubbed, and drives set_portal_rebind /
clear_portal_rebind against a temporary dnsmasq confdir. dnsmasq's handling
of the line it writes is checked in tests/sandbox/dns-rebind.sh.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PORTAL = Path(__file__).resolve().parents[1] / 'gl-feed/net/gl-portal/files/usr/sbin/gl-repeater-portal'

HARNESS = r'''
local confdir = CONFDIR
for _, m in ipairs({ "eco.http.client", "eco.time", "eco.ubus" }) do
	package.preload[m] = function() return {} end
end
package.preload["cjson"] = function() return { encode = function() return "{}" end, decode = function() return {} end } end
package.preload["eco.uci"] = function()
	local cursor = {}
	function cursor:foreach(c, t, fn) if c == "dhcp" and t == "dnsmasq" then fn({ [".name"] = "cfg01" }) end end
	function cursor:get(c, s, o) if o == "confdir" then return confdir end end
	return { cursor = function() return cursor end }
end
RELOADS = 0
os.execute = function(cmd) if cmd:find("dnsmasq reload", 1, true) then RELOADS = RELOADS + 1 end return 0 end
local src = io.open(PORTAL):read("a")
src = src:gsub("^#![^\n]*\n", "")
src = src:sub(1, src:find("\n-- A transient ubus/uci failure", 1, true))
src = src .. "\nreturn { set = set_portal_rebind, clear = clear_portal_rebind, host = portal_rebind_host }\n"
local api = load(src, "gl-repeater-portal")()
local path = confdir .. "/gl-repeater-portal-rebind.conf"
local function file()
	local f = io.open(path)
	if not f then return "-" end
	local c = f:read("a"); f:close(); return c
end
for _, step in ipairs(STEPS) do
	if step[1] == "host" then
		print("host", tostring(api.host(step[2])))
	else
		if step[1] == "set" then api.set(step[2]) else api.clear() end
		print(step[1], (file():gsub("\n", "\\n")), RELOADS)
	end
end
'''


def lua_str(s):
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


@unittest.skipUnless(shutil.which('lua'), 'needs a lua interpreter')
class PortalRebindTests(unittest.TestCase):
    def run_steps(self, steps):
        with tempfile.TemporaryDirectory() as d:
            code = 'PORTAL=%s\nCONFDIR=%s\nSTEPS={%s}\n' % (
                lua_str(str(PORTAL)), lua_str(d),
                ','.join('{%s}' % ','.join(lua_str(x) for x in s) for s in steps)) + HARNESS
            r = subprocess.run(['lua', '-'], input=code, capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            return [tuple(l.split('\t')) for l in r.stdout.splitlines()]

    def test_pending_portal_host_gets_an_exception_until_passed(self):
        out = self.run_steps([
            ('set', 'http://Login.MavStart.example/portal?x=1'),
            ('set', 'http://login.mavstart.example/other'),  # same host: no reload
            ('clear',),
            ('clear',),                                       # nothing to do: no reload
        ])
        self.assertEqual(out, [
            ('set', 'rebind-domain-ok=/login.mavstart.example/\\n', '1'),
            ('set', 'rebind-domain-ok=/login.mavstart.example/\\n', '1'),
            ('clear', '-', '2'),
            ('clear', '-', '2'),
        ])

    def test_a_new_portal_host_replaces_the_old_one(self):
        out = self.run_steps([('set', 'https://a.example:8443/x'), ('set', 'http://b.example/')])
        self.assertEqual(out[-1], ('set', 'rebind-domain-ok=/b.example/\\n', '2'))

    def test_ip_literals_and_unsafe_names_never_reach_dnsmasq(self):
        out = self.run_steps([
            ('host', 'http://192.168.10.1:8444/login'),
            ('host', 'http://[fe80::1]/login'),
            ('host', 'http://evil.example\nserver=6.6.6.6/'),
            ('host', 'http://bad_name.example/'),
            ('host', 'ftp://x.example/'),
            ('host', ''),
            ('host', 'http://ok-name.example/'),
        ])
        self.assertEqual([h for _, h in out], ['nil', 'nil', 'nil', 'nil', 'nil', 'nil', 'ok-name.example'])

    def test_detector_sets_and_clears_on_every_transition(self):
        s = PORTAL.read_text()
        detect = s[s.index('local function detect(settings)'):s.index('-- Returns the seconds until the next pass.')]
        self.assertIn('set_portal_rebind(url)', detect)
        # Passed, and no portal found: both clear it.
        self.assertEqual(detect.count('clear_portal_rebind()'), 2)
        tick = s[s.index('local function tick()'):]
        self.assertIn('clear_portal_rebind()', tick)  # uplink gone


if __name__ == '__main__':
    unittest.main()
