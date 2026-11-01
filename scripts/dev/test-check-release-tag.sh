#!/usr/bin/env bash
# Tests of check-release-tag.sh in a throwaway repository with throwaway GPG keys (never this repo's tags, never a
# real key): annotated + signed by a listed key passes; lightweight, annotated but unsigned, signed by an unlisted key,
# listed but with no public key file, and a missing tag are refused; --notes must name the release SHA. Rung: mocked.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/dev/check-release-tag.sh"
TMP="$(mktemp -d)"
trap 'gpgconf --homedir "$TMP/gnupg" --kill gpg-agent 2>/dev/null; rm -rf -- "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
expect() { # <description> <expected exit> <expected output regex> -- command...
  local desc="$1" code="$2" re="$3"; shift 4
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$code" ] && grep -qE "$re" <<<"$out"; then ok "$desc"; else bad "$desc (exit $rc, wanted $code): $out"; fi
}

command -v gpg >/dev/null || { echo "gpg missing: cannot run"; exit 1; }
mkdir -m 700 "$TMP/gnupg"
export GNUPGHOME="$TMP/gnupg"
newkey() { gpg --batch --quiet --passphrase '' --quick-generate-key "$1 <$2@example.invalid>" ed25519 sign never 2>/dev/null
           gpg --list-secret-keys --with-colons "$2@example.invalid" | awk -F: '/^fpr/ {print $10; exit}'; }
listed="$(newkey Listed listed)"; stranger="$(newkey Stranger stranger)"; nofile="$(newkey NoFile nofile)"

mkdir "$TMP/signers"
gpg --armor --export "$listed" > "$TMP/signers/listed.asc"
printf '# table\n%s listed\n%s nofile\n' "$listed" "$nofile" > "$TMP/signers/signers.txt"

repo="$TMP/repo"
git init -q "$repo"; cd "$repo" || exit 1
git config user.email t@example.invalid; git config user.name T; git config gpg.program gpg
echo 1 > f; git add f; git commit -q -m base
sha="$(git rev-parse HEAD)"
git tag -s -u "$listed" -m "release" good
git tag light
git tag -a -m "release" unsigned
git tag -s -u "$stranger" -m "release" stranger
git tag -s -u "$nofile" -m "release" nofile
S=(--signers-dir "$TMP/signers")

expect "annotated tag signed by a listed key: ok, SHA printed" 0 "signed by .*release commit $sha" -- "$CHECKER" good "${S[@]}"
expect "lightweight tag: refused" 1 "lightweight tag" -- "$CHECKER" light "${S[@]}"
expect "annotated but unsigned: refused" 1 "no valid signature" -- "$CHECKER" unsigned "${S[@]}"
expect "signed by a key outside the table: refused" 1 "not in" -- "$CHECKER" stranger "${S[@]}"
expect "in the table but no public key file: refused" 1 "not in $TMP/signers|no public key" -- "$CHECKER" nofile "${S[@]}"
expect "missing tag: refused" 1 "does not exist" -- "$CHECKER" nope "${S[@]}"
expect "no tag argument: usage" 2 "usage" -- "$CHECKER"
expect "no signer table: cannot check" 2 "no signer table" -- "$CHECKER" good --signers-dir "$TMP/none"
echo "release $sha" > "$TMP/notes-ok"; echo "release" > "$TMP/notes-bad"
expect "notes naming the SHA: ok" 0 "✓" -- "$CHECKER" good "${S[@]}" --notes "$TMP/notes-ok"
expect "notes without the SHA: refused" 1 "does not name the release commit" -- "$CHECKER" good "${S[@]}" --notes "$TMP/notes-bad"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
