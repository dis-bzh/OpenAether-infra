#!/usr/bin/env bash
# The passphrase heuristic and its three modes (warn / enforce / off), offline. A heuristic cannot prove entropy:
# what is asserted is that the documented generators never trip it, that the obvious weak shapes do, and that
# the default (warn) never refuses what `cluster-up` accepted before.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
oa_require_fn oa_passphrase_problems oa_check_passphrase || exit 1
CHK="$ROOT/scripts/internal/check-passphrase.sh"; GEN="$ROOT/scripts/ops/gen-passphrase.sh"

echo "=== what the documented generators produce is never flagged ==="
flagged=0
for _ in $(seq 40); do
  [ -z "$(oa_passphrase_problems "$("$GEN")")" ] || flagged=$((flagged + 1))
  [ -z "$(oa_passphrase_problems "$(openssl rand -base64 48)")" ] || flagged=$((flagged + 1))
  [ -z "$(oa_passphrase_problems "$(openssl rand -hex 32)")" ] || flagged=$((flagged + 1))
done
[ "$flagged" = 0 ] && ok "120 generated values (gen-passphrase.sh, base64 48, hex 32): none flagged" || bad "$flagged generated values were flagged"
out="$("$GEN")"
{ [ "$(wc -l <<<"$out")" = 1 ] && [ "${#out}" = 64 ]; } && ok "gen-passphrase.sh prints one line of 64 characters (48 random bytes)" || bad "gen output: ${#out} chars"
[ -z "$(oa_passphrase_problems "$(openssl rand -hex 16)")" ] && ok "a 32-character hex value (128 bits) is accepted" || bad "hex 16 flagged"

echo "=== the obvious weak shapes are flagged, each for its own reason ==="
want() { # label value expected-fragment
  local got; got="$(oa_passphrase_problems "$2")"
  grep -q -- "$3" <<<"$got" && ok "$1" || bad "$1 — got: ${got:-nothing}"
}
want "too short" "short-and-guessable" "shorter than 32"
want "the shipped placeholder" "change-me-to-a-long-random-passphrase-min-32-chars" "common word"
want "the test fixture style" "fixture-passphrase-of-at-least-32-characters" "common word"
want "a dictionary phrase (few distinct characters)" "correct-horse-battery-staple-32chars" "distinct characters"
want "one block repeated" "Xk9#mP2\$vL8@nQ4!Xk9#mP2\$vL8@nQ4!" "one block repeated"
want "a run of one character" "Xk9#mP2\$vL8@nQ4!wR7&tY5*uI3^oEEEEEE6%" "run of six"
want "hex with too few distinct characters" "ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12" "hex string"

echo "=== modes ==="
WEAK="correct-horse-battery-staple-32chars"; GOOD="$("$GEN")"
OA_PASSPHRASE_CHECK=warn oa_check_passphrase P "$WEAK" 2>/dev/null; [ $? = 0 ] && ok "warn (explicit): weak value accepted" || bad "warn refused"
err="$(oa_check_passphrase P "$WEAK" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q '⚠ P looks weak' <<<"$err" && grep -q 'gen-passphrase.sh' <<<"$err"; } && ok "default is warn: says so, names the generator, exits 0" || bad "default mode: rc=$rc $err"
grep -q "$WEAK" <<<"$err" && bad "the value was printed" || ok "the value is never printed"
err="$(OA_PASSPHRASE_CHECK=enforce oa_check_passphrase P "$WEAK" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && grep -q '✗ P looks weak' <<<"$err"; } && ok "enforce: weak value refused" || bad "enforce: rc=$rc $err"
OA_PASSPHRASE_CHECK=enforce oa_check_passphrase P "$GOOD" 2>/dev/null && ok "enforce: a generated value passes" || bad "enforce refused a generated value"
OA_PASSPHRASE_CHECK=off oa_check_passphrase P "$WEAK" 2>/dev/null && [ -z "$(OA_PASSPHRASE_CHECK=off oa_check_passphrase P "$WEAK" 2>&1)" ] && ok "off: silent, accepted" || bad "off"
OA_PASSPHRASE_CHECK=bogus oa_check_passphrase P "$GOOD" 2>/dev/null; [ $? = 2 ] && ok "an unknown mode is an error, not a silent off" || bad "bogus mode accepted"

echo "=== check-passphrase.sh (what cluster-up runs) ==="
run() { env -i PATH="$PATH" HOME="$HOME" "$@" bash "$CHK" 2>&1; }
run TF_VAR_encryption_passphrase="$GOOD" >/dev/null && ok "a generated state passphrase: silent success" || bad "good state passphrase refused"
run TF_VAR_encryption_passphrase="$WEAK" >/dev/null && ok "a weak one under the default: still success (warn)" || bad "default refused a weak passphrase"
run OA_PASSPHRASE_CHECK=enforce TF_VAR_encryption_passphrase="$WEAK" >/dev/null && bad "enforce let a weak state passphrase through" || ok "a weak one under enforce: refused"
ART="$("$GEN")"
run OA_PASSPHRASE_CHECK=enforce TF_VAR_encryption_passphrase="$GOOD" TF_VAR_artifact_passphrase="$ART" >/dev/null && ok "two distinct generated passphrases pass enforce" || bad "distinct passphrases refused"
out="$(run OA_PASSPHRASE_CHECK=enforce TF_VAR_encryption_passphrase="$GOOD" TF_VAR_artifact_passphrase="$GOOD")"; rc=$?
{ [ "$rc" != 0 ] && grep -q 'equals TF_VAR_encryption_passphrase' <<<"$out"; } && ok "enforce: an artifact passphrase equal to the state one is refused" || bad "equal passphrases: rc=$rc $out"
out="$(run TF_VAR_encryption_passphrase="$GOOD" TF_VAR_artifact_passphrase="$GOOD")"; rc=$?
{ [ "$rc" = 0 ] && grep -q 'equals' <<<"$out"; } && ok "warn: equal passphrases are reported but not refused" || bad "equal, warn: rc=$rc $out"
run OA_PASSPHRASE_CHECK=enforce TF_VAR_encryption_passphrase="$GOOD" TF_VAR_artifact_passphrase= >/dev/null && ok "an empty artifact passphrase counts as unset" || bad "empty artifact passphrase refused"

echo "=== the wiring a tofu test cannot see: what the backup provisioner receives ==="
# artifact-passphrase.tftest.hcl asserts the local, not the local-exec environment (a mock plan has no provisioner).
BK="$ROOT/infrastructure/opentofu/cluster/backup.tf"
grep -Eq '^[[:space:]]*PASSPHRASE[[:space:]]*=[[:space:]]*local\.artifact_passphrase[[:space:]]*$' "$BK" \
  && ok "backup.tf hands the script local.artifact_passphrase, not the state passphrase" || bad "backup.tf PASSPHRASE is not local.artifact_passphrase"
grep -Eq 'PASSPHRASE[[:space:]]*=.*var\.encryption_passphrase' "$BK" && bad "backup.tf hands PASSPHRASE the state passphrase directly" || ok "no PASSPHRASE assignment bypasses the local"
grep -q 'PASSPHRASE="${TF_VAR_artifact_passphrase:-$TF_VAR_encryption_passphrase}"' "$ROOT/scripts/ops/etcd-snapshot.sh" \
  && ok "etcd-snapshot.sh prefers TF_VAR_artifact_passphrase, then the state one" || bad "etcd-snapshot.sh passphrase selection changed"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
