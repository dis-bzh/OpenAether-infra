#!/usr/bin/env bash
# OpenAether — ensure the backup object stores exist (idempotent).
#
# Creates the four buckets a cluster needs, names derived from its tfvars (same
# convention as cluster/backup.tf): tfstate and artifacts, each with a -backup
# replica.
#
# Only the STATE PRIMARY must exist before `tofu init` (the S3 backend does not
# create its own bucket) — that one is FATAL. The other three are used later and
# may live on another provider, so they are best-effort and never block a deploy.
#
# --preflight (cluster-up only) also refuses a prod cluster with no state object
# yet whose replica shares the primary's cloud. One with a state object is only
# warned: a live cluster must stay plannable, upgradable and destroyable.
#
# Usage: ensure-buckets.sh <path/to/cluster.tfvars> [--preflight]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

TFVARS="${1:?usage: ensure-buckets.sh <cluster.tfvars> [--preflight]}"
case "${2:-}" in
  "" | --preflight) PREFLIGHT="${2:-}" ;;
  *) echo "✗ unknown argument: $2 (usage: ensure-buckets.sh <cluster.tfvars> [--preflight])"; exit 1 ;;
esac
[ -f "$TFVARS" ] || { echo "✗ tfvars not found: $TFVARS"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }
oa_aws_compat

CLUSTER="$(tfv "$TFVARS" cluster_name)"
ROLE="$(tfv "$TFVARS" cluster_role)"
ENVN="$(tfv "$TFVARS" environment)"
PRIMARY_EP="$(tfv "$TFVARS" s3_primary_endpoint)"
PRIMARY_REGION="$(tfv "$TFVARS" s3_primary_region)"
REPLICA_EP="$(tfv "$TFVARS" s3_replica_endpoint)"
REPLICA_REGION="$(tfv "$TFVARS" s3_replica_region)"
PROVIDER="$(tfv_provider "$TFVARS")"
PU="$(provider_pu "$PROVIDER")" || { echo "✗ could not detect provider from node_distribution in $TFVARS"; exit 1; }

[ -n "$CLUSTER" ] && [ -n "$ROLE" ] && [ -n "$ENVN" ] || {
  echo "✗ could not read cluster_name/cluster_role/environment from $TFVARS"; exit 1; }
[ -n "$PRIMARY_EP" ] && [ -n "$REPLICA_EP" ] || {
  echo "✗ could not read s3_primary_endpoint/s3_replica_endpoint from $TFVARS"; exit 1; }

PROJECT="$(oa_project "$CLUSTER" "$(tfv "$TFVARS" bucket_suffix)")"
PRIMARY_AK="$(s3_cred "$PROVIDER" primary ak)"
PRIMARY_SK="$(s3_cred "$PROVIDER" primary sk)"
# The endpoint decides whose keys these are: a bucket on another cloud needs
# that cloud's credentials, not this cluster's. See s3_cred.
BACKUP_AK="$(s3_cred "$PROVIDER" backup ak "$REPLICA_EP")"
BACKUP_SK="$(s3_cred "$PROVIDER" backup sk "$REPLICA_EP")"
BACKUP_SRC="$(s3_cred_source "$PROVIDER" backup ak "$REPLICA_EP")"
RPROV="$(provider_of_endpoint "$REPLICA_EP")"
RPU=""
if [ -n "$RPROV" ]; then RPU="$(provider_pu "$RPROV")"; fi
[ -n "$PRIMARY_AK" ] || {
  echo "✗ no S3 creds for '${PROVIDER}': export ${PU}_AWS_ACCESS_KEY_ID + ${PU}_AWS_SECRET_ACCESS_KEY"; exit 1; }

STATE_PRIMARY="$(oa_state_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
ARTIFACT_PRIMARY="$(oa_artifact_bucket "$PROJECT" "$PROVIDER" "$ROLE" "$ENVN")"

ensure_bucket() { # name  endpoint  region  access_key  secret_key
  if AWS_ACCESS_KEY_ID="$4" AWS_SECRET_ACCESS_KEY="$5" \
       aws s3api head-bucket --bucket "$1" --endpoint-url "$2" --region "$3" >/dev/null 2>&1; then
    echo "  ✓ $1 (exists)"
  else
    AWS_ACCESS_KEY_ID="$4" AWS_SECRET_ACCESS_KEY="$5" \
      aws s3 mb "s3://$1" --endpoint-url "$2" --region "$3" >/dev/null \
      && echo "  + $1 (created)"
  fi
}

