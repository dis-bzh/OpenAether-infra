#!/usr/bin/env bash
# Seed the Day-1 secrets a fresh cluster cannot converge without (S3 keys of the two backup stores and of Loki, the
# alerting URLs). Without them the Flux DAG sits at 29 of 35: six Kustomizations wait for `backup/s3-primary` alone.
#
# CREATE-ONLY. The secrets are written with `cas=0`, so a re-run can never overwrite one (a rotated value does not
# fail, it just breaks whatever holds the old one). The application secrets (restic password, database passwords,
# Longhorn passphrase...) are NOT seeded here: openbao-vault-bootstrap generates them, in OpenBao, and prints none.
#
# NO ROOT TOKEN. OpenBao has none (apps >= 0.1.1 revokes it right after bootstrap). The script asks Kubernetes for a
# 10-minute token of the ServiceAccount `openbao-seeder`, and OpenBao exchanges it, inside the pod, for a token whose
# policy `secret-seeder` can create these five paths and nothing else. Neither that token nor a value is ever on a
# command line (here or in the pod): they travel on the stdin of `kubectl exec`. Nothing is printed but the path.
#
# What it deliberately does NOT do, because a human is genuinely required:
#   - sign the PKI intermediate offline with the root CA (admin-access.md § 2)
#   - register the Grafana OIDC client in Zitadel through a browser (`grafana/oidc`)
# Neither blocks the DAG.
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
NS=foundation-vault

export KUBECONFIG="${KUBECONFIG:-$CLUSTER/kubeconfig}"

fail() { echo "✗ $*" >&2; exit 1; }

[ -f "$TFVARS" ] || fail "no $TFVARS"
command -v kubectl >/dev/null || fail "kubectl is required"
command -v jq >/dev/null || fail "jq is required"

tfvar() { # <key> — read a top-level string from the env file; empty when absent
  # sed, not grep|sed: an absent key made grep exit 1, and under pipefail + set -e that killed the script at the
  # assignment with no output at all.
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$TFVARS" |
    head -1 | tr -d '[:space:]'
}

# `task cluster-up` leaves the kubeconfig in the state, not necessarily on disk.
if [ ! -s "$KUBECONFIG" ]; then
  (cd "$ROOT" && task kubeconfig ROLE="$ROLE" PROVIDER="$PROVIDER") >/dev/null 2>&1 ||
    fail "could not fetch the kubeconfig for ${ROLE}-${PROVIDER}"
fi

# --- The values (resolved BEFORE waiting: a missing credential fails in a second, not after twenty minutes) ---------

# S3 credentials: the same resolver the Taskfile uses. A store is opened with the keys of the cloud that HOLDS it, so
# the replica's pair is asked for with its own endpoint; seeding the primary's pair there (#296) wrote Scaleway keys
# for an OVH endpoint. `|| true`: report, do not vanish under set -e.
PRIMARY_EP="$(tfvar s3_primary_endpoint)"
REPLICA_EP="$(tfvar s3_replica_endpoint)"
[ -n "$PRIMARY_EP" ] || fail "s3_primary_endpoint is not set in $TFVARS"
[ -n "$REPLICA_EP" ] || REPLICA_EP="$PRIMARY_EP"

AK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak || true)"
SK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk || true)"
[ -n "$AK" ] && [ -n "$SK" ] || fail "no S3 credentials in scope for $PROVIDER (source .env.sh?)"
RAK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak backup "$REPLICA_EP" || true)"
RSK="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk backup "$REPLICA_EP" || true)"
[ -n "$RAK" ] && [ -n "$RSK" ] || fail "no S3 credentials in scope for the replica store $REPLICA_EP (source .env.sh? the replica's cloud has its own keys)"

# Application-backup bucket, through the SAME derivation as cluster/backup.tf and every other shell caller (#166).
PROJECT="$(oa_project "$(tfvar cluster_name)" "$(tfvar bucket_suffix || true)")"
BUCKET="$(oa_backup_bucket "$PROJECT" "$PROVIDER" "$(tfvar environment)")"

# Loki writes to ITS OWN bucket (#302): handing it the backups bucket let a compromised Loki erase the backups. Its keys
# are the operator's, when given: both OA_LOKI_S3_ACCESS_KEY_ID and OA_LOKI_S3_SECRET_ACCESS_KEY, a pair that can reach
# the logs bucket and nothing else (the providers' S3 keys are account-wide unless the operator scopes them). Without
# them Loki gets the primary's keys, and the script says what that does and does not protect against.
LOGS_BUCKET="$(oa_logs_bucket "$PROJECT" "$PROVIDER" "$(tfvar environment)")"
LAK="${OA_LOKI_S3_ACCESS_KEY_ID:-}"; LSK="${OA_LOKI_S3_SECRET_ACCESS_KEY:-}"
if [ -n "$LAK" ] || [ -n "$LSK" ]; then
  [ -n "$LAK" ] && [ -n "$LSK" ] || fail "OA_LOKI_S3_ACCESS_KEY_ID and OA_LOKI_S3_SECRET_ACCESS_KEY go together: set both or neither"
  LOKI_KEYS="dedicated"
