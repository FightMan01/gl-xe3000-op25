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

    def watchdog(self, body, extra='', funcs=('administratively_enabled','sim_lock_watch')):
        self.write_state()
        s=(S/'gl-cellular-boot-redial').read_text()
        funcs='\n'.join(function(s,n) for n in funcs)
        funcs=funcs.replace('/usr/sbin/gl-cellular-sim-unlock','mock_unlock')
        setup=f'''
logger() {{ :; }}
uptime_sec() {{ echo 1000; }}
cpin_query() {{ cpin="${{TEST_CPIN:-+CPIN: SIM PIN}}"; cpin_valid=1; }}
mock_unlock() {{ echo UNLOCK; return "${{UNLOCK_STATUS:-0}}"; }}
relock_reconnect() {{ echo RECONNECT; }}
sim_locked_ticks=0; sim_was_locked=0; last_pin_bounce=0
relock_quiet_until=0; tick_up=1000; svc_nudged=0
cpin_valid=0; cpin=""; RELOCK_MIN_GAP=45; SIM_REINIT={self.root}/sim-reinit
relock_handled=0
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

    def test_watchdog_reuses_cached_cpin_between_ticks(self):
        # CPIN_EVERY exists so a healthy link is not asked about its SIM on
        # every single tick; sim_lock_watch must actually honour the cache or
        # the rate-limiting in the main loop buys nothing.
        body='\ncpin="+CPIN: READY"; cpin_valid=1; cpin_query() { echo QUERIED; }; sim_lock_watch; echo "cached=$cpin"'
        self.assertEqual(self.watchdog(body),['cached=+CPIN: READY'])

    def test_burst_sighting_inside_the_gap_is_still_counted(self):
        # A second re-lock inside the rate-limit window is counted as a
        # sighting and acted on by the next tick that is far enough past the
        # last attempt - it must not be swallowed.
        self.assertEqual(self.watchdog('last_pin_bounce=990; sim_lock_watch'),[])
        body='\nlast_pin_bounce=900; sim_lock_watch; echo "ticks=$sim_locked_ticks gap_after=$last_pin_bounce"'
        self.assertEqual(self.watchdog(body),['UNLOCK','RECONNECT','ticks=1 gap_after=1000'])

    def test_refused_unlock_keeps_the_gap_open_for_the_retry(self):
        body='\nUNLOCK_STATUS=5; sim_lock_watch; echo "ticks=$sim_locked_ticks gap=$last_pin_bounce"'
        self.assertEqual(self.watchdog(body),['UNLOCK','ticks=1 gap=0'])

    def test_sim_reinit_without_pin_reconnects(self):
        # The card came back READY (no PIN, or the user typed it in): nothing
        # on the +CPIN path fires, so the re-init indication itself has to be
        # what bounces wwan.
        marker=self.root/'sim-reinit'
        marker.write_text('"pb done"\n')
        body='\nsim_reinit_watch; echo "marker_left=$([ -e "$SIM_REINIT" ] && echo yes || echo no)"'
        out=self.watchdog(body, extra='TEST_CPIN="+CPIN: READY"',
                          funcs=('administratively_enabled','sim_lock_watch','sim_reinit_watch'))
        self.assertEqual(out,['RECONNECT','marker_left=no'])

    def test_sim_reinit_defers_to_the_pin_path_and_to_boot(self):
        # The marker is an edge trigger and is always consumed; what matters is
        # that neither a PIN-locked card (sim_lock_watch owns it) nor the
        # just-after-boot window bounces wwan a second time.
        for extra in ('TEST_CPIN="+CPIN: SIM PIN"', 'relock_quiet_until=999999'):
            with self.subTest(extra=extra):
                (self.root/'sim-reinit').write_text('"sms done"\n')
                body='\nsim_reinit_watch; echo "marker_left=$([ -e "$SIM_REINIT" ] && echo yes || echo no)"'
                out=self.watchdog(body, extra=extra,
                                  funcs=('administratively_enabled','sim_lock_watch','sim_reinit_watch'))
                self.assertEqual(out,['marker_left=no'])

    def test_sim_reinit_marker_is_consumed_without_a_reconnect_path(self):
        (self.root/'sim-reinit').unlink(missing_ok=True)
        body='\nsim_reinit_watch; echo "done"'
        self.assertEqual(self.watchdog(body, funcs=('administratively_enabled','sim_reinit_watch')),['done'])

    def test_pin_relock_does_not_bounce_twice(self):
        # With a PIN enabled the modem reports the re-init as well, seconds
        # after the unlock. One tick must produce one bounce, not two.
        (self.root/'sim-reinit').write_text('"pb done"\n')
        body='\nTEST_CPIN="+CPIN: SIM PIN"; sim_lock_watch; echo "handled=$relock_handled"; TEST_CPIN="+CPIN: READY"; sim_reinit_watch'
        self.assertEqual(self.watchdog(body, funcs=('administratively_enabled','sim_lock_watch','sim_reinit_watch')),
                         ['UNLOCK','RECONNECT','handled=1'])

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

    def modem_reset(self, ok_after, remove='echo 1 > "$PCI/devices/$pci_dev/remove"'):
        # Fake sysfs; the QMI node appears after the ok_after-th rescan (0 = never).
        pci=self.root/'pci'; dev=pci/'devices/0000:01:00.0'; dev.mkdir(parents=True)
        (dev/'vendor').write_text('0x17cb\n'); (dev/'device').write_text('0x0308\n')
        self.write_state()
        s=(S/'gl-cellular-modem-reset').read_text()
        s=s.replace('PCI=/sys/bus/pci',f'PCI={pci}').replace('/dev/mhi_QMI0',str(self.root/'qmi'))
        s=s.replace('/var/run/gl-net-reconfig.lock',str(self.root/'net.lock'))
        s=s.replace('[ -c "$QMI_NODE" ]','[ -e "$QMI_NODE" ]').replace('/usr/sbin/gl-cellular-pcie-pm',':')
        s=s.replace('echo 1 > "$PCI/devices/$pci_dev/remove"',remove)
        s=s.replace('echo 1 > "$PCI/rescan"','rescan')
        prefix=f"""
ifdown() {{ echo IFDOWN >> {self.root}/ops; }}
ifup() {{ echo IFUP >> {self.root}/ops; }}
rescan() {{ echo RESCAN >> {self.root}/ops; n=$(grep -c RESCAN {self.root}/ops); [ {ok_after} -gt 0 ] && [ "$n" -ge {ok_after} ] && : > "$QMI_NODE"; return 0; }}
"""
        s=s.replace('\nfind_modem() {',prefix+'\nfind_modem() {',1)
        (self.root/'reset').write_text(s)
        r=subprocess.run(['/bin/sh',str(self.root/'reset')],env=self.env,capture_output=True,text=True,timeout=30)
        ops=(self.root/'ops').read_text().split() if (self.root/'ops').exists() else []
        return r.returncode, ops

    def test_modem_reset_first_round(self):
        self.assertEqual(self.modem_reset(1),(0,['IFDOWN','RESCAN','IFUP']))

    def test_modem_reset_retries_once_when_mhi_stays_down(self):
        self.assertEqual(self.modem_reset(2),(0,['IFDOWN','RESCAN','RESCAN','IFUP']))

    def test_modem_reset_gives_up_after_two_rounds(self):
        self.assertEqual(self.modem_reset(0),(1,['IFDOWN','RESCAN','RESCAN','IFUP']))

    def test_modem_reset_stuck_remove_times_out(self):
        rc,ops=self.modem_reset(1,remove='/bin/sleep 2')
        self.assertEqual((rc,ops),(1,['IFDOWN','IFUP']))

    def test_watchdog_resets_when_qmi_node_missing(self):
        s=(S/'gl-cellular-boot-redial').read_text()
        start=s.index('\t\t# AT can come back over USB')
        block=s[start:s.index('\n\t\tfi\n',s.index('qmi_missing=$((qmi_missing + 1))'))+5].replace('-c "$QMI_NODE"','-e "$QMI_NODE"')
        code=f"""
logger() {{ :; }}; do_sleep() {{ :; }}
modem_hard_reset() {{ echo RESET; : > "$QMI_NODE"; return 0; }}
QMI_NODE={self.root}/qmi; AT_DEAD_TICKS=3; CHECK_PERIOD=10; qmi_missing=0
for tick in 1 2 3 4; do
{block}
echo "tick $tick $qmi_missing"
done
"""
        r=subprocess.run(['/bin/sh','-c',code],capture_output=True,text=True,timeout=5)
        self.assertEqual([l for l in r.stdout.splitlines()],['tick 1 1','tick 2 2','RESET','tick 4 0'],r.stderr)

    def test_flashing_flag_blocks_every_modem_entry_point(self):
        flag=self.root/'flashing'; flag.write_text('1\n')
        # Any of these reaching the modem would show up as a call to a mocked tool.
        trap='\n'.join(f'{t}() {{ echo CALLED-{t}; }}' for t in ('ifdown','ifup','ubus','logger','flock','uci'))
        cases={'gl-cellular-modem-reset':1,'gl-cellular-wwan-reconnect':1,'gl-cellular-sim-unlock':5,'gl-cellular-rat':1}
        for name,rc in cases.items():
            s=(S/name).read_text().replace('/var/run/gl-cellular-flashing',str(flag)).replace('. /usr/share/libubox/jshn.sh','')
            r=subprocess.run(['/bin/sh','-c',trap+'\n'+s],capture_output=True,text=True,timeout=10)
            self.assertEqual((r.returncode,'CALLED' in r.stdout),(rc,False),name+r.stdout+r.stderr)
        s=(S/'gl-cellular-mhi-reset').read_text().replace('/var/run/gl-cellular-flashing',str(flag))
        s=s.replace('reset) cmd_reset ;;','x) ;;').replace('cmd_reset ;;','echo RESET ;;').replace('tune)  cmd_tune ;;','tune) echo TUNE ;;')
        for arg,out,rc in (('reset','',1),('tune','TUNE',0)):
            r=subprocess.run(['/bin/sh','-c',s,'mhi',arg],capture_output=True,text=True,timeout=10)
            self.assertEqual((r.stdout.strip(),r.returncode),(out,rc),arg+r.stderr)
        q=(PACKAGE/'files/lib/netifd/proto/qcm.sh').read_text()
        guard=q[q.index('\tif [ -e /var/run/gl-cellular-flashing ]'):q.index('\tdevice="${device:-/dev/mhi_QMI0}"')]
        code=('proto_notify_error() { echo "$2"; }; proto_block_restart() { echo BLOCK; }; setup() {\n'
              +guard.replace('/var/run/gl-cellular-flashing',str(flag))+'\necho STARTED\n}; setup')
        r=subprocess.run(['/bin/sh','-c',code],capture_output=True,text=True,timeout=5)
        self.assertEqual((r.stdout.split(),r.returncode),(['MODEM_FLASHING','BLOCK'],1))

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

    def test_qcm_syncs_initial_attach_profile_only_when_different(self):
        s=(PACKAGE/'files/lib/netifd/proto/qcm.sh').read_text()
        fns=function(s,'_qcm_at_ip_type')+'\n'+function(s,'_qcm_sync_attach_profile')
        # The gate that blocked A03: profile 1 held the MBN's DT APN, so the
        # attach failed before quectel-CM could ever rewrite it.
        diff='+CGDCONT: 1,"IPV4V6","internet.v6.telekom","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0",0'
        same='+CGDCONT: 1,"IP","internet.telekom","0.0.0.0",0'
        cases=[(same,'internet.telekom','ipv4',[]),
               (diff,'internet.telekom','ipv4',['AT+CGDCONT=1,"IP","internet.telekom"']),
               (same,'internet.telekom','ipv4v6',['AT+CGDCONT=1,"IPV4V6","internet.telekom"']),
               (diff,'internet.telekom','ipv6',['AT+CGDCONT=1,"IPV6","internet.telekom"']),
               (diff,'internet.telekom','',['AT+CGDCONT=1,"IPV4V6","internet.telekom"']),
               (diff,'data.example.com','ipv4v6',['AT+CGDCONT=1,"IPV4V6","data.example.com"']),
               ('+CGDCONT: 2,"IPV4V6","ims",0','internet.telekom','ipv4',['AT+CGDCONT=1,"IP","internet.telekom"']),
               (diff,'','ipv4',[]),
               ('','internet.telekom','ipv4',[])]
        mock='''_qcm_at() { case "$1" in
'AT+CGDCONT?') cat "$CASE_DIR/cgdcont" ;;
'AT+CGDCONT='*) printf '%s\\n' "$1" >> "$CASE_DIR/writes"; echo OK ;;
esac; }
logger() { :; }
'''
        for line,apn,pdp,want in cases:
            with self.subTest(apn=apn,pdp=pdp,line=line):
                (self.root/'cgdcont').write_text(line+'\n' if line else '')
                (self.root/'writes').unlink(missing_ok=True)
                code=mock+fns+'\n_qcm_sync_attach_profile "$1" "$2"'
                r=subprocess.run(['/bin/sh','-c',code,'sh',apn,pdp],env=self.env,capture_output=True,text=True,timeout=5)
                self.assertEqual(r.returncode,0,r.stderr)
                got=(self.root/'writes').read_text().splitlines() if (self.root/'writes').exists() else []
                self.assertEqual(got,want)

    def test_qcm_sync_failure_is_reported_not_fatal(self):
        s=(PACKAGE/'files/lib/netifd/proto/qcm.sh').read_text()
        fns=function(s,'_qcm_at_ip_type')+'\n'+function(s,'_qcm_sync_attach_profile')
        code='''_qcm_at() { case "$1" in
'AT+CGDCONT?') echo '+CGDCONT: 1,"IPV4V6","internet.v6.telekom",0' ;;
*) echo ERROR ;;
esac; }
logger() { :; }
'''+fns+'\n_qcm_sync_attach_profile internet.telekom ipv4'
        r=subprocess.run(['/bin/sh','-c',code],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,1)

    def test_qcm_sync_rejects_an_apn_that_would_break_the_at_command(self):
        s=(PACKAGE/'files/lib/netifd/proto/qcm.sh').read_text()
        fns=function(s,'_qcm_at_ip_type')+'\n'+function(s,'_qcm_sync_attach_profile')
        code='''_qcm_at() { echo CALLED >> "$CASE_DIR/writes"; }
