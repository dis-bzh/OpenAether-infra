#!/usr/bin/env bash
# OpenAether — encrypted etcd snapshot → TWO object stores (client-side crypto)
#
# An RTO shortcut, not a replacement for the in-cluster backups: Flux rebuilds
# cluster content, this covers what lives only in etcd (Secrets written by Jobs,
# PVC bindings…).
#
# talosctl snapshot through the SSH tunnels → gpg AES-256 with the SAME
# passphrase as the tfstate → primary + replica artifact buckets, keeping the
# last $KEEP.
#
# SNAPSHOT_LABEL=<label> names the artifact <label>-etcd-<timestamp>.snap.gpg and skips retention: the prune only lists
# etcd-*, so a labelled snapshot is never a victim. `cluster-upgrade` takes a `pre-upgrade` one before the first step (#270).
#
# Restore (disaster only — wipes current etcd; prefer GitOps reconvergence):
#   gpg -d etcd-<ts>.snap.gpg > etcd.snap
#   talosctl -e <cp> -n <cp-ip> bootstrap --recover-from=etcd.snap
#
# Usage: etcd-snapshot.sh   (env: KEEP=30, TALOSCONFIG=./talosconfig)
#   Run from infrastructure/opentofu/cluster with tunnels open.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

KEEP="${KEEP:-30}"
LABEL="${SNAPSHOT_LABEL:-}"
[ -z "$LABEL" ] || [[ "$LABEL" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
  || { echo "✗ SNAPSHOT_LABEL must be lowercase letters, digits and dashes, starting with a letter (got '$LABEL')" >&2; exit 1; }
TALOSCONFIG_FILE="${TALOSCONFIG:-./talosconfig}"

for bin in tofu jq talosctl aws gpg; do
  command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required" >&2; exit 1; }
done
[ -f "$TALOSCONFIG_FILE" ] || { echo "✗ talosconfig not found: $TALOSCONFIG_FILE" >&2; exit 1; }
PASSPHRASE="${TF_VAR_encryption_passphrase:?✗ TF_VAR_encryption_passphrase required (same passphrase as the tfstate)}"
export TALOSCONFIG="$TALOSCONFIG_FILE"
oa_aws_compat

# --- targets & creds (single source of truth: backup_targets output) ---------
T="$(tofu output -json backup_targets 2>/dev/null || echo 'null')"
[ "$T" != "null" ] && [ -n "$T" ] || { echo "✗ no backup_targets output — apply the infra first" >&2; exit 1; }
PRIMARY_BUCKET="$(jq -r '.artifact_bucket_primary' <<<"$T")"
REPLICA_BUCKET="$(jq -r '.artifact_bucket_replica' <<<"$T")"
PRIMARY_EP="$(jq -r '.primary_endpoint' <<<"$T")";  PRIMARY_REGION="$(jq -r '.primary_region' <<<"$T")"
REPLICA_EP="$(jq -r '.replica_endpoint' <<<"$T")";  REPLICA_REGION="$(jq -r '.replica_region' <<<"$T")"
PROVIDER="$(jq -r '.provider' <<<"$T")"

PRIMARY_AK="$(s3_cred "$PROVIDER" primary ak)"; PRIMARY_SK="$(s3_cred "$PROVIDER" primary sk)"
BACKUP_AK="$(s3_cred "$PROVIDER" backup ak "$REPLICA_EP")"
BACKUP_SK="$(s3_cred "$PROVIDER" backup sk "$REPLICA_EP")"

mapfile -t CP_IPS < <(tofu output -json 2>/dev/null | jq -r '.control_plane_private_ips.value[]? // empty')
[ ${#CP_IPS[@]} -gt 0 ] || { echo "✗ no control_plane_private_ips output — is the infra deployed?" >&2; exit 1; }

GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
WORK="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME" "$WORK"' EXIT

# --- 1) snapshot from the first healthy CP (tunnels: CP i → 50000+i) ---------
SNAP="$WORK/etcd.snap"
took=""
TUNNEL_OFFSET="$(oa_tunnel_offset)"
for k in "${!CP_IPS[@]}"; do
  ep="127.0.0.1:$((50000 + TUNNEL_OFFSET + k))"; ip="${CP_IPS[$k]}"
  if talosctl -e "$ep" -n "$ip" etcd snapshot "$SNAP" >/dev/null 2>&1; then
    took="cp-${k} (${ip})"; break
  fi
done
[ -n "$took" ] || { echo "✗ etcd snapshot failed on every CP — tunnels open? (talos-tunnels.sh open)" >&2; exit 1; }
echo "✓ etcd snapshot taken via ${took} ($(du -h "$SNAP" | cut -f1))"

# --- 2) client-side encrypt (same model as backup-artifacts.sh) --------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$WORK/${LABEL:+$LABEL-}etcd-${TS}.snap.gpg"
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 \
    --symmetric --cipher-algo AES256 -o "$OUT" "$SNAP" 3< <(printf '%s' "$PASSPHRASE")

# --- 3) upload to both stores + 4) retention ---------------------------------
put_and_prune() { # bucket endpoint region ak sk
  local bucket="$1" ep="$2" region="$3" ak="$4" sk="$5"
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3 cp "$OUT" "s3://${bucket}/backups/etcd/$(basename "$OUT")" \
      --endpoint-url "$ep" --region "$region" --sse AES256 >/dev/null

  [ -z "$LABEL" ] || return 0   # a labelled snapshot is kept for a purpose, and the prune below only lists etcd-*
  # Retention: timestamped names sort lexically == chronologically. The slice
  # end is clamped at 0: a negative end counts from the END in jq, so with fewer
  # than $KEEP snapshots `.[0:(length - KEEP)]` deleted all but the newest few —
  # 28 of 29 at KEEP=30 — exactly while a young cluster had the fewest to lose.
  local old
  old="$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3api list-objects-v2 --bucket "$bucket" --prefix "backups/etcd/etcd-" \
      --endpoint-url "$ep" --region "$region" \
      --query 'Contents[].Key' --output json 2>/dev/null \
    | jq -r --argjson keep "$KEEP" '. // [] | sort | .[0:([length - $keep, 0] | max)] | .[]?' )"
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
      aws s3 rm "s3://${bucket}/${key}" --endpoint-url "$ep" --region "$region" >/dev/null
  done <<<"$old"
}

put_and_prune "$PRIMARY_BUCKET" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK"
put_and_prune "$REPLICA_BUCKET" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK"  "$BACKUP_SK"

if [ -n "$LABEL" ]; then
  echo "✓ Encrypted etcd snapshot → s3://${PRIMARY_BUCKET}/backups/etcd/$(basename "$OUT") + s3://${REPLICA_BUCKET}/backups/etcd/$(basename "$OUT") (labelled: never pruned)"
else
  echo "✓ Encrypted etcd snapshot → s3://${PRIMARY_BUCKET}/backups/etcd/ + s3://${REPLICA_BUCKET}/backups/etcd/ (keep ${KEEP})"
fi