else
  LAK="$AK"; LSK="$SK"; LOKI_KEYS="shared"
fi

# Alerting endpoints are real in production and arbitrary on a throwaway cluster. Say which of the two happened.
SLACK_URL="${OA_SLACK_WEBHOOK_URL:-}"
DMS_URL="${OA_DEADMANSSWITCH_URL:-}"
if [ -z "$SLACK_URL" ] || [ -z "$DMS_URL" ]; then
  echo "⚠ OA_SLACK_WEBHOOK_URL / OA_DEADMANSSWITCH_URL not set — seeding placeholders."
  echo "  Alertmanager will start and delivery will fail, which is the documented"
  echo "  throwaway-cluster behaviour. Set both for a cluster anyone relies on."
  SLACK_URL="${SLACK_URL:-https://hooks.slack.com/services/PLACEHOLDER/NOT/CONFIGURED}"
  DMS_URL="${DMS_URL:-https://hc-ping.com/00000000-0000-0000-0000-000000000000}"
fi

# One compact JSON document per secret, `path<TAB>{"options":{"cas":0},"data":{...}}`, values through the environment of
# jq (never an argument). Keys keep the names the ExternalSecrets read.
doc() { # <path> <key=ENVVAR>... — values come from the named variables
  local path="$1"; shift
  local filter='{options:{cas:0},data:{}}' k
  for k in "$@"; do filter="$filter | .data[\"${k%%=*}\"] = \$ENV.${k#*=}"; done
  printf '%s\t' "$path"
  jq -nc "$filter"
}
PAYLOAD="$(
  EP1="$PRIMARY_EP" B1="$BUCKET" A1="$AK" S1="$SK" \
  EP2="$REPLICA_EP" B2="${BUCKET}-backup" A2="$RAK" S2="$RSK" \
  B3="$LOGS_BUCKET" A3="$LAK" S3="$LSK" \
  SL="$SLACK_URL" DM="$DMS_URL" \
  bash -c "$(declare -f doc)
    doc backup/s3-primary endpoint=EP1 bucket=B1 access_key=A1 secret_key=S1
    doc backup/s3-replica endpoint=EP2 bucket=B2 access_key=A2 secret_key=S2
    doc observability/loki-s3 endpoint=EP1 bucket=B3 accessKey=A3 secretKey=S3
    doc observability/alertmanager-slack webhook-url=SL
    doc observability/alertmanager-deadmansswitch url=DM"
)"
EXPECTED="$(printf '%s\n' "$PAYLOAD" | grep -c .)"

# --- Where it runs ------------------------------------------------------------------------------------------------

# Stdin of the exec: line 1 = the ServiceAccount token, then the documents. In the pod: log in with it (the token is
# piped into `bao write ... jwt=-`, a shell builtin printf, so it is on no command line), then one `bao write` per
# document. The policy only allows `create`, so a path that exists answers 403 (and cas=0 would refuse it anyway):
# the metadata read, which the policy allows, tells "left alone" from a real refusal.
# shellcheck disable=SC2016  # the $ are for the remote shell
REMOTE='
read -r jwt || exit 4
tok="$(printf "%s" "$jwt" | bao write -field=token auth/kubernetes/login role=secret-seeder jwt=-)" || { echo "LOGIN-FAILED"; exit 3; }
export BAO_TOKEN="$tok"
tab="$(printf "\t")"
while IFS="$tab" read -r path data; do
  [ -n "$path" ] || continue
  if err="$(printf "%s" "$data" | bao write -format=json "secret/data/$path" - 2>&1 >/dev/null)"; then echo "+ $path"
  elif bao read -format=json "secret/metadata/$path" >/dev/null 2>&1; then echo "= $path"
  else echo "! $path: $(printf "%s" "$err" | tr "\n" " ")"; fi
done'

