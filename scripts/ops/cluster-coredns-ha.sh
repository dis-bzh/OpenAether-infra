#!/usr/bin/env bash
# ==============================================================================
# cluster-coredns-ha.sh makes the CoreDNS Deployment of a LIVE cluster the shape the config declares: min(3, nodes) replicas and a
# hard spread over nodes (lab 26 K2, lab 27 FB; docs/upgrade.md "From 0.3.x to 0.4.0"). It does the same, in the same step, for the
# CILIUM OPERATOR (0.4.0 critical-path audit): the Cilium manifest is an inline manifest too, so a cluster built by an older release
# keeps its ONE operator replica; the declared shape is min(2, nodes) replicas (scripts/ops/cilium-operator-ha-patch.json). The name
# stays "coredns" because `cluster-up` and the docs call it by that name; both are the objects Talos never rewrites.
#
# WHY IT EXISTS. The 0.4.0 CoreDNS HA is a Talos inline manifest. Talos creates an inline manifest's objects only when they are
# absent, so a cluster built by an older release keeps its 2-replica Deployment without spread. `cluster-verify` compares the
# Deployment with the declaration and FAILS on the difference; the one-time patch used to be documented AFTER `cluster-up`, so the
# verify inside `cluster-up` could never pass on an upgraded cluster (lab 27, FB: rc 201 on the CoreDNS line). `cluster-up` now runs
# this step before its verify.
#
# WHAT IT DOES. Dry run (default): reads the Deployment kube-system/coredns and the node count, prints replicas and spread against
# the declaration, writes nothing. --apply: merge-patches the Deployment with scripts/ops/coredns-ha-patch.json (replicas and
# minDomains lowered to the node count when there are fewer than 3 nodes: the file is the 3-node shape), then waits for the rollout
# and reads the Deployment back. Idempotent: in sync, it does nothing. A rolling restart of the DNS pods happens only when the spec
# differs (maxUnavailable of the Deployment and the budget keep two answering; lab 27: 6 s, 0 failed lookups at 1 Hz).
#
# CoreDNS is skipped when coredns_ha = false or the Deployment is absent; the operator is skipped on its own absence (Cilium is
# there on every provider but a cluster whose CNI was replaced by hand). Neither skip hides the other.
#
# Usage: cluster-coredns-ha.sh [--tfvars FILE] [--apply]
#   exit 0  nothing to do: coredns_ha = false, no Deployment of the Talos manifest, or the shape already matches (or was made to)
#   exit 3  dry run found a difference (nothing written)
#   exit 1  any other failure (no kubeconfig, API unreachable, patch refused, rollout or read-back failed)
# Env: OA_COREDNS_TIMEOUT (300 s). KUBECONFIG is the cluster directory's, never the caller's.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
PATCH_FILE="${OA_COREDNS_PATCH_FILE:-$ROOT/scripts/ops/coredns-ha-patch.json}"
OP_PATCH_FILE="${OA_CILIUM_OPERATOR_PATCH_FILE:-$ROOT/scripts/ops/cilium-operator-ha-patch.json}"
TIMEOUT="${OA_COREDNS_TIMEOUT:-300}"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

APPLY=0; TFVARS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --tfvars) shift; TFVARS="${1:-}" ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $1 (usage: cluster-coredns-ha.sh [--tfvars FILE] [--apply])" >&2; exit 1 ;;
  esac
  shift
done
fail() { echo "✗ $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
case "$TIMEOUT" in *[!0-9]*|"") fail "OA_COREDNS_TIMEOUT must be whole seconds" ;; esac
[ -s "$PATCH_FILE" ] || fail "the patch file $PATCH_FILE is missing"
[ -s "$OP_PATCH_FILE" ] || fail "the patch file $OP_PATCH_FILE is missing"

COREDNS_ON=1
if [ -n "$TFVARS" ]; then
  tf="$TFVARS"; [ -f "$tf" ] || tf="$CLUSTER_DIR/$TFVARS"
  ha="${TF_VAR_coredns_ha:-}"; [ -n "$ha" ] || { [ -f "$tf" ] && ha="$(tfv "$tf" coredns_ha)"; }
  if [ "$ha" = false ]; then echo "~ coredns_ha = false: Talos owns the CoreDNS Deployment, nothing to converge for it."; COREDNS_ON=0; fi
fi
export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
[ -s "$KUBECONFIG" ] || fail "no kubeconfig at infrastructure/opentofu/cluster/kubeconfig (task kubeconfig PROVIDER=… ROLE=…)"

ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
nodes="$(kubectl get nodes --no-headers 2>"$ERR" | wc -l)" || true
[[ "$nodes" =~ ^[0-9]+$ ]] && [ "$nodes" -ge 1 ] || fail "cannot count the nodes: $(head -c 300 "$ERR")"
want=$(( nodes < 3 ? nodes : 3 ))
op_want=$(( nodes < 2 ? nodes : 2 ))

