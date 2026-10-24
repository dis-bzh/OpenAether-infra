#!/usr/bin/env bash
# ==============================================================================
# cluster-bootstrap-sync.sh compares the Cilium and Flux controllers a LIVE cluster runs with the pinned bootstrap artifacts,
# and moves the Flux controllers (never Cilium) when asked (infra #408).
#
# WHY IT EXISTS. cilium.yaml and flux-install.yaml are injected as Talos inline manifests. Talos creates an inline-manifest
# object when it is missing and does not update one that exists (docs/upgrade.md "From 0.3.x to 0.4.0"), so a bumped pin
# (render-bootstrap-manifests.sh) never reaches a running cluster by `cluster-up`. cluster-verify fails on the difference;
# this is the command that closes it, where it is safe.
#
# WHAT IT READS. The pins: the committed artifact (cilium.yaml, or cilium-hubble-drops.yaml when cilium_hubble_drop_log = true;
# flux-install.yaml when deploy_flux = true), whose sha256 must match upstream-artifacts.lock. The running versions: the image
# tag of each workload's SPEC (7 Flux controller Deployments; the cilium DaemonSet and cilium-operator), not of a pod.
#
# FLUX (--apply). Server-side apply of flux-install.yaml, the path the Flux upgrade guide gives for a kubectl install, with the
# field manager openaether-bootstrap and --force-conflicts (Talos or an earlier kubectl owned the fields). Refused before any
# write: a downgrade of any controller; a controller more than ONE minor ahead of the running one (step through the releases;
# stricter than upstream's "any v2.x to any v2.x" on purpose); a running controller the artifact no longer has (apply does not
# prune); a Talos or Kubernetes roll pending or in progress (a node not Ready, cordoned, or a version that differs from the
# pin or between nodes). Then a rollout wait per Deployment (timeout) and a re-read: "applied" means the cluster runs the pin.
#
# CILIUM (never applied here). The check and the dry run work; --apply on Cilium is REFUSED (exit 5). Reasons, in
# docs/upgrade.md: the DaemonSets roll with maxUnavailable 2 (the CNI of 2 nodes at once on a 3-node cluster), nothing here
# runs the pre-flight the Cilium guide requires, apply does not prune, and docs/admin-access.md already says never to change
# the Cilium values of a live cluster. The documented path is a rebuild aside.
#
# Usage: cluster-bootstrap-sync.sh --tfvars FILE [--component flux|cilium|all] [--apply]
#   exit 0  everything selected runs the pin (or Flux was moved and re-read)
#   exit 3  dry run: a difference (nothing written)
#   exit 4  nothing to compare: the Flux namespace is absent although deploy_flux = true (and Cilium not selected)
#   exit 5  Cilium differs and this script does not apply Cilium (the rebuild-aside path is documented)
#   exit 2  refused (downgrade, more than one minor, roll in progress, override manifest, bad argument)
#   exit 1  any other failure (lock mismatch, API unreachable, apply refused, rollout timed out, not at the pin after apply)
# Env: OA_FLUX_NAMESPACE (flux-system), OA_ROLLOUT_TIMEOUT (300 s per Deployment). KUBECONFIG is the cluster directory's.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
MANIFESTS="${OA_MANIFESTS_DIR:-$CLUSTER_DIR/bootstrap-manifests}"
NS="${OA_FLUX_NAMESPACE:-flux-system}"
RTO="${OA_ROLLOUT_TIMEOUT:-300}"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=../lib/pins.sh
source "$ROOT/scripts/lib/pins.sh"

APPLY=0; COMPONENT=all; TFVARS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --component) shift; COMPONENT="${1:-}" ;;
    --tfvars) shift; TFVARS="${1:-}" ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $1 (usage: cluster-bootstrap-sync.sh --tfvars FILE [--component flux|cilium|all] [--apply])" >&2; exit 1 ;;
  esac
  shift
done
fail()   { echo "✗ $*" >&2; exit 1; }
refuse() { echo "✗ $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
case "$COMPONENT" in flux|cilium|all) ;; *) fail "--component must be flux, cilium or all" ;; esac
[ -n "$TFVARS" ] || fail "--tfvars FILE is required"
case "$RTO" in *[!0-9]*|"") fail "OA_ROLLOUT_TIMEOUT must be whole seconds" ;; esac
export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
[ -s "$KUBECONFIG" ] || fail "no kubeconfig at infrastructure/opentofu/cluster/kubeconfig (task kubeconfig PROVIDER=… ROLE=…)"

