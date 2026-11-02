#!/usr/bin/env bash
# Every tracked script must be reachable from something else in the tree — a
# task, a workflow, another script, or a document. A script git tracks and
# nothing else names is exactly the failure mode `task test-scripts` exists
# to catch, one level up: the check does the work, it is simply never asked
# (test-teardown.sh and test-cluster-checks.sh sat unreachable the same way
# until they were wired in).
#
# A plain basename match, deliberately: the reproduction in #116 is exactly
# `git grep -l <basename> -- . | grep -v ^<path>$`, and vulture cannot see
# this class of defect — it reasons inside a module, not across an
# invocation graph.
#
# Usage: check-script-reachability.sh [root-dir]   (default: repo root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" || exit 1

unreachable=0

# `task test-scripts` runs every scripts/dev/test-*.sh by glob, except the names listed (each with a reason) in
# scripts/dev/exclude-from-test-scripts.txt. A harness the glob runs needs no line of its own in the Taskfile.
# Without the glob in the Taskfile (not in a comment) every harness needs its own cmds entry, as before.
EXCL=scripts/dev/exclude-from-test-scripts.txt
# Counted, not `grep -q` at the end of a pipe: -q quits at the first match and pipefail then reads the SIGPIPE as "no".
glob=0
[ "$(grep -vE '^[[:space:]]*#' Taskfile.yml 2>/dev/null | grep -cF './scripts/dev/test-*.sh')" -gt 0 ] && glob=1
excluded=""
[ -f "$EXCL" ] && excluded="$(sed -E 's/[[:space:]]*#.*//; /^[[:space:]]*$/d' "$EXCL")"
by_glob() { # is this file run by the test-scripts glob?
  [ "$glob" -eq 1 ] || return 1
  case "$1" in scripts/dev/test-*.sh) ;; *) return 1 ;; esac
  ! grep -qxF "$(basename "$1")" <<<"$excluded"
}

while IFS= read -r f; do
  by_glob "$f" && continue
  base="$(basename "$f")"
  if ! git grep -q -F -e "$base" -- . ":(exclude)$f" 2>/dev/null; then
    echo "✗ unreachable: $f"
    unreachable=$((unreachable + 1))
  fi
done < <(git ls-files '*.sh' '*.py')

# A harness is coverage only when a task runs it, and a comment or the CHANGELOG
# naming it satisfies the match above: each one the glob does not run needs a Taskfile cmds entry.
while IFS= read -r f; do
  by_glob "$f" && continue
  if ! grep -qE "^[[:space:]]*- \./${f//./\\.}( |$)" Taskfile.yml 2>/dev/null; then
    echo "✗ never run: no Taskfile.yml cmds entry runs $f"
    unreachable=$((unreachable + 1))
  fi
done < <(git ls-files 'scripts/dev/test-*.sh')

# The exclusion list itself: a name must be a tracked harness (a stale line excludes nothing) and say why.
if [ -f "$EXCL" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! git ls-files --error-unmatch "scripts/dev/$name" >/dev/null 2>&1; then
      echo "✗ stale exclusion: $EXCL names $name, which is no tracked file under scripts/dev/"
      unreachable=$((unreachable + 1))
    fi
  done <<<"$excluded"
  while IFS= read -r name; do
    echo "✗ exclusion without a reason: $EXCL lists $name with no '# why' after it"
    unreachable=$((unreachable + 1))
  done < <(sed -E '/^[[:space:]]*(#|$)/d; /#[[:space:]]*[^[:space:]]/d; s/[[:space:]].*//' "$EXCL")
fi

if [ "$unreachable" -gt 0 ]; then
  echo
  echo "✗ ${unreachable} finding(s) above: a tracked script nothing else names, or a"
  echo "  harness no task runs. Decide, for each: wire it in, or delete it."
  echo "  A script nobody invokes is not coverage."
  exit 1
fi
echo "OK — every tracked script is named elsewhere in the tree, and a task runs every harness."
