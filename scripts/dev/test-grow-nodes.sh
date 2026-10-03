#!/usr/bin/env bash
# scripts/bootstrap/grow-nodes.sh (#59): adding a node to a cluster that is already bootstrapped.
# The script runs for real in a fake repository: tofu is a stub that logs its argv and answers
# `show`, `output` and `state list` from the environment, and the leaves it calls (the tunnels,
# the bootstrap-in-state answer) are stubs. SUT overrides the script, which is how mutants run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/bootstrap/grow-nodes.sh}"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"
mkdir -p "$C/envs" "$W/scripts"/{lib,internal,bootstrap} "$W/bin"
cp "$ROOT/scripts/lib/common.sh" "$W/scripts/lib/"
cp "$SUT" "$W/scripts/bootstrap/grow-nodes.sh"
cp "$ROOT/scripts/internal/refuse-node-deletes.sh" "$W/scripts/internal/"
: >"$C/envs/management-scaleway.tfvars"

cat >"$W/scripts/internal/bootstrap-in-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_TB:-true}"
STUB
cat >"$W/scripts/bootstrap/talos-tunnels.sh" <<'STUB'
#!/usr/bin/env bash
echo "tunnels $*" >>"$CALLS"; exit "${STUB_TUNNELS_RC:-0}"
STUB
cat >"$W/bin/tofu" <<'STUB'
#!/usr/bin/env bash
echo "tofu $*" >>"$CALLS"
case "$1" in
  plan)  [ "${STUB_PLAN_RC:-0}" = 0 ] || { echo "Error: boom" >&2; exit 1; }
         for a in "$@"; do case "$a" in -out=*) echo plan >"${a#-out=}" ;; esac; done ;;
  show)  case "$3" in *machines*) printf '%s\n' "${STUB_MACHINES:-{\}}" ;; *) printf '%s\n' "${STUB_CONFIG:-{\}}" ;; esac ;;
  apply) echo "apply $(basename "${*: -1}")" >>"$CALLS"; [ "${STUB_APPLY_RC:-0}" = 0 ] || { echo "Error: apply failed" >&2; exit 1; }
         case "${*: -1}" in *machines*) : >"$APPLIED" ;; esac ;;
  state)  if [ -e "$APPLIED" ]; then printf '%b' "${STUB_STATE_AFTER:-${STUB_STATE:-}}"; else printf '%b' "${STUB_STATE:-}"; fi ;;
