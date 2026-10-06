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
# Next to the current object it keeps dated GENERATIONS, <key>.<UTC timestamp>: one per run (identical
# states too, so two uploads of the state), only for a state that holds Talos secrets, written before
# the current object is touched (#267). The newest STATE_GENERATIONS are kept (the one place retention
# is set). `--list` prints them, most recently written first, and works with the secrets gone. Limits:
# a generation holds A PKI, not necessarily the one the nodes trust; and its label is tofu's view of the
# backend while its bytes are the primary bucket's, one object only while the backend is that bucket
# (not after a reconfigure against the replica).
#
# Creds:
#   primary : the ambient AWS_* (the Taskfile sets it to the cluster provider's keys)
#   replica : <PU>_BACKUP_AWS_* -> BACKUP_AWS_* -> primary    (../lib/common.sh::s3_cred)
#
# Usage: ./scripts/ops/backup-state.sh [--list] [tofu_dir]   (default: infrastructure/opentofu/cluster)
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

LIST=0; [ "${1:-}" != --list ] || { LIST=1; shift; }
TOFU_DIR="${1:-infrastructure/opentofu/cluster}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A retention that keeps nothing (0, a typo) is refused, not guessed.
GENERATIONS="${STATE_GENERATIONS:-5}"
[[ "$GENERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "✗ STATE_GENERATIONS must be a whole number, 1 or more (got '$GENERATIONS'): nothing was replicated." >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "✗ jq required"; exit 1; }
oa_aws_compat

cd "$TOFU_DIR"
# The replica is the undo of infra-down-plan's untracking (#66): a state without its secrets must not replace it.
# Not for --list: that is read-only, and wanted most when the secrets are gone.
[ "$LIST" = 1 ] || "$HERE/../internal/bootstrap-in-state.sh" >/dev/null \
  || { echo "✗ nothing was replicated: the replica may hold the only copy of the secrets, leave it as it is." >&2; exit 1; }
# "There is nothing to replicate yet" and "I could not ask" are different
# answers, and this used to give the first for both: any failure of `tofu output`
# — no backend, no credentials, wrong directory — became 'null', a warning and
# exit 0. The caller cannot see through that, so un-swallowing it in the Taskfile
# achieved nothing on its own.
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
T="$(tofu output -json backup_targets 2>"$ERR")" || T=""
# A listing that finds no target has listed nothing: it is a failure with the tofu-free way, never a skipped backup.
LS_HINT='Without tofu: aws s3 ls s3://<replica-bucket>/<key>. --endpoint-url <replica endpoint> --region <replica region>'
if [ -z "$T" ] || [ "$T" = null ]; then
  if grep -qiE 'no outputs|not found|does not have an output' "$ERR" 2>/dev/null || [ ! -s "$ERR" ]; then
    [ "$LIST" = 0 ] || { echo "✗ no backup_targets output, so there is nothing to list from here. $LS_HINT" >&2; exit 1; }
    echo "⚠ no backup_targets output — apply the infra first (or backup_enabled=false). Skipping state backup."
    exit 0
  fi
  echo "✗ could not read backup_targets, so nothing was $([ "$LIST" = 1 ] && echo listed || echo replicated) and nothing can" >&2
  echo "  confirm the copy exists. This is not 'no backup configured':" >&2
  sed 's/^/    /' "$ERR" >&2
  [ "$LIST" = 0 ] || echo "  $LS_HINT" >&2
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

replica() { AWS_ACCESS_KEY_ID="$BACKUP_AK" AWS_SECRET_ACCESS_KEY="$BACKUP_SK" aws "$@" --endpoint-url "$REPLICA_EP" --region "$REPLICA_REGION"; }
# Everything under the state key as [key, modified, size] rows ("null" when empty). A generation is <key>.<timestamp>
# and nothing else: retention never touches a key it did not name itself.
rows() { replica s3api list-objects-v2 --bucket "$REPLICA_BUCKET" --prefix "$KEY" --query 'Contents[].[Key,LastModified,Size]' --output json; }
JQ_GEN='def gen: .[0] | startswith($k + ".") and (ltrimstr($k + ".") | test("^[0-9]{8}T[0-9]{6}Z$"));'

if [ "$LIST" = 1 ]; then
  echo "s3://$REPLICA_BUCKET/ on ${REPLICA_EP}, most recently written first (LastModified, not the key's stamp: that is the writing machine's clock). Restore one by copying it over the state key (README, \"Lost the Talos secrets\")."
  rows | jq -r --arg k "$KEY" "$JQ_GEN"' (. // []) | ([.[] | select(.[0] == $k)] + ([.[] | select(gen)] | sort_by([.[1], .[0]]) | reverse))
    | if length == 0 then "  (no state object under \($k))" else .[] | ["  " + (if .[0] == $k then "current   " else "generation" end), .[1], .[2], .[0]] | @tsv end'
  exit 0
fi

# A generation is only ever a state that holds the secrets; the cluster-wide guard above passes a state with no
# Talos resources at all, which is worth replicating but not worth a generation. An unreadable state moves nothing.
STATE_LIST="$(tofu state list -no-color 2>&1)" \
  || { echo "✗ cannot read the state, so nothing was replicated:" >&2; sed 's/^/    /' <<<"$STATE_LIST" >&2; exit 1; }
SECRETS=0; ! grep -qF 'module.talos.talos_machine_secrets.' <<<"$STATE_LIST" || SECRETS=1

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Download the ciphertext from primary (ambient AWS_*), re-upload to replica (+SSE).
aws s3 cp "s3://$PRIMARY_BUCKET/$KEY" "$WORK/state" \
  --endpoint-url "$PRIMARY_EP" --region "$PRIMARY_REGION" >/dev/null
# The dated copy first: the current object is only replaced once the same bytes sit beside it under a name that stays.
GEN=""
if [ "$SECRETS" = 1 ]; then
  GEN="$KEY.$(date -u +%Y%m%dT%H%M%SZ)"
  replica s3 cp "$WORK/state" "s3://$REPLICA_BUCKET/$GEN" --sse AES256 >/dev/null \
    || { echo "✗ could not write s3://$REPLICA_BUCKET/$GEN: the current replica was left as it is." >&2; exit 1; }
fi
replica s3 cp "$WORK/state" "s3://$REPLICA_BUCKET/$KEY" --sse AES256 >/dev/null \
  || { echo "✗ could not write s3://$REPLICA_BUCKET/$KEY${GEN:+ (the generation $GEN was written)}." >&2; exit 1; }

if [ "$REPLICA_EP" = "$PRIMARY_EP" ]; then
  echo "✓ tfstate replicated (still client-encrypted) to s3://$REPLICA_BUCKET/$KEY — SAME provider"
else
  echo "✓ tfstate replicated (still client-encrypted) to s3://$REPLICA_BUCKET/$KEY — on ${REPLICA_EP}"
fi
[ -n "$GEN" ] || { echo "  no generation written: this state holds no Talos secrets, so the older generations that do are left alone."; exit 0; }

# Retention: names sort chronologically. The key just written is never a victim whatever its clock says: a
# machine whose clock is behind would otherwise prune the newest copy at once. A failure here costs space, not data.
PRUNED=0
if OLD="$(rows | jq -r --arg k "$KEY" --arg new "$GEN" --argjson keep "$GENERATIONS" "$JQ_GEN"' (. // []) | map(select(gen) | .[0]) | sort
      | . as $all | ($all - [$new])[0:([($all | length) - $keep, 0] | max)] | .[]')"; then
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    if replica s3 rm "s3://$REPLICA_BUCKET/$old" >/dev/null; then PRUNED=$((PRUNED + 1))
    else echo "⚠ could not remove the old generation s3://$REPLICA_BUCKET/$old (retention retries next run)" >&2; fi
  done <<<"$OLD"
else
  echo "⚠ could not list the generations in s3://$REPLICA_BUCKET: none was pruned (retention retries next run)" >&2
fi
echo "  generation $GEN kept (newest $GENERATIONS), $PRUNED older removed. List: backup-state.sh --list"
