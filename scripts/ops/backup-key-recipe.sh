#!/usr/bin/env bash
# Prints what a DEDICATED S3 key pair of this cluster needs, with the real bucket names and no identifier: the bucket policy of
# the pair's own bucket, the operator-only policy for every OTHER bucket of the project, and the rights the pair must hold.
# It creates nothing and calls no provider. The principal is yours to give (PAIR_PRINCIPAL, OPERATOR_PRINCIPAL), else a
# placeholder is printed. Infra #368: the replica pair had no recipe; docs/backup-policy.md, section 4, says how to use it.
#
#   scripts/ops/backup-key-recipe.sh <cluster.tfvars> <primary|replica|loki|audit-sink|audit-sink-secondary>
#
# primary  backup/s3-primary  -> s3-<project>-<provider>-backups-<env>            (restic, Barman, Longhorn)
# replica  backup/s3-replica  -> <that bucket>-backup, on the replica store       (restic, the CNPG archive copy, etcd, the verifier)
# loki     observability/loki-s3 -> s3-<project>-<provider>-logs-<env>
# audit-sink            audit/sink           -> s3-<project>-<provider>-audit-<env> on the first audit sink's store (infra #318, docs/audit-sink.md)
# audit-sink-secondary  audit/sink-secondary -> the same name on the second sink's store (audit_sink_placement = both)
#                       The sink pair gets NO delete right at all (restic runs with --no-lock; the bucket is object-locked).
# Policy shapes: Scaleway (bucket policy version 2023-04-17, principal {"SCW": "application_id:<id>"}) is the measured one;
# Outscale uses an AWS-style principal and is an expectation (the store refused dedicated keys in lab 15B, infra #377); OVH's
# S3 API has no bucket policy, so only the rights are printed and the user's policy goes through the OVH API (not verified).
# Exit 0 printed; 2 usage.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/audit-sink.sh"
USAGE="usage: backup-key-recipe.sh <cluster.tfvars> <primary|replica|loki|audit-sink|audit-sink-secondary>"
TFVARS="${1:?$USAGE}"; KIND="${2:?$USAGE}"
[ -f "$TFVARS" ] || { echo "✗ tfvars not found: $TFVARS" >&2; exit 2; }
case "$KIND" in primary | replica | loki | audit-sink | audit-sink-secondary) ;; *) echo "✗ kind must be primary, replica, loki, audit-sink or audit-sink-secondary" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "✗ jq required" >&2; exit 2; }

CLUSTER="$(tfv "$TFVARS" cluster_name)"; ROLE="$(tfv "$TFVARS" cluster_role)"; ENVN="$(tfv "$TFVARS" environment)"
PROVIDER="$(tfv_provider "$TFVARS")"
STORE_PROVIDER="$PROVIDER"   # who HOLDS the bucket: the replica pair lives on the replica store, which may be another cloud (lab 19: OVH)
if [ "$KIND" = replica ]; then rp="$(provider_of_endpoint "$(tfv "$TFVARS" s3_replica_endpoint)")"; [ -z "$rp" ] || STORE_PROVIDER="$rp"; fi
SINK_EP=""
case "$KIND" in audit-sink | audit-sink-secondary)
  oa_audit_sink_load "$TFVARS" || exit 2
  [ "$AS_PLACEMENT" != off ] || { echo "✗ audit_sink_placement is off in $TFVARS: there is no sink to make a key for" >&2; exit 2; }
  if [ "$KIND" = audit-sink ]; then SINK_EP="$AS_EP1"; else SINK_EP="$AS_EP2"; fi
  [ -n "$SINK_EP" ] || { echo "✗ $KIND: this tfvars has no such sink (audit_sink_placement = $AS_PLACEMENT)" >&2; exit 2; }
  STORE_PROVIDER="$(provider_of_endpoint "$SINK_EP")"; STORE_PROVIDER="${STORE_PROVIDER:-$PROVIDER}" ;; esac
PROJECT="$(oa_project "$CLUSTER" "$(tfv "$TFVARS" bucket_suffix)")"
STATE="$(oa_state_bucket "$PROJECT" "$PROVIDER" "$ENVN")"; ARTIFACT="$(oa_artifact_bucket "$PROJECT" "$PROVIDER" "$ROLE" "$ENVN")"
BACKUPS="$(oa_backup_bucket "$PROJECT" "$PROVIDER" "$ENVN")"; LOGS="$(oa_logs_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
AUDIT="$(oa_audit_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
case "$KIND" in primary) OWN="$BACKUPS"; OTHERS=("$STATE" "$ARTIFACT" "$LOGS") ;;
                replica) OWN="$BACKUPS-backup"; OTHERS=("$STATE-backup" "$ARTIFACT-backup") ;;
                loki)    OWN="$LOGS"; OTHERS=("$STATE" "$ARTIFACT" "$BACKUPS") ;;
                # The sink's own bucket, and the buckets of this cluster that sit on the SAME store (an account's other buckets are open
                # to a key pair without a policy on Scaleway): the primary ones when the sink is the cluster's provider, the -backup
                # ones when the replica store is the sink's provider.
                audit-sink*) OWN="$AUDIT"; OTHERS=()
                  [ "$STORE_PROVIDER" != "$PROVIDER" ] || OTHERS+=("$STATE" "$ARTIFACT" "$BACKUPS" "$LOGS")
                  [ "$(provider_of_endpoint "$(tfv "$TFVARS" s3_replica_endpoint)")" != "$STORE_PROVIDER" ] || OTHERS+=("$STATE-backup" "$ARTIFACT-backup" "$BACKUPS-backup") ;; esac
