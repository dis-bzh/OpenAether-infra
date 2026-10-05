#!/usr/bin/env bash
# OpenAether — rolling node replacement (zero-downtime ForceNew apply)
#
# The Talos image changes what a node must boot, and a plain `tofu apply` acts on
# every node AT ONCE → the 3 control planes go together → etcd loses quorum. This
# script does one node at a time: cordon+drain → targeted apply → wait for
# etcd/Longhorn → uncordon. Not for a node size change: an in-place update of
# every node that the roll refuses to mix in (foreign_changes); see docs/upgrade.md.
#
# Each node takes TWO applies: the instance first, then its Talos config once the
# new VM exists. The graph does not order those — modules/talos reads each node's
# address from IPAM, not from the instance — so in a single apply tofu configured
# the OLD VM a second before destroying it, and the replacement came up in
# maintenance mode. Every "kubelet not healthy after 600s" traced back to that.
#
# Before each node it PLANS and counts what would be destroyed, and refuses if
# that exceeds the resources it targets. "One node at a time" used to be an
# intention nothing checked: on 2026-08-12 one extra -target pulled a whole
# provider module in and a per-node apply replaced all three control planes
# together. The count is now the check.
#
# Four non-obvious points:
#   * `-replace` on the INSTANCE is ESSENTIAL, and `-target` is not enough:
#     -target narrows the plan, it forces nothing. Whether an image change is
#     ForceNew is provider-specific — true on Scaleway, false on OpenStack,
#     where image_id updates in place. Without the explicit replace, a Talos
#     version bump on OVH rewrote the attribute and left the VM booted on the
#     old image: state said v1.13.8, every node reported v1.13.7 (2026-08-12).
#   * `-replace` on talos_machine_configuration_apply is ESSENTIAL — it never
#     references the instance ID, so a replaced VM yields no diff and would stay
#     in maintenance mode, unconfigured.
#   * The target list EXCLUDES the data-volume resources (they must survive) but
#     INCLUDES the attach/link ones (they point at the old instance ID).
#
# Order: workers first, then control planes strictly one at a time, gated on
# etcd back to 3/3. Stops on the first failed gate.
#
# ⚠️ Exercised live on Scaleway, OVH and Outscale (--upgrade on all three;
# replacement only on Scaleway). Never on Proxmox. On Proxmox
# the worker data disk is inline on the VM: replacing a worker WIPES it and
# Longhorn rebuilds from the surviving replicas — check they are healthy first.
#
# Usage: rolling-replace.sh <provider> [--workers-only|--cp-only] [--upgrade]
#                          [--cp-order=leader-last|index|leader-first] [--dry-run] [--yes]
#   --upgrade: `talosctl upgrade` in place (version changes) instead of
#   replacing the VM. Reads the target from talos_version in the tfvars.
#   --cp-order: control-plane order, default leader-last (the etcd leader rolled last, after a
#   hand-off). The other two are for the #42 experiment only: no hand-off, an election is forced.
#   Needs: tofu init, AWS_* creds, open Talos tunnels, ./talosconfig + ./kubeconfig.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --- args --------------------------------------------------------------------
unset PLAN_ASSERT   # a hook of the shrink, not something the environment may set
PROVIDER="${1:-scaleway}"
shift || true
SCOPE="all"        # all | workers | cp
DRY_RUN=0
ASSUME_YES=0
UPGRADE=0         # --upgrade: in-place `talosctl upgrade`, no VM replacement
CP_ORDER="leader-last"  # --cp-order=: see cp_roll_order in lib/roll-gates.sh
# The role used to be the literal "management", here and in the Taskfile, while
# `task cluster-roll` declared a ROLE variable nothing read. So `cluster-upgrade
# ROLE=workload` applied the workload tfvars in both its phases and then rolled
# against the MANAGEMENT state. Defaulted, so every existing caller is unchanged.
ROLE="management"
# `--role=x`, one token: the loop below is a `for` over "$@" and cannot consume a
# following word. Splitting it into a while/shift parser to gain a space would
# rewrite the argument handling of every other flag for no benefit.
for arg in "$@"; do
  case "$arg" in
    --workers-only) SCOPE="workers" ;;
    --cp-only)      SCOPE="cp" ;;
    --dry-run)      DRY_RUN=1 ;;
    --upgrade)      UPGRADE=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --role=*)       ROLE="${arg#--role=}" ;;
    --cp-order=*)   CP_ORDER="${arg#--cp-order=}" ;;
    *) echo "✗ unknown flag: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$ROLE" ] || { echo "✗ --role= given with no value" >&2; exit 2; }
