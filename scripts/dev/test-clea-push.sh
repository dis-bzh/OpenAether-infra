#!/usr/bin/env bash
# scripts/clea/push-probes.sh against real git remotes on the local disk.
#
# Only the credential is a stand-in: the remote "bad" does not exist, "expired"
# refuses with GitHub's own words, "good" accepts, so a token's value picks the
# outcome. A rejected PAT must fall back to the default token, one branch that
# cannot be pushed must not stop the others, and no token may reach the log.
# Mutations each case was seen to fail against (PUSH_SCRIPT runs a mutated copy):
# the old inline logic, no fallback, stop at the first failure, a PAT tested by
# set-ness, --force dropped, an apply failure not counted, the name check removed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
ROOT="$PWD"
PUSH="${PUSH_SCRIPT:-$ROOT/scripts/clea/push-probes.sh}"
[ -x "$PUSH" ] || { echo "✗ $PUSH is missing or not executable — nothing was checked" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git -c init.defaultBranch=main init -q "$T/src"
git -C "$T/src" config user.email t@example.invalid; git -C "$T/src" config user.name t
echo base >"$T/src/a.txt"; git -C "$T/src" add a.txt; git -C "$T/src" commit -qm base
BASE="$(git -C "$T/src" rev-parse HEAD)"
mkdir "$T/patches"
for s in alpha beta; do
  git -C "$T/src" checkout -q -b "mk-$s" "$BASE"; echo "$s" >"$T/src/$s.txt"
  git -C "$T/src" add "$s.txt"; git -C "$T/src" commit -qm "probe $s"
  git -C "$T/src" format-patch -1 -q --stdout >"$T/patches/$s.patch"
  git -C "$T/src" checkout -q "$BASE"
done
mkdir "$T/patches-bad" "$T/patches-evil" "$T/patches-empty"
echo "this is not a patch" >"$T/patches-bad/alpha.patch"; cp "$T/patches/beta.patch" "$T/patches-bad/"
cp "$T/patches/beta.patch" "$T/patches-evil/"; cp "$T/patches/alpha.patch" "$T/patches-evil/"$'x\n::warning::FORGED.patch'

fresh() { # new remotes; $1 = a branch "good" must refuse, if any
  rm -rf "$T/remote"; mkdir "$T/remote"; git init -q --bare "$T/remote/good"; git init -q --bare "$T/remote/expired"
  printf '#!/bin/sh\necho "remote: Invalid username or token. Password authentication is not supported for Git operations." >&2\nexit 1\n' >"$T/remote/expired/hooks/pre-receive"
  chmod +x "$T/remote/expired/hooks/pre-receive"
  if [ -n "${1:-}" ]; then
    printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = "refs/heads/%s" ] && { echo "refusing to allow a GitHub App to create or update workflow" >&2; exit 1; }; done; exit 0\n' "$1" >"$T/remote/good/hooks/pre-receive"
    chmod +x "$T/remote/good/hooks/pre-receive"
  fi
  git -C "$T/src" reset -q --hard "$BASE"
}
# The workflow passes the secret SET, and empty when it is absent: do the same.
run() { # <pat or ""> <default> [patches dir]; output in $T/out
  ( cd "$T/src" && env -i PATH="$PATH" HOME="$T" REPO=o/r CLEA_REMOTE_TEMPLATE="file://$T/remote/@TOKEN@" \
      CLEA_WORKFLOW_TOKEN="$1" DEFAULT_TOKEN="$2" "$PUSH" "$BASE" "${3:-$T/patches}" ) >"$T/out" 2>&1
}
pushed() { git -C "$T/remote/good" for-each-ref --format='%(refname:short)' refs/heads/clea/probe | sort | paste -sd' '; }
BOTH="clea/probe/alpha clea/probe/beta"

echo "=== a rejected PAT falls back to the default token, and the log says why ==="
fresh; run bad good; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "$BOTH" ] \
  && ok "PAT rejected: both branches pushed with the default token, exit 0" \
  || bad "PAT rejected (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"
grep -q '::warning::CLEA_WORKFLOW_TOKEN did not push' "$T/out" && grep -q 'does not appear to be a git repository' "$T/out" \
  && ok "…the warning is there, with git's own explanation above it" || bad "no warning or no git output: $(tail -5 "$T/out")"
! grep -q 'secret was rejected' "$T/out" \
  && ok "…and it does not claim an expired secret when git did not say so" || bad "claims an expired secret without evidence: $(grep rejected "$T/out")"
fresh; run expired good; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "$BOTH" ] && grep -q 'Invalid username or token' "$T/out" && grep -q 'secret was rejected (expired or revoked)' "$T/out" \
  && ok "GitHub's 'Invalid username or token' reaches the log and earns the 'replace it' advice" \
  || bad "expired PAT (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out")"