PAIR="${PAIR_PRINCIPAL:-<principal of the pair>}"; OPER="${OPERATOR_PRINCIPAL:-<principal of the operator>}"
case "$STORE_PROVIDER" in
  scaleway) principal() { jq -cn --arg p "$1" '{SCW: ("application_id:" + $p)}'; }; opprincipal() { jq -cn --arg p "$1" '{SCW: ("user_id:" + $p)}'; } ;;
  *)        principal() { jq -cn --arg p "$1" '{AWS: $p}'; }; opprincipal() { principal "$1"; } ;;
esac

OBJ_ACTIONS='["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]'
echo "# ${KIND} pair for ${STORE_PROVIDER} (bucket ${OWN})"
echo
echo "## Rights the pair must hold on ${OWN} (nothing else; apps/base/backup/README.md, 'S3 rights of a dedicated key pair')"
echo "  bucket:  s3:ListBucket (it is also HeadBucket), s3:GetBucketLocation, s3:ListBucketMultipartUploads"
case "$KIND" in
  audit-sink*)
    OBJ_ACTIONS='["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]'
    echo "  objects: s3:GetObject, s3:PutObject, s3:AbortMultipartUpload, s3:ListMultipartUploadParts   (NO delete of any kind: the shipper writes with"
    echo "           restic --no-lock, so it never deletes a lock object, and the bucket is object-locked: docs/audit-sink.md, section 4)"
    echo "  withheld: s3:DeleteObject, s3:DeleteObjectVersion, versioning, lifecycle, object-lock and retention changes, bucket deletion, every other bucket" ;;
  *)
    echo "  objects: s3:GetObject, s3:PutObject (with the AES256 server-side-encryption request), s3:DeleteObject,"
    echo "           s3:AbortMultipartUpload, s3:ListMultipartUploadParts"
    echo "  withheld: s3:DeleteObjectVersion, versioning, lifecycle, object-lock and retention changes, bucket deletion, every other bucket" ;;
esac
[ "$STORE_PROVIDER" != scaleway ] || echo "  Scaleway IAM (project-wide sets): ObjectStorageBucketsRead + ObjectStorageObjectsRead/Write/Delete on the application; the bucket policies isolate"
[ "$STORE_PROVIDER" != ovh ] || echo "  OVH: no bucket policy through the S3 API; give the S3 user the same rights through the OVH API (not verified)"
case "$KIND" in audit-sink*) [ "$STORE_PROVIDER" != ovh ] || {
  echo "  OVH: the key pair of an OVH S3 user CANNOT be isolated per bucket (no bucket policies): it reaches every bucket of that OVH project."
  echo "       Give the sink its own OVH project and S3 user, so that the only bucket the pair can reach is this one." ; } ;; esac
if [ "$STORE_PROVIDER" != ovh ]; then
  echo
  echo "## Bucket policy of ${OWN} (apply with the operator's keys: aws s3api put-bucket-policy --bucket ${OWN} --policy file://policy.json)"
  jq -n --arg b "$OWN" --argjson objact "$OBJ_ACTIONS" --argjson pp "$(principal "$PAIR")" --argjson op "$(opprincipal "$OPER")" '{
    Version: "2023-04-17", Id: ("oa-" + $b),
    Statement: [
      {Sid: "operator", Effect: "Allow", Principal: $op, Action: "s3:*", Resource: [$b, ($b + "/*")]},
      {Sid: "pair-bucket", Effect: "Allow", Principal: $pp, Action: ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"], Resource: $b},
      {Sid: "pair-objects", Effect: "Allow", Principal: $pp,
       Action: $objact, Resource: ($b + "/*")}]}'
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
case "$KIND" in
  audit-sink*)
    SEEDVAR=OA_AUDIT_SINK_S3; [ "$KIND" = audit-sink ] || SEEDVAR=OA_AUDIT_SINK_SECONDARY_S3
    echo "  ${SEEDVAR}_ACCESS_KEY_ID=<ak> ${SEEDVAR}_SECRET_ACCESS_KEY=<sk> scripts/ops/seed-openbao.sh ...   (the seed writes secret/audit/sink)"
    echo "  then the delivery and integrity proof: scripts/ops/audit-sink-check.sh ${TFVARS}" ;;
  *)
echo "  OA_BACKUP_$([ "$KIND" = replica ] && echo REPLICA_)S3_ACCESS_KEY_ID=<ak> OA_BACKUP_$([ "$KIND" = replica ] && echo REPLICA_)S3_SECRET_ACCESS_KEY=<sk> OA_ISOLATION_REAL_VERSION=1 scripts/ops/s3-isolation-check.sh ${TFVARS}" ;;
esac
