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
echo "=== a glob in the Taskfile runs every harness but the excluded ones (infra #400) ==="

fixture_repo
mkdir -p "$TMP/repo/scripts/dev"
for n in foo bar; do printf '#!/usr/bin/env bash\necho ok\n' >"$TMP/repo/scripts/dev/test-$n.sh"; done
# The glob names neither harness: no Taskfile line and no document, and neither is unreachable for that.
printf 'tasks:\n  test-scripts:\n    cmds:\n      - |\n        for t in ./scripts/dev/test-*.sh; do "$t"; done\n' >"$TMP/repo/Taskfile.yml"
printf 'test-bar.sh  # needs a cluster\n' >"$TMP/repo/scripts/dev/exclude-from-test-scripts.txt"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'never run.*test-bar.sh' <<<"$out" \
  && ok "an excluded harness no cmds entry runs fails the check (rc=${rc})" \
  || bad "an excluded harness run by nothing passed: ${out}"
grep -q 'test-foo.sh' <<<"$out" && bad "a harness the glob runs was flagged — false positive: ${out}" \
  || ok "a harness the glob runs needs no Taskfile line of its own"
printf '  other:\n    cmds:\n      - ./scripts/dev/test-bar.sh\n' >>"$TMP/repo/Taskfile.yml"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "…and a cmds entry of another task clears it (rc=0)" || bad "excluded harness with its own task still failing: ${out}"

printf 'test-gone.sh  # no such file\n' >>"$TMP/repo/scripts/dev/exclude-from-test-scripts.txt"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'test-gone.sh' <<<"$out" && ok "an exclusion naming no file is stale and fails (rc=${rc})" \
  || bad "a stale exclusion passed: ${out}"
printf '# a comment line, then a blank one\n\ntest-bar.sh\n' >"$TMP/repo/scripts/dev/exclude-from-test-scripts.txt"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'without a reason.*test-bar.sh' <<<"$out" && ok "an exclusion without a reason fails: the list stays commented" \
  || bad "an exclusion with no reason passed (rc=${rc}): ${out}"
printf '# a comment line, then a blank one\n\ntest-bar.sh  # needs a cluster\n' >"$TMP/repo/scripts/dev/exclude-from-test-scripts.txt"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "comment and blank lines of the list are skipped (rc=0)" || bad "a commented list fails: ${out}"

# Take the glob away (back to a hand list): both harnesses now need their own cmds entry again.
printf 'tasks:\n  test-scripts:\n    cmds:\n      # for t in ./scripts/dev/test-*.sh; do "$t"; done\n' >"$TMP/repo/Taskfile.yml"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'never run.*test-foo.sh' <<<"$out" && ok "no glob in the Taskfile: every harness needs a cmds entry again" \
  || bad "a commented-out glob counted as running the harnesses (rc=${rc}): ${out}"

# The glob counts only as the test-scripts task's own loop: the same text in another task runs nothing of test-scripts,
# and the glob does not descend into a subdirectory (the `case` pattern's * would cross the slash).
fixture_repo
mkdir -p "$TMP/repo/scripts/dev"
printf '#!/usr/bin/env bash\necho ok\n' >"$TMP/repo/scripts/dev/test-foo.sh"
printf 'tasks:\n  test-scripts:\n    cmds:\n      - ./scripts/dev/check-x.sh\n  lint:\n    cmds:\n      - |\n        for t in ./scripts/dev/test-*.sh; do echo "$t"; done\n' >"$TMP/repo/Taskfile.yml"
: >"$TMP/repo/scripts/dev/exclude-from-test-scripts.txt"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'never run.*test-foo.sh' <<<"$out" \
  && ok "the glob in another task is not test-scripts running the harnesses (rc=${rc})" \
  || bad "a glob outside the test-scripts task counted as running the harnesses (rc=${rc}): ${out}"

fixture_repo
mkdir -p "$TMP/repo/scripts/dev/test-sub"
printf '#!/usr/bin/env bash\necho ok\n' >"$TMP/repo/scripts/dev/test-sub/inner.sh"
printf 'tasks:\n  test-scripts:\n    cmds:\n      - |\n        for t in ./scripts/dev/test-*.sh; do "$t"; done\n' >"$TMP/repo/Taskfile.yml"
: >"$TMP/repo/scripts/dev/exclude-from-test-scripts.txt"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'never run.*test-sub/inner.sh' <<<"$out" \
  && ok "a harness in a subdirectory is not run by the glob and fails the check (rc=${rc})" \
  || bad "a nested test-*.sh counted as run by a glob that does not descend (rc=${rc}): ${out}"

echo
echo "=== proof against reality: this repository's own tree is clean today ==="

out="$("$CHECKER" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "every tracked script in THIS repo is reachable (rc=0)" ||
  bad "this repository has an unreachable script the checker caught: ${out}"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
