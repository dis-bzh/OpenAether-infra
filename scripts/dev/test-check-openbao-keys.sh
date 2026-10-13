#!/usr/bin/env bash
# check-openbao-keys.sh against real gpg keys: one that can encrypt, one that can only sign, junk, and no keys at all.
# Needs gpg; without it the script says so and exits 0 (a skip is not a pass).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v gpg >/dev/null 2>&1 || { echo "↷ test-check-openbao-keys not run: gpg is missing (a skip is not a pass)"; exit 0; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export GNUPGHOME="$SB/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
SCRIPT=scripts/internal/check-openbao-keys.sh

gpg --batch --quiet --passphrase '' --quick-gen-key good@example.invalid rsa2048 sign never 2>/dev/null
F="$(gpg --list-keys --with-colons good@example.invalid | awk -F: '/^fpr/{print $10; exit}')"
gpg --batch --quiet --passphrase '' --quick-add-key "$F" rsa2048 encr never 2>/dev/null
gpg --export good@example.invalid | base64 -w0 > "$SB/good"
gpg --batch --quiet --passphrase '' --quick-gen-key signonly@example.invalid rsa2048 sign never 2>/dev/null
gpg --export signonly@example.invalid | base64 -w0 > "$SB/signonly"
JUNK="$(head -c 300 /dev/urandom | base64 -w0)"

tfvars() { # <key>... — a tfvars with a comment, the list and an unrelated string after it
  { echo 'environment = "prod"'; echo 'openbao_recovery_pgp_keys = ['; for k in "$@"; do echo "  \"$k\",   # someone"; done; echo ']'; echo 'git_ref = "refs/tags/0.1.0"'; } > "$SB/env.tfvars"
}
run() { OUT="$(bash "$SCRIPT" "$SB/env.tfvars" 2>&1)"; RC=$?; }

tfvars "$(cat "$SB/good")" "$(cat "$SB/good")" "$(cat "$SB/good")"
run; [ "$RC" = 0 ] && ok "three keys that can encrypt pass" || bad "rc=$RC $OUT"
grep -q "$F" <<<"$OUT" && ok "…and the fingerprint is printed for the person to compare" || bad "no fingerprint: $OUT"
[ "$(grep -c 'can encrypt' <<<"$OUT")" = 3 ] && ok "…one line per key" || bad "$OUT"

tfvars "$(cat "$SB/good")" "$(cat "$SB/signonly")" "$(cat "$SB/good")"
run; [ "$RC" -ne 0 ] && ok "a signing-only key is refused" || bad "rc=0 with a signing-only key"
grep -q 'keys\[2\].*no usable encryption subkey' <<<"$OUT" && ok "…naming which one" || bad "$OUT"

tfvars "$(cat "$SB/good")" "$JUNK" "$(cat "$SB/good")"
run; [ "$RC" -ne 0 ] && grep -q 'keys\[2\].*not a PGP public key' <<<"$OUT" && ok "something that is base64 but not a key is refused" || bad "rc=$RC $OUT"

printf 'environment = "dev"\ngit_ref = "refs/tags/0.1.0"\n' > "$SB/env.tfvars"
run; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok "no keys at all (a development bootstrap): silent, exit 0" || bad "rc=$RC $OUT"

printf 'openbao_recovery_pgp_keys = [\n  # "%s",\n]\n' "$(cat "$SB/signonly")" > "$SB/env.tfvars"
run; [ "$RC" = 0 ] && ok "a key in a comment is not a key" || bad "rc=$RC $OUT"

echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
