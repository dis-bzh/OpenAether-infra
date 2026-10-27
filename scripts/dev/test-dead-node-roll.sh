#!/usr/bin/env bash
# The --dead mode of rolling-replace.sh (task cluster-replace-node): the survey of the survivors, the order of the steps,
# the refusals. Function tests against stub kubectl/talosctl plus assertions on the script's text for what a stub cannot see.
#
# Pinned: a dead node is replaced ONLY when it is the only node down and, for a control plane, a quorum of the other etcd
# members is healthy (otherwise it is the disaster-recovery case); nothing is drained; the etcd member of a control plane is
# removed BEFORE its Node object is deleted; --dead needs one named node and cannot be combined with --upgrade.
# Usage: test-dead-node-roll.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
RR="$ROOT/scripts/ops/rolling-replace.sh"

cat >"$STUB/kubectl" <<'S'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_CALLS"
case "$*" in
  *"get nodes --no-headers"*) cat "$STUB_NODES" ;;
  *"describe nodes"*) cat "$STUB_DESCRIBE" 2>/dev/null ;;
  *"get node "*) [ -f "$STUB_GONE" ] && exit 1; exit 0 ;;
  *"cordon "*) [ -f "$STUB_CORDON_FAILS" ] && exit 1; exit 0 ;;
  *"delete node "*) exit 0 ;;
esac
exit 0
S
cat >"$STUB/talosctl" <<'S'
#!/usr/bin/env bash
case "$*" in *"service etcd"*) ep="$(sed -E 's/.*-e 127.0.0.1:([0-9]+).*/\1/' <<<"$*")"
  grep -qx "$ep" "$STUB_HEALTHY" && printf 'NODE  SERVICE\n1  etcd  Running  OK  HEALTH  OK\n' || exit 1 ;; esac
S
chmod +x "$STUB"/kubectl "$STUB"/talosctl
export PATH="$STUB:$PATH" STUB_CALLS="$STUB/calls" STUB_NODES="$STUB/nodes" STUB_DESCRIBE="$STUB/describe" STUB_HEALTHY="$STUB/healthy" STUB_GONE="$STUB/gone" STUB_CORDON_FAILS="$STUB/cordonfails"

extract() { awk -v fns="$1" 'BEGIN{n=split(fns,a,",");for(i=1;i<=n;i++)w[a[i]]=1} /^[a-z_]+\(\) \{/{nm=$1;sub(/\(\).*/,"",nm);ins=(nm in w)} ins{print} ins&&/^\}/{ins=0}' "$ROOT/scripts/lib/roll-gates.sh"; }
# shellcheck disable=SC2034  # read by the extracted functions
KCTL=(kubectl)
# shellcheck disable=SC2034
CP_IPS=(10.0.0.10 10.0.0.11 10.0.0.12)
info() { :; }; ok() { :; }; warn() { printf 'WARN:%s\n' "$*" >&2; }; hr() { :; }
die() { printf '%s\n' "$*" >&2; exit 42; }
# shellcheck disable=SC2034
TUNNEL_OFFSET=0
eval "$(extract 'talos_ep,worker_requests,worker_cpu_requests,worker_memory_requests,dead_node_survey,cordon_dead,delete_dead_node_object')"

survey() { (dead_node_survey "$@") >"$STUB/out" 2>&1; echo $?; }
nodes() { printf '%b' "$1" >"$STUB_NODES"; }
echo "=== dead_node_survey ==="
: >"$STUB/describe"
nodes 'w0 NotReady <none>\nw1 Ready <none>\nw2 Ready <none>\ncp0 Ready control-plane\n'
[ "$(survey worker 0 w0)" = 0 ] && ok_ "the dead worker is the only node down: clean" || bad "refused a lone dead worker: $(cat "$STUB/out")"
nodes 'w0 NotReady <none>\nw1 NotReady <none>\nw2 Ready <none>\n'
{ [ "$(survey worker 0 w0)" = 42 ] && grep -q 'another node is not Ready: w1' "$STUB/out"; } && ok_ "a second node down is refused and named (one node at a time; a zone loss is another procedure)" || bad "second node down passed"
nodes ''
[ "$(survey worker 0 w0)" = 42 ] && ok_ "an unanswered API refuses to replace blind" || bad "empty node list passed"

# Memory is only said: the pods of the dead node are Pending anyway, and the replacement gives them room (F-SHRINKMEM).
printf 'Name: w1\n  cpu     1 (30%%)\n  memory  3Gi (90%%)\nName: w2\n  cpu     1 (30%%)\n  memory  3Gi (95%%)\n' >"$STUB/describe"
nodes 'w0 NotReady <none>\nw1 Ready <none>\nw2 Ready <none>\n'
{ [ "$(survey worker 0 w0)" = 0 ] && grep -q 'request 185% of memory' "$STUB/out"; } \
  && ok_ "workers short of MEMORY (CPU fine) are warned about, and the replacement still goes ahead" || bad "memory not said, or refused: $(cat "$STUB/out")"
: >"$STUB/describe"

printf '%s\n' 50001 50002 >"$STUB/healthy"; nodes 'cp0 NotReady control-plane\ncp1 Ready control-plane\ncp2 Ready control-plane\n'
[ "$(survey cp 0 cp0)" = 0 ] && ok_ "a control plane: two healthy etcd members of three is a quorum" || bad "refused with a quorum: $(cat "$STUB/out")"
printf '%s\n' 50001 >"$STUB/healthy"; nodes 'cp0 NotReady control-plane\ncp1 Ready control-plane\ncp2 NotReady control-plane\n'
{ [ "$(survey cp 0 cp0)" = 42 ] && grep -q 'dr-restore-plan' "$STUB/out"; } && ok_ "one healthy member of three is NOT a replacement: it names dr-restore-plan" || bad "replaced without a quorum: $(cat "$STUB/out")"

