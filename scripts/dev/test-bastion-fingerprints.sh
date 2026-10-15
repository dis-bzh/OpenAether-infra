#!/usr/bin/env bash
# scripts/ops/bastion-fingerprints.sh on a JSON fixture of the bastion_access_keys output: one row per key with the
# account the login line must be matched to, the shared account listed per provider, --find, and a key that is not one.
# SUT overrides the script (mutants).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/bastion-fingerprints.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
for t in ssh-keygen jq; do command -v "$t" >/dev/null || { echo "✗ $t is required"; exit 1; }; done

for k in alice bob shared; do ssh-keygen -q -t ed25519 -N '' -f "$TMP/$k" -C "$k@laptop"; done
fp() { ssh-keygen -lf "$TMP/$1.pub" | awk '{ print $2 }'; }
jq -n --arg a "$(cat "$TMP/alice.pub")" --arg b "from=\"203.0.113.4\" $(cat "$TMP/bob.pub")" --arg s "$(cat "$TMP/shared.pub")" \
  '{shared: {scaleway: [$s]}, operators: {alice: [$a], bob: [$b, "not a key at all"]}}' >"$TMP/keys.json"

OUT="$(bash "$SUT" -f "$TMP/keys.json" 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -qFx "$(printf 'alice\t%s\tED25519\talice@laptop' "$(fp alice)")" <<<"$OUT" && ok "an operator's key is listed under the operator's account with its fingerprint" || bad "alice row: rc=$RC $OUT"
grep -qFx "$(printf 'bob\t%s\tED25519\tbob@laptop' "$(fp bob)")" <<<"$OUT" && ok "a key with an authorized_keys options prefix is read" || bad "bob row: $OUT"
grep -qFx "$(printf 'shared:scaleway\t%s\tED25519\tshared@laptop' "$(fp shared)")" <<<"$OUT" && ok "the shared account is listed per provider" || bad "shared row: $OUT"
grep -qFx "$(printf 'bob\tUNREADABLE\t-\t-')" <<<"$OUT" && ok "an entry that is not a key is reported, not skipped" || bad "unreadable row: $OUT"

OUT="$(bash "$SUT" -f "$TMP/keys.json" --find "$(fp alice)" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(wc -l <<<"$OUT")" = 1 ] && grep -q '^alice' <<<"$OUT" && ok "--find prints only the row of that fingerprint" || bad "--find: rc=$RC $OUT"
OUT="$(bash "$SUT" -f "$TMP/keys.json" --find SHA256:nope 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'no key with fingerprint' <<<"$OUT" && ok "--find of an unknown fingerprint exits 1 and says so (a removed operator?)" || bad "--find unknown: rc=$RC $OUT"
echo '{"shared":{},"operators":{}}' >"$TMP/empty.json"
OUT="$(bash "$SUT" -f "$TMP/empty.json" 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q 'no key in the state' <<<"$OUT" && ok "an empty state says so instead of printing nothing" || bad "empty: rc=$RC $OUT"
bash "$SUT" -f "$TMP/missing.json" >/dev/null 2>&1; [ "$?" = 2 ] && ok "a missing file is refused" || bad "missing file accepted"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
