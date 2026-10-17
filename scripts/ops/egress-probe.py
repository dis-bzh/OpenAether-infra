#!/usr/bin/env python3
"""Does this OVH project give a private network outbound Internet? (infra #365, #362)

Builds the minimum a cluster node sits on: a private network + subnet, a router with an
external gateway (SNAT on) and one small instance with no public address whose cloud-init
tries TCP connects to public addresses and prints the verdict on its console. Reads the
console through the compute API, then removes everything it created, also on error and on
SIGINT/SIGTERM. Needs only an empty project: run it BEFORE `cluster-up`.

Usage: egress-probe.py [--dry-run]       (credentials: the OS_* variables of .env.sh)
Exit:  0 the instance reached the Internet   1 it did not   2 the probe could not run
       (no credentials, a leftover of an earlier probe, quota, timeout: nothing was concluded).
All resources carry the prefix oa-egress-probe-<random>; a leftover of that prefix refuses the run.
Environment: OA_PROBE_IMAGE (default "Ubuntu 22.04"), OA_PROBE_FLAVOR (default d2-2, else the smallest),
OA_PROBE_EXT_NET (default Ext-Net), OA_PROBE_TARGETS (host:port list, default 1.1.1.1:443 9.9.9.9:443),
OA_PROBE_WAIT (seconds to wait for the console verdict, default 300).
"""
import json
import os
import secrets
import signal
import sys
import time
import urllib.error
import urllib.request

PREFIX = 'oa-egress-probe-'
MARK = 'OA-EGRESS-PROBE-RESULT'
CIDR = '10.250.0.0/24'


class Fail(Exception):
    """The probe could not conclude: exit 2."""


