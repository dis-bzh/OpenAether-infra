#!/usr/bin/env bash
# scripts/ops/shrink-nodes.sh: removing nodes from a bootstrapped cluster, gracefully.
# The script runs for real in a fake repository. tofu, kubectl and talosctl are stubs that log their
# argv to one call log and answer from files, so the ORDER of the calls is what is asserted: the node is
# drained before it is powered off, powered off before the Node is deleted, deleted before anything is
# destroyed. The plans are hand-written fixtures with placeholder addresses, and the state, the nodes and
# the labels have the shape a real cluster gives them (a Scaleway node is three state lines; the control
# plane label has an empty value). SUT overrides the script, which is how mutants run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/shrink-nodes.sh}"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; ST="$W/st"
mkdir -p "$C/envs" "$W/scripts"/{lib,internal,bootstrap,ops} "$W/bin" "$ST"
cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/roll-gates.sh" "$W/scripts/lib/"
cp "$SUT" "$W/scripts/ops/shrink-nodes.sh"
printf 'cluster_name = "oa"\nenvironment = "lab"\n' | tee "$C/envs/management-scaleway.tfvars" >"$C/envs/management-ovh.tfvars"
: >"$C/talosconfig"; : >"$C/kubeconfig"

export CALLS="$W/calls.log" ST
cat >"$W/scripts/internal/bootstrap-in-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_TB:-true}"
STUB
cat >"$W/scripts/bootstrap/talos-tunnels.sh" <<'STUB'
#!/usr/bin/env bash
echo "tunnels SSH_KEY=${SSH_KEY:-unset} $*" >>"$CALLS"
STUB
cat >"$W/scripts/ops/etcd-snapshot.sh" <<'STUB'
#!/usr/bin/env bash
echo "snapshot" >>"$CALLS"; exit "${STUB_SNAPSHOT_RC:-0}"
STUB

# tofu: the plan a run reads is picked by its flags (scope = the lowered counts, destroy = it has -target,
# refresh, close = the full plan after the removal) and copied to the file it was asked to write.
cat >"$W/bin/tofu" <<'STUB'
#!/usr/bin/env bash
echo "tofu $*" >>"$CALLS"
case "$1" in
  output) cat "$ST/outputs.json" ;;
  state)  cat "$ST/state.list" ;;
  show)   cat "${*: -1}" ;;
  plan)
    if [[ " $* " == *" -detailed-exitcode "* ]]; then
      [ "${STUB_FINAL_RC:-0}" = 0 ] || echo "Error: final plan said ${STUB_FINAL_RC}" >&2
      exit "${STUB_FINAL_RC:-0}"
    fi
    [ "${STUB_PLAN_RC:-0}" = 0 ] || { echo "Error: boom" >&2; exit 1; }
    out=""; kind=scope; targets=()
    for a in "$@"; do case "$a" in -out=*) out="${a#-out=}" ;; -target=*) targets+=("${a#-target=}") ;; esac; done
    [[ " $* " == *" -refresh-only "* ]] && kind=refresh
    (( ${#targets[@]} )) && kind=destroy
    [[ $kind == scope && " $* " != *"skip_health_check=true"* ]] && kind=close
    echo "plan $kind" >>"$CALLS"
    case $kind in
      destroy) # the scope plan cut down to the targets, the way a real targeted plan is
        jq -c --argjson t "$(printf '%s\n' "${targets[@]}" | jq -R . | jq -sc .)" --argjson extra "${STUB_DESTROY_EXTRA:-[]}" --argjson drop "${STUB_DESTROY_DROP:-[]}" '
          .resource_changes |= (map(select(.address as $a | (($t | index($a)) != null and (($drop | index($a)) == null))
                                       or (.change.actions == ["update"] and (.type | test("lb_backend|load_balancer_vms"))))) + $extra)' \
          "$ST/plan.scope.json" >"$out" ;;
      *) cp "$ST/plan.$kind.json" "$out" ;;
    esac
    echo "$kind" >"$out.kind" ;;
  apply)
    f="${*: -1}"; kind="$(cat "$f.kind" 2>/dev/null || echo ?)"
    echo "apply $kind $*" >>"$CALLS"
    [ "$kind" = refresh ] && [ -f "$ST/outputs.after.json" ] && cp "$ST/outputs.after.json" "$ST/outputs.json"
    [ "$kind" = close ] && [ -n "${STUB_CLOSE_BREAKS_ETCD:-}" ] && { sed '$d' "$ST/members" >"$ST/members.tmp"; mv "$ST/members.tmp" "$ST/members"; }
    [ "${STUB_APPLY_RC:-0}" = 0 ] || { echo "Error: apply failed" >&2; exit 1; } ;;
esac
exit 0
STUB

cat >"$W/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
argv=" $* "
nodes_of() { jq -r "$1" "$ST/nodes.json"; }
case "$argv" in
  *" get crd clusters.postgresql.cnpg.io "*) [ -n "${STUB_CNPG:-}" ] || { echo 'Error from server (NotFound): crd not found' >&2; exit 1; } ;;
  *" get crd "*longhorn*)
    [ -z "${STUB_CRD_ERROR:-}" ] || { echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1; }
    [ -n "${STUB_LONGHORN:-}" ] || { echo 'Error from server (NotFound): crd not found' >&2; exit 1; } ;;
  *" get nodes -o json "*)
    n=$(( $(cat "$ST/nodes.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$ST/nodes.calls"
    [ "${STUB_NODES_FAIL_NTH:-0}" = "$n" ] && { echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1; }
    cat "$ST/nodes.json" ;;
  *" get node "*"-o jsonpath="*) n="$(awk '{for(i=1;i<=NF;i++) if($i=="node") print $(i+1)}' <<<"$*" | head -1)"
                                 nodes_of ".items[] | select(.metadata.name == \"$n\") | .status.conditions[] | select(.type == \"Ready\") | .status" ;;
  *" get nodes -o jsonpath="*) nodes_of '.items[] | "\(.metadata.name) \(.status.addresses[0].address)"' ;;
  *" get pv -o json "*)
    k=$(( $(cat "$ST/pv.calls" 2>/dev/null || echo 0) + 1 )); echo "$k" >"$ST/pv.calls"
    if [ "$k" -gt "${STUB_PV_AFTER:-0}" ]; then cat "${STUB_PV_FILE:-/dev/null}" 2>/dev/null || echo '{"items":[]}'; else echo '{"items":[]}'; fi ;;
  *" get pods -A --field-selector status.phase=Pending "*) printf '%s' "${STUB_PENDING:-}" ;;
  *" get pdb -A -l cnpg.io/cluster "*) [ "$(cat "$ST/cnpg.pdb" 2>/dev/null || echo true)" = true ] && printf 'db/pg-primary ' ;;
  *" get pdb "*) echo '{"items":[]}' ;;
  *" patch clusters.postgresql.cnpg.io "*) case "$argv" in *'"enablePDB":false'*) echo false >"$ST/cnpg.pdb" ;; *'"enablePDB":true'*) echo true >"$ST/cnpg.pdb" ;; esac ;;
  *" get clusters.postgresql.cnpg.io "*kustomize*) ;;
  *" get clusters.postgresql.cnpg.io "*instances*) echo "db pg 1 1" ;;
  *" get clusters.postgresql.cnpg.io "*) echo "db pg" ;;
  *" describe nodes "*) cat "$ST/describe.txt" ;;
  *" patch nodes.longhorn.io "*)
    k=$(( $(cat "$ST/lhpatch.calls" 2>/dev/null || echo 0) + 1 )); echo "$k" >"$ST/lhpatch.calls"
    [ "$k" -gt "${STUB_LH_PATCH_DENY:-0}" ] || { echo 'admission webhook "validator.longhorn.io" denied the request: spec and status of disks on node are being syncing and please retry later.' >&2; exit 1; } ;;
  *"get nodes.longhorn.io -o json"*) cat "$ST/lh-nodes.json" ;;
  *"get volumes.longhorn.io -o json"*) cat "$ST/lh-volumes.json" ;;
  *"get volumes.longhorn.io -n longhorn-system -o json"*) echo '{"items":[]}' ;;
  *"get replicas.longhorn.io -o json"*)
    k=$(( $(cat "$ST/replicas.calls" 2>/dev/null || echo 0) + 1 )); echo "$k" >"$ST/replicas.calls"
    if [ -n "${STUB_REPLICAS_STUCK:-}" ] || [ "$k" -le "${STUB_REPLICAS_POLLS:-0}" ]; then
      echo '{"items":[{"spec":{"nodeID":"oa-lab-worker-1"}}]}'; else echo '{"items":[]}'; fi ;;
  *" drain "*) [ "${STUB_DRAIN_RC:-0}" = 0 ] || { echo 'drain timeout' >&2; exit 1; } ;;
  *" delete node "*) [ -z "${STUB_DELETE_NOOP:-}" ] || exit 0
                     n="$(awk '{for(i=1;i<=NF;i++) if($i=="node") print $(i+1)}' <<<"$*" | head -1)"
                     jq -c --arg n "$n" '.items |= map(select(.metadata.name != $n))' "$ST/nodes.json" >"$ST/nodes.tmp" && mv "$ST/nodes.tmp" "$ST/nodes.json" ;;