case "$CP_ORDER" in
  leader-last) ;;
  index|leader-first)
    echo "⚠ --cp-order=${CP_ORDER}: experiment order (#42), the etcd leader is not handed over before it goes." >&2 ;;
  *) echo "✗ --cp-order must be leader-last, index or leader-first (got '${CP_ORDER}')" >&2; exit 2 ;;
esac

# Provider → module name in cluster/main.tf (junction modules, count-gated).
case "$PROVIDER" in
  scaleway) MOD="scw" ;;
  ovh)      MOD="ovh" ;;
  outscale) MOD="outscale" ;;
  proxmox)  MOD="proxmox" ;;
  *) echo "✗ unknown provider: $PROVIDER (expected scaleway|ovh|outscale|proxmox)" >&2; exit 2 ;;
esac
# --upgrade has been exercised live on all three clouds (2026-08-13); the
# REPLACEMENT path (no --upgrade) only ever on Scaleway. Warn about the one that
# is actually unproven, not about the whole script — the blanket warning
# contradicted this file's own header and taught readers to ignore it.
if [[ "$PROVIDER" != "scaleway" && "$UPGRADE" -eq 0 ]]; then
  echo "⚠ ${PROVIDER}: the node-REPLACEMENT path has never been exercised on a live" >&2
  echo "  cluster (only --upgrade has) — run --dry-run first and review the targets." >&2
fi
if [[ "$PROVIDER" == "proxmox" ]]; then
  echo "⚠ proxmox: worker data disks are inline on the VM — replacing a worker WIPES its" >&2
  echo "  Longhorn disk (rebuild from surviving replicas). Check volume health/replicas first." >&2
fi

# --- config ------------------------------------------------------------------
TFVARS="envs/${ROLE}-${PROVIDER}.tfvars"
TALOSCONFIG_FILE="${TALOSCONFIG:-./talosconfig}"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
# 300s was not enough for a database switchover, and the run continued anyway.
# A switchover is a legitimate reason to wait; a drain that never finishes is now
# fatal, so the budget has to be generous enough to tell the two apart.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-900s}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-600}"   # seconds
# Ceiling on `talosctl upgrade --wait`, which has none. A Talos node reboots in
# one to three minutes; past this we stop watching and ask the node what it runs.
UPGRADE_WATCH_TIMEOUT="${UPGRADE_WATCH_TIMEOUT:-420}"
# Reaching stage=running takes seconds. A node that never will does not in 120.
UPGRADE_CONFIRM_TIMEOUT="${UPGRADE_CONFIRM_TIMEOUT:-120}"
# Set by the INT/TERM trap and by an interrupted upgrade. Checked BETWEEN nodes:
# the node in flight finishes and returns to rotation, then the run stops. Halting
# between drain and reboot would leave the cordoned, half-upgraded node that has
# already ruined one diagnosis.
STOP_REQUESTED=0
trap 'STOP_REQUESTED=1; printf "\n⚠ stop requested — finishing the node in flight, then stopping.\n" >&2' INT TERM
ETCD_TIMEOUT="${ETCD_TIMEOUT:-300}"               # seconds
LONGHORN_TIMEOUT="${LONGHORN_TIMEOUT:-600}"       # seconds
POLL=10                                           # seconds between health polls

export TALOSCONFIG="$TALOSCONFIG_FILE"
KCTL=(kubectl --kubeconfig "$KUBECONFIG_FILE")

# The gates and helpers live in the lib so other scripts can reuse them.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/roll-gates.sh"

# --- preflight ---------------------------------------------------------------
for bin in tofu jq talosctl; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required"
done
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
[[ -f "$TFVARS" ]] || die "tfvars not found: $TFVARS (run from infrastructure/opentofu/cluster)"
[[ -f "$TALOSCONFIG_FILE" ]] || die "talosconfig not found: $TALOSCONFIG_FILE"
[[ -f "$KUBECONFIG_FILE"  ]] || die "kubeconfig not found: $KUBECONFIG_FILE"

