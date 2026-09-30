#!/usr/bin/env bash
# OpenAether — CLEAN decommission of a CAPI child cluster (idempotent)
#
# Letting Flux `prune` the file is NOT enough: it deletes everything at once and
# CAPI needs the `Cluster` to go first. If the <Infra>Cluster is pruned before
# the machines, the provider loses the cloud client that destroys them and loops
# on "<Infra>Cluster is not available yet" — orphaned VMs, BILLED (hit twice).
#
# So, in order: suspend the Flux Kustomizations that manage the `Cluster` (they
# would recreate it before the cascade starts), delete the `Cluster`, wait, and
# as a last resort lift the finalizers and REPORT the VMs to check by hand.
# Only then remove the file from apps/clusters/kustomization.yaml.
#
# Usage:
#   edge-down.sh <cluster> [--namespace capi-clusters] [--timeout 900] [--yes]
#   KUBECONFIG must point at the MANAGEMENT cluster.
set -uo pipefail

CLUSTER="${1:?usage: edge-down.sh <cluster> [--namespace ns] [--timeout s] [--yes]}"
shift
NS=capi-clusters
TIMEOUT=900
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --yes | -y)  ASSUME_YES=1; shift ;;
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# ⚠️ Always qualify `clusters.cluster.x-k8s.io`: the `Cluster` kind is also
# CNPG's (postgresql.cnpg.io). Without the CAPI CRDs installed, an unqualified
# `kubectl delete cluster <name>` would target a DATABASE.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl required" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "✗ KUBECONFIG points at no reachable cluster" >&2; exit 1; }

# NotFound is "already absent"; anything else is "we do not know", and the two
# must not share an exit code — fleet-down reads a 0 here as a successful edge
# teardown and moves on to destroying the management.
if ! CLUSTER_ERR="$(kubectl get clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" 2>&1 >/dev/null)"; then
  case "$CLUSTER_ERR" in
    *NotFound* | *"not found"*)
      ok "cluster '$CLUSTER' already absent (nothing to do)"
      exit 0
      ;;
    *)
      echo "✗ cannot tell whether '$CLUSTER' exists: ${CLUSTER_ERR}" >&2
      echo "  Refusing to report a teardown that was never verified." >&2
      exit 1
      ;;
  esac
fi

# Inventory before deletion — used for the final report.
mapfile -t MACHINES < <(kubectl get machines -n "$NS" \
  -l "cluster.x-k8s.io/cluster-name=$CLUSTER" -o name 2>/dev/null)
info "Cluster '$CLUSTER' (ns $NS): ${#MACHINES[@]} machine(s) to destroy"

# Which infra provider this cluster is on — needed AFTER deletion (step 4) to
# know which API to re-check, so it must be captured now, before the objects
# that reveal it disappear.
PROVIDER=""
for kp in "openstackcluster:openstack" "osccluster:outscale" "scalewaycluster:scaleway"; do
  kind="${kp%%:*}"; prov="${kp##*:}"
  if kubectl get "$kind" -n "$NS" -o name 2>/dev/null | grep -q -- "$CLUSTER"; then
    PROVIDER="$prov"
    break
  fi
done

