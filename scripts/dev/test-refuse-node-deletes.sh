#!/usr/bin/env bash
# scripts/internal/refuse-node-deletes.sh: a saved plan that deletes a node, or a worker's data volume,
# on a bootstrapped cluster is refused. The script runs for real; tofu is a stub that answers `show`
# with the plan JSON of the environment, and bootstrap-in-state is a stub. SUT overrides the script,
# which is how the mutants run. The plans are hand-written, with placeholder addresses.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/internal/refuse-node-deletes.sh}"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts/internal" "$W/bin"
cp "$SUT" "$W/scripts/internal/refuse-node-deletes.sh"
cat >"$W/scripts/internal/bootstrap-in-state.sh" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_TB:-true}" = unreadable ] && { echo "✗ cannot read the state" >&2; exit 1; }
echo "${STUB_TB:-true}"
STUB
cat >"$W/bin/tofu" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_SHOW_RC:-0}" = 0 ] || exit 1
[ "$1" = show ] && printf '%s\n' "$STUB_PLAN"
STUB
chmod +x "$W"/scripts/internal/*.sh "$W/bin/tofu"
: >"$W/plan.tfplan"

run() { # <creates-only|-> <env assignments…> ; sets OUT, RC
  local flag="$1"; shift
  [ "$flag" = creates-only ] && flag=--creates-only || flag=
  OUT="$(env PATH="$W/bin:$PATH" "$@" "$W/scripts/internal/refuse-node-deletes.sh" $flag "${PLANFILE:-$W/plan.tfplan}" 2>&1)"; RC=$?
}
change() { # <address> <name> <actions-json> [reason]
  printf '{"address":"%s","mode":"managed","name":"%s","change":{"actions":%s},"action_reason":"%s"}' "$1" "$2" "$3" "${4:-}"
}
plan_of() { printf '{"resource_changes":[%s]}' "$(IFS=,; echo "$*")"; }

WDEL="$(change 'module.scw[0].scaleway_instance_server.worker[2]' worker '["delete"]' delete_because_count_index)"
VDEL="$(change 'module.scw[0].scaleway_block_volume.worker_data[\"w2-d0\"]' worker_data '["delete"]' delete_because_each_key)"
CDEL="$(change 'module.scw[0].scaleway_instance_server.control_plane[2]' control_plane '["delete"]' delete_because_count_index)"
WREP="$(change 'module.scw[0].scaleway_instance_server.worker[0]' worker '["delete","create"]' replace_because_tainted)"
LBDEL="$(change 'module.scw[0].scaleway_lb.k8s[0]' k8s '["delete"]' delete_because_count_index)"
MODDEL="$(change 'module.talos.talos_machine_configuration_apply.worker[0]' worker '["delete"]' delete_because_no_module)"
WUPD="$(change 'module.scw[0].scaleway_instance_server.worker[0]' worker '["update"]')"
WNEW="$(change 'module.scw[0].scaleway_instance_server.worker[3]' worker '["create"]')"
LBUPD="$(change 'module.scw[0].scaleway_lb_backend.k8s_api[0]' k8s_api '["update"]')"
NOOP="$(change 'module.scw[0].scaleway_instance_server.worker[1]' worker '["no-op"]')"

echo "=== a bootstrapped cluster: a node delete is refused ==="
run - STUB_PLAN="$(plan_of "$WDEL")"
{ [ "$RC" = 1 ] && grep -q 'worker\[2\]' <<<"$OUT" && grep -q 'Put the count back' <<<"$OUT"; } \
  && ok "a lowered workers count (the worker is deleted) is refused, the address named, with the way out" \
  || bad "a worker delete was let through (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$VDEL")"
{ [ "$RC" = 1 ] && grep -q 'worker_data' <<<"$OUT"; } \
  && ok "a worker's data volume deleted on its own (each_key) is refused too" || bad "a data volume delete was let through (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$CDEL")"
{ [ "$RC" = 1 ] && grep -q 'control_plane\[2\]' <<<"$OUT"; } \
  && ok "a control plane delete is refused" || bad "a control plane delete was let through (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$MODDEL")"
[ "$RC" = 1 ] && ok "whatever the reason (here a vanished module), a node resource that is deleted is refused" \
  || bad "a delete for another reason was let through (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$WDEL" "$VDEL" "$CDEL")"
{ [ "$RC" = 1 ] && [ "$(grep -c '^    module' <<<"$OUT")" = 3 ]; } \
  && ok "every deleted node resource is listed, not only the first" || bad "the list is incomplete (rc ${RC}): ${OUT}"

echo "=== what stays allowed ==="
run - STUB_TB=false STUB_PLAN="$(plan_of "$WDEL" "$CDEL")"
[ "$RC" = 0 ] && ok "a cluster that is not bootstrapped yet is not judged (phase 1 may rebuild a tainted node)" \
  || bad "a fresh cluster was refused (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$WREP")"
[ "$RC" = 0 ] && ok "a replace (delete then create, a tainted VM) is allowed: it is not a removal" \
  || bad "a replace was refused (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$LBDEL")"
[ "$RC" = 0 ] && ok "a deleted non-node resource (a load balancer) is not read as a node" \
  || bad "a load balancer delete was refused as a node (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$WNEW" "$LBUPD" "$NOOP")"
[ "$RC" = 0 ] && ok "creates, a load balancer update and no-ops pass" || bad "a plain growth was refused (rc ${RC}): ${OUT}"

echo "=== it cannot guess ==="
run - STUB_TB=unreadable STUB_PLAN="$(plan_of "$WDEL")"
[ "$RC" -ne 0 ] && ok "a state that cannot be read is a refusal, not a pass" || bad "an unreadable state passed (rc ${RC}): ${OUT}"
run - STUB_SHOW_RC=1 STUB_PLAN="$(plan_of "$WDEL")"
{ [ "$RC" -ne 0 ] && grep -q 'could not read the plan' <<<"$OUT"; } \
  && ok "a plan that cannot be shown is a refusal, not 'no deletes'" || bad "an unreadable plan passed (rc ${RC}): ${OUT}"
PLANFILE="$W/nope.tfplan" run - STUB_PLAN="$(plan_of "$WNEW")"
{ [ "$RC" = 2 ] && grep -q 'no plan file' <<<"$OUT"; } \
  && ok "a missing plan file is its own error" || bad "a missing plan file was not reported (rc ${RC}): ${OUT}"

echo "=== --creates-only (the plan grow-nodes applies whole) ==="
run creates-only STUB_PLAN="$(plan_of "$WNEW" "$LBUPD")"
[ "$RC" = 0 ] && ok "creates and a load balancer membership update are growth" || bad "growth was refused (rc ${RC}): ${OUT}"
run creates-only STUB_PLAN="$(plan_of "$WNEW" "$WUPD")"
{ [ "$RC" = 1 ] && grep -q 'worker\[0\] (update)' <<<"$OUT"; } \
  && ok "a resize of an existing node riding along with a growth is refused and named" \
  || bad "a resize rode along (rc ${RC}): ${OUT}"
run creates-only STUB_PLAN="$(plan_of "$WNEW" "$WREP")"
[ "$RC" = 1 ] && ok "a replace of an existing node riding along is refused too" || bad "a replace rode along (rc ${RC}): ${OUT}"
run - STUB_PLAN="$(plan_of "$WNEW" "$WUPD")"
[ "$RC" = 0 ] && ok "without the flag an update of a node is not this guard's concern" || bad "the default mode refused an update (rc ${RC}): ${OUT}"

echo "=== infra-apply asks it on both of its paths ==="
# The saved-plan path is exercised through cluster-up (test-cluster-up.sh); the APPROVE=auto path with no PLAN is not,
# so this reads the task itself: one call before each `tofu apply`.
TF="${TASKFILE:-$ROOT/Taskfile.yml}"
block="$(awk '/^  infra-apply:/ {on=1; next} on && /^  [A-Za-z_-]+:/ {on=0} on' "$TF")"
[ "$(grep -c 'refuse-node-deletes.sh' <<<"$block")" = 2 ] && ok "infra-apply calls the guard twice: once for PLAN=, once for the plan it makes itself" \
  || bad "infra-apply calls the guard $(grep -c 'refuse-node-deletes.sh' <<<"$block") time(s), expected 2"
awk '/refuse-node-deletes.sh/ {g=1; next} /^[[:space:]]*tofu apply/ {if (!g) bad=1; g=0} END {exit bad}' <<<"$block" \
  && ok "…and each call comes before the apply it guards" || bad "a tofu apply in infra-apply is not preceded by the guard"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: FAIL -eq 0 is also true when the harness died before asserting anything.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