esac
exit 0
STUB

cat >"$W/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
ip=""; ep=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = -n ] && ip="${args[$((i + 1))]}"
  [ "${args[$i]}" = -e ] && ep="${args[$((i + 1))]}"
done
echo "talosctl $*" >>"$CALLS"
case " $* " in
  *" version "*) grep -qxF "$ip" "$ST/down" 2>/dev/null && exit 1 ;;
  *" shutdown "*) [ -z "${STUB_SHUTDOWN_FAIL:-}" ] || exit 1
                  echo "$ip" >>"$ST/down"
                  [ -n "${STUB_KEEP_READY:-}" ] || { jq -c --arg ip "$ip" '(.items[] | select(.status.addresses[0].address == $ip) | .status.conditions[0].status) = "Unknown"' "$ST/nodes.json" >"$ST/nodes.tmp" && mv "$ST/nodes.tmp" "$ST/nodes.json"; } ;;
  *" etcd members "*) [ "$ep" != "${STUB_BROKEN_EP:-none}" ] || exit 1
                      awk '{printf "%s %s node-%s https://%s:2380 https://%s:2379 false\n", $1, $2, $1, $1, $1}' "$ST/members" | sed '1i NODE ID HOSTNAME PEER_URLS CLIENT_URLS LEARNER' ;;
  *" etcd leave "*) [ -n "${STUB_LEAVE_NOOP:-}" ] || { grep -vxF "$ip $(printf '%016x' "${ip##*.}")" "$ST/members" >"$ST/members.tmp"; mv "$ST/members.tmp" "$ST/members"; } ;;
  *" etcd forfeit-leadership "*) echo 99 >"$ST/leader" ;;
  *" etcd status "*) printf 'NODE MEMBER DB_SIZE IN_USE LEADER RAFT\n%s %016x 20MB 5%% %016x 7 7\n' "$ip" "${ip##*.}" "$(cat "$ST/leader" 2>/dev/null || echo "${STUB_LEADER_LAST:-0}")" ;;
  *" service etcd "*)
    case " ${STUB_UNHEALTHY_IPS:-} " in *" $ip "*) echo "etcd Running Fail HEALTH   Fail"; exit 0 ;; esac
    if [ -n "${STUB_UNHEALTHY_WHEN_DOWN:-}" ] && [ -s "$ST/down" ] && [[ "$ip" == 10.0.0.1[01] ]]; then echo "etcd Running Fail HEALTH   Fail"; exit 0; fi
    echo "etcd Running OK HEALTH   OK" ;;
