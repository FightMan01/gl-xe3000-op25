#!/usr/bin/env python3
"""Offline PIN and recovery regressions; all AT and network operations are mocked."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

PACKAGE = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'gl-feed/net/gl-cellular'
S = PACKAGE / 'files/usr/sbin'

MOCK = r'''#!/usr/bin/env python3
import fcntl, json, os, pathlib, sys, time
root=pathlib.Path(os.environ['CASE_DIR']); kind=pathlib.Path(sys.argv[0]).name
if kind=='flock':
 try: fcntl.flock(int(sys.argv[-1]),fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError: sys.exit(1)
 sys.exit(0)
if kind=='sleep': time.sleep(0.005); sys.exit(0)
if kind=='logger': sys.exit(0)
p=root/'state.json'; d=json.loads(p.read_text())
if kind=='uci':
 args=[a for a in sys.argv[1:] if a!='-q']; op=args[0]; key=args[1] if len(args)>1 else ''
 if op=='get':
  if key not in d: sys.exit(1)
  print(d[key]); sys.exit(0)
 if op=='show':
  for k,v in d.items():
   if k.startswith(key+'.'): print(k+"='"+str(v)+"'")
  sys.exit(0)
 if op=='set': k,v=key.split('=',1); d[k]=v
 if op=='delete': d.pop(key,None)
 if op=='commit' and d.get('commit_failure'): sys.exit(1)
 p.write_text(json.dumps(d)); sys.exit(0)
if kind=='mock-at':
 cmd=sys.argv[1]
 with (root/'at.log').open('a') as f: f.write(cmd.split('=')[0]+'\n')
 if cmd=='AT+CPIN?':
  submitted=(root/'submitted').exists()
  ready=d.get('initial_ready') or (submitted and d.get('outcome','ok') in ('ok','lost_ok'))
  print('+CPIN: READY\nOK' if ready else '+CPIN: SIM PIN\nOK')
 elif cmd=='AT+QCCID': print('+QCCID: '+d.get('current_iccid','89880001')+'\nOK')
 elif cmd=='AT+QPINC?': print(d.get('counter','+QPINC: "SC",3,10\nOK'))
 elif cmd.startswith('AT+CPIN='):
  with (root/'submitted').open('a') as f: f.write('sent\n')
  print({'ok':'OK','wrong':'+CME ERROR: 16','lost_ok':'','unknown':''}[d.get('outcome','ok')])
'''


def function(source, name):
    return re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', source, re.M | re.S).group()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = {'network.wwan.pincode': '1234', 'network.wwan.pin_iccid': '89880001'}
        self.env = dict(os.environ, CASE_DIR=str(self.root), PATH=str(self.root)+':'+os.environ['PATH'])
        for name in ('uci', 'flock', 'logger', 'sleep', 'mock-at'):
            p = self.root / name
            p.write_text(MOCK)
            p.chmod(0o755)
        s = (S/'gl-cellular-sim-unlock').read_text().replace('. /usr/share/libubox/jshn.sh', '')
        s = s.replace(function(s, 'at'), 'at() { mock-at "$@"; }')
        s = s.replace('/var/run/gl-cellular-sim-unlock.lock', str(self.root/'unlock.lock'))
        self.unlock = self.root/'unlock'
        self.unlock.write_text(s)

    def write_state(self):
        (self.root/'state.json').write_text(json.dumps(self.state))

    def run_unlock(self):
        return subprocess.run(['/bin/sh', str(self.unlock)], env=self.env, capture_output=True, text=True, timeout=15).returncode

    def submissions(self):
        p = self.root/'submitted'
        return len(p.read_text().splitlines()) if p.exists() else 0

    def test_matching_card(self):
        self.write_state()
        self.assertEqual(self.run_unlock(), 0)
        self.assertEqual(self.submissions(), 1)
        self.assertNotIn('network.wwan.pin_pending', json.loads((self.root/'state.json').read_text()))

    def test_fail_closed_inputs(self):
        for change, code in [({'current_iccid': ''},4), ({'current_iccid':'other'},1),
                             ({'network.wwan.pin_iccid':''},1), ({'counter':'ERROR'},4),
                             ({'counter':'+QPINC: "SC",1,10'},2),
                             ({'network.wwan.pincode':'12"34'},1), ({'commit_failure':True},5),
                             ({'network.wwan.auto':'0'},5), ({'gl-cellular.state.scan_in_progress':'1'},5)]:
            with self.subTest(change=change):
                old = self.state.copy()
                self.state.update(change)
                self.write_state()
                self.assertEqual(self.run_unlock(), code)
                self.assertEqual(self.submissions(), 0)
                self.state = old

    def test_ambiguous_reply_unused_attempt_resubmits(self):
        self.state['outcome']='unknown'
        self.write_state()
        self.assertEqual(self.run_unlock(),5)
        self.assertEqual(self.run_unlock(),5)
        self.assertEqual(self.submissions(),2)
        self.assertNotIn('network.wwan.pin_failed',json.loads((self.root/'state.json').read_text()))

    def test_ambiguous_reply_used_attempt_blocks(self):
        self.state['outcome']='unknown'
        self.write_state()
        self.assertEqual(self.run_unlock(),5)
        d=json.loads((self.root/'state.json').read_text())
        d['counter']='+QPINC: "SC",2,10'
        (self.root/'state.json').write_text(json.dumps(d))
        self.assertEqual(self.run_unlock(),2)
        self.assertEqual(self.submissions(),1)
        self.assertEqual(json.loads((self.root/'state.json').read_text()).get('network.wwan.pin_failed'),'1')

    def test_lost_reply_but_ready(self):
        self.state['outcome']='lost_ok'
        self.write_state()
        self.assertEqual(self.run_unlock(),0)
        self.assertEqual(self.submissions(),1)

    def test_explicit_rejection(self):
        self.state['outcome']='wrong'
        self.write_state()
        self.assertEqual(self.run_unlock(),2)
        self.assertEqual(self.run_unlock(),2)
        self.assertEqual(self.submissions(),1)

    def test_pending_cleared_after_manual_ready(self):
        self.state.update({'network.wwan.pin_pending':'1','initial_ready':True})
        self.write_state()
        self.assertEqual(self.run_unlock(),0)
        self.assertEqual(self.submissions(),0)
        self.assertNotIn('network.wwan.pin_pending',json.loads((self.root/'state.json').read_text()))

    def test_two_callers_submit_once(self):
        self.write_state()
        callers=[subprocess.Popen(['/bin/sh',str(self.unlock)],env=self.env) for _ in range(2)]
        self.assertEqual([p.wait(timeout=15) for p in callers],[0,0])
        self.assertEqual(self.submissions(),1)

    def test_lock_timeout_never_queries_at(self):
        import fcntl
        self.write_state()
        with (self.root/'unlock.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.run_unlock(),5)
        self.assertFalse((self.root/'at.log').exists())

    def watchdog(self, body, extra=''):
        self.write_state()
        s=(S/'gl-cellular-boot-redial').read_text()
        funcs='\n'.join(function(s,n) for n in ('administratively_enabled','sim_lock_watch'))
        funcs=funcs.replace('/usr/sbin/gl-cellular-sim-unlock','mock_unlock')
        setup='''
logger() { :; }
uptime_sec() { echo 1000; }
cpin_query() { cpin="${TEST_CPIN:-+CPIN: SIM PIN}"; cpin_valid=1; }
mock_unlock() { echo UNLOCK; return "${UNLOCK_STATUS:-0}"; }
relock_reconnect() { echo RECONNECT; }
sim_locked_ticks=0; sim_was_locked=0; last_pin_bounce=0
relock_quiet_until=0; tick_up=1000; svc_nudged=0
'''
        r=subprocess.run(['/bin/sh','-c',setup+funcs+'\n'+extra+'\n'+body],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout.strip().splitlines()

    def test_watchdog_failed_unlock_no_reconnect(self):
        self.assertEqual(self.watchdog('UNLOCK_STATUS=5; sim_lock_watch'),['UNLOCK'])

    def test_watchdog_quiet_first_sighting_waits(self):
        self.assertEqual(self.watchdog('relock_quiet_until=999999; TEST_CPIN="+CPIN: SIM PIN"; sim_lock_watch'),[])

    def test_watchdog_quiet_second_sighting_acts(self):
        self.assertEqual(self.watchdog('relock_quiet_until=999999; sim_locked_ticks=1; TEST_CPIN="+CPIN: SIM PIN"; sim_lock_watch'),['UNLOCK','RECONNECT'])

    def test_watchdog_disabled_and_scan(self):
        for key in ('network.wwan.auto','network.wwan.disabled','gl-cellular.state.dial_enabled','gl-cellular.state.scan_in_progress'):
            self.state={key: '0' if key.endswith(('auto','dial_enabled')) else '1'}
            self.assertEqual(self.watchdog('sim_lock_watch'),[])

    def test_watchdog_rechecks_intent_after_unlock(self):
        self.assertEqual(self.watchdog('sim_lock_watch', 'mock_unlock() { echo UNLOCK; uci set network.wwan.auto=0; }'),['UNLOCK'])

    def test_watchdog_success(self):
        self.assertEqual(self.watchdog('sim_lock_watch'),['UNLOCK','RECONNECT'])

    def test_reset_result_and_quiet_state(self):
        source=(S/'gl-cellular-boot-redial').read_text()
        f=function(source,'modem_hard_reset').replace('/usr/sbin/gl-cellular-modem-reset','mock_reset')
        for result in (0,1):
            setup=f"""
