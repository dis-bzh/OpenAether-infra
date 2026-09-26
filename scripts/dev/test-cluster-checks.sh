#!/usr/bin/env bash
# Unit tests for the assertions that decide an upgrade run is GREEN, against a
# stub kubectl — same shape as test-rolling-replace.sh, one rung below the cloud.
#
# cluster-upgrade.sh is what turns "the apply returned" into "the cluster
# works", and every conclusion it reaches comes out of a
# kubectl query. The class of defect that cost 25 to 90 minutes of paid cloud
# time each on 2026-08-15 was never the cloud: it was a query that FAILED and a
# counter that read the failure as zero. `grep -c` on empty input prints 0, and
# nothing downstream can tell that apart from "every node is on the target".
#
# So the input that matters here is a failing query, not a passing one. Each
# scenario overrides one line of an all-green plan and asks what the script
# concludes from it.
#
# A defect PROVEN in a script under test is reported as KNOWN DEFECT and does
# not redden the suite: this file owns the tests, not the scripts. The day one
# starts holding, `defect_gone` fails so the expectation is promoted to a hard
# assertion. STRICT_DEFECTS=1 makes them fatal now.
#
# Verdicts: ✓ pass, ✗ fail, ⏱ hang (the run never returned, so nothing was
# proven), — skip (the check never ran), ! known defect. Only ✓ is green.
#
# Usage: test-cluster-checks.sh          (STRICT_DEFECTS=1, STRICT_SKIPS=1, RUN_TIMEOUT=<s>)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

REAL_SLEEP="$(command -v sleep)"; export REAL_SLEEP
REAL_KUBECTL="$(command -v kubectl || true)"

PASS=0 FAIL=0 KNOWN=0 SKIPPED=0 HUNG=0
# A run killed by the timeout comes back rc 124, and EVERY negative below is
# `[ "$RUN_RC" -ne 0 ]` — so a script that deadlocks scores as one that correctly
# refused. A hang proves nothing in either direction: it is its own verdict, and
# no conclusion drawn from a run that never returned may count as pass or fail.
RUN_HUNG=0 RUN_CMD=
hung() { printf '  \033[35m⏱\033[0m HANG %s\n' "$*"; HUNG=$((HUNG + 1)); }
from_hang() { # true (and reports) when the verdict comes from a run that never returned
  [ "$RUN_HUNG" = 1 ] || return 1
  hung "$1 — verdict void: '${RUN_CMD}' never returned, killed after ${RUN_TIMEOUT}s"
}
ok()   { from_hang "$*" && return 0; printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { from_hang "$*" && return 0; printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
# Counted, because "27 passed" reads identical whether 0 or 20 of them ran.
skip() { printf '  \033[34m—\033[0m SKIP %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
defect() { # a defect proven in the script under test, not fixed here
  from_hang "$*" && return 0
  printf '  \033[33m!\033[0m KNOWN DEFECT %s\n' "$*"
  KNOWN=$((KNOWN + 1)); [ "${STRICT_DEFECTS:-0}" = 1 ] && FAIL=$((FAIL + 1)); return 0
}
defect_gone() {
  from_hang "$*" && return 0
  printf '  \033[35m^\033[0m FIXED: %s — promote this to a hard assertion\n' "$*"; FAIL=$((FAIL + 1))
}

# --- the stubs ----------------------------------------------------------------
# One stub serves kubectl, task and flux, keyed on "<name> <argv>", so a single
# plan file drives a whole run. STUB_PLAN is "match<TAB>rc<TAB>stdout" lines; the
# first line whose match is a substring of the argv wins, no match = rc 1 and
# silence. In stdout, %% is a newline and @@ a tab (the plan is tab-delimited,
# and two of these queries legitimately return a tab-separated list).
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
argv="$(basename "$0") $*"
printf '%s\n' "$argv" >>"${STUB_LOG:-/dev/null}"
# A manifest piped to `apply -f -` is kept, so a scenario can read what was applied.
case "$argv" in *"apply -f -"*) cat >>"${STUB_LOG:-/dev/null}.stdin" ;; esac
# STUB_BLOCK: the matching call hangs, so a scenario can interrupt a run mid-step.
if [ -n "${STUB_BLOCK:-}" ] && [[ $argv == *"$STUB_BLOCK"* ]]; then
  : >"${STUB_LOG}.blocked"; exec "$REAL_SLEEP" 30
fi
[ -f "${STUB_PLAN:-}" ] || exit 1
while IFS=$'\t' read -r match rc out; do
  [ -n "$match" ] || continue
  case "$argv" in
    *"$match"*)
      out="${out//%%/$'\n'}"; out="${out//@@/$'\t'}"
      # Results on stdout, diagnostics on stderr, like the real thing: a script
      # that reads an error message as data is exactly what we are hunting.
      if [ "${rc:-0}" = 0 ]; then
        [ -n "$out" ] && printf '%b\n' "$out"
      else
        [ -n "$out" ] && printf '%b\n' "$out" >&2
      fi
      exit "${rc:-0}"
      ;;
  esac
done <"$STUB_PLAN"
exit 1
STUB
chmod +x "$STUB_DIR/kubectl"

# A stub talosctl serving one ExtensionStatus: the SCHEMATIC the fleet runs.
# STUB_SCHEMATIC unset = the node cannot be asked, which is its own case.
cat >"$STUB_DIR/talosctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get extensions"*)
    [ -n "${STUB_SCHEMATIC:-}" ] &&
      printf '{"spec":{"metadata":{"name":"schematic","version":"%s"}}}\n' "$STUB_SCHEMATIC"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/talosctl"
ln -s kubectl "$STUB_DIR/task"
ln -s kubectl "$STUB_DIR/flux"

# Time is the one thing a wait loop must not really spend here. Log the request,
# then yield briefly — a pure no-op spins cluster-upgrade's background probe hot.
cat >"$STUB_DIR/sleep" <<'STUB'
#!/usr/bin/env bash
printf 'sleep %s\n' "$1" >>"${STUB_LOG:-/dev/null}"
exec "$REAL_SLEEP" 0.02
STUB
chmod +x "$STUB_DIR/sleep"
export PATH="$STUB_DIR:$PATH"

STUB_PLAN="$STUB_DIR/plan"; export STUB_PLAN
STUB_LOG="$STUB_DIR/calls";  export STUB_LOG

# --- a fake repository root ----------------------------------------------------
# Both scripts derive ROOT from their own path, so a symlinked copy of the layout
# hands them fixture tfvars without going anywhere near envs/ — and still runs
# the real file, never a copy that can drift out of date.
PROVIDER=stubcloud ROLE=staging
GIT_REF='refs/tags/9.9.9-stub'
FAKE="$STUB_DIR/root"
CLUSTER="$FAKE/infrastructure/opentofu/cluster"
TFVARS="$CLUSTER/envs/${ROLE}-${PROVIDER}.tfvars"
mkdir -p "$FAKE/scripts/dev" "$CLUSTER/envs"
ln -s "$ROOT/scripts/dev/cluster-upgrade.sh" "$FAKE/scripts/dev/cluster-upgrade.sh"
# cluster-upgrade chains into infra-verify at the end, which has to be reachable
# from the fake root or the all-green control dies on rc 127 — which is how this
# harness caught the verifier change five minutes after it was written.
ln -s "$ROOT/scripts/dev/infra-verify.sh" "$FAKE/scripts/dev/infra-verify.sh"
UPGRADE="$FAKE/scripts/dev/cluster-upgrade.sh"
KEYFILE="$STUB_DIR/ssh-key-fixture"; : >"$KEYFILE"