# --- CoreDNS ---------------------------------------------------------------------------------------------------------------------
read_dep() {
  if ! DEP="$(kubectl -n kube-system get deployment coredns -o json 2>"$ERR")"; then
    if grep -qi "notfound\|not found" "$ERR"; then echo "~ no kube-system/coredns Deployment: nothing to converge for CoreDNS."; return 1; fi
    fail "cannot read kube-system/coredns: $(head -c 300 "$ERR")"
  fi
  have="$(jq -r '.spec.replicas // empty' <<<"$DEP")"
  hard="$(jq -r '[.spec.template.spec.topologySpreadConstraints[]? | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule")] | length' <<<"$DEP")"
  [[ "$have" =~ ^[0-9]+$ ]] && [[ "$hard" =~ ^[0-9]+$ ]] || fail "cannot read the replica count or the spread of kube-system/coredns"
}
in_sync() { [ "$have" -eq "$want" ] && [ "$hard" -gt 0 ]; }

DIFF=0
converge_coredns() {
  read_dep || return 0
  echo "CoreDNS (kube-system/coredns): $have replica(s), $hard hard hostname spread constraint(s); declared: $want replica(s) (min(3, $nodes node(s))) with a hard spread over nodes."
  if in_sync; then echo "✓ CoreDNS already is the declared shape: nothing to do."; return 0; fi
  if [ "$APPLY" -ne 1 ]; then
    echo "✗ CoreDNS differs from the declaration. NOTHING was written (dry run)." >&2
    echo "  Converge it (a rolling restart of the DNS pods): task cluster-coredns-ha PROVIDER=… ROLE=… APPLY=1" >&2
    DIFF=1; return 0
  fi
  patch="$(jq -c --argjson n "$want" '.spec.replicas = $n | (.spec.template.spec.topologySpreadConstraints[] | select(.minDomains != null)).minDomains = $n' "$PATCH_FILE")" \
    || fail "the patch file is not what this script can adjust"
  kubectl -n kube-system patch deployment coredns --type merge -p "$patch" >/dev/null 2>"$ERR" || fail "patch of kube-system/coredns refused: $(head -c 300 "$ERR")"
  echo "▶ kube-system/coredns patched (replicas $want, hard spread over nodes, zone preference, 30 s tolerations)."
  kubectl -n kube-system rollout status deployment coredns --timeout="${TIMEOUT}s" >/dev/null 2>"$ERR" \
    || fail "the CoreDNS rollout did not finish within ${TIMEOUT} s: $(head -c 300 "$ERR")"
  read_dep || fail "kube-system/coredns disappeared during the patch"
  in_sync || fail "after the patch CoreDNS has $have replica(s) and $hard hard spread constraint(s); declared $want"
  echo "✓ CoreDNS converged: $have replica(s), hard spread over nodes."
}

# --- Cilium operator (0.4.0 critical-path audit) --------------------------------------------------------------------------------------
converge_operator() {
  local odep ohave
  if ! odep="$(kubectl -n kube-system get deployment cilium-operator -o json 2>"$ERR")"; then
    if grep -qi "notfound\|not found" "$ERR"; then echo "~ no kube-system/cilium-operator Deployment: nothing to converge for Cilium."; return 0; fi
    fail "cannot read kube-system/cilium-operator: $(head -c 300 "$ERR")"
  fi
  ohave="$(jq -r '.spec.replicas // empty' <<<"$odep")"
  [[ "$ohave" =~ ^[0-9]+$ ]] || fail "cannot read the replica count of kube-system/cilium-operator"
  echo "Cilium operator (kube-system/cilium-operator): $ohave replica(s); declared: $op_want replica(s) (min(2, $nodes node(s)))."
  if [ "$ohave" -eq "$op_want" ]; then echo "✓ The Cilium operator already is the declared shape: nothing to do."; return 0; fi
  if [ "$APPLY" -ne 1 ]; then
    echo "✗ The Cilium operator differs from the declaration. NOTHING was written (dry run)." >&2
    echo "  Converge it (the operator pods restart one at a time): task cluster-coredns-ha PROVIDER=… ROLE=… APPLY=1" >&2
    DIFF=1; return 0
  fi
  patch="$(jq -c --argjson n "$op_want" '.spec.replicas = $n' "$OP_PATCH_FILE")" || fail "the operator patch file is not what this script can adjust"
  kubectl -n kube-system patch deployment cilium-operator --type merge -p "$patch" >/dev/null 2>"$ERR" || fail "patch of kube-system/cilium-operator refused: $(head -c 300 "$ERR")"
  echo "▶ kube-system/cilium-operator patched (replicas $op_want, zone preference)."
  kubectl -n kube-system rollout status deployment cilium-operator --timeout="${TIMEOUT}s" >/dev/null 2>"$ERR" \
    || fail "the Cilium operator rollout did not finish within ${TIMEOUT} s: $(head -c 300 "$ERR")"
  ohave="$(kubectl -n kube-system get deployment cilium-operator -o jsonpath='{.spec.replicas}' 2>"$ERR")" || fail "cannot read back kube-system/cilium-operator"
  [ "$ohave" = "$op_want" ] || fail "after the patch the Cilium operator has ${ohave:-?} replica(s); declared $op_want"
  echo "✓ The Cilium operator converged: $ohave replica(s)."
}

[ "$COREDNS_ON" -eq 1 ] && converge_coredns
converge_operator
[ "$DIFF" -eq 0 ] || exit 3
exit 0
