#!/usr/bin/env bash
# scripts/clea/push-probes.sh against real git remotes on the local disk.
#
# The remote "bad" does not exist and "good" does, so a token's value picks the
# outcome: the push is real, only the credential is a stand-in. A rejected PAT
# must fall back to the default token, and one branch that cannot be pushed must
# not stop the others.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
ROOT="$PWD"
PUSH="${PUSH_SCRIPT:-$ROOT/scripts/clea/push-probes.sh}"   # PUSH_SCRIPT: mutate a copy to see a case fail
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

fresh() { # a new "good" remote, empty; $1 = a branch it must refuse, if any
  rm -rf "$T/remote"; mkdir "$T/remote"; git init -q --bare "$T/remote/good"
  if [ -n "${1:-}" ]; then
    printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = "refs/heads/%s" ] && { echo "refusing to allow a GitHub App to create or update workflow" >&2; exit 1; }; done; exit 0\n' "$1" >"$T/remote/good/hooks/pre-receive"
    chmod +x "$T/remote/good/hooks/pre-receive"
  fi
  git -C "$T/src" reset -q --hard "$BASE"
}
run() { # <pat> <default> ; output in $T/out
  ( cd "$T/src" && env -i PATH="$PATH" HOME="$T" REPO=o/r CLEA_REMOTE_TEMPLATE="file://$T/remote/@TOKEN@" \
      ${1:+CLEA_WORKFLOW_TOKEN="$1"} DEFAULT_TOKEN="$2" "$PUSH" "$BASE" "$T/patches" ) >"$T/out" 2>&1
}
pushed() { git -C "$T/remote/good" for-each-ref --format='%(refname:short)' refs/heads/clea/probe | sort | paste -sd' '; }

echo "=== a rejected PAT falls back to the default token ==="
fresh; run bad good; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "clea/probe/alpha clea/probe/beta" ] \
  && ok "PAT rejected: both branches pushed with the default token, exit 0" \
  || bad "PAT rejected (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"
grep -q '::warning::CLEA_WORKFLOW_TOKEN' "$T/out" \
  && ok "…and the log says the secret did not work, so the expiry is visible" \
  || bad "no warning about the rejected secret: $(tail -4 "$T/out")"

echo "=== the PAT is used when it works, and optional when absent ==="
fresh; run good bad; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "clea/probe/alpha clea/probe/beta" ] && ! grep -q '::warning::' "$T/out" \
  && ok "PAT accepted: pushed with it, no warning" || bad "PAT accepted (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"
fresh; run "" good; rc=$?
[ "$rc" = 0 ] && [ "$(pushed)" = "clea/probe/alpha clea/probe/beta" ] && ! grep -q '::warning::' "$T/out" \
  && ok "no PAT: pushed with the default token, no warning" || bad "no PAT (rc=$rc, pushed: $(pushed)): $(tail -4 "$T/out")"

echo "=== a branch that cannot be pushed does not stop the others ==="
fresh clea/probe/alpha; run "" good; rc=$?
[ "$rc" != 0 ] && [ "$(pushed)" = "clea/probe/beta" ] && grep -q 'not pushed: clea/probe/alpha' "$T/out" \
  && ok "alpha refused (a workflow-file change with no PAT): beta still pushed, the run fails and names alpha" \
  || bad "alpha refused (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out")"
fresh; run bad bad; rc=$?
[ "$rc" != 0 ] && [ -z "$(pushed)" ] && grep -q 'not pushed: clea/probe/alpha clea/probe/beta' "$T/out" \
  && ok "both tokens rejected: nothing pushed, both branches named, exit non-zero" \
  || bad "both rejected (rc=$rc, pushed: $(pushed)): $(tail -5 "$T/out")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