cfg() { local n="TF_VAR_$1" v; v="${!n:-}"; [ -n "$v" ] || { [ -f "$TFVARS" ] && v="$(tfv "$TFVARS" "$1")"; }; printf '%s' "$v"; }
for k in cilium_manifest flux_manifest; do
  if [ -f "$TFVARS" ] && grep -qE "^[[:space:]]*$k[[:space:]]*=" "$TFVARS" && ! grep -qE "^[[:space:]]*$k[[:space:]]*=[[:space:]]*null" "$TFVARS"; then
    fail "$k is overridden in $TFVARS: the manifest the cluster was built with is not the committed one, so what it should run is UNKNOWN to this script."
  fi
done
WANT_FLUX=0; [ "$(cfg deploy_flux)" = true ] && WANT_FLUX=1
CILIUM_FILE=cilium.yaml; [ "$(cfg cilium_hubble_drop_log)" = true ] && CILIUM_FILE=cilium-hubble-drops.yaml
DO_FLUX=0; DO_CILIUM=0
case "$COMPONENT" in flux) DO_FLUX=1 ;; cilium) DO_CILIUM=1 ;; all) DO_FLUX=$WANT_FLUX; DO_CILIUM=1 ;; esac
if [ "$COMPONENT" = flux ] && [ "$WANT_FLUX" -eq 0 ]; then echo "~ deploy_flux is not true in the config: there is no Flux to compare."; exit 0; fi
if [ "$APPLY" -eq 1 ] && [ "$DO_CILIUM" -eq 1 ] && [ "$COMPONENT" = cilium ]; then
  refuse "Cilium is never applied by this script (docs/upgrade.md, 'Cilium and Flux on a running cluster'): the DaemonSets roll with maxUnavailable 2, the Cilium guide's pre-flight is not run here, and docs/admin-access.md says never to change the Cilium values of a live cluster. Rebuild aside instead."
fi

# --- the pins: committed artifacts, checked against the lock ------------------------------------------------------------
LOCK="$MANIFESTS/upstream-artifacts.lock"
[ -f "$LOCK" ] || fail "$LOCK is missing"
lock_ok() { # <file> — its line of the lock must match the file's sha256
  local want have
  want="$(awk -v f="$1" '$2 == f { print $1 }' "$LOCK")"
  [ -n "$want" ] || fail "$1 is not in upstream-artifacts.lock"
  have="$(sha256sum "$MANIFESTS/$1" | awk '{ print $1 }')"
  [ "$want" = "$have" ] || fail "$1 does not match upstream-artifacts.lock (sha256 differs): not applying or comparing against a file nobody recorded. See scripts/dev/check-upstream-artifacts-lock.sh."
}
FLUX_PINS=""; CILIUM_PINS=""
if [ "$DO_FLUX" -eq 1 ]; then lock_ok flux-install.yaml; FLUX_PINS="$(oa_artifact_pins flux "$MANIFESTS/flux-install.yaml")"; [ -n "$FLUX_PINS" ] || fail "no controller image found in flux-install.yaml"; fi
if [ "$DO_CILIUM" -eq 1 ]; then lock_ok "$CILIUM_FILE"; CILIUM_PINS="$(oa_artifact_pins cilium "$MANIFESTS/$CILIUM_FILE")"; [ -n "$CILIUM_PINS" ] || fail "no cilium image found in $CILIUM_FILE"; fi

# --- what runs ----------------------------------------------------------------------------------------------------------
FLUX_LIVE=""; CILIUM_LIVE=""
if [ "$DO_FLUX" -eq 1 ]; then
  kubectl get namespace "$NS" >/dev/null 2>&1 || { echo "✗ namespace $NS does not exist although deploy_flux = true: nothing to compare." >&2; [ "$DO_CILIUM" -eq 1 ] || exit 4; DO_FLUX=0; }
fi
if [ "$DO_FLUX" -eq 1 ]; then FLUX_LIVE="$(oa_live_pins flux "$NS")" || fail "cannot read the Deployments of $NS"; fi
if [ "$DO_CILIUM" -eq 1 ]; then CILIUM_LIVE="$(oa_live_pins cilium)" || fail "cannot read the Cilium workloads of kube-system"; [ -n "$CILIUM_LIVE" ] || fail "no cilium DaemonSet in kube-system: the CNI cannot be compared"; fi
if [ "$DO_FLUX" -eq 1 ] && [ -z "$FLUX_LIVE" ]; then fail "no Flux controller Deployment in $NS: cannot compare"; fi

