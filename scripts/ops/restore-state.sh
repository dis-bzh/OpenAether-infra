#!/usr/bin/env bash
# ==============================================================================
# OpenAether — seed a failover cluster's state from the replica of the provider that is gone.
#
# A's tfstate survives as the -backup replica; the Talos PKI and the etcd secretbox key exist only
# there. This copies it to B's own state key and untracks all but those, so `task cluster-up` on B
# builds a cluster A's backed-up kubeconfig and talosconfig still open. It never writes over a state
# that holds resources. Runbook: infrastructure/opentofu/cluster/README.md, "Cross-provider failover".
#
# Run from the cluster dir with B's backend initialised (`task restore-state` does both). Needs
# TF_VAR_encryption_passphrase, the S3 keys of the cloud holding the replica, and B's own.
# STATE_GENERATION=<timestamp> reads an older replica generation (backup-state.sh --list) instead of the current object.
# Usage: restore-state.sh <A.tfvars> <B.tfvars>
# ==============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

A="${1:?usage: restore-state.sh <A.tfvars> <B.tfvars>}"; B="${2:?usage: restore-state.sh <A.tfvars> <B.tfvars>}"
die() { echo "✗ $*" >&2; exit 1; }
for f in "$A" "$B"; do [ -f "$f" ] || die "no $f"; done
for bin in aws jq tofu; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done
[ -n "${TF_VAR_encryption_passphrase:-}" ] || die "TF_VAR_encryption_passphrase is not set: the state is unreadable without it"
oa_aws_compat

# What stays: the three state-only Talos resources, no cloud object behind them, so nothing else can
# recreate them; the rest of the state is A's machines and addresses. The #66 guards (bootstrap-in-state.sh,
# infra-down-plan) reason about the same resources and are deliberately not fed from this list.
PKI='module.talos.talos_machine_secrets.this[0]'   # also what makes a state worth restoring
KEEP=("$PKI" 'module.talos.random_bytes.etcd_encryption_secret' 'module.talos.random_password.disk_encryption_secret')

PA="$(tfv_provider "$A")"; PB="$(tfv_provider "$B")"
[ -n "$PA" ] && [ -n "$PB" ] || die "could not detect the provider in $A or $B"
CN_A="$(tfv "$A" cluster_name)"; SRC_EP="$(tfv "$A" s3_replica_endpoint)"; SRC_REGION="$(tfv "$A" s3_replica_region)"
CN_B="$(tfv "$B" cluster_name)"; DST_EP="$(tfv "$B" s3_primary_endpoint)"; DST_REGION="$(tfv "$B" s3_primary_region)"
# Each store signs with its own region; an empty one would reach the aws CLI as `--region ''`.
[ -n "$CN_A" ] && [ -n "$SRC_EP" ] && [ -n "$SRC_REGION" ] || die "$A needs cluster_name, s3_replica_endpoint and s3_replica_region"
[ -n "$CN_B" ] && [ -n "$DST_EP" ] && [ -n "$DST_REGION" ] || die "$B needs cluster_name, s3_primary_endpoint and s3_primary_region"
SRC="$(oa_state_bucket "$(oa_project "$CN_A" "$(tfv "$A" bucket_suffix)")" "$PA" "$(tfv "$A" environment)")-backup"
SRC_KEY="${CN_A}.tfstate"
# The current object can be a state written after a teardown (no PKI): an older generation may still hold it.
if [ -n "${STATE_GENERATION:-}" ]; then
  [[ "$STATE_GENERATION" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "STATE_GENERATION must look like 20261006T120000Z, as backup-state.sh --list prints it"
  SRC_KEY="${SRC_KEY}.${STATE_GENERATION}"
fi
DST="$(oa_state_bucket "$(oa_project "$CN_B" "$(tfv "$B" bucket_suffix)")" "$PB" "$(tfv "$B" environment)")"
DST_KEY="${CN_B}.tfstate"
# The undo below deletes the target: were it the replica itself, a failed run would delete the only PKI.
[ "$SRC_EP/$SRC/$SRC_KEY" != "$DST_EP/$DST/$DST_KEY" ] || die "the replica and the target are the same object, nothing was touched"

# The replica is opened with the keys of the cloud that HOLDS it (its endpoint says which), the target with B's own.
SRC_AK="$(s3_cred "$PA" backup ak "$SRC_EP")"; SRC_SK="$(s3_cred "$PA" backup sk "$SRC_EP")"
DST_AK="$(s3_cred "$PB" primary ak)";          DST_SK="$(s3_cred "$PB" primary sk)"
[ -n "$SRC_AK" ] && [ -n "$SRC_SK" ] || die "no S3 keys for the replica store ${SRC_EP}: the <PU>_AWS_* of the cloud that holds it"
[ -n "$DST_AK" ] && [ -n "$DST_SK" ] || die "no S3 keys for '${PB}': $(provider_pu "$PB")_AWS_*"

# The target must be empty: this seeds a cluster, it never replaces one. "No state file" is a real empty;
# any other failure is an unreadable state, which is not.
if OUT="$(tofu state list -no-color 2>&1)"; then
  [ -z "$OUT" ] || die "the state at s3://${DST}/${DST_KEY} already holds resources, nothing was copied"
else
  case "$OUT" in *"No state file was found"*) ;; *) die "cannot read the target state, so whether it is empty is unknown: $OUT" ;; esac
