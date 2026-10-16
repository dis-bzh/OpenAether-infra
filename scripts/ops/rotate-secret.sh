#!/usr/bin/env bash
# Replace ONE operator-supplied secret in OpenBao with a new version, then make the cluster pick it up. This is the replace
# path that seed-openbao.sh (create-only, `cas=0`) deliberately does not have (ANSSI B2 renewal rule, PG-078 R7/R26;
# docs/incident-response.md section 7). It supports the paths whose new value comes from outside the cluster and whose
# consumers read it again by themselves; every other path is REFUSED with the reason, because replacing it here would
# break what holds the old value (a database role, an encrypted volume, restic's repositories, Zitadel's masterkey).
#
# Identity: the ServiceAccount `openaether-admin`, exchanged for an OpenBao token inside the pod (as `bao_admin` does); neither
# the token nor a value is on a command line here or in the pod, they travel on the stdin of `kubectl exec`; only the path and
# the version are printed. The write is a check-and-set on the version it read: a concurrent change fails it, nothing is clobbered.
# Dry run by default; --apply writes. ORDER OF A KEY ROTATION: create the new key at the provider, run this, confirm one backup
# run succeeded, THEN revoke the old key at the provider (revoking first stops the backups).
#
# Values (environment, never arguments):
#   backup/s3-primary  backup/s3-replica  observability/loki-s3   OA_ROTATE_ACCESS_KEY_ID + OA_ROTATE_SECRET_ACCESS_KEY
#                                           (optional OA_ROTATE_BUCKET, OA_ROTATE_ENDPOINT: the other fields stay as they are)
#   observability/alertmanager-slack  observability/alertmanager-deadmansswitch  grafana/oidc    OA_ROTATE_VALUE
#
# Usage: rotate-secret.sh <path> [--apply] [--restart <namespace>/<deployment|statefulset|daemonset>/<name>]...
#        KUBECONFIG (default: the cluster directory's). --restart waits for the ExternalSecrets to refresh first.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS=foundation-vault
export KUBECONFIG="${KUBECONFIG:-$ROOT/infrastructure/opentofu/cluster/kubeconfig}"
fail() { echo "✗ $*" >&2; exit "${2:-1}"; }
usage() { sed -n '/^# Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }

for t in kubectl jq; do command -v "$t" >/dev/null || fail "$t is required" 2; done
[ $# -ge 1 ] || usage
P="$1"; shift
APPLY=0; RESTARTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --restart) [[ "${2:-}" =~ ^[a-z0-9-]+/(deployment|statefulset|daemonset)/[a-z0-9.-]+$ ]] || fail "--restart takes <namespace>/<deployment|statefulset|daemonset>/<name>" 2
               RESTARTS+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done

# Which fields a path has and where the new value comes from. FIELDS: field=ENVVAR pairs; OPT: optional ones.
FIELDS=(); OPT=()
case "$P" in
  backup/s3-primary|backup/s3-replica)
    FIELDS=(access_key=OA_ROTATE_ACCESS_KEY_ID secret_key=OA_ROTATE_SECRET_ACCESS_KEY); OPT=(bucket=OA_ROTATE_BUCKET endpoint=OA_ROTATE_ENDPOINT) ;;
  observability/loki-s3)
    FIELDS=(accessKey=OA_ROTATE_ACCESS_KEY_ID secretKey=OA_ROTATE_SECRET_ACCESS_KEY); OPT=(bucket=OA_ROTATE_BUCKET endpoint=OA_ROTATE_ENDPOINT) ;;
  observability/alertmanager-slack) FIELDS=(webhook-url=OA_ROTATE_VALUE) ;;
  observability/alertmanager-deadmansswitch) FIELDS=(url=OA_ROTATE_VALUE) ;;
  grafana/oidc) FIELDS=(client-secret=OA_ROTATE_VALUE) ;;   # the new value is generated in the Zitadel console first
  backup/restic) fail "$P is not replaced here: restic encrypts the repositories with it. Add the new password to each repository (restic key add), check it opens, remove the old one, then write the new version by hand (OpenAether-apps docs/key-inventory.md); a leak with the bucket readable means a NEW repository" ;;
  zitadel/masterkey) fail "$P is not replaced here: it encrypts what Zitadel already stored and no rotation is known (OpenAether-apps docs/key-inventory.md); a new value breaks the identity layer" ;;
  longhorn/encryption) fail "$P is not replaced here: one passphrase serves every encrypted volume, a new value would be handed to volumes whose LUKS header holds the old one; a change is a new StorageClass and a data migration" ;;
  zitadel/db|grafana/db) fail "$P is not replaced here: the password also lives in PostgreSQL. ALTER ROLE first, then write the new version, refresh, restart the consumer (OpenAether-apps docs/key-inventory.md)" ;;
  zitadel/admin) fail "$P holds only the INITIAL password of the first admin; the current one is in Zitadel (change it in the console)" ;;
  grafana/admin) fail "$P is not replaced here: Grafana stores the admin password in its database after the first start (upstream: set once on first run), so a new value is not applied by a restart; reset it with grafana's own CLI (not verified on this platform)" ;;
  minio/root) fail "$P is not replaced here: not exercised, and its consumers are not all known to this tool; write a new version by hand and restart MinIO (OpenAether-apps docs/key-inventory.md)" ;;
  pki/*|secret/*) fail "$P is not a path this tool replaces (the PKI has its own runbook; give the path without the secret/ mount)" ;;
  *) fail "unknown path '$P'. Supported: backup/s3-primary backup/s3-replica observability/loki-s3 observability/alertmanager-slack observability/alertmanager-deadmansswitch grafana/oidc" 2 ;;
esac

# Values: all required ones present, no line break, the optional ones only when set. Resolved BEFORE the cluster is touched.
FILTER='.'; PICKED=()
for fv in "${FIELDS[@]}" "${OPT[@]}"; do
  f="${fv%%=*}"; v="${fv#*=}"
  if [ -z "${!v:-}" ]; then
    case " ${FIELDS[*]} " in *" $fv "*) fail "$v is required for $P (and is never read from an argument)" 2 ;; esac
    continue
  fi
  case "${!v}" in *$'\n'*|*$'\r'*) fail "$v holds a line break" 2 ;; esac
  FILTER="$FILTER | .data[\"$f\"] = \$ENV.$v"; PICKED+=("$f")
done
if [ "$P" = observability/alertmanager-slack ] || [ "$P" = observability/alertmanager-deadmansswitch ]; then
  case "$OA_ROTATE_VALUE" in https://*) ;; *) fail "OA_ROTATE_VALUE for $P must be an https:// URL" 2 ;; esac
fi

# --- OpenBao, through the pod --------------------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the $ are for the remote shell
REMOTE='
read -r jwt || exit 4
tok="$(printf "%s" "$jwt" | bao write -field=token auth/kubernetes/login role=openaether-admin jwt=-)" || { echo "LOGIN-FAILED" >&2; exit 3; }
export BAO_TOKEN="$tok"
case "$1" in
  read) exec bao read -format=json "secret/data/$2" ;;
  write) exec bao write -format=json "secret/data/$2" - ;;
esac'
JWT="$(kubectl -n "$NS" create token openaether-admin --duration=10m 2>&1)" && [ -n "$JWT" ] ||
  fail "no token for openaether-admin: is the cluster reachable (KUBECONFIG, tunnels) and OpenBao bootstrapped? ${JWT:0:200}"
bao_exec() { # <read|write> — stdin after the token line is the document (write)
  { printf '%s\n' "$JWT"; cat; } | kubectl -n "$NS" exec -i openbao-0 -- sh -c "$REMOTE" sh "$1" "$P"
}

CUR="$(bao_exec read </dev/null)" || fail "could not read secret/$P (does it exist? seed it first with seed-openbao.sh; the token and OpenBao must be up)"
VER="$(jq -r '.data.metadata.version // empty' <<<"$CUR")"
[[ "$VER" =~ ^[0-9]+$ ]] || fail "secret/$P answered without a version: refusing to write blind"
# The document is built from stdin (the old values are in it): nothing secret is ever an argument of jq.
NEW="$(jq -c --argjson ver "$VER" "{options:{cas:\$ver}, data:(.data.data // {})} | $FILTER" <<<"$CUR")" || fail "could not build the new document"
KEPT="$(jq -r --argjson p "$(printf '%s\n' "${PICKED[@]}" | jq -R . | jq -sc .)" '(.data.data // {}) | keys - $p | join(", ")' <<<"$CUR")"

echo "▶ secret/$P: version $VER; replaces: ${PICKED[*]}; keeps: ${KEPT:-nothing else}"
echo "  restarts after the refresh: ${RESTARTS[*]:-none}"
if [ "$APPLY" != 1 ]; then
  echo "  dry run: nothing written. Create the new key at the provider first, then add --apply. Revoke the OLD key only after a backup run succeeded."
  exit 0
fi

ANS="$(printf '%s\n' "$NEW" | bao_exec write)" || fail "OpenBao refused the write (a concurrent change makes the check-and-set fail: read again and retry): $(tr '\n' ' ' <<<"$ANS" | cut -c1-200)"
echo "  ✓ secret/$P: version $(jq -r '.data.version // "?"' <<<"$ANS") written"
JWT=""

# ExternalSecrets refresh hourly: nudge them, and (for a restart) wait until each has read after this moment.
T0="$(date -u +%FT%TZ)"
kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null |
  while read -r ns name; do
    [ -n "$ns" ] && kubectl annotate externalsecret "$name" -n "$ns" "force-sync=$(date -u +%s)" --overwrite >/dev/null 2>&1 || true
  done
echo "  ▶ ExternalSecrets nudged"
if [ "${#RESTARTS[@]}" -gt 0 ]; then
  deadline=$((SECONDS + ${OA_ROTATE_WAIT:-180}))
  while :; do
    stale="$(kubectl get externalsecrets -A -o json 2>/dev/null | jq --arg t "$T0" '[.items[] | select((.status.refreshTime // "") < $t)] | length' 2>/dev/null || echo x)"
    [ "$stale" = 0 ] && break
    [ "$SECONDS" -lt "$deadline" ] || fail "$stale ExternalSecret(s) did not refresh within ${OA_ROTATE_WAIT:-180}s: the new value is in OpenBao, NO consumer was restarted (kubectl get externalsecrets -A, then restart by hand)"
    sleep "${OA_ROTATE_POLL:-5}"
  done
  for r in "${RESTARTS[@]}"; do
    IFS=/ read -r rns rkind rname <<<"$r"
    kubectl -n "$rns" rollout restart "$rkind/$rname" >/dev/null || fail "could not restart $r"
    echo "  ✓ restarted $r"
  done
fi
echo "✓ done. Confirm a consumer works with the new value (a backup run, an alert delivery), THEN revoke the old one at its issuer."
