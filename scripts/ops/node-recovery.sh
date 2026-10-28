#!/usr/bin/env bash
# OpenAether - what to do about a node that stopped answering (0.4.0 M4). An OPERATOR command, never a controller.
#
# The management cluster is built by OpenTofu and nothing in the cluster heals its nodes (what Cluster API manages stays
# Cluster API's). The alerts NodeUnreachable and NodeNotReady say a person has to act; this is what they run:
#
#   state    <provider> --node=NAME   read-only: what the provider says about the machine, whether the kubelet and the
#                                     Talos port answer, the etcd membership, and the ONE next command (VERDICT=...)
#   recover  <provider> --node=NAME   the machine runs at the provider but the node is silent (OVH shows it ACTIVE: infra
#                                     #49, #371): a provider HARD reboot, bounded wait. Destroys nothing.
#   replace  <provider> --node=NAME   the machine is stopped, in error or gone, or the hard reboot did not bring it back:
#                                     rolling-replace.sh --dead (survey of the survivors, etcd member removed for a control
#                                     plane, Node object deleted, the same two tofu applies as `task cluster-roll`), then
#                                     checks. One node. Wipes the node's system disk and its local-path data.
#
# Flags: --role=management|workload (default management), --ip=ADDR (private address, when the Node object is gone),
#        --yes (no prompt), --dry-run (replace: print the plan of the roll and stop), --even-if-running (replace a
#        machine the provider calls running: only after `recover` failed), --clean (replace: after the checks, drop the
#        volumes the old disk left behind, see below).
# After a replacement the pods whose local-path volume was pinned to the old disk (CNPG instances, an OpenBao member, loki-0,
# vmselect-0, vmstorage: lab 21) do not start by themselves. replace then runs scripts/ops/replaced-node-cleanup.py: it lists them
# and PRINTS the exact kubectl commands; with --clean it runs them, for the known safe cases only (a healthy primary or a raft
# majority or another Ready replica must remain) and refuses the rest.
# Needs the same as cluster-roll: tofu init done, the provider credentials, open Talos tunnels, ./talosconfig, ./kubeconfig,
# run from infrastructure/opentofu/cluster. NODE_PROVIDER_CMD overrides node-provider.py (the tests).
#
# Not drilled on a cluster: see docs/resilience.md for the lab that proves it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"

usage() { echo "usage: $0 <state|recover|replace> <ovh|scaleway|outscale|proxmox> --node=NAME [--ip=ADDR] [--role=R] [--yes] [--dry-run] [--even-if-running] [--clean]" >&2; exit 2; }
[[ $# -ge 2 ]] || usage
CMD="$1"; PROVIDER="$2"; shift 2
case "$CMD" in state | recover | replace) ;; *) usage ;; esac
NODE=""; ONLY_IP=""; ROLE="management"; ASSUME_YES=0; DRY_RUN=0; EVEN_RUNNING=0; CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --node=*) NODE="${arg#--node=}" ;;
    --ip=*) ONLY_IP="${arg#--ip=}" ;;
    --role=*) ROLE="${arg#--role=}" ;;
    --yes | -y) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --even-if-running) EVEN_RUNNING=1 ;;
    --clean) CLEAN=1 ;;
    *) echo "✗ unknown flag: $arg" >&2; usage ;;
  esac
done
[[ -n "$NODE" || -n "$ONLY_IP" ]] || { echo "✗ --node=NAME (or --ip=ADDR) is required: this acts on one node" >&2; exit 2; }
case "$PROVIDER" in ovh | scaleway | outscale | proxmox) ;; *) echo "✗ unknown provider: $PROVIDER" >&2; exit 2 ;; esac

info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

TFVARS="envs/${ROLE}-${PROVIDER}.tfvars"
export TALOSCONFIG="${TALOSCONFIG:-./talosconfig}"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
KCTL=(kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=20s)
NODE_PROVIDER_CMD="${NODE_PROVIDER_CMD:-python3 $HERE/node-provider.py}"
CLEANUP_CMD="${CLEANUP_CMD:-python3 $HERE/replaced-node-cleanup.py}"
RECOVER_TIMEOUT="${RECOVER_TIMEOUT:-600}"
POLL="${POLL:-10}"
for bin in tofu jq talosctl kubectl; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done
[[ -f "$TFVARS" ]] || die "tfvars not found: $TFVARS (run from infrastructure/opentofu/cluster)"

