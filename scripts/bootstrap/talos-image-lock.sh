#!/usr/bin/env bash
# Record, or re-check, the sha256 of the Talos Image Factory raw images the
# talos-image modules download (talos-image/images.lock). The schematic id only
# fixes what is asked for; the lock is what lets a later build notice that the
# bytes are not the ones reviewed (ANSSI SSDLC CICD-AIP-03).
#
# One line per file: "<sha256>  <schematic>/<version>/<platform>-<arch>", where the
# platform is the Factory's own name for it (scaleway, openstack, aws for Outscale,
# nocloud for Proxmox). Downloads ~230 MB per line; needs the network, no credential.
#
# Usage:
#   talos-image-lock.sh [--version vX.Y.Z] [--arch amd64,arm64]          # (re)record, keep other versions
#   talos-image-lock.sh --check [--version vX.Y.Z] [--arch amd64,arm64]  # re-download, compare, change nothing
# Environment: OA_FACTORY_BASE overrides https://factory.talos.dev (tests point it at file://).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK="${OA_IMAGES_LOCK:-${ROOT}/infrastructure/opentofu/talos-image/images.lock}"
BASE="${OA_FACTORY_BASE:-https://factory.talos.dev}"
PLATFORMS=(scaleway openstack aws nocloud)
VERSION=""; ARCHES="amd64"; CHECK=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift ;;
    --arch) ARCHES="${2:?--arch needs a value}"; shift ;;
    --check) CHECK=true ;;
    *) echo "✗ unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$VERSION" ] || VERSION="$("${ROOT}/scripts/internal/talos-version.sh")"
SCHEMATIC="$(awk '/variable "talos_installer_schematic_id"/,/^}/' "${ROOT}/infrastructure/opentofu/cluster/variables.tf" \
  | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([0-9a-f]{64})".*/\1/p' | head -1)"
[ -n "$SCHEMATIC" ] || { echo "✗ could not read talos_installer_schematic_id from cluster/variables.tf" >&2; exit 1; }
for a in ${ARCHES//,/ }; do
  [[ "$a" == amd64 || "$a" == arm64 ]] || { echo "✗ arch must be amd64 or arm64 (got ${a})" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/talos-image-lock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
NEW="$TMP/new"; : >"$NEW"
for a in ${ARCHES//,/ }; do
  for p in "${PLATFORMS[@]}"; do
    key="${SCHEMATIC}/${VERSION}/${p}-${a}"
    echo "▶ ${p}-${a} ${VERSION}"
    curl -fsSL --retry 3 "${BASE}/image/${key}.raw.zst" -o "$TMP/img"
    printf '%s  %s\n' "$(sha256sum "$TMP/img" | awk '{print $1}')" "$key" >>"$NEW"
    rm -f "$TMP/img"
  done
done

if $CHECK; then
  rc=0
  while read -r sum key; do
    want="$(awk -v k="$key" '$2 == k {print $1}' "$LOCK" 2>/dev/null || true)"
    if [ -z "$want" ]; then echo "✗ ${key} is not in ${LOCK}"; rc=1
    elif [ "$want" != "$sum" ]; then echo "✗ ${key}: Factory serves ${sum}, the lock records ${want}"; rc=1
    else echo "✓ ${key}"; fi
  done <"$NEW"
  exit "$rc"
fi

{
  grep -E '^#' "$LOCK" 2>/dev/null || cat <<'HDR'
# sha256 of the Image Factory raw.zst each talos-image module downloads, one line per
# "<schematic>/<version>/<platform>-<arch>". Written by scripts/bootstrap/talos-image-lock.sh;
# read by the talos-image root (image_checksum_mode, default warn). Review a change to this file
# like a change to code: each line is the OS every node of that version boots.
HDR
  { grep -Ev '^#|^[[:space:]]*$' "$LOCK" 2>/dev/null || true; cat "$NEW"; } |
    awk '{ line[$2] = $0 } END { for (k in line) print line[k] }' | sort -k2
} >"$TMP/out"
mkdir -p "$(dirname "$LOCK")"
cp "$TMP/out" "$LOCK"
echo "OK — ${LOCK} holds $(grep -Evc '^#|^[[:space:]]*$' "$LOCK") line(s)."