# The versions cluster-upgrade upgrades TOWARD. Fictional on purpose: nothing in
# a fixture should read like a pin someone could copy into a real environment.
cat >"$CLUSTER/variables.tf" <<'TF'
variable "talos_installer_schematic_id" {
  default = "1111111111111111111111111111111111111111111111111111111111111111"
}
variable "talos_version" {
  default = "v0.0.2"
}
variable "kubernetes_version" {
  default = "v0.0.2"
}
TF

tfvars() { # <talos> <k8s> — rewrite the fixture env file
  cat >"$TFVARS" <<EOF
talos_version      = "$1"
kubernetes_version = "$2"
git_ref            = "$GIT_REF"
EOF
}
tfvars v0.0.1 v0.0.1

# --- driving a run -------------------------------------------------------------
plan() { : >"$STUB_LOG"; printf '%b' "$*" >"$STUB_PLAN"; }
RUN_TIMEOUT="${RUN_TIMEOUT:-30}"
# `timeout 0` means NO timeout: the knob that exists to catch hangs would silently
# switch the catching off, and a hang would go back to being the CI job's own.
[ "$RUN_TIMEOUT" -gt 0 ] 2>/dev/null ||
  { echo "RUN_TIMEOUT must be a positive integer (0 disables the hang guard)" >&2; exit 2; }
run() { # <cmd...> — RUN_OUT gets stdout+stderr, RUN_RC the status
  : >"$STUB_LOG"; rm -f "$STUB_LOG.stdin"; RUN_HUNG=0; RUN_CMD="$*"
  # To a file, not a pipe: cluster-upgrade leaves a background probe holding the
  # inherited stdout, and a command substitution would wait on it forever.
  # 30s is ten times the slowest scenario. -k: a script that swallows TERM must
  # still die here rather than become the CI job's own timeout.
  timeout -k 5 "$RUN_TIMEOUT" "$@" >"$STUB_DIR/out" 2>&1 && RUN_RC=0 || RUN_RC=$?
  # 124 = timed out, 137 = still there 5s after TERM. Nothing under test exits
  # with either on purpose, so both mean "it never returned".
  case "$RUN_RC" in 124 | 137) RUN_HUNG=1 ;; esac
  RUN_OUT="$(cat "$STUB_DIR/out")"
}
# A real run rewrites the pins, so every scenario starts from a fresh env file a
# patch below the target — otherwise the second one aborts on "upgrades nothing"
# and each assertion after it silently measures the wrong run.
upgrade() { tfvars v0.0.1 v0.0.1; run "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"; }
said()    { case "$RUN_OUT" in *"$1"*) return 0 ;; esac; return 1; }
called()  { grep -qF -- "$1" "$STUB_LOG"; }
# awk, not `grep -c`: this file exists because of what `grep -c` returns on input
# that never arrived.
# Keyed on the DURATION: cluster-upgrade's background probe sleeps 1 the whole
# run, and counting those made "it kept waiting" true of a loop that never ran.
slept() { awk -v d="${1:-}" '/^sleep /{ if (d == "" || $2 == d) n++ } END{print n+0}' "$STUB_LOG"; }
# Call order. A call that never happened reads as "never" on the left and
# "first thing" on the right, so an order check over a missing call fails.
first_at() { awk -v pat="$1" 'index($0,pat){n=NR; exit} END{print (n ? n : 999999)}' "$STUB_LOG"; }
last_at()  { awk -v pat="$1" 'index($0,pat){n=NR} END{print n+0}' "$STUB_LOG"; }

# Every query the tail of a clean upgrade makes, all answered green. Scenarios
# prepend the one line they want to change, because the first match wins.
# `task ` is stubbed because cluster-upgrade chains into `task cluster-verify`
# rather than calling the verifier directly — see the comment where it does.
VERIFY_OK='get --raw=/readyz\t0\tok\n'
VERIFY_OK+='get namespace flux-system\t1\tError from server (NotFound): namespaces "flux-system" not found\n'
VERIFY_OK+='get nodes --no-headers\t0\tnode-a Ready control-plane 9m v0.0.1%%node-b Ready <none> 9m v0.0.1\n'
VERIFY_OK+='k8s-app=cilium\t0\tcilium-aaaaa 1/1 Running 0 9m%%cilium-bbbbb 1/1 Running 0 9m\n'
VERIFY_OK+='task \t0\t\n'
# The service probe (#41): two schedulable nodes, a workload that rolls out and
# answers. Here because every real run deploys it before the first step.
VERIFY_OK+='spec.taints\t0\tNoSchedule%%%%\n'
VERIFY_OK+='apply -f -\t0\t\n'
VERIFY_OK+='rollout status deployment/upgrade-probe\t0\t\n'
VERIFY_OK+='services/http:upgrade-probe\t0\tupgrade-probe-aaaaa\n'
VERIFY_OK+='delete namespace upgrade-probe\t0\t\n'

# Nodes and kubelets already on the target, for cluster-upgrade.
# The fleet BEFORE the upgrade. cluster-upgrade now decides what to run by asking
# the cluster rather than by reading the tfvars — the tfvars is rewritten before
# the apply lands, so an interrupted run leaves it claiming a version nobody has,
# and the next run would skip that step for ever. The survey uses custom-columns
# so it is a different question from the jsonpath counters below, which is what
# lets one stub plan answer "v0.0.1 today" and "v0.0.2 afterwards" in one run.
SURVEY_PRE='custom-columns=V:.status.nodeInfo.kubeletVersion\t0\tv0.0.1%%v0.0.1\n'
SURVEY_PRE+='custom-columns=V:.status.nodeInfo.osImage\t0\tTalos (v0.0.1)%%Talos (v0.0.1)\n'

UPGRADE_OK="$SURVEY_PRE"
UPGRADE_OK+='nodeInfo.kubeletVersion\t0\tv0.0.2%%v0.0.2\n'
UPGRADE_OK+='nodeInfo.osImage\t0\tTalos (v0.0.2)%%Talos (v0.0.2)\n'

echo "=== cluster-upgrade: resolving the target, without a cluster ==="

tfvars v0.0.1 v0.0.1
plan "$VERIFY_OK"
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
{ [ "$RUN_RC" -eq 0 ] && said '+talos_version      = "v0.0.2"' && said '+kubernetes_version = "v0.0.2"'; } \
  && ok "the target comes from cluster/variables.tf and both pins are rewritten" \
  || bad "the dry run did not rewrite both pins (rc=$RUN_RC)"
grep -q 'v0.0.1' "$TFVARS" && ok "…on a COPY: the env file itself is untouched" \
  || bad "DRY_RUN=1 rewrote the real tfvars"

tfvars v0.0.2 v0.0.2
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
{ [ "$RUN_RC" -ne 0 ] && said 'upgrade nothing'; } \
  && ok "a run that would upgrade nothing FAILS instead of quietly passing" \
  || bad "a no-op upgrade ended green — indistinguishable from one that worked"

# SAME VERSION, DIFFERENT SCHEMATIC. The schematic carries the system extensions,
# so this is a real reinstall — and until 2026-08-19 every gate compared the
# version tag alone and called the fleet done. A fleet then sat on the image that
# broke OVH while its own config named the fixed one, reachable by no command.
tfvars v0.0.2 v0.0.2
# export, not a VAR=x prefix: that prefix does not reach the child of a shell
# function, so the stub answered nothing and the case tested itself.
export STUB_SCHEMATIC=2222222222222222222222222222222222222222222222222222222222222222
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
said 'DIFFERENT schematic' \
  && ok "a schematic change is seen even though the versions match" \
  || bad "a schematic change is invisible — it can be rolled out by no path"
