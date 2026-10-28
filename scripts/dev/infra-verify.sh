#!/usr/bin/env bash
# What a PURE-INFRA cluster must prove once `task cluster-up` returns.
#
# This is the ONLY verifier. A full-platform sibling used to wait for 35 Flux
# Kustomizations, the Gateway and the OpenAether-apps ref; it went with the
# staging lane, because 0.1.0 ships none of that. The claim defended here is
# exactly the release scope: a cluster that is healthy, up and ready, with its
# state backed up.
#
# It also asserts what must be ABSENT. "No Flux" and "no application load
# balancer" are the product decision for this release, and a decision nothing checks is
# a decision that quietly reverts — this repository has watched that happen. They are
# absent unless the env file (or TF_VAR_deploy_flux / TF_VAR_deploy_app_lb) asks for them:
# a deploy_flux = true cluster must then HAVE Flux, with its controllers Available.
#
# Every check FAILS the run. A verify that warns and ends green is the defect
# that let a CNI-less cluster ship for weeks.
#
# Usage: infra-verify.sh <provider> <role>
#        infra-verify.sh local                (the Docker cluster)
set -uo pipefail

PROVIDER="${1:?usage: infra-verify.sh <provider|local> [role]}"
ROLE="${2:-management}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "$PROVIDER" = local ]; then
  CLUSTER_DIR="$ROOT/infrastructure/opentofu-local"
else
  CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
fi
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$CLUSTER_DIR/talosconfig}"

PASS=0
FAIL=0
UNKNOWN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
# Neither pass nor fail: a fact the operator must read. Used where the cluster is
# legitimately below the release's target but the run is not wrong (a non-HA
# topology, a dev replica sharing its endpoint).
warn() { printf '  \033[33m~\033[0m %s\n' "$*"; }
# "I could not perform this check" is NOT "this check failed", and reporting both
# as `2 failed` tells an operator their cluster is broken when the truth is that
# the verifier could not see it. Still fatal — a release is not certified on
# questions nobody could ask — but counted and named apart.
unk()  { printf '  \033[33m?\033[0m %s\n' "$*"; UNKNOWN=$((UNKNOWN + 1)); }
info() { printf '\n▶ %s\n' "$*"; }

K() { timeout 60 kubectl "$@"; }

# Sourced HERE, not where the first caller happens to be: the version check below
# needs `tfv` too, and it runs long before the backup section that used to own
# this line. common.sh is function definitions only, so sourcing it early costs
# nothing and runs nothing.
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

info "The cluster answers"

# WAIT, do not sample once. `task cluster-up` returns when the Talos bootstrap RPC
# succeeded, which is before the apiserver serves — and on the tfvars that set
# skip_health_check it returns even earlier. Measured on OVH 2026-08-16: nodes
# five seconds old and the API load balancer answering EOF because it has no
# healthy backend yet. Sampling once here would have made every cloud run red
# for the one reason that is guaranteed to pass a minute later. Same defect this
# repository fixed in the roll's pre-flight the same morning.
API_TIMEOUT="${API_TIMEOUT:-420}"
deadline=$((SECONDS + API_TIMEOUT))
until K get --raw='/readyz' >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then break; fi
  sleep 10
done
if K get --raw='/readyz' >/dev/null 2>&1; then
  ok "apiserver ready"
else
  bad "apiserver never answered /readyz within ${API_TIMEOUT}s"
fi

# Bounded wait, not an instant assertion: `task cluster-up` returns when OpenTofu is
# done, which is before the last worker has finished joining.
NODES_TIMEOUT="${NODES_TIMEOUT:-300}"
deadline=$((SECONDS + NODES_TIMEOUT))
while :; do
  # A FAILED query is not "every node is Ready", and an EMPTY list is not either.
  if raw="$(K get nodes --no-headers 2>/dev/null)" && [ -n "$raw" ]; then
    notready="$(awk '$2 !~ /^Ready/{printf "%s ", $1}' <<<"$raw")"
    [ -z "$notready" ] && break
  else
    notready="(the apiserver did not answer)"
  fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 10
done
if [ -z "${notready:-}" ] && [ -n "${raw:-}" ]; then
  ok "$(wc -l <<<"$raw") node(s) Ready"
else
  bad "after ${NODES_TIMEOUT}s, not Ready: ${notready:-unknown}"
fi

# "Every node is Ready" is a count of what turned up, not of what was asked for.
# A one-control-plane cluster passed every check in this file while HA is the
# release's headline objective — so compare the cluster against the STATE, which
# is the only place that records the topology the operator actually requested.
if [ "$PROVIDER" != local ]; then
  want_cp="$(cd "$CLUSTER_DIR" && timeout 60 tofu output -json control_plane_private_ips 2>/dev/null | jq 'length' 2>/dev/null)"
  got_cp="$(K get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)"
  if ! [[ "${want_cp:-}" =~ ^[0-9]+$ ]] || [ "$want_cp" -eq 0 ]; then
    unk "could not read control_plane_private_ips from the state — the topology is UNCHECKED"
  elif [ "$got_cp" -ne "$want_cp" ]; then
    bad "${got_cp} control-plane node(s) in the cluster, ${want_cp} in the state"
  elif [ "$want_cp" -lt 3 ]; then
    warn "${want_cp} control plane(s): this cluster is NOT HA, and an upgrade WILL interrupt the API"
  else
    # Counting nodes is not HA: three in one zone all go when it does. The spread
    # is what the state says it PLACED (control_plane_zones), not a measurement.
    # One domain is red; a quorum's worth in one of several is a warning, because
    # the 2-zone topology 0.1.0 was measured on is a 2+1 split.
    zones="$(cd "$CLUSTER_DIR" && timeout 60 tofu output -json control_plane_zones 2>/dev/null)" || zones=""
    # "<most nodes in one domain> <distinct domains> <names>", or "x x" for a list
    # that cannot be trusted: wrong length, null, or a name the provider left empty.
    read -r worst doms names < <(jq -r --argjson n "$want_cp" '
      if type == "array" and length == $n and all(.[]; type == "string" and . != "")
      then "\(group_by(.) | map(length) | max) \(unique | length) \(join(","))"
      else "x x" end' <<<"$zones" 2>/dev/null)
    if ! [[ "${worst:-}" =~ ^[0-9]+$ ]]; then
      if [ -z "$zones" ]; then
        unk "control_plane_zones could not be read from the state — the spread is UNCHECKED; a state older than this output needs one apply: task infra-plan PROVIDER=${PROVIDER} ROLE=${ROLE} OUT=tfplan, read it, then task infra-apply PROVIDER=${PROVIDER} ROLE=${ROLE} PLAN=tfplan"
      else
        unk "control_plane_zones is not ${want_cp} non-empty zone names (the provider placed nodes it did not name) — the spread is UNCHECKED"
      fi
    elif [ "$doms" -lt 2 ]; then
      case "$PROVIDER" in
        scaleway | scw) clears="spread node_distribution.scaleway.zones" ;;
        ovh)            clears="spread node_distribution.ovh.availability_zones" ;;
        proxmox)        clears="spread node_distribution.proxmox.node_names" ;;
        outscale)       clears="list 2+ subregions in availability_zones (a node's zone is fixed when it is created)" ;;
        *)              clears="spread the control planes" ;;
      esac
      bad "${worst} of ${got_cp} control planes share one failure domain (${names}) — losing it loses the control plane: HA against a node, not against a zone; ${clears}"
    elif [ "$worst" -ge $((want_cp - want_cp / 2)) ]; then
      ok "${got_cp} control planes, matching the state"
      warn "${worst} of ${got_cp} control planes sit in one of ${doms} failure domains (${names}): losing that one loses etcd quorum"
    else
      ok "${got_cp} control planes across ${doms} failure domains, none holding a quorum — HA"
    fi
  fi
