#!/usr/bin/env bash
# ==============================================================================
# seed-openbao.sh writes the Day-1 secrets. What this pins:
#   - CREATE-ONLY: every document carries cas=0 and a re-run leaves what exists alone;
#   - NO ROOT TOKEN and no value on any command line: the identity is the ServiceAccount `openbao-seeder`, the token and
#     the documents travel on the stdin of `kubectl exec`, and the output names paths, never values;
#   - the replica store gets the keys of the cloud that HOLDS it (#296), not the primary's;
#   - it seeds the five paths of the `secret-seeder` policy and nothing else (the application secrets are generated
#     by openbao-vault-bootstrap, in OpenBao).
#
# A stub `kubectl` plays the cluster: `create token`, and `exec … sh -c <script>` which it answers the way the remote
# script would (+ created, = left alone, ! refused). Offline: no cluster, no OpenBao. The remote script itself was run
# against a real OpenBao 2.7.1 with the real `secret-seeder` policy (create → +, again → =, other path → !).
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
ROLE=oaseed
mkdir "$SB/envs"; FIXTURE="$SB/envs/${ROLE}-scaleway.tfvars"
trap 'rm -rf "$SB"' EXIT

write_tfvars() { # [replica endpoint line]
  cat >"$FIXTURE" <<TF
cluster_name        = "example-mgmt"
environment         = "test"
s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
$1
TF
}
write_tfvars ""
printf 'apiVersion: v1\nkind: Config\n' >"$SB/kubeconfig"   # non-empty: no `task kubeconfig`

cat >"$SB/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl:%s\n' "$*" >>"$OA_STUB_LOG"
case "$*" in
  "-n foundation-vault create token openbao-seeder"*)
    if [ "${OA_STUB_NO_SA:-0}" = 1 ]; then echo 'Error from server (NotFound): serviceaccounts "openbao-seeder" not found' >&2; exit 1; fi
    printf 'jwt-STUB-SA-TOKEN' ;;
  "get externalsecrets"*) printf 'observability alertmanager-slack\nbackup restic\n' ;;
  "annotate externalsecret"*) ;;
  "exec -i openbao-0 -n foundation-vault -- sh -c "*)
    n="$(cat "$OA_STUB_LOG.attempts" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$OA_STUB_LOG.attempts"
    if [ "$n" -lt "${OA_STUB_NOT_READY:-0}" ]; then echo "LOGIN-FAILED"; exit 3; fi
    IFS= read -r jwt; printf 'stdin-jwt:%s\n' "$jwt" >>"$OA_STUB_LOG"
    tab="$(printf '\t')"
    while IFS="$tab" read -r path data; do
      [ -n "$path" ] || continue
      printf 'put:%s|%s\n' "$path" "$data" >>"$OA_STUB_LOG"
      case ",${OA_STUB_PUT_FAIL:-}," in *",$path,"*) echo "! $path: Error making API request: permission denied"; continue ;; esac
      case ",${OA_STUB_EXISTING:-}," in *",$path,"*) echo "= $path" ;; *) echo "+ $path" ;; esac
    done ;;
esac
exit 0
STUB
chmod +x "$SB/kubectl"

BASE="KUBECONFIG=$SB/kubeconfig OPENBAO_WAIT=0 OA_SEED_POLL=0 SCW_AWS_ACCESS_KEY_ID=STUB-PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=STUB-PRIMARY-SK"
run() { # the script's stdout+stderr; env is exactly $ENV_EXTRA
  : >"$LOG"; rm -f "$LOG.attempts"
  # shellcheck disable=SC2086
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_LOG="$LOG" OA_ENVS_DIR="$SB/envs" $ENV_EXTRA "$SCRIPT" scaleway "$ROLE" </dev/null 2>&1
}
puts()   { grep '^put:' "$LOG"; }
doc_of() { grep "^put:$1|" "$LOG" | sed 's/^[^|]*|//'; }
field()  { jq -r ".data[\"$2\"]" <<<"$(doc_of "$1")"; }

echo "--- a fresh cluster: the five seeding paths are written, with the resolved S3 keys ---"
ENV_EXTRA="$BASE"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
is "five paths written" 5 "$(puts | wc -l)"
for p in backup/s3-primary backup/s3-replica observability/loki-s3 \
         observability/alertmanager-slack observability/alertmanager-deadmansswitch; do
  grep -q "^put:$p|" "$LOG" && ok "  + $p" || bad "  $p was not written"
done
for p in backup/restic grafana/db zitadel/db longhorn/encryption; do
  grep -q "^put:$p|" "$LOG" && bad "$p is seeded here: openbao-vault-bootstrap generates it" || ok "  $p is left to openbao-vault-bootstrap"
