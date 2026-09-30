#!/usr/bin/env bash
# Seed the Day-1 secrets a fresh cluster cannot converge without.
#
# `docs/admin-access.md` § 3 lists these as manual `bao kv put` calls, and they
# are the difference between a cluster that looks up and a cluster whose Flux DAG
# converges: measured on Scaleway 2026-08-14, six Kustomizations sat not-Ready
# for want of `backup/s3-primary` alone, and all 35 went Ready within two minutes
# of seeding. Nothing automated it and nothing checked it, so the only lane that
# could have caught it — the unattended one — asserted a convergence the product
# never delivers on its own.
#
# WRITE-IF-ABSENT, never overwrite. Re-running must not rotate `backup/restic`:
# a new password does not fail, it makes every existing backup undecryptable.
# Same for the DB passwords, which the running Postgres roles already hold.
#
# Values come from the environment (the same `.env.sh` / CI secrets everything
# else uses). Nothing is printed: the script says which path it wrote, never what.
#
# What it deliberately does NOT do, because a human is genuinely required:
#   - sign the PKI intermediate offline with the root CA (§ 2)
#   - register the Grafana OIDC client in Zitadel through a browser (`grafana/oidc`)
# Neither blocks the DAG — verified on the same cluster.
#
# Usage: seed-openbao.sh <scaleway|ovh|outscale|proxmox> [role]
set -euo pipefail

PROVIDER="${1:?usage: seed-openbao.sh <provider> [role]}"
ROLE="${2:-management}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"   # oa_project / oa_backup_bucket
CLUSTER="$ROOT/infrastructure/opentofu/cluster"
TFVARS="${OA_ENVS_DIR:-$CLUSTER/envs}/${ROLE}-${PROVIDER}.tfvars"   # OA_ENVS_DIR: a test sandbox

export KUBECONFIG="${KUBECONFIG:-$CLUSTER/kubeconfig}"

fail() { echo "✗ $*" >&2; exit 1; }

[ -f "$TFVARS" ] || fail "no $TFVARS"
command -v kubectl >/dev/null || fail "kubectl is required"

tfvar() { # <key> — read a top-level string from the env file; empty when absent
  # sed, not grep|sed: an absent key made grep exit 1, and under pipefail +
  # set -e that killed the script at the assignment with no output at all —
  # the "vanish" this file's own comments below refuse for the root token.
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$TFVARS" |
    head -1 | tr -d '[:space:]'
}

# --- Where the secrets go -----------------------------------------------------

# `task cluster-up` leaves the kubeconfig in the state, not necessarily on disk, and this
# runs before anything else fetches it. Without this the script died at the first
# kubectl call — see the `|| true` note directly below for why it died silently.
if [ ! -s "$KUBECONFIG" ]; then
  (cd "$ROOT" && task kubeconfig ROLE="$ROLE" PROVIDER="$PROVIDER") >/dev/null 2>&1 ||
    fail "could not fetch the kubeconfig for ${ROLE}-${PROVIDER}"
fi

# WAIT for OpenBao to exist. Day-1 seeding runs right after `task cluster-up`, and at
# that moment Flux has barely started: `foundation-vault` is several
# Kustomizations down the DAG and its init Job has not produced the recovery
# Secret yet. Failing here was just being early — measured twice on 2026-08-14.
# OPENBAO_WAIT is in seconds.
#
# `|| true` on the substitution is load-bearing. Under `set -e` with `pipefail` a
# failing command substitution aborts the script AT THE ASSIGNMENT, so the check
# below never ran and the script exited 1 with NO OUTPUT AT ALL — the one thing
# an error path must never do.
OPENBAO_WAIT="${OPENBAO_WAIT:-1200}"
__deadline=$((SECONDS + OPENBAO_WAIT))
ROOT_TOKEN=""
while :; do
  ROOT_TOKEN="$(kubectl get secret openbao-recovery -n foundation-vault \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || true)"
  [ -n "$ROOT_TOKEN" ] && break
  if [ "$SECONDS" -ge "$__deadline" ]; then
    fail "no root token in Secret/openbao-recovery after ${OPENBAO_WAIT}s — is foundation-vault reconciling, and does \$KUBECONFIG reach the cluster?"
  fi
  sleep 15
done

# ⚠️ https, not http. admin-access.md said `BAO_ADDR=http://127.0.0.1:8200` and
# the pod answers "Client sent an HTTP request to an HTTPS server" — the
# documented command could never have worked. Skip-verify because the listener
# holds the cluster's own self-signed pair and we are already inside the pod.
bao() {
  kubectl exec -i openbao-0 -n foundation-vault -- \
    env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
    bao "$@"
}

# The Secret can exist a few seconds before the pod answers, and it is unsealed
# by its own Job — so wait here too rather than racing it.
while :; do
  bao status >/dev/null 2>&1 && break
  [ "$SECONDS" -lt "$__deadline" ] || fail "OpenBao did not answer within ${OPENBAO_WAIT}s (sealed?)"
  sleep 10
done