class Api:
    """The real OpenStack REST API (keystone password auth, like purge-orphans/ovh.py)."""

    def __init__(self):
        try:
            base = os.environ['OS_AUTH_URL'].rstrip('/')
            if not base.startswith('https://'):
                raise Fail('OS_AUTH_URL must be https:// (the password goes in this request). Nothing was sent.')
            url = base + ('/auth/tokens' if base.endswith('/v3') else '/v3/auth/tokens')
            auth = {'auth': {'identity': {'methods': ['password'], 'password': {'user': {
                'name': os.environ['OS_USERNAME'], 'password': os.environ['OS_PASSWORD'],
                'domain': {'name': os.environ.get('OS_USER_DOMAIN_NAME', 'Default')}}}},
                'scope': {'project': {'id': os.environ['OS_PROJECT_ID']}}}}
            self.region = os.environ['OS_REGION_NAME'].lower()
        except KeyError as e:
            raise Fail(f'missing credential {e}: source .env.sh first') from None
        req = urllib.request.Request(url, data=json.dumps(auth).encode(), headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                self.tok, self.cat = r.headers['X-Subject-Token'], json.load(r)['token']['catalog']
        except (urllib.error.URLError, TimeoutError) as e:
            raise Fail(f'authentication refused or unreachable ({str(e)[:60]})') from None

    def ep(self, t):
        for s in self.cat:
            if s['type'] == t:
                for e in s['endpoints']:
                    if e['interface'] == 'public' and e['region'].lower() == self.region:
                        return e['url'].rstrip('/')
        raise Fail(f'no {t} endpoint in region {self.region}')

    def call(self, service, method, path, body=None):
        u = self.ep(service) + path
        req = urllib.request.Request(u, method=method, data=None if body is None else json.dumps(body).encode(),
                                     headers={'X-Auth-Token': self.tok, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise Fail(f'{method} {service}{path.split("?")[0]} -> HTTP {e.code} {e.read()[:160].decode(errors="replace")}') from None
        except (urllib.error.URLError, TimeoutError) as e:
            raise Fail(f'{method} {service}{path.split("?")[0]} -> {str(e)[:80]}') from None


def user_data(targets):
    """cloud-init: try each target with bash /dev/tcp, print one line on the console."""
    probe = ' '.join(f'"{t}"' for t in targets)
    script = (
        "#!/bin/bash\n"
        f"ok=no; for t in {probe}; do h=${{t%:*}}; p=${{t##*:}}; "
        "if timeout 8 bash -c \"exec 3<>/dev/tcp/$h/$p\" 2>/dev/null; then ok=yes; reached=$t; break; fi; done\n"
        f"echo \"{MARK}=$ok ${{reached:-none}}\" | tee /dev/console /dev/ttyS0 /dev/kmsg >/dev/null 2>&1\n")
    import base64
    return base64.b64encode(script.encode()).decode()


def verdict(console):
    """The last result line of a console text -> 'yes' | 'no' | None."""
    out = None
    for line in console.splitlines():
        if MARK + '=' in line:
            word = line.split(MARK + '=', 1)[1].split()
            out = word[0] if word else None
    return out if out in ('yes', 'no') else None


def plan(name):
    return [f'network {name}-net', f'subnet {name}-subnet ({CIDR})', f'router {name}-router (external gateway, SNAT on)',
            f'router interface {name}-subnet', f'server {name}-vm (no public address)']


def run(api, dry=False, wait=300, sleep=time.sleep, image='Ubuntu 22.04', flavor='d2-2', ext='Ext-Net',
        targets=('1.1.1.1:443', '9.9.9.9:443'), out=print):
    """Returns 0 yes, 1 no. Raises Fail when nothing could be concluded. Always cleans up."""
    name = PREFIX + secrets.token_hex(3)
    # a leftover of an earlier probe refuses the run (it may be billing)
    left = [x for x in api.call('network', 'GET', '/v2.0/networks')['networks'] if x['name'].startswith(PREFIX)]
    left += [x for x in api.call('compute', 'GET', '/servers/detail')['servers'] if x['name'].startswith(PREFIX)]
    left += [x for x in api.call('network', 'GET', '/v2.0/routers')['routers'] if x['name'].startswith(PREFIX)]
    if left:
        raise Fail('a leftover of an earlier probe exists (' + ', '.join(sorted({x['name'] for x in left})) +
                   '): delete it (task purge-orphans PROVIDER=ovh APPLY=1) before probing again')
    if dry:
        out(f'dry run: would create (prefix {name}):')
        for p in plan(name):
            out('  ' + p)
        out(f'  then read the console of the server for up to {wait} s and remove all of it.')
        return 0
    made = []   # (kind, id) in creation order; removed in reverse

    def cleanup():
        for kind, ident, extra in reversed(made):
            try:
                if kind == 'server':
                    api.call('compute', 'DELETE', f'/servers/{ident}')
                    for _ in range(60):
                        try:
                            api.call('compute', 'GET', f'/servers/{ident}')
                        except Fail:
                            break
                        sleep(5)
                elif kind == 'rif':
                    api.call('network', 'PUT', f'/v2.0/routers/{ident}/remove_router_interface', {'subnet_id': extra})
                elif kind == 'router':
                    api.call('network', 'PUT', f'/v2.0/routers/{ident}', {'router': {'external_gateway_info': None}})
                    api.call('network', 'DELETE', f'/v2.0/routers/{ident}')
                else:
                    api.call('network', 'DELETE', f'/v2.0/{kind}s/{ident}')
            except Fail as e:
                out(f'  ! cleanup of {kind} {ident} failed: {e}  (run: task purge-orphans PROVIDER=ovh APPLY=1)')
        made.clear()

    def on_signal(sig, _frame):
        cleanup()
        sys.exit(2)
    old = [signal.signal(s, on_signal) for s in (signal.SIGINT, signal.SIGTERM)] if _main_thread() else []
    try:
        extnets = [n for n in api.call('network', 'GET', '/v2.0/networks')['networks'] if n['name'] == ext]
        if not extnets:
            raise Fail(f'external network {ext} not found')
        imgs = api.call('image', 'GET', '/v2/images?name=' + image.replace(' ', '%20'))['images']
        if not imgs:
            raise Fail(f'image {image!r} not found (OA_PROBE_IMAGE)')
        fl = api.call('compute', 'GET', '/flavors/detail')['flavors']
        pick = [f for f in fl if f['name'] == flavor] or sorted(fl, key=lambda f: (f['vcpus'], f['ram'], f['disk']))[:1]
        if not pick:
            raise Fail('no flavor')
        net = api.call('network', 'POST', '/v2.0/networks', {'network': {'name': name + '-net'}})['network']
        made.append(('network', net['id'], None))
        sub = api.call('network', 'POST', '/v2.0/subnets', {'subnet': {
            'name': name + '-subnet', 'network_id': net['id'], 'cidr': CIDR, 'ip_version': 4,
            'dns_nameservers': ['1.1.1.1', '8.8.8.8']}})['subnet']
        made.append(('subnet', sub['id'], None))
        rt = api.call('network', 'POST', '/v2.0/routers', {'router': {
            'name': name + '-router', 'admin_state_up': True,
            'external_gateway_info': {'network_id': extnets[0]['id'], 'enable_snat': True}}})['router']
        made.append(('router', rt['id'], None))
        api.call('network', 'PUT', f'/v2.0/routers/{rt["id"]}/add_router_interface', {'subnet_id': sub['id']})
        made.append(('rif', rt['id'], sub['id']))
        srv = api.call('compute', 'POST', '/servers', {'server': {
            'name': name + '-vm', 'imageRef': imgs[0]['id'], 'flavorRef': pick[0]['id'],
            'networks': [{'uuid': net['id']}], 'user_data': user_data(targets)}})['server']
        made.append(('server', srv['id'], None))
        out(f'probe {name}: server {srv["id"][:8]} created, waiting for its verdict (max {wait} s)')
        t0, res = time.time(), None
        while time.time() - t0 < wait:
            sleep(10)
            st = api.call('compute', 'GET', f'/servers/{srv["id"]}')['server']
            if st['status'] == 'ERROR':
                raise Fail('the probe server went to ERROR: ' + json.dumps(st.get('fault', {}))[:160])
            if st['status'] != 'ACTIVE':
                continue
            try:
                con = api.call('compute', 'POST', f'/servers/{srv["id"]}/action', {'os-getConsoleOutput': {'length': 200}}).get('output', '')
            except Fail:
                continue
            res = verdict(con)
            if res:
                break
        if res is None:
            raise Fail(f'no verdict on the console after {wait} s (image without cloud-init, or the instance has no metadata)')
        out(f'egress {"YES" if res == "yes" else "NO"}: a private-network instance behind a SNAT router '
            f'{"reached" if res == "yes" else "could not reach"} {", ".join(targets)}')
        return 0 if res == 'yes' else 1
    finally:
        cleanup()
        for s, o in zip((signal.SIGINT, signal.SIGTERM), old):
            signal.signal(s, o)


def _main_thread():
    import threading
    return threading.current_thread() is threading.main_thread()


def main(argv):
    dry = '--dry-run' in argv
    try:
        api = Api()
        return run(api, dry=dry, wait=int(os.environ.get('OA_PROBE_WAIT', '300')),
                   image=os.environ.get('OA_PROBE_IMAGE', 'Ubuntu 22.04'), flavor=os.environ.get('OA_PROBE_FLAVOR', 'd2-2'),
                   ext=os.environ.get('OA_PROBE_EXT_NET', 'Ext-Net'),
                   targets=tuple(os.environ.get('OA_PROBE_TARGETS', '1.1.1.1:443 9.9.9.9:443').split()))
    except Fail as e:
        print(f'✗ probe could not conclude: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
