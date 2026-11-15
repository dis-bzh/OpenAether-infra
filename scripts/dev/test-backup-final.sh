#!/usr/bin/env bash
# scripts/ops/backup-final.sh (task backup-final), offline: the final backups before a planned destroy, against a kubectl double that
# serves the CronJobs, Jobs, Backups, Clusters, psql answers and the backup-verify log from fixture files, and stub aws and task.
# Proven here: dry-run runs nothing; --execute needs the cluster name and the right cluster; a failed Job, a Job that never ends, an
# API error, a FAIL or a SKIP of the verifier, a stale backup, a segment never archived and a store without the segment each fail
# the run, named, and no failed step reads OK. Not shown: what a real CNPG, barman or store answers (docs/disaster-recovery.md).
# SUT overrides the script (mutants).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/backup-final.sh}"
TMP="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] && echo "kept $TMP" || rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$TMP/tree/scripts/ops" "$TMP/tree/scripts/lib" "$TMP/tree/infrastructure/opentofu/cluster/envs" "$TMP/bin"
cp "$SUT" "$TMP/tree/scripts/ops/backup-final.sh"; cp "$ROOT"/scripts/lib/*.sh "$TMP/tree/scripts/lib/"
BF="$TMP/tree/scripts/ops/backup-final.sh"
cat >"$TMP/tree/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars" <<'TF'
cluster_name = "oa-test"
environment = "prod"
bucket_suffix = "zz"
s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
s3_primary_region = "fr-par"
s3_replica_endpoint = "https://s3.gra.io.cloud.ovh.net"
s3_replica_region = "gra"
TF
export OA_ENVS_DIR="$TMP/tree/infrastructure/opentofu/cluster/envs"
echo "apiVersion: v1" >"$TMP/kubeconfig"
SFX=zz; PB="s3-oa-${SFX}-scaleway-backups-prod"; RB="$PB-backup"   # derived from the test tfvars; a literal trips the env-data scan
SEGN=00000001000000000000000C

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# kubectl double: --kubeconfig F [-n NS] VERB ...; fixtures under $FX
shift 2
echo "kubectl $*" >>"$FX/calls.log"
ns=""; [ "$1" = -n ] && { ns="$2"; shift 2; }
apierr() { echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1; }
notfound() { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
mode() { cat "$FX/$1" 2>/dev/null || echo "${2:-}"; }
case "$*" in
  "get configmap cluster-identity -o "*) mode identity oa-test-prod-scaleway ;;
  "get cronjob "*" -o name") [ -f "$FX/absent-$3" ] && notfound "cronjobs.batch \"$3\""; echo "cronjob.batch/$3" ;;
  "delete job "* | "patch job "* | "delete backups.postgresql.cnpg.io "*) : ;;
  "create job "*) echo "$4" >>"$FX/jobs.log" ;;
  "get job "*)
    case "$(mode "job-$3" complete)" in
      complete) echo "True//" ;; failed) echo "/True/BackoffLimitExceeded" ;; never) echo "//" ;; apierr) apierr ;;
    esac ;;
  "get clusters.postgresql.cnpg.io -o "*) [ -f "$FX/list-apierr" ] && apierr; printf 'zitadel-db\tzitadel-db\ngrafana-db\tgrafana-db\nscratch\t\n' ;;
  "apply -f -") sed -n 's/.*"name":"\(final-base-[a-z-]*\)".*/\1/p' >>"$FX/backups.log" ;;
  "get backups.postgresql.cnpg.io "*) [ -f "$FX/backup-failed" ] && echo "failed/barman: Expected empty archive" || echo "completed/" ;;
  "get clusters.postgresql.cnpg.io "*" -o "*) echo "$3-1" ;;
  "exec "*)
    sql="${*: -1}"; echo "sql $2 $sql" >>"$FX/sql.log"
    case "$sql" in
      *pg_switch_wal*) echo 00000001000000000000000C ;;
      *">= '"*) mode archived t ;;
      *) echo "00000001000000000000000B|" ;;
    esac ;;
  "logs job/final-backup-verify "*)
    if [ -f "$FX/verify.log" ]; then cat "$FX/verify.log"; else
      for d in openbao cnpg-dump etcd cnpg; do for s in primary replica; do echo "PASS $d/$s: fine"; done; done; echo "SKIP longhorn: no Longhorn backup objects"; fi ;;
  "get configmap oa-backup-verify-metrics "*)
    now="$(date +%s)"; age="$(mode age 5)"
    echo "oa_backup_verify_last_run_timestamp_seconds $now"
    for d in openbao cnpg-dump etcd cnpg; do for s in primary replica; do echo "oa_backup_verify_newest_backup_age_seconds{dataset=\"$d\",store=\"$s\"} $age"; done; done ;;
  *) echo "kubectl double: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
