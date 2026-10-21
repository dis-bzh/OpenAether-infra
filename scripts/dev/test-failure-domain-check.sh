#!/usr/bin/env bash
# scripts/ops/failure-domain-check.sh against stub tofu and kubectl: for each failure domain, would losing it stop the
# control plane, the workers' capacity, OpenBao, a database, a volume or the Gateway? Fixtures are the shape the real
# commands print (node names and addresses are placeholders). A cluster spread over three domains passes; the shapes that
# a zone loss really breaks (three control planes in two domains, a database whose instances share a domain, a volume whose
# replicas share one) each fail by name.
# Usage: test-failure-domain-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/failure-domain-check.sh}"
W="$(mktemp -d)"; trap 'rm -rf "${W:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
mkdir -p "$W/bin"; export ST="$W"

cat >"$W/bin/tofu" <<'S'
#!/usr/bin/env bash
[ "$1" = output ] && cat "$ST/outputs.json"
S
cat >"$W/bin/kubectl" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"get nodes -o json"*) cat "$ST/nodes.json" ;;
  *"describe nodes"*) cat "$ST/describe.txt" 2>/dev/null ;;
  *"get pods -l app=openbao"*) cat "$ST/vault.json" ;;
  *"cnpg.io/cluster"*) cat "$ST/db.json" ;;
  *"gateway-name"*) cat "$ST/gw.json" ;;
  *"replicas.longhorn.io"*) cat "$ST/replicas.json" ;;
