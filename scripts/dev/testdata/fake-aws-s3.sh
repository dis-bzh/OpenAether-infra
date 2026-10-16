#!/usr/bin/env bash
# A stand-in for `aws` that behaves like an S3 store with versioning, lifecycle and object lock, for the offline tests of
# ensure-buckets.sh and s3-isolation-check.sh. State is files under $FAKE_S3:
#   buckets/<name>/{lock_enabled,versioning,lifecycle.json,lock.json}   the bucket and what was set on it
#   id/<ACCESS_KEY>   no file = full access; else lines: "bucket <name>" (the only buckets it may touch),
#                     "no-version-delete" (DeleteObjectVersion refused), "invalid" (the store does not know the key)
#   refuse/<op> or refuse/<op>.<bucket>   the error text this call answers with (the provider "not supporting" it)
#   ignore/<op>       the call is accepted and does nothing (a store that says yes and means no)
#   calls.log         "<access key> <operation> <bucket>" per request
# It models only what those scripts ask for, and the one rule that matters: object lock is refused on a bucket that was
# not created with it.
set -u
: "${FAKE_S3:?FAKE_S3 is the state directory}"
ak="${AWS_ACCESS_KEY_ID:-}"
[ "${1:-}" = s3 ] || [ "${1:-}" = s3api ] || { echo "fake aws: unsupported $*" >&2; exit 2; }
kind="$1"; shift
if [ "$kind" = s3 ]; then
  [ "$1" = mb ] || { echo "fake aws: unsupported s3 $*" >&2; exit 2; }
  op=create-bucket; bucket="${2#s3://}"; shift 2
else
  op="$1"; shift; bucket=""
fi
cfg="" key="" vid="" lockflag=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --versioning-configuration) cfg="$2"; shift 2 ;;
    --lifecycle-configuration | --object-lock-configuration) cfg="$2"; shift 2 ;;
    --create-bucket-configuration) shift 2 ;;
    # aws CLI v2: a blob parameter must be a path to a regular file (`--body /dev/null` is refused; found by lab 12)
    --body) if [ ! -f "$2" ]; then echo "aws: [ERROR]: An error occurred (ParamValidation): Error parsing parameter '--body': Blob values must be a path to a file." >&2; exit 252; fi; shift 2 ;;
    --object-lock-enabled-for-bucket) lockflag=1; shift ;;
    --key) key="$2"; shift 2 ;;
    --version-id) vid="$2"; shift 2 ;;
    --max-keys | --endpoint-url | --region | --output | --prefix | --query) shift 2 ;;
    *) shift ;;
  esac
done
echo "$ak $op $bucket" >>"$FAKE_S3/calls.log"
B="$FAKE_S3/buckets/$bucket"
fail() { echo "An error occurred ($1) when calling the ${op} operation: ${2:-}" >&2; exit 254; }

if [ -f "$FAKE_S3/refuse/$op.$bucket" ]; then fail Refused "$(cat "$FAKE_S3/refuse/$op.$bucket")"; fi
if [ -f "$FAKE_S3/refuse/$op" ]; then fail NotImplemented "$(cat "$FAKE_S3/refuse/$op")"; fi
if [ -f "$FAKE_S3/ignore/$op" ] && [ -d "$B" ]; then exit 0; fi
if [ -f "$FAKE_S3/id/$ak" ]; then
  grep -qx invalid "$FAKE_S3/id/$ak" && fail InvalidAccessKeyId "The access key does not exist"
  if [ -d "$B" ]; then
    grep -qx "bucket $bucket" "$FAKE_S3/id/$ak" || fail AccessDenied "Access Denied"
    if [ "$op" = delete-object ] && [ -n "$vid" ] && grep -qx no-version-delete "$FAKE_S3/id/$ak"; then fail AccessDenied "Access Denied"; fi
  fi
fi

case "$op" in
  head-bucket) [ -d "$B" ] || { echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2; exit 254; }
               exit 0 ;;
  create-bucket)
    if [ -d "$B" ]; then fail BucketAlreadyOwnedByYou "exists"; fi
    mkdir -p "$B"; [ "$lockflag" = 1 ] && touch "$B/lock_enabled"; exit 0 ;;
  head-object) exit 254 ;;
esac
[ -d "$B" ] || fail NoSuchBucket "The specified bucket does not exist"
case "$op" in
  put-bucket-versioning) printf '%s' "${cfg#Status=}" >"$B/versioning" ;;
  get-bucket-versioning) if [ -s "$B/versioning" ]; then jq -nc --arg s "$(cat "$B/versioning")" '{Status:$s}'; else echo '{}'; fi ;;
  put-bucket-lifecycle-configuration) printf '%s' "$cfg" >"$B/lifecycle.json" ;;
  get-bucket-lifecycle-configuration)
    [ -s "$B/lifecycle.json" ] && cat "$B/lifecycle.json" || fail NoSuchLifecycleConfiguration "The lifecycle configuration does not exist" ;;
  put-object-lock-configuration)
    [ -f "$B/lock_enabled" ] || fail InvalidBucketState "Bucket is missing Object Lock Configuration"
    printf '%s' "$cfg" >"$B/lock.json" ;;
  get-object-lock-configuration)
    [ -f "$B/lock_enabled" ] || fail ObjectLockConfigurationNotFoundError "Object Lock configuration does not exist for this bucket"
    if [ -s "$B/lock.json" ]; then jq -c '{ObjectLockConfiguration: .}' "$B/lock.json"
    else echo '{"ObjectLockConfiguration":{"ObjectLockEnabled":"Enabled"}}'; fi ;;
  list-objects-v2) echo '{}' ;;
  # The real CLI has no `delete-object-version`: it exits 252 with this message (a probe that used it passed its test here and
  # failed on Scaleway, 2026-10-16). A version is deleted with `delete-object --version-id`, and a store that allows it answers
  # success for a version that does not exist; a non-numeric id is refused as InvalidArgument (Scaleway).
  delete-object-version) echo "aws: [ERROR]: argument operation: Invalid choice, valid choices are: delete-object, delete-objects" >&2; exit 252 ;;
  delete-object) [ -n "$key" ] && [ -n "$vid" ] || fail InvalidArgument "key and version id are required"
                 case "$vid" in *[!0-9]*) fail InvalidArgument "Invalid version id specified" ;; esac
                 # strict-vid: like Scaleway, only a version id the store issued is well formed
                 if [ -f "$FAKE_S3/strict-vid" ] && [ "$vid" != "$(cat "$FAKE_S3/last-vid" 2>/dev/null)" ]; then fail InvalidArgument "Invalid version id specified"; fi
                 echo "{\"VersionId\": \"$vid\"}" ;;
  put-object) echo 1234567890123456 >"$FAKE_S3/last-vid"; echo '{"VersionId": "1234567890123456"}' ;;
  *) echo "fake aws: unsupported operation $op" >&2; exit 2 ;;
esac
exit 0