said 'upgrade nothing' \
  && bad "it still called the fleet done" \
  || ok "…and the run is not refused as a no-op"

# THE SAME SCHEMATIC must stay a no-op: a guard written for the pathological case
# and never run against the normal one has turned red on the happy path three
# times in this repository.
export STUB_SCHEMATIC=1111111111111111111111111111111111111111111111111111111111111111
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
{ [ "$RUN_RC" -ne 0 ] && said 'upgrade nothing'; } \
  && ok "a matching schematic is still nothing to do" \
  || bad "the schematic check fires when the fleet already matches"

# AND IT MUST NOT GUESS. No tunnel, no answer — say so rather than assume either way.
unset STUB_SCHEMATIC
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
said 'could not be read' \
  && ok "a schematic it could not read is reported, not assumed" \
  || bad "it stayed silent about a comparison it never made"

# THE DISAGREEMENT. An interrupted run rewrites the tfvars BEFORE the apply lands,
# so the file can claim a version no node is running — and the next run used to
# read that file, conclude the step was done, and skip it for ever. Here the
# tfvars says v0.0.2 and the fleet says v0.0.1: the cluster is the one that
# counts, so the run must PROCEED.
#
# This is the only scenario in this file where the two sources differ, and
# therefore the only one that can tell the fix from the bug: reverting
# cluster-upgrade to read the tfvars turns this red and nothing else.
tfvars v0.0.2 v0.0.2
plan "$SURVEY_PRE"
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
{ [ "$RUN_RC" -eq 0 ] && ! said 'upgrade nothing' && said 'read from the cluster'; } \
  && ok "a tfvars that claims the target is overruled by a fleet that does not run it" \
  || bad "a stale tfvars made the run skip an upgrade the cluster still needs (rc=$RUN_RC)"
tfvars v0.0.1 v0.0.1

echo
echo "=== cluster-upgrade: the two version counters ==="

tfvars v0.0.1 v0.0.1
plan "${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -eq 0 ] && said 'every kubelet on v0.0.2' && said 'every node on Talos v0.0.2' \
  && said 'plan empty after the upgrade'; } \
  && ok "an upgrade whose nodes report the target passes end to end" \
  || bad "the all-green upgrade control does not pass (rc=$RUN_RC)"
called 'task image-build PROVIDER=stubcloud VERSION=v0.0.2 ENSURE=1' \
  && ok "the Talos image is ensured for the TARGET version" \
  || bad "task image-build was not called with the target version"
{ [ "$(first_at 'task image-build')" -lt "$(last_at 'task infra-apply')" ]; } \
  && ok "…before the apply that needs the image data source to resolve" \
  || bad "the image was ensured after the apply, which is the plan failure it exists to avoid"
# APPROVE=auto now, not `-- --yes`: one spelling of "do not ask me" across the whole
# repository instead of three (--yes, TF_CLI_ARGS_apply, and a prompt).
{ called 'APPROVE=auto -- --cp-only --upgrade' && called 'APPROVE=auto -- --workers-only --upgrade'; } \
  && ok "the roll is driven non-interactively with APPROVE=auto, control planes first" \
  || bad "the roll was not called with APPROVE=auto (an unattended lane would hang on its prompt)"

# --- and what it verifies at the end ------------------------------------------
# One verifier, because the release ships one floor. This asserts the chain is
# still made at all: an upgrade that skipped its verify would look identical up
# to here, which is how a broken cluster once passed for a working one.
plan "${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ said 'infrastructure floor' && called 'cluster-verify'; } \
  && ok "the upgrade ends by verifying against the infrastructure floor" \
  || bad "the upgrade never chained into cluster-verify"

plan "nodeInfo.kubeletVersion\t0\tv0.0.2%%v0.0.1\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -ne 0 ] && said 'still not on v0.0.2'; } \
  && ok "ONE stale kubelet fails the run after the bounded wait" \
  || bad "a stale kubelet passed (rc=$RUN_RC)"
[ "$(slept 10)" -ge 25 ] && ok "…having actually retried, not judged on the first read" \
  || bad "the kubelet wait did not retry"

plan "nodeInfo.osImage\t0\tTalos (v0.0.2)%%Talos (v0.0.1)\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -ne 0 ] && said 'not running Talos v0.0.2'; } \
  && ok "ONE node left on the old Talos fails the run" \
  || bad "a node still on the old Talos passed (rc=$RUN_RC)"

# The case both counters are built out of. kubectl fails, the pipeline yields no
# lines, `grep -cv … || true` prints 0, and 0 stale nodes reads as "all of them
# are on the target" — from a query that returned nothing at all.
plan "nodeInfo.kubeletVersion\t1\terror: unable to parse requirement\nnodeInfo.osImage\t1\terror: unable to parse requirement\n${VERIFY_OK}"
upgrade
# Promoted from KNOWN DEFECT on 2026-08-17. `grep -cvx <target>` over the output
# of a kubectl that answered nothing prints 0, and 0 stale nodes read as "every
# one of them is on the target" — so a dead apiserver certified both upgrades.
# Both counters now also count the nodes they SAW, and zero seen is fatal.
said 'every kubelet on v0.0.2' \
  && bad "'every kubelet on v0.0.2' announced after a FAILED node query — the counter concluded from nothing" \
  || ok "a failed node query does not announce 'every kubelet on the target'"
said 'every node on Talos v0.0.2' \
  && bad "'every node on Talos v0.0.2' announced after a FAILED node query — same counter, same nothing" \
  || ok "a failed node query does not announce 'every node on the target Talos'"
[ "$RUN_RC" -ne 0 ] \
  && ok "an upgrade that could not read a single node FAILS" \
  || bad "the upgrade ended green (rc=0) without one node version ever having been read"

echo
echo "=== cluster-upgrade: the service probe (#41) ==="

svc_line() { sed -nE 's/.*service probe: ([0-9]+) FAIL, ([0-9]+) BLIND in ([0-9]+) samples, longest outage ([0-9]+)s.*/\1 \2 \3 \4/p' <<<"$RUN_OUT" | tail -1; }
svc_cleaned() { # the namespace went, and the probe loop is no longer polling
  local a
  called 'delete namespace upgrade-probe' || return 1
  # Not "no request after the delete": one already in flight when the loop is
  # killed may still land, harmlessly. A loop still alive keeps adding lines.
  "$REAL_SLEEP" 0.2; a="$(grep -c 'services/http:upgrade-probe' "$STUB_LOG")"
  "$REAL_SLEEP" 0.3; [ "$(grep -c 'services/http:upgrade-probe' "$STUB_LOG")" = "$a" ]
}

plan "${UPGRADE_OK}${VERIFY_OK}"
upgrade
read -r s_fail s_blind s_total s_long <<<"$(svc_line)"
{ [ "$RUN_RC" -eq 0 ] && [ "${s_total:-0}" -gt 0 ] && [ "$s_fail" = 0 ] && [ "$s_long" = 0 ]; } \
  && ok "a green run reports the service probe: ${s_total} samples, 0 FAIL, longest outage 0s" \
  || bad "the service probe reported nothing usable on a green run (rc=$RUN_RC): '$(svc_line)'"
{ [ "$(first_at 'services/http:upgrade-probe')" -lt "$(first_at 'task infra-apply')" ] \
  && grep -q 'replicas: 2' "$STUB_LOG.stdin" && grep -q 'kind: PodDisruptionBudget' "$STUB_LOG.stdin"; } \
  && ok "…2 replicas and a PDB, polled before the first apply" \
  || bad "the probe workload was not deployed and polled before the upgrade started"
