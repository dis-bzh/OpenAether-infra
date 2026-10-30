#!/usr/bin/env bash
# ==============================================================================
# cluster-identity-sync.sh makes the `cluster-identity` ConfigMap of a LIVE cluster match what OpenTofu renders (lab 25, D9).
#
# WHY IT EXISTS. The ConfigMap is part of the Talos inline manifest `flux-bootstrap`. Talos creates the objects of an inline
# manifest when they are missing and never updates one that exists (upstream manifest_apply controller: a Get first, the
# apply only on NotFound; docs/upgrade.md "From 0.3.x to 0.4.0"). So a key added by a newer release (BACKUP_REPLICA_S3_*,
# AUDIT_SINK_*) reaches a NEW cluster only; on a cluster built by an older release `tofu apply` re-sends the machine config,
# the plan reads "N to change", and the ConfigMap stays as it was. The apps content reads those keys through Flux
# postBuild.substituteFrom.
#
# WHAT IT DOES. Reads `tofu output -json cluster_identity` (the SAME map the bootstrap template renders; host and bucket
# names, nothing secret), reads the live ConfigMap, prints the difference, and with --apply writes ONLY the keys of the
# map to `data` (a merge patch: a key the map does not know is left alone and reported), then asks Flux to reconcile the
# Kustomizations. Nothing else in the cluster is touched. Idempotent: a second --apply changes nothing.
#
# Usage: cluster-identity-sync.sh [--apply] [--no-reconcile]
#   exit 0  in sync (or applied), or Flux is off (empty output)
#   exit 3  dry run found a difference (nothing written)
#   exit 4  the ConfigMap does not exist (a cluster whose Flux bootstrap has not run)
#   exit 1  any other failure (no state, no kubeconfig, API unreachable, patch refused, not in sync after the patch)
# Env: OA_FLUX_NAMESPACE (default flux-system). KUBECONFIG is the cluster directory's, never the caller's.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
NS="${OA_FLUX_NAMESPACE:-flux-system}"
CM=cluster-identity

APPLY=0; RECONCILE=1
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --no-reconcile) RECONCILE=0 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $a (usage: cluster-identity-sync.sh [--apply] [--no-reconcile])" >&2; exit 1 ;;
  esac
done

fail() { echo "✗ $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"

export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
[ -s "$KUBECONFIG" ] || fail "no kubeconfig at infrastructure/opentofu/cluster/kubeconfig (task kubeconfig PROVIDER=… ROLE=…)"

# 1. What OpenTofu renders. A failing `tofu output` must not read as "empty".
DESIRED="$(cd "$CLUSTER_DIR" && tofu output -json cluster_identity)" \
  || fail "tofu output cluster_identity failed (no state or no backend; task cluster-identity-sync inits it first)"
printf '%s' "$DESIRED" | jq -e 'type == "object" and all(.[]; type == "string")' >/dev/null 2>&1 \
  || fail "tofu output cluster_identity is not a map of strings (a release older than 0.4.0 has no such output)"
if [ "$(printf '%s' "$DESIRED" | jq 'length')" -eq 0 ]; then
  echo "~ cluster_identity is empty (deploy_flux = false): there is no ConfigMap to keep. Nothing to do."
  exit 0
fi

# 2. What the cluster holds. NotFound is its own answer; any other failure is not.
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
if ! LIVE="$(kubectl -n "$NS" get configmap "$CM" -o json 2>"$ERR")"; then
  if grep -qi "notfound\|not found" "$ERR"; then
    echo "✗ ConfigMap $NS/$CM does not exist: the Flux bootstrap manifest has not been applied on this cluster yet." >&2
    exit 4
  fi
  echo "✗ cannot read $NS/$CM: $(head -c 300 "$ERR")" >&2
  exit 1
fi

# 3. The difference, per key. Values are host and bucket names by construction (cluster/main.tf, local.cluster_identity).
DIFF="$(jq -nr --argjson want "$DESIRED" --argjson live "$LIVE" '
  ($live.data // {}) as $have
  | ($want | to_entries | sort_by(.key)[] | . as $e
      | if ($have | has($e.key) | not) then "  + \($e.key) = \($e.value)   (missing on the cluster)"
        elif $have[$e.key] != $e.value then "  ~ \($e.key): \($have[$e.key]) -> \($e.value)"
        else empty end),
    ($have | to_entries | sort_by(.key)[] | . as $e | select($want | has($e.key) | not)
      | "  = \($e.key) is not in the rendered map; left as it is")')"
CHANGES="$(printf '%s\n' "$DIFF" | grep -c '^  [+~] ' || true)"

echo "ConfigMap $NS/$CM against the rendered cluster_identity:"
if [ -n "$DIFF" ]; then printf '%s\n' "$DIFF"; fi

if [ "$CHANGES" -eq 0 ]; then
  echo "✓ in sync: every rendered key is on the cluster with the same value."
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  echo "✗ $CHANGES key(s) differ. NOTHING was written (dry run). Until they match, the apps that read them stay NotReady." >&2
  echo "  Write them: task cluster-identity-sync PROVIDER=… ROLE=… APPLY=1" >&2
  exit 3
fi

# 4. Write ONLY the rendered keys. A merge patch on `data` leaves every other key and field alone.
PATCH="$(printf '%s' "$DESIRED" | jq -c '{data: .}')"
kubectl -n "$NS" patch configmap "$CM" --type merge -p "$PATCH" >/dev/null 2>"$ERR" \
  || fail "patch refused: $(head -c 300 "$ERR")"

# 5. Read it back: "applied" means the cluster holds the values, not that the call returned.
LIVE="$(kubectl -n "$NS" get configmap "$CM" -o json)" || fail "cannot read $NS/$CM back after the patch"
if ! printf '%s' "$LIVE" | jq -e --argjson want "$DESIRED" '(.data // {}) as $h | all($want | to_entries[]; $h[.key] == .value)' >/dev/null; then
  fail "the ConfigMap still differs after the patch (something else rewrites it?)"
fi
echo "✓ $CHANGES key(s) written to $NS/$CM and read back."

# 6. substituteFrom is read at reconcile time, not watched: ask for a reconcile now rather than at the next interval.
if [ "$RECONCILE" -eq 1 ]; then
  if kubectl -n "$NS" annotate kustomizations.kustomize.toolkit.fluxcd.io --all --overwrite \
       "reconcile.fluxcd.io/requestedAt=$(date +%s)" >/dev/null 2>"$ERR"; then
    echo "✓ Flux asked to reconcile the Kustomizations of $NS. Watch: kubectl get kustomizations -A"
  else
    echo "⚠ the values are written but the reconcile request failed ($(head -c 200 "$ERR")); Flux picks them up at the next interval." >&2
  fi
fi
