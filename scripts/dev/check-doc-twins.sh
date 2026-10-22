#!/usr/bin/env bash
# The documents in docs/ come in pairs, x.md (canonical) and x.fr.md, and the security set (key management,
# incident response, backup and recovery, network, hardening...) is exactly the kind of text that is edited in
# one language and forgotten in the other. This checks, per pair:
#   - each file opens with a link to the other (the first five lines);
#   - both have the same number of headings and of fenced code blocks (a section added to one side is a drift).
#     Enforced for the documents of STRICT below (the security set, written as pairs); for the older pairs a
#     difference is printed as a warning, because upgrade.fr.md is known to lag behind upgrade.md;
# and, for every tracked Markdown file of docs/ plus the two READMEs:
#   - each relative link resolves to a file (anchors are not checked);
# and that a docs/*.md with no twin is one of the two documents that say they are English only.
#
# It cannot tell whether the French says the same thing as the English: the counts catch a missing part,
# not a wrong sentence. Read the pair when you change one.
#
# Usage: check-doc-twins.sh [root-dir]   (default: repo root; tracked files only)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" || exit 1

# English only on purpose: both say so in their own header or in the README table.
EXEMPT=" docs/release-checklist.md docs/status.md "

# The pairs written together, where a missing section is a defect and not a backlog.
STRICT=" key-management incident-response backup-policy disaster-recovery security-architecture network hardening threat-model component-selection audit-register audit-sink "

BAD=0
fail() { echo "✗ $*"; BAD=$((BAD + 1)); }

count_headings() { awk '/^```/ { fence = !fence; next } !fence && /^#{1,4} / { n++ } END { print n + 0 }' "$1"; }
count_fences() { grep -cE '^```' "$1" || true; }

FILES="$(git ls-files 'docs/*.md' README.md README.fr.md 2>/dev/null)"

while IFS= read -r f; do
  case "$f" in docs/*.fr.md | README.fr.md) continue ;; docs/*.md) ;; *) continue ;; esac
  base="${f%.md}"
  twin="$base.fr.md"
  if [ ! -f "$twin" ]; then
    case "$EXEMPT" in *" $f "*) ;; *) fail "$f has no French twin ($twin)" ;; esac
    continue
  fi
  en_name="$(basename "$f")"; fr_name="$(basename "$twin")"
  head -5 "$f" | grep -qF "($fr_name)" || fail "$f does not open with a link to $fr_name"
  head -5 "$twin" | grep -qF "($en_name)" || fail "$twin does not open with a link to $en_name"
  name="$(basename "$base")"
  eh="$(count_headings "$f")"; fh="$(count_headings "$twin")"
  ef="$(count_fences "$f")"; ff="$(count_fences "$twin")"
  case "$STRICT" in
    *" $name "*)
      [ "$eh" = "$fh" ] || fail "$f has $eh headings, $twin has $fh"
      [ "$ef" = "$ff" ] || fail "$f has $ef code fences, $twin has $ff" ;;
    *)
      { [ "$eh" = "$fh" ] && [ "$ef" = "$ff" ]; } || echo "⚠ $f and $twin differ in structure ($eh/$fh headings, $ef/$ff fences): not enforced for this pair" ;;
  esac
done <<<"$FILES"

# Relative links. Skip fenced blocks (they hold commands and sample text, not links).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  dir="$(dirname "$f")"
  awk '/^```/ { fence = !fence; next } !fence' "$f" \
    | grep -oE '\]\([^)[:space:]]+\)' \
    | sed -E 's/^\]\((.*)\)$/\1/' \
    | while IFS= read -r target; do
      case "$target" in http://* | https://* | mailto:* | '#'*) continue ;; esac
      path="${target%%#*}"
      [ -n "$path" ] || continue
      [ -e "$dir/$path" ] || echo "✗ $f: link to $target does not resolve"
    done
done <<<"$FILES" > "${TMPDIR:-/tmp}/doc-twins.$$.links"
if [ -s "${TMPDIR:-/tmp}/doc-twins.$$.links" ]; then
  cat "${TMPDIR:-/tmp}/doc-twins.$$.links"
  BAD=$((BAD + $(wc -l < "${TMPDIR:-/tmp}/doc-twins.$$.links")))
fi
rm -f "${TMPDIR:-/tmp}/doc-twins.$$.links"

if [ "$BAD" -ne 0 ]; then
  echo
  echo "✗ $BAD documentation problem(s). English is canonical; the French twin follows it."
  exit 1
fi
echo "✓ every docs/ pair is complete and every relative link resolves"
