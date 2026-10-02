#!/usr/bin/env bash
# Push each probe patch as its own clea/probe/<slug> branch.
#
# A PAT that GitHub rejects (expired, revoked) must not silence every probe: the
# default token still pushes every branch that touches no workflow file, so it is
# the fallback, and a branch that cannot be pushed does not stop the others.
# The report reads each verdict from its branch, so a lost push reads "not probed".
#
# Usage: push-probes.sh <base-sha> <patches-dir>
# Env:   REPO (owner/name), DEFAULT_TOKEN, CLEA_WORKFLOW_TOKEN (optional classic
#        PAT, scope `workflow`: GITHUB_TOKEN cannot push a file under
#        .github/workflows/), CLEA_REMOTE_TEMPLATE (tests: @TOKEN@ and @REPO@).
set -uo pipefail

base="${1:?usage: push-probes.sh <base-sha> <patches-dir>}"
dir="${2:?usage: push-probes.sh <base-sha> <patches-dir>}"
repo="${REPO:?REPO is not set}"
template="${CLEA_REMOTE_TEMPLATE:-https://x-access-token:@TOKEN@@github.com/@REPO@.git}"

remote_for() { local url="${template//@TOKEN@/$1}"; printf '%s' "${url//@REPO@/$repo}"; }
# git anonymises the URL in its own errors; this makes sure of it, since a token is in it.
redact() { sed -E 's#(://)[^/@[:space:]]*@#\1***@#g'; }

# --force, not --force-with-lease: this checkout never fetched the branch it
# overwrites, so the lease has nothing to compare against and refuses every push
# once the branch exists. Nobody but this workflow writes clea/probe/*.
push_branch() { # <branch>: the PAT first, then the default token
  local out hint
  if [ -n "${CLEA_WORKFLOW_TOKEN:-}" ]; then
    out="$(git push --force "$(remote_for "$CLEA_WORKFLOW_TOKEN")" "HEAD:$1" 2>&1)" && return 0
    printf '%s\n' "$out" | redact >&2
    hint=""
    if grep -q 'Invalid username or token' <<<"$out"; then
      hint=" The secret was rejected (expired or revoked): replace it."
    fi
    echo "::warning::CLEA_WORKFLOW_TOKEN did not push $1; trying GITHUB_TOKEN.${hint}"
  fi
  out="$(git push --force "$(remote_for "${DEFAULT_TOKEN:?DEFAULT_TOKEN is not set}")" "HEAD:$1" 2>&1)" && return 0
  printf '%s\n' "$out" | redact >&2
  echo "::error::could not push $1"
  return 1
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

failed=()
count=0
shopt -s nullglob
for patch in "$dir"/*.patch; do
  count=$((count + 1))
  slug="$(basename "$patch" .patch)"
  # The name comes from an artifact that a probe job, which runs upstream code,
  # produced: it must not carry a newline into a workflow command in this log.
  case "$slug" in
    '' | [.-]* | *[!A-Za-z0-9._-]*)
      echo "::error::skipping a patch with an unexpected file name"
      failed+=("<unexpected file name>")
      continue ;;
  esac
  branch="clea/probe/${slug}"
  if git checkout -q -B "$branch" "$base" && git am -q "$patch"; then
    push_branch "$branch" || failed+=("$branch")
  else
    git am --abort 2>/dev/null
    echo "::error::could not apply $patch on $base"
    failed+=("$branch")
  fi
  git checkout -q "$base"
done

[ "$count" -gt 0 ] || echo "no patches to push"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::${#failed[@]} probe branch(es) not pushed: ${failed[*]}"
  exit 1
fi
