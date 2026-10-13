#!/usr/bin/env bash
# Compare a downloaded Talos Image Factory artifact with the sha256 recorded in
# talos-image/images.lock, before it is converted and written to a cloud
# (ANSSI SSDLC CICD-AIP-03). Called by the talos-image modules' local-exec.
#
# Usage: verify-image-checksum.sh <file> <expected sha256 or ""> <off|warn|enforce> <label>
#   off     nothing is read or said (the module's old behaviour)
#   warn    a mismatch or a missing record is printed, the build goes on
#   enforce either one exits 1
set -euo pipefail

FILE="${1:?usage: verify-image-checksum.sh <file> <expected> <off|warn|enforce> <label>}"
EXPECTED="${2-}"
MODE="${3:?mode is required}"
LABEL="${4:-$FILE}"

case "$MODE" in
  off) exit 0 ;;
  warn | enforce) ;;
  *) echo "✗ image_checksum_mode must be off, warn or enforce (got '${MODE}')" >&2; exit 2 ;;
esac

fail() { # <message>: a problem, fatal only under enforce
  if [ "$MODE" = enforce ]; then echo "✗ ${LABEL}: $1" >&2; exit 1; fi
  echo "⚠ ${LABEL}: $1 (image_checksum_mode=warn: continuing)" >&2
}

[ -f "$FILE" ] || { echo "✗ ${LABEL}: ${FILE} is missing, nothing to verify" >&2; exit 1; }
if [ -z "$EXPECTED" ]; then
  fail "no sha256 recorded in images.lock for this schematic, version and platform — run scripts/bootstrap/talos-image-lock.sh"
  exit 0
fi
ACTUAL="$(sha256sum "$FILE" | awk '{print $1}')"
if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "✓ ${LABEL}: sha256 matches images.lock (${ACTUAL:0:12}…)"
else
  fail "sha256 is ${ACTUAL}, images.lock records ${EXPECTED}"
fi