esac
exit 0
STUB
chmod +x "$W"/scripts/*/*.sh "$W"/bin/*

# --- fixtures ------------------------------------------------------------------------
change() { # <address> <type> <name> <index-json> <actions-json> [action_reason]
  printf '{"address":"%s","mode":"managed","type":"%s","name":"%s","index":%s,"change":{"actions":%s}%s}' \
    "$1" "$2" "$3" "$4" "$5" "${6:+,\"action_reason\":\"$6\"}"
}
plan_of() { printf '{"resource_changes":[%s]}' "$(IFS=,; echo "$*")"; }
S='module.scw[0]'; T='module.talos'
worker_del() { # <n> — one resource per line: what lowering workers deletes for worker <n> on Scaleway
  local n="$1" r=delete_because_count_index
  change "$S.scaleway_instance_server.worker[$n]" scaleway_instance_server worker "$n" '["delete"]' $r; echo
  change "$S.scaleway_instance_private_nic.worker[$n]" scaleway_instance_private_nic worker "$n" '["delete"]' $r; echo
  change "$S.scaleway_ipam_ip.worker[$n]" scaleway_ipam_ip worker "$n" '["delete"]' $r; echo
  change "$S.scaleway_block_volume.worker_data[\\\"w$n-d0\\\"]" scaleway_block_volume worker_data "\"w$n-d0\"" '["delete"]' delete_because_each_key; echo
  change "$T.talos_machine_configuration_apply.worker[$n]" talos_machine_configuration_apply worker "$n" '["delete"]' $r; echo
  change "$T.terraform_data.talos_port_ready_worker[$n]" terraform_data talos_port_ready_worker "$n" '["delete"]' $r; echo
}
mapfile -t W1_DEL < <(worker_del 1)
mapfile -t W2_DEL < <(worker_del 2)
CP2_DEL=(
  "$(change "$S.scaleway_instance_server.control_plane[2]" scaleway_instance_server control_plane 2 '["delete"]')"
  "$(change "$S.scaleway_instance_private_nic.control_plane[2]" scaleway_instance_private_nic control_plane 2 '["delete"]')"
  "$(change "$S.scaleway_ipam_ip.control_plane[2]" scaleway_ipam_ip control_plane 2 '["delete"]')"
  "$(change "$T.talos_machine_configuration_apply.control_plane[2]" talos_machine_configuration_apply control_plane 2 '["delete"]')"
  "$(change "$T.terraform_data.talos_port_ready_cp[2]" terraform_data talos_port_ready_cp 2 '["delete"]')"
)
RIDERS=(  # what rides along on any lowered count
  "$(change "$T.talos_machine_configuration_apply.control_plane[0]" talos_machine_configuration_apply control_plane 0 '["update"]')"
  "$(change "$T.talos_machine_configuration_apply.worker[0]" talos_machine_configuration_apply worker 0 '["update"]')"
  "$(change 'local_file.talosconfig' local_file talosconfig null '["delete","create"]')"
  "$(change 'terraform_data.backup[0]' terraform_data backup 0 '["delete","create"]')"
)
LB_UPD="$(change "$S.scaleway_lb_backend.k8s_api[0]" scaleway_lb_backend k8s_api 0 '["update"]')"

node_json() { # <name> <ip> — a Kubernetes Node as the API serves it: the CP label has an EMPTY value
  local lab='{}'; [[ "$1" == *-cp-* ]] && lab='{"node-role.kubernetes.io/control-plane":""}'
  printf '{"metadata":{"name":"%s","creationTimestamp":"2026-10-0%s","labels":%s},"status":{"addresses":[{"type":"InternalIP","address":"%s"}],"conditions":[{"type":"Ready","status":"True"}]}}' \
    "$1" "${2##*.}" "$lab" "$2"
}
nodes_json() { # <name ip>... — the cluster's Nodes
  local a=()
  while [ $# -gt 0 ]; do a+=("$(node_json "$1" "$2")"); shift 2; done
  printf '{"items":[%s]}' "$(IFS=,; echo "${a[*]}")"
}
# The cluster the plans below start from: 3 control planes and 2 workers on Scaleway, all Ready. The state lists
# what a real one does: server, NIC and IPAM address per node, and a data volume per worker.
setup() {
  rm -f "$ST"/*; : >"$ST/down"; : >"$CALLS"
  echo '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.1.10","10.0.1.11"]}}' >"$ST/outputs.json"
  nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-cp-2 10.0.0.12 oa-lab-worker-0 10.0.1.10 oa-lab-worker-1 10.0.1.11 >"$ST/nodes.json"
  printf '10.0.0.10 %016x\n10.0.0.11 %016x\n10.0.0.12 %016x\n' 10 11 12 >"$ST/members"
  : >"$ST/state.list"
  for i in 0 1 2; do for t in scaleway_instance_server scaleway_instance_private_nic scaleway_ipam_ip; do echo "module.scw[0].$t.control_plane[$i]" >>"$ST/state.list"; done; done
  for i in 0 1; do
    for t in scaleway_instance_server scaleway_instance_private_nic scaleway_ipam_ip; do echo "module.scw[0].$t.worker[$i]" >>"$ST/state.list"; done
    echo "module.scw[0].scaleway_block_volume.worker_data[\"w$i-d0\"]" >>"$ST/state.list"
  done
  printf 'Name: oa-lab-worker-0\n  cpu                1 (25%%)\nName: oa-lab-worker-1\n  cpu                1 (20%%)\n' >"$ST/describe.txt"
  rm -f "$C"/shrink-*.json
}
ENVV=(X=1)
run() { # <mode args…> — from the cluster dir; sets OUT, RC
  : >"$CALLS"
  # A run that does not end is a failure, not a hung harness.
  OUT="$( cd "$C" && timeout 60 env PATH="$W/bin:$PATH" POLL=0 POWEROFF_TIMEOUT=5 ETCD_TIMEOUT=5 LONGHORN_TIMEOUT=5 EVICT_TIMEOUT=5 \
          RESTORE_TIMEOUT=3 RESTORE_POLL=0 PLACED_TIMEOUT=3 "${ENVV[@]}" "$W/scripts/ops/shrink-nodes.sh" "$@" 2>&1 )"; RC=$?
}
calls() { cat "$CALLS"; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
n_of() { grep -c -- "$1" "$CALLS" || true; }
mutating() { # any call that changes the cluster or the infrastructure
  grep -E '^(kubectl .*(cordon|drain|delete node|patch)|talosctl .*(shutdown|etcd leave|forfeit)|apply |snapshot)' "$CALLS" | grep -v '^kubectl .*uncordon' || true
  grep -E '^tofu apply' "$CALLS" || true
}
before() { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } # <first> <then>
no_destroy() { [ "$(n_of 'apply destroy')" = 0 ]; }
SCOPE_F="$C/shrink-management-scaleway.json"
WPLAN="$(plan_of "${W1_DEL[@]}" "${RIDERS[@]}")"
CLOSE_PLAN="$(plan_of "${RIDERS[@]}")"
plan_run() { # <provider> <plan-json> [flags…] — a fresh cluster, the given scope plan, --plan
  local prov="$1" pj="$2"; shift 2
  setup; printf '%s' "$pj" >"$ST/plan.scope.json"; run "$prov" --plan "$@"
}
refuses() { # <what> <pattern> — the last run was refused, said so, and changed nothing
  { [ "$RC" -ne 0 ] && grep -qE -- "$2" <<<"$OUT" && [ -z "$(mutating)" ] && [ ! -f "$SCOPE_F" ]; } \
    && ok "$1" || bad "$1 — rc ${RC}, mutating '$(mutating | tr '\n' '|')', output: ${OUT}"
}
fixtures() { # <scope-plan-json> [flags…] — a fresh cluster, the plans each step of a run reads, and the scope file written
  local pj="$1"; shift
  setup; printf '%s' "$pj" >"$ST/plan.scope.json"; printf '%s' "$CLOSE_PLAN" >"$ST/plan.close.json"; echo '{"resource_changes":[]}' >"$ST/plan.refresh.json"
  run scaleway --plan "$@"
}

echo "=== --plan reads, writes the scope, and changes nothing ==="
plan_run scaleway "$WPLAN"
{ [ "$RC" = 0 ] && [ -f "$SCOPE_F" ] && [ -z "$(mutating)" ]; } \
  && ok "workers 2 -> 1 on a real-shaped state: --plan writes the scope file and mutates nothing" \
  || bad "--plan (rc ${RC}, file $([ -f "$SCOPE_F" ] && echo yes || echo no), mutating: $(mutating | tr '\n' '|')): ${OUT}"
{ jq -e '.class == "worker" and .indices == [1] and .old == 2 and .new == 1 and (.addresses | length == 6)
         and (.addresses | any(test("worker_data")))' "$SCOPE_F" >/dev/null; } \
  && ok "…it names the worker, the index and all six resources, the data volume among them" \
  || bad "scope file wrong: $(cat "$SCOPE_F" 2>/dev/null)"
grep -q 'allow-below-ha' <<<"$OUT" && bad "…and a worker plan does not ask for --allow-below-ha" || ok "…and a worker plan does not ask for --allow-below-ha"

echo "=== what a lowered count may not take with it ==="
plan_run scaleway "$(plan_of "${W1_DEL[@]}" "${CP2_DEL[@]}" "${RIDERS[@]}")"
refuses "control planes and workers in one plan are refused" 'together'
plan_run scaleway "$(plan_of "${W1_DEL[@]}" "$(change 'module.scw[0].scaleway_lb_backend.http[0]' scaleway_lb_backend http 0 '["delete"]')" "${RIDERS[@]}")"
refuses "a delete that is not a node's own is refused, and named" 'delete module.scw\[0\].scaleway_lb_backend.http'
plan_run scaleway "$(plan_of "${W1_DEL[@]}" "$(change 'module.scw[0].scaleway_instance_server.worker[0]' scaleway_instance_server worker 0 '["delete","create"]')" "${RIDERS[@]}")"
refuses "a node REPLACEMENT riding along is refused" 'delete,create module.scw\[0\].scaleway_instance_server.worker\[0\]'
plan_run scaleway "$(plan_of "${W1_DEL[@]}" "$(change 'module.scw[0].scaleway_instance_security_group.this[\"fr-par-1\"]' scaleway_instance_security_group this '"fr-par-1"' '["update"]')" "${RIDERS[@]}")"
refuses "an unrelated edit pending in the tfvars is refused, so the removal stays alone" 'security_group'
plan_run scaleway "$(plan_of "$(change 'module.scw[0].scaleway_instance_server.worker[1]' scaleway_instance_server worker 1 '["delete"]' delete_because_no_resource_config)" "${RIDERS[@]}")"
refuses "a node delete tofu says is NOT a lowered count (a removed resource block) is refused" 'delete_because_no_resource_config'
W0_DEL=("$(change 'module.scw[0].scaleway_instance_server.worker[0]' scaleway_instance_server worker 0 '["delete"]')"
        "$(change 'module.scw[0].scaleway_ipam_ip.worker[0]' scaleway_ipam_ip worker 0 '["delete"]')")
plan_run scaleway "$(plan_of "${W0_DEL[@]}" "${RIDERS[@]}")"
refuses "removing worker 0 of 2 is refused: only the highest index can go" 'only the highest indexes can go'
plan_run scaleway "$(plan_of "$(change "$S.scaleway_block_volume.worker_data[\\\"w1-d0\\\"]" scaleway_block_volume worker_data '"w1-d0"' '["delete"]')" "${RIDERS[@]}")"
refuses "a plan that deletes only a worker's disk, its machine staying, is not a removal" 'not its machine'
plan_run scaleway "$(plan_of "${CP2_DEL[@]}" "$(change 'module.scw[0].scaleway_instance_server.control_plane[1]' scaleway_instance_server control_plane 1 '["delete"]')" "${RIDERS[@]}")"
refuses "two control planes in one run are refused" 'one control plane per run'
plan_run scaleway "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")"
refuses "3 -> 2 control planes is below HA and needs the flag" 'allow-below-ha'
plan_run scaleway "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
{ [ "$RC" = 0 ] && [ -f "$SCOPE_F" ] && grep -q 'tolerate no failure' <<<"$OUT" && grep -q -- '-- --allow-below-ha' <<<"$OUT"; } \
  && ok "…and with the flag it passes, warns that two members tolerate no failure, and prints the next command WITH the flag" \
  || bad "--allow-below-ha (rc ${RC}): ${OUT}"
plan_run scaleway "$(plan_of "${RIDERS[@]}")"
{ [ "$RC" = 0 ] && grep -q 'nothing to remove' <<<"$OUT" && [ ! -f "$SCOPE_F" ] && [ -z "$(mutating)" ]; } \
  && ok "a plan that deletes no node is 'nothing to remove', rc 0, no file" || bad "empty scope (rc ${RC}): ${OUT}"
# half-finished: the machine is already out of the state, only its leftovers remain in the plan
setup; printf '%s' "$(plan_of "$(change "$S.scaleway_block_volume.worker_data[\\\"w1-d0\\\"]" scaleway_block_volume worker_data '"w1-d0"' '["delete"]')" "$(change "$T.talos_machine_configuration_apply.worker[1]" talos_machine_configuration_apply worker 1 '["delete"]')" "${RIDERS[@]}")" >"$ST/plan.scope.json"
grep -v 'worker\[1\]$' "$ST/state.list" >"$ST/s.tmp"; mv "$ST/s.tmp" "$ST/state.list"
nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-cp-2 10.0.0.12 oa-lab-worker-0 10.0.1.10 >"$ST/nodes.json"; echo 10.0.1.11 >>"$ST/down"
printf 'Name: oa-lab-worker-0\n  cpu                1 (25%%)\n' >"$ST/describe.txt"
run scaleway --plan
{ [ "$RC" = 0 ] && jq -e '.old == 2 and .new == 1' "$SCOPE_F" >/dev/null; } \
  && ok "a half-finished earlier run (machine gone from the state, Node gone, one worker describable) still adds up" \
  || bad "partial scope (rc ${RC}): ${OUT}"
setup; printf '%s' "$WPLAN" >"$ST/plan.scope.json"
ENVV=(STUB_TB=false); run scaleway --plan; ENVV=(X=1)
refuses "an un-bootstrapped state is refused: there is nothing to drain" 'no Talos bootstrap'

echo "=== what the cluster must be able to lose ==="
echo '{"items":[{"metadata":{"name":"pvc-a"},"spec":{"claimRef":{"namespace":"db","name":"data-0"},"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["oa-lab-worker-1"]}]}]}}}}]}' >"$W/pv.json"
ENVV=(STUB_PV_FILE="$W/pv.json"); plan_run scaleway "$WPLAN"; ENVV=(X=1)
refuses "a volume pinned to the node is refused, with the volume and its claim named" 'pvc-a \(db/data-0\)'
echo '{"items":[{"metadata":{"name":"oa-lab-worker-0"},"spec":{"allowScheduling":true}},{"metadata":{"name":"oa-lab-worker-1"},"spec":{"allowScheduling":true}}]}' >"$W/lh-nodes.json"
echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":2}}]}' >"$W/lh-volumes.json"
setup; cp "$W/lh-nodes.json" "$W/lh-volumes.json" "$ST/"; printf '%s' "$WPLAN" >"$ST/plan.scope.json"
ENVV=(STUB_LONGHORN=1); run scaleway --plan; ENVV=(X=1)
refuses "a Longhorn volume that wants more replicas than nodes would remain is refused" 'vol-1 wants 2 replicas, 1 node'
setup; cp "$W/lh-nodes.json" "$W/lh-volumes.json" "$ST/"; printf '%s' "$WPLAN" >"$ST/plan.scope.json"
ENVV=(STUB_LONGHORN=1 STUB_CRD_ERROR=1); run scaleway --plan; ENVV=(X=1)
refuses "an apiserver error on the Longhorn CRD is not read as 'Longhorn is not installed'" 'cannot tell whether the CRD'
setup; printf 'Name: oa-lab-worker-0\n  cpu                1 (90%%)\nName: oa-lab-worker-1\n  cpu                1 (80%%)\n' >"$ST/describe.txt"
printf '%s' "$WPLAN" >"$ST/plan.scope.json"; run scaleway --plan
refuses "workers whose CPU requests the remaining ones cannot hold are refused" 'request 170%'
setup; nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-cp-2 10.0.0.12 oa-lab-worker-0 10.0.1.10 oa-lab-cp-9 10.0.1.11 >"$ST/nodes.json"
printf '%s' "$WPLAN" >"$ST/plan.scope.json"; run scaleway --plan
refuses "a node that carries the control-plane label (an EMPTY value, as Talos sets it) is not removed as a worker" 'not a worker node by its labels'
plan_run scaleway "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
{ [ "$RC" = 0 ] && [ -f "$SCOPE_F" ]; } && ok "…and a real control plane, label value empty, passes the same check" || bad "cp label (rc ${RC}): ${OUT}"
setup; jq -c '(.items[] | select(.metadata.name == "oa-lab-worker-0") | .status.conditions[0].status) = "False"' "$ST/nodes.json" >"$ST/n.tmp" && mv "$ST/n.tmp" "$ST/nodes.json"
printf '%s' "$WPLAN" >"$ST/plan.scope.json"; run scaleway --plan
refuses "a node that is not Ready stops the removal before it starts" 'not Ready'
setup; printf '%s' "$WPLAN" >"$ST/plan.scope.json"; ENVV=(STUB_NODES_FAIL_NTH=1); run scaleway --plan; ENVV=(X=1)
refuses "an apiserver that does not answer the node list is a refusal, not an empty cluster" 'cannot reach the API'
setup; nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-cp-2 10.0.0.12 oa-lab-worker-0 10.0.1.10 >"$ST/nodes.json"
printf '%s' "$WPLAN" >"$ST/plan.scope.json"; run scaleway --plan
refuses "no Node for the IP while the machine still answers: the outputs are wrong, refused" 'does not read as down'
OVHCP="$(change 'module.ovh[0].openstack_compute_instance_v2.control_plane[2]' openstack_compute_instance_v2 control_plane 2 '["delete"]')"
OVHPORT="$(change 'module.ovh[0].openstack_networking_port_v2.control_plane[2]' openstack_networking_port_v2 control_plane 2 '["delete"]')"
OVHMEM="$(change 'module.ovh[0].openstack_lb_member_v2.k8s_api[2]' openstack_lb_member_v2 k8s_api 2 '["delete"]')"
ovh_state() { # a real OVH control plane is a port and an instance
  setup; : >"$ST/state.list"
  for i in 0 1 2; do for t in openstack_networking_port_v2 openstack_compute_instance_v2; do echo "module.ovh[0].$t.control_plane[$i]" >>"$ST/state.list"; done; done
  for i in 0 1; do echo "module.ovh[0].openstack_compute_instance_v2.worker[$i]" >>"$ST/state.list"; done
}
ovh_state; printf '%s' "$(plan_of "$OVHCP" "$OVHPORT" "$OVHMEM" "$(change 'module.ovh[0].openstack_lb_member_v2.http[1]' openstack_lb_member_v2 http 1 '["delete"]')" "${RIDERS[@]}")" >"$ST/plan.scope.json"
run ovh --plan --allow-below-ha
refuses "on OVH a control plane and a worker's pool member are classed by type: both classes, refused" 'together'
ovh_state; printf '%s' "$(plan_of "$OVHCP" "$OVHPORT" "$OVHMEM" "${RIDERS[@]}")" >"$ST/plan.scope.json"
run ovh --plan --allow-below-ha
{ [ "$RC" = 0 ] && jq -e '.class == "cp" and .old == 3 and (.addresses | any(test("lb_member_v2.k8s_api")))' "$C/shrink-management-ovh.json" >/dev/null; } \
  && ok "…and an OVH control plane (a port AND an instance in the state) counts once, its pool member in its bundle" || bad "OVH cp bundle (rc ${RC}): ${OUT}"
rm -f "$C"/shrink-*.json

echo "=== --apply: the order is the safety ==="
fixtures "$WPLAN"
run scaleway --apply="$SCOPE_F"
{ [ "$RC" = 0 ] && grep -q 'removed worker 1' <<<"$OUT" && grep -q 'Removal complete' <<<"$OUT"; } \
  && ok "a worker removal runs to the end, says so, and does not call it a roll" || bad "worker removal (rc ${RC}): ${OUT}"
{ before ' cordon oa-lab-worker-1' ' drain oa-lab-worker-1' && before ' drain oa-lab-worker-1' 'shutdown --force' \
  && before 'shutdown --force' 'delete node oa-lab-worker-1' && before 'delete node oa-lab-worker-1' 'apply destroy' \
  && before 'apply destroy' 'apply refresh' && before 'apply refresh' 'apply close'; } \
  && ok "…cordon, drain, power off, delete the Node, destroy, refresh, close — in that order" \
  || bad "order wrong: $(grep -nE ' cordon | drain |shutdown|delete node|^apply ' "$CALLS" | cut -c1-90 | tr '\n' '|')"
grep -E '^tofu plan .*-target' "$CALLS" | grep -q 'worker_data' \
  && [ "$(grep -E '^tofu plan .*-target' "$CALLS" | grep -o -- '-target=' | wc -l)" = 6 ] \
  && ok "…the destroy is a plan targeted at exactly the six resources of the bundle, data volume included" \
  || bad "targets: $(grep -E '^tofu plan .*-target' "$CALLS" | cut -c1-300)"
grep -E '^apply close ' "$CALLS" | grep -q -- '-parallelism=1' \
  && ok "…and the closing apply goes one at a time" || bad "closing apply: $(grep '^apply close' "$CALLS")"
[ "$(n_of '^snapshot')" = 0 ] && [ "$(n_of 'etcd leave')" = 0 ] \
  && ok "a worker removal touches neither etcd nor the snapshot" || bad "a worker run touched etcd: $(grep -E 'snapshot|etcd leave' "$CALLS")"
[ ! -f "$SCOPE_F" ] && ok "the scope file is consumed by a finished run" || bad "the scope file was left behind"
grep -q 'talosctl -e 127.0.0.1:[0-9]* -n 10.0.1.11 version' "$CALLS" \
  && ok "…and 'down' was asked of a control plane's apid, about the worker's IP" || bad "down was never asked through a peer"

fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
run scaleway --apply="$SCOPE_F" --allow-below-ha
{ [ "$RC" = 0 ] && grep -q 'removed cp 2' <<<"$OUT"; } && ok "a control plane removal runs to the end" || bad "cp removal (rc ${RC}): ${OUT}"
{ before '^snapshot' ' cordon oa-lab-cp-2' && before ' cordon oa-lab-cp-2' ' drain oa-lab-cp-2' && before ' drain oa-lab-cp-2' 'etcd leave' \
  && before 'etcd leave' 'shutdown --force' && before 'shutdown --force' 'delete node oa-lab-cp-2' && before 'delete node oa-lab-cp-2' 'apply destroy'; } \
  && ok "…etcd snapshot, drain, etcd LEAVE, power off, delete the Node, destroy — in that order" \
  || bad "cp order wrong: $(grep -nE 'snapshot| cordon | drain |etcd|shutdown|delete node|^apply ' "$CALLS" | cut -c1-90 | tr '\n' '|')"
[ "$(n_of 'etcd leave')" = 1 ] && ok "…and leaves etcd exactly once" || bad "etcd leave count $(n_of 'etcd leave')"
grep -qE '^talosctl .*-n 10\.0\.0\.12 etcd leave' "$CALLS" \
  && ok "…on the control plane being removed, not another" || bad "etcd leave aimed elsewhere: $(grep 'etcd leave' "$CALLS")"
{ [ "$(n_of 'etcd forfeit')" = 0 ]; } && ok "a follower hands no leadership over" || bad "forfeit-leadership on a follower"
grep -E '^talosctl .*-n 10\.0\.0\.12 version' "$CALLS" | grep -vq -- '-e 127.0.0.1:50002' \
  && ok "…and 'down' is asked through a peer, never through the removed control plane's own tunnel" || bad "cp down was asked through its own tunnel"
fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
ENVV=(STUB_LEADER_LAST=12); run scaleway --apply="$SCOPE_F" --allow-below-ha; ENVV=(X=1)
{ [ "$RC" = 0 ] && before 'etcd forfeit' ' cordon oa-lab-cp-2' && before 'etcd forfeit' 'etcd leave' && grep -q 'leadership moved' <<<"$OUT"; } \
  && ok "a control plane that holds the etcd leader hands it off, sees it move, and only then drains" \
  || bad "leader hand-off (rc ${RC}): $(grep -nE 'forfeit| cordon |etcd leave' "$CALLS" | cut -c1-90 | tr '\n' '|'): ${OUT}"

echo "=== several workers, highest first ==="
W3PLAN="$(plan_of "${W1_DEL[@]}" "${W2_DEL[@]}" "${RIDERS[@]}")"
multi() { # a 3-worker cluster, and the plan that takes two of them
  setup; printf '%s' "$W3PLAN" >"$ST/plan.scope.json"; printf '%s' "$CLOSE_PLAN" >"$ST/plan.close.json"; echo '{"resource_changes":[]}' >"$ST/plan.refresh.json"
  echo '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.1.10","10.0.1.11","10.0.1.12"]}}' >"$ST/outputs.json"
  nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-cp-2 10.0.0.12 oa-lab-worker-0 10.0.1.10 oa-lab-worker-1 10.0.1.11 oa-lab-worker-2 10.0.1.12 >"$ST/nodes.json"
  for t in scaleway_instance_server scaleway_instance_private_nic scaleway_ipam_ip; do echo "module.scw[0].$t.worker[2]" >>"$ST/state.list"; done
  printf 'Name: oa-lab-worker-0\n  cpu                1 (20%%)\nName: oa-lab-worker-1\n  cpu                1 (20%%)\nName: oa-lab-worker-2\n  cpu                1 (20%%)\n' >"$ST/describe.txt"
}
multi; run scaleway --plan
{ [ "$RC" = 0 ] && jq -e '.indices == [1,2] and .old == 3 and .new == 1' "$SCOPE_F" >/dev/null; } \
  && ok "workers 3 -> 1: the scope names both, 3 before and 1 after" || bad "multi scope (rc ${RC}): ${OUT}"
run scaleway --apply="$SCOPE_F"
{ [ "$RC" = 0 ] && [ "$(n_of 'apply destroy')" = 2 ] && before ' cordon oa-lab-worker-2' ' cordon oa-lab-worker-1' \
  && before 'apply destroy' ' cordon oa-lab-worker-1'; } \
  && ok "…removed one at a time, the highest index first, the first destroyed before the second is touched" \
  || bad "multi order (rc ${RC}): $(grep -nE ' cordon |delete node|^apply destroy' "$CALLS" | cut -c1-80 | tr '\n' '|'): ${OUT}"
multi; printf 'Name: oa-lab-worker-0\n  cpu                1 (50%%)\nName: oa-lab-worker-1\n  cpu                1 (50%%)\nName: oa-lab-worker-2\n  cpu                1 (50%%)\n' >"$ST/describe.txt"
run scaleway --plan
refuses "two workers leaving at once are checked together: 150% does not fit on the one that stays" 'request 150%'

multi; echo '{"items":[{"metadata":{"name":"oa-lab-worker-0"},"spec":{"allowScheduling":true}},{"metadata":{"name":"oa-lab-worker-1"},"spec":{"allowScheduling":true}},{"metadata":{"name":"oa-lab-worker-2"},"spec":{"allowScheduling":true}}]}' >"$ST/lh-nodes.json"
echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":2}}]}' >"$ST/lh-volumes.json"
ENVV=(STUB_LONGHORN=1); run scaleway --plan; ENVV=(X=1)
refuses "Longhorn room is counted for the whole scope: two replicas cannot stay on the one worker left when two go" 'vol-1 wants 2 replicas, 1 node'

echo "=== when the plan or the cluster is not what was read ==="
fixtures "$WPLAN"
ENVV=(STUB_DESTROY_EXTRA="[$(change 'module.scw[0].scaleway_instance_server.worker[0]' scaleway_instance_server worker 0 '["delete"]')]"); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && no_destroy && grep -qE 'different set|at most 6' <<<"$OUT"; } \
  && ok "a destroy plan that deletes one more resource than the scope is refused, nothing destroyed" \
  || bad "extra delete (rc ${RC}, destroy applied $(n_of 'apply destroy')): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_DESTROY_DROP="[\"module.scw[0].scaleway_block_volume.worker_data[\\\"w1-d0\\\"]\"]"); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && no_destroy && grep -q 'different set' <<<"$OUT"; } \
  && ok "…and one that leaves a resource of the bundle out is refused too (the set must match, not just fit)" \
  || bad "dropped member (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_DESTROY_EXTRA="[$(change 'module.scw[0].scaleway_instance_server.worker[3]' scaleway_instance_server worker 3 '["create"]')]"); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && no_destroy; } && ok "…and one that creates something is refused" || bad "create in destroy plan (rc ${RC}): ${OUT}"

fixtures "$WPLAN"
ENVV=(STUB_DRAIN_RC=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'uncordon oa-lab-worker-1' "$CALLS" && [ "$(n_of 'shutdown')" = 0 ] && no_destroy && [ -f "$SCOPE_F" ]; } \
  && ok "a drain that cannot finish uncordons the node, powers nothing off, destroys nothing" \
  || bad "failed drain (rc ${RC}): $(grep -nE 'cordon|shutdown|^apply' "$CALLS" | tr '\n' '|')"
fixtures "$WPLAN"
ENVV=(STUB_CNPG=1 STUB_DRAIN_RC=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && before 'enablePDB":false' 'enablePDB":true'; } \
  && ok "a failed run still gives the databases their budgets back (the shared restore runs on every exit)" \
  || bad "cnpg restore (rc ${RC}): $(grep -n 'enablePDB' "$CALLS" | cut -c1-120 | tr '\n' '|'): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_CNPG=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" = 0 ] && before 'enablePDB":false' ' drain oa-lab-worker-1' && before ' drain oa-lab-worker-1' 'enablePDB":true'; } \
  && ok "…and a good run relaxes the budgets before the first drain and restores them after the last" \
  || bad "cnpg window (rc ${RC}): $(grep -n 'enablePDB\| drain ' "$CALLS" | cut -c1-100 | tr '\n' '|'): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_SHUTDOWN_FAIL=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'did not accept the shutdown' <<<"$OUT" && grep -q 'uncordon oa-lab-worker-1' "$CALLS" && ! grep -q 'delete node' "$CALLS" && no_destroy; } \
  && ok "a shutdown Talos did not accept (a dead tunnel looks the same) stops the run before anything is destroyed, node given back" \
  || bad "shutdown refused (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_KEEP_READY=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'does not read as down' <<<"$OUT" && ! grep -q 'delete node' "$CALLS" && no_destroy; } \
  && ok "a node whose kubelet still reads Ready is not called down, whatever the tunnel says" \
  || bad "node still Ready (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_NODES_FAIL_NTH=4); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'cannot ask the cluster which Node' <<<"$OUT" && [ "$(n_of 'shutdown')" = 0 ] && no_destroy; } \
  && ok "a kubectl failure on the Node lookup stops the run: it is not read as 'the Node is already gone'" \
  || bad "kubectl blip (rc ${RC}): $(grep -nE 'shutdown|^apply|get nodes' "$CALLS" | cut -c1-80 | tr '\n' '|'): ${OUT}"
fixtures "$WPLAN"; rm -f "$ST/pv.calls"   # the --plan above counted one read; the survey of --apply is the next, the re-check after the drain the one after
ENVV=(STUB_PV_FILE="$W/pv.json" STUB_PV_AFTER=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'gained a node-local volume' <<<"$OUT" && grep -q 'uncordon oa-lab-worker-1' "$CALLS" && [ "$(n_of 'shutdown')" = 0 ] && no_destroy; } \
  && ok "a node-local volume that appears while the node drains stops the run before power-off, node given back" \
  || bad "pv after drain (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_DELETE_NOOP=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'names or creation times differ' <<<"$OUT"; } \
  && ok "a Node that is still there after its delete is caught by the final identity check, not reported removed" || bad "identity (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_CLOSE_BREAKS_ETCD=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'after the removal' <<<"$OUT" && grep -q 'etcd is not 3/3 healthy' <<<"$OUT"; } \
  && ok "an etcd that lost a member during the closing apply fails the run" || bad "closing etcd (rc ${RC}): ${OUT}"
fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
ENVV=(STUB_BROKEN_EP=127.0.0.1:50002); run scaleway --apply="$SCOPE_F" --allow-below-ha; ENVV=(X=1)
{ [ "$RC" = 0 ] && [ "$(n_of '^snapshot')" = 1 ] && [ "$(n_of 'etcd leave')" = 1 ]; } \
  && ok "membership is asked of a peer: a broken etcd on the node being removed does not read as 'already left'" \
  || bad "broken own etcd (rc ${RC}): $(grep -nE 'snapshot|leave' "$CALLS" | tr '\n' '|'): ${OUT}"
setup; printf '%s' "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" >"$ST/plan.scope.json"
ENVV=(STUB_UNHEALTHY_IPS="10.0.0.10 10.0.0.11"); run scaleway --plan --allow-below-ha; ENVV=(X=1)
refuses "etcd is read through a control plane that is not the one being removed: with no other healthy one the removal is refused" 'no control plane reports a healthy etcd'
fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
ENVV=(STUB_UNHEALTHY_WHEN_DOWN=1); run scaleway --apply="$SCOPE_F" --allow-below-ha; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'does not read as down' <<<"$OUT" && no_destroy; } \
  && ok "no witness, no verdict: with no other healthy control plane to ask, a removed one is not called down" \
  || bad "no witness (rc ${RC}): ${OUT}"

fixtures "$WPLAN"; cp "$W/lh-nodes.json" "$ST/"; echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":1}}]}' >"$ST/lh-volumes.json"
ENVV=(STUB_LONGHORN=1 STUB_DRAIN_RC=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'patch nodes.longhorn.io oa-lab-worker-1.*allowScheduling":false' "$CALLS" \
  && grep -q 'patch nodes.longhorn.io oa-lab-worker-1.*allowScheduling":true' "$CALLS"; } \
  && ok "Longhorn is asked to evict the node first, and gets it back when the run fails before power-off" \
  || bad "longhorn eviction (rc ${RC}): $(grep -n longhorn "$CALLS" | cut -c1-140 | tr '\n' '|')"
fixtures "$WPLAN"; cp "$W/lh-nodes.json" "$ST/"; echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":1}}]}' >"$ST/lh-volumes.json"
ENVV=(STUB_LONGHORN=1 STUB_REPLICAS_POLLS=3); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" = 0 ] && before 'allowScheduling":false' ' drain oa-lab-worker-1' && before 'shutdown --force' 'delete nodes.longhorn.io oa-lab-worker-1' \
  && [ "$(n_of 'get replicas.longhorn.io')" -ge 4 ]; } \
  && ok "…it waits for the replicas to leave (4 polls here) before draining, and deletes the Longhorn node after power-off" \
  || bad "longhorn wait (rc ${RC}): $(grep -n 'longhorn\|drain\|shutdown' "$CALLS" | cut -c1-110 | tr '\n' '|'): ${OUT}"
fixtures "$WPLAN"; cp "$W/lh-nodes.json" "$ST/"; echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":1}}]}' >"$ST/lh-volumes.json"
ENVV=(STUB_LONGHORN=1 STUB_LH_PATCH_DENY=2); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" = 0 ] && grep -q 'removed worker 1' <<<"$OUT"; } \
  && ok "Longhorn's webhook refusing the eviction twice (\"retry later\") is retried, not fatal" || bad "webhook retry (rc ${RC}): ${OUT}"
fixtures "$WPLAN"; cp "$W/lh-nodes.json" "$ST/"; echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":1}}]}' >"$ST/lh-volumes.json"
ENVV=(STUB_LONGHORN=1 STUB_LH_PATCH_DENY=99); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'could not ask Longhorn to evict' <<<"$OUT" && grep -q 'retry later' <<<"$OUT" && [ "$(n_of 'shutdown')" = 0 ] && no_destroy; } \
  && ok "…and a webhook that never relents stops the run before the drain, with its own words" || bad "webhook never relents (rc ${RC}): ${OUT}"
fixtures "$WPLAN"; cp "$W/lh-nodes.json" "$ST/"; echo '{"items":[{"metadata":{"name":"vol-1"},"spec":{"numberOfReplicas":1}}]}' >"$ST/lh-volumes.json"
ENVV=(STUB_LONGHORN=1 STUB_REPLICAS_STUCK=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'still holds replicas' <<<"$OUT" && [ "$(n_of 'shutdown')" = 0 ] && no_destroy && grep -q 'allowScheduling":true' "$CALLS"; } \
  && ok "replicas that never leave stop the run before the drain, and the eviction is undone" \
  || bad "stuck replicas (rc ${RC}): ${OUT}"

fixtures "$WPLAN"; jq '.new = 0' "$SCOPE_F" >"$W/moved.json"
run scaleway --apply="$W/moved.json"
{ [ "$RC" -ne 0 ] && grep -q 'moved since' <<<"$OUT" && [ -z "$(mutating)" ]; } \
  && ok "a scope file that no longer matches the plan is refused before anything is touched" || bad "moved scope (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
run scaleway --apply="$W/does-not-exist.json"
{ [ "$RC" -ne 0 ] && grep -q 'run --plan first' <<<"$OUT" && [ -z "$(calls)" ]; } \
  && ok "no scope file, no removal" || bad "missing scope file (rc ${RC}): ${OUT}"
fixtures "$WPLAN"; printf '%s' "$CLOSE_PLAN" >"$ST/plan.scope.json"
run scaleway --apply="$SCOPE_F"
{ [ "$RC" -ne 0 ] && grep -q 'no longer deletes a node' <<<"$OUT" && [ -z "$(mutating)" ]; } \
  && ok "--apply against a plan that no longer deletes a node fails, it does not report success" || bad "apply with nothing (rc ${RC}): ${OUT}"
fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
ENVV=(STUB_SNAPSHOT_RC=1); run scaleway --apply="$SCOPE_F" --allow-below-ha; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && [ "$(n_of 'etcd leave')" = 0 ] && [ "$(n_of 'shutdown')" = 0 ] && no_destroy && ! grep -q ' cordon ' "$CALLS"; } \
  && ok "a failed etcd snapshot stops a control plane removal before it drains, leaves, or powers off" \
  || bad "failed snapshot (rc ${RC}): $(grep -nE 'snapshot|cordon|leave|shutdown|^apply' "$CALLS" | tr '\n' '|')"
fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha
ENVV=(STUB_LEAVE_NOOP=1); run scaleway --apply="$SCOPE_F" --allow-below-ha; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'etcd is not 2/2 healthy' <<<"$OUT" && [ "$(n_of 'shutdown')" = 0 ] && no_destroy; } \
  && ok "an etcd that still has three members after the leave stops the run before the machine is powered off" \
  || bad "leave did nothing (rc ${RC}): ${OUT}"

echo "=== a run that stopped half-way can be finished ==="
# worker: the Node and the machine are gone, the destroy did not run; the survivors are all describe lists
fixtures "$WPLAN"; cp "$SCOPE_F" "$W/resume.json"
nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-cp-2 10.0.0.12 oa-lab-worker-0 10.0.1.10 >"$ST/nodes.json"; echo 10.0.1.11 >>"$ST/down"
printf 'Name: oa-lab-worker-0\n  cpu                1 (25%%)\n' >"$ST/describe.txt"
run scaleway --apply="$W/resume.json"
{ [ "$RC" = 0 ] && ! grep -qE ' cordon | drain |delete node|shutdown' "$CALLS" && grep -q 'apply destroy' "$CALLS"; } \
  && ok "a worker whose Node is gone and machine down is finished: no drain, no shutdown, the destroy runs" \
  || bad "worker resume (rc ${RC}): $(grep -nE ' cordon | drain |delete node|shutdown|^apply' "$CALLS" | cut -c1-80 | tr '\n' '|'): ${OUT}"
# control plane: it left etcd, its Node and machine are gone, the destroy did not run
fixtures "$(plan_of "${CP2_DEL[@]}" "$LB_UPD" "${RIDERS[@]}")" --allow-below-ha; cp "$SCOPE_F" "$W/resume-cp.json"
printf '10.0.0.10 %016x\n10.0.0.11 %016x\n' 10 11 >"$ST/members"
nodes_json oa-lab-cp-0 10.0.0.10 oa-lab-cp-1 10.0.0.11 oa-lab-worker-0 10.0.1.10 oa-lab-worker-1 10.0.1.11 >"$ST/nodes.json"; echo 10.0.0.12 >>"$ST/down"
run scaleway --apply="$W/resume-cp.json" --allow-below-ha
{ [ "$RC" = 0 ] && [ "$(n_of 'etcd leave')" = 0 ] && [ "$(n_of '^snapshot')" = 0 ] && ! grep -qE ' cordon | drain |shutdown' "$CALLS" && grep -q 'apply destroy' "$CALLS"; } \
  && ok "a control plane that already left etcd (2 members, outputs still 3) is finished: no snapshot, no leave, the destroy runs" \
  || bad "cp resume (rc ${RC}): $(grep -nE 'snapshot|etcd|shutdown|^apply' "$CALLS" | cut -c1-80 | tr '\n' '|'): ${OUT}"

echo "=== the closing step ==="
fixtures "$WPLAN"
printf '%s' "$(plan_of "${RIDERS[@]}" "$(change 'module.scw[0].scaleway_lb_backend.http[0]' scaleway_lb_backend http 0 '["delete"]')")" >"$ST/plan.close.json"
run scaleway --apply="$SCOPE_F"
{ [ "$RC" -ne 0 ] && grep -q 'closing plan changes more' <<<"$OUT" && [ "$(n_of 'apply close')" = 0 ]; } \
  && ok "a closing plan that changes more than the nodes' config is refused, not applied" || bad "closing plan (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_FINAL_RC=2); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'not empty' <<<"$OUT"; } \
  && ok "a plan that still has changes after the removal fails the run, saying so" || bad "final plan 2 (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_FINAL_RC=1); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" -ne 0 ] && grep -q 'could not plan after the removal' <<<"$OUT" && ! grep -q 'not empty' <<<"$OUT"; } \
  && ok "…and a plan that ERRORS is not reported as 'not empty'" || bad "final plan 1 (rc ${RC}): ${OUT}"
fixtures "$WPLAN"
ENVV=(STUB_PENDING=$'kube-system pod-a\n'); run scaleway --apply="$SCOPE_F"; ENVV=(X=1)
{ [ "$RC" = 0 ] && grep -q 'still Pending' <<<"$OUT"; } \
  && ok "pods left Pending after a worker removal are named, not hidden behind a green run" || bad "pending pods (rc ${RC}): ${OUT}"

echo "=== the two commands ==="
TF="$ROOT/Taskfile.yml"
DRY_NO="$(cd "$ROOT" && task --dry cluster-shrink PROVIDER=scaleway ROLE=management PLAN=x.json KEY=/k -- --allow-below-ha 2>&1)"
{ grep -q 'SSH_KEY="/k" ../../../scripts/ops/shrink-nodes.sh scaleway --role=management' <<<"$DRY_NO" \
  && grep -q -- '--apply="x.json" --allow-below-ha' <<<"$DRY_NO"; } \
  && ok "cluster-shrink renders the file as --apply= and gives the removal its SSH key (it reopens tunnels itself)" \
  || bad "cluster-shrink rendering: ${DRY_NO}"
DRY_PL="$(cd "$ROOT" && task --dry cluster-shrink-plan PROVIDER=scaleway KEY=/k -- --allow-below-ha 2>&1)"
grep -q 'SSH_KEY="/k" ../../../scripts/ops/shrink-nodes.sh scaleway --role=management --plan --allow-below-ha' <<<"$DRY_PL" \
  && ok "cluster-shrink-plan renders --plan with the key and the passthrough flag" || bad "cluster-shrink-plan rendering: ${DRY_PL}"
SH="$(awk '/^  cluster-shrink:/{f=1} f&&/^  [a-z_-]+:$/&&!/cluster-shrink:/{f=0} f' "$TF")"
{ grep -q 'refusing to remove nodes without a scope you have read' <<<"$SH" && grep -q 'APPROVE=auto cannot stand in for it' <<<"$SH" \
  && grep -qE '\[ -z "\{\{\.PLAN\}\}" \]' <<<"$SH" && grep -q 'exit 1' <<<"$SH"; } \
  && ok "cluster-shrink refuses without PLAN=, in the refusal the operator reads, and exits 1" || bad "cluster-shrink has no PLAN= refusal"
{ L1="$(grep -n 'talos-tunnels.sh open' <<<"$SH" | head -1 | cut -d: -f1)"; L2="$(grep -n 'shrink-nodes.sh' <<<"$SH" | head -1 | cut -d: -f1)"
  L3="$(grep -n '_backup-state' <<<"$SH" | head -1 | cut -d: -f1)"; L4="$(grep -n 'task: cluster-verify' <<<"$SH" | head -1 | cut -d: -f1)"
  [ -n "$L1" ] && [ -n "$L2" ] && [ -n "$L3" ] && [ -n "$L4" ] && [ "$L1" -lt "$L2" ] && [ "$L2" -lt "$L3" ] && [ "$L3" -lt "$L4" ]; } \
  && ok "…tunnels, the removal, the state backup, then cluster-verify" || bad "cluster-shrink steps out of order or missing"
grep -q 'cluster-shrink-plan' "$ROOT/scripts/internal/refuse-node-deletes.sh" \
  && ok "cluster-up's refusal of a lowered count points at cluster-shrink-plan" || bad "the refusal does not name the way to remove nodes"
git -C "$ROOT" check-ignore -q infrastructure/opentofu/cluster/shrink-management-scaleway.json 2>/dev/null \
  && ok "the scope file is gitignored" || bad "the scope file would be committed by git add -A"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
