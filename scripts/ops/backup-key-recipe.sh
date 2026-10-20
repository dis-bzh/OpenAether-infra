#!/usr/bin/env bash
# Prints what a DEDICATED S3 key pair of this cluster needs, with the real bucket names and no identifier: the bucket policy of
# the pair's own bucket, the operator-only policy for every OTHER bucket of the project, and the rights the pair must hold.
# It creates nothing and calls no provider. The principal is yours to give (PAIR_PRINCIPAL, OPERATOR_PRINCIPAL), else a
# placeholder is printed. Infra #368: the replica pair had no recipe; docs/backup-policy.md, section 4, says how to use it.
#
#   scripts/ops/backup-key-recipe.sh <cluster.tfvars> <primary|replica|loki>
#
# primary  backup/s3-primary  -> s3-<project>-<provider>-backups-<env>            (restic, Barman, Longhorn)
# replica  backup/s3-replica  -> <that bucket>-backup, on the replica store       (restic, the CNPG archive copy, etcd, the verifier)
# loki     observability/loki-s3 -> s3-<project>-<provider>-logs-<env>
# Policy shapes: Scaleway (bucket policy version 2023-04-17, principal {"SCW": "application_id:<id>"}) is the measured one;
# Outscale uses an AWS-style principal and is an expectation (the store refused dedicated keys in lab 15B, infra #377); OVH's
# S3 API has no bucket policy, so only the rights are printed and the user's policy goes through the OVH API (not verified).
# Exit 0 printed; 2 usage.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
TFVARS="${1:?usage: backup-key-recipe.sh <cluster.tfvars> <primary|replica|loki>}"; KIND="${2:?usage: backup-key-recipe.sh <cluster.tfvars> <primary|replica|loki>}"
[ -f "$TFVARS" ] || { echo "✗ tfvars not found: $TFVARS" >&2; exit 2; }
case "$KIND" in primary | replica | loki) ;; *) echo "✗ kind must be primary, replica or loki" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "✗ jq required" >&2; exit 2; }

CLUSTER="$(tfv "$TFVARS" cluster_name)"; ROLE="$(tfv "$TFVARS" cluster_role)"; ENVN="$(tfv "$TFVARS" environment)"
PROVIDER="$(tfv_provider "$TFVARS")"
STORE_PROVIDER="$PROVIDER"   # who HOLDS the bucket: the replica pair lives on the replica store, which may be another cloud (lab 19: OVH)
if [ "$KIND" = replica ]; then rp="$(provider_of_endpoint "$(tfv "$TFVARS" s3_replica_endpoint)")"; [ -z "$rp" ] || STORE_PROVIDER="$rp"; fi
PROJECT="$(oa_project "$CLUSTER" "$(tfv "$TFVARS" bucket_suffix)")"
STATE="$(oa_state_bucket "$PROJECT" "$PROVIDER" "$ENVN")"; ARTIFACT="$(oa_artifact_bucket "$PROJECT" "$PROVIDER" "$ROLE" "$ENVN")"
BACKUPS="$(oa_backup_bucket "$PROJECT" "$PROVIDER" "$ENVN")"; LOGS="$(oa_logs_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
case "$KIND" in primary) OWN="$BACKUPS"; OTHERS=("$STATE" "$ARTIFACT" "$LOGS") ;;
                replica) OWN="$BACKUPS-backup"; OTHERS=("$STATE-backup" "$ARTIFACT-backup") ;;
                loki)    OWN="$LOGS"; OTHERS=("$STATE" "$ARTIFACT" "$BACKUPS") ;; esac
PAIR="${PAIR_PRINCIPAL:-<principal of the pair>}"; OPER="${OPERATOR_PRINCIPAL:-<principal of the operator>}"
case "$STORE_PROVIDER" in
  scaleway) principal() { jq -cn --arg p "$1" '{SCW: ("application_id:" + $p)}'; }; opprincipal() { jq -cn --arg p "$1" '{SCW: ("user_id:" + $p)}'; } ;;
  *)        principal() { jq -cn --arg p "$1" '{AWS: $p}'; }; opprincipal() { principal "$1"; } ;;
esac

echo "# ${KIND} pair for ${STORE_PROVIDER} (bucket ${OWN})"
echo
echo "## Rights the pair must hold on ${OWN} (nothing else; apps/base/backup/README.md, 'S3 rights of a dedicated key pair')"
echo "  bucket:  s3:ListBucket (it is also HeadBucket), s3:GetBucketLocation, s3:ListBucketMultipartUploads"
echo "  objects: s3:GetObject, s3:PutObject (with the AES256 server-side-encryption request), s3:DeleteObject,"
echo "           s3:AbortMultipartUpload, s3:ListMultipartUploadParts"
echo "  withheld: s3:DeleteObjectVersion, versioning, lifecycle, object-lock and retention changes, bucket deletion, every other bucket"
[ "$STORE_PROVIDER" != scaleway ] || echo "  Scaleway IAM (project-wide sets): ObjectStorageBucketsRead + ObjectStorageObjectsRead/Write/Delete on the application; the bucket policies isolate"
[ "$STORE_PROVIDER" != ovh ] || echo "  OVH: no bucket policy through the S3 API; give the S3 user the same rights through the OVH API (not verified)"
if [ "$STORE_PROVIDER" != ovh ]; then
  echo
  echo "## Bucket policy of ${OWN} (apply with the operator's keys: aws s3api put-bucket-policy --bucket ${OWN} --policy file://policy.json)"
  jq -n --arg b "$OWN" --argjson pp "$(principal "$PAIR")" --argjson op "$(opprincipal "$OPER")" '{
    Version: "2023-04-17", Id: ("oa-" + $b),
    Statement: [
      {Sid: "operator", Effect: "Allow", Principal: $op, Action: "s3:*", Resource: [$b, ($b + "/*")]},
      {Sid: "pair-bucket", Effect: "Allow", Principal: $pp, Action: ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"], Resource: $b},
      {Sid: "pair-objects", Effect: "Allow", Principal: $pp,
       Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource: ($b + "/*")}]}'
  for b in "${OTHERS[@]}"; do
    echo
    echo "## Operator-only policy of ${b} (the pair must not open it; a bucket WITHOUT a policy is open to the pair on Scaleway)"
    jq -n --arg b "$b" --argjson op "$(opprincipal "$OPER")" '{
      Version: "2023-04-17", Id: ("oa-" + $b),
      Statement: [{Sid: "operator-only", Effect: "Allow", Principal: $op, Action: "s3:*", Resource: [$b, ($b + "/*")]}]}'
  done
fi
echo
echo "## Then prove it, before and after seeding"
echo "  S3_ENDPOINT=<endpoint> S3_BUCKET=${OWN} AWS_ACCESS_KEY_ID=<ak> AWS_SECRET_ACCESS_KEY=<sk> OpenAether-apps/scripts/ops/check-backup-key-rights.sh"
echo "  OA_BACKUP_$([ "$KIND" = replica ] && echo REPLICA_)S3_ACCESS_KEY_ID=<ak> OA_BACKUP_$([ "$KIND" = replica ] && echo REPLICA_)S3_SECRET_ACCESS_KEY=<sk> OA_ISOLATION_REAL_VERSION=1 scripts/ops/s3-isolation-check.sh ${TFVARS}"
