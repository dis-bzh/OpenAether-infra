#!/usr/bin/env bash
# scripts/internal/tunnel-guard.sh: the check before a plan or an apply of a bootstrapped state. It runs for
# real in a fake repository whose talos-tunnels.sh is a stub that logs how it was called. SUT overrides the
# script, which is how mutants run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/internal/tunnel-guard.sh}"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts/internal" "$W/scripts/bootstrap" "$W/cluster"
cp "$SUT" "$W/scripts/internal/tunnel-guard.sh"
cat >"$W/scripts/bootstrap/talos-tunnels.sh" <<'STUB'
#!/usr/bin/env bash
echo "ensure key=${SSH_KEY:-unset} args=$*" >>"$CALLS"; exit "${STUB_ENSURE_RC:-0}"
STUB
chmod +x "$W"/scripts/*/*.sh
export CALLS="$W/calls.log"
run() { # <env…> -- <args…>; sets OUT, RC
  : >"$CALLS"; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  OUT="$(cd "$W/cluster" && env "${e[@]}" "$W/scripts/internal/tunnel-guard.sh" "$@" 2>&1)"; RC=$?
}

run X=1 -- /k/key
{ [ "$RC" = 0 ] && grep -q 'ensure key=/k/key args=ensure \.' "$CALLS"; } \
  && ok "tunnels that answer: rc 0, ensure called with the key, from the cluster dir" || bad "healthy (rc ${RC}): $(cat "$CALLS") ${OUT}"
run STUB_ENSURE_RC=1 -- /k/key
{ [ "$RC" = 1 ] && grep -q 'OA_SKIP_TUNNEL_GUARD=1' <<<"$OUT" && grep -q 'TF_VAR_skip_health_check=true' <<<"$OUT" && grep -q 'admin_ip' <<<"$OUT"; } \
  && ok "tunnels that cannot be rebuilt: rc 1, and the message names the changed-admin_ip way out, both variables" || bad "broken (rc ${RC}): ${OUT}"
run OA_SKIP_TUNNEL_GUARD=1 STUB_ENSURE_RC=1 -- /k/key
{ [ "$RC" = 0 ] && [ ! -s "$CALLS" ]; } && ok "OA_SKIP_TUNNEL_GUARD=1: rc 0 and ensure is not even called" || bad "skip (rc ${RC}): $(cat "$CALLS")"
run OA_SKIP_TUNNEL_GUARD=0 STUB_ENSURE_RC=1 -- /k/key
[ "$RC" = 1 ] && ok "only the value 1 skips it" || bad "OA_SKIP_TUNNEL_GUARD=0 skipped the check (rc ${RC})"
run X=1 --
{ [ "$RC" != 0 ] && grep -q 'usage' <<<"$OUT" && [ ! -s "$CALLS" ]; } && ok "no key: a usage error, nothing called" || bad "no key (rc ${RC}): ${OUT}"

TF="$ROOT/Taskfile.yml"
[ "$(grep -c 'scripts/internal/tunnel-guard.sh "{{.KEY}}"' "$TF")" = 2 ] \
  && ok "infra-plan and infra-apply both go through the guard, with the key" || bad "the guard is not wired at both sites"
grep -n 'talos-tunnels.sh ensure' "$TF" | grep -v '^\S*:\s*#' | grep -q . \
  && bad "an inline 'talos-tunnels.sh ensure' is back in the Taskfile: $(grep -n 'talos-tunnels.sh ensure' "$TF" | head -3)" \
  || ok "…and no inline copy of the check is left beside it"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
