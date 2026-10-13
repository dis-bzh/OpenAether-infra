#!/usr/bin/env bash
# Before anything bills: every key in openbao_recovery_pgp_keys must be one OpenBao can encrypt a recovery share to.
#
# `sys/init` commits the cluster BEFORE it encrypts the shares: given a key with no usable encryption subkey (a signing-only
# key, an expired subkey) it answers HTTP 400 with the cluster already initialised, no root token and no shares, and the
# first run ends in a re-init. Cheap to catch here, expensive after. Prints each key's fingerprint, so that the person
# who pastes it can compare it with the one they hold.
#
# Needs gpg. Without it: a warning and exit 0 (refusing to deploy over a check that could not run is worse).
#
# Usage: check-openbao-keys.sh <env-file.tfvars>
set -uo pipefail

TFVARS="${1:?usage: check-openbao-keys.sh <env-file.tfvars>}"
[ -f "$TFVARS" ] || { echo "✗ no $TFVARS" >&2; exit 1; }

# The base64 strings inside `openbao_recovery_pgp_keys = [ ... ]`, one per line.
KEYS="$(awk '
  /^[[:space:]]*openbao_recovery_pgp_keys[[:space:]]*=/ { on = 1 }
  on { sub(/#.*/, ""); print }
  on && /\]/ { on = 0 }
' "$TFVARS" | grep -oE '"[A-Za-z0-9+/]{100,}={0,2}"' | tr -d '"')"
[ -n "$KEYS" ] || exit 0   # a development bootstrap: nothing to check

if ! command -v gpg >/dev/null 2>&1; then
  echo "⚠ openbao_recovery_pgp_keys is set but gpg is not installed: the keys were NOT checked for an encryption subkey." >&2
  exit 0
fi

G="$(mktemp -d)"; trap 'rm -rf "$G"' EXIT
i=0; bad=0
while IFS= read -r k; do
  i=$((i + 1))
  out="$(printf '%s' "$k" | base64 -d 2>/dev/null | GNUPGHOME="$G" gpg --batch --quiet --with-colons --with-fingerprint \
        --import-options show-only --import 2>/dev/null)" || out=""
  fpr="$(awk -F: '/^fpr/ {print $10; exit}' <<<"$out")"
  # A usable key (primary or subkey) that can encrypt: capability 'e', validity none of expired, revoked, invalid, disabled.
  if awk -F: '($1 == "pub" || $1 == "sub") && $2 !~ /^[erid]$/ && $12 ~ /e/ {found = 1} END {exit !found}' <<<"$out"; then
    echo "  ✓ openbao_recovery_pgp_keys[$i]: ${fpr:-?} can encrypt"
  else
    echo "  ✗ openbao_recovery_pgp_keys[$i]: ${fpr:-not a PGP public key} has no usable encryption subkey (gpg --list-keys must show an [E]; export with: gpg --export <id> | base64 -w0)" >&2
    bad=1
  fi
done <<<"$KEYS"
[ "$bad" = 0 ] || { echo "✗ OpenBao would initialise and then fail to encrypt a recovery share: fix the key(s) in $TFVARS first." >&2; exit 1; }
