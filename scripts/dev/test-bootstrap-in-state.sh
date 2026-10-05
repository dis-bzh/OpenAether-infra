#!/usr/bin/env bash
# scripts/internal/bootstrap-in-state.sh: the answer `infra-plan` and `infra-apply`
# pass as -var talos_bootstrap, and the refusal of a state that lost its Talos secrets. A stub
# tofu stands for the state; each case runs the real script. SUT overrides the script, which is
# how the mutants run. The last sections run each script that calls it, in a copy of the tree.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/internal/bootstrap-in-state.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/tofu" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "state list" ] || exit 99
printf '%s' "${STUB_OUT:-}"; printf '%s' "${STUB_ERR:-}" >&2
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/tofu"
run() { OUT="$(PATH="$TMP/bin:$PATH" "$SUT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }

LIVE=$'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.talos_machine_bootstrap.this[0]\nmodule.talos.talos_machine_secrets.this[0]'
FRESH=$'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.talos_machine_secrets.this[0]'
# What `task infra-down-plan` leaves behind: every talos_* resource but the secrets (#66).
LOST=$'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.talos_machine_configuration_apply.cp[0]\nmodule.talos.talos_machine_bootstrap.this[0]\nmodule.talos.talos_cluster_kubeconfig.this[0]'
UNPROT=$'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.talos_machine_bootstrap.this[0]\nmodule.talos.talos_machine_secrets.unprotected[0]'

echo "=== the state answers ==="
STUB_OUT="$LIVE" run
[ "$RC" = 0 ] && [ "$OUT" = true ] && ok "a state holding the bootstrap answers true" || bad "bootstrapped state: rc=$RC out=[$OUT]"
STUB_OUT="$FRESH" run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "a state without it answers false" || bad "unbootstrapped state: rc=$RC out=[$OUT]"
STUB_OUT="" run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "an empty state answers false" || bad "empty state: rc=$RC out=[$OUT]"
STUB_RC=1 STUB_ERR=$'Error: No state file was found!\n' run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "a first run (no state object yet) answers false, not an error" || bad "absent state: rc=$RC out=[$OUT] err=[$ERR]"

echo "=== the bootstrap is there and the secrets are not ==="
STUB_OUT="$LOST" run
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q 'talos_machine_secrets' <<<"$ERR" && grep -q 'infra-down-plan' <<<"$ERR" \
  && grep -q 'Lost the Talos secrets' <<<"$ERR" && grep -q 'Do not run cluster-up or infra-apply' <<<"$ERR" \
  && ok "refused with nothing on stdout, naming the secrets, the likely cause and where the recovery is" \
  || bad "a state without its secrets was answered (rc=$RC out=[$OUT] err=[$ERR])"
# The trigger is any resource that only exists because the secrets did, not the bootstrap alone: a destroy
# interrupted after the bootstrap went leaves a machine config behind (decision, #66).
for r in talos_machine_bootstrap.this[0] talos_machine_configuration_apply.worker[0] talos_cluster_kubeconfig.this[0]; do
  STUB_OUT="module.talos.$r" run
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "…${r%%.*} alone, whatever else the state holds, is enough to refuse" \
    || bad "a state holding only $r was answered (rc=$RC out=[$OUT])"
done
STUB_OUT=$'module.talos.talos_machine_configuration_apply.cp[0]\nmodule.talos.talos_machine_secrets.this[0]' run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "secrets and a machine config but no bootstrap (a bootstrap removed by hand): false, not refused" \
  || bad "secrets without the bootstrap: rc=$RC out=[$OUT] err=[$ERR]"
STUB_OUT=$'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.terraform_data.talos_port_ready_cp[0]' run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "machines and a port guard but no secrets and nothing built on them: false, not refused" \
  || bad "nothing built on the secrets: rc=$RC out=[$OUT] err=[$ERR]"
STUB_OUT="$UNPROT" run
[ "$RC" = 0 ] && [ "$OUT" = true ] && ok "the unprotected twin of the secrets (tofu test) counts as the secrets" \
  || bad "unprotected secrets were not accepted: rc=$RC out=[$OUT] err=[$ERR]"

echo "=== the state cannot be read ==="
STUB_RC=1 STUB_ERR='Error: S3: 503 SlowDown' run
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q 'SlowDown' <<<"$ERR" && grep -q 'unknown' <<<"$ERR" \
  && ok "a failed read refuses, prints nothing on stdout, and quotes why" \
  || bad "a failed read was answered (rc=$RC out=[$OUT] err=[$ERR])"
