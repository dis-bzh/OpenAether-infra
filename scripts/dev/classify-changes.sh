#!/usr/bin/env bash
# CI's docs-only rule (job "Detect change scope" of ci.yml): `code=false` when every changed file is documentation, so the
# heavy jobs may skip, else `code=true`. Prints one `code=` line, ready for $GITHUB_OUTPUT.
#   classify-changes.sh <base>      the files of `git diff <base>...HEAD`
#   classify-changes.sh             one path per line on stdin
#   classify-changes.sh --listed    the documents a harness reads, one per line
# It errs toward code: documentation is what the pattern recognises, anything else (a new file type, say) is code. One
# exception runs the other way: a document a harness asserts on counts as code, or a PR that edits only it would skip the
# harness that catches the break. A harness that reads a document written some other way than the list below is caught
# by the push run on main, not by the PR: add the document here.
set -uo pipefail

DOCS='^(docs/|README|CHANGELOG\.md$|CONTRIBUTING\.md$|LICENSE$|.*\.md$)'
HARNESS_DOCS=(
  docs/network.md docs/network.fr.md                 # test-flow-matrix.sh
  docs/status.md                                     # test-evidence-age.sh
  CONTRIBUTING.md .github/pull_request_template.md   # test-rung-receipts.sh
  infrastructure/opentofu/cluster/README.md          # test-bootstrap-in-state.sh
)

if [ "${1:-}" = "--listed" ]; then printf '%s\n' "${HARNESS_DOCS[@]}"; exit 0; fi

tmp="$(mktemp)" || exit 1
trap 'rm -f "$tmp"' EXIT
if [ "$#" -eq 1 ]; then
  # --no-renames: a moved file is listed under both names, so a renamed document a harness reads still counts as code.
  git diff --name-only --no-renames "$1...HEAD" >"$tmp" || { echo "✗ classify-changes: git diff $1...HEAD failed" >&2; exit 1; }
elif [ "$#" -eq 0 ]; then
  cat >"$tmp"
else
  echo "usage: ${0##*/} [<base> | --listed]" >&2; exit 2
fi

if grep -vEq "$DOCS" "$tmp" || grep -qxFf <(printf '%s\n' "${HARNESS_DOCS[@]}") "$tmp"; then
  echo "code=true"
else
  echo "code=false"
fi
