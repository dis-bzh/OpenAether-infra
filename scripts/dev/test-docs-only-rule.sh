#!/usr/bin/env bash
# scripts/dev/classify-changes.sh, the docs-only rule of CI: pure documentation is docs-only, anything else is code, and a
# document a harness reads is code (so is a moved one, on a real git history). Offline, a few seconds.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLS="$ROOT/scripts/dev/classify-changes.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
want() { # <code=true|code=false> <what> <path>...
  local w="$1" what="$2" got; shift 2
  got="$(printf '%s\n' "$@" | "$CLS")"
  if [ "$got" = "$w" ]; then printf '  \033[32m✓\033[0m %s\n' "$what"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s: got %s, want %s\n' "$what" "${got:-<nothing>}" "$w"; FAIL=$((FAIL + 1)); fi
}

# Invented page names: a real page may become a harness input one day, and this must not turn red for it.
want code=false "a new page and its French twin" docs/some-new-page.md docs/some-new-page.fr.md
want code=false "the READMEs, the CHANGELOG and the licence" README.md README.fr.md CHANGELOG.md LICENSE
want code=false "documentation only, mixed" README.md docs/some-new-page.md CHANGELOG.md
want code=true "a script" scripts/dev/some-new-script.sh
want code=true "a page and a script" docs/some-new-page.md scripts/dev/some-new-script.sh
want code=true "a workflow" .github/workflows/ci.yml

mapfile -t LISTED < <("$CLS" --listed)
[ "${#LISTED[@]}" -gt 0 ] || { echo "✗ the list of documents a harness reads is empty"; exit 1; }
for f in "${LISTED[@]}"; do
  want code=true "$f, alone, is code" "$f"
  if git -C "$ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then :
  else printf '  \033[31m✗\033[0m %s is listed and is no tracked file: a stale line protects nothing\n' "$f"; FAIL=$((FAIL + 1)); fi
done
want code=true "a listed document beside plain documentation" README.md "${LISTED[0]}" docs/some-new-page.md

# A moved document: git lists only the new name by default, the old one is the path a harness reads.
R="$TMP/repo"
git init -q -b main "$R" && cd "$R" || exit 1
git config user.email t@example.invalid && git config user.name t && git config commit.gpgsign false
mkdir docs && printf 'line one\nline two\nline three\n' >docs/status.md && git add . && git commit -q -m base
git checkout -q -b pr && git mv docs/status.md docs/status-old.md && git commit -q -m move
got="$("$CLS" main)"
if [ "$got" = code=true ]; then printf '  \033[32m✓\033[0m %s\n' "a listed document moved away is code"; PASS=$((PASS + 1))
else printf '  \033[31m✗\033[0m a listed document moved away: got %s, want code=true\n' "$got"; FAIL=$((FAIL + 1)); fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