svc_cleaned && ok "…and deleted after the probe stopped" || bad "the probe workload was left behind on a green run"

# The Service stops answering while the apiserver does: reported, not gated.
plan "services/http:upgrade-probe\t1\terror: no endpoints available\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
read -r s_fail s_blind s_total s_long <<<"$(svc_line)"
{ [ "$RUN_RC" -eq 0 ] && [ "${s_fail:-0}" -gt 0 ] && [ "$s_fail" = "$s_total" ] && [ "$s_long" = "$s_fail" ]; } \
  && ok "a Service that never answers is counted: ${s_fail} FAIL, longest outage ${s_long}s — reported, not gated" \
  || bad "a dead Service was not counted as down (rc=$RUN_RC): '$(svc_line)'"

# Failure: a stale kubelet fails the run; the numbers and the cleanup must survive it.
plan "nodeInfo.kubeletVersion\t0\tv0.0.2%%v0.0.1\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -ne 0 ] && [ -n "$(svc_line)" ] && svc_cleaned; } \
  && ok "a failed run still reports the service probe and deletes its workload" \
  || bad "a failed run lost the service numbers or left the workload behind (rc=$RUN_RC)"

# The workload never comes up: nothing is measured, so nothing is upgraded.
plan "rollout status deployment/upgrade-probe\t1\terror: timed out\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -ne 0 ] && said 'never became ready' && ! called 'task infra-apply' \
  && called 'delete namespace upgrade-probe'; } \
  && ok "a probe workload that never becomes ready stops the run before any apply, and is deleted" \
  || bad "an unready probe workload did not stop the run cleanly (rc=$RUN_RC)"

# One schedulable node: a PDB there would hold the only worker's drain to its timeout.
plan "spec.taints\t0\tNoSchedule%%\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -eq 0 ] && said 'no PDB' && [ -s "$STUB_LOG.stdin" ] && ! grep -q PodDisruptionBudget "$STUB_LOG.stdin"; } \
  && ok "a single schedulable node gets no PDB, and the run says so" \
  || bad "a PDB was applied on a single schedulable node (rc=$RUN_RC)"

# Interrupt mid-step: TERM to the whole group, as Ctrl+C would send it.
plan "${UPGRADE_OK}${VERIFY_OK}"
tfvars v0.0.1 v0.0.1; rm -f "$STUB_LOG.blocked"; RUN_HUNG=0
STUB_BLOCK='task infra-apply' setsid "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE" >"$STUB_DIR/out" 2>&1 &
int_pid=$!
for _ in $(seq 1 200); do [ -f "$STUB_LOG.blocked" ] && break; "$REAL_SLEEP" 0.05; done
if [ ! -f "$STUB_LOG.blocked" ]; then
  kill -KILL -- "-$int_pid" 2>/dev/null; bad "the run never reached the blocked apply — the interrupt case tested nothing"
else
  kill -TERM -- "-$int_pid"; wait "$int_pid"; int_rc=$?
  { [ "$int_rc" -ne 0 ] && called 'delete namespace upgrade-probe'; } \
    && ok "an interrupted run (rc=$int_rc) still deletes the probe workload" \
    || bad "an interrupted run left the probe workload in the cluster (rc=$int_rc)"
fi
rm -f "$STUB_LOG.blocked"

echo
echo "=== cluster-upgrade: report_probe, the interruption budget ==="

RUN_HUNG=0  # nothing below concludes from a run(), so a prior hang must not void it
# Extracted rather than run: how many samples a background probe gets in a stub
# run is a timing accident, and the interesting input is a log that stayed empty.
eval "$(awk '/^report_probe\(\) \{/,/^\}/' "$ROOT/scripts/dev/cluster-upgrade.sh")"
# `fail` must ABORT, as it does in the script. Returning 1 instead lets the rest
# of the function run and the LAST test decide — which quietly reported a probe
# gate as broken while a fixed one was under test.
fail() { echo "✗ $*"; exit 1; }
probe_ok() { ( report_probe ) >/dev/null; }
# shellcheck disable=SC2034  # both are read by the extracted function
PROBE_LOG="$STUB_DIR/probe"; MAX_PROBE_FAILS=15

# The awk range above is a text match on the script's FORMATTING. When it misses
# — `report_probe () {`, a reindented brace — eval defines nothing, report_probe
# is "command not found", and `probe_ok && bad … || ok …` takes the GREEN branch
# on rc 127. So the extraction is asserted before anything is concluded from it.
if ! declare -F report_probe >/dev/null; then
  bad "report_probe could NOT be extracted from cluster-upgrade.sh — the checks below would have scored a pass from rc 127"
else
  # PROBE_STARTED is what lets report_probe tell a quick step from a dead probe.
  # Unset here would leave `elapsed` at the test shell's own uptime, so every
  # case below sets it deliberately — the sample floor is exercised, not dodged.
  PROBE_STARTED=$SECONDS   # elapsed 0: the floor is inert, as on a fast step
  printf 'ok\nok\nFAIL\nok\n' >"$PROBE_LOG"
  probe_ok && ok "3 samples, 1 FAIL, budget 15 → passes" || bad "a healthy probe failed"

  printf 'FAIL\n%.0s' {1..20} >"$PROBE_LOG"
  probe_ok && bad "20 FAIL against a budget of 15 passed" || ok "20 FAIL over a budget of 15 → fails"

  # The case that used to be a KNOWN DEFECT: an empty log gives longest=0, and
  # `[ 0 -le 15 ]` passes — a probe that never ran reported the API stayed up.
  : >"$PROBE_LOG"
  PROBE_STARTED=$(( SECONDS - 600 ))
  probe_ok && bad "an empty probe log passed after 600s — a probe that never ran proves nothing" \
    || ok "empty log over 600s → refuses to conclude"

  # …and the mirror: the floor must NOT punish a step that was simply quick.
  PROBE_STARTED=$SECONDS
  : >"$PROBE_LOG"
  probe_ok && ok "empty log over 0s → inert, a fast step is not a dead probe" \
    || bad "the sample floor fired on a step that had no time to sample — the guard turned on the happy path"

  # A live probe that is merely behind must still pass: 400 samples in 600s is
  # well above a quarter, and this is what a real run looks like.
  PROBE_STARTED=$(( SECONDS - 600 ))
  printf 'ok\n%.0s' {1..400} >"$PROBE_LOG"
  probe_ok && ok "400 samples over 600s → a healthy real-length run passes" \
    || bad "a healthy 600s run was rejected by the sample floor"
  unset PROBE_STARTED
fi

# BLIND = the apiserver was down too, so the Service could not be observed. It
# must count neither as downtime nor as recovery.
eval "$(awk '/^report_svc_probe\(\) \{/,/^\}/' "$ROOT/scripts/dev/cluster-upgrade.sh")"
if ! declare -F report_svc_probe >/dev/null; then
  bad "report_svc_probe could NOT be extracted from cluster-upgrade.sh"