OUTPUTS="$(tofu output -json 2>/dev/null || echo '{}')"
CN="$(grep -E '^[[:space:]]*cluster_name[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//')"
ENVN="$(grep -E '^[[:space:]]*environment[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//')"
[[ -n "$CN" && -n "$ENVN" ]] || die "could not read cluster_name/environment from $TFVARS"
PREFIX="${CN}-${ENVN}"
mapfile -t CP_IPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WK_IPS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
[[ ${#CP_IPS[@]} -gt 0 ]] || die "no control_plane_private_ips in tofu output - is the infra deployed?"

# --- which node is it? The private address is the identity all providers agree on. ---------------------------------------
NODE_IP="$ONLY_IP"
if [[ -z "$NODE_IP" ]]; then
  NODE_IP="$("${KCTL[@]}" get node "$NODE" -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}" 2>/dev/null)" || NODE_IP=""
fi
[[ -n "$NODE_IP" ]] || die "cannot tell the address of ${NODE}: no Node object answers. Pass --ip=<private address> (tofu output worker_private_ips / control_plane_private_ips)."
T=""; IDX=""
for k in "${!CP_IPS[@]}"; do if [[ "${CP_IPS[$k]}" == "$NODE_IP" ]]; then T="cp"; IDX="$k"; fi; done
for k in "${!WK_IPS[@]}"; do if [[ "${WK_IPS[$k]}" == "$NODE_IP" ]]; then T="worker"; IDX="$k"; fi; done
[[ -n "$T" ]] || die "no node of this state has the address ${NODE_IP} - wrong PROVIDER or ROLE?"
INSTANCE="${PREFIX}-$([[ $T == cp ]] && echo cp || echo worker)-${IDX}"
TUNNEL_OFFSET="$(oa_tunnel_offset)" || exit 1
if [[ $T == cp ]]; then TPORT=$((50000 + TUNNEL_OFFSET + IDX)); else TPORT=$((50100 + TUNNEL_OFFSET + IDX)); fi
NAME_FOR_K8S="${NODE:-$INSTANCE}"
ROLE_ARG=""
if [[ $ROLE != management ]]; then ROLE_ARG=" ROLE=${ROLE}"; fi
TASKARGS="PROVIDER=${PROVIDER}${ROLE_ARG} NODE=${NAME_FOR_K8S}"

# --- observations --------------------------------------------------------------------------------------------------------
provider_state() { # prints the state word; "unknown" when the provider did not answer
  local out
  if out="$($NODE_PROVIDER_CMD state "$PROVIDER" --name "$INSTANCE" --ip "$NODE_IP" 2>/dev/null)"; then
    jq -r '.state // "unknown"' <<<"$out" 2>/dev/null || echo unknown
  else
    echo unknown
  fi
}
kubelet_state() { # Ready | NotReady | Unknown | absent
  local st
  if ! "${KCTL[@]}" get node "$NAME_FOR_K8S" >/dev/null 2>&1; then echo absent; return; fi
  st="$("${KCTL[@]}" get node "$NAME_FOR_K8S" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  case "$st" in True) echo Ready ;; False) echo NotReady ;; *) echo Unknown ;; esac
}
talos_answers() { oa_talos_endpoint_ok 127.0.0.1 "$TPORT"; }
# The operator's own path (tunnel, bastion) must be known good BEFORE a node is called dead: a tunnel that is down makes every
# node look dead, and a hard reboot of a healthy node is the cost of not checking.
other_node_reachable() {
  local k port
  for k in "${!CP_IPS[@]}"; do
    [[ "$T" == cp && "$k" == "$IDX" ]] && continue
    port=$((50000 + TUNNEL_OFFSET + k))
    oa_talos_endpoint_ok 127.0.0.1 "$port" && return 0
  done
  for k in "${!WK_IPS[@]}"; do
    [[ "$T" == worker && "$k" == "$IDX" ]] && continue
    port=$((50100 + TUNNEL_OFFSET + k))
    oa_talos_endpoint_ok 127.0.0.1 "$port" && return 0
  done
  return 1
}

PSTATE="$(provider_state)"
KSTATE="$(kubelet_state)"
if talos_answers; then TSTATE="answers"; else TSTATE="silent"; fi

verdict() {
  if [[ "$KSTATE" == Ready ]]; then echo healthy; return; fi
  case "$PSTATE" in
    running) echo recover ;;
    stopped | error | absent) echo replace ;;
    transition) echo wait ;;
    *) echo unknown ;;
  esac
}
VERDICT="$(verdict)"

