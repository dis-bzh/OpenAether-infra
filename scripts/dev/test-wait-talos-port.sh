#!/usr/bin/env bash
# infrastructure/opentofu/modules/talos/scripts/wait-talos-port.sh, the guard that waits for a new node's Talos API, and its OVH recovery (lab 27 part B, D6/D11,
# infra #371): after RECOVER_AFTER seconds without an answer it asks the provider for a hard reboot, at most RECOVER_MAX times, never when
# it is off, never fatal on its own, and never when the node answers at once. A fake listener and a fake openssl stand for a live Talos,
# a fake node-provider for the cloud: no network, no credential.
# Usage: test-wait-talos-port.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/infrastructure/opentofu/modules/talos/scripts/wait-talos-port.sh}"
TMP="$(mktemp -d)"
trap 'kill "${LISTEN_PID:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
# What openssl s_client prints against a node that answers the handshake.
cat >"$TMP/bin/openssl" <<'S'
#!/usr/bin/env bash
echo "CONNECTION ESTABLISHED"
S
cat >"$TMP/provider" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
[ "${PROVIDER_RC:-0}" = 0 ] && echo '{"accepted": true}' || { echo '{"accepted": false, "refused": "too old"}'; exit 3; }
S
chmod +x "$TMP/bin/openssl" "$TMP/provider"
export CALLS="$TMP/calls" PATH="$TMP/bin:$PATH"

# A free local port that nothing listens on, and one that does.
FREE="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I - "$TMP/live" <<'PY' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept(); c.close()
PY
LISTEN_PID=$!
for _ in $(seq 50); do [ -s "$TMP/live" ] && break; sleep 0.1; done
LIVE="$(cat "$TMP/live")"

run() { # <port> <env…> — one run of the guard; sets OUT, RC
  local port="$1"; shift
  : >"$CALLS"
  OUT="$(env -i PATH="$PATH" CALLS="$CALLS" ENDPOINT="127.0.0.1:${port}" NODE=10.0.0.12 POLL_SECONDS=1 MAX_WAIT_SECONDS=8 "$@" bash "$SUT" 2>&1)"; RC=$?
}
calls() { wc -l <"$CALLS" | tr -d ' '; }

echo "=== wait-talos-port.sh: the recovery ==="
run "$FREE"
{ [ "$RC" -eq 1 ] && [ "$(calls)" = 0 ]; } && ok_ "off by default: a node that never answers fails at the bound and nothing is rebooted" || bad "default run: rc=${RC} calls=$(calls)"

run "$FREE" RECOVER_AFTER=0 RECOVER_PROVIDER=ovh RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/provider"
{ [ "$RC" -eq 1 ] && [ "$(calls)" = 0 ]; } && ok_ "RECOVER_AFTER=0 is off even with a provider named" || bad "RECOVER_AFTER=0 rebooted (calls=$(calls))"

run "$FREE" RECOVER_AFTER=3 RECOVER_PROVIDER=ovh RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/provider"
{ [ "$RC" -eq 1 ] && [ "$(calls)" = 2 ]; } && ok_ "on: two hard reboots at most, 3 s apart, then the wait ends at its bound (rc 1)" || bad "recovery: rc=${RC} calls=$(calls): ${OUT}"
{ grep -q '^hard-reboot ovh --name c-cp-2 --ip 10.0.0.12 --younger-than 3600$' "$CALLS"; } && ok_ "…asking for the machine of this node, by name and address, and only while it is young" || bad "the call was: $(head -1 "$CALLS")"

run "$FREE" RECOVER_AFTER=3 RECOVER_MAX=1 RECOVER_PROVIDER=ovh RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/provider"
[ "$(calls)" = 1 ] && ok_ "RECOVER_MAX bounds the number of reboots" || bad "RECOVER_MAX=1 gave $(calls) calls"

run "$FREE" PROVIDER_RC=3 RECOVER_AFTER=3 RECOVER_PROVIDER=ovh RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/provider"
{ [ "$RC" -eq 1 ] && grep -q 'NOT done (the wait goes on)' <<<"$OUT" && grep -q 'too old' <<<"$OUT"; } \
  && ok_ "a refused reboot (an old machine) is said, with the provider's reason, and the wait goes on" || bad "refusal: rc=${RC}: ${OUT}"

run "$FREE" RECOVER_AFTER=3 RECOVER_PROVIDER=ovh RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/missing"
{ [ "$RC" -eq 1 ] && grep -q 'NOT done' <<<"$OUT"; } && ok_ "a provider command that cannot run is not fatal either" || bad "missing command: rc=${RC}: ${OUT}"

run "$FREE" RECOVER_AFTER=3 RECOVER_PROVIDER= RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/provider"
[ "$(calls)" = 0 ] && ok_ "no provider named (every provider but OVH) reboots nothing" || bad "rebooted without a provider"

run "$LIVE" RECOVER_AFTER=3 RECOVER_PROVIDER=ovh RECOVER_NAME=c-cp-2 RECOVER_CMD="$TMP/provider"
{ [ "$RC" -eq 0 ] && [ "$(calls)" = 0 ] && grep -q 'Talos API answering' <<<"$OUT"; } && ok_ "a node that answers at once is never rebooted" || bad "live node: rc=${RC} calls=$(calls)"

echo
echo "=== the module wires it, and the root turns it on for OVH only ==="
T="$ROOT/infrastructure/opentofu"
[ "$(grep -c 'RECOVER_PROVIDER = var.port_ready_recovery.provider' "$T/modules/talos/main.tf")" = 2 ] \
  && [ "$(grep -c 'RECOVER_NAME     = "${var.cluster_name}-' "$T/modules/talos/main.tf")" = 2 ] \
  && [ "$(grep -c 'node-provider.py' "$T/modules/talos/main.tf")" -ge 2 ] \
  && ok_ "both guards (control plane and worker) pass the provider, the instance name and the script to the wait" || bad "the module does not pass the recovery environment to both guards"
grep -q 'provider      = contains(local.active_providers, "ovh") ? "ovh" : ""' "$T/cluster/main.tf" \
  && grep -q 'default     = 300' <(sed -n '/variable "port_ready_hard_reboot_after_seconds"/,/^}/p' "$T/cluster/variables.tf") \
  && ok_ "the root passes \"ovh\" only when OVH is active, 300 s by default" || bad "the root wiring changed"
grep -q -- '--younger-than' "$ROOT/scripts/ops/node-provider.py" \
  && ok_ "node-provider.py knows the age limit the guard sends" || bad "node-provider.py has no --younger-than"

kill "$LISTEN_PID" 2>/dev/null
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
