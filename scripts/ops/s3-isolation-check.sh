#!/usr/bin/env bash
# Which S3 identity can reach which bucket, and what the buckets themselves are set to. Run it from the operator's machine
# with the pairs you seeded in the environment; it needs no cluster, only the stores.
#
#   source .env.sh && OA_LOKI_S3_ACCESS_KEY_ID=... scripts/ops/s3-isolation-check.sh <cluster.tfvars>
#
# Identities (a pair is skipped when its variables are unset): the operator's keys on each store, OA_LOKI_S3_*,
# OA_BACKUP_S3_* (primary backups bucket), OA_BACKUP_REPLICA_S3_* (its -backup twin). Probes, all harmless:
#   list    ListObjectsV2, one key: may this identity read the bucket at all?
#   delver  DeleteObjectVersion on a version that does not exist: refused with AccessDenied = the policy withholds it
#           (anything else = the store was willing to look, so a real version would go). Nothing is ever deleted.
# Expected: a dedicated pair lists its own bucket and nothing else; with backup_immutability not off it may not call
# DeleteObjectVersion on it (OA_EXPECT_NO_VERSION_DELETE=0/1 overrides). The operator's keys are listed for contrast and
# never asserted. A bucket that does not exist is skipped, not counted as "denied".
#
# Exit: 0 every assertion held; 1 one did not (or a key was not accepted at all); 2 no dedicated pair in scope, so
# there is nothing to assert (the cluster is running on the operator's keys).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/bucket-protection.sh"