# And wait for the KV engine to be MOUNTED. Being unsealed is not being ready:
# `openbao-vault-bootstrap` enables `secret/` in a Job of its own, and until it
# has, every write here fails — which is exactly how this failed on the fourth
# clean run, one stage further along than the time before.
while :; do
  bao secrets list 2>/dev/null | grep -q '^secret/' && break
  [ "$SECONDS" -lt "$__deadline" ] || fail "the KV engine at secret/ was never mounted within ${OPENBAO_WAIT}s — is openbao-vault-bootstrap still running?"
  sleep 10
done

exists() { bao kv get "secret/$1" >/dev/null 2>&1; }

put() { # <path> <k=v>...
  local path="$1"; shift
  if exists "$path"; then
    echo "  = secret/$path (already set, left alone)"
    return 0
  fi
  local err
  # Keep stderr. Swallowing it made the first failure here read as
  # "could not write secret/backup/s3-primary" with no reason at all, which is
  # the same blindness this script exists to remove.
  if err="$(bao kv put "secret/$path" "$@" 2>&1 >/dev/null)"; then
    echo "  + secret/$path"
  else
    fail "could not write secret/$path: ${err}"
  fi
}

rnd() { openssl rand -base64 "$1" | tr -d '=+/'; }

# --- The values ---------------------------------------------------------------

# S3 credentials: the same resolver the Taskfile uses, so one place decides.
# Same `|| true` reasoning as the root token above: report, do not vanish.
AK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak || true)"
SK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk || true)"
[ -n "$AK" ] && [ -n "$SK" ] || fail "no S3 credentials in scope for $PROVIDER (source .env.sh?)"

PRIMARY_EP="$(tfvar s3_primary_endpoint)"
REPLICA_EP="$(tfvar s3_replica_endpoint)"
[ -n "$PRIMARY_EP" ] || fail "s3_primary_endpoint is not set in $TFVARS"
[ -n "$REPLICA_EP" ] || REPLICA_EP="$PRIMARY_EP"

# Application-backup bucket, through the SAME derivation as cluster/backup.tf
# and every other shell caller — this was the one place that rebuilt the name
# by hand and dropped bucket_suffix, so a suffixed cluster's restic and Loki
# were pointed at a bucket nothing created (#166). bucket_suffix is optional.
BUCKET="$(oa_backup_bucket "$(oa_project "$(tfvar cluster_name)" "$(tfvar bucket_suffix || true)")" "$PROVIDER" "$(tfvar environment)")"

# Alerting endpoints are real in production and arbitrary on a throwaway cluster,
# which admin-access.md says explicitly. Take them from the environment when set,
# and say which of the two happened rather than quietly using a placeholder.
SLACK_URL="${OA_SLACK_WEBHOOK_URL:-}"
DMS_URL="${OA_DEADMANSSWITCH_URL:-}"
if [ -z "$SLACK_URL" ] || [ -z "$DMS_URL" ]; then
  echo "⚠ OA_SLACK_WEBHOOK_URL / OA_DEADMANSSWITCH_URL not set — seeding placeholders."
  echo "  Alertmanager will start and delivery will fail, which is the documented"
  echo "  throwaway-cluster behaviour. Set both for a cluster anyone relies on."
  SLACK_URL="${SLACK_URL:-https://hooks.slack.com/services/PLACEHOLDER/NOT/CONFIGURED}"
  DMS_URL="${DMS_URL:-https://hc-ping.com/00000000-0000-0000-0000-000000000000}"
fi

echo "▶ Seeding Day-1 secrets (${PROVIDER}/${ROLE}, bucket ${BUCKET})"

put backup/s3-primary endpoint="$PRIMARY_EP" bucket="$BUCKET" access_key="$AK" secret_key="$SK"
put backup/s3-replica endpoint="$REPLICA_EP" bucket="${BUCKET}-backup" access_key="$AK" secret_key="$SK"
put backup/restic password="$(rnd 36)"
put observability/loki-s3 endpoint="$PRIMARY_EP" bucket="$BUCKET" accessKey="$AK" secretKey="$SK"
put observability/alertmanager-slack webhook-url="$SLACK_URL"
put observability/alertmanager-deadmansswitch url="$DMS_URL"
put grafana/db password="$(rnd 24)"
put zitadel/db username=zitadel password="$(rnd 24)"
put longhorn/encryption passphrase="$(rnd 48)"

# ExternalSecrets refresh hourly. Nudge them, or the cluster spends up to an hour
# looking broken for secrets that are already there.
echo "▶ Nudging ExternalSecrets to re-read"
kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null |
  while read -r ns name; do
    [ -n "$ns" ] && kubectl annotate externalsecret "$name" -n "$ns" \
      "seed-openbao/synced-at=$(date -u +%s)" --overwrite >/dev/null 2>&1 || true
  done

echo "✓ Day-1 secrets seeded. Still manual, and neither blocks the DAG:"
echo "    - sign the PKI intermediate offline (admin-access.md § 2)"
echo "    - register the Grafana OIDC client in Zitadel (grafana/oidc)"
