#!/usr/bin/env bash
# Bring the RUNNING fleet to the versions the config pins — the half of
# `cluster-up` that OpenTofu cannot do.
#
# `cluster-up` writes the pinned installer image into the machine config and asks
# NO node to upgrade, so a bumped pin lands a machine config and leaves the fleet
# a version behind, with an empty plan behind it. Editing the tfvars IS the
# decision to upgrade; this is what makes the command reach it.
#
# NOT cluster-upgrade.sh. That script fails BY DESIGN when the fleet already
# matches both targets — exactly the state cluster-up leaves behind — so folding
# it in would turn every ordinary bring-up into a hard failure. This reuses the
# roll it calls, and nothing else.
#
# --check reports and rolls nothing. cluster-up runs it BEFORE the approval
# question, so the operator says yes to a journey that includes the roll instead
# of discovering it afterwards. `ignore_changes` on the image attribute keeps the
# roll out of the OpenTofu plan entirely, so the plan cannot show it.
#
# Usage: converge-versions.sh <provider> <role> <key> [--check]
set -euo pipefail

PROVIDER="${1:?usage: converge-versions.sh <provider> <role> <key> [--check]}"
ROLE="${2:?usage: converge-versions.sh <provider> <role> <key> [--check]}"
KEY="${3:-$HOME/.ssh/id_ed25519}"; KEY="${KEY/#\~/$HOME}"
CHECK_ONLY=0; [ "${4:-}" = --check ] && CHECK_ONLY=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
TFVARS="${OA_ENVS_DIR:-$CLUSTER_DIR/envs}/${ROLE}-${PROVIDER}.tfvars"   # OA_ENVS_DIR: a test sandbox
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"

fail() { echo "✗ $*" >&2; exit 1; }

want_talos="$(oa_pinned_version "$CLUSTER_DIR" "$TFVARS" talos_version)"
want_k8s="$(oa_pinned_version "$CLUSTER_DIR" "$TFVARS" kubernetes_version)"
have_talos="$(oa_fleet_versions '.status.nodeInfo.osImage')"
have_k8s="$(oa_fleet_versions '.status.nodeInfo.kubeletVersion')"

# Nothing pinned anywhere is a legitimate configuration, not a drift.
if [ -z "$want_talos" ] && [ -z "$want_k8s" ]; then
  echo "  no talos_version or kubernetes_version pinned — nothing to converge toward"
  exit 0
fi

# No cluster to ask. Before the apply that is the normal case and says nothing
# useful; after it, a fleet we cannot read is a fleet we cannot claim anything
# about — and claiming it anyway is the defect this whole file exists to close.
if [ -z "$have_talos" ] && [ -z "$have_k8s" ]; then
  [ "$CHECK_ONLY" = 1 ] && exit 0
  fail "the apiserver named no nodes, so the running versions are UNKNOWN.
  Nothing was rolled and nothing can be promised about this fleet.
  Check the cluster, then: task cluster-verify PROVIDER=${PROVIDER} ROLE=${ROLE}"
fi

# Refuse a pin that is semver-LOWER than what is running, before anything below
# calls infra-apply or cluster-roll. This script has no downgrade guard of its
# own otherwise — it only survives one today by accident, on two layers it does
# not own: the pinned talos provider forces a PKI replacement on a lower
# version, and secrets_prevent_destroy turns that into a hard refusal. Neither
# is this script's to depend on; secrets_prevent_destroy is explicitly false in
# `tofu test`, and nothing here would notice on a config where it were false for
# real. A fleet can be MIXED mid-roll (comma-separated), so a pin counts as a
# downgrade against ANY node still running above it, not only the lowest one.
downgrade() { # <pin> <running-csv> — 0 if pin is a downgrade from any of running
  local pin="$1" running="$2" v
  [ -n "$pin" ] && [ -n "$running" ] || return 1
  IFS=',' read -ra _running_vs <<<"$running"
  for v in "${_running_vs[@]}"; do
    oa_semver_lt "$pin" "$v" && return 0
  done
  return 1
}
if downgrade "$want_talos" "$have_talos"; then
  fail "the config pins Talos ${want_talos}, the fleet runs ${have_talos} — that is a DOWNGRADE.
  converge-versions.sh does not build a downgrade path (cluster-upgrade.sh refuses one for
  the same reason). Revert the pin, or roll the cluster forward instead."
fi
if downgrade "$want_k8s" "$have_k8s"; then
  fail "the config pins Kubernetes ${want_k8s}, the fleet runs ${have_k8s} — that is a DOWNGRADE.
  converge-versions.sh does not build a downgrade path (cluster-upgrade.sh refuses one for
  the same reason). Revert the pin, or roll the cluster forward instead."
fi

drift=0
[ -n "$want_talos" ] && [ "$have_talos" != "$want_talos" ] && drift=1
[ -n "$want_k8s" ]   && [ "$have_k8s"   != "$want_k8s"   ] && drift=1

