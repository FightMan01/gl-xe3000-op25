#!/usr/bin/env python3
"""The SQM page's upload/download against the sqm-scripts options, offline.

Runs the real sqm.lua under the host's lua with an in-memory uci module and
os.execute stubbed out. Which direction each sqm option shapes on br-lan is
measured in tests/sandbox-sqm-direction.sh.
"""
import json
from pathlib import Path
import shutil
import subprocess
import unittest

SQM = Path(__file__).resolve().parents[1] / 'gl-feed/net/gl-oui-rpc/files/usr/lib/oui-rpc/sqm.lua'

HARNESS = r'''
local state = {}
for k, v in pairs(INITIAL) do state[k] = v end
package.preload["uci"] = function()
	local cursor = {}
	function cursor:get(c, s, o)
		if o == nil then return state[c .. "." .. s] end
		return state[c .. "." .. s .. "." .. o]
	end
	function cursor:set(c, s, o, v)
		if v == nil then state[c .. "." .. s] = o else state[c .. "." .. s .. "." .. o] = v end
	end
	function cursor:foreach(c, t, fn)
		local names = {}
		for k, v in pairs(state) do
			local name = k:match("^" .. c .. "%.([^.]+)$")
			if name and v == t then names[#names + 1] = name end
		end
		table.sort(names)
		for _, n in ipairs(names) do fn({ [".name"] = n }) end
	end
	function cursor:commit() end
	return { cursor = function() return cursor end }
end
os.execute = function() return 0 end
local sqm = dofile(SQM)
local out = {}
for _, call in ipairs(CALLS) do
	local r = sqm[call[1]](call[2])
	out[#out + 1] = r
end
local function enc(v)
	if type(v) == "table" then
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q:%s", tostring(k), enc(v[k])) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then return string.format("%q", v)
	elseif type(v) == "number" then return (v == math.floor(v)) and string.format("%d", v) or tostring(v)
	else return tostring(v) end
end
print(enc({ results = out, state = state }))
'''


def lua_table(d):
    items = []
    for k, v in d.items():
        if isinstance(v, bool):
            val = 'true' if v else 'false'
        elif isinstance(v, (int, float)):
            val = repr(v)
        elif isinstance(v, dict):
            val = lua_table(v)
        else:
            val = '"%s"' % v
        items.append('["%s"]=%s' % (k, val))
    return '{' + ','.join(items) + '}'


def run(initial, calls):
    code = ('SQM=%r\nINITIAL=%s\nCALLS={%s}\n' % (str(SQM), lua_table(initial),
            ','.join('{"%s",%s}' % (n, lua_table(a)) for n, a in calls))) + HARNESS
    r = subprocess.run(['lua', '-'], input=code, capture_output=True, text=True, timeout=10)
    if r.returncode:
        raise AssertionError(r.stderr)
    out = json.loads(r.stdout)
    out['results'] = [out['results'][str(i + 1)] for i in range(len(out['results']))]
    return out


@unittest.skipUnless(shutil.which('lua'), 'needs a lua interpreter')
class SqmDirectionTests(unittest.TestCase):
    def test_page_values_shape_the_direction_they_name_on_br_lan(self):
        out = run({'firewall.d': 'defaults'}, [
            ('set_config', {'enable': True, 'upload': 10, 'download': 100, 'qdisc': 'cake'}),
            ('get_config', {}),
        ])
        st = out['state']
        q = 'sqm.gl.'
        self.assertEqual(st[q + 'interface'], 'br-lan')
        # br-lan egress (sqm "upload") is the LAN's download.
        self.assertEqual((st[q + 'upload'], st[q + 'download']), ('100000', '10000'))
        self.assertEqual(st[q + 'gl_lan_swap'], '1')
        self.assertEqual(out['results'][1], {'enable': True, 'upload': 10, 'download': 100, 'qdisc': 'cake'})

    def test_existing_first_queue_is_reused_and_swapped(self):
        out = run({'sqm.eth1': 'queue', 'sqm.eth1.interface': 'eth1', 'sqm.eth1.upload': '10000',
                   'sqm.eth1.download': '85000'}, [
            ('set_config', {'enable': False, 'upload': 20, 'download': 200, 'qdisc': 'fq_codel'}),
            ('get_config', {}),
        ])
        st = out['state']
        self.assertEqual((st['sqm.eth1.interface'], st['sqm.eth1.upload'], st['sqm.eth1.download']),
                         ('br-lan', '200000', '20000'))
        self.assertEqual((out['results'][1]['upload'], out['results'][1]['download']), (20, 200))

    def test_a_queue_on_a_wan_device_reads_unswapped(self):
        # Stock swaps only for br-lan; a WAN-side queue's egress is the upload.
        out = run({'sqm.eth1': 'queue', 'sqm.eth1.interface': 'eth1', 'sqm.eth1.upload': '10000',
                   'sqm.eth1.download': '85000'}, [('get_config', {})])
        self.assertEqual((out['results'][0]['upload'], out['results'][0]['download']), (10, 85))


if __name__ == '__main__':
    unittest.main()