esac
exit 0
STUB
chmod +x "$W"/scripts/internal/*.sh "$W"/scripts/bootstrap/*.sh "$W/bin/tofu"

export CALLS="$W/calls.log" APPLIED="$W/machines-applied"
run() { # <env assignments…> — runs from the cluster dir; sets OUT, RC
  : >"$CALLS"; rm -f "$APPLIED"
  OUT="$( cd "$C" && env PATH="$W/bin:$PATH" SSH_KEY=/k "$@" "$W/scripts/bootstrap/grow-nodes.sh" management scaleway 2>&1 )"; RC=$?
}
change() { # <address> <name> <index> <actions-json>
  printf '{"address":"%s","mode":"managed","name":"%s","index":%s,"change":{"actions":%s}}' "$1" "$2" "$3" "$4"
}
plan_of() { printf '{"resource_changes":[%s]}' "$(IFS=,; echo "$*")"; }
calls() { cat "$CALLS"; }
line_of() { grep -n "$1" "$CALLS" | head -1 | cut -d: -f1; }

SRV3="$(change 'module.scw[0].scaleway_instance_server.worker[3]' worker 3 '["create"]')"
NIC3="$(change 'module.scw[0].scaleway_instance_private_nic.worker[3]' worker 3 '["create"]')"
SG="$(change 'module.scw[0].scaleway_instance_security_group.this[\"fr-par-1\"]' this '"fr-par-1"' '["create"]')"
CFG3="$(change 'module.talos.talos_machine_configuration_apply.worker[3]' worker 3 '["create"]')"
GUARD3="$(change 'module.talos.terraform_data.talos_port_ready_worker[3]' talos_port_ready_worker 3 '["create"]')"
CFG='module.talos.talos_machine_configuration_apply'
MACH='module.scw[0].scaleway_instance_server'
STATE3="$MACH.control_plane[0]\n$MACH.control_plane[1]\n$MACH.control_plane[2]\n$MACH.worker[0]\n$MACH.worker[1]\n$MACH.worker[2]\n"
STATE3+="$CFG.control_plane[0]\n$CFG.control_plane[1]\n$CFG.control_plane[2]\n$CFG.worker[0]\n$CFG.worker[1]\n$CFG.worker[2]\n"
STATE4="${STATE3}$MACH.worker[3]\n"

echo "=== nothing to grow: a no-op ==="
run STUB_TB=false
[ "$RC" = 0 ] && [ ! -s "$CALLS" ] && ok "a cluster with no bootstrap yet is left to the two phases: tofu is never called" \
  || bad "a fresh cluster was touched (rc ${RC}): $(calls | tr '\n' '|')"

run STUB_STATE="$STATE3" STUB_MACHINES="$(plan_of "$SG")"
{ [ "$RC" = 0 ] && ! grep -q '^apply' "$CALLS" && ! grep -q '^tunnels' "$CALLS"; } \
  && ok "a bootstrapped cluster whose every machine is configured plans the machines, applies nothing, opens no tunnel" \
  || bad "a steady cluster was changed (rc ${RC}): $(calls | tr '\n' '|')"
grep -q 'plan .*-target=module.scw\[0\]' "$CALLS" && ! grep -q 'talos_cluster_health\|-target=module.talos' "$CALLS" \
  && ok "…and that plan targets the provider module alone, which never reads the cluster" || bad "the first plan is not the provider module alone: $(calls | tr '\n' '|')"

echo "=== a new worker: machines, outputs, tunnels, then its configuration, in that order ==="
run STUB_STATE="$STATE3" STUB_STATE_AFTER="$STATE4" STUB_MACHINES="$(plan_of "$SRV3" "$NIC3")" STUB_CONFIG="$(plan_of "$CFG3" "$GUARD3")"
[ "$RC" = 0 ] && ok "a fourth worker is created and configured, exit 0" || bad "the growth failed (rc ${RC}): ${OUT}"
a="$(line_of '^apply machines')"; r="$(line_of '^apply refresh')"; t="$(line_of '^tunnels open')"; p="$(line_of 'plan .*config.tfplan')"; b="$(line_of '^apply config')"
{ [ -n "$a" ] && [ -n "$r" ] && [ -n "$t" ] && [ -n "$p" ] && [ -n "$b" ] && [ "$a" -lt "$r" ] && [ "$r" -lt "$t" ] && [ "$t" -lt "$p" ] && [ "$p" -lt "$b" ]; } \
  && ok "machines applied, THEN outputs refreshed, THEN tunnels opened, THEN the configuration planned and applied" \
  || bad "wrong order (machines $a, refresh $r, tunnels $t, plan config $p, apply config $b): $(calls | tr '\n' '|')"
grep -q 'plan .*refresh.tfplan' "$CALLS" && grep 'refresh.tfplan' "$CALLS" | head -1 | grep -q -- '-refresh-only' \
  && grep 'refresh.tfplan' "$CALLS" | head -1 | grep -q 'skip_health_check=true' \
  && ok "the refresh is refresh-only and skips the health read, which would wait for the node being configured" \
  || bad "the refresh step is wrong: $(grep refresh "$CALLS" | tr '\n' '|')"
grep -q 'plan .*-target=module.talos.talos_machine_configuration_apply.worker\[3\]' "$CALLS" \
  && ok "the configuration plan targets worker 3's config apply, by address" || bad "no targeted config plan: $(calls | tr '\n' '|')"
! grep -qE 'plan .*config.tfplan.*(worker\[[012]\]|control_plane)' "$CALLS" \
  && ok "…and only that node: the nodes that already have a configuration are not retargeted" || bad "an existing node was targeted: $(grep 'config.tfplan' "$CALLS")"

echo "=== a node left unconfigured by an earlier, interrupted run ==="
run STUB_STATE="$STATE4" STUB_MACHINES="$(plan_of "$SG")" STUB_CONFIG="$(plan_of "$CFG3")"
{ [ "$RC" = 0 ] && ! grep -q '^apply machines' "$CALLS" && grep -q '^apply config' "$CALLS" && grep -q '^tunnels open' "$CALLS"; } \
  && ok "a machine with no configuration is configured even though none is created now, tunnels included" \
  || bad "the leftover node was not configured (rc ${RC}): $(calls | tr '\n' '|')"

echo "=== it refuses ==="
OTHER="$(change 'module.talos.talos_machine_configuration_apply.worker[1]' worker 1 '["delete","create"]')"
run STUB_STATE="$STATE3" STUB_STATE_AFTER="$STATE4" STUB_MACHINES="$(plan_of "$SRV3")" STUB_CONFIG="$(plan_of "$CFG3" "$OTHER")"
{ [ "$RC" -ne 0 ] && ! grep -q '^apply config' "$CALLS" && grep -q 'worker\[1\]' <<<"$OUT"; } \
  && ok "a configuration plan that also replaces another node's config is refused, named, and never applied" \
  || bad "an existing node's config was let through (rc ${RC}): ${OUT}"

# The machines plan is applied whole, so what rides along with the creates is judged first.
WDEL1="$(change 'module.scw[0].scaleway_instance_server.worker[2]' worker 2 '["delete"]')"
WUPD0="$(change 'module.scw[0].scaleway_instance_server.worker[0]' worker 0 '["update"]')"
run STUB_STATE="$STATE3" STUB_STATE_AFTER="$STATE4" STUB_MACHINES="$(plan_of "$SRV3" "$WDEL1")" STUB_CONFIG="$(plan_of "$CFG3")"
{ [ "$RC" -ne 0 ] && ! grep -q '^apply' "$CALLS" && grep -q 'worker\[2\]' <<<"$OUT"; } \
  && ok "a growth edited together with a lowered count: the worker delete is refused before anything is applied" \
  || bad "a delete rode along with a growth (rc ${RC}): ${OUT}"
run STUB_STATE="$STATE3" STUB_STATE_AFTER="$STATE4" STUB_MACHINES="$(plan_of "$SRV3" "$WUPD0")" STUB_CONFIG="$(plan_of "$CFG3")"
{ [ "$RC" -ne 0 ] && ! grep -q '^apply' "$CALLS" && grep -q 'worker\[0\] (update)' <<<"$OUT"; } \
  && ok "a growth with a pending resize of another node (the #222 class) is refused, named, nothing applied" \
  || bad "a resize rode along with a growth (rc ${RC}): ${OUT}"

run STUB_STATE="$STATE3" STUB_STATE_AFTER="$STATE4" STUB_MACHINES="$(plan_of "$SRV3")" STUB_CONFIG="$(plan_of "$CFG3")" STUB_APPLY_RC=1
{ [ "$RC" -ne 0 ] && ! grep -q '^tunnels' "$CALLS" && grep -q 'creating the machines failed' <<<"$OUT"; } \
  && ok "if creating the machines fails nothing else runs: no refresh, no tunnels, no configuration" || bad "it carried on after a failed apply (rc ${RC}): ${OUT}"

run STUB_STATE="$STATE3" STUB_STATE_AFTER="$STATE4" STUB_MACHINES="$(plan_of "$SRV3")" STUB_CONFIG="$(plan_of "$CFG3")" STUB_TUNNELS_RC=1
{ [ "$RC" -ne 0 ] && ! grep -q 'config.tfplan' "$CALLS"; } \
  && ok "if the tunnels cannot be opened the configuration is not attempted" || bad "it configured without tunnels (rc ${RC}): ${OUT}"

run STUB_STATE="$STATE3" STUB_PLAN_RC=1
{ [ "$RC" -ne 0 ] && grep -q 'could not plan the machines' <<<"$OUT" && grep -q 'boom' <<<"$OUT"; } \
  && ok "a machines plan that fails is refused with tofu's own words, never read as 'no new node'" || bad "a failed plan was swallowed (rc ${RC}): ${OUT}"

echo "=== it is wired in ==="
TF="$ROOT/Taskfile.yml"
[ "$(grep -c 'task: _grow-nodes' "$TF")" = 1 ] && ok "cluster-up calls the _grow-nodes task once" || bad "cluster-up does not call _grow-nodes exactly once"
awk '/task: _grow-nodes/ {g=NR} /PLANFILE="up-/ {p=NR} END{exit !(g && p && g < p)}' "$TF" \
  && ok "…before the plan it would otherwise hang in" || bad "_grow-nodes runs after the first plan"
grep -q 'grow-nodes.sh {{.ROLE}} {{.PROVIDER}}' "$TF" && ok "…and the task runs the script for the role and provider" || bad "the task does not run the script"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