echo
echo "=== cordon_dead and delete_dead_node_object ==="
: >"$STUB/calls"; rm -f "${STUB:?}/cordonfails" "${STUB:?}/gone"
cordon_dead w0 && delete_dead_node_object w0
{ grep -q 'cordon w0' "$STUB/calls" && grep -q 'delete node w0' "$STUB/calls" && ! grep -q 'drain' "$STUB/calls"; } && ok_ "cordon then delete the Node object, and never a drain" || bad "calls: $(cat "$STUB/calls")"
: >"$STUB/calls"; : >"$STUB/gone"; : >"$STUB/cordonfails"
cordon_dead w0 2>/dev/null; delete_dead_node_object w0
{ ! grep -q 'delete node' "$STUB/calls"; } && ok_ "a Node object that is already gone (an interrupted run) is not an error" || bad "deleted a missing node"

echo
echo "=== the script's own text ==="
bash "$RR" ovh --dead >/dev/null 2>"$STUB/err"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q -- '--dead needs --node' "$STUB/err"; } && ok_ "--dead without a named node is refused (it acts on one node)" || bad "--dead alone: rc=$rc $(cat "$STUB/err")"
bash "$RR" ovh --dead --node=x --upgrade >/dev/null 2>"$STUB/err"; rc=$?
[ "$rc" -eq 2 ] && ok_ "--dead cannot be combined with --upgrade" || bad "--dead --upgrade: rc=$rc"

body="$(awk '/^replace_node\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RR")"
a="$(grep -n 'cordon_dead "\$node_name"' <<<"$body" | head -1 | cut -d: -f1)"
b="$(grep -n 'etcd_remove_member' <<<"$body" | head -1 | cut -d: -f1)"
c="$(grep -n 'delete_dead_node_object' <<<"$body" | head -1 | cut -d: -f1)"
{ [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; } \
  && ok_ "cordon, then the etcd member is removed, THEN the Node object is deleted" || bad "order wrong (cordon:$a etcd:$b delete:$c)"
grep -q 'if \[\[ \$DEAD -eq 1 \]\]; then' <<<"$body" && awk '/\$DEAD -eq 1/{d=1} d&&/cordon_drain "\$node_name"/{found=1} END{exit !found}' <<<"$body" \
  && ok_ "the drain is only on the else branch of --dead" || bad "cordon_drain is not guarded by --dead"
awk '/dead_node_survey "\$ONLY_T"/{s=1;next} s&&/^  else$/{e=1;next} s&&/preflight_roll$/{exit !e}' "$RR" \
  && ok_ "preflight_roll (every node Ready) sits on the else branch: a dead-node run uses the survey instead" || bad "preflight_roll is not behind the --dead branch"
grep -q 'api_want=\$(( \${#CP_IPS\[@\]} - DEAD ))' "$RR" && ok_ "the other apiservers must serve (the dead one cannot)" || bad "the apiserver gate counts the dead control plane"

echo
echo "=== a node whose Node object is gone needs --ip, and the message says so (lab 27 sitting 3) ==="
# The real script, in a throwaway tree: only tofu, talosctl and kubectl and the bootstrap check are stubs.
T="$STUB/tree"; mkdir -p "$T/scripts/ops" "$T/scripts/internal" "$T/cluster/envs" "$STUB/bin"
cp "$RR" "$T/scripts/ops/"; ln -s "$ROOT/scripts/lib" "$T/scripts/lib"
printf '#!/usr/bin/env bash\necho true\n' >"$T/scripts/internal/bootstrap-in-state.sh"; chmod +x "$T/scripts/internal/bootstrap-in-state.sh"
printf 'cluster_name = "lab"\nenvironment = "dev"\n' >"$T/cluster/envs/management-ovh.tfvars"; : >"$T/cluster/talosconfig"; : >"$T/cluster/kubeconfig"
cat >"$STUB/bin/tofu" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "output -json" ] && echo '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.0.20","10.0.0.21"]}}'
exit 0
S
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/bin/kubectl"; chmod +x "$STUB/bin/tofu" "$STUB/bin/kubectl"
( cd "$T/cluster" && PATH="$STUB/bin:$PATH" bash "$T/scripts/ops/rolling-replace.sh" ovh --dead --node=lab-dev-worker-1 --dry-run --yes ) >"$STUB/out" 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'needed for a WORKER as well as for a control plane' "$STUB/out" \
  && grep -q 'task cluster-replace-node PROVIDER=ovh NODE=lab-dev-worker-1 -- --even-if-running --ip=<private address>' "$STUB/out" \
  && grep -q 'workers: 10.0.0.20 10.0.0.21' "$STUB/out"; } \
  && ok_ "a worker without a Node object: the message names --ip, the whole command and the state's addresses" || bad "message: rc=$rc $(cat "$STUB/out")"
( cd "$T/cluster" && PATH="$STUB/bin:$PATH" bash "$T/scripts/ops/rolling-replace.sh" ovh --dead --node=lab-dev-worker-1 --ip=10.0.0.21 --dry-run --yes ) >"$STUB/out" 2>&1
grep -q 'Single node: worker 1 (10.0.0.21)' "$STUB/out" && ok_ "with --ip the same node is found by its address" || bad "--ip not accepted: $(head -c 600 "$STUB/out")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
