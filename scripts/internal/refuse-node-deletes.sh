#!/usr/bin/env bash
# Refuses a saved plan that deletes a node, or a worker's data volume, on a bootstrapped cluster.
#
# Lowering a count in the tfvars plans exactly that: OpenTofu removes the highest index, with no
# drain, no etcd leave and no Node delete, and the data volumes go with the worker (measured on a
# real Scaleway plan: server, NIC, IPAM address and volume). A control plane taken out so is a dead
# etcd member; two of three at once is a lost quorum. Whatever the reason (a lowered count, a removed
# resource block), a pure delete is refused; a replace (a tainted VM during phase 1) and a cluster that
# is not bootstrapped yet stay allowed. No override: removal is its own command.
#
# --creates-only: also refuse any change to a node's own resources that is not a create (a resize
# riding along a growth, the #222 class). For grow-nodes, whose plan is applied whole.
#
# Usage, from the cluster dir with the backend inited: refuse-node-deletes.sh [--creates-only] <planfile>
set -euo pipefail

ONLY=0
if [ "${1:-}" = --creates-only ]; then ONLY=1; shift; fi
PLAN="${1:?usage: refuse-node-deletes.sh [--creates-only] <planfile>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$PLAN" ] || { echo "✗ no plan file $PLAN" >&2; exit 2; }

# A state that cannot be read is not a fresh cluster: the helper refuses, and so does this.
TB="$("$HERE/bootstrap-in-state.sh")" || exit 1
[ "$TB" = true ] || exit 0

NODE_JQ='def cls: if test("(^|_)(cp|control_plane)(_|$)") then "cp" elif test("(^|_)worker(_|$)") then "worker" else empty end;'
JSON="$(tofu show -json "$PLAN" 2>/dev/null)" || { echo "✗ could not read the plan $PLAN" >&2; exit 1; }

DEL="$(jq -r "$NODE_JQ"'
  .resource_changes[]? | select(.mode == "managed" and .change.actions == ["delete"])
  | select((.name // "") | cls) | .address' <<<"$JSON")" || { echo "✗ could not read the plan $PLAN" >&2; exit 1; }
if [ -n "$DEL" ]; then
  {
    echo "✗ this plan deletes a node of a bootstrapped cluster, nothing was applied:"
    sed 's/^/    /' <<<"$DEL"
    echo "  Lowering a count destroys the highest-index node and its data volumes with no drain, no etcd"
    echo "  leave and no Node delete; a control plane below quorum is only recoverable from an etcd snapshot."
    echo "  Put the count back in the tfvars."
  } >&2
  exit 1
fi

if [ "$ONLY" = 1 ]; then
  CHG="$(jq -r "$NODE_JQ"'
    .resource_changes[]? | select(.mode == "managed" and (.change.actions | any(. != "no-op" and . != "create" and . != "read")))
    | select((.name // "") | cls) | "\(.address) (\(.change.actions | join(",")))"' <<<"$JSON")" \
    || { echo "✗ could not read the plan $PLAN" >&2; exit 1; }
  if [ -n "$CHG" ]; then
    {
      echo "✗ this plan also changes nodes that already exist, nothing was applied:"
      sed 's/^/    /' <<<"$CHG"
      echo "  Growing a cluster only creates nodes. Resize one at a time with task cluster-roll, then grow."
    } >&2
    exit 1
  fi
fi