done
is "every document is create-only (cas=0)" 5 "$(puts | sed 's/^[^|]*|//' | jq -r '.options.cas' | grep -c '^0$')"
is "s3-primary endpoint" "https://s3.fr-par.scw.cloud" "$(field backup/s3-primary endpoint)"
is "…bucket built from cluster_name/environment" "s3-example-scaleway-backups-test" "$(field backup/s3-primary bucket)"
is "…access key resolved by resolve-s3-cred.sh" "STUB-PRIMARY-AK" "$(field backup/s3-primary access_key)"
is "…secret key" "STUB-PRIMARY-SK" "$(field backup/s3-primary secret_key)"
is "no s3_replica_endpoint: the replica falls back to the primary endpoint" "https://s3.fr-par.scw.cloud" "$(field backup/s3-replica endpoint)"
is "…in the -backup bucket" "s3-example-scaleway-backups-test-backup" "$(field backup/s3-replica bucket)"
is "…with the primary's keys (same cloud)" "STUB-PRIMARY-AK" "$(field backup/s3-replica access_key)"
is "loki-s3 uses accessKey/secretKey, the names the ExternalSecret reads" "STUB-PRIMARY-SK" "$(field observability/loki-s3 secretKey)"
is "loki writes to its OWN bucket, never the backups bucket (#302)" "s3-example-scaleway-logs-test" "$(field observability/loki-s3 bucket)"
[ "$(field observability/loki-s3 bucket)" != "$(field backup/s3-primary bucket)" ] && ok "…and it differs from the backups bucket" || bad "Loki shares the backups bucket"
grep -q "does NOT protect them from a compromised one" <<<"$OUT" && ok "without dedicated keys it SAYS what the separation does not cover" || bad "silent shared keys: $OUT"
grep -q "placeholders" <<<"$OUT" && ok "no alerting URLs in scope: it SAYS placeholders were seeded" || bad "silent placeholders: $OUT"
grep -q "seed-openbao/synced-at=" "$LOG" && ok "ExternalSecrets are nudged to re-read" || bad "no annotate call recorded"

echo "--- Loki with a key pair of its own: that pair is seeded, and the warning is gone ---"
ENV_EXTRA="$BASE OA_LOKI_S3_ACCESS_KEY_ID=STUB-LOKI-AK OA_LOKI_S3_SECRET_ACCESS_KEY=STUB-LOKI-SK"
OUT2="$(run)"; RC=$?
is "the script completes" 0 "$RC"
is "loki access key is the dedicated one" "STUB-LOKI-AK" "$(field observability/loki-s3 accessKey)"
is "loki secret key is the dedicated one" "STUB-LOKI-SK" "$(field observability/loki-s3 secretKey)"
is "the backups keep the primary's keys" "STUB-PRIMARY-AK" "$(field backup/s3-primary access_key)"
grep -q "does NOT protect" <<<"$OUT2" && bad "the warning is printed for a dedicated pair" || ok "no warning for a dedicated pair"
grep -q "STUB-LOKI" <<<"$OUT2" && bad "a Loki key was printed" || ok "the Loki keys are not printed"
ENV_EXTRA="$BASE OA_LOKI_S3_ACCESS_KEY_ID=STUB-LOKI-AK"
OUT2="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "half a pair is refused (rc=$RC)" || bad "seeded with half a Loki pair"
is "…before any write" 0 "$(puts | wc -l)"
ENV_EXTRA="$BASE"
OUT="$(run)"

echo "--- Loki entry already there (re-run, or a cluster seeded before the dedicated bucket): the script does not claim what it did not do ---"
ENV_EXTRA="$BASE OA_STUB_EXISTING=observability/loki-s3"
OUT2="$(run)"; RC=$?
is "the script completes" 0 "$RC"
grep -q "already existed and was left alone" <<<"$OUT2" && ok "it says the Loki entry was left alone" || bad "$OUT2"
grep -q "does NOT protect" <<<"$OUT2" && bad "the shared-keys warning is printed for an entry that was not written" || ok "…and does not describe keys it did not write"
ENV_EXTRA="$BASE OA_STUB_EXISTING=observability/loki-s3 OA_LOKI_S3_ACCESS_KEY_ID=STUB-LOKI-AK OA_LOKI_S3_SECRET_ACCESS_KEY=STUB-LOKI-SK"
OUT2="$(run)"
grep -q "pair you set were not applied" <<<"$OUT2" && ok "a dedicated pair set against an existing entry is reported as NOT applied" || bad "$OUT2"
ENV_EXTRA="$BASE"
OUT="$(run)"

echo "--- the promise: which path, never what; no root token; nothing on a command line ---"
for v in STUB-PRIMARY-SK STUB-PRIMARY-AK jwt-STUB-SA-TOKEN; do
  grep -q "$v" <<<"$OUT" && bad "$v was printed" || ok "$v is not in the output"
done
if grep '^kubectl:' "$LOG" | grep -qE 'STUB-PRIMARY|jwt-STUB|webhook|PLACEHOLDER'; then bad "a value or the token is on a kubectl command line"; else ok "no value and no token on any kubectl command line"; fi
grep -q 'openbao-recovery\|root_token' "$LOG" && bad "the script touches a root token" || ok "no root token anywhere in the calls"
is "the ServiceAccount token reaches the pod on stdin" "jwt-STUB-SA-TOKEN" "$(sed -n 's/^stdin-jwt://p' "$LOG")"
grep -q "create token openbao-seeder --duration=10m" "$LOG" && ok "a 10-minute token of the seeding ServiceAccount" || bad "no token request: $(grep create "$LOG")"

