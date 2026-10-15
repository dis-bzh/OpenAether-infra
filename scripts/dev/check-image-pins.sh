#!/usr/bin/env bash
# Which `image:` references in this repository are not pinned by digest.
#
# A tag can be re-pushed upstream and change no committed byte (ANSSI SSDLC
# CICD-AIP-01a/-03). This lists every `image:` value in a tracked manifest and
# sorts it: pinned (`@sha256:`), recorded (tag, with its digest in
# flux-image-digests.lock, re-checked weekly by check-flux-image-digests.sh), or
# unpinned. REPORT-ONLY by default (exit 0, one `::warning::` per unpinned image
# under GitHub Actions): rendered upstream manifests are rewritten by
# `task render-manifests`, so failing on them today would block every render. With
# `--enforce` an unpinned image exits 1; switch it on in `task lint` once the
# renderer pins digests.
#
# Usage:
#   check-image-pins.sh [--enforce] [--lock <file>] [file...]   # default: tracked *.yaml, *.yml, *.tftpl
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
ENFORCE=false
LOCK=infrastructure/opentofu/cluster/bootstrap-manifests/flux-image-digests.lock
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --enforce) ENFORCE=true ;;
    --lock) LOCK="${2:?--lock needs a file}"; shift ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
if [ ${#FILES[@]} -eq 0 ]; then
  # Docs and test fixtures quote images as prose or as deliberately bad input.
  mapfile -t FILES < <(git ls-files '*.yaml' '*.yml' '*.tftpl' | grep -vE '(^|/)(docs|testdata)/' || true)
fi
[ ${#FILES[@]} -gt 0 ] || { echo "✗ no manifest to read — the file list is broken, not the repository" >&2; exit 1; }

declare -A RECORDED=()
if [ -f "$LOCK" ]; then
  while read -r ref _; do [ -n "$ref" ] && RECORDED["$ref"]=1; done <"$LOCK"
fi

pinned=0; recorded=0; unpinned=0; seen=0
while IFS=$'\t' read -r file line ref; do
  seen=$((seen + 1))
  case "$ref" in
    *'@sha256:'*) pinned=$((pinned + 1)) ;;
    *'${'*|*'{{'*) ;;  # templated: the rendered result is what matters, not the template
    *)
      if [ -n "${RECORDED[$ref]:-}" ]; then
        recorded=$((recorded + 1))
      else
        unpinned=$((unpinned + 1))
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
          echo "::warning file=${file},line=${line}::image ${ref} is pinned by tag only"
        else
          echo "  ~ ${file}:${line} ${ref} (tag only)"
        fi
      fi ;;
  esac
done < <(grep -nHE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[^[:space:]#]' "${FILES[@]}" 2>/dev/null |
         sed -E 's/^([^:]+):([0-9]+):[[:space:]]*-?[[:space:]]*image:[[:space:]]*["'"'"']?([^"'"'"'[:space:]#]+).*/\1\t\2\t\3/')

printf '%s image reference(s): %s pinned by digest, %s tag with a recorded digest, %s tag only\n' \
  "$seen" "$pinned" "$recorded" "$unpinned"
if $ENFORCE && [ "$unpinned" -gt 0 ]; then
  echo "✗ ${unpinned} image(s) pinned by tag only (--enforce)" >&2
  exit 1
fi
exit 0
