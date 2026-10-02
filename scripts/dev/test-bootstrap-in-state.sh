#!/usr/bin/env bash
# scripts/internal/bootstrap-in-state.sh: the answer `infra-plan` and `infra-apply`
# pass as -var talos_bootstrap. A stub tofu stands for the state; each case runs the
# real script. SUT overrides the script, which is how the mutants run.
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

echo "=== the state answers ==="
STUB_OUT="$LIVE" run
[ "$RC" = 0 ] && [ "$OUT" = true ] && ok "a state holding the bootstrap answers true" || bad "bootstrapped state: rc=$RC out=[$OUT]"
STUB_OUT="$FRESH" run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "a state without it answers false" || bad "unbootstrapped state: rc=$RC out=[$OUT]"
STUB_OUT="" run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "an empty state answers false" || bad "empty state: rc=$RC out=[$OUT]"
STUB_RC=1 STUB_ERR=$'Error: No state file was found!\n' run
[ "$RC" = 0 ] && [ "$OUT" = false ] && ok "a first run (no state object yet) answers false, not an error" || bad "absent state: rc=$RC out=[$OUT] err=[$ERR]"

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

echo "=== both call sites use it ==="
[ "$(grep -c 'scripts/internal/bootstrap-in-state.sh' "$ROOT/Taskfile.yml")" = 2 ] \
  && ok "infra-apply and infra-plan resolve talos_bootstrap through it" || bad "expected two call sites in the Taskfile"
! grep -q "tofu state list 2>/dev/null | grep -q 'module.talos.talos_machine_bootstrap'" "$ROOT/Taskfile.yml" \
  && ok "…and no inline copy of the old guard is left" || bad "an inline copy of the old guard survives"
[ "$(grep -c '|| exit 1' <(grep 'bootstrap-in-state.sh' "$ROOT/Taskfile.yml"))" = 2 ] \
  && ok "…and each stops on its failure instead of carrying on with an empty TB" || bad "a call site ignores the script's exit code"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