echo "=== the PAT is used when it works, and optional when absent or empty ==="
fresh; run good bad; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "$BOTH" ] && ! grep -q '::warning::' "$T/out" \
  && ok "PAT accepted: pushed with it, no warning" || bad "PAT accepted (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"
fresh; run "" good; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "$BOTH" ] && ! grep -q '::warning::' "$T/out" \
  && ok "empty secret, as the workflow passes it when unset: default token, no warning" || bad "empty PAT (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"

echo "=== a branch that cannot be pushed does not stop the others ==="
fresh clea/probe/alpha; run "" good; rc=$?
[ "$rc" != 0 ] && [ "$(pushed)" = "clea/probe/beta" ] && grep -q 'not pushed: clea/probe/alpha' "$T/out" && grep -q 'refusing to allow a GitHub App' "$T/out" \
  && ok "alpha refused (a workflow-file change with no PAT): beta pushed, the run fails, names alpha and shows the remote's reason" \
  || bad "alpha refused (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out")"
fresh; run bad bad; rc=$?
[ "$rc" != 0 ] && [ -z "$(pushed)" ] && grep -q 'not pushed: clea/probe/alpha clea/probe/beta' "$T/out" \
  && ok "both tokens rejected: nothing pushed, both branches named, exit non-zero" \
  || bad "both rejected (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out")"
fresh; run "" good "$T/patches-bad"; rc=$?
[ "$rc" != 0 ] && [ "$(pushed)" = "clea/probe/beta" ] && grep -q 'not pushed: clea/probe/alpha' "$T/out" \
  && ok "an unapplicable patch: beta still pushed, the run fails and names alpha" \
  || bad "unapplicable patch (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out")"

echo "=== an existing branch is overwritten, an odd file name is refused, an empty directory is said ==="
fresh
git -C "$T/src" checkout -q --orphan stale-tmp; git -C "$T/src" commit -q --allow-empty -m stale
for b in alpha beta; do git -C "$T/src" push -q "$T/remote/good" "HEAD:refs/heads/clea/probe/$b"; done
git -C "$T/src" checkout -q -f "$BASE"; git -C "$T/src" branch -q -D stale-tmp
run "" good; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$T/remote/good" log -1 --format=%s clea/probe/alpha)" = "probe alpha" ] \
  && [ "$(git -C "$T/remote/good" log -1 --format=%s clea/probe/beta)" = "probe beta" ] \
  && ok "a branch that exists from a prior run, on other history, is force-pushed over" \
  || bad "existing branches (rc=$rc): $(git -C "$T/remote/good" log -1 --format=%s clea/probe/alpha) / $(tail -3 "$T/out")"
fresh; run "" good "$T/patches-evil"; rc=$?
[ "$rc" != 0 ] && [ "$(pushed)" = "clea/probe/beta" ] && grep -q 'unexpected file name' "$T/out" && ! grep -q '^::warning::FORGED' "$T/out" \
  && ok "a patch named with a newline and a workflow command: refused, no forged command in the log, beta pushed" \
  || bad "hostile name (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out" | cat -v)"
fresh; run "" good "$T/patches-empty"; rc=$?
[ "$rc" = 0 ] && grep -q 'no patches to push' "$T/out" && [ -z "$(pushed)" ] \
  && ok "no patch at all: exit 0, and the log says nothing was pushed" || bad "empty directory (rc=$rc): $(tail -3 "$T/out")"

echo "=== the production URL, and no token in the log ==="
fresh
( cd "$T/src" && env -i PATH="$PATH" HOME="$T" REPO=o/r CLEA_WORKFLOW_TOKEN="" DEFAULT_TOKEN=tok123 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$T/remote/good.insteadOf" \
    GIT_CONFIG_VALUE_0="https://x-access-token:tok123@github.com/o/r.git" "$PUSH" "$BASE" "$T/patches" ) >"$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "$BOTH" ] \
  && ok "without the test template, the push goes to https://x-access-token:<token>@github.com/<repo>.git" \
  || bad "production URL (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"
fresh
( cd "$T/src" && env -i PATH="$PATH" HOME="$T" REPO=o/r CLEA_REMOTE_TEMPLATE='http://x-access-token:@TOKEN@@127.0.0.1:1/@REPO@.git' \
    CLEA_WORKFLOW_TOKEN=tokpat-aaaa DEFAULT_TOKEN=tokdef-bbbb "$PUSH" "$BASE" "$T/patches" ) >"$T/out" 2>&1; rc=$?
[ "$rc" != 0 ] && ! grep -qE 'tokpat-aaaa|tokdef-bbbb' "$T/out" && grep -q 'could not push' "$T/out" \
  && ok "a failing push over a URL that carries both tokens leaves neither in the log" \
  || bad "token in the log or no failure (rc=$rc): $(grep -E 'tok(pat|def)|could not' "$T/out" | head -3)"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