# The token is minted per attempt (10 minutes; a TokenRequest JWT can be replayed until it expires, which is why it is short). The wait is for OpenBao itself to be configured: the first
# login succeeds only once openbao-vault-bootstrap has created the role, so "can log in" is the readiness test.
OPENBAO_WAIT="${OPENBAO_WAIT:-1200}"
POLL="${OA_SEED_POLL:-15}"   # seconds between attempts (a test knob)
deadline=$((SECONDS + OPENBAO_WAIT))
echo "▶ Seeding Day-1 secrets (${PROVIDER}/${ROLE}, bucket ${BUCKET}, Loki bucket ${LOGS_BUCKET})"
last_note=0; ERR=""
while :; do
  OUT=""
  if jwt="$(kubectl -n "$NS" create token openbao-seeder --duration=10m 2>&1)" && [ -n "$jwt" ]; then
    if OUT="$( { printf '%s\n' "$jwt"; printf '%s\n' "$PAYLOAD"; } |
               kubectl exec -i openbao-0 -n "$NS" -- sh -c "$REMOTE" 2>&1 )"; then
      break
    fi
    ERR="$OUT"
  else
    ERR="$jwt"   # the error text, not a token
  fi
  jwt=""
  if [ "$SECONDS" -ge "$deadline" ]; then
    hint=""
    grep -q 'serviceaccounts "openbao-seeder" not found' <<<"$ERR" &&
      hint=" A cluster bootstrapped by apps 0.1.0 has no seeding identity (it keeps a root token in a Secret): seed it with the script of OpenAether-infra 0.2.0, or build a new cluster on apps >= 0.1.1 (a cluster initialised by 0.1.0 cannot be moved in place)."
    fail "OpenBao did not accept the seeding identity within ${OPENBAO_WAIT}s — is foundation-vault reconciling (kubectl -n $NS get pods,jobs), did openbao-vault-bootstrap finish, and does \$KUBECONFIG reach the cluster? Last answer: $(tr '\n' ' ' <<<"${ERR:-none}" | cut -c1-300).${hint}"
  fi
  if [ $((SECONDS - last_note)) -ge 60 ]; then echo "  … waiting for OpenBao to accept the seeding identity"; last_note=$SECONDS; fi
  sleep "$POLL"
done

WROTE=0; KEPT=0; FAILED=0
while IFS= read -r line; do
  case "$line" in
    "+ "*) echo "  + secret/${line#+ }"; WROTE=$((WROTE + 1)) ;;
    "= "*) echo "  = secret/${line#= } (already set, left alone)"; KEPT=$((KEPT + 1)) ;;
    "! "*) echo "  ✗ secret/${line#! }" >&2; FAILED=$((FAILED + 1)) ;;
  esac
done <<<"$OUT"
[ "$FAILED" -eq 0 ] || fail "could not write $FAILED secret(s) (see above)"

# What Loki really got, said from the answers of OpenBao and not from what this run intended: the entry is create-only, so a re-run
# or a cluster seeded before the dedicated bucket keeps whatever it holds.
if grep -q '^+ observability/loki-s3' <<<"$OUT"; then
  if [ "$LOKI_KEYS" = shared ]; then
    echo "⚠ Loki got the primary store's keys (OA_LOKI_S3_ACCESS_KEY_ID / OA_LOKI_S3_SECRET_ACCESS_KEY not set) and its own bucket."
    echo "  That protects the backups from a misconfigured Loki; it does NOT protect them from a compromised one, because these"
    echo "  keys reach the backups, state and artifact buckets too. Give Loki a key pair limited to ${LOGS_BUCKET} for that."
  else
    echo "  Loki got the key pair you gave (OA_LOKI_S3_*) and bucket ${LOGS_BUCKET}."
  fi
elif grep -q '^= observability/loki-s3' <<<"$OUT"; then
  echo "⚠ observability/loki-s3 already existed and was left alone: Loki keeps the bucket and keys it holds. A cluster seeded before the"
  echo "  dedicated logs bucket points at the BACKUPS bucket with the primary keys; ${LOGS_BUCKET}$([ "$LOKI_KEYS" = dedicated ] && echo " and the OA_LOKI_S3_* pair you set were") not applied."
  echo "  Replace the entry by hand to change it (docs/admin-access.md, section 3)."
fi
[ $((WROTE + KEPT)) -eq "$EXPECTED" ] || fail "expected $EXPECTED answers from OpenBao, got $((WROTE + KEPT)): $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"

# ExternalSecrets refresh hourly. Nudge them, or the cluster spends up to an hour looking broken for secrets that are
# already there.
echo "▶ Nudging ExternalSecrets to re-read"
kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null |
  while read -r ns name; do
    [ -n "$ns" ] && kubectl annotate externalsecret "$name" -n "$ns" \
      "seed-openbao/synced-at=$(date -u +%s)" --overwrite >/dev/null 2>&1 || true
  done

echo "✓ Day-1 secrets seeded. Still manual, and neither blocks the DAG:"
echo "    - sign the PKI intermediate offline (admin-access.md § 2)"
echo "    - register the Grafana OIDC client in Zitadel (grafana/oidc)"