fi

# The CNI is the floor. A node can be Ready with a broken CNI only briefly, but
# "Cilium is on every node" is the thing that makes the cluster usable, and it is
# counted per node rather than globally — one agent short is the interesting case.
EXPECTED="$(K get nodes --no-headers 2>/dev/null | wc -l)"
CILIUM="$(K -n kube-system get pods -l k8s-app=cilium --field-selector status.phase=Running --no-headers 2>/dev/null | wc -l)"
if [ "$CILIUM" -gt 0 ] && [ "$CILIUM" -eq "$EXPECTED" ]; then
  ok "Cilium running on ${CILIUM}/${EXPECTED} node(s)"
else
  bad "Cilium on ${CILIUM} node(s), expected ${EXPECTED}"
fi

# CoreDNS proves the CNI actually carries traffic, which "the pod is Running"
# does not: a broken datapath leaves DNS pods up and every lookup dead.
#
# Bounded wait, like the nodes above and for the same reason. This was an
# INSTANT read, and every node being Ready does not mean CoreDNS has finished
# rolling out: measured 2026-08-24 on the Docker lane, `local-verify` run right
# after `local-up` reported "no ready replica" against a cluster that was 2/2
# forty seconds later. A gate that fails on a healthy cluster is worse than no
# gate — it is the one people learn to re-run until it passes.
DNS_TIMEOUT="${DNS_TIMEOUT:-180}"
deadline=$((SECONDS + DNS_TIMEOUT))
dns_ready=""
while :; do
  dns_ready="$(K -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ "$dns_ready" =~ ^[1-9] ]] && break
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 5
done
if [[ "$dns_ready" =~ ^[1-9] ]]; then
  ok "CoreDNS has ${dns_ready} ready replica(s) — the datapath carries traffic"
else
  bad "after ${DNS_TIMEOUT}s CoreDNS has no ready replica — the CNI is up but the network is not"
fi

info "The floor is the floor — what this release says is NOT there"

# What the operator configured decides what must be present and what must be absent. Before, the verdict ignored it: a
# deploy_flux = true cluster could never be green ("flux-system exists", "an application load balancer exists"), and the first
# message said that red was "expected until the Day-1 seeding" (it is not: the namespace exists from the install on). TF_VAR_*
# wins over the env file, like tofu; anything but the word true is false, the variables' defaults.
VER_TFVARS="$CLUSTER_DIR/envs/${ROLE}-${PROVIDER}.tfvars"
cfg_value() { # <key> — TF_VAR_<key>, else the env file, else empty
  local n="TF_VAR_$1" v
  v="${!n:-}"
  [ -n "$v" ] || { [ -f "$VER_TFVARS" ] && v="$(tfv "$VER_TFVARS" "$1")"; }
  printf '%s' "$v"
}
WANT_FLUX=false; [ "$(cfg_value deploy_flux)" = true ] && WANT_FLUX=true
WANT_APP_LB=false; [ "$(cfg_value deploy_app_lb)" = true ] && WANT_APP_LB=true

# The CoreDNS HA of 0.4.0 is an inline manifest, and Talos creates an inline manifest's objects only when they are absent (lab 26,
# K2): on a cluster built by an older release the Talos-created Deployment stays at 2 replicas with no spread, while the budget (new)
# does appear. So "CoreDNS answers" (above) is not "CoreDNS is what the config declares": compare the Deployment with the declared
# shape, in both directions. The declared count is min(3, nodes), as modules/talos computes it.
if [ "$PROVIDER" != local ] && [ "$(cfg_value coredns_ha)" != false ]; then
  info "CoreDNS runs the declared replica count and spread"
  dns_fix="kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json   (a rolling restart of the CoreDNS pods; docs/upgrade.md, From 0.3.x to 0.4.0)"
  dns_want=$(( EXPECTED < 3 ? EXPECTED : 3 ))
  if dns_json="$(K -n kube-system get deploy coredns -o json 2>/dev/null)" && [ -n "$dns_json" ] && [ "$dns_want" -ge 1 ]; then
    dns_have="$(jq -r '.spec.replicas // empty' <<<"$dns_json" 2>/dev/null)"
    dns_hard="$(jq -r '[.spec.template.spec.topologySpreadConstraints[]? | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule")] | length' <<<"$dns_json" 2>/dev/null)"
    if ! [[ "$dns_have" =~ ^[0-9]+$ ]] || ! [[ "$dns_hard" =~ ^[0-9]+$ ]]; then
      unk "could not read the replica count or the spread of Deployment kube-system/coredns"
    elif [ "$dns_have" -ne "$dns_want" ]; then
      bad "CoreDNS has ${dns_have} replica(s) (spec), the config declares ${dns_want} (coredns_ha: min(3, nodes)) — $([ "$dns_have" -lt "$dns_want" ] && echo BEHIND || echo AHEAD of) the declaration; an object Talos created earlier is never rewritten by an inline manifest. One-time: ${dns_fix}"
    elif [ "$dns_hard" -eq 0 ]; then
      bad "CoreDNS has ${dns_have} replica(s) but no hard spread over nodes: they can share one node, whose loss takes DNS down. One-time: ${dns_fix}"
    else
      ok "CoreDNS runs the declared ${dns_want} replica(s) with a hard spread over nodes"
    fi
  else
    unk "could not read Deployment kube-system/coredns — the replica count and spread are UNCHECKED"
  fi