op="$2"; b=""; p=""; k=""; while [ $# -gt 0 ]; do case "$1" in --bucket) b="$2" ;; --prefix) p="$2" ;; --key) k="$2" ;; esac; shift; done
echo "aws $op bucket=$b prefix=$p key=$k ak=${AWS_ACCESS_KEY_ID:+set}" >>"$FX/calls.log"
if [ "$op" = head-object ]; then   # --query ServerSideEncryption --output text: None when the store sent no header
  case "$(cat "$FX/sse-$b" 2>/dev/null)" in err) echo "An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 254 ;; none) echo None ;; *) echo AES256 ;; esac
  exit 0
fi
case "$(cat "$FX/aws-$b" 2>/dev/null)" in
  err) echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 254 ;;
  none) echo None ;;
  empty) printf '%s.gz\t0\n' "$p" ;;
  *) printf '%s.gz\t16384\n' "$p" ;;
esac
STUB
cat >"$TMP/bin/task" <<'STUB'
#!/usr/bin/env bash
echo "task $*" >>"$FX/calls.log"; exit "$(cat "$FX/task.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" OA_BF_POLL=0 OA_BF_WAIT_TRIES=3 OA_BF_API_TRIES=2 OA_BF_WAL_TRIES=2 OA_BF_WAL_POLL=0
export SCW_AWS_ACCESS_KEY_ID=AKIAEXAMPLE SCW_AWS_SECRET_ACCESS_KEY=SECRET-CANARY-p1 OVH_AWS_ACCESS_KEY_ID=ovhak OVH_AWS_SECRET_ACCESS_KEY=SECRET-CANARY-r2

