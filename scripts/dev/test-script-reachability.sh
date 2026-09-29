#!/usr/bin/env bash
# Unit tests for #116: check-script-reachability.sh, against an isolated,
# throwaway git repo — never this one, so the fixtures cannot collide with a
# real script's name and the test needs no network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/dev/check-script-reachability.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

fixture_repo() { # sets up $TMP/repo, a fresh throwaway git repo
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/scripts"
  git -C "$TMP/repo" init -q
  git -C "$TMP/repo" config user.email test@example.invalid
  git -C "$TMP/repo" config user.name test
}
commit() { git -C "$TMP/repo" add -A && git -C "$TMP/repo" commit -q -m fixture; }

echo "=== check-script-reachability.sh: named by nothing is unreachable ==="

fixture_repo
# bar.sh IS referenced (by a doc); foo.sh is not referenced anywhere.
printf '#!/usr/bin/env bash\necho bar\n' >"$TMP/repo/scripts/bar.sh"
printf '#!/usr/bin/env bash\necho foo\n' >"$TMP/repo/scripts/foo.sh"
printf 'Run it: scripts/bar.sh\n' >"$TMP/repo/README.md"
commit

out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an unreferenced script fails the check (rc=${rc})"
else bad "an unreferenced script passed"; fi
grep -q 'scripts/foo.sh' <<<"$out" && ok "the unreferenced script is named" ||
  bad "the unreferenced script is never named: ${out}"
grep -q 'scripts/bar.sh' <<<"$out" && bad "the REFERENCED script was flagged too — false positive" ||
  ok "the referenced script is not flagged"

echo
echo "=== wiring in a reference clears it ==="

printf 'Run it: scripts/bar.sh\nAlso: scripts/foo.sh\n' >"$TMP/repo/README.md"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "referencing it from a document clears the failure (rc=0)" ||
  bad "still failing after wiring foo.sh into a doc: ${out}"

echo
echo "=== a script referenced only by another script counts as reachable ==="

fixture_repo
# caller.sh is the entry point, named by Taskfile.yml; callee.sh is named by
# NOTHING but caller.sh's own body — that must be enough.
printf '#!/usr/bin/env bash\n./scripts/callee.sh\n' >"$TMP/repo/scripts/caller.sh"
printf '#!/usr/bin/env bash\necho callee\n' >"$TMP/repo/scripts/callee.sh"
printf 'thing:\n  cmds:\n    - ./scripts/caller.sh\n' >"$TMP/repo/Taskfile.yml"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a script named only by another script still passes (rc=0)" ||
  bad "a script->script reference was not recognised: ${out}"

echo
echo "=== a harness only a comment names is run by nothing ==="

fixture_repo
mkdir -p "$TMP/repo/scripts/dev"
printf '#!/usr/bin/env bash\necho ok\n' >"$TMP/repo/scripts/dev/test-foo.sh"
printf 'test-scripts:\n  cmds:\n    # - ./scripts/dev/test-foo.sh\n' >"$TMP/repo/Taskfile.yml"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'scripts/dev/test-foo.sh' <<<"$out" \
  && ok "a harness no cmds entry runs fails the check (rc=${rc})" \
  || bad "a harness named only in a comment passed: ${out}"
printf '    - ./scripts/dev/test-foo.sh\n' >>"$TMP/repo/Taskfile.yml"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a cmds entry running it clears the failure (rc=0)" ||
  bad "still failing with a cmds entry: ${out}"

echo
echo "=== proof against reality: this repository's own tree is clean today ==="

out="$("$CHECKER" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "every tracked script in THIS repo is reachable (rc=0)" ||
  bad "this repository has an unreachable script the checker caught: ${out}"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