logger() { :; }
'''+fns+'\n_qcm_sync_attach_profile "$1" "$2"; echo "rc=$?"'
        for apn in ('bad"apn','bad,apn','bad apn'):
            with self.subTest(apn=apn):
                (self.root/'writes').unlink(missing_ok=True)
                r=subprocess.run(['/bin/sh','-c',code,'sh',apn,'ipv4'],env=self.env,capture_output=True,text=True,timeout=5)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertEqual(r.stdout.strip(),'rc=1',r.stderr)
                self.assertFalse((self.root/'writes').exists())

    def test_qcm_sync_runs_before_attach_gate_and_pdp_sweep(self):
        s=(PACKAGE/'files/lib/netifd/proto/qcm.sh').read_text()
        sync=s.index('_qcm_sync_attach_profile "$apn" "$pdptype"')
        self.assertLess(sync,s.index('not attached after'))
        self.assertLess(sync,s.index('_qcm_deactivate_pdp "$apn" "$pdptype"'))

    def test_watchdog_at_alive_retries_once_but_still_detects_a_hang(self):
        s=(S/'gl-cellular-boot-redial').read_text()
        f=function(s,'at_alive')
        code='''at_query() { [ -e "$CASE_DIR/second" ] && echo OK; : > "$CASE_DIR/second"; }
sleep() { :; }
'''+f+'''
rm -f "$CASE_DIR/second"
at_alive; echo "retry=$?"
at_query() { :; }
at_alive; echo "dead=$?"
'''
        r=subprocess.run(['/bin/sh','-c',code],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(r.stdout.split(),['retry=0','dead=1'],r.stderr)


if __name__ == '__main__':
    unittest.main()
