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
# A flagged draw is printed with its value and its rules, so a rare red names its own cause (infra #416). The value is a
# test draw, never used as a secret.
draw_check() { # label value
  local why; why="$(oa_passphrase_problems "$2")"
  [ -z "$why" ] && return 0
  flagged=$((flagged + 1))
  printf '    flagged %s draw: %s -> %s\n' "$1" "$2" "$(paste -sd ';' <<<"$why")"
}
for _ in $(seq 40); do
  draw_check gen-passphrase "$("$GEN")"
  draw_check base64-48 "$(openssl rand -base64 48)"
  draw_check hex-32 "$(openssl rand -hex 32)"
done
[ "$flagged" = 0 ] && ok "120 generated values (gen-passphrase.sh, base64 48, hex 32): none flagged" || bad "$flagged generated values were flagged (listed above)"
out="$(draw_check forced "$(printf 'a%.0s' $(seq 40))")"
{ grep -q 'forced draw: a\{40\} ->' <<<"$out" && grep -q 'one block repeated' <<<"$out"; } \
  && ok "a flagged draw is printed with its value and the rule that flagged it" || bad "draw_check output: ${out:-nothing}"
out="$("$GEN")"
{ [ "$(wc -l <<<"$out")" = 1 ] && [ "${#out}" = 64 ]; } && ok "gen-passphrase.sh prints one line of 64 characters (48 random bytes)" || bad "gen output: ${#out} chars"
# A fixed value: a random hex-16 has fewer than 10 distinct characters about once in 10^4 draws and the heuristic then
# rightly flags it, which made this line flaky.
[ -z "$(oa_passphrase_problems "9f86d081884c7d659a2feaa0c55ad015")" ] && ok "a 32-character hex value (128 bits) is accepted" || bad "hex 16 flagged"

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

echo "=== a random hex draw is not flagged for what chance puts in it, some typed shapes still are (infra #416) ==="
# 64 hex characters from `openssl rand -hex 32` carry a run of six identical characters about once in 18,000 draws
# and "abcdef" or "123456" somewhere about once in 140,000 (computed; a replica over 1,000,000 simulated draws flagged
# 62 under the old rules, 0 under the new): those are not weaknesses of a random value. Hex keeps the guard in a form
# chance does not trip: a run of ten (about 8e-10 per draw), a word only at the start (about 1.2e-7) or twice, plus the
# distinct-character and repeated-block rules. A typed value with one word inside and none of these is accepted.
hex_tail="1c7a9b3d5f2e8c4a6071b9d3f5e7a2c4b6d8091a3f"
accept() { # label value: a random-looking hex value has to pass
  local got; got="$(oa_passphrase_problems "$2")"
  [ -z "$got" ] && ok "$1" || bad "$1 — flagged: $(paste -sd ';' <<<"$got")"
}
accept "hex with a run of six identical characters inside is accepted" "3f9a7c1e5b2d8046eeeeee$hex_tail"
accept "hex with 'abcdef' inside is accepted" "3f9a7c1e5b2d8046abcdef$hex_tail"
accept "hex with '123456' inside is accepted" "3f9a7c1e5b2d8046123456$hex_tail"
accept "hex with an uppercase 'ABCDEF' inside is accepted" "3F9A7C1E5B2D8046ABCDEF$hex_tail"
want "hex with a run of ten is still flagged" "3f9a7c1e5b2d8046eeeeeeeeee$hex_tail" "run of ten"
want "hex that starts with 'abcdef' is still flagged" "abcdef9a7c1e5b2d8046$hex_tail" "common word 'abcdef'"
want "hex that starts with '123456' is still flagged" "1234563f9a7c1e5b2d80$hex_tail" "common word '123456'"
want "hex that carries 'abcdef' twice is still flagged" "3f9a7c1eabcdef2d8046${hex_tail}abcdef" "repeats the common word 'abcdef'"
want "the lazy hex 0123456789abcdef0123456789abcdef0123 is still flagged" "0123456789abcdef0123456789abcdef0123" "common word"
want "a non-hex value with 'abcdef' inside is still flagged" "Xk9#mP2\$vL8@nQ4!abcdefwR7&tY5*uI3^oE" "common word 'abcdef'"
want "a non-hex value with a run of six is still flagged" "Xk9#mP2\$vL8@nQ4!wR7&tY5*uI3^oE111111" "run of six"

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