FLUX_DIFF=""; CILIUM_DIFF=""
[ "$DO_FLUX" -eq 1 ] && FLUX_DIFF="$(oa_pin_diff "$FLUX_PINS" "$FLUX_LIVE")"
[ "$DO_CILIUM" -eq 1 ] && CILIUM_DIFF="$(oa_pin_diff "$CILIUM_PINS" "$CILIUM_LIVE")"

show() { # <label> <pins> <live> <diff>
  echo "$1 (pinned in the artifact / running):"
  while read -r _ n want; do
    have="$(awk -v n="$n" '$2 == n { print $3 }' <<<"$3")"
    mark="="; [ "$have" = "$want" ] || mark="~"
    printf '  %s %-28s pinned %-10s running %s\n' "$mark" "$n" "$want" "${have:-(not running)}"
  done <<<"$2"
  while read -r _ n have; do
    grep -q " $n " <<<"$2" || printf '  ~ %-28s pinned (none)   running %s\n' "$n" "$have"
  done <<<"$3"
}
[ "$DO_FLUX" -eq 1 ] && show "Flux controllers" "$FLUX_PINS" "$FLUX_LIVE" "$FLUX_DIFF"
[ "$DO_CILIUM" -eq 1 ] && show "Cilium ($CILIUM_FILE)" "$CILIUM_PINS" "$CILIUM_LIVE" "$CILIUM_DIFF"

if [ -z "$FLUX_DIFF$CILIUM_DIFF" ]; then
  echo "✓ the selected components run exactly the pinned versions."
  exit 0
fi

