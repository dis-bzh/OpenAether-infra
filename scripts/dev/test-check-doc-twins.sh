#!/usr/bin/env bash
# Unit tests for check-doc-twins.sh against throwaway git repos, never this one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/dev/check-doc-twins.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

fixture_repo() {
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo/docs"
  git -C "$TMP/repo" init -q
  git -C "$TMP/repo" config user.email test@example.invalid
  git -C "$TMP/repo" config user.name test
}
commit() { git -C "$TMP/repo" add -A && git -C "$TMP/repo" commit -q -m fixture; }
pair() { # <name> : a complete, structurally equal pair
  printf '# T\n\n[FR](%s.fr.md)\n\n## A\n\n```\nx\n```\n' "$1" >"$TMP/repo/docs/$1.md"
  printf '# T\n\n[EN](%s.md)\n\n## A\n\n```\nx\n```\n' "$1" >"$TMP/repo/docs/$1.fr.md"
}
run() { out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?; }

echo "=== a complete pair passes ==="
fixture_repo; pair key-management; commit; run
[ "$rc" -eq 0 ] && ok "complete pair passes" || bad "complete pair failed: $out"

echo; echo "=== a document without a twin fails, the English-only ones do not ==="
fixture_repo; printf '# T\n' >"$TMP/repo/docs/lonely.md"; commit; run
[ "$rc" -ne 0 ] && grep -q 'lonely.md has no French twin' <<<"$out" && ok "a twinless document is named" || bad "twinless document passed: $out"
fixture_repo; printf '# T\n' >"$TMP/repo/docs/status.md"; commit; run
[ "$rc" -eq 0 ] && ok "status.md may stay English only" || bad "status.md refused: $out"

echo; echo "=== the link to the other language is required on both sides ==="
fixture_repo; pair key-management; printf '# T\n\nno link here\n\n## A\n\n```\nx\n```\n' >"$TMP/repo/docs/key-management.fr.md"; commit; run
[ "$rc" -ne 0 ] && grep -q 'does not open with a link to key-management.md' <<<"$out" && ok "a missing back-link is named" || bad "missing back-link passed: $out"

echo; echo "=== structure: enforced for the security set, a warning elsewhere ==="
fixture_repo; pair key-management; printf '\n## B\n' >>"$TMP/repo/docs/key-management.md"; commit; run
[ "$rc" -ne 0 ] && grep -q 'headings' <<<"$out" && ok "an extra section on one side fails in the security set" || bad "heading drift passed: $out"
fixture_repo; pair older; printf '\n## B\n' >>"$TMP/repo/docs/older.md"; commit; run
[ "$rc" -eq 0 ] && grep -q 'not enforced' <<<"$out" && ok "the same drift is only a warning for an older pair" || bad "older pair handled wrongly: rc=$rc $out"
fixture_repo; pair key-management; printf '\n```\ny\n```\n' >>"$TMP/repo/docs/key-management.md"; commit; run
[ "$rc" -ne 0 ] && grep -q 'code fences' <<<"$out" && ok "an extra code block fails in the security set" || bad "fence drift passed: $out"
fixture_repo; pair key-management; printf '\n```\n# a shell comment is not a heading\n```\n' >>"$TMP/repo/docs/key-management.md"; printf '\n```\n# un commentaire\n```\n' >>"$TMP/repo/docs/key-management.fr.md"; commit; run
[ "$rc" -eq 0 ] && ok "a # line inside a fence is not counted as a heading" || bad "fenced comment counted: $out"

echo; echo "=== relative links ==="
fixture_repo; pair key-management; printf '\nSee [x](gone.md) and [y](key-management.md#a) and [z](https://example.invalid/x).\n' >>"$TMP/repo/docs/key-management.md"
printf '\nVoir [x](gone.md) et [y](key-management.fr.md#a).\n' >>"$TMP/repo/docs/key-management.fr.md"; commit; run
[ "$rc" -ne 0 ] && grep -q 'link to gone.md does not resolve' <<<"$out" && ok "a dead relative link is named" || bad "dead link passed: $out"
! grep -q 'key-management.md#a' <<<"$out" && ! grep -q 'example.invalid' <<<"$out" && ok "anchors and external links are left alone" || bad "an anchor or external link was flagged: $out"
fixture_repo; pair key-management; printf '\n```\n[x](gone.md)\n```\n' >>"$TMP/repo/docs/key-management.md"; printf '\n```\n[x](gone.md)\n```\n' >>"$TMP/repo/docs/key-management.fr.md"; commit; run
[ "$rc" -eq 0 ] && ok "a link inside a code fence is not a link" || bad "fenced link flagged: $out"

echo; echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
