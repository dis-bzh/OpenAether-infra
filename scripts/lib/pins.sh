#!/usr/bin/env bash
# ==============================================================================
# OpenAether: readers for the pins that a running cluster does NOT follow by itself (infra #408). Source this; do not run it.
#
# The Talos inline manifest `flux-bootstrap` creates an object when it is missing and never updates one that exists, so the
# apps ref (git_ref), the Cilium and the Flux controllers of a running cluster are not moved by a machine-config change. For
# each of them the model is: a declared pin, a command that converges the cluster to it, a verify check that fails on any
# difference. Both the commands and the verifier read the pins through THESE functions, so they cannot disagree.
#
# Needs common.sh (tfv, oa_pinned_version, oa_fleet_versions) sourced first. Reads files and prints; touches nothing.
# ==============================================================================

# A fully qualified Git ref, as variables.tf demands (refs/(heads|tags)/...), restricted to the characters a tag or branch
# name needs: the value goes into a YAML field, a JSON patch and a tfvars line, so nothing that quotes or splits is accepted.
# Usage: oa_ref_valid <ref>   (0 valid)
oa_ref_valid() {
  [[ "$1" =~ ^refs/(heads|tags)/[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]] && [[ "$1" != *..* ]] && [[ "$1" != */ ]]
}

# A branch moves under Flux without anyone asking. Usage: oa_ref_is_branch <ref>
oa_ref_is_branch() { [[ "$1" == refs/heads/* ]]; }

# The declared apps ref: TF_VAR_git_ref, else the tfvars, else the default of variables.tf (tofu's own precedence).
# Usage: oa_declared_git_ref <cluster-dir> <tfvars-file>
oa_declared_git_ref() {
  if [ -n "${TF_VAR_git_ref:-}" ]; then printf '%s' "$TF_VAR_git_ref"; else oa_pinned_version "$1" "$2" git_ref; fi
}

# The versions the committed artifacts install. One line per component, "<kind> <name> <image tag>":
#   flux   <deployment>  <tag>     from bootstrap-manifests/flux-install.yaml (the 7 controllers)
#   cilium <workload>    <tag>     from the cilium manifest (agent, operator; the envoy image is not compared)
# Usage: oa_artifact_pins flux <flux-install.yaml> | oa_artifact_pins cilium <cilium*.yaml>
oa_artifact_pins() {
  case "$1" in
    flux)
      awk '
        /^kind: Deployment$/ { dep = 1; name = ""; next }
        /^kind: / { dep = 0 }
        dep && /^  name: / && name == "" { name = $2 }
        dep && name != "" && /^ +image: ghcr.io\/fluxcd\// { img = $2; sub(/.*:/, "", img); print "flux " name " " img; dep = 0 }
      ' "$2" ;;
    cilium)
      awk '
        /^kind: (DaemonSet|Deployment)$/ { w = 1; name = ""; next }
        /^kind: / { w = 0 }
        w && /^  name: / && name == "" { name = $2 }
        w && name != "" && /^ +image: "?quay.io\/cilium\/(cilium|operator-generic):/ {
          img = $2; gsub(/"/, "", img); sub(/@.*/, "", img); sub(/.*:/, "", img)
          if (!(name in seen)) { seen[name] = 1; print "cilium " name " " img }
        }
      ' "$2" ;;
  esac
}

# The versions a LIVE cluster runs, read from the image of the workload spec (not from a pod: a pod may be mid-roll), same
# shape as oa_artifact_pins. Prints nothing and returns 1 when the API cannot be read. Flux: namespace $2 (default flux-system).
# Usage: oa_live_pins flux [ns] | oa_live_pins cilium
oa_live_pins() {
  local out
  case "$1" in
    flux)
      out="$(timeout 60 kubectl -n "${2:-flux-system}" get deployments -o json 2>/dev/null)" || return 1
      jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("^ghcr.io/fluxcd/"))
             | "flux \(.metadata.name) \(.spec.template.spec.containers[0].image | sub("@.*"; "") | sub(".*:"; ""))"' <<<"$out" 2>/dev/null | sort ;;
    cilium)
      out="$(timeout 60 kubectl -n kube-system get daemonsets,deployments -o json 2>/dev/null)" || return 1
      jq -r '.items[] | select(.metadata.name == "cilium" or .metadata.name == "cilium-operator")
             | "cilium \(.metadata.name) \(.spec.template.spec.containers[0].image | sub("@.*"; "") | sub(".*:"; ""))"' <<<"$out" 2>/dev/null | sort ;;
  esac
}

# The marker of a refused or interrupted Flux apply (infra #448), one per config file: oa_flux_marker <cluster dir> <tfvars file>
oa_flux_marker() { printf '%s/.flux-apply-unfinished-%s' "$1" "$(basename "$2" .tfvars)"; }