else
  SVC_LOG="$STUB_DIR/svc-probe"
  printf '%s\n' '10:00:00 ok pod-a' '10:00:01 FAIL' '10:00:02 FAIL' '10:00:03 BLIND' \
    '10:00:04 FAIL' '10:00:05 ok pod-b' '10:00:06 FAIL' >"$SVC_LOG"
  got="$( (ROOT="$FAKE" SVC_STARTED=$SECONDS report_svc_probe) 2>&1)"
  case "$got" in
    *"4 FAIL, 1 BLIND in 7 samples, longest outage 3s, total downtime ~4s"*)
      ok "BLIND neither ends an outage nor counts as one: 4 FAIL, 1 BLIND, longest 3s" ;;
    *) bad "the service probe summary is wrong: $got" ;;
  esac
  : >"$SVC_LOG"
  ( ROOT="$FAKE" SVC_STARTED=$(( SECONDS - 600 )) report_svc_probe ) >/dev/null 2>&1 \
    && bad "an empty service log after 600s passed — a dead probe proves nothing" \
    || ok "an empty service log over 600s → refuses to conclude"
  unset SVC_LOG
fi
unset -f fail probe_ok; unset -f report_probe report_svc_probe 2>/dev/null || true

echo
echo "=== the jsonpath templates parse (real kubectl, no cluster) ==="

RUN_HUNG=0  # kubectl is driven directly here, not through run()
# The stub answers whatever the plan says, so it can never tell us the QUERY is
# wrong — and one of the 2026-08-15 defects was a filter kubectl cannot parse,
# which fails every time and returns nothing, which reads as "nothing wrong".
# `patch --local` runs the template through the same parser, offline.
if [ -z "$REAL_KUBECTL" ]; then
  skip "kubectl is not installed — the jsonpath templates went unchecked"
else
  cat >"$STUB_DIR/obj.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: fixture, namespace: flux-system}
spec: {suspend: true, ref: {name: refs/tags/9.9.9-stub}}
status:
  conditions: [{type: Ready, status: "True"}]
  nodeInfo: {kubeletVersion: v0.0.2, osImage: "Talos (v0.0.2)"}
YAML
  parses() { # <template> — true unless kubectl's jsonpath parser rejects it
    # Through a file, not a pipe: under pipefail the pipeline would report
    # kubectl's rc, not grep's, and every template would look accepted.
    "$REAL_KUBECTL" patch --local --type merge -f "$STUB_DIR/obj.yaml" -p '{}' \
      -o "jsonpath=$1" >/dev/null 2>"$STUB_DIR/jsonpath.err"
    ! grep -q 'error parsing jsonpath' "$STUB_DIR/jsonpath.err"
  }
  parses '{range .items[?(@.spec.suspend==true]}{end}' \
    && bad "an unterminated filter was accepted — this check cannot fail" \
    || ok "control: a malformed template IS rejected"
  templates() { # <file...> — every jsonpath template, whichever way it is quoted
    # Four shapes in the wild: single or double quotes, opening either before
    # the word jsonpath or after its `=`. An extractor that knows one of them is
    # blind to the rest and reports that blindness as "every template parses" —
    # the defect class this block exists for. What it cannot see, it cannot
    # check. (No literal template in this comment: check-jsonpath.sh reads it.)
    grep -ohE -e "jsonpath='[^']*'" -e "'jsonpath=[^']*'" "$@" |
      sed -E "s/^'?jsonpath='?//; s/'\$//"
    # A double-quoted shell string owns the backslash before " $ ` \ — strip
    # exactly those, so the template is what kubectl would receive. {"\n"} stays.
    grep -ohE -e 'jsonpath="(\\.|[^"\\])*"' -e '"jsonpath=(\\.|[^"\\])*"' "$@" |
      sed -E 's/^"?jsonpath="?//; s/"$//; s/\\(["$`\\])/\1/g'
  }
  # Read out of the scripts, so a template added tomorrow is covered too — and
  # from BOTH, cluster-idempotency.sh included.
  TPL_FILES=("$ROOT/scripts/dev/cluster-upgrade.sh"
    "$ROOT/scripts/dev/cluster-idempotency.sh")
  n_tpl=0
  while read -r tpl; do
    [ -n "$tpl" ] || continue
    n_tpl=$((n_tpl + 1))
    # A `$VAR` survives extraction as literal text, and kubectl ACCEPTS literal
    # text — so parsing it would mint a green tick for a template never read.
    if [[ $tpl =~ \$[A-Za-z_{] ]]; then
      skip "built from a shell variable, so it was never parsed: $tpl"; continue
    fi
    # `{range}` with no `{end}` PARSES and then prints nothing — the same "the
    # query came back empty, so nothing is wrong" class. It is also what a
    # template split over a line continuation looks like to the extractor.
    case "$tpl" in
      *'{range'*'{end}'*) ;;
      *'{range'*) bad "unterminated {range}: parses, selects nothing, reads as clean: $tpl"; continue ;;
    esac
    parses "$tpl" && ok "parses: ${tpl:0:56}…" || bad "kubectl cannot parse: $tpl"
  done < <(templates "${TPL_FILES[@]}" | sort -u)
  # A COVERAGE floor, not a zero floor: "> 0" still reads green when the extractor
  # sees five uses out of six. Count what the files ASK for and demand as many
  # back, so a quoting style nobody anticipated fails loudly instead of unchecked.
  n_used="$(grep -vhE '^[[:space:]]*#' "${TPL_FILES[@]}" | grep -ohE 'jsonpath[a-z-]*=' | grep -c . || true)"
  n_raw="$(templates "${TPL_FILES[@]}" | grep -c . || true)"
  { [ "$n_raw" -ge "$n_used" ] && [ "$n_tpl" -gt 0 ]; } \
    && ok "the extractor saw all ${n_used} jsonpath use(s): ${n_tpl} distinct template(s)" \
    || bad "the jsonpath extractor saw ${n_raw} of ${n_used} jsonpath use(s) — what it cannot see, it cannot check"
  # The filter itself, against data: parsing it is not selecting with it.
  got="$("$REAL_KUBECTL" patch --local --type merge -f "$STUB_DIR/obj.yaml" -p '{}' \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "$got" = True ] && ok "the Ready-condition filter selects the condition, not the first one" \
    || bad "the Ready-condition filter selected '$got'"
fi


# =============================================================================
# infra-verify: the fleet runs the versions the tfvars pin
#
# `cluster-up` writes the pinned installer image into the machine config and asks
# no node to upgrade, so a bumped pin leaves the fleet behind with an empty plan
# behind it — and the schematic check cannot see it, because a version bump does
# not change the schematic. Until this section existed, infra-verify.sh was
# symlinked into the fake root and never once executed: the only assertion about
# the verifier was that cluster-upgrade CALLED it.
#
# PROVIDER=local on purpose: that path skips every `tofu output` and `aws s3`, so
# the whole script is drivable by the stub kubectl alone.
# =============================================================================
echo
echo "=== infra-verify: the fleet runs the versions the config pins ==="

VERIFY_SH="$FAKE/scripts/dev/infra-verify.sh"
LOCAL_DIR="$FAKE/infrastructure/opentofu-local"
mkdir -p "$LOCAL_DIR"
: >"$LOCAL_DIR/kubeconfig"; : >"$LOCAL_DIR/talosconfig"
cat >"$LOCAL_DIR/variables.tf" <<'TFV'
variable "talos_version" {
  type    = string
  default = "v0.0.2"
}

variable "kubernetes_version" {
  type    = string
  default = "v0.0.2"
}
TFV

# Everything section 1 asks, answered green, so the run reaches the version
# section instead of timing out in the bounded waits above it.
BASE='get --raw=/readyz\t0\tok\n'
BASE+='get nodes -l node-role.kubernetes.io/control-plane\t0\tcp-a Ready control-plane 9m\n'
BASE+='k8s-app=cilium\t0\tcilium-a 1/1 Running%%cilium-b 1/1 Running\n'
BASE+='readyReplicas\t0\t1\n'
BASE+='get namespace flux-system\t1\tNotFound\n'
BASE+='get nodes --no-headers\t0\tnode-a Ready control-plane 9m%%node-b Ready <none> 9m\n'