administratively_enabled() {{ return 0; }}
logger() {{ :; }}
uptime_sec() {{ echo 1000; }}
date() {{ echo 1000; }}
mock_reset() {{ return {result}; }}
reset_window_start=1000; reset_count=0; MODEM_RESET_WINDOW=3600; MODEM_RESET_MAX=3
MODEM_RESET_REBOOT=0; RELOCK_QUIET=120; GRACE_SEC=30
sim_was_locked=1; sim_locked_ticks=3; cpin_valid=1; at_dead=9
relock_quiet_until=0; redial_pending=0
"""
            body='\nmodem_hard_reset; rc=$?; echo "$rc $sim_was_locked $sim_locked_ticks $cpin_valid $at_dead $relock_quiet_until $redial_pending"'
            r=subprocess.run(['/bin/sh','-c',setup+f+body],capture_output=True,text=True,timeout=5)
            self.assertEqual(r.stdout.strip(), '0 0 0 0 0 1120 1' if result==0 else '1 1 3 1 9 0 0')

    def test_reset_budget_backs_off_instead_of_stopping(self):
        source=(S/'gl-cellular-boot-redial').read_text()
        f=function(source,'modem_hard_reset').replace('/usr/sbin/gl-cellular-modem-reset','mock_reset')
        for last,expected in ((1900,'1 3'),(1000,'0 4')):
            setup=f"""
