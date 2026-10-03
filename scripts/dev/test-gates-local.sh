#!/usr/bin/env bash
# Rung ONE: the roll's gates against a real Kubernetes, in Docker.
#
# Rung zero (test-rolling-replace.sh) drives them against a stub keyed on argv.
# That proves the branching and NOT that the queries are executable: on
# 2026-08-15 a gate passed eleven of eleven unit assertions while its jsonpath
# was one kubectl refuses to parse, and it took a real deadlock on a paying
# cluster to find out. check-jsonpath.sh now catches that shape offline; this
# catches the rest — a resource name that resolves to the wrong CRD, a label
# selector that matches nothing, a budget the gate misreads.
#
# What it CANNOT cover: `talosctl upgrade` itself. Talos in a container has no
# disk and no installer, so the upgrade stays cloud-only. Of the eleven defects
# found on 2026-08-15, exactly one needed that.
#
# Needs: `task local-up` (3 CP + 3 workers in Docker).
# Usage: test-gates-local.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/infrastructure/opentofu-local/kubeconfig}"
# One namespace per run: cleanup is --wait=false, so a reused namespace still
# holds the previous run's blocking budget and fails the satisfiable case.
NS="gate-lab-$$"

PASS=0
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

kubectl cluster-info >/dev/null 2>&1 || {
  echo "✗ no local cluster — run: task local-up" >&2
  exit 1
}

cleanup() { kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
kubectl create ns "$NS" >/dev/null

# --- the functions under test, with a REAL kubectl -----------------------------
eval "$(awk '
  BEGIN { # pdb_short is what wait_pdb_headroom calls: extracting one without the other
          # gave "pdb_short: command not found", a non-zero return, and an assertion
          # that read it as "the gate blocked" — red for a reason that was not the code.
          split("cnpg_installed,cnpg_pod_state,cnpg_deadlocked,pdb_short,wait_pdb_headroom", a, ",")
          for (i in a) want[a[i]] = 1 }
  /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
  inside { print }
  inside && /^\}/ { inside = 0 }
' "$ROOT/scripts/lib/roll-gates.sh")"
KCTL=(kubectl)
info() { :; }
warn() { :; }
# `ok` is what the gates themselves log through, so it must NOT be the pass
# counter. While it was, a gate logging its own success scored an assertion
# nobody wrote: this file reported 8 passes for 6 assertions.
ok()   { :; }
die()  { printf 'die: %s\n' "$*"; return 1; }
ASSUME_YES=0
DRAIN_TIMEOUT=60s

echo "=== every resource name the ops scripts use resolves to what they mean ==="
# The defect this covers: `kubectl get cluster` is ambiguous the moment CAPI is
# installed, and resolves to clusters.cluster.x-k8s.io rather than CNPG's.
while IFS= read -r res; do
  [ -n "$res" ] || continue
  out="$(kubectl get "$res" -A 2>&1 >/dev/null)"
  case "$out" in
    *"the server doesn't have a resource type"* | *NotFound* | "")
      pass "$res — resolves or is legitimately absent" ;;
    *"error parsing"* | *ambiguous*)
      bad "$res — $out" ;;
    *) pass "$res — resolves" ;;
  esac
done < <(grep -rhoE "get [a-z]+\.[a-z0-9.-]+\.io\b" "$ROOT/scripts/ops" "$ROOT/scripts/dev" 2>/dev/null |
  sed 's/^get //' | sort -u)

echo
echo "=== wait_pdb_headroom against a real PodDisruptionBudget ==="
kubectl -n "$NS" create deployment pause --image=registry.k8s.io/pause:3.9 --replicas=2 >/dev/null 2>&1
kubectl -n "$NS" rollout status deployment/pause --timeout=120s >/dev/null 2>&1
# Wait for a SCHEDULED pod, and assert it. An empty node name makes
# `--field-selector spec.nodeName=` an error, which the gate now correctly reads
# as blocking — so racing the rollout here failed the gate for the wrong reason.
for _ in $(seq 1 30); do
  NODE="$(kubectl -n "$NS" get pods -l app=pause -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
  [ -n "$NODE" ] && break
  sleep 2
done
[ -n "$NODE" ] || { echo "✗ no pause pod was scheduled — cannot test the gate" >&2; exit 1; }