fi
# The Cilium operator runs 2 replicas since 0.4.0 (critical-path audit: it ran 1). Same trap as CoreDNS above: the Cilium manifest is
# an inline manifest, Talos creates its objects only when absent, so a cluster built by an older release keeps ONE operator replica
# (the new budget appears, the Deployment does not change). Not judged on the local provider (one Docker node, replicas 1 by design).
if [ "$PROVIDER" != local ]; then
  info "The Cilium operator runs 2 replicas"
  op_fix="kubectl -n kube-system patch deployment cilium-operator --type merge --patch-file scripts/ops/cilium-operator-ha-patch.json   (the operator pods restart one at a time; docs/upgrade.md, From 0.3.x to 0.4.0)"
  if op_json="$(K -n kube-system get deploy cilium-operator -o json 2>/dev/null)" && [ -n "$op_json" ]; then
    op_have="$(jq -r '.spec.replicas // empty' <<<"$op_json" 2>/dev/null)"
    if ! [[ "$op_have" =~ ^[0-9]+$ ]]; then
      unk "could not read the replica count of Deployment kube-system/cilium-operator"
    elif [ "$EXPECTED" -ge 2 ] && [ "$op_have" -lt 2 ]; then
      bad "the Cilium operator has ${op_have} replica(s), the manifest declares 2: a lost node leaves identity and node garbage collection and the Gateway/LB-IPAM controllers down for the 5 minute toleration; an object Talos created earlier is never rewritten by an inline manifest. One-time: ${op_fix}"
    else
      ok "the Cilium operator runs ${op_have} replica(s)"
    fi
  else
    unk "could not read Deployment kube-system/cilium-operator — the operator replica count is UNCHECKED"
  fi
fi
FLUX_NS="$(cfg_value flux_namespace)"; FLUX_NS="${FLUX_NS:-flux-system}"

# Not cosmetic. deploy_flux defaults to false; if something re-enables it the cluster silently stops being the thing this
# release validated. And the other way round: deploy_flux = true must find Flux, or the install did not land.
if [ "$WANT_FLUX" = true ]; then
  if ! K get ns "$FLUX_NS" >/dev/null 2>&1; then
    bad "deploy_flux = true but there is no ${FLUX_NS} namespace — Flux was not installed (bootstrap-phase2 of cluster-up), or the file read here (${VER_TFVARS##*/}) is not the one applied"
  elif K -n "$FLUX_NS" wait --for=condition=Available deploy --all --timeout=60s >/dev/null 2>&1; then
    ok "deploy_flux = true: ${FLUX_NS} exists and every Flux controller is Available"
  else
    bad "deploy_flux = true: ${FLUX_NS} exists but a Flux controller is not Available (kubectl -n ${FLUX_NS} get deploy)"
  fi
elif K get ns "$FLUX_NS" >/dev/null 2>&1; then
  bad "${FLUX_NS} exists — this is not a pure-infra cluster, and deploy_flux is not true in ${VER_TFVARS##*/} or TF_VAR_deploy_flux. If Flux is meant to be here, set deploy_flux = true there (this check then asks for it instead); otherwise something re-enabled it"
else
  ok "no ${FLUX_NS} namespace — Talos and Cilium, as scoped (deploy_flux is not true)"
fi

if [ "$PROVIDER" != local ]; then
  # `tofu output` failing and `tofu output` saying N/A are DIFFERENT ANSWERS, and
  # this used to green on both — an uninitialised backend, missing credentials or
  # a timeout all produce an empty string, which the old `${APP_LB:-N/A}` read as
  # "no load balancer". From a cold shell it could only ever pass. Capture the
  # exit code and treat a failed question as unanswered, never as reassurance.
  if APP_LB="$(cd "$CLUSTER_DIR" && timeout 60 tofu output -raw app_lb_ip 2>/dev/null)"; then
    case "$APP_LB" in
      N/A | "" | null)
        if [ "$WANT_APP_LB" = true ]; then
          bad "deploy_app_lb = true but the state holds no application load balancer (app_lb_ip is ${APP_LB:-empty}) — the apply that creates it did not land"
        else
          ok "no application load balancer (deploy_app_lb is not true)"
        fi ;;
      *)
        if [ "$WANT_APP_LB" = true ]; then
          ok "deploy_app_lb = true: an application load balancer exists"
          [ "$WANT_FLUX" = true ] || warn "deploy_app_lb = true without deploy_flux: the load balancer points at Gateway NodePorts nothing serves"
        else
          bad "an application load balancer exists and is billed, and deploy_app_lb is not true in ${VER_TFVARS##*/} or TF_VAR_deploy_app_lb: on an infra-only cluster it points at Gateway NodePorts nothing serves. Set deploy_app_lb = true there if it is meant to be, or remove it"
        fi ;;
    esac
  else
    unk "could not read app_lb_ip (is the backend initialised, are the S3 credentials exported?) — the application load balancer is UNCHECKED"
  fi
fi

# --- The fleet runs the versions the config pins --------------------------------
#
# `cluster-up` writes the pinned installer image into the machine config and asks
# NO node to upgrade — `talosctl upgrade` lives in rolling-replace.sh alone. So a
# bumped pin leaves the fleet a version behind with an empty plan behind it, and
# the schematic check below cannot see it: a version bump does not change the
# schematic. Every signal read green. This is the one that does not.
#
# kubectl, not talosctl: the node publishes both versions to the apiserver, which
# section 1 has already proven reachable. So unlike the schematic this needs no
# tunnel, cannot degrade for want of one, and a mismatch is a hard failure rather
# than a warning.
info "The fleet runs the versions the config pins"

