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
# balancer" are the product decision for 1.0.0, and a decision nothing checks is
# a decision that quietly reverts — this repository has watched that happen.
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
    ok "${got_cp} control planes, matching the state — HA"
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

info "The floor is the floor — what 1.0.0 says is NOT there"

# Not cosmetic. deploy_flux defaults to false; if something re-enables it the
# cluster silently stops being the thing this release validated.
if K get ns flux-system >/dev/null 2>&1; then
  bad "flux-system exists — this is not a pure-infra cluster (deploy_flux?)"
else
  ok "no flux-system namespace — Talos and Cilium, as scoped"
fi

if [ "$PROVIDER" != local ]; then
  # `tofu output` failing and `tofu output` saying N/A are DIFFERENT ANSWERS, and
  # this used to green on both — an uninitialised backend, missing credentials or
  # a timeout all produce an empty string, which the old `${APP_LB:-N/A}` read as
  # "no load balancer". From a cold shell it could only ever pass. Capture the
  # exit code and treat a failed question as unanswered, never as reassurance.
  if APP_LB="$(cd "$CLUSTER_DIR" && timeout 60 tofu output -raw app_lb_ip 2>/dev/null)"; then
    case "$APP_LB" in
      N/A | "" | null) ok "no application load balancer (deploy_app_lb=false)" ;;
      *) bad "an application load balancer exists and is billed, pointing at Gateway NodePorts nothing serves" ;;
    esac
  else
    unk "could not read app_lb_ip (is the backend initialised, are the S3 credentials exported?) — the absence of an app LB is UNCHECKED"
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

VER_TFVARS="$CLUSTER_DIR/envs/${ROLE}-${PROVIDER}.tfvars"
version_check "Talos"      '.status.nodeInfo.osImage'        talos_version
version_check "Kubernetes" '.status.nodeInfo.kubeletVersion' kubernetes_version

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
  elif AWS_ACCESS_KEY_ID="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak backup "${REPL_EP:-$PRIM_EP}")" \
       AWS_SECRET_ACCESS_KEY="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk backup "${REPL_EP:-$PRIM_EP}")" \
       timeout 90 aws s3 ls "s3://${BUCKET}/" --endpoint-url "${REPL_EP:-$PRIM_EP}" 2>/dev/null | grep -q 'tfstate'; then
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
