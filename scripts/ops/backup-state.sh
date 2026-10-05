#!/usr/bin/env bash
# ==============================================================================
# OpenAether — replicate the (already client-encrypted) tfstate to the backup store
#
# The S3 backend object is ALREADY ciphertext (OpenTofu encryption{} block,
# AES-GCM + PBKDF2). This copies it from the PRIMARY bucket to the "-backup" one —
# in prod a DIFFERENT provider — layering S3 SSE on top.
#
# Run AFTER each apply (the backend only flushes state on apply exit). The
# bucket/endpoint/key/provider come from the `backup_targets` tofu output.
#
# Creds:
#   primary : the ambient AWS_* (the Taskfile sets it to the cluster provider's keys)
#   replica : <PU>_BACKUP_AWS_* -> BACKUP_AWS_* -> primary    (../lib/common.sh::s3_cred)
#
# Usage: ./scripts/ops/backup-state.sh [tofu_dir]   (default: infrastructure/opentofu/cluster)
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

TOFU_DIR="${1:-infrastructure/opentofu/cluster}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "✗ jq required"; exit 1; }
oa_aws_compat

cd "$TOFU_DIR"
# The replica is the undo of infra-down-plan's untracking (#66): a state without its secrets must not replace it.
"$HERE/../internal/bootstrap-in-state.sh" >/dev/null \
  || { echo "✗ nothing was replicated: the replica may hold the only copy of the secrets, leave it as it is." >&2; exit 1; }
# "There is nothing to replicate yet" and "I could not ask" are different
# answers, and this used to give the first for both: any failure of `tofu output`
# — no backend, no credentials, wrong directory — became 'null', a warning and
# exit 0. The caller cannot see through that, so un-swallowing it in the Taskfile
# achieved nothing on its own.
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
T="$(tofu output -json backup_targets 2>"$ERR")" || T=""
if [ -z "$T" ] || [ "$T" = null ]; then
  if grep -qiE 'no outputs|not found|does not have an output' "$ERR" 2>/dev/null || [ ! -s "$ERR" ]; then
    echo "⚠ no backup_targets output — apply the infra first (or backup_enabled=false). Skipping state backup."
    exit 0
  fi
  echo "✗ could not read backup_targets, so nothing was replicated and nothing can" >&2
  echo "  confirm the copy exists. This is not 'no backup configured':" >&2
  sed 's/^/    /' "$ERR" >&2
  exit 1
fi

PRIMARY_BUCKET="$(jq -r '.state_bucket_primary' <<<"$T")"
REPLICA_BUCKET="$(jq -r '.state_bucket_replica' <<<"$T")"
KEY="$(jq -r '.state_key' <<<"$T")"
PRIMARY_EP="$(jq -r '.primary_endpoint' <<<"$T")"
PRIMARY_REGION="$(jq -r '.primary_region' <<<"$T")"
REPLICA_EP="$(jq -r '.replica_endpoint' <<<"$T")"
REPLICA_REGION="$(jq -r '.replica_region' <<<"$T")"
PROVIDER="$(jq -r '.provider // empty' <<<"$T")"
# Fallback: derive provider from the bucket name (s3-<project>-<provider>-tfstate-<env>).
[ -n "$PROVIDER" ] || PROVIDER="$(sed -E 's/^s3-[^-]+-([a-z]+)-tfstate-.*/\1/' <<<"$PRIMARY_BUCKET")"

# Replica creds = the cluster provider's BACKUP creds (cross-provider in prod).
BACKUP_AK="$(s3_cred "$PROVIDER" backup ak "$REPLICA_EP")"
BACKUP_SK="$(s3_cred "$PROVIDER" backup sk "$REPLICA_EP")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Download the ciphertext from primary (ambient AWS_*), re-upload to replica (+SSE).
aws s3 cp "s3://$PRIMARY_BUCKET/$KEY" "$WORK/state" \
  --endpoint-url "$PRIMARY_EP" --region "$PRIMARY_REGION" >/dev/null
AWS_ACCESS_KEY_ID="$BACKUP_AK" AWS_SECRET_ACCESS_KEY="$BACKUP_SK" \
  aws s3 cp "$WORK/state" "s3://$REPLICA_BUCKET/$KEY" \
    --endpoint-url "$REPLICA_EP" --region "$REPLICA_REGION" --sse AES256 >/dev/null

if [ "$REPLICA_EP" = "$PRIMARY_EP" ]; then
  echo "✓ tfstate replicated (still client-encrypted) to s3://$REPLICA_BUCKET/$KEY — SAME provider"
else
  echo "✓ tfstate replicated (still client-encrypted) to s3://$REPLICA_BUCKET/$KEY — on ${REPLICA_EP}"
fi