fi

WORK="$(mktemp -d)"
# From the PUT on, B's key holds A's whole state. Whatever ends the run before the untrack lands (a refusal,
# a failing tofu, Ctrl-C) takes it out again, so a retry meets an empty target; the replica is only read,
# so nothing is lost. Armed before the PUT: a write that errored may still have landed. kill -9 leaves it.
COPIED=0
undo() { AWS_ACCESS_KEY_ID="$DST_AK" AWS_SECRET_ACCESS_KEY="$DST_SK" aws s3 rm "s3://${DST}/${DST_KEY}" \
           --endpoint-url "$DST_EP" --region "$DST_REGION" >/dev/null 2>&1; }
finish() {
  local rc=$?
  if [ "$COPIED" = 1 ]; then
    if undo; then echo "  s3://${DST}/${DST_KEY} is empty again: nothing of ${PA}'s was left in it" >&2
    else echo "⚠ could not remove the copy: delete s3://${DST}/${DST_KEY} before a retry, it holds ${PA}'s whole state" >&2; fi
  fi
  rm -rf "$WORK"; exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT   # SIGTERM and SIGHUP run the EXIT trap by themselves; without this, the SIGINT test leaves the copy

AWS_ACCESS_KEY_ID="$SRC_AK" AWS_SECRET_ACCESS_KEY="$SRC_SK" \
  aws s3 cp "s3://${SRC}/${SRC_KEY}" "$WORK/state" --endpoint-url "$SRC_EP" --region "$SRC_REGION" >/dev/null ||
  die "could not fetch s3://${SRC}/${SRC_KEY} from ${SRC_EP}"
head -c 4096 "$WORK/state" | grep -q '"encrypted_data"' || die "the replica is not an encrypted OpenTofu state: refusing to guess"
COPIED=1
AWS_ACCESS_KEY_ID="$DST_AK" AWS_SECRET_ACCESS_KEY="$DST_SK" \
  aws s3 cp "$WORK/state" "s3://${DST}/${DST_KEY}" --endpoint-url "$DST_EP" --region "$DST_REGION" >/dev/null ||
  die "could not write s3://${DST}/${DST_KEY} on ${DST_EP}"

LIST="$(tofu state list -no-color 2>&1)" || die "the copied state could not be read (wrong TF_VAR_encryption_passphrase?): $(tail -n 2 <<<"$LIST")"
grep -qxF "$PKI" <<<"$LIST" ||
  die "this state holds no Talos PKI (a replica written after the teardown has none): try an older generation (STATE_GENERATION=<timestamp>, listed by backup-state.sh --list), else a fresh task cluster-up is the answer"

# prevent_destroy refuses a plan that replaces the secrets, and a talos_version below the recorded one plans exactly that (#66).
REC="$(tofu state pull | jq -r '[.resources[] | select(.module == "module.talos" and .type == "talos_machine_secrets") | .instances[0].attributes.talos_version][0] // empty')"
PIN="$(oa_pinned_version . "$B" talos_version)"
if [ -n "$REC" ] && [ -n "$PIN" ] && oa_semver_lt "$PIN" "$REC"; then
  die "talos_version ${PIN} in ${B##*/} is below ${REC}, the one the PKI was made for: raise it first, a lower one plans a replacement of the secrets"
fi

mapfile -t DROP < <(grep -vxFf <(printf '%s\n' "${KEEP[@]}") <<<"$LIST" || true)
# One call, one state write: a state half-pruned by an interrupted loop is the case this avoids.
if [ "${#DROP[@]}" -gt 0 ]; then tofu state rm -no-color "${DROP[@]}" >/dev/null; fi
COPIED=0

echo "✓ s3://${DST}/${DST_KEY} now holds the PKI of ${SRC} (recorded for Talos ${REC:-?}); ${#DROP[@]} resource(s) of ${PA} untracked:"
tofu state list -no-color | sed 's/^/    kept /'
echo "  Next: task cluster-up PROVIDER=${PB} ROLE=$(basename "$B" .tfvars | sed "s/-${PB}\$//") — and run nothing that reads outputs first: the stale ones are ${PA}'s."
