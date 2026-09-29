#!/usr/bin/env bash
# Issue a SHORT-LIVED, role-scoped talosconfig from the admin one.
#
# What this repository hands an operator today is `os:admin`, valid one year,
# and it is the same file for every task and every person. Talos enforces its
# roles with nothing added to the machine config (measured on the Docker lane,
# 2026-08-24: an os:reader config is refused `read` and cannot mint an os:admin
# one), so the day-to-day credential can be smaller and expire on its own.
#
# The admin config stays where it is — this does not replace it, it gives the
# read-only work something cheaper to lose.
#
# Usage:
#   talosconfig-new.sh <provider|local> [--roles os:reader] [--ttl 8h] [--out PATH] [--node IP]
set -euo pipefail

LANE="${1:?usage: talosconfig-new.sh <provider|local> [--roles R] [--ttl D] [--out PATH] [--node IP]}"
shift
ROLES="os:reader"
TTL="8h"
OUT=""
NODE="${NODE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --ttl)   TTL="$2";   shift 2 ;;
    --out)   OUT="$2";   shift 2 ;;
    --node)  NODE="$2";  shift 2 ;;
    *) echo "✗ unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Same lane resolution as scripts/dev/infra-verify.sh — two spellings of "where
# does this cluster keep its credentials" would drift. The two roots name their
# control-plane output differently.
if [ "$LANE" = local ]; then
  CLUSTER_DIR="$ROOT/infrastructure/opentofu-local"; CP_OUTPUT=control_plane_ips
else
  CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"; CP_OUTPUT=control_plane_private_ips
fi
SRC="${TALOSCONFIG:-$CLUSTER_DIR/talosconfig}"
OUT="${OUT:-$CLUSTER_DIR/talosconfig.${ROLES#os:}}"

# A talosconfig with no context is the 25-byte stub a fresh clone carries, not a
# cluster. `talosctl` answers "no context is set", which reads like a flag
# mistake; say what is actually missing instead of forwarding that.
if [ ! -s "$SRC" ] || ! TALOSCONFIG="$SRC" talosctl config info >/dev/null 2>&1; then
  echo "✗ no usable talosconfig at $SRC" >&2
  echo "  That file is empty or has no context: there is no cluster to ask." >&2
  [ "$LANE" = local ] && echo "  Bring one up:  task local-up" >&2 \
                      || echo "  Deploy one:    task cluster-up PROVIDER=$LANE" >&2
  exit 1
fi

if [ -z "$NODE" ]; then
  NODE="$(tofu -chdir="$CLUSTER_DIR" output -json "$CP_OUTPUT" 2>/dev/null |
          sed -nE 's/^\["([^"]+)".*/\1/p')" || true
fi
if [ -z "$NODE" ]; then
  echo "✗ no node to ask, and the state did not answer." >&2
  echo "  Pass one:  $ROOT/scripts/ops/talosconfig-new.sh $LANE --node <control-plane private IP>" >&2
  [ "$LANE" != local ] && echo "  On a cloud lane the Talos API is reached through the bastion:" >&2 \
                       && echo "    task tunnels-up PROVIDER=$LANE [ROLE=workload]" >&2
  exit 1
fi

rm -f "$OUT"
TALOSCONFIG="$SRC" talosctl -n "$NODE" config new "$OUT" --roles "$ROLES" --crt-ttl "$TTL"

# Report what came back, not what was requested: the roles are granted by the
# node, and asking for one it will not give is a silent downgrade otherwise.
GOT="$(TALOSCONFIG="$OUT" talosctl config info 2>/dev/null | sed -nE 's/^Roles:[[:space:]]+(.*)$/\1/p')"
EXP="$(TALOSCONFIG="$OUT" talosctl config info 2>/dev/null | sed -nE 's/^Certificate expires:[[:space:]]+(.*)$/\1/p')"
if [ "$GOT" != "$ROLES" ]; then
  echo "✗ asked for '$ROLES', the node issued '$GOT' — not using it." >&2
  rm -f "$OUT"
  exit 1
fi
printf '✓ %s\n  roles:   %s\n  expires: %s\n  use it:  TALOSCONFIG=%s talosctl -n %s <read-only command>\n' \
  "$OUT" "$GOT" "$EXP" "$OUT" "$NODE"