verify_local() { run "$VERIFY_SH" local; }

# The COUNT, not the message. Turning `unk` into `ok` leaves the sentence
# identical — an assertion on the words alone survives that mutation, and did.
unk_count() { sed -E 's/\x1b\[[0-9;]*m//g' <<<"$RUN_OUT" |
                sed -nE 's/.*, ([0-9]+) could not be checked.*/\1/p' | tail -1; }

# --- both pins matched --------------------------------------------------------
plan 'osImage\t0\tTalos (v0.0.2)\n''kubeletVersion\t0\tv0.0.2\n'"$BASE"
verify_local
{ said 'every node runs the pinned Talos (v0.0.2)' && said 'every node runs the pinned Kubernetes (v0.0.2)'; } \
  && ok "a fleet on the pinned versions passes" \
  || bad "a fleet that matches its pins was not recognised as matching"

# --- the case this section exists for -----------------------------------------
# One patch behind, which is what a bumped tfvars and an un-rolled fleet look
# like. The schematic is untouched by a version bump, so nothing else sees it.
plan 'osImage\t0\tTalos (v0.0.1)\n''kubeletVersion\t0\tv0.0.2\n'"$BASE"
verify_local
{ said 'the fleet runs Talos v0.0.1, the config pins v0.0.2' && [ "$RUN_RC" -ne 0 ]; } \
  && ok "a fleet a version behind its pin FAILS the run" \
  || bad "a version behind the pin passed — the drift cluster-up leaves is invisible"

# --- a roll that stopped half way ---------------------------------------------
# Neither "matches" nor "drifted": saying "drifted" here would send the operator
# to re-run an upgrade when the truth is that one is already half done.
plan 'osImage\t0\tTalos (v0.0.1)%%Talos (v0.0.2)\n''kubeletVersion\t0\tv0.0.2\n'"$BASE"
verify_local
{ said 'the fleet is MIXED on Talos' && said 'v0.0.1,v0.0.2'; } \
  && ok "a mixed fleet is named as mixed, not as drifted" \
  || bad "a half-finished roll reads as a plain version drift"

# --- the question could not be asked ------------------------------------------
# `unk`, never `ok`: a node query that FAILED once read as "everything is on the
# target" in this repository, which is the defect this whole file exists for.
plan 'osImage\t1\tError from server: connection refused\n''kubeletVersion\t0\tv0.0.2\n'"$BASE"
verify_local
{ said 'could not read the running Talos' && [ "$(unk_count)" -ge 1 ] \
  && ! said 'every node runs the pinned Talos'; } \
  && ok "an unanswered version query is UNCHECKED ($(unk_count) unknown), not a pass" \
  || bad "a failed node query read as a fleet on the target, or was not counted as unknown"

# =============================================================================
# cluster-upgrade: the path across minors
#
# Kubernetes forbids skipping a minor on the way up, and Talos supports a WINDOW
# of Kubernetes minors — so a valid start and a valid end can be joined by a step
# that is neither. (1.12, 1.30) → (1.13, 1.36) taken Talos-first lands on
# (1.13, 1.30), below 1.13's floor of 1.31, and is refused at apply time — after
# the step before it has already landed on a paying cluster.
#
# The functions are sourced rather than driven through the script: the harness
# fixture pins v0.0.1/v0.0.2, which carries no minor semantics at all.
# =============================================================================
echo
echo "=== cluster-upgrade: the path across minors ==="

PATH_FNS="$STUB_DIR/pathfns.sh"
_a=$(grep -n '^SUPPORT_JSON=' "$ROOT/scripts/dev/cluster-upgrade.sh" | cut -d: -f1)
_b=$(awk -v a="$_a" 'NR>a && /^}$/ {n=NR} NR>a && /^TALOS_TO=/ {print n; exit}' "$ROOT/scripts/dev/cluster-upgrade.sh")
{ printf 'ROOT=%q\n' "$ROOT"; sed -n "${_a},${_b}p" "$ROOT/scripts/dev/cluster-upgrade.sh"; } > "$PATH_FNS"
# rc 127 from a failed extraction would make every negative below score a pass.
# shellcheck source=/dev/null
if source "$PATH_FNS" 2>/dev/null && declare -f version_path >/dev/null; then
  ok "the path functions were extracted and are callable"
else
  bad "could not extract version_path — every assertion below would be vacuous"
fi

CLIMB="$(version_path v1.12.7 v1.30.0 v1.13.9 v1.36.3 2>/dev/null)"
[ "$(printf '%s' "$CLIMB" | grep -c .)" = 7 ] \
  && ok "(1.12.7, 1.30.0) → (1.13.9, 1.36.3) is a 7-step climb" \
  || bad "expected 7 steps, got $(printf '%s' "$CLIMB" | grep -c .)"

# EVERY pair on the way, not just the ends. This is the whole point.
_bad=0
while read -r tv kv; do
  [ -n "$tv" ] || continue
  pair_ok "$tv" "$kv" || { _bad=$((_bad + 1)); }
done <<<"$CLIMB"
[ "$_bad" = 0 ] \
  && ok "…and every pair along it is inside the supported window" \
  || bad "${_bad} step(s) of the climb are pairs the guard would refuse"

# The first draft passed through v1.12.0 while the cluster ran v1.12.7 — a patch
# DOWNGRADE, commanded by a function whose job is to go up.
[ "$(printf '%s' "$CLIMB" | head -1 | awk '{print $1}')" = v1.12.7 ] \
  && ok "the minor it is already on keeps its patch — no downgrade on the way through" \
  || bad "step 1 moves Talos to $(printf '%s' "$CLIMB" | head -1 | awk '{print $1}'), off the running v1.12.7"

[ "$(version_path v1.13.8 v1.36.3 v1.13.9 v1.36.3 2>/dev/null)" = "v1.13.9 v1.36.3" ] \
  && ok "a patch bump is one step, not an empty list" \
  || bad "a patch-only move produced $(version_path v1.13.8 v1.36.3 v1.13.9 v1.36.3 2>/dev/null | tr '\n' '/')"

# Kubernetes alone, Talos held still — a real thing to want, and the ONLY route
# that consults a Talos minor's CEILING. Every climb that also moves Talos takes
# it first, so 1.12's k8s_max is never read on those: narrowing it to 31 changed
# nothing and looked like a weak test until this case existed.
_k8sonly="$(version_path v1.12.7 v1.30.0 v1.12.9 v1.35.0 2>/dev/null)"
{ [ "$(printf '%s' "$_k8sonly" | grep -c .)" = 5 ] \
  && [ "$(printf '%s' "$_k8sonly" | tail -1)" = "v1.12.9 v1.35.0" ]; } \
  && ok "Kubernetes 1.30 → 1.35 on a held Talos is five steps, up to the ceiling" \
  || bad "a Kubernetes-only climb to 1.12's ceiling produced $(printf '%s' "$_k8sonly" | tr '\n' '/')"

# On the MESSAGE, not just the verdict: without the guard the loop refuses a
# downgrade anyway, having tried and failed to climb — same exit code, and an
# operator told "no supported step out of 1.13" when they asked to go DOWN reads
# it as a broken map. The guard's whole value is the sentence.
_dn="$(version_path v1.13.9 v1.36.3 v1.12.7 v1.30.0 2>&1)"; _dnrc=$?
{ [ "$_dnrc" -ne 0 ] && grep -q 'goes DOWN' <<<"$_dn"; } \
  && ok "a downgrade is refused AS a downgrade, not as a dead end" \
  || bad "downgrade refused without saying so (rc=$_dnrc): ${_dn%%$'\n'*}"