if [ "$drift" = 0 ]; then
  echo "✓ the fleet already runs the pinned versions (Talos ${have_talos}, Kubernetes ${have_k8s}) — nothing to roll"
  exit 0
fi

echo "▶ the fleet does not match the pin:"
[ "$have_talos" = "$want_talos" ] || echo "    Talos      running ${have_talos:-?} → pinned ${want_talos}"
[ "$have_k8s"   = "$want_k8s"   ] || echo "    Kubernetes running ${have_k8s:-?} → pinned ${want_k8s}"

# The apply that writes the pin reaches every node BEFORE any roll, so a Kubernetes pin the RUNNING
# Talos cannot host is refused by the node itself, late and cryptically ("1.37.1 is too new to be used
# with Talos 1.13.9", Scaleway 2026-10-06). cluster-upgrade.sh walks the pair one minor at a time.
if [ -n "$want_k8s" ] && [ "$have_k8s" != "$want_k8s" ] && [ -n "$have_talos" ]; then
  support="$CLUSTER_DIR/version-support.json"
  km="$(sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/' <<<"$want_k8s")"
  IFS=',' read -ra _talos_vs <<<"$have_talos"
  for v in "${_talos_vs[@]}"; do
    range="$(jq -r --arg m "$(sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/' <<<"$v")" \
             '.talos_minors[$m] // empty | "\(.k8s_min) \(.k8s_max)"' "$support")" ||
      fail "cannot read $support, so whether Talos ${v} can host Kubernetes ${want_k8s} is UNKNOWN."
    read -r lo hi <<<"$range"
    # A Talos minor the matrix has never heard of is the plan-time guard's to refuse.
    [ -z "${lo:-}" ] || { [ "$km" -ge "$lo" ] && [ "$km" -le "$hi" ]; } ||
      fail "the fleet runs Talos ${v}, which supports Kubernetes 1.${lo} to 1.${hi}, and the config pins ${want_k8s}.
  The apply would push that pin to nodes that refuse it, before any roll. Nothing was planned or applied.
  Move the pair one minor at a time instead: task cluster-upgrade PROVIDER=${PROVIDER} ROLE=${ROLE}"
  done
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo "    Approving below also approves rolling every node, one at a time, to close this."
  exit 0
fi

# Kubernetes moves through the machine config, not through a roll: an
# `infra-apply` writes kubernetes_version into talos_machine_configuration_apply
# and every kubelet picks it up on its own — cluster-upgrade.sh:upgrade_k8s_to()
# does exactly this and rolls nothing. `cluster-roll --upgrade` only ever runs
# `talosctl upgrade`, the TALOS image, so calling it for a Kubernetes-only lag
# would roll every node for a version it does not carry. rolling-replace.sh does
# make that harmless today — it compares the RUNNING image to the pinned one and
# skips a node that already matches — but relying on that no-op is the wrong
# thing to depend on, and if a Kubernetes-only lag ever coincides with a real
# Talos lag, calling the roll unconditionally here would roll it against the
# WRONG target: converge-versions never passes TALOS_IMAGE, so the roll derives
# it from the state's current installer_image output, which is fine only because
# the two moves never overlap in this script.
if [ -n "$want_k8s" ] && [ "$have_k8s" != "$want_k8s" ]; then
  task infra-apply ROLE="$ROLE" PROVIDER="$PROVIDER" KEY="$KEY" APPROVE=auto
fi

# Talos moves through a roll: control planes first, because a worker's upgrade
# drains against a healthy control plane.
if [ -n "$want_talos" ] && [ "$have_talos" != "$want_talos" ]; then
  task cluster-roll PROVIDER="$PROVIDER" ROLE="$ROLE" KEY="$KEY" APPROVE=auto -- --cp-only --upgrade
  task cluster-roll PROVIDER="$PROVIDER" ROLE="$ROLE" KEY="$KEY" APPROVE=auto -- --workers-only --upgrade
fi

# Ask again. The roll reporting success is the client talking; this is the fleet.
got_talos="$(oa_fleet_versions '.status.nodeInfo.osImage')"
got_k8s="$(oa_fleet_versions '.status.nodeInfo.kubeletVersion')"
[ -n "$got_talos" ] || fail "after the roll the apiserver named no nodes — nothing was verified"
[ -z "$want_talos" ] || [ "$got_talos" = "$want_talos" ] ||
  fail "after the roll the fleet runs Talos ${got_talos}, the config pins ${want_talos}"
[ -z "$want_k8s" ] || [ "$got_k8s" = "$want_k8s" ] ||
  fail "after the roll the fleet runs Kubernetes ${got_k8s}, the config pins ${want_k8s}"
echo "✓ converged: every node runs Talos ${got_talos}, Kubernetes ${got_k8s}"