# --- semver gates, shared by the dry run (so it tells the truth about what --apply would do) and --apply -----------------
minor_of() { local v="${1#v}"; IFS=. read -r a b _ <<<"$v"; echo "${a:-0}.${b:-0}"; }
gate_flux() { # prints the reasons a Flux apply is refused, nothing when it is allowed
  local n want have wm hm
  while read -r _ n want; do
    have="$(awk -v n="$n" '$2 == n { print $3 }' <<<"$FLUX_LIVE")"
    [ -n "$have" ] && [ "$have" != "$want" ] || continue
    if oa_semver_lt "$want" "$have"; then echo "$n runs $have, the pin is $want: a DOWNGRADE (never done here; revert the pin or rebuild aside)"; continue; fi
    wm="$(minor_of "$want")"; hm="$(minor_of "$have")"
    if [ "${wm%%.*}" != "${hm%%.*}" ] || [ $(( ${wm##*.} - ${hm##*.} )) -gt 1 ]; then
      echo "$n runs $have and the pin is $want: more than ONE minor ahead (step through the intermediate releases: render and apply each in turn)"
    fi
  done <<<"$FLUX_PINS"
  while read -r _ n have; do
    grep -q " $n " <<<"$FLUX_PINS" || echo "$n runs $have and the artifact no longer contains it: server-side apply does not prune it"
  done <<<"$FLUX_LIVE"
}
gate_roll() { # prints why a Talos or Kubernetes roll may be under way, nothing when the fleet is quiet and at its pins
  local nodes bad tv kv wt wk
  nodes="$(timeout 60 kubectl get nodes -o json 2>/dev/null)" || { echo "the nodes cannot be read: whether a roll is under way is UNKNOWN"; return; }
  bad="$(jq -r '[.items[] | select(((.status.conditions[]? | select(.type == "Ready") | .status) != "True") or (.spec.unschedulable == true)) | .metadata.name] | join(" ")' <<<"$nodes")"
  [ -z "$bad" ] || echo "node(s) not Ready or cordoned (a drain or a roll is under way): $bad"
  tv="$(oa_fleet_versions '.status.nodeInfo.osImage')"; kv="$(oa_fleet_versions '.status.nodeInfo.kubeletVersion')"
  case "$tv$kv" in *,*) echo "the nodes disagree on Talos ($tv) or Kubernetes ($kv): a roll stopped part way or is running" ;; esac
  wt="$(oa_pinned_version "$CLUSTER_DIR" "$TFVARS" talos_version)"; wk="$(oa_pinned_version "$CLUSTER_DIR" "$TFVARS" kubernetes_version)"
  { [ -z "$wt" ] || [ "$tv" = "$wt" ]; } || echo "the fleet runs Talos ${tv:-?}, the config pins $wt: the Talos roll is pending (task cluster-up converges it first)"
  { [ -z "$wk" ] || [ "$kv" = "$wk" ]; } || echo "the fleet runs Kubernetes ${kv:-?}, the config pins $wk: the Kubernetes roll is pending (task cluster-up converges it first)"
}

REASONS=""
if [ -n "$FLUX_DIFF" ]; then REASONS="$(gate_flux)"; fi
ROLLWHY=""
if [ -n "$FLUX_DIFF" ]; then ROLLWHY="$(gate_roll)"; fi

if [ "$APPLY" -ne 1 ]; then
  [ -z "$FLUX_DIFF" ] || echo "Flux differs from the pin."
  [ -z "$CILIUM_DIFF" ] || echo "Cilium differs from the pin: this script does not apply Cilium. Rebuild aside (docs/upgrade.md, 'Cilium and Flux on a running cluster')."
  [ -z "$REASONS" ] || printf 'An apply of Flux would be REFUSED:\n%s\n' "$(sed 's/^/  - /' <<<"$REASONS")"
  [ -z "$ROLLWHY" ] || printf 'An apply of Flux would be REFUSED (a roll may be under way):\n%s\n' "$(sed 's/^/  - /' <<<"$ROLLWHY")"
  if [ -n "$FLUX_DIFF" ] && [ -z "$REASONS$ROLLWHY" ]; then
    out="$(kubectl apply --server-side --force-conflicts --field-manager=openaether-bootstrap --dry-run=server -f "$MANIFESTS/flux-install.yaml" 2>&1)" \
      || fail "the API server would refuse flux-install.yaml (server-side dry run): $(head -c 300 <<<"$out")"
    echo "  server-side dry run: the API server accepts $(grep -c . <<<"$out") object(s) of flux-install.yaml."
  fi
  echo "✗ NOTHING was written (dry run)." >&2
  [ -z "$FLUX_DIFF" ] || echo "  Move Flux: task cluster-bootstrap-sync PROVIDER=… ROLE=… APPLY=1" >&2
  exit 3
fi

# --- --apply (Flux only): every refusal before the first write -----------------------------------------------------------
if [ -n "$FLUX_DIFF" ]; then
  [ -z "$REASONS" ] || refuse "Flux is not applied: $(sed 's/^/  - /' <<<"$REASONS" | paste -sd' ' -)"
  [ -z "$ROLLWHY" ] || refuse "Flux is not applied while a Talos or Kubernetes roll may be under way: $(sed 's/^/  - /' <<<"$ROLLWHY" | paste -sd' ' -)"
  err="$(mktemp)"; trap 'rm -f "$err"' EXIT
  echo "▶ server-side apply of flux-install.yaml (field manager openaether-bootstrap)"
  kubectl apply --server-side --force-conflicts --field-manager=openaether-bootstrap -f "$MANIFESTS/flux-install.yaml" >/dev/null 2>"$err" \
    || fail "apply refused: $(head -c 400 "$err")"
  while read -r _ n _; do
    kubectl -n "$NS" rollout status "deployment/$n" --timeout="${RTO}s" >/dev/null 2>"$err" \
      || fail "deployment/$n did not finish rolling out within ${RTO}s: $(head -c 300 "$err"). Read: kubectl -n $NS describe deployment $n"
  done <<<"$FLUX_PINS"
  FLUX_LIVE="$(oa_live_pins flux "$NS")" || fail "cannot read the Deployments of $NS after the apply"
  left="$(oa_pin_diff "$FLUX_PINS" "$FLUX_LIVE")"
  [ -z "$left" ] || fail "after the apply the controllers still differ from the pin: $(paste -sd';' - <<<"$left")"
  echo "✓ the Flux controllers run the pinned versions and every Deployment rolled out."
fi
if [ -n "$CILIUM_DIFF" ]; then
  echo "✗ Cilium differs from the pin and was NOT changed: this script does not apply Cilium. Rebuild aside (docs/upgrade.md, 'Cilium and Flux on a running cluster')." >&2
  exit 5
fi
exit 0
