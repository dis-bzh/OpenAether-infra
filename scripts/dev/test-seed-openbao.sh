#!/usr/bin/env bash
# ==============================================================================
# seed-openbao.sh writes the Day-1 secrets, and its one hard rule is WRITE-IF-
# ABSENT: a re-run that rotated `backup/restic` would not fail, it would make
# every existing backup undecryptable. Nothing measured that rule, or that the
# script keeps its promise to print WHICH path it wrote and never WHAT.
#
# A stub `kubectl` answers the recovery Secret and plays `bao` behind
# `kubectl exec`: which paths already exist, which writes are refused. Offline —
# no cluster, no OpenBao, no credentials beyond the placeholders below.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { # <label> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"
}

SCRIPT=scripts/ops/seed-openbao.sh
SB="$(mktemp -d)"; LOG="$SB/calls.log"
# A sandbox envs dir (OA_ENVS_DIR): the real one holds the operator's tfvars.
ROLE=oaseed
mkdir "$SB/envs"; FIXTURE="$SB/envs/${ROLE}-scaleway.tfvars"
trap 'rm -rf "$SB"' EXIT

cat >"$FIXTURE" <<'EOF'
cluster_name        = "example-mgmt"
environment         = "test"
s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
EOF
printf 'apiVersion: v1\nkind: Config\n' >"$SB/kubeconfig"   # non-empty: no `task kubeconfig`

cat >"$SB/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl:%s\n' "$*" >>"$OA_STUB_LOG"
case "$*" in
  "get secret openbao-recovery"*)
    [ "${OA_STUB_NO_TOKEN:-0}" = 1 ] && exit 1
    printf 'root-token-STUB' | base64 ;;
  "get externalsecrets"*) printf 'observability alertmanager-slack\nbackup restic\n' ;;
  "annotate externalsecret"*) ;;
  "exec -i openbao-0 -n foundation-vault -- env "*)
    set -- "${@:7}"   # drop: exec -i pod -n ns -- ; then env + 3 assignments
    while [ "$1" != bao ]; do shift; done; shift
    case "$1 $2" in
      "status ") exit 0 ;;
      "secrets list") printf 'secret/    kv\n' ;;
      "kv get")  case ",${OA_STUB_EXISTING:-}," in *",${3#secret/},"*) exit 0 ;; *) exit 1 ;; esac ;;
      "kv put")
        p="${3#secret/}"; shift 3
        printf 'put:%s|%s\n' "$p" "$*" >>"$OA_STUB_LOG"
        case ",${OA_STUB_PUT_FAIL:-}," in *",$p,"*) echo "Error making API request: permission denied" >&2; exit 2 ;; esac ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$SB/kubectl"

BASE="KUBECONFIG=$SB/kubeconfig OPENBAO_WAIT=0 SCW_AWS_ACCESS_KEY_ID=STUB-PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=STUB-PRIMARY-SK"
run() { # [env k=v ...] — the script's stdout+stderr; env is exactly $ENV_EXTRA
  : >"$LOG"
  # shellcheck disable=SC2086
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_LOG="$LOG" OA_ENVS_DIR="$SB/envs" $ENV_EXTRA "$SCRIPT" scaleway "$ROLE" </dev/null 2>&1
}
puts()   { grep '^put:' "$LOG"; }
put_of() { grep "^put:$1|" "$LOG" | sed 's/^[^|]*|//'; }

echo "--- a fresh cluster: every Day-1 path is written, with the resolved S3 keys ---"
ENV_EXTRA="$BASE"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
is "nine paths written" 9 "$(puts | wc -l)"
for p in backup/s3-primary backup/s3-replica backup/restic observability/loki-s3 \
         observability/alertmanager-slack observability/alertmanager-deadmansswitch \
         grafana/db zitadel/db longhorn/encryption; do
  grep -q "^put:$p|" "$LOG" && ok "  + $p" || bad "  $p was not written"