STUB_RC=1 STUB_OUT="$LIVE" STUB_ERR='Error: connection reset' run
[ "$RC" -ne 0 ] && [ -z "$OUT" ] \
  && ok "…even when a partial listing holding the bootstrap came out before the failure" \
  || bad "a partial listing was trusted (rc=$RC out=[$OUT])"
STUB_RC=1 STUB_ERR='Error: Failed to load state: decryption failed' run
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "a state that will not decrypt is refused too" || bad "decrypt failure answered (rc=$RC out=[$OUT])"

echo "=== each script that calls it stops, before it plans, drains or applies ==="
# The real scripts and the real helper in a copy of the tree; tofu answers `state list` from a file and logs the
# rest, kubectl and talosctl only log. A control with the secrets present proves the stubs reach each guard.
W="$TMP/tree"; C="$W/infrastructure/opentofu/cluster"; mkdir -p "$C/envs" "$W/scripts"/{ops,lib,internal,bootstrap} "$TMP/sb"
for f in ops/rolling-replace.sh ops/shrink-nodes.sh lib/common.sh lib/roll-gates.sh internal/refuse-node-deletes.sh bootstrap/grow-nodes.sh; do
  cp "$ROOT/scripts/$f" "$W/scripts/$f"; done
cp "$SUT" "$W/scripts/internal/bootstrap-in-state.sh"
: >"$C/envs/management-scaleway.tfvars"; : >"$C/talosconfig"; : >"$C/kubeconfig"; : >"$C/p.tfplan"
printf '#!/usr/bin/env bash\necho "tofu $*" >>"$CALLS"\n[ "$1 $2" = "state list" ] && { cat "$STATE_FILE"; exit 0; }\nexit 1\n' >"$TMP/sb/tofu"
for b in kubectl talosctl; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\nexit 1\n' "$b" >"$TMP/sb/$b"; done
chmod +x "$TMP/sb"/* "$W/scripts"/*/*.sh
export CALLS="$TMP/calls" STATE_FILE="$TMP/state"
guarded() { # <label> <command…>, in the cluster dir
  local label="$1"; shift
  printf '%s\n' "$LOST" >"$STATE_FILE"; : >"$CALLS"
  ( cd "$C" && PATH="$TMP/sb:$PATH" "$@" ) >"$TMP/o" 2>"$TMP/e"; local rc=$?
  [ "$rc" -ne 0 ] && grep -q 'talos_machine_secrets' "$TMP/e" && [ "$(grep -vc '^tofu state list' "$CALLS")" = 0 ] \
    && ok "$label: refused with the state's own reason, and nothing else was called" \
    || bad "$label on a state without its secrets (rc=$rc, calls: $(tr '\n' ';' <"$CALLS")): $(cat "$TMP/e")"
  printf '%s\n' "$LIVE" >"$STATE_FILE"; : >"$CALLS"
  ( cd "$C" && PATH="$TMP/sb:$PATH" "$@" ) >"$TMP/o" 2>"$TMP/e"
  [ "$(grep -vc '^tofu state list' "$CALLS")" -gt 0 ] && ok "…and $label goes on from the same state with its secrets" \
    || bad "$label never got past the guard with the secrets present: $(cat "$TMP/e")"
}
guarded "grow-nodes" ../../../scripts/bootstrap/grow-nodes.sh management scaleway
guarded "shrink-nodes" ../../../scripts/ops/shrink-nodes.sh scaleway --role=management --plan
guarded "rolling-replace" ../../../scripts/ops/rolling-replace.sh scaleway --role=management --workers-only
guarded "the plan guard" ../../../scripts/internal/refuse-node-deletes.sh p.tfplan

echo "=== the Taskfile's two call sites ==="
code() { grep -vE '^[[:space:]]*#' "$ROOT/Taskfile.yml"; }   # a comment that keeps an old line is not a caller
[ "$(code | grep -c 'scripts/internal/bootstrap-in-state.sh')" = 2 ] \
  && ok "infra-apply and infra-plan resolve talos_bootstrap through it" || bad "expected two call sites in the Taskfile"
! code | grep -q "tofu state list 2>/dev/null | grep -q 'module.talos.talos_machine_bootstrap'" \
  && ok "…and no inline copy of the old guard is left" || bad "an inline copy of the old guard survives"
[ "$(code | grep 'bootstrap-in-state.sh' | grep -c '|| exit 1')" = 2 ] \
  && ok "…and each stops on its failure instead of carrying on with an empty TB" || bad "a call site ignores the script's exit code"

echo "=== the recovery the refusal points to exists ==="
grep -q '^### Lost the Talos secrets$' "$ROOT/infrastructure/opentofu/cluster/README.md" \
  && ok "the README has the heading the helper and the Taskfile quote" || bad "no 'Lost the Talos secrets' heading in the cluster README"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
