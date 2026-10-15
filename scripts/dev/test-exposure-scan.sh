#!/usr/bin/env bash
# scripts/ops/exposure-scan.sh: which public ports answer, and the verdict drawn from that. The probe is a
# stub table (OA_PROBE), plus one run of the REAL probe against a listener on loopback. SUT overrides the
# script under test (how the mutants run).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/exposure-scan.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [ -z "${LPID:-}" ] || kill "$LPID" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The stub probe: "<host> <port>" lines in $OPEN_TABLE are open, everything else is closed.
cat >"$TMP/probe" <<'STUB'
#!/usr/bin/env bash
grep -qx "$1 $2" "$OPEN_TABLE"
STUB
chmod +x "$TMP/probe"
export OA_PROBE="$TMP/probe" OPEN_TABLE="$TMP/open"
B=192.0.2.1 A=192.0.2.2 W=192.0.2.3   # RFC 5737 documentation addresses
run() { OUT="$(bash "$SUT" "$@" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')"; RC=${PIPESTATUS[0]}; }
table() { : >"$OPEN_TABLE"; local l; for l in "$@"; do echo "$l" >>"$OPEN_TABLE"; done; }

echo "=== from an allowed source ==="
table "$B 22" "$A 6443" "$W 80" "$W 443"
run --bastion $B --api-lb $A --app-lb $W
[ "$RC" = 0 ] && grep -q '^  ✓ bastion: 22 open' <<<"$OUT" && grep -q '✓ api LB: 6443 open' <<<"$OUT" && grep -q '✓ app LB: 80 443 open' <<<"$OUT" \
  && ok "22 / 6443 / 80+443 and nothing else: green" || bad "the good case: rc=$RC $OUT"

table "$B 22" "$A 6443" "$W 80" "$W 443" "$B 50000"
run --bastion $B --api-lb $A --app-lb $W
[ "$RC" != 0 ] && grep -q '✗ bastion: reachable but must not be: 50000' <<<"$OUT" \
  && ok "the Talos API open on the bastion FAILS, by port" || bad "50000 open passed: rc=$RC $OUT"

table "$B 22" "$A 6443" "$A 22" "$W 80" "$W 443"
run --bastion $B --api-lb $A --app-lb $W
[ "$RC" != 0 ] && grep -q '✗ api LB: reachable but must not be: 22' <<<"$OUT" \
  && ok "SSH answering on the API load balancer FAILS" || bad "22 on the LB passed: rc=$RC $OUT"

table "$B 22" "$A 6443" "$W 80"
run --bastion $B --api-lb $A --app-lb $W
[ "$RC" != 0 ] && grep -q '✗ app LB: expected open but unreachable: 443' <<<"$OUT" \
  && ok "443 closed on the app LB FAILS: a missing rule is as wrong as an open one" || bad "closed 443 passed: rc=$RC $OUT"

table "$B 22" "$B 6443" "$A 6443"
run --bastion $B --api-lb $A
[ "$RC" != 0 ] && grep -q '✗ bastion: reachable but must not be: 6443' <<<"$OUT" \
  && ok "6443 on the bastion FAILS (the LB's port, not the bastion's)" || bad "6443 on the bastion passed: rc=$RC $OUT"

echo "=== from a source the allowlist does not contain ==="
table "$W 80" "$W 443"
run --bastion $B --api-lb $A --app-lb $W --from denied
[ "$RC" = 0 ] && grep -q '✓ bastion: no port open' <<<"$OUT" && ok "22 and 6443 closed, the Gateway open: green" || bad "denied, good: rc=$RC $OUT"
table "$B 22" "$W 80" "$W 443"
run --bastion $B --api-lb $A --app-lb $W --from denied
[ "$RC" != 0 ] && grep -q '✗ bastion: reachable but must not be: 22' <<<"$OUT" \
  && ok "SSH answering a stranger FAILS: the allowlist does not hold" || bad "22 open to a stranger passed: rc=$RC $OUT"

echo "=== missing pieces ==="
table "$B 22" "$A 6443"
run --bastion $B --api-lb $A --app-lb N/A
[ "$RC" = 0 ] && grep -q 'deploy_app_lb=false' <<<"$OUT" && ok "no app LB (N/A) is said, not failed" || bad "N/A app LB: rc=$RC $OUT"
run --bastion $B
[ "$RC" != 0 ] && grep -q '? no API load balancer address' <<<"$OUT" && ok "an address that was not given is UNCHECKED, never green" || bad "missing API LB: rc=$RC $OUT"
run
[ "$RC" = 2 ] && ok "no address at all is a usage error" || bad "no args: rc=$RC"

echo "=== the real probe, against a listener on loopback ==="
unset OA_PROBE
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -I -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True: s.accept()' "$PORT" &
LPID=$!
sleep 1
# The sensitive list is just that port: the listener stands for a service that must not be reachable.
OA_SCAN_SENSITIVE="$PORT" run --bastion 127.0.0.1 --from denied
[ "$RC" != 0 ] && grep -q "reachable but must not be: $PORT" <<<"$OUT" && ok "an open port is seen by the built-in /dev/tcp probe" || bad "real probe, open: rc=$RC $OUT"
kill "$LPID"; wait "$LPID" 2>/dev/null; LPID=""
# The scan always probes 22, 80, 443 and 6443 as well: a runner with sshd or a web server on loopback would turn "closed" red for a
# reason that has nothing to do with the scan (GitHub-hosted runners listen on 22). Say so and skip that one assertion.
BUSY=""
for p in 22 80 443 6443; do (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && BUSY="$BUSY $p"; done
if [ -n "$BUSY" ]; then
  echo "  - skipped 'a closed port is not reported': something already listens on loopback port(s)$BUSY"
else
  OA_SCAN_SENSITIVE="$PORT" OA_SCAN_TIMEOUT=2 run --bastion 127.0.0.1 --api-lb 127.0.0.1 --from denied
  [ "$RC" = 0 ] && ok "…and a closed one is not" || bad "real probe, closed: rc=$RC $OUT"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
