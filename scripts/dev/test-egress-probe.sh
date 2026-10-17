#!/usr/bin/env bash
# Offline test of scripts/ops/egress-probe.py against a fake OpenStack API (no provider, no network):
# yes / no verdicts, the cleanup on every path (error, timeout, signal-free), the dry run, the refusal on a leftover.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
python3 -I - <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('probe', 'scripts/ops/egress-probe.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Fake:
    def __init__(self, console='', leftover=False, fail_on=None, status='ACTIVE'):
        self.res = {}; self.log = []; self.console = console; self.fail_on = fail_on; self.status = status
        self.nets = [{'id': 'ext1', 'name': 'Ext-Net'}] + ([{'id': 'old', 'name': m.PREFIX + 'dead-net'}] if leftover else [])
        self.n = 0
    def call(self, svc, method, path, body=None):
        self.log.append((method, path))
        if self.fail_on and self.fail_on in path and method == 'POST':
            raise m.Fail('boom')
        if path == '/v2.0/networks' and method == 'GET': return {'networks': list(self.nets)}
        if path == '/servers/detail': return {'servers': []}
        if path == '/v2.0/routers' and method == 'GET': return {'routers': []}
        if path.startswith('/v2/images'): return {'images': [{'id': 'img'}]}
        if path == '/flavors/detail': return {'flavors': [{'id': 'f1', 'name': 'd2-2', 'vcpus': 1, 'ram': 1, 'disk': 1}]}
        if method == 'POST' and path.endswith('/action'): return {'output': self.console}
        if method == 'POST':
            self.n += 1; key = [k for k in ('network', 'subnet', 'router', 'server') if k in (body or {})][0]
            self.res[f'{key}{self.n}'] = path; return {key: {'id': f'{key}{self.n}', 'status': 'ACTIVE'}}
        if method == 'GET' and path.startswith('/servers/'):
            if any(p == ('DELETE', path) for p in self.log): raise m.Fail('gone')
            return {'server': {'status': self.status}}
        return {}
    def cleaned(self):
        d = [p for (me, p) in self.log if me == 'DELETE']
        return all(any(k in x for x in d) for k in ('/servers/', '/routers/', '/subnets/', '/networks/'))

def run(api, **kw):
    out = []
    try: rc = m.run(api, sleep=lambda s: None, out=out.append, wait=30, **kw)
    except m.Fail as e: rc = 'fail:' + str(e)
    return rc, out
bad = 0
def check(name, cond):
    global bad
    print(('PASS ' if cond else 'FAIL ') + name); bad += (not cond)
a = Fake(console='x\nOA-EGRESS-PROBE-RESULT=yes 1.1.1.1:443\n'); rc, _ = run(a); check('yes verdict -> 0 and everything removed', rc == 0 and a.cleaned())
a = Fake(console='OA-EGRESS-PROBE-RESULT=no none'); rc, _ = run(a); check('no verdict -> 1 and everything removed', rc == 1 and a.cleaned())
a = Fake(console='nothing here'); rc, _ = run(a); check('no console verdict -> Fail (2) and everything removed', str(rc).startswith('fail') and a.cleaned())
a = Fake(status='ERROR'); rc, _ = run(a); check('server ERROR -> Fail and removed', str(rc).startswith('fail') and a.cleaned())
a = Fake(fail_on='/servers'); rc, _ = run(a); check('server creation refused -> Fail, network/router removed', str(rc).startswith('fail') and any('/routers/' in p for _, p in a.log if _ == 'DELETE') and any('/networks/' in p for _, p in a.log if _ == 'DELETE'))
a = Fake(leftover=True); rc, _ = run(a); check('leftover refuses and creates nothing', str(rc).startswith('fail') and not any(me == 'POST' for me, _ in a.log))
a = Fake(); rc, out = run(a, dry=True); check('dry run lists, creates nothing', rc == 0 and len(out) >= 6 and not any(me in ('POST', 'DELETE') for me, _ in a.log))
check('verdict parser takes the last line', m.verdict('OA-EGRESS-PROBE-RESULT=no x\nOA-EGRESS-PROBE-RESULT=yes y') == 'yes' and m.verdict('') is None)
import base64; ud = base64.b64decode(m.user_data(('1.1.1.1:443',))).decode(); check('user-data prints the marker to the console', 'OA-EGRESS-PROBE-RESULT' in ud and '/dev/console' in ud)
sys.exit(1 if bad else 0)
PY
