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
while IFS= read -r f; do
  base="$(basename "$f")"
  if ! git grep -q -F -e "$base" -- . ":(exclude)$f" 2>/dev/null; then
    echo "✗ unreachable: $f"
    unreachable=$((unreachable + 1))
  fi
done < <(git ls-files '*.sh' '*.py')

# A harness is coverage only when a task runs it, and a comment or the CHANGELOG
# naming it satisfies the match above: each one needs a Taskfile cmds entry.
while IFS= read -r f; do
  if ! grep -qE "^[[:space:]]*- \./${f//./\\.}( |$)" Taskfile.yml 2>/dev/null; then
    echo "✗ never run: no Taskfile.yml cmds entry runs $f"
    unreachable=$((unreachable + 1))
  fi
done < <(git ls-files 'scripts/dev/test-*.sh')

if [ "$unreachable" -gt 0 ]; then
  echo
  echo "✗ ${unreachable} finding(s) above: a tracked script nothing else names, or a"
  echo "  harness no task runs. Decide, for each: wire it in, or delete it."
  echo "  A script nobody invokes is not coverage."
  exit 1
fi
echo "OK — every tracked script is named elsewhere in the tree, and a task runs every harness."
