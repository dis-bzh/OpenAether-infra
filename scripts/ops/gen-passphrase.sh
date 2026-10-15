#!/usr/bin/env bash
# Print a fresh random passphrase (48 random bytes, base64: 384 bits) on stdout, and nothing else.
# Run it once per secret: the state passphrase and the artifact passphrase must differ and be kept
# in different places, or the separation is cosmetic (docs/first-cluster.md).
#   export TF_VAR_encryption_passphrase="$(scripts/ops/gen-passphrase.sh)"
set -euo pipefail
command -v openssl >/dev/null 2>&1 || { echo "✗ openssl is required" >&2; exit 1; }
openssl rand -base64 48 | tr -d '\n'
echo
