#!/usr/bin/env bash
# scripts/ops/node-provider.py against a FAKE provider API on localhost: the state words (running, stopped, error, absent,
# transition, unknown) and the hard-reboot requests, for the three clouds. No cloud, no credential.
#
# What it pins: an OVH instance that is ACTIVE reads `running` (the infra #371 shape: the machine runs, the node is silent),
# SHUTOFF and ERROR do not, a machine that is not in the listing is `absent` and NOT an error, an unreachable API exits 2 and
# decides nothing, a hard reboot is only sent to a machine that exists, and the credentials never reach stdout.
# Usage: test-node-provider.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill "${FAKE_PID:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

cat >"$TMP/fake.py" <<'PY'
import http.server, json, sys, threading
scn, log = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return json.loads(self.rfile.read(n) or b"{}")
    def do_GET(self):
        s = json.load(open(scn))
        if self.path.startswith("/compute/v2.1/servers/detail"): self.send(200, {"servers": s.get("ovh", [])})
        elif self.path.startswith("/scw/instance/v1/zones/z1/servers"): self.send(200, {"servers": s.get("scw", [])})
        else: self.send(404, {})
    def do_POST(self):
        b = self.body(); s = json.load(open(scn))
        with open(log, "a") as f: f.write("%s %s\n" % (self.path, json.dumps(b, sort_keys=True)))
        if self.path.endswith("/ReadVms"): self.send(200, {"Vms": s.get("osc", [])})
        else: self.send(202 if "/action" in self.path or "Vms" in self.path else 200, {})
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1])); srv.serve_forever()
PY
: >"$TMP/log"; echo '{}' >"$TMP/scn.json"
python3 -I "$TMP/fake.py" "$TMP/port" "$TMP/scn.json" "$TMP/log" &
FAKE_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"
export OA_PROVIDER_TEST_BASE="http://127.0.0.1:${PORT}"
NP() { python3 -I "$ROOT/scripts/ops/node-provider.py" "$@"; }
scn() { printf '%s' "$1" >"$TMP/scn.json"; : >"$TMP/log"; }
field() { python3 -I -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

echo "=== OVH (OpenStack) ==="
ovh() { printf '{"ovh":[{"id":"s-1","name":"%s","status":"%s","addresses":{"net":[{"addr":"10.0.0.21"}]}}]}' "$1" "$2"; }
for pair in ACTIVE:running SHUTOFF:stopped ERROR:error HARD_REBOOT:transition BUILD:transition WEIRD:unknown; do
  scn "$(ovh c-worker-0 "${pair%%:*}")"
  got="$(NP state ovh --name c-worker-0 | field state)"
  [ "$got" = "${pair#*:}" ] && ok_ "${pair%%:*} reads ${pair#*:}" || bad "${pair%%:*} read '$got', not ${pair#*:}"
done
scn '{"ovh":[]}'
[ "$(NP state ovh --name c-worker-0 | field state)" = absent ] && ok_ "no server of that name reads absent, not an error" || bad "a missing server did not read absent"
scn "$(ovh other ACTIVE)"
[ "$(NP state ovh --name c-worker-0 --ip 10.0.0.21 | field state)" = running ] && ok_ "the private address finds the server when the name differs" || bad "the address fallback failed"
scn "$(ovh c-worker-0 ACTIVE)"
NP hard-reboot ovh --name c-worker-0 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '/servers/s-1/action {"reboot": {"type": "HARD"}}' "$TMP/log" && ok_ "hard-reboot sends a HARD reboot to the right server" || bad "hard-reboot did not post a HARD reboot (rc=$rc: $(cat "$TMP/log"))"
# --younger-than (infra #371, D6/D11 of lab 27 part B): the automatic reboot of a node that never answered at creation must not reach a
# machine that has been serving: only a RUNNING machine created less than N seconds ago.
fresh="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"; old="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
ovhc() { printf '{"ovh":[{"id":"s-1","name":"c-cp-2","status":"%s","created":"%s","addresses":{}}]}' "$1" "$2"; }
scn "$(ovhc ACTIVE "$fresh")"
NP hard-reboot ovh --name c-cp-2 --younger-than 1800 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '/servers/s-1/action {"reboot": {"type": "HARD"}}' "$TMP/log" \
  && ok_ "--younger-than: a running machine created 2 minutes ago is rebooted" || bad "a fresh machine was not rebooted (rc=$rc: $(cat "$TMP/log"))"
scn "$(ovhc ACTIVE "$old")"
NP hard-reboot ovh --name c-cp-2 --younger-than 1800 >"$TMP/out" 2>/dev/null; rc=$?
[ "$rc" -eq 3 ] && ! grep -q action "$TMP/log" && grep -q 'created less than 1800 s ago' "$TMP/out" \
  && ok_ "--younger-than: a machine created 3 hours ago is NOT rebooted (rc 3, says why)" || bad "an old machine was rebooted or the refusal is silent (rc=$rc: $(cat "$TMP/log") $(cat "$TMP/out"))"
scn "$(ovhc SHUTOFF "$fresh")"
NP hard-reboot ovh --name c-cp-2 --younger-than 1800 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ! grep -q action "$TMP/log" && ok_ "--younger-than: a machine that is not running is not rebooted" || bad "a stopped machine was rebooted (rc=$rc)"
scn '{"ovh":[{"id":"s-1","name":"c-cp-2","status":"ACTIVE","addresses":{}}]}'
NP hard-reboot ovh --name c-cp-2 --younger-than 1800 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ! grep -q action "$TMP/log" && ok_ "--younger-than: a listing without a creation date refuses (an unknown age is not young)" || bad "an undated machine was rebooted (rc=$rc)"
NP hard-reboot scaleway --name c-cp-2 --younger-than 1800 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok_ "--younger-than is refused outside OVH, where it is not implemented" || bad "--younger-than was accepted for scaleway"
scn '{"ovh":[]}'
NP hard-reboot ovh --name c-worker-0 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ! grep -q action "$TMP/log" && ok_ "no hard reboot is sent for a machine that does not exist (rc 3)" || bad "hard-reboot on an absent machine: rc=$rc log=$(cat "$TMP/log")"

echo
echo "=== Scaleway ==="
scn '{"scw":[{"id":"i-9","name":"c-cp-1","state":"running"}]}'
[ "$(SCW_SECRET_KEY=x SCW_DEFAULT_PROJECT_ID=p NP state scaleway --name c-cp-1 | field state)" = running ] && ok_ "a running instance reads running" || bad "scaleway running"
scn '{"scw":[{"id":"i-9","name":"c-cp-1","state":"stopped"}]}'
[ "$(NP state scaleway --name c-cp-1 | field state)" = stopped ] && ok_ "a stopped instance reads stopped" || bad "scaleway stopped"
scn '{"scw":[]}'
[ "$(NP state scaleway --name c-cp-1 | field state)" = absent ] && ok_ "no instance of that name reads absent" || bad "scaleway absent"
scn '{"scw":[{"id":"i-9","name":"c-cp-1","state":"running"}]}'
NP hard-reboot scaleway --name c-cp-1 >/dev/null && grep -q '/servers/i-9/action {"action": "reboot"}' "$TMP/log" && ok_ "hard-reboot posts the reboot action" || bad "scaleway hard-reboot"

echo
echo "=== Outscale ==="
scn '{"osc":[{"VmId":"i-aa","State":"running"}]}'
[ "$(NP state outscale --name c-cp-2 | field state)" = running ] && ok_ "a running VM reads running" || bad "outscale running"
scn '{"osc":[{"VmId":"i-aa","State":"stopped"}]}'
[ "$(NP state outscale --name c-cp-2 | field state)" = stopped ] && ok_ "a stopped VM reads stopped" || bad "outscale stopped"
scn '{"osc":[]}'
[ "$(NP state outscale --name c-cp-2 | field state)" = absent ] && ok_ "no VM reads absent" || bad "outscale absent"
scn '{"osc":[{"VmId":"i-aa","State":"running"}]}'
NP hard-reboot outscale --name c-cp-2 >/dev/null
grep -q 'StopVms {"ForceStop": true, "VmIds": \["i-aa"\]}' "$TMP/log" && grep -q 'StartVms {"VmIds": \["i-aa"\]}' "$TMP/log" \
  && ok_ "hard-reboot is a ForceStop then a Start, not a guest reboot" || bad "outscale hard-reboot: $(cat "$TMP/log")"

echo
echo "=== failure shapes ==="
OA_PROVIDER_TEST_BASE="http://127.0.0.1:1" NP state ovh --name x >"$TMP/out" 2>"$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] && ok_ "an unreachable API exits 2 and prints no state" || bad "unreachable API: rc=$rc out=$(cat "$TMP/out")"
env -u OA_PROVIDER_TEST_BASE -u OS_AUTH_URL python3 -I "$ROOT/scripts/ops/node-provider.py" state ovh --name x >"$TMP/out" 2>"$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'missing credential' "$TMP/err" && ok_ "a missing credential exits 2 and names it" || bad "missing credential: rc=$rc $(cat "$TMP/err")"
env -u OA_PROVIDER_TEST_BASE OS_AUTH_URL=http://insecure OS_USERNAME=u OS_PASSWORD=sekret OS_PROJECT_ID=p OS_REGION_NAME=r python3 -I "$ROOT/scripts/ops/node-provider.py" state ovh --name x >"$TMP/out" 2>"$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && ! grep -q sekret "$TMP/out" "$TMP/err" && grep -q 'https' "$TMP/err" && ok_ "a plain-http auth URL is refused before the password is sent, and the password is never printed" || bad "plain http auth: rc=$rc"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