report() {
  hr_() { printf -- '─%.0s' {1..70}; printf '\n'; }
  hr_
  info "Node ${NAME_FOR_K8S}  (${T} ${IDX}, ${NODE_IP}, instance ${INSTANCE}, ${PROVIDER})"
  printf '  provider says : %s\n  kubelet       : %s\n  talos port    : %s (127.0.0.1:%s)\n' "$PSTATE" "$KSTATE" "$TSTATE" "$TPORT"
  case "$VERDICT" in
    healthy) ok "the node is Ready - nothing to recover or replace. (To roll the cluster: task cluster-roll.)" ;;
    recover)
      warn "the machine runs at the provider but the node is not Ready: the 'ACTIVE but unreachable' shape (infra #371)."
      echo "  next: task cluster-node-recover ${TASKARGS}"
      echo "  Read the serial console first if you want to know why: a hard reboot erases that trace." ;;
    replace)
      warn "the machine is ${PSTATE} at the provider."
      echo "  next: task cluster-replace-node ${TASKARGS}"
      if [[ $T == cp ]]; then echo "  (a control plane: needs a quorum of the others, checked first; if two of three are gone: task dr-restore-plan PROVIDER=${PROVIDER}${ROLE_ARG})"; fi ;;
    wait) info "the provider reports an operation in progress (reboot, build): wait, then run state again." ;;
    *) warn "the provider did not answer: nothing is decided from it. Check the credentials (source .env.sh) and the provider status page." ;;
  esac
  echo "VERDICT=${VERDICT}"
}