# Before the first bucket, and before cluster-up's image build can spend. A state
# object (same key as tf-backend.sh) means the cluster was applied at least once,
# even if since destroyed with its bucket kept: warn only.
WHY=""
if [ -n "$PREFLIGHT" ] && [ "$ENVN" = prod ]; then WHY="$(oa_replica_colocated "$PRIMARY_EP" "$REPLICA_EP")"; fi
if [ -n "$WHY" ]; then
  if AWS_ACCESS_KEY_ID="$PRIMARY_AK" AWS_SECRET_ACCESS_KEY="$PRIMARY_SK" \
       aws s3api head-object --bucket "$STATE_PRIMARY" --key "${CLUSTER}.tfstate" \
         --endpoint-url "$PRIMARY_EP" --region "$PRIMARY_REGION" >/dev/null 2>&1; then
    echo "  ⚠ environment = \"prod\", and ${WHY}."
    echo "    s3://${STATE_PRIMARY}/${CLUSTER}.tfstate exists: the cluster was applied"
    echo "    at least once, so this is not refused, and cluster-verify reports it red."
    echo "    If it was torn down, this is a rebuild: stop and fix s3_replica_endpoint"
    echo "    before the image build spends. If it is live, move s3_replica_endpoint to"
    echo "    another provider; do not switch it to \"dev\" (that renames its state bucket)."
  else
    echo "✗ environment = \"prod\", and ${WHY}." >&2
    echo "  A copy on the cloud that just failed is not a backup. No state was found at" >&2
    echo "    s3://${STATE_PRIMARY}/${CLUSTER}.tfstate" >&2
    echo "  so this is a new cluster, and it stops before anything is built. Point" >&2
    echo "  s3_replica_endpoint at another provider's S3 (that cloud's <PU>_AWS_* keys" >&2
    echo "  go in .env.sh), or use environment = \"dev\" to stay on one cloud." >&2
    exit 1
  fi
fi

echo "▶ Ensuring buckets for ${PROJECT} (${PU}/${ROLE}/${ENVN})"

# State PRIMARY — REQUIRED before `tofu init`. Fatal under set -e.
ensure_bucket "$STATE_PRIMARY" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK"

ensure_bucket "$ARTIFACT_PRIMARY" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK" ||
  echo "  ⚠ ${ARTIFACT_PRIMARY} not ready (will retry at backup time)"

# --- The two shapes, and neither of them silent -------------------------------
#
# A backup store on the SAME provider as the primary survives a deleted bucket.
# It does not survive the provider, which is the only thing it was built for. So
# the configuration must say WHICH of the two shapes was chosen, out loud, before
# anything is created — and if the operator chose the second, it has to be true.
#
# It used to be best-effort with a ⚠ per bucket, in a wall of tofu output: you
# could believe you had a copy on another provider and have nothing at all.
CROSS=no
[ "$REPLICA_EP" != "$PRIMARY_EP" ] && CROSS=yes

REPL_OK=yes
ensure_bucket "${STATE_PRIMARY}-backup"    "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK" "$BACKUP_SK" || REPL_OK=no
ensure_bucket "${ARTIFACT_PRIMARY}-backup" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK" "$BACKUP_SK" || REPL_OK=no

if [ "$CROSS" = no ]; then
  echo "  ~ backup store is the SAME endpoint as the primary (${PRIMARY_EP})"
  echo "    That survives a deleted bucket, not a lost provider. Deliberate for a"
  echo "    single-provider setup; point s3_replica_endpoint elsewhere to change it."
  [ "$REPL_OK" = yes ] || echo "  ⚠ the -backup buckets are not ready"
elif [ "$REPL_OK" = yes ]; then
  echo "  ✓ backup store is a DIFFERENT provider: ${REPLICA_EP}"
  if [ -n "$RPU" ]; then echo "    authenticated with the ${RPU}_* credentials"; fi
else
  echo "✗ s3_replica_endpoint points at another provider (${REPLICA_EP}) and the" >&2
  echo "  -backup buckets could not be created there. Refusing to continue: a copy" >&2
  echo "  you asked for and did not get is worse than no copy at all." >&2
  if [ -z "$BACKUP_AK" ]; then
    echo "  No variable in this shell holds a credential for it." >&2
  else
    echo "  The key it tried came from \$${BACKUP_SRC}, and that endpoint rejected it." >&2
  fi
  echo "  That store needs the credentials of the cloud that HOLDS it. Export" >&2
  if [ -n "$RPU" ]; then
    echo "  either of these pairs — the first is the one you already have if you" >&2
    echo "  also run a ${RPROV} cluster:" >&2
    echo "    ${RPU}_AWS_ACCESS_KEY_ID + ${RPU}_AWS_SECRET_ACCESS_KEY" >&2
    echo "    ${RPU}_BACKUP_AWS_ACCESS_KEY_ID + ${RPU}_BACKUP_AWS_SECRET_ACCESS_KEY" >&2
  else
    echo "  them under this cluster's namespace — the endpoint is not one of the" >&2
    echo "  clouds this repo knows, so it cannot be named for you:" >&2
    echo "    ${PU}_BACKUP_AWS_ACCESS_KEY_ID + ${PU}_BACKUP_AWS_SECRET_ACCESS_KEY" >&2
  fi
  # Prod refuses a replica on the primary's cloud, so that cannot be the advice.
  if [ "$ENVN" = prod ]; then
    echo "  Or, for a NEW cluster that stays on one cloud: environment = \"dev\" with" >&2
    echo "  s3_replica_endpoint = ${PRIMARY_EP} (environment names the state bucket)." >&2
  else
    echo "  Or point s3_replica_endpoint back at ${PRIMARY_EP} to keep one cloud." >&2
  fi
  exit 1
fi

echo "✓ buckets ready"