# The distinct set across all nodes, or empty. custom-columns rather than
# jsonpath, and `|| true` because with no cluster the grep matches nothing and
# pipefail would otherwise turn an empty answer into a dead script. Same reader as
# cluster-upgrade.sh:97 — deliberately, so the two cannot disagree about what the
# fleet runs.
fleet_versions() { # <field>
  K get nodes --no-headers -o "custom-columns=V:$1" 2>/dev/null |
    sed -E 's/^Talos \((v[^)]+)\)$/\1/' | grep -E '^v' | sort -u | paste -sd, - || true
}

# The pin, with the precedence scripts/internal/talos-version.sh already defines:
# the env file if it pins one, otherwise the root's default. An env file that
# omits the key is a DELIBERATE choice to track the default (see the header of
# envs/management-*.tfvars), so an empty read falls through — it is never a fault.
pinned_version() { # <key>
  local v="" blk
  [ -f "$VER_TFVARS" ] && v="$(tfv "$VER_TFVARS" "$1")"
  # The awk pattern is built HERE, not escaped inline: a \" inside single quotes
  # inside $( ) inside " " is where bash stops agreeing with you.
  blk="variable \"$1\""
  [ -n "$v" ] || v="$(awk -v k="$blk" 'index($0, k) == 1, /^}/' \
                        "$CLUSTER_DIR/variables.tf" 2>/dev/null |
                      sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
  printf '%s' "$v"
}

# Four answers, not three. A comma means the nodes disagree with EACH OTHER, which
# is neither "matches" nor "drifted" — it is a roll that stopped half way, and
# saying "drifted" there would send the operator looking for the wrong thing.
version_check() { # <label> <field> <key>
  local have want fix
  have="$(fleet_versions "$2")"
  want="$(pinned_version "$3")"
  # The remedy has to be one that exists HERE. `talosctl upgrade` needs a disk,
  # which a container does not have, so cluster-upgrade is not a thing to send a
  # local operator to — the local cluster is rebuilt, not upgraded.
  if [ "$PROVIDER" = local ]; then fix="task local-down && task local-up"
  else fix="task cluster-upgrade PROVIDER=${PROVIDER}"; fi
  if [ -z "$want" ]; then
    warn "no ${3} pinned in ${VER_TFVARS##*/} or variables.tf — nothing to compare the fleet against"
  elif [ -z "$have" ]; then
    unk "could not read the running ${1} from any node — the fleet's version is UNCHECKED"
  elif case "$have" in *,*) true ;; *) false ;; esac; then
    bad "the fleet is MIXED on ${1}: ${have}. The config pins ${want} — a roll stopped part way. Finish it: ${fix}"
  elif [ "$have" = "$want" ]; then
    ok "every node runs the pinned ${1} (${want})"
  else
    bad "the fleet runs ${1} ${have}, the config pins ${want} — the pin was changed and never landed. Land it: ${fix}"
  fi
}

version_check "Talos"      '.status.nodeInfo.osImage'        talos_version
version_check "Kubernetes" '.status.nodeInfo.kubeletVersion' kubernetes_version

# --- Cilium and the Flux controllers run the version the artifacts pin (infra #408) ---------------------------------------
#
# Talos creates an inline-manifest object when it is missing and does not update one that exists, so a bumped Cilium or Flux
# pin (render-bootstrap-manifests.sh) never reaches a running cluster by itself. Compared in BOTH directions, per workload:
# behind and ahead are both a difference. The pin is what the committed artifact installs (scripts/lib/pins.sh), the running
# version is the image tag of the workload spec. The local Docker cluster is rebuilt, not upgraded, and renders its own Cilium.
# shellcheck source=../lib/pins.sh
source "$ROOT/scripts/lib/pins.sh"
pins_check() { # <label> <artifact file> <kind> <fix-when-behind> <fix-when-ahead> [ns]
  local label="$1" file="$2" kind="$3" behind="$4" ahead="$5" want have diff line
  if [ ! -f "$file" ]; then unk "${label}: the pinned artifact ${file##*/} is not readable here — the running version is UNCHECKED"; return; fi
  want="$(oa_artifact_pins "$kind" "$file")"
  have="$(oa_live_pins "$kind" "${6:-}")" || have=""
  if [ -z "$want" ]; then unk "${label}: no image found in ${file##*/} — nothing to compare against"; return; fi
  if [ -z "$have" ]; then unk "${label}: could not read the running workloads (API error or none found) — their versions are UNCHECKED"; return; fi
  diff="$(oa_pin_diff "$want" "$have")"
  if [ -z "$diff" ]; then
    ok "${label} run the pinned version ($(awk '{print $3}' <<<"$want" | sort -u | paste -sd, -))"
    return
  fi
  while read -r line; do
    pv="$(awk '{print $4}' <<<"$line")"; rv="$(awk '{print $6}' <<<"$line")"; line="${line#* }"   # drop the kind: the label says it
    case "$line" in
      *"not running"*) bad "${label}: ${line}. ${behind}" ;;
      *"not pinned"*) bad "${label}: ${line} — the artifact no longer has it. ${ahead}" ;;
      *) # "<kind> <name> pinned A running B": which side is ahead decides the advice
         if oa_semver_lt "$pv" "$rv"; then bad "${label}: ${line} — the cluster is AHEAD of the pin. ${ahead}"
         else bad "${label}: ${line} — the cluster is BEHIND the pin. ${behind}"; fi ;;
    esac
  done <<<"$diff"
}
if [ "$PROVIDER" != local ]; then
info "Cilium and Flux run the version the artifacts pin"
if [ -f "$VER_TFVARS" ] && grep -qE '^[[:space:]]*(cilium_manifest|flux_manifest)[[:space:]]*=' "$VER_TFVARS" \
   && ! grep -qE '^[[:space:]]*(cilium_manifest|flux_manifest)[[:space:]]*=[[:space:]]*null' "$VER_TFVARS"; then
  unk "cilium_manifest or flux_manifest is overridden in ${VER_TFVARS##*/}: the manifest the cluster was built from is not the committed one — the versions are UNCHECKED"