done
P="$(put_of backup/s3-primary)"
grep -q "endpoint=https://s3.fr-par.scw.cloud" <<<"$P" && ok "s3-primary carries the tfvars endpoint" || bad "$P"
grep -q "bucket=s3-example-scaleway-backups-test" <<<"$P" && ok "…and the backups bucket built from cluster_name/environment" || bad "$P"
grep -q "access_key=STUB-PRIMARY-AK secret_key=STUB-PRIMARY-SK" <<<"$P" && ok "…and the keys resolve-s3-cred.sh resolved" || bad "$P"
R="$(put_of backup/s3-replica)"
grep -q "endpoint=https://s3.fr-par.scw.cloud" <<<"$R" && ok "no s3_replica_endpoint in the tfvars: the replica falls back to the primary endpoint" || bad "$R"
grep -q "bucket=s3-example-scaleway-backups-test-backup" <<<"$R" && ok "…in the -backup bucket" || bad "$R"
[ "$(put_of backup/restic | sed -n 's/^password=//p' | wc -c)" -gt 30 ] && ok "restic gets a fresh random password" || bad "restic: $(put_of backup/restic)"
grep -q "placeholders" <<<"$OUT" && ok "no alerting URLs in scope: it SAYS placeholders were seeded" || bad "silent placeholders: $OUT"
grep -q "seed-openbao/synced-at=" "$LOG" && ok "ExternalSecrets are nudged to re-read" || bad "no annotate call recorded"

echo "--- the promise: which path, never what ---"
grep -q "STUB-PRIMARY-SK" <<<"$OUT" && bad "the S3 secret key was printed" || ok "the S3 secret key is not in the output"
grep -q "STUB-PRIMARY-AK" <<<"$OUT" && bad "the S3 access key was printed" || ok "the S3 access key is not in the output"
grep -q "root-token-STUB" <<<"$OUT" && bad "the root token was printed" || ok "the root token is not in the output"
RESTIC_PW="$(put_of backup/restic | sed -n 's/^password=//p')"
[ -n "$RESTIC_PW" ] && ! grep -q "$RESTIC_PW" <<<"$OUT" \
  && ok "the generated restic password is not in the output" || bad "the restic password was printed (or never generated)"

echo "--- a re-run: what exists is left ALONE (rotating restic loses every backup) ---"
ENV_EXTRA="$BASE OA_STUB_EXISTING=backup/restic,zitadel/db"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
is "seven paths written" 7 "$(puts | wc -l)"
grep -q "^put:backup/restic|" "$LOG" && bad "backup/restic was REWRITTEN on a re-run" || ok "backup/restic is not rewritten"
grep -q "^put:zitadel/db|" "$LOG" && bad "zitadel/db was REWRITTEN on a re-run" || ok "zitadel/db is not rewritten"
grep -q "= secret/backup/restic (already set, left alone)" <<<"$OUT" && ok "and the output says it was left alone" || bad "$OUT"

echo "--- alerting URLs in scope: used, and no placeholder warning ---"
ENV_EXTRA="$BASE OA_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T0/B0/x OA_DEADMANSSWITCH_URL=https://hc-ping.com/1234"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
grep -q "webhook-url=https://hooks.slack.com/services/T0/B0/x" <<<"$(put_of observability/alertmanager-slack)" && ok "the Slack webhook is the one given" || bad "$(put_of observability/alertmanager-slack)"
grep -q "placeholders" <<<"$OUT" && bad "warned about placeholders with both URLs set" || ok "no placeholder warning"

echo "--- no S3 keys in scope: refused before any write ---"
ENV_EXTRA="KUBECONFIG=$SB/kubeconfig OPENBAO_WAIT=0"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "rc=0 with no credentials"
grep -q "no S3 credentials in scope" <<<"$OUT" && ok "and says so" || bad "$OUT"
is "zero writes" 0 "$(puts | wc -l)"

echo "--- a write is refused: the reason is on screen, and the run fails ---"
ENV_EXTRA="$BASE OA_STUB_PUT_FAIL=backup/s3-primary"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 after a refused write"
grep -q "could not write secret/backup/s3-primary: .*permission denied" <<<"$OUT" \
  && ok "the path AND bao's own reason are in the message" || bad "$OUT"

echo "--- the recovery Secret never appears: fails naming it, writes nothing ---"
ENV_EXTRA="$BASE OA_STUB_NO_TOKEN=1"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 with no root token"
grep -q "Secret/openbao-recovery" <<<"$OUT" && ok "and names the Secret it waited for" || bad "$OUT"
is "zero writes" 0 "$(puts | wc -l)"

echo "--- no s3_primary_endpoint in the tfvars: refused, not seeded empty ---"
sed -i '/s3_primary_endpoint/d' "$FIXTURE"
ENV_EXTRA="$BASE"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "seeded with an empty endpoint"
grep -q "s3_primary_endpoint is not set" <<<"$OUT" && ok "and names the missing field" || bad "$OUT"
is "zero writes" 0 "$(puts | wc -l)"

echo "--- no tfvars for that role/provider: refused ---"
rm -f "$FIXTURE"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "ran without a tfvars"
grep -q "no .*${ROLE}-scaleway.tfvars" <<<"$OUT" && ok "and names the file it wanted" || bad "$OUT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
