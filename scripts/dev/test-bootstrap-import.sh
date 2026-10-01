#!/usr/bin/env bash
# ==============================================================================
# Importing talos_machine_bootstrap adopts it without touching a node (#67).
#
# adopt-bootstrap.sh stakes its recovery on three provider behaviours no stub can
# show: a failed create leaves the resource out of state, `tofu import` accepts
# whatever ID it is given, and the plan after it is an in-place update that applies
# without an RPC. Measured here with the provider version the cluster root pins, in
# a scratch config aimed at a closed loopback port: real provider, real tofu, no
# node, no cloud. A provider bump that changes any of the three turns this red.
#
# Needs the provider (the registry, or the cache TF_PLUGIN_CACHE_DIR names). A run
# that cannot init fails: it does not skip.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

command -v tofu >/dev/null && command -v jq >/dev/null \
  || { echo "✗ tofu and jq are required — nothing was checked" >&2; exit 1; }
# CI's setup-opentofu puts a Node wrapper on PATH as `tofu`; the binary behind it
# is what an operator runs, and what prints plain stdout for the parsing below.
TOFU="$(command -v tofu)"
[ -n "${TOFU_CLI_PATH:-}" ] && [ -x "$TOFU_CLI_PATH/tofu-bin" ] && TOFU="$TOFU_CLI_PATH/tofu-bin"

# The constraint the cluster root pins, not a copy of it.
PIN="$(sed -nE '/^[[:space:]]*talos[[:space:]]*=/,/^[[:space:]]*}/ s/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
  infrastructure/opentofu/cluster/versions.tf | head -1)"
[ -n "$PIN" ] || { echo "✗ no talos provider constraint in cluster/versions.tf — nothing was checked" >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1
export TF_DATA_DIR="$W/.data" TF_IN_AUTOMATION=1 TF_INPUT=0
cat >main.tf <<EOF
terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "$PIN"
    }
  }
}
resource "talos_machine_secrets" "this" {}
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = "127.0.0.1:1" # nothing listens: every RPC is refused
  node                 = "192.0.2.10"
  timeouts = {
    create = "3s"
  }
}
EOF
t() { local sub="$1"; shift; "$TOFU" "$sub" -no-color "$@" 2>&1; }
BOOT=talos_machine_bootstrap.this

echo "--- the provider the cluster root pins ($PIN) ---"
if out="$(t init)"; then ok "tofu init"; else
  bad "tofu init failed — the provider is unreachable, so nothing below ran: $(tail -n 3 <<<"$out")"
  printf '%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi

echo "--- a create that never reaches a node leaves the resource out of state ---"
out="$(t apply -auto-approve)"; rc=$?
[ "$rc" != 0 ] && grep -q 'code = Unavailable' <<<"$out" \
  && ok "the apply fails with the connection error a dropped tunnel gives" \
  || bad "apply rc $rc: $(tail -n 4 <<<"$out")"
state="$("$TOFU" state list 2>/dev/null)"
grep -qx "$BOOT" <<<"$state" \
  && bad "the failed create is in state: it would be tainted, not absent" \
  || ok "it is absent from state (not tainted): the state phase 2 finds on a re-run"

echo "--- an import takes any ID and sends nothing ---"
out="$(t import "$BOOT" an-id-the-provider-ignores)"; rc=$?
[ "$rc" = 0 ] && grep -qx "$BOOT" <<<"$("$TOFU" state list 2>/dev/null)" \
  && ok "tofu import with an arbitrary ID exits 0 and records the resource" \
  || bad "import rc $rc: $(tail -n 4 <<<"$out")"

echo "--- and what follows is an in-place update, never a create ---"
out="$(t plan -out=p.tfplan)"
acts="$("$TOFU" show -json p.tfplan 2>/dev/null | jq -c --arg a "$BOOT" '[.resource_changes[] | select(.address == $a) | .change.actions] | add')"
[ "$acts" = '["update"]' ] && ok "the plan's action on it is [\"update\"]" || bad "actions: ${acts:-none}; $(tail -n 4 <<<"$out")"
start=$SECONDS; out="$(t apply p.tfplan)"; rc=$?; took=$((SECONDS - start))
# A bootstrap RPC would retry against the closed port until the 3s create timeout.
[ "$rc" = 0 ] && [ "$took" -lt 10 ] && ok "the apply succeeds in ${took}s: no RPC" || bad "apply rc $rc after ${took}s: $(tail -n 3 <<<"$out")"
t plan -detailed-exitcode >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "the re-plan is empty" || bad "the re-plan exits $rc (2 = a change is still pending)"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
