#!/usr/bin/env python3
"""gl-repeater-portal's portal DNS helpers, offline.

Loads the real detector up to its main loop under the host's lua, with the
eco modules, uci and os.execute stubbed, and drives set_portal_rebind /
set_portal_forward against a temporary dnsmasq confdir. dnsmasq's handling
of the lines they write is checked in tests/sandbox/dns-rebind.sh.
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
os.execute = function(cmd) if cmd:find("dnsmasq restart", 1, true) then RELOADS = RELOADS + 1 end return 0 end
local src = io.open(PORTAL):read("a")
src = src:gsub("^#![^\n]*\n", "")
src = src:sub(1, src:find("\n-- A transient ubus/uci failure", 1, true))
src = src .. "\nreturn { rebind_set = set_portal_rebind, rebind_clear = clear_portal_rebind," ..
	" forward_set = set_portal_forward, forward_clear = clear_portal_forward," ..
	" domains = portal_domains }\n"
local api = load(src, "gl-repeater-portal")()
local REBIND = confdir .. "/gl-repeater-portal-rebind.conf"
local FORWARD = confdir .. "/gl-repeater-portal-domain.conf"
local function read(path)
	local f = io.open(path)
	if not f then return "-" end
	local c = f:read("a")
	f:close()
	return (c:gsub("\n", "\\n"))
end
for _, step in ipairs(STEPS) do
	local op = step[1]
	if op == "domains" then
		print("domains", table.concat(api.domains(step[2]), "|"))
	elseif op == "rebind" then
		api.rebind_set(step[2])
		print("rebind", read(REBIND), RELOADS)
	elseif op == "rebind_clear" then
		api.rebind_clear()
		print("rebind_clear", read(REBIND), RELOADS)
	elseif op == "forward" then
		api.forward_set(step[2], { "10.0.3.5", "10.0.3.6" })
		print("forward", read(FORWARD), RELOADS)
	elseif op == "forward_noservers" then
		api.forward_set(step[2], {})
		print("forward", read(FORWARD), RELOADS)
	elseif op == "forward_clear" then
		api.forward_clear()
		print("forward_clear", read(FORWARD), RELOADS)
	end
end
'''


def lua_str(s):
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


@unittest.skipUnless(shutil.which('lua'), 'needs a lua interpreter')
class PortalDnsTests(unittest.TestCase):
    def run_steps(self, steps):
        with tempfile.TemporaryDirectory() as d:
            code = 'PORTAL=%s\nCONFDIR=%s\nSTEPS={%s}\n' % (
                lua_str(str(PORTAL)), lua_str(d),
                ','.join('{%s}' % ','.join(lua_str(x) for x in s) for s in steps)) + HARNESS
            r = subprocess.run(['lua', '-'], input=code, capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            return [tuple(l.split('\t')) for l in r.stdout.splitlines()]

    def test_domains_cover_the_portal_host_and_its_parent(self):
        out = self.run_steps([
            ('domains', 'https://mav-fedelzet.instant.telekom.hu/index.php?x=1'),
            ('domains', 'http://portal.example.com/login'),
            ('domains', 'https://example.com/'),
            ('domains', 'http://192.168.1.1/login'),
            ('domains', 'http://[2001:db8::1]/'),
            ('domains', 'http://evil.example\nserver=6.6.6.6/'),
            ('domains', 'http://bad_name.example/'),
        ])
        self.assertEqual([v for _, v in out], [
            'mav-fedelzet.instant.telekom.hu|instant.telekom.hu',
            'portal.example.com|example.com',
            'example.com',
            '',
            '',
            '',
            '',
        ])

    def test_pending_portal_gets_scoped_dns_until_passed(self):
        out = self.run_steps([
            ('forward', 'http://mav-fedelzet.instant.telekom.hu/index.php?x=1'),
            ('forward', 'http://mav-fedelzet.instant.telekom.hu/index.php?x=1'),  # unchanged: no reload
            ('forward_clear',),
            ('forward_clear',),                                                   # nothing to do: no reload
        ])
        self.assertEqual(out, [
            ('forward', 'server=/mav-fedelzet.instant.telekom.hu/10.0.3.5\\n'
                        'server=/mav-fedelzet.instant.telekom.hu/10.0.3.6\\n'
                        'server=/instant.telekom.hu/10.0.3.5\\n'
                        'server=/instant.telekom.hu/10.0.3.6\\n', '1'),
            ('forward', 'server=/mav-fedelzet.instant.telekom.hu/10.0.3.5\\n'
                        'server=/mav-fedelzet.instant.telekom.hu/10.0.3.6\\n'
                        'server=/instant.telekom.hu/10.0.3.5\\n'
                        'server=/instant.telekom.hu/10.0.3.6\\n', '1'),
            ('forward_clear', '-', '2'),
            ('forward_clear', '-', '2'),
        ])

    def test_no_servers_means_no_forward_file(self):
        out = self.run_steps([('forward_noservers', 'http://portal.example.com/')])
        self.assertEqual(out, [('forward', '-', '0')])

    def test_rebind_uses_the_parent_domain(self):
        out = self.run_steps([
            ('rebind', 'http://Login.MavStart.example/portal?x=1'),
            ('rebind', 'http://login.mavstart.example/other'),  # same domains: no reload
            ('rebind_clear',),
        ])
        self.assertEqual(out, [
            ('rebind', 'rebind-domain-ok=/login.mavstart.example/\\n'
                       'rebind-domain-ok=/mavstart.example/\\n', '1'),
            ('rebind', 'rebind-domain-ok=/login.mavstart.example/\\n'
                       'rebind-domain-ok=/mavstart.example/\\n', '1'),
            ('rebind_clear', '-', '2'),
        ])

    def test_ip_literals_and_unsafe_names_never_reach_dnsmasq(self):
        out = self.run_steps([
            ('rebind', 'http://192.168.10.1:8444/login'),
            ('rebind', 'http://[fe80::1]/login'),
            ('rebind', 'http://evil.example\nserver=6.6.6.6/'),
            ('rebind', 'http://bad_name.example/'),
            ('rebind', 'ftp://x.example/'),
            ('rebind', ''),
            ('rebind', 'http://ok-name.example/'),
        ])
        self.assertEqual([v for op, v, _ in out], ['-', '-', '-', '-', '-', '-',
                                                   'rebind-domain-ok=/ok-name.example/\\n'])

    def test_detector_sets_and_clears_on_every_transition(self):
        s = PORTAL.read_text()
        detect = s[s.index('local function detect(settings)'):s.index('-- Returns the seconds until the next pass.')]
        self.assertIn('set_portal_rebind(url)', detect)
        self.assertIn('set_portal_forward(url, settings.dns)', detect)
        self.assertIn('set_portal_routes(settings.dns)', detect)
        # Passed, and no portal found: both clear them.
        self.assertEqual(detect.count('clear_portal_rebind()'), 2)
        self.assertEqual(detect.count('clear_portal_forward()'), 2)
        self.assertEqual(detect.count('clear_portal_routes()'), 2)
        tick = s[s.index('local function tick()'):]
        self.assertIn('clear_portal_rebind()', tick)   # uplink gone
        self.assertIn('clear_portal_forward()', tick)
        self.assertIn('clear_portal_routes()', tick)


if __name__ == '__main__':
    unittest.main()