case "$CMD" in
  state)
    report
    exit 0 ;;

  recover)
    report
    [[ "$PSTATE" == running ]] || die "the provider says '${PSTATE}', not running: a hard reboot is for a machine that runs and does not answer. Use: task cluster-replace-node ${TASKARGS} if it is gone."
    [[ "$KSTATE" != Ready ]] || die "the node is Ready: nothing to recover."
    # Early fail: is the silence the NODE's, or the path to it? Tunnels down make every node look dead.
    if ! other_node_reachable; then
      die "no other node answers through the Talos tunnels either: the tunnels (or the bastion) are the likely fault, not ${NAME_FOR_K8S}. Nothing was rebooted. Reopen them: task tunnels-up PROVIDER=${PROVIDER} KEY=<your key>, then run state again."
    fi
    if [[ $ASSUME_YES -eq 0 ]]; then
      warn "This sends a provider HARD reboot to ${INSTANCE}: no clean shutdown, and the serial console trace of the failure is lost."
      read -rp "Proceed? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"
    fi
    info "hard reboot of ${INSTANCE} through the ${PROVIDER} API…"
    $NODE_PROVIDER_CMD hard-reboot "$PROVIDER" --name "$INSTANCE" --ip "$NODE_IP" >/dev/null \
      || die "the provider refused or did not answer the hard reboot. Nothing else was done."
    deadline=$((SECONDS + RECOVER_TIMEOUT))
    info "waiting up to ${RECOVER_TIMEOUT}s for the Talos port and the node…"
    while (( SECONDS < deadline )); do
      if talos_answers && [[ "$(kubelet_state)" == Ready ]]; then
        ok "${NAME_FOR_K8S} answers and is Ready again"
        echo "  Rerun whatever was interrupted (for OVH, the cluster-up that stopped at this node)."
        exit 0
      fi
      sleep "$POLL"
    done
    warn "${NAME_FOR_K8S} still does not answer ${RECOVER_TIMEOUT}s after the hard reboot (talos: $(talos_answers && echo answers || echo silent), kubelet: $(kubelet_state))."
    die "recover failed. The next step is a replacement: task cluster-replace-node ${TASKARGS}" ;;

  replace)
    report
    if [[ "$KSTATE" == Ready ]]; then die "the node is Ready: this is not a dead node. To replace healthy nodes (an image change): task cluster-roll."; fi
    if [[ "$PSTATE" == running && $EVEN_RUNNING -eq 0 ]]; then
      die "the provider says ${INSTANCE} is running: try task cluster-node-recover ${TASKARGS} first. If the hard reboot already failed, add --even-if-running."
    fi
    [[ "$PSTATE" != unknown ]] || [[ $EVEN_RUNNING -eq 1 ]] \
      || die "the provider did not answer, so a dead machine is not established. Fix the credentials, or add --even-if-running if you know it is gone."
    if ! other_node_reachable && [[ "$PSTATE" == running || "$PSTATE" == unknown ]]; then
      die "no other node answers through the tunnels: the path to the cluster is the likely fault. Nothing was changed. task tunnels-up PROVIDER=${PROVIDER} KEY=<your key>."
    fi
    flags=(--role="$ROLE" --dead --node="$NAME_FOR_K8S" --ip="$NODE_IP")
    [[ $DRY_RUN -eq 0 ]] || flags+=(--dry-run)
    [[ $ASSUME_YES -eq 0 ]] || flags+=(--yes)
    scope=--workers-only; [[ $T == cp ]] && scope=--cp-only
    "$HERE/rolling-replace.sh" "$PROVIDER" "$scope" "${flags[@]}"
    [[ $DRY_RUN -eq 0 ]] || exit 0
    # --- checks after the replacement ---
    fail=0
    [[ "$(kubelet_state)" == Ready ]] && ok "${NAME_FOR_K8S} is Ready" || { warn "${NAME_FOR_K8S} is not Ready"; fail=1; }
    notrunning="$("${KCTL[@]}" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | head -20 || true)"
    if [[ -n "$notrunning" ]]; then
      warn "pods that are not Running yet (a local-path volume pinned to the old disk keeps its pod Pending until the data is rebuilt):"
      printf '%s\n' "$notrunning" | sed 's/^/    /' >&2
      echo "  The volumes the old disk left behind are listed below (a CNPG instance, an OpenBao member, loki-0, vmselect-0 do not start" >&2
      echo "  by themselves on an empty directory: lab 21)." >&2
    else
      ok "every pod is Running or finished"
    fi
    # The pods the other nodes took while this one was gone stay there (lab 27 part C, E4): critical ones back, one per node.
    REBALANCE_CMD="${REBALANCE_CMD:-python3 $HERE/cluster-rebalance.py}"
    # shellcheck disable=SC2086  # the command line is meant to split (the tests replace it)
    KUBECTL="kubectl --kubeconfig $KUBECONFIG_FILE --request-timeout=30s" $REBALANCE_CMD --apply \
      || warn "critical pods still share a node: run  task cluster-rebalance PROVIDER=${PROVIDER} APPLY=1  (cluster-verify fails on it)"
    # The pods above wait for a volume of the old disk: list them, print the commands, run them only with --clean.
    clean_flag=(); [[ $CLEAN -eq 0 ]] || clean_flag=(--clean)
    cleanup_rc=0
    KUBECTL="kubectl --kubeconfig $KUBECONFIG_FILE --request-timeout=30s" $CLEANUP_CMD --node "$NAME_FOR_K8S" "${clean_flag[@]}" || cleanup_rc=$?
    if [[ $cleanup_rc -ne 0 ]]; then warn "volumes of the old disk remain that were not cleaned (see above): look at them before anything else."; fail=1; fi
    [[ $CLEAN -eq 1 ]] || echo "  To drop the safe ones: task cluster-replaced-node-cleanup NODE=${NAME_FOR_K8S} -- --clean   (it refuses a primary of record and any workload that would be left without a healthy replica)"
    (( fail == 0 )) || exit 1
    ok "Replacement of ${NAME_FOR_K8S} done. Verify: task cluster-verify PROVIDER=${PROVIDER}${ROLE_ARG}" ;;
esac