else
  CIL_FILE="$CLUSTER_DIR/bootstrap-manifests/cilium.yaml"
  [ "$(cfg_value cilium_hubble_drop_log)" = true ] && CIL_FILE="$CLUSTER_DIR/bootstrap-manifests/cilium-hubble-drops.yaml"
  pins_check "Cilium" "$CIL_FILE" cilium \
    "Cilium is never upgraded in place by this repository: rebuild aside (docs/upgrade.md, 'Cilium and Flux on a running cluster')." \
    "Set the pin back (render-bootstrap-manifests.sh) or rebuild aside; a downgrade is not done in place (docs/upgrade.md)."
  if [ "$WANT_FLUX" = true ]; then
    pins_check "Flux controllers" "$CLUSTER_DIR/bootstrap-manifests/flux-install.yaml" flux \
      "Move them: task cluster-bootstrap-sync PROVIDER=${PROVIDER} ROLE=${ROLE} APPLY=1" \
      "Set the pin back (render-bootstrap-manifests.sh) or rebuild aside; a downgrade is not done in place (docs/upgrade.md)." "$FLUX_NS"
  fi
fi
fi

# The apps ref (git_ref): what Flux follows against what the config declares, in both directions (infra #408). Three values: the
# tfvars, the GitRepository's spec.ref.name, the Kustomization's GIT_REF. Only when the config asks for Flux.
if [ "$PROVIDER" != local ] && [ "$WANT_FLUX" = true ]; then
info "The apps ref Flux follows is the git_ref the config declares"
DECL_REF="$(oa_declared_git_ref "$CLUSTER_DIR" "$VER_TFVARS")"
if GR_REF="$(K -n "$FLUX_NS" get gitrepositories.source.toolkit.fluxcd.io openaether -o json 2>/dev/null)" \
   && KS_REF="$(K -n "$FLUX_NS" get kustomizations.kustomize.toolkit.fluxcd.io openaether-platform -o json 2>/dev/null)"; then
  LIVE_GR_REF="$(jq -r '.spec.ref.name // ""' <<<"$GR_REF" 2>/dev/null)"
  LIVE_KS_REF="$(jq -r '.spec.postBuild.substitute.GIT_REF // ""' <<<"$KS_REF" 2>/dev/null)"
  FIXREF="task cluster-apps-ref PROVIDER=${PROVIDER} ROLE=${ROLE} APPLY=1"
  if [ -z "$DECL_REF" ]; then
    unk "no git_ref is declared (TF_VAR_git_ref, ${VER_TFVARS##*/}, variables.tf) — the apps ref is UNCHECKED"
  elif [ -z "$LIVE_GR_REF" ]; then
    unk "the GitRepository openaether has no spec.ref.name (another ref form, or unreadable) — the apps ref is UNCHECKED"
  elif [ "$LIVE_GR_REF" = "$DECL_REF" ] && [ "$LIVE_KS_REF" = "$DECL_REF" ]; then
    ok "the GitRepository and GIT_REF both follow the declared git_ref (${DECL_REF})"
  else
    [ "$LIVE_GR_REF" = "$DECL_REF" ] || bad "the GitRepository openaether follows ${LIVE_GR_REF}, git_ref declares ${DECL_REF}. Move the cluster: ${FIXREF}  (or keep the cluster's ref: ... REF=${LIVE_GR_REF} APPLY=1 writes it into the tfvars)"
    [ "$LIVE_KS_REF" = "$DECL_REF" ] || bad "GIT_REF of the Kustomization openaether-platform is '${LIVE_KS_REF:-empty}', git_ref declares ${DECL_REF}. Move the cluster: ${FIXREF}"
  fi
  case "$DECL_REF" in refs/heads/*) warn "git_ref ${DECL_REF} is a branch, a moving ref: Flux applies whatever lands on it. Pin a tag outside a throwaway lab" ;; esac
else
  unk "could not read the GitRepository openaether or the Kustomization openaether-platform — the apps ref is UNCHECKED"
fi
fi

# --- The platform CNPG Clusters run the 0.4.0 synchronous replication and archive (study LAB-B2) ----------------------------
#
# Declared: the block spec.postgresql.synchronous = any / 1 / required / failoverQuorum (the 0.4.0 content). Converged by
# `task cnpg-presync` (BEFORE the apps ref moves; docs/upgrade.md "From 0.3.x to 0.4.0"). Checked here on EVERY Cluster the apps
# content manages (label openaether.io/managed in OA_CNPG_NAMESPACES, default foundation-databases; not db-profile or rt-*
# Clusters: the same selection as cnpg-presync): the block is on the spec, ContinuousArchiving is True, the primary holds a
# non-empty synchronous_standby_names, every replica is quorum/sync in pg_stat_replication, and the FailoverQuorum object exists.
# BAD says the command; UNKNOWN when a fact cannot be read. A running state that the spec does not declare is BAD too.
# Nothing is printed from the databases but pod names and the words quorum/sync. Silent when the cluster has no CNPG Cluster.
if [ "$PROVIDER" != local ]; then
CNPG_NS="${OA_CNPG_NAMESPACES:-foundation-databases}"
cnpg_header=0
cnpg_head() { if [ "$cnpg_header" = 0 ]; then info "The platform CNPG Clusters: synchronous replication, archiving, failover quorum"; cnpg_header=1; fi; }
for ns in $CNPG_NS; do
  if ! CL_LIST="$(K -n "$ns" get clusters.postgresql.cnpg.io -l openaether.io/managed=true -o json 2>&1)"; then
    case "$CL_LIST" in
      *"doesn't have a resource type"*|*"no matches for kind"*|*"could not find the requested resource"*) ;;
      *) cnpg_head; unk "could not list the CNPG Clusters of ${ns} — their synchronous replication and archiving are UNCHECKED" ;;
    esac
    continue
  fi
  while IFS= read -r CL; do
    [ -n "$CL" ] || continue
    cnpg_head
    cname="$(jq -r '.metadata.name' <<<"$CL")"; cid="${ns}/${cname}"
    cinst="$(jq -r '.spec.instances // 1' <<<"$CL")"; cprim="$(jq -r '.status.currentPrimary // ""' <<<"$CL")"
    cfix="task cnpg-presync PROVIDER=${PROVIDER} ROLE=${ROLE} APPLY=1"
    declared=0
    jq -e '(.spec.postgresql.synchronous // {}) as $s | $s.method == "any" and $s.number == 1 and $s.dataDurability == "required" and $s.failoverQuorum == true' <<<"$CL" >/dev/null && declared=1
    if [ "$declared" = 0 ]; then
      bad "${cid}: spec.postgresql.synchronous is not the 0.4.0 block (any / 1 / required / failoverQuorum true): $(jq -c '.spec.postgresql.synchronous // "(none)"' <<<"$CL"). Before the apps ref moves: ${cfix}"
    fi
    carch="$(jq -r '[.status.conditions[]? | select(.type == "ContinuousArchiving") | .status] | first // "absent"' <<<"$CL")"
    case "$carch" in
      True) ok "${cid}: ContinuousArchiving True" ;;
      absent) unk "${cid}: no ContinuousArchiving condition on the Cluster — archiving is UNCHECKED" ;;
      *) bad "${cid}: ContinuousArchiving is ${carch}: WAL is not reaching the store. Read: kubectl cnpg status ${cname} -n ${ns}; a Cluster stuck after the 0.4.0 move: docs/upgrade.md (break-glass R1, R2). Then: task backup-verify" ;;
    esac
    if [ -z "$cprim" ]; then
      unk "${cid}: no current primary in the status — synchronous replication is UNCHECKED"
    elif ! SNAMES="$(K -n "$ns" exec "$cprim" -c postgres -- psql -U postgres -Atc "show synchronous_standby_names" 2>/dev/null)"; then
      unk "${cid}: could not ask the primary ${cprim} for synchronous_standby_names — UNCHECKED"
    elif ! REPL="$(K -n "$ns" exec "$cprim" -c postgres -- psql -U postgres -Atc "select application_name, sync_state from pg_stat_replication" 2>/dev/null)"; then
      unk "${cid}: could not read pg_stat_replication on ${cprim} — UNCHECKED"
    else
      nsync="$(grep -cE '\|(quorum|sync)$' <<<"$REPL" || true)"
      if [ -n "$SNAMES" ]; then
        if [ "$declared" = 0 ]; then
          bad "${cid}: the primary runs synchronous replication (synchronous_standby_names is set) but the spec does not declare the 0.4.0 block — the running state and the declaration disagree. ${cfix}"
        elif [ "$nsync" -ge $((cinst - 1)) ]; then
          ok "${cid}: synchronous_standby_names set on ${cprim}, ${nsync} replica(s) quorum/sync"
        else
          bad "${cid}: synchronous_standby_names is set but only ${nsync} of $((cinst - 1)) replica(s) are quorum/sync in pg_stat_replication. Read: kubectl cnpg status ${cname} -n ${ns}"
        fi
      elif [ "$declared" = 1 ]; then
        bad "${cid}: the spec asks for synchronous replication and synchronous_standby_names is EMPTY on ${cprim} (the lost reload, cloudnative-pg#11627). Reload: kubectl -n ${ns} exec <pod> -c postgres -- psql -U postgres -Atc \"select pg_reload_conf()\" on every instance; docs/upgrade.md (break-glass R1, R2)"
      fi
    fi
    if FQ="$(K -n "$ns" get failoverquorums.postgresql.cnpg.io "$cname" -o name 2>&1)"; then
      if [ "$declared" = 1 ]; then ok "${cid}: the FailoverQuorum object exists"
      else bad "${cid}: a FailoverQuorum object exists but the spec does not declare failoverQuorum true — the running state and the declaration disagree"; fi
    else
      case "$FQ" in
        *NotFound*|*"not found"*) [ "$declared" = 0 ] || bad "${cid}: the spec declares failoverQuorum true and the FailoverQuorum object does not exist. Read: kubectl cnpg status ${cname} -n ${ns}; the operator creates it at its next reconcile (a single 'not found' line right after the patch is normal)" ;;
        *) unk "${cid}: could not read the FailoverQuorum object — UNCHECKED" ;;
      esac
    fi
  done < <(jq -c '.items[] | select(((.metadata.labels["openaether.io/db-profile"] // "") == "") and (.metadata.name | startswith("rt-") | not))' <<<"$CL_LIST")
done
fi

# --- The fleet runs the image the config names ----------------------------------
#
# The version tag is not the image. The schematic carries the system extensions,
# and until 2026-08-19 nothing compared it: a fleet ran the schematic whose
# qemu-guest-agent never started on OVH — so nodes never reached Stage=Running,
# never dropped the upgrade fallback, and reverted on their next reboot — while
# its own config named the fixed one. Every gate said "already runs v1.13.8".
#
# `warn`, not `unk`, when no tunnel answers: `task cluster-verify` is legitimately run
# without tunnels, and a check that turns the normal case red is the defect this
# file keeps catching in others. A mismatch actually READ is a hard failure.
# The local Docker cluster has no Image Factory schematic at all — asserting one
# there would be a guard that cannot pass where it runs, which gets muted, and a
# muted guard protects nothing anywhere.
if [ "$PROVIDER" != local ]; then
info "The fleet runs the image the config names"
WANT_SCH="$(awk '/variable "talos_installer_schematic_id"/,/^}/' \
              "$CLUSTER_DIR/variables.tf" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)" || WANT_SCH=""
if [ -z "$WANT_SCH" ]; then
  warn "no talos_installer_schematic_id pinned — nothing to compare the fleet against"
else
  TUN="127.0.0.1:$((50000 + ${TF_VAR_talos_tunnel_port_offset:-0}))"
  HAVE_SCH="$(timeout 20 talosctl get extensions -e "$TUN" -n 127.0.0.1 -o json 2>/dev/null |
              jq -s -r '.[] | select(.spec.metadata.name == "schematic") | .spec.metadata.version' 2>/dev/null | head -1)" || HAVE_SCH=""
  if [ -z "$HAVE_SCH" ]; then
    warn "could not read the running schematic (no Talos tunnel on ${TUN}) — run 'task tunnels-up PROVIDER=${PROVIDER}' to make this checkable"
  elif [ "$HAVE_SCH" = "$WANT_SCH" ]; then
    ok "the fleet runs the pinned schematic (${WANT_SCH:0:12}…)"
  else
    bad "the fleet runs schematic ${HAVE_SCH:0:12}…, the config pins ${WANT_SCH:0:12}… — the nodes do NOT carry the extensions this release ships. Roll them: task cluster-upgrade PROVIDER=${PROVIDER}"
  fi
fi
fi

# --- The workers carry the data volumes the config names (#62) -------------------
#
# worker_storage asks for Talos user volumes, LUKS2-encrypted, on each worker, and
# until now nothing read one back: a volume that was never created, or created
# without encryption, left every other check green. The node's own Talos API is
# the only witness (`talosctl get volumestatus u-<name>`), so this needs the
# tunnels: `warn` when none answers, `bad` only for a node that answered and
# does not carry the volume as configured.
worker_volume_names() { # <tfvars> — each `name = "…"` inside the worker_storage block
  awk '
    /^[[:space:]]*worker_storage[[:space:]]*=/ { on = 1 }
    on {
      line = $0; sub(/#.*/, "", line)
      o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); depth += o - c; seen = seen || o > 0
      while (match(line, /(^|[^A-Za-z0-9_])name[[:space:]]*=[[:space:]]*"[^"]+"/)) {
        v = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); print v
        line = substr(line, RSTART + RLENGTH)
      }
      if (seen && depth <= 0) exit
    }' "$1" 2>/dev/null
}