TFVARS="${1:?usage: s3-isolation-check.sh <cluster.tfvars>}"
[ -f "$TFVARS" ] || { echo "✗ tfvars not found: $TFVARS" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq required" >&2; exit 1; }
oa_aws_compat

CLUSTER="$(tfv "$TFVARS" cluster_name)"; ROLE="$(tfv "$TFVARS" cluster_role)"; ENVN="$(tfv "$TFVARS" environment)"
PRIMARY_EP="$(tfv "$TFVARS" s3_primary_endpoint)"; PRIMARY_REGION="$(tfv "$TFVARS" s3_primary_region)"
REPLICA_EP="$(tfv "$TFVARS" s3_replica_endpoint)"; REPLICA_REGION="$(tfv "$TFVARS" s3_replica_region)"
PROVIDER="$(tfv_provider "$TFVARS")"
[ -n "$CLUSTER" ] && [ -n "$ROLE" ] && [ -n "$ENVN" ] && [ -n "$PRIMARY_EP" ] || { echo "✗ cluster_name, cluster_role, environment and s3_primary_endpoint are required in $TFVARS" >&2; exit 1; }
[ -n "$REPLICA_EP" ] || { REPLICA_EP="$PRIMARY_EP"; REPLICA_REGION="$PRIMARY_REGION"; }
IMMUT="$(oa_immutability "$TFVARS")"; RETENTION="$(oa_retention_days "$TFVARS")"
EXPECT_NOVD="${OA_EXPECT_NO_VERSION_DELETE:-$([ "$IMMUT" = off ] && echo 0 || echo 1)}"

PROJECT="$(oa_project "$CLUSTER" "$(tfv "$TFVARS" bucket_suffix)")"
STATE="$(oa_state_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
ARTIFACT="$(oa_artifact_bucket "$PROJECT" "$PROVIDER" "$ROLE" "$ENVN")"
BACKUPS="$(oa_backup_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
LOGS="$(oa_logs_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
# bucket|which store (p primary, r replica)|kind (lock = holds copies or logs)
BUCKETS=("$STATE|p|nolock" "$ARTIFACT|p|nolock" "$BACKUPS|p|lock" "$LOGS|p|lock"
         "$STATE-backup|r|lock" "$ARTIFACT-backup|r|lock" "$BACKUPS-backup|r|lock")

OPAK="$(s3_cred "$PROVIDER" primary ak)"; OPSK="$(s3_cred "$PROVIDER" primary sk)"
RPAK="$(s3_cred "$PROVIDER" backup ak "$REPLICA_EP")"; RPSK="$(s3_cred "$PROVIDER" backup sk "$REPLICA_EP")"
[ -n "$OPAK" ] || { echo "✗ no S3 credentials for '$PROVIDER' in this shell (source .env.sh)" >&2; exit 1; }

FAILS=0; ASSERTED=0
ep_of() { [ "$1" = p ] && printf '%s' "$PRIMARY_EP" || printf '%s' "$REPLICA_EP"; }
rg_of() { [ "$1" = p ] && printf '%s' "$PRIMARY_REGION" || printf '%s' "$REPLICA_REGION"; }

# probe <ak> <sk> <store p|r> <list|delver> <bucket> -> allowed | denied | absent | error:<text>
probe() {
  local ak="$1" sk="$2" st="$3" what="$4" b="$5" out rc=0
  if [ "$what" = list ]; then
    out="$(_oa_s3api "$ak" "$sk" "$(ep_of "$st")" "$(rg_of "$st")" list-objects-v2 --bucket "$b" --max-keys 1 2>&1)" || rc=$?
  else
    out="$(_oa_s3api "$ak" "$sk" "$(ep_of "$st")" "$(rg_of "$st")" delete-object-version --bucket "$b" \
            --key oa-isolation-probe --version-id oa-isolation-probe-no-such-version 2>&1)" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then echo allowed
  elif grep -qiE 'InvalidAccessKeyId|SignatureDoesNotMatch|AuthFailure|InvalidToken' <<<"$out"; then echo "error:the store does not accept this key"
  elif grep -qiE 'AccessDenied|Forbidden|\(403\)' <<<"$out"; then echo denied
  elif grep -qiE 'NoSuchBucket|\(404\).*(Not Found)' <<<"$out" && ! grep -qi 'NoSuchVersion\|NoSuchKey' <<<"$out"; then echo absent
  elif [ "$what" = delver ] && grep -qiE 'NoSuchVersion|NoSuchKey|InvalidArgument|InvalidVersion' <<<"$out"; then echo allowed
  else echo "error:$(_oa_first_line "$out")"; fi
}

report() { # <label> <expected> <observed> <asserted 0|1>
  local mark="·" extra=""
  if [ "$4" = 1 ]; then
    ASSERTED=$((ASSERTED + 1))
    if [ "$2" = "$3" ]; then mark="✓"; else mark="✗"; FAILS=$((FAILS + 1)); fi
  fi
  case "$3" in error:*) extra=" (${3#error:})" ;; esac
  printf '  %s %-34s expected %-7s observed %s%s\n' "$mark" "$1" "$2" "${3%%:*}" "$extra"
}

DEDICATED=0
check_identity() { # <name> <ak> <sk> <store p|r> <own bucket> <asserted 1|0> — dedicated pairs are asserted, operator keys are not
  local name="$1" ak="$2" sk="$3" st="$4" own="$5" asserted="$6" row b bs kind exp obs
  echo "▶ $name ($([ "$st" = p ] && echo "primary store" || echo "replica store"))"
  for row in "${BUCKETS[@]}"; do
    IFS='|' read -r b bs kind <<<"$row"
    # a store holds the buckets that live on its endpoint; on one provider both sets are on it
    [ "$bs" = "$st" ] || [ "$PRIMARY_EP" = "$REPLICA_EP" ] || continue
    obs="$(probe "$ak" "$sk" "$st" list "$b")"
    # An absent bucket proves nothing about access; for the identity's OWN bucket it is a failure, reported below.
    if [ "$obs" = absent ] && [ "$b" != "$own" ]; then printf '  · %-34s bucket does not exist, skipped\n' "$b list"; continue; fi
    exp=denied; if [ "$asserted" = 0 ] || [ "$b" = "$own" ]; then exp=allowed; fi
    report "$b list" "$exp" "$obs" "$asserted"
    if [ "$asserted" = 1 ] && [ "$b" = "$own" ]; then
      obs="$(probe "$ak" "$sk" "$st" delver "$b")"
      report "$b delete-version" denied "$obs" "$EXPECT_NOVD"
    fi
  done
}

