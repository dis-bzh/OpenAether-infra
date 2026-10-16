#!/usr/bin/env bash
# Preflight for the secrets that protect the state, the access artifacts and the etcd snapshots:
# TF_VAR_encryption_passphrase (required) and TF_VAR_artifact_passphrase (optional, must then differ).
# Mode through OA_PASSPHRASE_CHECK=warn|enforce|off (default warn): see oa_check_passphrase.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

rc=0
oa_check_passphrase TF_VAR_encryption_passphrase "${TF_VAR_encryption_passphrase:-}" || rc=1
if [ -n "${TF_VAR_artifact_passphrase:-}" ]; then
  oa_check_passphrase TF_VAR_artifact_passphrase "$TF_VAR_artifact_passphrase" || rc=1
  if [ "$TF_VAR_artifact_passphrase" = "${TF_VAR_encryption_passphrase:-}" ] && [ "${OA_PASSPHRASE_CHECK:-warn}" != off ]; then
    echo "$([ "${OA_PASSPHRASE_CHECK:-warn}" = enforce ] && echo ✗ || echo ⚠) TF_VAR_artifact_passphrase equals TF_VAR_encryption_passphrase: one leak opens both." >&2
    [ "${OA_PASSPHRASE_CHECK:-warn}" = enforce ] && rc=1
  fi
fi
exit "$rc"