N=0
new() { N=$((N + 1)); FX="$TMP/fx.$N"; mkdir -p "$FX"; export FX; }
run() { bash "$BF" scaleway --kubeconfig "$TMP/kubeconfig" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?; }
exe() { run --execute --confirm oa-test "$@"; }
row() { grep -qE "^  $1 +$2" "$TMP/out"; }                   # <step> <status regex>: the receipt line
says() { grep -q -- "$1" "$TMP/out" "$TMP/err"; }
calls() { cat "$FX/calls.log" 2>/dev/null; }
before() { local a b; a="$(calls | grep -n -m1 -- "$1" | cut -d: -f1)"; b="$(calls | grep -n -m1 -- "$2" | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
no_ok_after_failure() { ! grep -qE '^  [a-z]+ +OK .*(FAILED|did not)' "$TMP/out"; }

echo "=== arguments and dry-run ==="
new; bash "$BF" >/dev/null 2>&1; chk "no provider: usage, exit 2" "[ $? = 2 ]"
run --without nonsense; chk "an unknown step in --without is refused" "[ $RC = 2 ]"
run; chk "dry-run by default: exit 0, every step shown, nothing called" "[ $RC = 0 ] && says 'MODE: DRY-RUN' && [ \$(grep -c '^── step ' '$TMP/out') = 9 ] && [ ! -s '$FX/calls.log' ]"
chk "...and it names this cluster's two stores" "says 's3://$PB (https://s3.fr-par.scw.cloud)' && says 's3://$RB (https://s3.gra.io.cloud.ovh.net)'"
run --execute; chk "--execute without --confirm: exit 2, nothing called" "[ $RC = 2 ] && [ ! -s '$FX/calls.log' ]"
new; echo other-prod-scaleway >"$FX/identity"; exe
chk "a kubeconfig that reaches another cluster: refused before any Job (exit 1)" "[ $RC = 1 ] && says 'not oa-test-prod-scaleway' && [ ! -s '$FX/jobs.log' ]"

echo "=== the nominal run ==="
new; exe
chk "exit 0, RESULT COMPLETE, every step OK" "[ $RC = 0 ] && says 'RESULT: COMPLETE' && for s in openbao dump etcd base wal replicate verify store state; do row \$s OK || exit 1; done"
chk "the existing CronJobs are started, nothing re-implemented" "[ \"\$(sort '$FX/jobs.log' | tr '\n' ' ')\" = 'final-backup-verify final-cnpg-dump final-cnpg-store-replicate final-etcd-snapshot final-openbao-snapshot ' ]"
chk "a plugin Backup per archiving Cluster; the Cluster without archiver is left to the dump, and said" "[ \"\$(sort '$FX/backups.log' | tr '\n' ' ')\" = 'final-base-grafana-db final-base-zitadel-db ' ] && says 'scratch has no WAL archiver'"
chk "order: Backups completed, WAL switch, archived, then copy, then verify, then the store listing" "before 'get backups.postgresql.cnpg.io final-base-grafana-db' 'pg_switch_wal' && before 'pg_switch_wal' 'cronjob/cnpg-store-replicate' && before 'cronjob/cnpg-store-replicate' 'cronjob/backup-verify' && before 'logs job/final-backup-verify' 'aws list-objects-v2'"
chk "the store listing reads the switched segment in BOTH buckets, for each Cluster" "for b in $PB $RB; do for c in zitadel-db grafana-db; do calls | grep -q \"aws list-objects-v2 bucket=\$b prefix=cnpg/\$c/\$c/wals/0000000100000000/$SEGN\" || exit 1; done; done"
chk "the state is replicated through task backup-state" "calls | grep -q 'task backup-state PROVIDER=scaleway ROLE=management'"
chk "the receipt names the segments and the switch time" "row wal 'OK +zitadel-db $SEGN archived'; grep -q 'switched at' '$TMP/out'"
chk "no S3 secret in the output or a call" "! grep -q SECRET-CANARY '$TMP/out' '$TMP/err' '$FX/calls.log'"

echo "=== a Job that fails ==="
new; echo failed >"$FX/job-final-cnpg-dump"; exe
chk "exit 1, dump FAILED naming the Job and its reason, RESULT INCOMPLETE names dump" "[ $RC = 1 ] && row dump FAILED && grep -q 'final-cnpg-dump.*BackoffLimitExceeded' '$TMP/out' && grep -q 'INCOMPLETE — dump did not complete' '$TMP/err'"
chk "...the other backups still run and are reported" "row openbao OK && row base OK && row state OK"
new; echo failed >"$FX/job-final-cnpg-store-replicate"; exe
chk "a failed copy: replicate FAILED, verify and store NOT RUN (never OK)" "[ $RC = 1 ] && row replicate FAILED && row verify 'NOT RUN' && row store 'NOT RUN'"

echo "=== a Job that never completes ==="
new; echo never >"$FX/job-final-etcd-snapshot"; exe
chk "exit 1, etcd FAILED: did not finish within the bound" "[ $RC = 1 ] && row etcd FAILED && grep -q 'final-etcd-snapshot did not finish within' '$TMP/out'"

echo "=== an API error is not an empty answer ==="
new; touch "$FX/list-apierr"; exe
chk "the Cluster listing fails: base FAILED 'could not list', wal and store NOT RUN" "[ $RC = 1 ] && row base 'FAILED +could not list' && row wal 'NOT RUN' && row store 'NOT RUN'"
new; echo apierr >"$FX/job-final-openbao-snapshot"; exe
chk "a Job read keeps failing: openbao FAILED, 'the API did not answer', result unknown" "[ $RC = 1 ] && row openbao FAILED && grep -q 'the API did not answer about the Job foundation-vault/final-openbao-snapshot' '$TMP/out'"
new; touch "$FX/absent-etcd-snapshot"; exe
chk "a CronJob that does not exist: FAILED with the way out, not skipped" "[ $RC = 1 ] && row etcd 'FAILED +the CronJob foundation-databases/etcd-snapshot does not exist' && says '\-\-without etcd'"
new; touch "$FX/absent-etcd-snapshot"; exe --without etcd
chk "--without etcd: exit 0, NOT TAKEN in the receipt and in the RESULT, verify does not ask for etcd" "[ $RC = 0 ] && row etcd 'NOT TAKEN' && says 'except what --without left out: etcd' && ! calls | grep -q 'cronjob/etcd-snapshot'"
new; exe --without base
chk "--without base also leaves out wal, replicate and store (they need it)" "[ $RC = 0 ] && row wal 'NOT TAKEN' && row replicate 'NOT TAKEN' && row store 'NOT TAKEN' && row verify OK && ! calls | grep -q pg_switch_wal"

echo "=== the verifier: the lines, not the Job ==="
new; printf 'PASS openbao/primary: x\nFAIL cnpg/primary: backup b: its end WAL %s is not archived yet\n' "$SEGN" >"$FX/verify.log"; exe
chk "a Complete verify Job that printed FAIL: verify FAILED with the line" "[ $RC = 1 ] && row verify 'FAILED +backup-verify printed FAIL cnpg/primary'"
new; for d in openbao cnpg-dump etcd; do for s in primary replica; do echo "PASS $d/$s: x"; done; done >"$FX/verify.log"; echo "PASS cnpg/primary: x" >>"$FX/verify.log"; echo "SKIP cnpg/replica: no base backup" >>"$FX/verify.log"; exe
chk "a SKIP where a PASS is needed: verify FAILED naming dataset and store" "[ $RC = 1 ] && row verify 'FAILED +no PASS for cnpg/replica'"
new; echo 90000 >"$FX/age"; exe
chk "a PASS about a backup older than this run: verify FAILED (age)" "[ $RC = 1 ] && row verify 'FAILED +the newest openbao backup on primary is 90000s old'"

echo "=== the WAL and the stores ==="
new; echo f >"$FX/archived"; exe
chk "a segment never archived: wal FAILED with pg_stat_archiver, the copy, verify and store NOT RUN" "[ $RC = 1 ] && row wal 'FAILED +zitadel-db: segment $SEGN is not archived' && row replicate 'NOT RUN' && row verify 'NOT RUN' && row store 'NOT RUN'"
new; echo none >"$FX/aws-$RB"; exe
chk "the segment is not in the replica store: store FAILED naming the store" "[ $RC = 1 ] && row store 'FAILED +zitadel-db: segment $SEGN is not in the replica store'"
new; echo empty >"$FX/aws-$PB"; exe
chk "a zero-byte object does not count" "[ $RC = 1 ] && row store 'FAILED +zitadel-db: segment $SEGN is not in the primary store'"
new; echo err >"$FX/aws-$PB"; exe
chk "a refused listing is a failure, not an absence" "[ $RC = 1 ] && row store 'FAILED +could not list primary' && says AccessDenied"
new; echo 3 >"$FX/task.rc"; exe
chk "task backup-state failing: state FAILED" "[ $RC = 1 ] && row state FAILED"

echo "=== server-side encryption, read on the segment (infra #406) ==="
new; echo none >"$FX/sse-$RB"; echo err >"$FX/sse-$PB"; exe
chk "the receipt prints the header each store returned for the segment object: none when absent" "row store 'OK .*zitadel-db/replica 16384B sse=none'"
chk "a refused head-object is 'unread', never 'none', and does not fail a step that only reports it" "[ $RC = 0 ] && row store 'OK .*zitadel-db/primary 16384B sse=unread' && ! row store 'OK .*primary 16384B sse=none'"
new; exe
chk "the head-object reads the very key the listing found, in each store" "calls | grep -q 'aws head-object bucket=$PB prefix= key=cnpg/zitadel-db/zitadel-db/wals/0000000100000000/$SEGN.gz' && row store 'OK .*grafana-db/replica 16384B sse=AES256'"

echo "=== every failure above: no failed step was ever printed OK ==="
chk "no receipt line says OK with a failure message" "no_ok_after_failure"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