echo "▶ Buckets as the operator's keys read them (backup_immutability = ${IMMUT}, ${RETENTION} days)"
PROT_BAD=0
for row in "${BUCKETS[@]}"; do
  IFS='|' read -r b bs kind <<<"$row"
  if [ "$bs" = p ]; then ak="$OPAK"; sk="$OPSK"; else ak="$RPAK"; sk="$RPSK"; fi
  if ! _oa_s3api "$ak" "$sk" "$(ep_of "$bs")" "$(rg_of "$bs")" head-bucket --bucket "$b" >/dev/null 2>&1; then
    printf '  · %s: not there\n' "$b"; continue
  fi
  st="$(oa_protection_state "$b" "$(ep_of "$bs")" "$(rg_of "$bs")" "$ak" "$sk")"
  if [ "$IMMUT" = off ]; then printf '  · %s [%s]\n' "$b" "$st"; continue; fi
  want=""
  case "$st" in *"versioning=Enabled"*) ;; *) want="versioning missing; " ;; esac
  case "$st" in *"noncurrent_days=$RETENTION "*) ;; *) want+="expiry of old versions missing; " ;; esac
  case "$IMMUT:$kind" in
    governance:lock | compliance:lock)
      case "$st" in *"lock=$(tr '[:lower:]' '[:upper:]' <<<"$IMMUT"):$RETENTION") ;; *) want+="object lock missing; " ;; esac ;;
  esac
  [ -z "$want" ] || PROT_BAD=$((PROT_BAD + 1))
  printf '  %s %s [%s]%s\n' "$([ -z "$want" ] && echo ✓ || echo ✗)" "$b" "$st" "${want:+ - ${want%; }}"
done
FAILS=$((FAILS + PROT_BAD))

echo "▶ The operator's keys, for contrast (not asserted)"
check_identity "operator, primary store" "$OPAK" "$OPSK" p "" 0
if [ "$PRIMARY_EP" != "$REPLICA_EP" ] && [ -n "$RPAK" ]; then check_identity "operator, replica store" "$RPAK" "$RPSK" r "" 0; fi

add_pair() { # <label> <ak var> <sk var> <store> <own bucket>
  local ak="${!2:-}" sk="${!3:-}"
  if [ -z "$ak" ] && [ -z "$sk" ]; then echo "· $1: $2 not set, not checked"; return 0; fi
  [ -n "$ak" ] && [ -n "$sk" ] || { echo "✗ $2 and $3 go together" >&2; FAILS=$((FAILS + 1)); return 0; }
  DEDICATED=$((DEDICATED + 1))
  check_identity "$1" "$ak" "$sk" "$4" "$5" 1
}
add_pair "Loki" OA_LOKI_S3_ACCESS_KEY_ID OA_LOKI_S3_SECRET_ACCESS_KEY p "$LOGS"
add_pair "backups (primary)" OA_BACKUP_S3_ACCESS_KEY_ID OA_BACKUP_S3_SECRET_ACCESS_KEY p "$BACKUPS"
add_pair "backups (replica)" OA_BACKUP_REPLICA_S3_ACCESS_KEY_ID OA_BACKUP_REPLICA_S3_SECRET_ACCESS_KEY r "$BACKUPS-backup"

echo
if [ "$DEDICATED" -eq 0 ]; then
  echo "⚠ No dedicated pair in scope (OA_LOKI_S3_*, OA_BACKUP_S3_*, OA_BACKUP_REPLICA_S3_*): the cluster, seeded without them, runs on the operator's keys and nothing is isolated."
  [ "$FAILS" -eq 0 ] || { echo "✗ $FAILS problem(s) above (a half pair, or a bucket setting that differs from backup_immutability)"; exit 1; }
  exit 2
fi
if [ "$FAILS" -gt 0 ]; then echo "✗ $FAILS of $((ASSERTED + PROT_BAD)) assertion(s) did not hold"; exit 1; fi
echo "✓ $ASSERTED assertion(s) held"