echo "--- the replica store is on another cloud: it gets THAT cloud's keys (#296) ---"
write_tfvars 's3_replica_endpoint = "https://s3.gra.io.cloud.ovh.net"'
ENV_EXTRA="$BASE OVH_BACKUP_AWS_ACCESS_KEY_ID=STUB-REPLICA-AK OVH_BACKUP_AWS_SECRET_ACCESS_KEY=STUB-REPLICA-SK"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
is "replica endpoint is the tfvars one" "https://s3.gra.io.cloud.ovh.net" "$(field backup/s3-replica endpoint)"
is "replica access key is the replica cloud's" "STUB-REPLICA-AK" "$(field backup/s3-replica access_key)"
is "replica secret key is the replica cloud's" "STUB-REPLICA-SK" "$(field backup/s3-replica secret_key)"
is "the primary keeps the primary's keys" "STUB-PRIMARY-AK" "$(field backup/s3-primary access_key)"
is "loki (the primary bucket) keeps the primary's keys" "STUB-PRIMARY-AK" "$(field observability/loki-s3 accessKey)"
grep -q "STUB-REPLICA" <<<"$OUT" && bad "a replica key was printed" || ok "the replica keys are not printed either"
echo "--- …and without that cloud's keys: refused before any write, naming the store ---"
ENV_EXTRA="$BASE"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "seeded the replica with no keys of its own"
grep -q "replica store https://s3.gra.io.cloud.ovh.net" <<<"$OUT" && ok "and names the replica store" || bad "$OUT"
is "zero writes" 0 "$(puts | wc -l)"
write_tfvars ""

echo "--- a re-run: what exists is left ALONE ---"
ENV_EXTRA="$BASE OA_STUB_EXISTING=backup/s3-primary,observability/loki-s3"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
grep -q "= secret/backup/s3-primary (already set, left alone)" <<<"$OUT" && ok "s3-primary reported as left alone" || bad "$OUT"
grep -q "+ secret/backup/s3-replica" <<<"$OUT" && ok "…while the missing one is written" || bad "$OUT"
is "every document still carries cas=0, so a race can not overwrite" 5 "$(puts | sed 's/^[^|]*|//' | jq -r '.options.cas' | grep -c '^0$')"

echo "--- alerting URLs in scope: used, and no placeholder warning ---"
ENV_EXTRA="$BASE OA_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T0/B0/x OA_DEADMANSSWITCH_URL=https://hc-ping.com/1234"
OUT="$(run)"; RC=$?
is "the script completes" 0 "$RC"
is "the Slack webhook is the one given" "https://hooks.slack.com/services/T0/B0/x" "$(field observability/alertmanager-slack webhook-url)"
grep -q "placeholders" <<<"$OUT" && bad "warned about placeholders with both URLs set" || ok "no placeholder warning"

echo "--- no S3 keys in scope: refused before any attempt ---"
ENV_EXTRA="KUBECONFIG=$SB/kubeconfig OPENBAO_WAIT=0"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "rc=0 with no credentials"
grep -q "no S3 credentials in scope" <<<"$OUT" && ok "and says so" || bad "$OUT"
is "zero writes" 0 "$(puts | wc -l)"
grep -q "create token" "$LOG" && bad "asked Kubernetes for a token before checking the inputs" || ok "no token requested"

echo "--- a write is refused: the reason is on screen, and the run fails ---"
ENV_EXTRA="$BASE OA_STUB_PUT_FAIL=backup/s3-primary"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 after a refused write"
grep -q "secret/backup/s3-primary: .*permission denied" <<<"$OUT" && ok "the path AND bao's own reason are in the message" || bad "$OUT"

echo "--- OpenBao is not configured yet: it waits, then seeds ---"
ENV_EXTRA="$BASE OPENBAO_WAIT=60 OA_STUB_NOT_READY=2"
OUT="$(run)"; RC=$?
is "completes after the retries" 0 "$RC"
is "five paths written" 5 "$(puts | wc -l)"
is "three attempts were made" 3 "$(cat "$LOG.attempts")"

echo "--- OpenBao never accepts the seeding identity: fails naming the wait ---"
ENV_EXTRA="$BASE OA_STUB_NOT_READY=99"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 when the login never works"
grep -q "did not accept the seeding identity" <<<"$OUT" && ok "and says what it waited for" || bad "$OUT"
is "zero writes" 0 "$(puts | wc -l)"

echo "--- a cluster bootstrapped by apps 0.1.0 (no seeding identity): fails with the way out ---"
ENV_EXTRA="$BASE OA_STUB_NO_SA=1"
OUT="$(run)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 without a seeding identity"
grep -q "apps 0.1.0" <<<"$OUT" && ok "and explains the legacy cluster" || bad "$OUT"
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