worker_volume_check() { # <volume names, one per line> — read each back from each worker
  # A worker's apid does not forward ("no request forwarding"), so each one is asked
  # through the first control plane's tunnel, naming the worker as the node.
  local ip v out checked=0 failed=0 ips TUN="127.0.0.1:$((50000 + ${TF_VAR_talos_tunnel_port_offset:-0}))"
  ips="$(K get nodes -l '!node-role.kubernetes.io/control-plane' \
           -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)"
  if [ -z "$ips" ]; then
    unk "no worker node answered — the data volumes are UNCHECKED"; return
  fi
  for ip in $ips; do
    if ! timeout 20 talosctl get nodename -e "$TUN" -n "$ip" >/dev/null 2>&1; then
      warn "worker ${ip}: not reachable through the Talos tunnel on ${TUN} — its data volumes are unchecked (run 'task tunnels-up PROVIDER=${PROVIDER}')"
      continue
    fi
    for v in $1; do
      out="$(timeout 20 talosctl get volumestatus "u-${v}" -e "$TUN" -n "$ip" -o json 2>/dev/null |
             jq -r '.spec | "\(.phase) \(.encryptionProvider // "none")"' 2>/dev/null)" || out=""
      checked=$((checked + 1))
      case "$out" in
        "ready luks2") ;;
        "") bad "worker ${ip} has no volume u-${v}: the config asks for it and the node does not carry it"
            failed=$((failed + 1)) ;;
        *) bad "worker ${ip} volume u-${v} is '${out}', expected 'ready luks2': the data is not encrypted at rest as configured"
           failed=$((failed + 1)) ;;
      esac
    done
  done
  if [ "$checked" -gt 0 ] && [ "$failed" -eq 0 ]; then
    ok "every worker carries its data volume(s), ready and LUKS2-encrypted (${checked} read back from the nodes)"
  fi
}