esac
S
chmod +x "$W"/bin/*; export PATH="$W/bin:$PATH"

# fixture: 3 control planes (cp0-2) and 3 workers (w0-2), one of each per domain a, b, c
outputs() { # <cp zones json> <worker zones json>
  printf '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.0.20","10.0.0.21","10.0.0.22"]},"control_plane_zones":{"value":%s},"worker_zones":{"value":%s}}' "$1" "$2" >"$W/outputs.json"
}
node() { printf '{"metadata":{"name":"%s"},"status":{"addresses":[{"type":"InternalIP","address":"%s"}]}}' "$1" "$2"; }
echo "{\"items\":[$(node cp0 10.0.0.10),$(node cp1 10.0.0.11),$(node cp2 10.0.0.12),$(node w0 10.0.0.20),$(node w1 10.0.0.21),$(node w2 10.0.0.22)]}" >"$W/nodes.json"
pod() { printf '{"metadata":{"labels":{"cnpg.io/cluster":"%s"}},"spec":{"nodeName":"%s"}}' "$1" "$2"; }
vpod() { printf '{"spec":{"nodeName":"%s"}}' "$1"; }
rep() { printf '{"spec":{"volumeName":"%s","nodeID":"%s"}}' "$1" "$2"; }
printf 'Name:  w0\n  cpu  1200m (30%%)\nName:  w1\n  cpu  1400m (35%%)\nName:  w2\n  cpu  1000m (25%%)\n' >"$W/describe.txt"
healthy() {
  printf 'Name:  w0\n  cpu  1200m (30%%)\nName:  w1\n  cpu  1400m (35%%)\nName:  w2\n  cpu  1000m (25%%)\n' >"$W/describe.txt"
  outputs '["a","b","c"]' '["a","b","c"]'
  echo "{\"items\":[$(vpod w0),$(vpod w1),$(vpod w2)]}" >"$W/vault.json"
  echo "{\"items\":[$(pod db w0),$(pod db w1),$(pod db w2)]}" >"$W/db.json"
  echo "{\"items\":[$(vpod w0),$(vpod w1)]}" >"$W/gw.json"
  echo "{\"items\":[$(rep v1 w0),$(rep v1 w1)]}" >"$W/replicas.json"
}
run() { OUT="$(cd "$W" && bash "$SUT" ovh "$@" 2>&1)"; RC=$?; }

echo "=== a cluster spread over three domains ==="
healthy; run
{ [ "$RC" = 0 ] && grep -q 'survivable' <<<"$OUT"; } && ok_ "losing any one of three domains is survivable" || bad "healthy cluster refused (rc=$RC): $OUT"
grep -q 'If a is lost' <<<"$OUT" && grep -q 'If c is lost' <<<"$OUT" && ok_ "every domain is examined" || bad "not every domain examined"

echo
echo "=== what a zone loss really breaks ==="
healthy; outputs '["a","a","b"]' '["a","b","c"]'; run
{ [ "$RC" = 1 ] && grep -q 'only 1 of 3 stay, etcd quorum is 2' <<<"$OUT"; } && ok_ "two control planes in one domain: that domain's loss stops etcd, and it says so" || bad "cp spread not caught (rc=$RC): $OUT"
healthy; outputs '["a","b","c"]' '["a","a","b"]'; run
{ [ "$RC" = 1 ] && grep -q 'workers: 1 of 3 stay' <<<"$OUT"; } && ok_ "two workers in one domain leave one worker: refused" || bad "worker spread not caught: $OUT"
healthy; printf 'Name:  w0\n  cpu  3000m (75%%)\nName:  w1\n  cpu  3000m (75%%)\nName:  w2\n  cpu  1600m (40%%)\n' >"$W/describe.txt"; run
{ [ "$RC" = 0 ] && grep -q 'requests 190% fit in 200%' <<<"$OUT"; } && ok_ "190% requested fits in the 200% of the two workers that stay" || bad "capacity not computed: $OUT"
printf 'Name:  w0\n  cpu  3600m (90%%)\nName:  w1\n  cpu  3600m (90%%)\nName:  w2\n  cpu  3000m (75%%)\n' >"$W/describe.txt"; run
{ [ "$RC" = 1 ] && grep -q 'pods stay Pending' <<<"$OUT"; } && ok_ "255% requested cannot fit in 200%: refused, naming docs/capacity.md" || bad "over-capacity passed: $OUT"
healthy; echo "{\"items\":[$(vpod w0),$(vpod w0),$(vpod w1)]}" >"$W/vault.json"; run
{ [ "$RC" = 1 ] && grep -q 'OpenBao: 2 of 3 raft members there' <<<"$OUT"; } && ok_ "two OpenBao members in one domain lose the raft quorum with it" || bad "openbao not caught: $OUT"
healthy; echo "{\"items\":[$(pod db w0),$(pod db w0)]}" >"$W/db.json"; run
{ [ "$RC" = 1 ] && grep -q 'database db: no instance outside a' <<<"$OUT"; } && ok_ "a database whose instances share a domain is named" || bad "cnpg not caught: $OUT"
healthy; echo "{\"items\":[$(rep v1 w0),$(rep v1 w0),$(rep v2 w1),$(rep v2 w2)]}" >"$W/replicas.json"; run
{ [ "$RC" = 1 ] && grep -q 'volume v1: every replica is in a' <<<"$OUT" && ! grep -q 'volume v2' <<<"$OUT"; } && ok_ "a Longhorn volume with all replicas in one domain is named, one spread is not" || bad "longhorn not caught: $OUT"
healthy; echo "{\"items\":[$(vpod w0)]}" >"$W/gw.json"; run
{ [ "$RC" = 1 ] && grep -q 'gateway: every pod is in a' <<<"$OUT"; } && ok_ "a single Gateway pod is a zone SPOF" || bad "gateway not caught: $OUT"

echo
echo "=== what cannot be read ==="
healthy; echo '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.0.20"]}}' >"$W/outputs.json"; run
{ [ "$RC" = 0 ] && grep -q 'UNCHECKED' <<<"$OUT"; } && ok_ "a state without the zone outputs is UNCHECKED, not green" || bad "missing zones: rc=$RC $OUT"
run --strict
[ "$RC" = 1 ] && ok_ "...and fatal under --strict" || bad "--strict passed an unchecked state"
healthy; : >"$W/vault.json"; run
{ [ "$RC" = 0 ] && grep -q 'OpenBao pods could not be listed' <<<"$OUT"; } && ok_ "an unreadable component is reported UNCHECKED" || bad "unreadable openbao: rc=$RC $OUT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
