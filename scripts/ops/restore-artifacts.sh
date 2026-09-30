#!/usr/bin/env bash
# ==============================================================================
# OpenAether — restore cluster access from the encrypted backups.
#
# The inverse of backup-artifacts.sh, and the half that did not exist. Until
# 2026-08-17 this repository could encrypt a kubeconfig and a talosconfig to two
# object stores and had NO way to read them back — no script, no documented
# command, and the nearest thing stood up a brand new cluster
# rather than recovering access to the one you have. A backup nobody has ever
# restored is a hypothesis, not a backup.
#
# What it recovers: the ability to TALK to an existing cluster. It does not
# rebuild anything and it touches no infrastructure.
#
# WHY --from replica MATTERS. The primary store lives on the cluster's own
# provider. The scenario this exists for is that provider being unreachable, so
# the replica — in production a DIFFERENT provider — is the copy that answers.
# `--from replica` reads it with the BACKUP credentials, which is the only way
# a cross-provider copy can be read at all.
#
# Usage:
#   restore-artifacts.sh <provider> [--role management] [--from primary|replica]
#                        [--out <dir>] [--force]
#
# Needs: TF_VAR_encryption_passphrase (the SAME one that wrote them — nothing
# else can decrypt), and the S3 credentials for the store being read.
# ==============================================================================
set -euo pipefail

PROVIDER="${1:?usage: restore-artifacts.sh <provider> [--role management] [--from primary|replica] [--out DIR] [--force]}"
shift
ROLE=management
FROM=primary
OUT=""
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$FROM" in primary | replica) ;; *) echo "✗ --from must be primary or replica" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
TFVARS="${OA_ENVS_DIR:-$CLUSTER_DIR/envs}/${ROLE}-${PROVIDER}.tfvars"   # OA_ENVS_DIR: a test sandbox
OUT="${OUT:-$CLUSTER_DIR}"

# FIRST, before the tools and before the tfvars. It is the only thing that cannot
# be obtained any other way: without it these objects are noise, whatever else is
# in place. Checking it after the download would also turn a missing key into
# what looks like a corrupt backup — gpg reports a checksum error either way.
#
# The order is not cosmetic. It first sat below the tfvars check, so on a machine
# with no cluster configured the script refused for a different reason, and
# test-restore.sh — which asserts THIS refusal — passed only where a real tfvars
# happened to exist. It passed here and failed in CI.
PASSPHRASE="${TF_VAR_encryption_passphrase:-}"
[ -n "$PASSPHRASE" ] || {
  echo "✗ TF_VAR_encryption_passphrase is not set." >&2
  echo "  It is the ONLY thing that can decrypt these objects; there is no recovery without it." >&2
  exit 1
}

command -v gpg >/dev/null 2>&1 || { echo "✗ gpg is required to decrypt" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "✗ the aws CLI is required to fetch" >&2; exit 1; }
[ -f "$TFVARS" ] || { echo "✗ no $TFVARS — the bucket name is derived from it" >&2; exit 1; }

tfv() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)".*/\1/'; }
CN="$(tfv cluster_name)"; ENVN="$(tfv environment)"
PRIM_EP="$(tfv s3_primary_endpoint)"; PRIM_REGION="$(tfv s3_primary_region)"
REPL_EP="$(tfv s3_replica_endpoint)"; REPL_REGION="$(tfv s3_replica_region)"
[ -n "$CN" ] && [ -n "$ENVN" ] || { echo "✗ could not read cluster_name/environment from ${TFVARS##*/}" >&2; exit 1; }

# Same convention as backup.tf and ensure-buckets.sh — via the shared helper, so
# a change to the naming cannot leave the restore path pointing at the old names.
#
# The SUFFIX is part of that convention and was missing here: this was the only
# one of five oa_project callers passing a single argument, so on any cluster
# deployed with a bucket_suffix the restore looked in s3-<project>-<provider>-…
# while the objects sat in s3-<project>-<suffix>-<provider>-… and reported "not
# found" for a backup that existed. Using the shared helper is not the same as
# using it with the same inputs.
BUCKET="$(oa_artifact_bucket "$(oa_project "$CN" "$(tfv bucket_suffix)")" "$PROVIDER" "$ROLE" "$ENVN")"
if [ "$FROM" = replica ]; then
  BUCKET="${BUCKET}-backup"
  EP="${REPL_EP:-$PRIM_EP}"; REGION="${REPL_REGION:-$PRIM_REGION}"; KIND=backup
else
  EP="$PRIM_EP"; REGION="$PRIM_REGION"; KIND=primary
fi
AK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak "$KIND")"
SK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk "$KIND")"
[ -n "$AK" ] && [ -n "$SK" ] || { echo "✗ no ${KIND} S3 credentials resolved for '${PROVIDER}'" >&2; exit 1; }

echo "▶ Restoring from the ${FROM} store: s3://${BUCKET}/backups/  (${EP})"

WORK="$(mktemp -d)"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
trap 'rm -rf "$WORK" "$GNUPGHOME"' EXIT

# Decrypt, mirroring enc() in backup-artifacts.sh. The passphrase goes over fd 3
# so it never appears in argv, exactly as on the way in.
dec() { # in-file  out-file
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
      --decrypt -o "$2" "$1" 3< <(printf '%s' "$PASSPHRASE")
}

RESTORED=0
for name in talosconfig kubeconfig; do
  if ! AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" \
       aws s3 cp "s3://${BUCKET}/backups/${name}.gpg" "$WORK/${name}.gpg" \
         --endpoint-url "$EP" --region "$REGION" >/dev/null 2>&1; then
    echo "  ✗ ${name}.gpg not found in s3://${BUCKET}/backups/" >&2
    continue
  fi
  if ! dec "$WORK/${name}.gpg" "$WORK/${name}"; then
    echo "  ✗ ${name}.gpg downloaded but would not decrypt — wrong passphrase, or the object is damaged" >&2
    continue
  fi
  # A decrypted file that is empty or is not what it claims to be is a failure,
  # not a success with a small file: gpg exits 0 on an empty payload.
  if [ ! -s "$WORK/${name}" ] || ! grep -qE '^(apiVersion|context|contexts):' "$WORK/${name}"; then
    echo "  ✗ ${name} decrypted to something that is not a ${name}" >&2
    continue
  fi
  DEST="$OUT/${name}"
  if [ -e "$DEST" ] && [ "$FORCE" -ne 1 ]; then
    # Never silently overwrite live credentials: the file on disk may be the only
    # working copy, and this script exists for the case where it is not.
    DEST="${DEST}.restored"
    echo "  ~ $OUT/${name} exists — written to ${DEST##*/} instead (--force to replace)"
  fi
  install -m 0600 "$WORK/${name}" "$DEST"
  echo "  ✓ ${DEST}"
  RESTORED=$((RESTORED + 1))
done

[ "$RESTORED" -eq 2 ] || { echo "✗ restored ${RESTORED}/2 artifacts — this is not a successful restore" >&2; exit 1; }
echo "✓ both artifacts restored from the ${FROM} store."
echo "  export KUBECONFIG=${OUT}/kubeconfig"
echo "  export TALOSCONFIG=${OUT}/talosconfig"