administratively_enabled() {{ return 0; }}
logger() {{ :; }}
uptime_sec() {{ echo 2000; }}
date() {{ echo 2000; }}
mock_reset() {{ return 0; }}
reset_window_start=1000; reset_count=3; last_hard_reset={last}; reset_refused_logged=0
MODEM_RESET_WINDOW=3600; MODEM_RESET_MAX=3; MODEM_RESET_BACKOFF=900
MODEM_RESET_REBOOT=0; RELOCK_QUIET=120; GRACE_SEC=30
"""
            body='\nmodem_hard_reset; echo "$? $reset_count"'
            r=subprocess.run(['/bin/sh','-c',setup+f+body],capture_output=True,text=True,timeout=5)
            self.assertEqual(r.stdout.strip(),expected,r.stderr)

    def test_unknown_pending_blocks_normal_reset_ladder(self):
        self.state['network.wwan.pin_pending']='1'
        self.write_state()
        s=(S/'gl-cellular-boot-redial').read_text()
        code='administratively_enabled() { return 0; }; cpin_valid=1; cpin="";\n'+function(s,'enabled')+'\nenabled'
        r=subprocess.run(['/bin/sh','-c',code],env=self.env,timeout=5)
        self.assertEqual(r.returncode,1)

    def test_relock_accepts_http_and_cancels_disabled(self):
        s=(S/'gl-cellular-boot-redial').read_text()
        f=function(s,'relock_reconnect').replace('/usr/sbin/gl-cellular-wwan-reconnect','mock_reconnect')
        for disabled in (False,True):
            self.write_state()
            setup="""
administratively_enabled() { uci -q get network.wwan.auto | grep -q '^0$' && return 1; return 0; }
cpin_query() { cpin='+CPIN: READY'; }
uptime_sec() { echo 1000; }
mock_reconnect() { :; }
wwan4_status() { up=true; device=mock0; }
ping_confirms() { echo PING; return 1; }
https_confirms() { echo HTTP; return 0; }
modem_hard_reset() { echo RESET; }
"""
            if disabled:
                setup+='sleep() { uci set network.wwan.auto=0; };\n'
            r=subprocess.run(['/bin/sh','-c',setup+f+'\nrelock_reconnect'],env=self.env,capture_output=True,text=True,timeout=5)
            self.assertEqual(r.returncode,1 if disabled else 0,r.stderr)
            self.assertEqual(r.stdout.strip(),'' if disabled else 'PING\nHTTP')

    def test_qcm_pending_is_retryable(self):
        s=(PACKAGE/'files/lib/netifd/proto/qcm.sh').read_text()
        start=s.index('\tcase $? in',s.index('/usr/sbin/gl-cellular-sim-unlock'))
        end=start+re.search(r'\n[ \t]*esac',s[start:]).start()
        case=s[start:end]+ '\nesac'
        code='proto_notify_error() { echo "$2"; }; proto_block_restart() { echo BLOCK; }; sleep() { :; }; run_case() { (exit 5);\n'+case+'\n}; run_case'
        r=subprocess.run(['/bin/sh','-c',code],capture_output=True,text=True,timeout=5)
        self.assertEqual(r.stdout.strip(),'PIN_PENDING')
        self.assertEqual(r.returncode,1)


if __name__ == '__main__':
    unittest.main()