# A budget that is satisfiable: 2 healthy, 1 required.
kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: pause-ok, namespace: $NS}
spec: {minAvailable: 1, selector: {matchLabels: {app: pause}}}
EOF
# Establish the precondition rather than sleep and hope: a PDB's status is
# computed asynchronously, and a budget that has not been evaluated yet reads
# currentHealthy 0 of 2 — which is exactly the "short" shape the gate waits on.
for _ in $(seq 1 30); do
  [ "$(kubectl -n "$NS" get pdb pause-ok -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)" = "1" ] && break
  sleep 2
done
PDB_TIMEOUT=20
# stdin closed: on timeout the gate falls back to an interactive prompt, and
  # `read -rp` on a non-terminal stdin blocks for ever. Unattended is the mode
  # under test, and this harness hung ten minutes learning that.
  if wait_pdb_headroom "$NODE" >/dev/null 2>&1 </dev/null; then
  pass "a satisfiable budget lets the gate through"
else
  bad "the gate blocked on a budget that allows a disruption"
fi

# A budget that can never allow one AND is short a pod: 3 required, 2 healthy.
# This is the shape the gate must WAIT on (currentHealthy < expectedPods).
#
# The third pod is one that can NEVER be scheduled, not a third replica: scaling
# the deployment made the shape a race that failed both ways — read too early the
# budget still says 2 of 2, read too late all three are healthy and not short.
# And pause-ok goes first, because while two budgets select the same pods a pod
# event re-syncs exactly ONE of them ("matches multiple PodDisruptionBudgets.
# Chose arbitrarily") and the loser keeps a stale expectedPods for ever.
kubectl -n "$NS" delete pdb pause-ok >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata: {name: pause-ghost, namespace: $NS, labels: {app: pause}}
spec:
  nodeSelector: {openaether.io/no-such-node: "true"}
  containers: [{name: pause, image: registry.k8s.io/pause:3.9}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: pause-stuck, namespace: $NS}
spec: {minAvailable: 3, selector: {matchLabels: {app: pause}}}
EOF
for _ in $(seq 1 30); do
  ALLOWED="$(kubectl -n "$NS" get pdb pause-stuck -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)"
  HEALTHY="$(kubectl -n "$NS" get pdb pause-stuck -o jsonpath='{.status.currentHealthy}' 2>/dev/null)"
  EXPECTED="$(kubectl -n "$NS" get pdb pause-stuck -o jsonpath='{.status.expectedPods}' 2>/dev/null)"
  [ "${ALLOWED:-1}" = "0" ] && [ "${HEALTHY:-0}" -lt "${EXPECTED:-0}" ] && break
  sleep 2
done
if [ "${ALLOWED:-1}" = "0" ]; then
  ASSUME_YES=1
  PDB_TIMEOUT=20
  # stdin closed: on timeout the gate falls back to an interactive prompt, and
  # `read -rp` on a non-terminal stdin blocks for ever. Unattended is the mode
  # under test, and this harness hung ten minutes learning that.
  if wait_pdb_headroom "$NODE" >/dev/null 2>&1 </dev/null; then
    bad "the gate passed a budget at disruptionsAllowed=0 (healthy=$HEALTHY expected=$EXPECTED)"
  else
    pass "a blocking budget stops the gate (healthy=$HEALTHY expected=$EXPECTED)"
  fi
else
  bad "could not build a blocking budget — got disruptionsAllowed=$ALLOWED, test inconclusive"
fi

echo
echo "=== cnpg_installed agrees with the apiserver, whichever answer that is ==="
# Both branches are real states of this cluster: test-cnpg-gates-local.sh leaves
# the operator installed. Asserting only "absent" turned that into a failure and
# said nothing about the branch the roll actually takes on a cluster with databases.
if kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  cnpg_installed \
    && pass "the CNPG CRD is there and cnpg_installed says so" \
    || bad "the CNPG CRD is there and cnpg_installed denies it — the roll would drain past every database gate"
else
  cnpg_installed \
    && bad "claims CNPG is installed on a cluster that has no such CRD" \
    || pass "no CNPG CRD → not installed (so the roll skips its gates instead of dying)"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
