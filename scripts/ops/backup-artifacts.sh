#!/usr/bin/env bash
# ==============================================================================
# OpenAether — encrypted backup of cluster access artifacts (talosconfig/kubeconfig)
#
# Called by cluster/backup.tf (local-exec) during a Phase-2 apply. CLIENT-side
# encrypts each artifact with gpg (symmetric AES-256) using PASSPHRASE (backup.tf: the
# artifact passphrase when set, else the tfstate one), then uploads the ciphertext to TWO object
# stores — PRIMARY (the cluster's own provider) and REPLICA (in prod a different
# provider) — with S3 SSE (server-side) layered on top.
#
# Inputs (env, set by backup.tf):
#   TALOSCONFIG_B64, KUBECONFIG_B64   base64 of the artifacts
#   PASSPHRASE                        client-encryption passphrase (>=32)
#   PROVIDER                          cluster provider (scaleway|ovh|outscale)
#   PRIMARY_BUCKET / PRIMARY_EP / PRIMARY_REGION
#   REPLICA_BUCKET / REPLICA_EP / REPLICA_REGION
# Creds are resolved by ../lib/common.sh::s3_cred from PROVIDER (primary + replica).
#
# Restore (DR): see cluster/README.md → "Restore a backup".
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required for backups (or set backup_enabled=false)"; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "✗ gpg required for client-side encryption (or set backup_enabled=false)"; exit 1; }
oa_aws_compat

PRIMARY_AK="$(s3_cred "$PROVIDER" primary ak)"; PRIMARY_SK="$(s3_cred "$PROVIDER" primary sk)"
# The replica endpoint decides whose keys these are — see s3_cred.
BACKUP_AK="$(s3_cred "$PROVIDER" backup ak "${REPLICA_EP:-}")"
BACKUP_SK="$(s3_cred "$PROVIDER" backup sk "${REPLICA_EP:-}")"

# Isolated GnuPG home (symmetric mode uses no keyring, but keep ~/.gnupg untouched).
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
WORK="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME" "$WORK"' EXIT

# Client-side encrypt: AES-256 in OpenPGP CFB with a SHA-1 MDC (tamper-evident, not an AEAD mode:
# no OCB/AEAD option is requested), key derived with iterated-salted S2K (max count, SHA-512).
# Passphrase via fd 3 so it never appears in argv.
enc() { # base64-content  out-file
  printf '%s' "$1" | base64 -d | \
    gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
        --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 \
        --symmetric --cipher-algo AES256 -o "$2" 3< <(printf '%s' "$PASSPHRASE")
}

put() { # file  bucket  endpoint  region  access_key  secret_key
  AWS_ACCESS_KEY_ID="$5" AWS_SECRET_ACCESS_KEY="$6" \
    aws s3 cp "$1" "s3://$2/backups/$(basename "$1")" \
      --endpoint-url "$3" --region "$4" --sse AES256 >/dev/null
}

enc "$TALOSCONFIG_B64" "$WORK/talosconfig.gpg"
enc "$KUBECONFIG_B64"  "$WORK/kubeconfig.gpg"

for f in "$WORK/talosconfig.gpg" "$WORK/kubeconfig.gpg"; do
  put "$f" "$PRIMARY_BUCKET" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK"
  put "$f" "$REPLICA_BUCKET" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK"  "$BACKUP_SK"
done

echo "✓ Encrypted talosconfig + kubeconfig → s3://$PRIMARY_BUCKET/backups/ + s3://$REPLICA_BUCKET/backups/"
