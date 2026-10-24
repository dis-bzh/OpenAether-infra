#!/usr/bin/env bash
# ==============================================================================
# OpenAether: readers for the pins that a running cluster does NOT follow by itself (infra #408). Source this; do not run it.
#
# The Talos inline manifest `flux-bootstrap` creates an object when it is missing and never updates one that exists, so the
# apps ref (git_ref), the Cilium and the Flux controllers of a running cluster are not moved by a machine-config change. For
# each of them the model is: a declared pin, a command that converges the cluster to it, a verify check that fails on any
# difference. Both the commands and the verifier read the pins through THESE functions, so they cannot disagree.
#
# Needs common.sh (tfv, oa_pinned_version) sourced first. Reads files and prints; touches nothing.
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