if [ "$PROVIDER" != local ]; then
info "The workers' data volumes are the ones the config names"
VOLS="$(worker_volume_names "$VER_TFVARS")"
if [ -z "$VOLS" ]; then
  ok "no worker data volumes configured — nothing to read back"
else
  worker_volume_check "$VOLS"
fi
fi

# --- Encryption at rest is EFFECTIVE, not just configured (ANSSI HYG M37/M38 evidence) -------
#
# The machine config asks for LUKS2 on STATE and EPHEMERAL and a secretbox key for the etcd
# Secrets, and until now only the worker user volumes were read back. Each node's own Talos
# API is the witness for the disks, the apiserver's own command line for etcd.
system_volume_check() { # <node ips, one per line> — STATE and EPHEMERAL must be ready and luks2
  local ip v out checked=0 failed=0 TUN="127.0.0.1:$((50000 + ${TF_VAR_talos_tunnel_port_offset:-0}))"
  if [ -z "$1" ]; then
    unk "no node answered — the encryption of STATE and EPHEMERAL is UNCHECKED"; return
  fi
  for ip in $1; do
    if ! timeout 20 talosctl get nodename -e "$TUN" -n "$ip" >/dev/null 2>&1; then
      warn "node ${ip}: not reachable through the Talos tunnel on ${TUN} — its STATE/EPHEMERAL encryption is unchecked (run 'task tunnels-up PROVIDER=${PROVIDER}')"
      continue
    fi
    for v in STATE EPHEMERAL; do
      out="$(timeout 20 talosctl get volumestatus "$v" -e "$TUN" -n "$ip" -o json 2>/dev/null |
             jq -r '.spec | "\(.phase) \(.encryptionProvider // "none")"' 2>/dev/null)" || out=""
      case "$out" in
        "ready luks2") checked=$((checked + 1)) ;;
        # No answer is not "unencrypted": the resource id is the partition label, taken from Talos' source, and
        # this is the first time anything reads it. Unknown, never green and never a false red.
        "") unk "node ${ip}: no volume status '${v}' — its encryption is UNCHECKED"; failed=$((failed + 1)) ;;
        *) bad "node ${ip} volume ${v} is '${out}', expected 'ready luks2': the node's disk is not encrypted at rest as configured"
           failed=$((failed + 1)) ;;
      esac
    done
  done
  if [ "$checked" -gt 0 ] && [ "$failed" -eq 0 ]; then
    ok "STATE and EPHEMERAL are ready and LUKS2-encrypted (${checked} volume(s) read back from the nodes)"
  fi
}

# The flag is how the apiserver is told to encrypt Secrets in etcd; Talos writes it from
# cluster.secretboxEncryptionSecret. Its presence proves encryption is on, not which cipher.
apiserver_encryption_check() {
  local args
  args="$(K -n kube-system get pods -l component=kube-apiserver \
            -o jsonpath='{range .items[*]}{.spec.containers[0].command}{.spec.containers[0].args}{"\n"}{end}' 2>/dev/null)" || args=""
  if [ -z "$args" ]; then
    unk "could not read the kube-apiserver command line — Secrets encryption in etcd is UNCHECKED"
  elif grep -q -- '--encryption-provider-config=' <<<"$args"; then
    ok "kube-apiserver runs with --encryption-provider-config (Secrets encrypted in etcd)"
  else
    bad "kube-apiserver has no --encryption-provider-config: Secrets are stored in etcd in clear"
  fi
}

# The Docker cluster has no disks and its apiserver is not a Talos static pod run from a machine
# config in the same way; asserting either there would be a guard that cannot pass where it runs.
if [ "$PROVIDER" != local ]; then
info "Encryption at rest is effective"
system_volume_check "$(K get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)"
apiserver_encryption_check
fi

info "The state is backed up"