# Is the Flux install FINISHED, not only at the pinned tags? (infra #448) `kubectl apply` does not stop at the first refused object: the
# Deployments can carry the pinned tags while a CRD was refused, or a rollout never completed, and the tags alone then read "all is well".
# Prints one line per gap, nothing when every pinned Deployment has observedGeneration == generation and readyReplicas == replicas AND every
# CRD of the artifact exists and is Established. Returns 1, printing the reason, when the API cannot be read (the caller says UNKNOWN).
# A refused UPDATE of a CRD that already exists is NOT visible in the cluster (the old CRD stays Established): the optional marker file is
# what remembers it. cluster-bootstrap-sync.sh creates it before an apply and deletes it once an apply was accepted whole; while it exists
# the install is "not finished", whatever the cluster shows. It lives in the cluster directory of one checkout (gitignored): an apply made
# elsewhere, or by hand, leaves no trace here.
# Usage: oa_flux_gaps <namespace> <flux-install.yaml> [marker file]
oa_flux_gaps() {
  local ns="$1" file="$2" marker="${3:-}" names dj cj est c s
  if [ -n "$marker" ] && [ -e "$marker" ]; then
    echo "the last apply of flux-install.yaml was refused or interrupted (marker ${marker##*/}): some of its objects, an UPDATE of an existing CRD among them, may not be applied, and the cluster cannot show it"
  fi
  names="$(oa_artifact_pins flux "$file" | awk '{ print $2 }' | paste -sd' ' -)"
  [ -n "$names" ] || { echo "no controller in $(basename "$file")"; return 1; }
  dj="$(timeout 60 kubectl -n "$ns" get deployments -o json 2>/dev/null)" || { echo "the Deployments of $ns cannot be read"; return 1; }
  cj="$(timeout 60 kubectl get crd -l app.kubernetes.io/part-of=flux -o json 2>/dev/null)" || { echo "the Flux CRDs cannot be read"; return 1; }
  jq -r --arg names "$names" '
    ($names | split(" ")) as $w
    | .items[] | select(.metadata.name as $n | $w | index($n)) | (.spec.replicas // 1) as $r
    | if (.status.observedGeneration // 0) != (.metadata.generation // 0)
      then "deployment/\(.metadata.name): the controller has not observed generation \(.metadata.generation // 0) (observedGeneration \(.status.observedGeneration // 0)): the rollout is unfinished"
      elif (.status.readyReplicas // 0) != $r
      then "deployment/\(.metadata.name): \(.status.readyReplicas // 0) of \($r) replicas ready: the rollout is unfinished"
      else empty end' <<<"$dj" 2>/dev/null || { echo "the Deployments of $ns cannot be parsed"; return 1; }
  est="$(jq -r '.items[] | "\(.metadata.name) \([.status.conditions[]? | select(.type == "Established") | .status][0] // "Unknown")"' <<<"$cj" 2>/dev/null)" \
    || { echo "the Flux CRDs cannot be parsed"; return 1; }
  while read -r c; do
    [ -n "$c" ] || continue
    s="$(awk -v c="$c" '$1 == c { print $2 }' <<<"$est")"
    [ "$s" = True ] && continue
    if [ -z "$s" ]; then echo "customresourcedefinition/$c: not found (not applied yet, or refused)"
    else echo "customresourcedefinition/$c: not Established ($s)"; fi
  done < <(awk '/^kind: / { w = ($2 == "CustomResourceDefinition"); n = 0; next } w && !n && /^  name: / { print $2; n = 1 }' "$file")
  return 0
}

# Compare two pin lists (declared, live): prints one line per difference, nothing when they are the same.
#   "<kind> <name> pinned <a> running <b>"  /  "... not running" / "... not pinned"
# Both directions: a component that runs and is not pinned is a difference too.
# Usage: oa_pin_diff <declared-list> <live-list>
oa_pin_diff() {
  awk '
    FNR == NR { want[$2] = $3; kind[$2] = $1; next }
    { have[$2] = $3; kind[$2] = $1 }
    END {
      for (n in want) {
        if (!(n in have)) print kind[n], n, "pinned", want[n], "not running"
        else if (have[n] != want[n]) print kind[n], n, "pinned", want[n], "running", have[n]
      }
      for (n in have) if (!(n in want)) print kind[n], n, "running", have[n], "not pinned"
    }' <(printf '%s\n' "$1") <(printf '%s\n' "$2") | sort
}

# Why a Talos or Kubernetes roll may be under way: prints one reason per line, nothing when the fleet is quiet and at its pins.
# Shared by cluster-bootstrap-sync and cnpg-presync: neither may write while the nodes are moving. Needs common.sh (oa_fleet_versions,
# oa_pinned_version) and a kubeconfig in KUBECONFIG. Usage: oa_roll_gate <cluster-dir> <tfvars-file>
oa_roll_gate() {
  local nodes bad tv kv wt wk
  nodes="$(timeout 60 kubectl get nodes -o json 2>/dev/null)" || { echo "the nodes cannot be read: whether a roll is under way is UNKNOWN"; return; }
  bad="$(jq -r '[.items[] | select(((.status.conditions[]? | select(.type == "Ready") | .status) != "True") or (.spec.unschedulable == true)) | .metadata.name] | join(" ")' <<<"$nodes")"
  [ -z "$bad" ] || echo "node(s) not Ready or cordoned (a drain or a roll is under way): $bad"
  tv="$(oa_fleet_versions '.status.nodeInfo.osImage')"; kv="$(oa_fleet_versions '.status.nodeInfo.kubeletVersion')"
  case "$tv$kv" in *,*) echo "the nodes disagree on Talos ($tv) or Kubernetes ($kv): a roll stopped part way or is running" ;; esac
  wt="$(oa_pinned_version "$1" "$2" talos_version)"; wk="$(oa_pinned_version "$1" "$2" kubernetes_version)"
  { [ -z "$wt" ] || [ "$tv" = "$wt" ]; } || echo "the fleet runs Talos ${tv:-?}, the config pins $wt: the Talos roll is pending (task cluster-up converges it first)"
  { [ -z "$wk" ] || [ "$kv" = "$wk" ]; } || echo "the fleet runs Kubernetes ${kv:-?}, the config pins $wk: the Kubernetes roll is pending (task cluster-up converges it first)"
}