if [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Permanently destroy '$CLUSTER' and its VMs? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || { echo "aborted"; exit 1; }
fi

# 1. SUSPEND Flux first — otherwise the deletion is undone in a loop.
#
# ⚠️ Trap hit on 2026-07-27: the `<cluster>-cluster` Kustomization reapplies
# the `Cluster` object every 10 min. Once deleted, it was RECREATED before the
# CAPI cascade had started — the Machines never got a deletionTimestamp and
# this script looped to the timeout without reporting anything.
# So we suspend both the Kustomization that manages it AND the parent one
# (`capi-clusters`), which would recreate the former.
for k in "${CLUSTER}-cluster" capi-clusters; do
  if kubectl get kustomization -n flux-system "$k" >/dev/null 2>&1; then
    kubectl patch kustomization -n flux-system "$k" --type=merge \
      -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 && info "Flux suspended: $k"
  fi
done

# 2. Delete the Cluster → CAPI cascades (non-blocking: we follow it ourselves).
#    The error is NOT swallowed: a rejected delete (unreachable webhook, RBAC…)
#    must show immediately, not after 15 min of silent waiting.
info "kubectl delete cluster $CLUSTER (cascade CAPI)…"
if ! kubectl delete clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --wait=false; then
  echo "✗ the Cluster deletion was REFUSED (see the error above)." >&2
  exit 1
fi

# 3. Wait for everything to disappear.
info "Attente de la fin de la cascade (timeout ${TIMEOUT}s)…"
deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
  left=$(kubectl get clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --no-headers 2>/dev/null | wc -l)
  mach=$(kubectl get machines -n "$NS" -l "cluster.x-k8s.io/cluster-name=$CLUSTER" \
           --no-headers 2>/dev/null | wc -l)
  if [ "$left" = 0 ] && [ "$mach" = 0 ]; then
    ok "cluster '$CLUSTER' Kubernetes objects gone"

    # 4. The Kubernetes-level signal above is NOT proof the provider finished:
    # CAPO/CAPOSC's own network cleanup can lag past the object's own deletion
    # (found live 2026-07-30 — OVH network/router/SGs and a billed Outscale EIP
    # both survived a "fully deleted" report). Re-check the provider directly;
    # retry a few times before failing, since this is a real async cascade, not
    # necessarily a stuck one.
    VERIFY="$ROOT/scripts/ops/verify-provider-clean.py"
    if [ -n "$PROVIDER" ] && [ -f "$VERIFY" ]; then
      info "Vérification côté provider ($PROVIDER)…"
      for attempt in 1 2 3 4; do
        OUT="$(python3 "$VERIFY" "$CLUSTER" "$PROVIDER" 2>&1)"; rc=$?
        case $rc in
          0) ok "cluster '$CLUSTER' fully deleted (provider verified clean)"; exit 0 ;;
          2) warn "provider verification skipped: $OUT"
             ok "cluster '$CLUSTER' Kubernetes objects gone (provider NOT re-checked)"
             exit 0 ;;
        esac
        warn "attempt $attempt/4: $PROVIDER still has resources for '$CLUSTER', retrying in 20s…"
        sleep 20
      done
      printf '%s\n' "$OUT" >&2
      # Only OpenStack has a scoped deleter; Scaleway's check also lists project-wide
      # detached IPs and volumes, which no tag ties to $CLUSTER.
      DELETE_ONE="python3 scripts/ops/delete-openstack-resource.py <kind> <id>"
      DETACHED=""
      if [ "$PROVIDER" != openstack ]; then
        DELETE_ONE="delete each one in the $PROVIDER console or CLI"
        [ "$PROVIDER" = scaleway ] && DETACHED=", or left detached in the project"
      fi
      cat >&2 <<EOT

✗ the Kubernetes-level cascade finished but $PROVIDER still has resources
  named or tagged '$CLUSTER'$DETACHED (listed above) after 4 checks
  (~80s) — CAPO/CAPOSC's own cleanup did not finish. Purge by hand, ONE
  resource at a time (a leftover Octavia LB alone breaks the NEXT redeploy —
  found live 2026-07-31):
    $DELETE_ONE
  scripts/ops/purge-orphans/ also works but is WHOLE-ACCOUNT (no name
  filtering) — never run it while another cluster is live on the same
  provider. Then re-run: this script is idempotent and will report clean
  once they are gone.
EOT
      exit 1
    fi
    # Falling through means the provider was never re-checked — either the
    # kind→provider probe above matched nothing, or verify-provider-clean.py is
    # missing. Both are the state the comment at the top of this block calls NOT
    # proof, and claiming "fully deleted" here is the sentence that let an OVH
    # network and a billed Outscale EIP survive on 2026-07-30.
    if [ -z "$PROVIDER" ]; then
      echo "✗ could not tell which provider '$CLUSTER' ran on, so nothing verified" >&2
      echo "  its provider side. Kubernetes objects are gone; resources may not be." >&2
      echo "  Check by hand: scripts/ops/verify-provider-clean.py $CLUSTER <provider>" >&2
      exit 1
    fi
    warn "cluster '$CLUSTER': Kubernetes objects gone, provider NOT re-checked ($VERIFY missing)"
    exit 0
  fi
  printf '  … cluster=%s machines=%s\n' "$left" "$mach"
  sleep 15
done

# 4. Safety net — the provider is stuck (known bug: see the GitHub issues).
warn "timeout after ${TIMEOUT}s — the provider did not finish the cascade."
warn "Lifting finalizers on the remaining infra objects (the VMs may survive!):"
for kind in scalewaymachine oscmachine openstackmachine scalewaycluster osccluster openstackcluster; do
  for obj in $(kubectl get "$kind" -n "$NS" -o name 2>/dev/null | grep -- "$CLUSTER" || true); do
    kubectl patch "$obj" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
      && warn "  finalizers lifted: $obj"
  done
done
for obj in $(kubectl get machines -n "$NS" -o name 2>/dev/null | grep -- "$CLUSTER" || true); do
  kubectl patch "$obj" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
done
kubectl patch clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1

cat >&2 <<EOT

⚠ MANUAL ACTION REQUIRED — check that no VM survives on the provider side:
    Scaleway: scw instance server list  (or console)  → look for '${CLUSTER}-'
    OVH:      openstack server list                   → look for '${CLUSTER}-'
    Outscale: ReadVms (API)                           → look for tag ${CLUSTER}
  The Kubernetes objects were forced, but the matching cloud resources are
  NOT guaranteed to be destroyed.
EOT
exit 1
