#!/usr/bin/env bash
# Reports the commits of a range that carry NO signature (`git log %G?` = N) or a BAD one (B, R, X, Y). Addresses
# ANSSI SSDLC-CICD-AIP-03 (signed source commits); docs/signed-commits.md. A WARNING by default: the history has
# no signed commit yet, so failing would block every PR. `--strict` fails, to be switched on once every maintainer
# signs. A runner without the signer keys sees a signed commit as `E` (cannot be checked): that counts as signed
# here, because the cryptographic verdict is GitHub's (required_signatures ruleset) and Flux's (spec.verify).
#
# Merge commits are skipped: on a pull_request run HEAD is GitHub's synthetic, unsigned refs/pull/N/merge commit,
# which would make --strict fail every PR.
#
# Usage: check-commit-signatures.sh [--strict] <rev-range>
set -euo pipefail

strict=0
if [ "${1:-}" = "--strict" ]; then strict=1; shift; fi
range="${1:?usage: check-commit-signatures.sh [--strict] <rev-range>}"

# A file, not a process substitution: a failing `git log` must stop the script (see check-commit-authors.sh, #132).
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! git log --no-merges --format='%H%x09%G?%x09%s' "$range" > "$tmp"; then
  echo "✗ git log $range failed — commit signatures could not be checked" >&2
  exit 2
fi

total=0 bad=0
while IFS=$'\t' read -r sha status subject; do
  [ -n "$sha" ] || continue
  total=$((total + 1))
  case "$status" in
    N | B | R | X | Y)
      bad=$((bad + 1))
      msg="${sha:0:12} $subject: $([ "$status" = N ] && echo 'not signed' || echo "signature status $status")"
      if [ "$strict" = 1 ]; then echo "✗ $msg" >&2; elif [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$msg"; else echo "⚠ $msg"; fi
      ;;
  esac
done < "$tmp"

if [ "$bad" -eq 0 ]; then
  echo "✓ $total commit(s) in $range carry a signature"
elif [ "$strict" = 1 ]; then
  echo "✗ $bad of $total commit(s) in $range are unsigned or badly signed" >&2
  exit 1
else
  echo "⚠ $bad of $total commit(s) in $range are unsigned or badly signed (warning: pass --strict to fail)"
fi
