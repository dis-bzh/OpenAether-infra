#!/usr/bin/env bash
# ==============================================================================
# cluster-coredns-ha.sh makes the CoreDNS Deployment of a LIVE cluster the shape the config declares: min(3, nodes) replicas and a
# hard spread over nodes (lab 26 K2, lab 27 FB; docs/upgrade.md "From 0.3.x to 0.4.0").
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
TIMEOUT="${OA_COREDNS_TIMEOUT:-300}"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

APPLY=0; TFVARS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --tfvars) shift; TFVARS="${1:-}" ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $1 (usage: cluster-coredns-ha.sh [--tfvars FILE] [--apply])" >&2; exit 1 ;;
  esac
  shift
done
fail() { echo "✗ $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
case "$TIMEOUT" in *[!0-9]*|"") fail "OA_COREDNS_TIMEOUT must be whole seconds" ;; esac
[ -s "$PATCH_FILE" ] || fail "the patch file $PATCH_FILE is missing"

if [ -n "$TFVARS" ]; then
  tf="$TFVARS"; [ -f "$tf" ] || tf="$CLUSTER_DIR/$TFVARS"
  ha="${TF_VAR_coredns_ha:-}"; [ -n "$ha" ] || { [ -f "$tf" ] && ha="$(tfv "$tf" coredns_ha)"; }
  if [ "$ha" = false ]; then echo "~ coredns_ha = false: Talos owns the CoreDNS Deployment, nothing to converge."; exit 0; fi
fi
export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
[ -s "$KUBECONFIG" ] || fail "no kubeconfig at infrastructure/opentofu/cluster/kubeconfig (task kubeconfig PROVIDER=… ROLE=…)"

ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
nodes="$(kubectl get nodes --no-headers 2>"$ERR" | wc -l)" || true
[[ "$nodes" =~ ^[0-9]+$ ]] && [ "$nodes" -ge 1 ] || fail "cannot count the nodes: $(head -c 300 "$ERR")"
want=$(( nodes < 3 ? nodes : 3 ))

read_dep() {
  if ! DEP="$(kubectl -n kube-system get deployment coredns -o json 2>"$ERR")"; then
    if grep -qi "notfound\|not found" "$ERR"; then echo "~ no kube-system/coredns Deployment: nothing to converge."; exit 0; fi
    fail "cannot read kube-system/coredns: $(head -c 300 "$ERR")"
  fi
  have="$(jq -r '.spec.replicas // empty' <<<"$DEP")"
  hard="$(jq -r '[.spec.template.spec.topologySpreadConstraints[]? | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule")] | length' <<<"$DEP")"
  [[ "$have" =~ ^[0-9]+$ ]] && [[ "$hard" =~ ^[0-9]+$ ]] || fail "cannot read the replica count or the spread of kube-system/coredns"
}
in_sync() { [ "$have" -eq "$want" ] && [ "$hard" -gt 0 ]; }

read_dep
echo "CoreDNS (kube-system/coredns): $have replica(s), $hard hard hostname spread constraint(s); declared: $want replica(s) (min(3, $nodes node(s))) with a hard spread over nodes."
if in_sync; then echo "✓ CoreDNS already is the declared shape: nothing to do."; exit 0; fi
if [ "$APPLY" -ne 1 ]; then
  echo "✗ CoreDNS differs from the declaration. NOTHING was written (dry run)." >&2
  echo "  Converge it (a rolling restart of the DNS pods): task cluster-coredns-ha PROVIDER=… ROLE=… APPLY=1" >&2
  exit 3
fi

patch="$(jq -c --argjson n "$want" '.spec.replicas = $n | (.spec.template.spec.topologySpreadConstraints[] | select(.minDomains != null)).minDomains = $n' "$PATCH_FILE")" \
  || fail "the patch file is not what this script can adjust"
kubectl -n kube-system patch deployment coredns --type merge -p "$patch" >/dev/null 2>"$ERR" || fail "patch of kube-system/coredns refused: $(head -c 300 "$ERR")"
echo "▶ kube-system/coredns patched (replicas $want, hard spread over nodes, zone preference, 30 s tolerations)."
kubectl -n kube-system rollout status deployment coredns --timeout="${TIMEOUT}s" >/dev/null 2>"$ERR" \
  || fail "the CoreDNS rollout did not finish within ${TIMEOUT} s: $(head -c 300 "$ERR")"
read_dep
in_sync || fail "after the patch CoreDNS has $have replica(s) and $hard hard spread constraint(s); declared $want"
echo "✓ CoreDNS converged: $have replica(s), hard spread over nodes."
exit 0