OUTPUTS="$(tofu output -json 2>/dev/null || echo '{}')"
# Node identity prefix is "<cluster_name>-<environment>" (cluster/main.tf:249).
# Derive it from the tfvars (single source of truth) rather than guessing.
CN="$(grep -E '^[[:space:]]*cluster_name[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//')"
ENVN="$(grep -E '^[[:space:]]*environment[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//')"
[[ -n "$CN" && -n "$ENVN" ]] || die "could not read cluster_name/environment from $TFVARS"
NODE_PREFIX="${CN}-${ENVN}"

# --upgrade needs the installer image, and it must be THE ONE THE MACHINE CONFIG
# NAMES. This used to rebuild the string itself as
# `ghcr.io/siderolabs/installer:<talos_version>` — a real image, the right
# version, and no system extensions. So an upgrade reinstalled every node
# without iscsi-tools, longhorn-manager crash-looped on the missing iscsiadm and
# storage-backup-target could not apply, on a cluster whose API had not blinked
# (Scaleway, 2026-08-15). The comment here even said a Factory schematic "is not
# derivable from a version" and then derived it anyway.
# `installer_image` is now a root output, so there is one source and it is the
# config's own. TALOS_IMAGE still overrides, for a deliberate one-off.
if [[ $UPGRADE -eq 1 && -z "${TALOS_IMAGE:-}" ]]; then
  TALOS_IMAGE="$(jq -r '.installer_image.value // empty' <<<"$OUTPUTS")"
  if [[ -z "$TALOS_IMAGE" ]]; then
    TV="$(grep -E '^[[:space:]]*talos_version[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]')"
    [[ -n "$TV" ]] || die "--upgrade: no installer_image output and no talos_version in ${TFVARS}."
    die "--upgrade: the state has no installer_image output (pre-2026-08-15 apply).
  Re-run \`task infra-apply\` so the root republishes it, or pass it explicitly:
    TALOS_IMAGE=factory.talos.dev/installer/<schematic-id>:${TV}
  Do NOT fall back to ghcr.io/siderolabs/installer — it has no extensions."
  fi
fi

mapfile -t CP_IPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WK_IPS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
[[ ${#CP_IPS[@]} -gt 0 ]] || die "no control_plane_private_ips in tofu output — is the infra deployed?"

info "Cluster: ${NODE_PREFIX} on ${PROVIDER}  (${#CP_IPS[@]} CP, ${#WK_IPS[@]} workers)"
info "Scope: ${SCOPE}   dry-run: $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"

# --- talos endpoint per node (matches talos-tunnels.sh: CP 50000+i, WK 50100+i,
# both shifted by TALOS_TUNNEL_OFFSET) ---
# Talos node identity is the private IP; we reach its API via the localhost tunnel.
TUNNEL_OFFSET="$(oa_tunnel_offset)" || exit 1

# stop_here answers "was a stop asked for?" and says so once, at the only place
# it is safe to obey: before touching the next node.
stop_here() {
  (( STOP_REQUESTED == 1 )) || return 1
  warn "stopping before the next ${1}: the cluster is consistent, and the nodes not yet"
  warn "reached are still on the previous version. Re-run to continue where this left off."
  return 0
}

replace_node() { # <type: cp|worker> <index>
  local t="$1" i="$2"
  local node_name node_ip ep cfg_addr tf_t
  if [[ "$t" == "cp" ]]; then
    node_ip="${CP_IPS[$i]}"; tf_t="control_plane"
  else
    node_ip="${WK_IPS[$i]}"; tf_t="worker"
  fi
  # Ask the cluster what this node is called instead of assuming the naming
  # convention. Scaleway and OVH get their hostname from the machine config
  # (<cluster>-<env>-cp-N); on Outscale Talos keeps the platform hostname, so
  # the nodes are ip-10-0-0-53 and every `kubectl cordon` here failed on "node
  # not found" — the dry-run printed the invented names and looked fine.
  # The private IP is the one identity all providers agree on.
  node_name="$(k8s_node_for_ip "$node_ip")" \
    || die "no Kubernetes node has internal IP ${node_ip} — is the cluster the one this state describes?"
  ep="$(talos_ep "$t" "$i")"
  cfg_addr="module.talos.talos_machine_configuration_apply.${tf_t}[${i}]"

  local -a targets=()
  local addr
  while IFS= read -r addr; do targets+=("-target=${addr}"); done < <(node_targets "$tf_t" "$i")
  [[ ${#targets[@]} -gt 0 ]] \
    || die "no state resources match module.${MOD}[0].*.${tf_t}[${i}] — wrong PROVIDER, or state not initialized?"

  # -target only NARROWS the plan; it does not force anything to be replaced.
  # The header of this script assumes a Talos image change is ForceNew, which is
  # true on Scaleway and false on OpenStack: there image_id updates in place, so
  # a version bump rewrote the attribute and left the VM booted on the old image
  # — state claiming v1.13.8 while every node reported v1.13.7 (2026-08-12).
  # Name the instance and replace it explicitly. NOT the port: recreating that
  # would hand the node a new private IP, which is its identity.
  local inst_addr
  inst_addr="$(printf '%s\n' "${targets[@]#-target=}" | grep -E '\.(scaleway_instance_server|openstack_compute_instance_v2|outscale_vm|proxmox_virtual_environment_vm)\.' | head -1)"
  [[ -n "$inst_addr" ]] \
    || die "no compute instance among the targets for ${node_name} — new provider whose instance resource this script does not know?"

  # The machine config lives under module.talos, and node_targets only collects
  # module.<provider>[0].* — so -target excluded it and the -replace naming it
  # below was silently dropped: tofu said "some changes requested in the
  # configuration may have been ignored" and carried on, the fresh VM booted into
  # maintenance mode, and the health gate waited 600s for a kubelet that was
  # never coming. Seen identically on OVH and Scaleway, 2026-08-12.
  #
  # Safe to target only because cluster/main.tf no longer gives module.talos a
  # module-level depends_on over the provider modules; with it, this single line
  # pulled every instance into the plan. Check the blast radius with --dry-run
  # and a plan before trusting it on a cluster you care about.
  targets+=("-target=${cfg_addr}")

  # And the port-ready guard the config apply depends on. Its triggers_replace is
  # the node ENDPOINT, which is unchanged by a replacement (same private IP), so
  # it is never re-created on its own — and being in module.talos it was outside
  # -target too. Without it the config apply fired against a node that had not
  # finished booting and reported "Creation complete after 0s" having done
  # nothing; the health gate then waited 600s for a kubelet that never started.
  # Absent from state when skip_port_ready_wait is set, hence the lookup.
  local guard_addr=""
  if tofu state list 2>/dev/null | grep -qxF "module.talos.terraform_data.talos_port_ready_${tf_t}[${i}]"; then
    guard_addr="module.talos.terraform_data.talos_port_ready_${tf_t}[${i}]"
    targets+=("-target=${guard_addr}")
  fi

  # Split for the two applies below: the instance alone, then the config.
  local -a infra_targets=() cfg_targets=(-target="$cfg_addr" -replace="$cfg_addr")
  local cfg_max=1 tgt
  for tgt in "${targets[@]}"; do
    [[ "$tgt" == "-target=${cfg_addr}" || "$tgt" == "-target=${guard_addr}" ]] || infra_targets+=("$tgt")
  done
  if [[ -n "$guard_addr" ]]; then
    cfg_targets+=(-target="$guard_addr" -replace="$guard_addr"); cfg_max=2
  fi

  hr
  info "Node ${node_name}  (ip ${node_ip}, talos ${ep})"

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $UPGRADE -eq 1 ]]; then
      echo "  would: talosctl upgrade -e ${ep} -n ${node_ip} --image ${TALOS_IMAGE} --wait"
      echo "         (Talos cordons and drains the node itself, and refuses a CP that would cost etcd its quorum)"
      echo "  would: wait Talos health @ ${ep}, node Ready, $( [[ $t == cp ]] && echo 'etcd 3/3, ' )Longhorn healthy"
      return 0
    fi
    echo "  would: kubectl cordon ${node_name}"
    echo "  would: kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT}"
    [[ $t == cp ]] && echo "  would: talosctl etcd remove-member ${node_name} (via a healthy peer CP)"
    echo "  would: tofu plan -out=<instance.tfplan> ${infra_targets[*]} -replace='${inst_addr}' \\"
    echo "                    -var-file='${TFVARS}' -var talos_bootstrap=true"
    echo "         count its deletes from 'tofu show -json', then: tofu apply <instance.tfplan>"
    echo "  would: tofu plan -out=<config.tfplan> ${cfg_targets[*]} \\"
    echo "                    -var-file='${TFVARS}' -var talos_bootstrap=true"
    echo "         count its deletes from 'tofu show -json', then: tofu apply <config.tfplan>"
    echo "  would: wait Talos health @ ${ep}, node Ready, $( [[ $t == cp ]] && echo 'etcd 3/3, ' )Longhorn healthy"
    echo "  would: kubectl uncordon ${node_name}"
    return 0
  fi

  # ── in-place upgrade: what Talos actually supports ──────────────────────────
  # `talosctl upgrade` writes the new system partition and reboots into it. The
  # node keeps its identity, its disk and its etcd membership, so none of the
  # replacement machinery below applies: no config to re-apply, no maintenance
  # mode, no stale etcd member to evict, and no orphan Kubernetes node object
  # from a kubelet that registered under a temporary hostname.
  #
  # Talos cordons and drains the node itself (--drain, on by default) and
  # refuses to upgrade a control plane if that would cost etcd its quorum. The
  # gates further down still run: they are ours to keep, and they are what makes
  # this one node at a time.
  if [[ $UPGRADE -eq 1 ]]; then
    # Re-runnable: a node already on the target version is left alone. Without
    # this, resuming an interrupted roll reboots the nodes it already did.
    local running
    running="$(node_talos_version "$ep" "$node_ip")"
    if [[ -z "$running" ]]; then
      # Retry once: this is the first thing touched after the previous node's
      # reboot, and the tunnel behind it may be a second from re-establishing.
      sleep "$POLL"; running="$(node_talos_version "$ep" "$node_ip")"
    fi
    if [[ -z "$running" ]]; then
      # Say WHICH end is silent. oa_talos_endpoint_ok demands a TLS answer, so
      # it separates "the tunnel is gone" from "the node is gone" — `nc -z`
      # cannot, because ssh -L keeps listening after the far end dies.
      if oa_talos_endpoint_ok "${ep%%:*}" "${ep##*:}"; then
        die "${node_name}: ${ep} answers TLS but talosctl will not report a version.
  The tunnel is up, so this is the node or the talosconfig, not the network."
      fi
      die "${node_name}: nothing is answering on ${ep}.
  The Talos tunnels are down. Reopen them and re-run — an upgrade is re-runnable
  and skips every node already on the target version:
    task tunnels-up PROVIDER=<provider> KEY=<your key>"
    fi
    if [[ "$running" == "${TALOS_IMAGE##*:}" ]]; then
      # Same version is not the same image. Ask for the schematic too, or a
      # change to the extensions can never be rolled out: on 2026-08-19 a fleet
      # sat on the schematic that broke OVH while its config named the fixed
      # one, and this line greeted every node with "already runs — skipping".
      local want_sch have_sch
      want_sch="${TALOS_IMAGE#*/installer/}"; want_sch="${want_sch%%:*}"
      have_sch="$(node_schematic "$ep" "$node_ip")"
      if [[ -n "$want_sch" && -n "$have_sch" && "$want_sch" != "$have_sch" ]]; then
        info "${node_name} runs ${running} but from schematic ${have_sch:0:12}…, not ${want_sch:0:12}… — rolling it to align"
      else
        ok "${node_name} already runs ${running} — skipping"
        return 0
      fi
    fi
    # The endpoint must be a CONTROL PLANE, even when the target is a worker.
    # talosctl fetches a kubeconfig from the endpoint to drain the node, and a
    # worker answers "kubeconfig is only available on control plane nodes" — so
    # the install succeeds and the command still exits non-zero. -n keeps naming
    # the node to act on; apid proxies.
    local up_ep="$ep"
    if [[ "$t" != "cp" ]]; then
      local cp_peer
      cp_peer="$(healthy_peer_cp -1)" || die "no healthy control plane to drive the upgrade of ${node_name}"
      read -r up_ep _ <<<"$cp_peer"
    fi
    cordon_drain "$node_name"
    info "talosctl upgrade ${node_name} ${running:-?} → ${TALOS_IMAGE}"
    # --drain=false: we just drained, tolerantly. Talos's own drain is all-or-
    # nothing and dies on the first PDB that forbids eviction.
    # BOUNDED. `--wait` has no deadline of its own, and on OVH it does not return:
    # the node reboots, reports `stage: BOOTING ready: true unmetCond: []`, never
    # reaches Running as far as the watcher is concerned, and the operator waits
    # forty minutes for nothing (measured 2026-08-17). The recovery below already
    # knew how to ask the node directly — it was simply unreachable, because a
    # command that hangs never returns non-zero.
    upgrade_rc=0
    timeout "$UPGRADE_WATCH_TIMEOUT" talosctl upgrade -e "$up_ep" -n "$node_ip" \
      --image "$TALOS_IMAGE" --wait --drain=false || upgrade_rc=$?
    if (( upgrade_rc != 0 )); then
      # The CLIENT'S WATCH IS NOT THE VERDICT. On OVH 2026-08-16 the installer
      # logged "installation of v1.13.8 complete" and "Exit code: 0", then
      # talosctl spent 14 minutes being GOAWAY'd — ENHANCE_YOUR_CALM,
      # "too_many_pings" — following the node through its own reboot over an SSH
      # tunnel, and returned non-zero. The node was Ready on the new version the
      # whole time, and the roll aborted anyway. Ask the node, not the client.
      case "$upgrade_rc" in
        124) warn "the upgrade watch did not return within ${UPGRADE_WATCH_TIMEOUT}s on ${node_name} — asking the node itself" ;;
        130 | 2)
          # SIGINT. The operator asked to stop, and until 2026-08-17 this branch
          # read the interrupt as a lost watch, confirmed the node was on the new
          # version, and rolled on to drain the NEXT one. Pressing Ctrl+C must
          # stop the roll, not accelerate it.
          STOP_REQUESTED=1
          warn "interrupted during the upgrade of ${node_name} — finishing this node, then stopping" ;;
        *) warn "talosctl upgrade --wait returned ${upgrade_rc} on ${node_name}; asking the node itself" ;;
      esac
      local back=0 deadline=$(( SECONDS + NODE_READY_TIMEOUT ))
      while (( SECONDS < deadline )); do
        running="$(node_talos_version "$ep" "$node_ip")"
        [[ "$running" == "${TALOS_IMAGE##*:}" ]] && { back=1; break; }
        sleep "$POLL"
      done
      (( back == 1 )) || die "upgrade failed on ${node_name} — it reports ${running:-no version at all}, not ${TALOS_IMAGE##*:}.
  The node kept its disk and its etcd membership; investigate before retrying."
      ok "${node_name} came back on ${running} — the watch failed, the upgrade did not"
    fi
    ok "${node_name} upgraded, waiting for it to come back"
  else

  # 0. Both plans of step 2, made now and applied to nothing: the second one only
  # shows what it drags in once the node exists, and refusing then would leave a
  # fresh VM with no config.
  saved_plan_apply "${node_name}-instance" "$t" "$i" "${#infra_targets[@]}" "" check \
    "${infra_targets[@]}" -replace="$inst_addr"
  saved_plan_apply "${node_name}-config" "$t" "$i" "$cfg_max" "" check "${cfg_targets[@]}"

  # 1. cordon + drain (evacuate workloads, trigger Longhorn rebuild / app failover)
  cordon_drain "$node_name"

  # 1b. control plane: evict the stale etcd member BEFORE destroying the VM, while
  # the remaining peers still hold quorum. (tofu destroy = ungraceful leave.)
  if [[ "$t" == "cp" ]]; then
    etcd_remove_member "$node_name" "$node_ip" "$i"
  fi

  # 2. TWO applies, and the split is the whole point.
  #
  # modules/talos takes each node's address from the provider module's IPAM
  # resource, never from its instance, so nothing in the graph says "configure
  # the node after you have rebuilt it". In one apply tofu is free to order it
  # the other way round, and it does: observed 2026-08-13, the config applied to
  # the OLD VM one second before that VM was destroyed, and the replacement then
  # booted into maintenance mode with no config at all — which is what every
  # "kubelet not healthy after 600s" of the last two days actually was.
  #
  # The ordering has to come from here. First the instance, alone. Then the
  # guard and the config, against a node that now exists. The second plan is
  # made after the first apply: a saved plan goes stale once the state moves.
  #
  # Each plan's blast radius is counted before it applies. "One node at a time"
  # was an intention this script never checked: on 2026-08-12 a single extra
  # -target pulled the whole provider module into the plan and one "per-node"
  # apply replaced all three control planes together, taking etcd down.
  info "tofu 1/2 — recreate ${node_name} (instance, NIC/IP)…"
  info "targets: ${infra_targets[*]#-target=}"
  saved_plan_apply "${node_name}-instance" "$t" "$i" "${#infra_targets[@]}" \
    "tofu apply (instance) failed for ${node_name} — cluster left with ${node_name} cordoned; investigate before retrying" \
    apply "${infra_targets[@]}" -replace="$inst_addr"

  info "tofu 2/2 — wait for the new node, then apply its Talos config…"
  saved_plan_apply "${node_name}-config" "$t" "$i" "$cfg_max" \
    "tofu apply (config) failed for ${node_name} — the VM exists but is unconfigured (maintenance mode); re-run to resume" \
    apply "${cfg_targets[@]}"

  fi  # end of the replacement path

  # 4. Talos services up on the fresh VM (-e tunnel connects, -n real IP = identity)
  info "Waiting for Talos to come up on ${node_name} (${ep} → ${node_ip})…"
  local td=$(( SECONDS + NODE_READY_TIMEOUT ))
  until talosctl -e "$ep" -n "$node_ip" service kubelet 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; do
    (( SECONDS < td )) || die "Talos kubelet not healthy on ${node_name} after ${NODE_READY_TIMEOUT}s"
    sleep "$POLL"
  done
  ok "Talos services up on ${node_name}"

  # 5. node Ready in k8s
  wait_node_ready "$node_name" || die "node ${node_name} not Ready in time — STOP"

  # 5b. and Talos must have ACCEPTED it, not merely booted it.
  # An `if` rather than `[[ … ]] && …` for legibility. The && form was checked
  # and is safe here — bash does not apply `set -e` to an AND-list whose test is
  # simply false — but it stops being safe the moment it becomes the last
  # statement of a function, and this block moves.
  if [[ $UPGRADE -eq 1 ]]; then
    assert_upgrade_confirmed "$ep" "$node_ip" "$node_name"
  fi

  # 6. for control planes: etcd must be back to full membership before the next CP
  if [[ "$t" == "cp" ]]; then
    wait_etcd_healthy "${#CP_IPS[@]}" || die "etcd did not return to ${#CP_IPS[@]}/${#CP_IPS[@]} healthy — STOP (do NOT replace another CP)"
  fi

  # 7. back into rotation, BEFORE the Longhorn gate: Longhorn does not schedule a
  # replica onto a cordoned node, so with as many replicas as workers (the default 3
  # on 3) the node this gate waits for is the one it keeps from rebuilding. Measured
  # on Scaleway 2026-10-03: degraded for 600 s until a manual uncordon, healthy 63 s later.
  "${KCTL[@]}" uncordon "$node_name" || warn "uncordon failed for ${node_name} (re-run manually)"

  # 8. Longhorn rebuild complete (no degraded/faulted) before the next node is touched
  wait_longhorn_healthy || die "Longhorn not healthy after replacing ${node_name} — STOP"
  ok "Node ${node_name} $([[ $UPGRADE -eq 1 ]] && echo upgraded || echo replaced) and back in rotation"
}

# ==============================================================================
# Main
# ==============================================================================
# Global pre-check: cluster must be healthy BEFORE we start pulling nodes.
hr
info "Pre-flight health check…"
if [[ $DRY_RUN -eq 0 ]]; then
  wait_etcd_healthy "${#CP_IPS[@]}" || die "etcd is not ${#CP_IPS[@]}/${#CP_IPS[@]} healthy — refusing to start a rolling replace on an unhealthy cluster"
  "${KCTL[@]}" get nodes >/dev/null 2>&1 || die "kubectl cannot reach the API via ${KUBECONFIG_FILE}"
  # WAIT, do not sample once. cluster-upgrade.sh calls this immediately after a
  # Kubernetes version bump, and a kubelet that has just restarted is NotReady
  # for a few seconds while reporting the new version — so a single sample
  # refused the whole Talos roll on a cluster that was fine moments later
  # (OVH, 2026-08-16). The etcd check one line above already waits; this is the
  # same requirement, and it was the only one asserted instantaneously.
  #
  # "Ready,SchedulingDisabled" is Ready. Matching the column exactly counted a
  # merely cordoned node as unhealthy — and a cordoned node is the state THIS
  # script leaves behind when it stops mid-node, so the check blocked its own
  # retry until someone uncordoned by hand.
  nodes_deadline=$(( SECONDS + NODE_READY_TIMEOUT ))
  info "Waiting for every node to be Ready…"
  while :; do
    # A FAILED query is not "every node is Ready". Keeping the exit status is
    # the difference between waiting and draining a cluster we cannot see.
    if raw="$("${KCTL[@]}" get nodes --no-headers 2>/dev/null)" && [[ -n "$raw" ]]; then
      not_ready="$(awk '$2 !~ /^Ready/{printf "%s ", $1}' <<<"$raw")"
      # An EMPTY node list has no not-Ready node either, and would read as
      # "everything is fine" — the same shape as the failed query above.
      [[ -z "$not_ready" ]] && { ok "all $(wc -l <<<"$raw") nodes Ready"; break; }
    else
      not_ready="(apiserver did not answer)"
    fi
    (( SECONDS < nodes_deadline )) ||
      die "still not Ready after ${NODE_READY_TIMEOUT}s: ${not_ready}— stabilize the cluster first"
    sleep "$POLL"
  done
  cordoned="$("${KCTL[@]}" get nodes --no-headers 2>/dev/null | awk '$2 ~ /SchedulingDisabled/{printf "%s ", $1}')"
  [[ -z "$cordoned" ]] || warn "already cordoned (interrupted run?): ${cordoned}— uncordon by hand any node this run does not touch."
  ok "Cluster healthy — proceeding"
else
  ok "dry-run — skipping live pre-flight"
fi

if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  hr
  # The prompt described the REPLACE path in both modes. `--upgrade` destroys
  # nothing and wipes nothing — it reboots each node into a new Talos version and
  # keeps its disk, identity and etcd membership — so the warning was frightening
  # and wrong for half the runs that reach it.
  if [[ $UPGRADE -eq 1 ]]; then
    warn "This will upgrade Talos IN PLACE, one node at a time, on ${PROVIDER}."
    warn "No instance is destroyed and no disk is wiped; each node reboots once."
    read -rp "Proceed with the rolling upgrade? [y/N] " a
  else
    warn "This will DESTROY and recreate node instances one at a time on ${PROVIDER}."
    warn "System disks are wiped (OS only); Longhorn data disks are preserved."
    read -rp "Proceed with rolling replacement? [y/N] " a
  fi
  [[ "$a" == [yY] ]] || die "aborted by operator"
fi

# Tell CNPG a maintenance is on for the whole roll, and take it back off however
# this ends — including on failure, where leaving the budgets relaxed would be
# worse than the drain that failed.
if [[ $DRY_RUN -eq 0 ]]; then
  # Trap FIRST. cnpg_maintenance suspends Flux and patches enablePDB before it
  # confirms the budgets are gone, and that confirmation can die — so installing
  # the trap after the call leaves a suspended Kustomization and relaxed budgets
  # behind with nothing to restore them. Restoring a cluster that was never
  # changed is a no-op; not restoring one that was is the failure that matters.
  trap finish_roll EXIT
  cnpg_maintenance true
  # Now that the budgets are actually gone, ask everything else that is knowable
  # before the first node is touched — see preflight_roll.
  preflight_roll
fi

# Workers first (heavy stateful load), then control planes (etcd-gated).
if [[ "$SCOPE" == "all" || "$SCOPE" == "workers" ]]; then
  for j in "${!WK_IPS[@]}"; do stop_here worker && break; replace_node worker "$j"; done
fi
if [[ "$SCOPE" == "all" || "$SCOPE" == "cp" ]]; then
  for j in $(cp_roll_order "$CP_ORDER"); do
    stop_here cp && break
    # Re-read each time: leadership can move for reasons that are not ours.
    if [[ $DRY_RUN -eq 0 ]] && cp_forfeit_wanted "$CP_ORDER" "$j"; then
      forfeit_leadership "$j"
    fi
    replace_node cp "$j"
  done
fi

hr
# A real run's "complete" line is finish_roll's: it cannot be said before the check.
if [[ $DRY_RUN -eq 1 ]]; then
  ok "dry-run complete — no changes made"
fi