# Refused BEFORE printing: a caller shown steps and then a refusal has been told
# to start something that cannot finish.
# Also on the message. The loop would refuse this on its own after climbing and
# failing, so the verdict alone does not distinguish "your target is not in the
# matrix" from "I got stuck somewhere on the way" — and only the first is true.
_out="$(version_path v1.12.7 v1.30.0 v1.99.0 v1.36.3 2>/dev/null)"; _rc=$?
_err="$(version_path v1.12.7 v1.30.0 v1.99.0 v1.36.3 2>&1 >/dev/null)"
{ [ "$_rc" -ne 0 ] && [ -z "$_out" ] && grep -q 'the TARGET' <<<"$_err"; } \
  && ok "an unreachable TARGET is named as such, with no steps printed" \
  || bad "refused without naming the target (rc=$_rc, steps=${_out:+yes}): ${_err%%$'\n'*}"

# And the control: the guard must refuse something, or it guards nothing.
pair_ok v1.13.9 v1.30.0 \
  && bad "1.13 + Kubernetes 1.30 accepted — below the floor of 1.31" \
  || ok "1.13 + Kubernetes 1.30 refused — the window is actually consulted"

# The dispatch across a real seven-step path. The harness fixture pins v0.0.1 on
# purpose — fictional, so nobody copies it into an environment — which means it
# carries no minor semantics and exercises exactly one step. walk_path is a
# function so this can feed it a path directly, with the two operations stubbed.
_wa=$(grep -n '^walk_path() {' "$ROOT/scripts/dev/cluster-upgrade.sh" | cut -d: -f1)
_wb=$(awk -v a="$_wa" 'NR>=a && /^}$/ {print NR; exit}' "$ROOT/scripts/dev/cluster-upgrade.sh")
eval "$(sed -n "${_wa},${_wb}p" "$ROOT/scripts/dev/cluster-upgrade.sh")"
declare -f walk_path >/dev/null \
  && ok "walk_path was extracted and is callable" \
  || bad "could not extract walk_path — the assertions below would be vacuous"

CLIMB7="$(version_path v1.12.7 v1.30.0 v1.13.9 v1.36.3 2>/dev/null)"
upgrade_k8s_to()   { echo "k8s $1"; }
upgrade_talos_to() { echo "talos $1"; }
_seq="$(walk_path v1.12.7 v1.30.0 7 <<<"$CLIMB7" | grep -E '^(k8s|talos) ' | tr '\n' '|')"
_want='k8s v1.31.0|talos v1.13.9|k8s v1.32.0|k8s v1.33.0|k8s v1.34.0|k8s v1.35.0|k8s v1.36.3|'
[ "$_seq" = "$_want" ] \
  && ok "seven steps dispatch as one Kubernetes hop, then Talos, then five more" \
  || bad "dispatch order wrong: $_seq"

# An axis that does not move must not be touched. Talos appears once in that
# sequence, not seven times — re-applying an unchanged version would re-roll six
# nodes for nothing, six times over.
[ "$(grep -c '^talos ' <<<"$(walk_path v1.12.7 v1.30.0 7 <<<"$CLIMB7")")" = 1 ] \
  && ok "…and Talos is rolled once, not once per step" \
  || bad "Talos was dispatched $(grep -c '^talos ' <<<"$(walk_path v1.12.7 v1.30.0 7 <<<"$CLIMB7")") times"

# The within-step order is DEFENSIVE: version_path never emits a step that moves
# both axes, so nothing in a real climb observes it, and swapping the two lines
# changed no assertion. Feed it the step the builder cannot produce, and the
# choice becomes checkable — Kubernetes first, because it reboots nothing and so
# keeps the control-plane roll separate from the node roll.
upgrade_k8s_to()   { echo "k8s $1"; }
upgrade_talos_to() { echo "talos $1"; }
_both="$(walk_path v1.12.7 v1.30.0 1 <<<"v1.13.9 v1.31.0" | grep -E '^(k8s|talos) ' | tr '\n' '|')"
[ "$_both" = 'k8s v1.31.0|talos v1.13.9|' ] \
  && ok "a step moving both axes does Kubernetes first — the reboot-free one" \
  || bad "both-axis step dispatched as: $_both"

# The one that matters most. `printf … | walk_path` put the loop in a subshell,
# where a failing step exits the subshell and the run carries on to the next —
# measured, the harness went 35/8. A step that fails must stop the climb.
upgrade_k8s_to() { echo "k8s $1"; [ "$1" = v1.32.0 ] && { echo "BOOM" >&2; exit 1; }; return 0; }
_out="$( walk_path v1.12.7 v1.30.0 7 <<<"$CLIMB7" 2>/dev/null )" || true
{ grep -q 'k8s v1.32.0' <<<"$_out" && ! grep -q 'k8s v1.33.0' <<<"$_out"; } \
  && ok "a step that fails stops the climb instead of walking past it" \
  || bad "the climb continued after a failed step: $(tr '\n' '|' <<<"$_out")"
# The defect a real cluster found, and every stub above hid. Inside the loop
# `task cluster-roll` reaches ssh and talosctl, and BOTH READ STDIN — the same
# stdin the here-string feeds the loop. Measured on Scaleway 2026-08-21: the
# Talos roll of step 2 swallowed steps 3-7, the climb exited 0 announcing
# v1.36.3, and the cluster sat on v1.31.0 with every check green. A stub that
# drains stdin, as ssh does, reproduces it without a cloud.
upgrade_k8s_to()   { echo "k8s $1"; }
upgrade_talos_to() { echo "talos $1"; cat >/dev/null; }
_eat="$(walk_path v1.12.7 v1.30.0 7 <<<"$CLIMB7" | grep -cE '^(k8s|talos) ' || true)"
[ "$_eat" = 7 ] \
  && ok "a step that reads stdin cannot swallow the rest of the climb" \
  || bad "a stdin-reading step truncated the climb to ${_eat}/7 dispatches"

unset -f upgrade_k8s_to upgrade_talos_to walk_path
echo "=== converge-versions: the half of cluster-up that OpenTofu cannot do ==="

# Its own stub, because both reads ask the SAME question — `custom-columns` on the
# same field — so the shared plan cannot tell "before the roll" from "after" it.
# This one keys on whether a roll has happened, which is exactly the distinction
# the post-roll re-read exists to make.
mkdir -p "$FAKE/scripts/internal" "$FAKE/scripts/lib" "$STUB_DIR/conv"
ln -s "$ROOT/scripts/internal/converge-versions.sh" "$FAKE/scripts/internal/converge-versions.sh"
ln -s "$ROOT/scripts/lib/common.sh" "$FAKE/scripts/lib/common.sh"
CONVERGE="$FAKE/scripts/internal/converge-versions.sh"
cat >"$STUB_DIR/conv/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"${STUB_LOG:-/dev/null}"
# Talos moves after a `cluster-roll`, Kubernetes moves after an `infra-apply` —
# they are two different commands now, so each field flips on its own trigger.
if grep -q 'cluster-roll' "${STUB_LOG:-/dev/null}" 2>/dev/null
  then t="${CONV_T_AFTER:-}"; else t="${CONV_T_BEFORE:-}"; fi
if grep -q 'infra-apply' "${STUB_LOG:-/dev/null}" 2>/dev/null
  then k="${CONV_K_AFTER:-}"; else k="${CONV_K_BEFORE:-}"; fi
