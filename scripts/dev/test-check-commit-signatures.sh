#!/usr/bin/env bash
# Tests of check-commit-signatures.sh against a throwaway repository with a throwaway GPG key (never this repo's
# history, never a real key): signed passes, unsigned warns, --strict fails, an unknown signer (status E) still counts
# as signed, a failing git log is exit 2. Rung: mocked/static.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/dev/check-commit-signatures.sh"
TMP="$(mktemp -d)"
trap 'gpgconf --homedir "$TMP/gnupg" --kill gpg-agent 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
expect() { # <description> <expected exit> <expected output regex> -- command...
  local desc="$1" code="$2" re="$3"; shift 4
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$code" ] && grep -qE "$re" <<<"$out"; then ok "$desc"; else bad "$desc (exit $rc, wanted $code): $out"; fi
}

if ! command -v gpg >/dev/null; then echo "gpg missing: cannot run"; exit 1; fi
mkdir -m 700 "$TMP/gnupg"
export GNUPGHOME="$TMP/gnupg"
gpg --batch --quiet --passphrase '' --quick-generate-key 'Test Signer <signer@example.invalid>' ed25519 sign never 2>/dev/null
key="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')"

repo="$TMP/repo"
git init -q "$repo"
cd "$repo" || exit 1
git config user.email signer@example.invalid
git config user.name "Test Signer"
git config gpg.program gpg
echo 0 > f; git add f; git commit -q -m "base"
base="$(git rev-parse HEAD)"
echo 1 > f; git -c user.signingkey="$key" commit -q -S -am "signed"
signed="$(git rev-parse HEAD)"
echo 2 > f; git commit -q -am "unsigned"
unsigned="$(git rev-parse HEAD)"

# An expired key (status Y/X) must be reported: sign in the past with a key that expired since. The wrapper plays
# the faked clock only for the signing step; verification runs on the real clock.
cat >"$TMP/gpg-past" <<WRAP
#!/usr/bin/env bash
if [ -n "\${GPG_PAST:-}" ]; then exec gpg --faked-system-time "\$GPG_PAST" "\$@"; fi
exec gpg "\$@"
WRAP
chmod +x "$TMP/gpg-past"
past="$(date -u -d '30 days ago' +%Y%m%dT%H%M%S)"
gpg --batch --quiet --passphrase '' --faked-system-time "$past" \
  --quick-generate-key 'Expired Signer <expired@example.invalid>' ed25519 sign 1d 2>/dev/null
expkey="$(gpg --list-secret-keys --with-colons expired@example.invalid | awk -F: '/^fpr/ {print $10; exit}')"
git checkout -q "$signed"; echo 3 > f
GPG_PAST="$past" git -c gpg.program="$TMP/gpg-past" -c user.signingkey="$expkey" commit -q -S -am "expired"
expired="$(git rev-parse HEAD)"
git checkout -q "$unsigned"
expect "expired key or signature (X/Y): reported" 0 'signature status [XY]' -- "$CHECKER" "$signed..$expired"
expect "expired key or signature (X/Y) under --strict: fail" 1 'signature status [XY]' -- "$CHECKER" --strict "$signed..$expired"

# A merge commit (unsigned, like GitHub's refs/pull/N/merge) must not count: --strict passes on signed commits.
git checkout -q -b side "$base"; echo s > g; git add g; git -c user.signingkey="$key" commit -q -S -am "side signed"
git checkout -q "$signed"
git merge -q --no-ff side -m "Merge side" >/dev/null 2>&1; merged="$(git rev-parse HEAD)"
expect "unsigned merge commit in the range is ignored" 0 'carry a signature' -- "$CHECKER" --strict "$base..$merged"

expect "signed commit: pass" 0 'carry a signature' -- "$CHECKER" "$base..$signed"
expect "unsigned commit: warning, exit 0" 0 'not signed' -- "$CHECKER" "$signed..$unsigned"
expect "unsigned commit under --strict: fail" 1 'unsigned or badly signed' -- "$CHECKER" --strict "$signed..$unsigned"
expect "signed commit under --strict: pass" 0 'carry a signature' -- "$CHECKER" --strict "$base..$signed"
expect "mixed range under --strict: fail" 1 'not signed' -- "$CHECKER" --strict "$base..$unsigned"
GNUPGHOME="$TMP/empty" expect "signer key unknown to the runner (E): counts as signed" 0 'carry a signature' -- \
  "$CHECKER" --strict "$base..$signed"
expect "bad revision: exit 2, no success line" 2 'could not be checked' -- "$CHECKER" "nope..alsonope"
expect "no argument: usage" 1 'usage' -- "$CHECKER"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
