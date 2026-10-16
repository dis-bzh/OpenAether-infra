#!/usr/bin/env bash
# flux-install.yaml pins its seven controller images by TAG only (#119) — a tag
# force-moved upstream changes not one byte of the committed YAML, so nothing
# in this repository would notice: `task render-check` re-renders from the
# same pinned tag, Cléa has no `# renovate:` anchor on these lines, and Trivy
# has this file in `skip-files`. This is the OTHER half of #119 (the offline
# half — sha256 of the file itself — is upstream-artifacts.lock): resolve each
# tag to the digest ghcr.io serves TODAY and compare it to the one recorded
# below the last time this ran.
#
# Needs the network (an anonymous ghcr.io token, same as `docker pull` would
# use) but never a cloud account — same rung distinction Cléa's probes draw.
# Not part of `task lint`, which must stay fully offline: .github/workflows/image-digests.yml runs it weekly.
#
# Usage:
#   check-flux-image-digests.sh          # compare against the recorded lock
#   check-flux-image-digests.sh --write  # resolve current digests and rewrite the lock
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT}/infrastructure/opentofu/cluster/bootstrap-manifests/flux-install.yaml"
LOCK="${ROOT}/infrastructure/opentofu/cluster/bootstrap-manifests/flux-image-digests.lock"
WRITE=false
[[ "${1:-}" == "--write" ]] && WRITE=true

[ -f "$MANIFEST" ] || { echo "✗ ${MANIFEST} is missing" >&2; exit 1; }

# ghcr.io/fluxcd/<name>:<tag> — every controller image flux-install.yaml pins,
# in the order they appear. `sort -u` because two containers can share one image.
mapfile -t REFS < <(grep -oE 'ghcr\.io/fluxcd/[a-z-]+:v[0-9.]+' "$MANIFEST" | sort -u)
[ "${#REFS[@]}" -gt 0 ] || { echo "✗ no ghcr.io/fluxcd/* image ref found in ${MANIFEST}" >&2; exit 1; }

resolve_digest() { # <image> <tag>
  local image="$1" tag="$2" token
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:fluxcd/${image}:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  curl -fsS -D - -o /dev/null \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/fluxcd/${image}/manifests/${tag}" |
    grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}'
}

if $WRITE; then
  : >"$LOCK"
  for ref in "${REFS[@]}"; do
    image="${ref#ghcr.io/fluxcd/}"; image="${image%%:*}"; tag="${ref##*:}"
    digest="$(resolve_digest "$image" "$tag")"
    [ -n "$digest" ] || { echo "✗ ${ref} — ghcr.io returned no Docker-Content-Digest" >&2; exit 1; }
    printf '%s %s\n' "$ref" "$digest" >>"$LOCK"
    echo "  recorded ${ref} -> ${digest}"
  done
  echo "OK — ${LOCK} written."
  exit 0
fi

[ -f "$LOCK" ] || { echo "✗ ${LOCK} is missing — run with --write to create it" >&2; exit 1; }
declare -A RECORDED
while read -r ref digest; do
  [ -n "$ref" ] || continue
  RECORDED["$ref"]="$digest"
done <"$LOCK"

FAIL=0
for ref in "${REFS[@]}"; do
  recorded="${RECORDED[$ref]:-}"
  if [ -z "$recorded" ]; then
    echo "✗ ${ref} — not in ${LOCK} (run --write)" >&2
    FAIL=1
    continue
  fi
  image="${ref#ghcr.io/fluxcd/}"; image="${image%%:*}"; tag="${ref##*:}"
  live="$(resolve_digest "$image" "$tag")"
  if [ -z "$live" ]; then
    echo "✗ ${ref} — ghcr.io returned no Docker-Content-Digest" >&2
    FAIL=1
  elif [ "$live" != "$recorded" ]; then
    echo "✗ ${ref} — tag now resolves to ${live}, recorded ${recorded} (re-run --write once you have verified the new digest)" >&2
    FAIL=1
  else
    echo "  ✓ ${ref} — ${live}"
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "OK — every flux-install.yaml image tag still resolves to its recorded digest."
fi
exit "$FAIL"
