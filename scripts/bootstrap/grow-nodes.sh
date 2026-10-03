#!/usr/bin/env bash
# OpenAether — add nodes to a cluster that is already bootstrapped (#59)
#
# One apply that creates a node AND configures it waits, for the node's Talos port,
# on a tunnel that cannot exist until the node does. Measured on Scaleway
# (2026-10-02): `workers = 4` waited on the new node's port, and after the tunnels
# were opened by hand the next plan blocked 15 minutes on data.talos_cluster_health,
# which cannot pass while a node it lists has no configuration. So it is three steps:
#   1. create the machines: a plan of the provider module alone, which never reads the cluster;
#   2. refresh the outputs (a plan of the provider module alone does not update the root outputs
#      the tunnels read) with a refresh-only run that skips the health read, then open the tunnels;
#   3. configure only the nodes the state has no config apply for: a plan targeted at those.
# Then the usual plan and apply find a cluster whose nodes are all configured.
# A fresh cluster, or a bootstrapped one with no new node, leaves this at a no-op.
#
# Usage, from the cluster dir with the backend inited:  SSH_KEY=… grow-nodes.sh <role> <provider>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROLE="${1:?usage: grow-nodes.sh <role> <provider>}"
PROVIDER="${2:?usage: grow-nodes.sh <role> <provider>}"
TFVARS="envs/${ROLE}-${PROVIDER}.tfvars"
case "$PROVIDER" in
  scaleway) MOD=scw ;; ovh) MOD=ovh ;; outscale) MOD=outscale ;; proxmox) MOD=proxmox ;;
  *) echo "✗ unknown provider: $PROVIDER" >&2; exit 2 ;;
esac
die() { echo "✗ $*" >&2; exit 1; }
# tofu with its output kept: shown, tail only, when it fails — a swallowed provider error is a dead end.
t() { local f="$D/tofu.log"; tofu "$@" >"$f" 2>&1 || { tail -n 15 "$f" >&2; return 1; }; }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
TB="$(../../../scripts/internal/bootstrap-in-state.sh)" || exit 1
[ "$TB" = true ] || exit 0 # no bootstrap yet: the two phases build every node

VARS=(-input=false -no-color -var-file="$TFVARS" -var talos_bootstrap=true)

# Node-scoped addresses are told by name, as in rolling-replace.sh: cp/control_plane/worker.
NODE_JQ='def cls: if test("(^|_)(cp|control_plane)(_|$)") then "cp" elif test("(^|_)worker(_|$)") then "worker" else empty end;'

# --- 1. machines ------------------------------------------------------------------
t plan "${VARS[@]}" -out="$D/machines.tfplan" -target="module.${MOD}[0]" \
  || die "could not plan the machines of ${PROVIDER} — refusing to guess whether nodes are missing"
NEW="$(tofu show -json "$D/machines.tfplan" 2>/dev/null | jq -r "$NODE_JQ"'
  .resource_changes[]? | select(.mode == "managed" and .change.actions == ["create"])
  | select((.name // "") | cls) | .address')" \
  || die "could not read the plan of the machines"
if [ -n "$NEW" ]; then
  echo "▶ grow-nodes: the config asks for $(wc -l <<<"$NEW") machine resource(s) the state does not hold:"
  sed 's/^/    /' <<<"$NEW"
  # The plan is applied whole: a delete or a resize that rides along with the creates is not growth.
  ../../../scripts/internal/refuse-node-deletes.sh --creates-only "$D/machines.tfplan" || exit 1
  t apply -input=false -no-color "$D/machines.tfplan" || die "creating the machines failed"
  echo "✓ machines created"
fi

# --- 3. nodes that have a machine and no configuration -------------------------------
# Read from the state, not the root outputs: a plan of the provider module alone leaves those
# stale (measured: worker_private_ips read 3 with 4 workers in the state). Also after a step 1
# that created nothing: an earlier run may have stopped between creating a machine and
# configuring it, and that node is exactly what this finds.
STATE="$(tofu state list 2>/dev/null)" || die "could not read the state"
MACHINE_RE="^module\.${MOD}\[0\]\.(scaleway_instance_server|openstack_compute_instance_v2|outscale_vm|proxmox_virtual_environment_vm)\.(control_plane|cp|worker)\[([0-9]+)\]$"
TARGETS=() MISSING=()
while IFS= read -r addr; do
  [[ "$addr" =~ $MACHINE_RE ]] || continue
  kind="${BASH_REMATCH[2]}"; i="${BASH_REMATCH[3]}"; cls=worker; res=worker
  if [ "$kind" != worker ]; then cls="cp"; res="control_plane"; fi
  grep -qxF "module.talos.talos_machine_configuration_apply.${res}[${i}]" <<<"$STATE" && continue
  TARGETS+=(-target="module.talos.talos_machine_configuration_apply.${res}[${i}]")
  MISSING+=("${cls}:${i}")
done <<<"$STATE"
[ "${#MISSING[@]}" -gt 0 ] || exit 0

# --- 2. outputs, then tunnels ---------------------------------------------------------
# skip_health_check: data.talos_cluster_health would wait for the node this is about to configure.
t plan "${VARS[@]}" -var skip_health_check=true -refresh-only -out="$D/refresh.tfplan" \
  || die "could not refresh the outputs"
t apply -input=false -no-color "$D/refresh.tfplan" || die "refreshing the outputs failed"
../../../scripts/bootstrap/talos-tunnels.sh open . || die "could not open the Talos tunnels"

echo "▶ grow-nodes: configuring ${#MISSING[@]} node(s) the state has no configuration for: ${MISSING[*]}"
t plan "${VARS[@]}" -out="$D/config.tfplan" "${TARGETS[@]}" \
  || die "could not plan the configuration of ${MISSING[*]}"
# Only those nodes' own resources and shared ones: a node outside the set is not to be touched here.
OUTSIDE="$(tofu show -json "$D/config.tfplan" 2>/dev/null | jq -r --argjson miss "$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -sc .)" "$NODE_JQ"'
  .resource_changes[]? | select(.mode == "managed" and (.change.actions | any(. != "no-op")))
  | ((.name // "") | cls) as $c | "\($c):\(.index // -1)" as $k | select(($miss | index($k)) | not) | .address')" \
  || die "could not read the plan of the configuration"
if [ -n "$OUTSIDE" ]; then
  die "the plan to configure ${MISSING[*]} also changes other nodes — refusing, nothing applied:
$(sed 's/^/    /' <<<"$OUTSIDE")"
fi
t apply -input=false -no-color "$D/config.tfplan" || die "configuring ${MISSING[*]} failed"
echo "✓ configured ${MISSING[*]}"
