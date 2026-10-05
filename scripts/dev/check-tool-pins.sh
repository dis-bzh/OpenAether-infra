#!/usr/bin/env bash
# Every `pip install`, `apt-get install -y` and `npx -p` invocation in a
# tracked shell or workflow file must carry a pin: a literal `==`/`@x.y.z` on
# the line, or a `# renovate:` anchor a few lines above it — the shape
# commitizen already uses (ci.yml:96-98) and gitleaks/Flux's env-var pins use
# one step removed. ci.yml installed yamllint, shellcheck and
# renovate-config-validator with none of the three, between a comment arguing
# against exactly that and ten lines explaining why Task is pinned instead of
# fetched by an action (#113). This is the inverse of `clea coverage`: that one
# asks "is every anchor watched", this one asks "does every install have one".
#
# WHAT THIS DOES NOT DO: decide that a package name is "safe" to install
# unpinned. The ALLOWLIST below is this repository's own prior decision, one
# line each — most are generic OS utilities with no meaningful version to
# track (apt's actual candidates drift by Ubuntu release), a few are pinned by
# a different mechanism entirely (a GPG-verified apt channel).
#
# `python3 -m pip install` is deliberately invisible to the pip pattern below
# (it matches bare `pip install` only); setup.sh's own installs go through
# pip_install_pinned, which takes the pin from an anchored variable.
#
# Usage: check-tool-pins.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

declare -A ALLOW=(
  [unzip]="generic OS utility (unpacks vendored downloads) — no meaningful version to track"
  [xz-utils]="generic OS utility (unpacks vendored downloads, e.g. shellcheck's .tar.xz) — no meaningful version to track"
  [zstd]="generic OS utility (talos image build)"
  [qemu-utils]="generic OS utility (talos image build)"
  [gnupg]="generic OS utility (backup encryption, Zabbly key verification)"
  [jq]="generic OS utility (backup-state.sh)"
  [netcat-openbsd]="generic OS utility (port probes)"
  [openssh-server]="generic OS utility (ssh-ca-check.sh's throwaway Docker sshd, torn down every run)"
  [openssh-client]="generic OS utility (ssh-ca-check.sh's throwaway Docker sshd, torn down every run)"
  [pipx]="a package manager, not a tracked tool"
  [curl]="bootstrap prerequisite needed before any pinned download can even run"
  [ca-certificates]="bootstrap prerequisite needed before any pinned download can even run"
  [incus]="pinned by the Zabbly stable channel + GPG key fingerprint one step above (ci.yml), not by an apt package version"
  [incus-client]="same as incus — one apt line, one pin, on the channel"
)

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# This file's own prose and its patterns below quote the three shapes
# verbatim, and would otherwise report itself — same reason renovate.json5
# excludes itself from Cléa's `renovate` inventory (clea.toml).
SELF="scripts/dev/check-tool-pins.sh"
FILES=('*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml' ":(exclude)$SELF")

# A commented-out line is not a real invocation, and prose describing one
# (this file's own header, above) is textually indistinguishable from one —
# same distinction check-version-drift.sh draws between a pin and a mention.
is_comment() { [[ "$1" =~ ^[[:space:]]*# ]]; }

# Does a `# renovate:` anchor sit within LOOKBACK lines above <file>:<line>?
# A fixed small window rather than parsing YAML step boundaries — the same
# tradeoff check-version-drift.sh makes with its own sed-based extractors, and
# every anchor in this tree today sits 1-2 lines above what it pins.
LOOKBACK=6
has_anchor_above() {
  local file="$1" line="$2" start
  start=$(( line - LOOKBACK )); [ "$start" -lt 1 ] && start=1
  sed -n "${start},$((line - 1))p" "$file" 2>/dev/null | grep -q '# renovate:'
}

echo "=== pip install ==="
while IFS=: read -r file line text; do
  is_comment "$text" && continue
  case "$text" in
    *'-m pip install'*) continue ;;  # deliberately out of scope, see header
  esac
  if [[ "$text" == *'=='* ]]; then
    ok "$file:$line — pinned (==)"
  elif has_anchor_above "$file" "$line"; then
    ok "$file:$line — pinned (# renovate: anchor above)"
  else
    bad "$file:$line — no ==version and no # renovate: anchor above:${text#*pip install}"
  fi
done < <(git grep -nE '(^|[^-])\bpip install\b' -- "${FILES[@]}" 2>/dev/null)

echo "=== apt-get install -y ==="
while IFS=: read -r file line text; do
  is_comment "$text" && continue
  if has_anchor_above "$file" "$line"; then
    ok "$file:$line — pinned (# renovate: anchor above)"
    continue
  fi
  # Everything after the FIRST "apt-get install -y" on the line is the
  # package list (a preceding "apt-get update &&" never matches this itself)
  # — up to the next shell separator, so a chained second command
  # ("apt-get install -y pipx && pipx install checkov") does not get read as
  # more packages to this one.
  payload="${text#*apt-get install -y}"
  payload="${payload%%[\&\|\;]*}"
  read -ra toks <<< "$payload"
  unpinned=()
  for tok in "${toks[@]}"; do
    tok="${tok//[\"\']/}"
    # A real apt package name only — this single shape also skips flags
    # (-qq, --no-install-recommends), shell variable/array expansions
    # (${need[@]}) and stray shell-string punctuation (>/dev/null') without a
    # separate case for each: none of them can match it.
    [[ "$tok" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || continue
    [[ "$tok" == *=* ]] && continue                # already apt-pinned (pkg=1.2.3)
    [[ -n "${ALLOW[$tok]:-}" ]] && continue
    unpinned+=("$tok")
  done
  if [ "${#unpinned[@]}" -eq 0 ]; then
    ok "$file:$line — every package pinned, allowlisted, or not statically checkable"
  else
    bad "$file:$line — no pin, not allowlisted: ${unpinned[*]}"
  fi
done < <(git grep -nE 'apt-get install -y' -- "${FILES[@]}" 2>/dev/null)

echo "=== npx -p ==="
while IFS=: read -r file line text; do
  is_comment "$text" && continue
  if [[ "$text" =~ -p[[:space:]]+[^[:space:]]*@[0-9] ]]; then
    ok "$file:$line — pinned (@version)"
  elif has_anchor_above "$file" "$line"; then
    ok "$file:$line — pinned (# renovate: anchor above)"
  else
    bad "$file:$line — no @version and no # renovate: anchor above:${text#*npx}"
  fi
done < <(git grep -nE 'npx[[:space:]]+.*-p[[:space:]]' -- "${FILES[@]}" 2>/dev/null)

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