case "$*" in
  *osImage*)        [ -n "$t" ] || exit 0; printf 'Talos (%s)\nTalos (%s)\n' "$t" "$t" ;;
  *kubeletVersion*) [ -n "$k" ] || exit 0; printf '%s\n%s\n' "$k" "$k" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/conv/kubectl"
cat >"$STUB_DIR/conv/task" <<'STUB'
#!/usr/bin/env bash
printf 'task %s\n' "$*" >>"${STUB_LOG:-/dev/null}"
STUB
chmod +x "$STUB_DIR/conv/task"

conv() { # <t-before> <k-before> <t-after> <k-after> [--check]
  : >"$STUB_LOG"
  CONV_OUT="$(PATH="$STUB_DIR/conv:$PATH" \
    CONV_T_BEFORE="$1" CONV_K_BEFORE="$2" CONV_T_AFTER="${3:-$1}" CONV_K_AFTER="${4:-$2}" \
    "$CONVERGE" "$PROVIDER" "$ROLE" "$KEYFILE" ${5:+--check} 2>&1)"; CONV_RC=$?
}
rolled() { grep -q "cluster-roll.*$1" "$STUB_LOG" 2>/dev/null; }

tfvars v0.0.2 v0.0.2

# The NORMAL case first. cluster-up leaves the fleet matching its pin, so this
# runs on every ordinary bring-up: if it rolled here it would re-roll every node
# of every healthy cluster, for ever.
conv v0.0.2 v0.0.2
{ [ "$CONV_RC" -eq 0 ] && ! rolled . ; } \
  && ok "a fleet already on the pin is not rolled" \
  || bad "an up-to-date fleet was rolled anyway (rc=$CONV_RC): $CONV_OUT"

conv v0.0.1 v0.0.1 v0.0.2 v0.0.2
{ [ "$CONV_RC" -eq 0 ] && rolled cp-only && rolled workers-only; } \
  && ok "a drifted fleet is rolled, control planes before workers" \
  || bad "the drift was not converged (rc=$CONV_RC): $CONV_OUT"

# The defect stage 3 found, one level up: the roll reporting success is the
# CLIENT talking. Ask the fleet again, and refuse to claim what it does not say.
conv v0.0.1 v0.0.1 v0.0.1 v0.0.1
{ [ "$CONV_RC" -ne 0 ] && printf '%s' "$CONV_OUT" | grep -q 'after the roll'; } \
  && ok "a roll that did not move the fleet fails instead of announcing success" \
  || bad "a roll that changed nothing was reported as converged (rc=$CONV_RC)"

# One axis at a time. The scenario above lags on BOTH, so the Talos check alone
# catches it and the Kubernetes one can be deleted with every assertion still
# green — measured, it survived the mutation. These two isolate each branch.
conv v0.0.1 v0.0.1 v0.0.2 v0.0.1
{ [ "$CONV_RC" -ne 0 ] && printf '%s' "$CONV_OUT" | grep -q 'Kubernetes v0.0.1'; } \
  && ok "…and a Kubernetes-only lag is caught on its own" \
  || bad "a Kubernetes-only lag survived the post-roll re-read (rc=$CONV_RC): $CONV_OUT"

conv v0.0.1 v0.0.1 v0.0.1 v0.0.2
{ [ "$CONV_RC" -ne 0 ] && printf '%s' "$CONV_OUT" | grep -q 'Talos v0.0.1'; } \
  && ok "…and a Talos-only lag is caught on its own" \
  || bad "a Talos-only lag survived the post-roll re-read (rc=$CONV_RC): $CONV_OUT"

conv v0.0.1 v0.0.1 v0.0.2 v0.0.2 --check
{ [ "$CONV_RC" -eq 0 ] && ! rolled . && printf '%s' "$CONV_OUT" | grep -q 'does not match'; } \
  && ok "--check reports the drift before the approval and rolls nothing" \
  || bad "--check rolled something or said nothing (rc=$CONV_RC): $CONV_OUT"

# The defect found on 2026-08-24: a Kubernetes-only lag used to call
# `cluster-roll --upgrade` unconditionally, which only ever runs `talosctl
# upgrade` — the wrong mechanism for a version that moves through the machine
# config alone. Assert on the MECHANISM, not on rolling-replace.sh's own
# happen-to-be-harmless no-op: the Talos roll must not be invoked at all when
# only Kubernetes lags, and the reverse.
applied() { grep -q 'infra-apply' "$STUB_LOG" 2>/dev/null; }

# Talos ALREADY on the pin, only Kubernetes lags — the case that used to call
# cluster-roll unconditionally for a version that never moves through a roll.
conv v0.0.2 v0.0.1 v0.0.2 v0.0.2
{ [ "$CONV_RC" -eq 0 ] && applied && ! rolled cp-only && ! rolled workers-only; } \
  && ok "a Kubernetes-only lag applies the config and never calls the Talos roll" \
  || bad "a Kubernetes-only lag touched the roll (rc=$CONV_RC): $CONV_OUT"

# Kubernetes ALREADY on the pin, only Talos lags.
conv v0.0.1 v0.0.2 v0.0.2 v0.0.2
{ [ "$CONV_RC" -eq 0 ] && rolled cp-only && rolled workers-only && ! applied; } \
  && ok "a Talos-only lag rolls and never calls infra-apply on its own" \
  || bad "a Talos-only lag skipped the roll or applied redundantly (rc=$CONV_RC): $CONV_OUT"


# A fleet nobody could read is not a converged fleet. Before the apply that is
# normal and silent; after it, claiming anything would be the original defect.
conv "" ""
{ [ "$CONV_RC" -ne 0 ] && printf '%s' "$CONV_OUT" | grep -q 'UNKNOWN'; } \
  && ok "an unreadable fleet is refused, not called converged" \
  || bad "an unreadable fleet did not stop the run (rc=$CONV_RC): $CONV_OUT"

conv "" "" "" "" --check
[ "$CONV_RC" -eq 0 ] \
  && ok "…but before the apply, no cluster to read is not an error" \
  || bad "--check failed with no cluster yet (rc=$CONV_RC): $CONV_OUT"

echo
printf '%s passed, %s failed, %s hung, %s skipped, %s known defect(s) in the scripts under test\n' \
  "$PASS" "$FAIL" "$HUNG" "$SKIPPED" "$KNOWN"
{ [ "$KNOWN" -eq 0 ] || [ "${STRICT_DEFECTS:-0}" = 1 ]; } ||
  printf 'known defects are reported, not fixed: this file owns the tests. STRICT_DEFECTS=1 makes them fatal.\n'
RC=0
[ "$FAIL" -eq 0 ] || RC=1
  # Zero failures is also what a harness that never asserted reports.
  [ "$PASS" -gt 0 ] || { printf 'NOT green: no assertion ran at all.\n'; RC=1; }
# A hang is red on its own: it means an assertion never got an answer to judge.
[ "$HUNG" -eq 0 ] || { printf 'NOT green: %s verdict(s) came from a run that never returned.\n' "$HUNG"; RC=1; }
# An assertion that did not run has proven nothing, so a run with skips is not
# "all passed" however many passed. Soft by default (kubectl may be absent).
[ "$SKIPPED" -eq 0 ] || {
  printf 'NOT fully green: %s check(s) were SKIPPED and proved nothing. STRICT_SKIPS=1 makes them fatal.\n' "$SKIPPED"
  [ "${STRICT_SKIPS:-0}" = 1 ] && RC=1
}
exit "$RC"
