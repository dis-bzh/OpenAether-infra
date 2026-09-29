#!/usr/bin/env bash
# The Talos version, from the one place that decides it: the cluster env file if
# it pins one, otherwise cluster/variables.tf's default.
#
# It used to be a literal in Taskfile.yml, duplicated twice. It drifted: the
# Taskfile said v1.13.7 while variables.tf said v1.13.8, so `task cluster-up` built an
# image the cluster then refused to find — "no image found with the name
# talos-scaleway-amd64-v1.13.8". Two defaults for one fact is one too many.
#
# Usage: talos-version.sh [<role>-<provider>.tfvars]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="$ROOT/infrastructure/opentofu/cluster"
TFVARS="${1:-}"

read_pin() { # <file>
  [[ -f "$1" ]] || return 1
  grep -E '^[[:space:]]*talos_version[[:space:]]*=' "$1" | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]'
}

v=""
# OA_ENVS_DIR lets a test harness point this at a sandbox instead of the real envs/ (#191).
[[ -n "$TFVARS" ]] && v="$(read_pin "${OA_ENVS_DIR:-$CLUSTER/envs}/$TFVARS" || true)"
[[ -n "$v" ]] || v="$(awk '/variable "talos_version"/,/^}/' "$CLUSTER/variables.tf" \
                      | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[[ -n "$v" ]] || { echo "✗ could not read talos_version from $TFVARS or cluster/variables.tf" >&2; exit 1; }
echo "$v"