if [ "$PROVIDER" = local ]; then
  ok "local cluster: no remote state, nothing to replicate (backup_enabled=false)"
else
  # The claim is not "the backup step ran": it is that the object EXISTS in the
  # replica store, and that the replica is not on the primary's cloud — a copy
  # on the cloud that just failed is not a backup.
  # The shared helpers, not a local copy: this file used to build the bucket name
  # inline, so any change to the convention — the bucket_suffix, for one — would
  # leave it probing the old name and reporting a missing backup that is there
  # under another one. `tfv` takes <file> <key>; common.sh is sourced at the top.
  TFVARS="$CLUSTER_DIR/envs/${ROLE}-${PROVIDER}.tfvars"
  CN="$(tfv "$TFVARS" cluster_name)"; ENVN="$(tfv "$TFVARS" environment)"
  PRIM_EP="$(tfv "$TFVARS" s3_primary_endpoint)"; REPL_EP="$(tfv "$TFVARS" s3_replica_endpoint)"
  BUCKET="$(oa_state_bucket "$(oa_project "$CN" "$(tfv "$TFVARS" bucket_suffix)")" "$PROVIDER" "$ENVN")-backup"
  if [ -z "$CN" ] || [ -z "$ENVN" ]; then
    unk "could not read cluster_name/environment from ${TFVARS##*/} — cannot name the backup bucket"
  # BACKUP credentials, not primary. The bucket being listed is the replica, and
  # in production the replica is on a different provider's account — so reading
  # it with the cluster provider's keys fails precisely when the release's
  # cross-provider objective is satisfied.
  # The listing is captured, then grepped: `aws ... | grep -q` exits on the first match, aws gets SIGPIPE while it
  # still writes the next object, and pipefail then reads the whole check as "no replica" (measured on a replica
  # with generations: 2 of 6 runs failed).
  elif REPL_LIST="$(AWS_ACCESS_KEY_ID="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak backup "${REPL_EP:-$PRIM_EP}")" \
       AWS_SECRET_ACCESS_KEY="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk backup "${REPL_EP:-$PRIM_EP}")" \
       timeout 90 aws s3 ls "s3://${BUCKET}/" --endpoint-url "${REPL_EP:-$PRIM_EP}" 2>/dev/null)" && grep -q 'tfstate' <<<"$REPL_LIST"; then
    ok "a tfstate replica exists in ${BUCKET}"
    # …and OPEN it. Listing a filename proved nothing about its contents, and
    # "the state is encrypted" was declared in backend.tf, implemented, and never
    # once verified against a stored object.
    #
    # The predicate has to distinguish two JSON documents, and a careless one gets
    # this backwards: an ENCRYPTED state is an envelope that also carries `serial`
    # and `lineage`, so matching on those calls ciphertext plaintext. What only a
    # plaintext state has is `terraform_version` and `resources`; what only an
    # encrypted one has is `encrypted_data`. Measured on a live Scaleway cluster
    # 2026-08-17: the envelope's keys are encrypted_data, encryption_version,
    # lineage, meta, serial — and 4 KB is far more than enough to see them.
    HEAD="$(AWS_ACCESS_KEY_ID="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak backup "${REPL_EP:-$PRIM_EP}")" \
            AWS_SECRET_ACCESS_KEY="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk backup "${REPL_EP:-$PRIM_EP}")" \
            timeout 90 aws s3api get-object --bucket "$BUCKET" --key "${CN}.tfstate" \
              --range bytes=0-4095 --endpoint-url "${REPL_EP:-$PRIM_EP}" /dev/stdout 2>/dev/null)"
    if [ -z "$HEAD" ]; then
      unk "could not read the first bytes of ${CN}.tfstate — the encryption claim is UNCHECKED"
    elif grep -qE '"(terraform_version|resources)"' <<<"$HEAD"; then
      bad "the stored state is PLAINTEXT — anyone with read access to ${BUCKET} has the cluster"
    elif grep -q '"encrypted_data"' <<<"$HEAD"; then
      ok "the stored state is ciphertext (OpenTofu encrypted envelope)"
    else
      bad "the stored state is neither recognisably encrypted nor plaintext — refusing to guess"
    fi
  else
    bad "no tfstate object found in ${BUCKET} — the backup claim is unproven"
  fi
  # Cross-provider is a PRODUCTION rule, and variables.tf says so in as many
  # words ("Prod: a different provider"). Failing a dev cluster for it is a
  # false red — the mirror of the false greens this repository keeps meeting,
  # and just as useless: an assertion that cannot pass where it runs gets muted,
  # and then it protects nothing anywhere. Same predicate as cluster-up's
  # refusal (ensure-buckets.sh --preflight), which only sees new clusters.
  WHY="$(oa_replica_colocated "$PRIM_EP" "$REPL_EP")"
  if [ -z "$WHY" ]; then
    ok "the replica store is elsewhere: another provider, or another endpoint for an S3 this repo cannot name"
  elif [ "$ENVN" = prod ]; then
    bad "prod: ${WHY} — a copy on the cloud that just failed is not a backup"
  else
    printf '  \033[33m~\033[0m %s\n' "${ENVN}: ${WHY} — fine here, but prod must cross providers"
  fi
fi

echo
printf '%s passed, %s failed, %s could not be checked\n' "$PASS" "$FAIL" "$UNKNOWN"
if [ "$FAIL" -eq 0 ] && [ "$UNKNOWN" -eq 0 ]; then
  printf '✓ %s/%s: pure-infra cluster verified against the cluster, not the state\n' "$PROVIDER" "$ROLE"
  exit 0
fi
if [ "$FAIL" -gt 0 ]; then
  printf '✗ %s/%s: %s assertion(s) FAILED — the cluster is not what this release promises.\n' "$PROVIDER" "$ROLE" "$FAIL" >&2
else
  # The distinction that matters at 2am: nothing is known to be wrong.
  printf '✗ %s/%s: nothing failed, but %s check(s) could not be performed, so this run\n' "$PROVIDER" "$ROLE" "$UNKNOWN" >&2
  printf '  proves less than it looks. Usually the S3 credentials: run it as\n' >&2
  printf '    task cluster-verify PROVIDER=%s ROLE=%s\n' "$PROVIDER" "$ROLE" >&2
  printf '  rather than calling this script directly — the Taskfile derives AWS_* per provider.\n' >&2
fi
exit 1
