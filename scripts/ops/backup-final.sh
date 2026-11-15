#!/usr/bin/env bash
# ==============================================================================
# OpenAether — the final backups before a planned destroy or a migration, as one command that ends on a receipt (infra #435).
#
# It adds no backup mechanism: it starts the cluster's own CronJobs as Jobs (openbao-snapshot, cnpg-dump, etcd-snapshot), takes a
# plugin Backup of each archiving CNPG Cluster, forces the WAL segment that holds the last commit into the archive, runs
# cnpg-store-replicate then backup-verify and reads its PASS lines (not the Job, which ends Complete on a FAIL), lists that segment in
# both stores from here, and replicates the tfstate (task backup-state). The rule it enforces is the apps backup README, "A completed
# Backup is not a restore point yet"; docs/disaster-recovery.md, "Before a planned destruction", has the hand version.
#
# DRY-RUN IS THE DEFAULT: it prints the steps and their commands and runs nothing. --execute needs --confirm <cluster_name>, and the
# kubeconfig must reach the cluster that the tfvars name (cluster-identity). Stop the writers first: a commit after the WAL switch is in
# no store, and the receipt says when the switch was. A step that cannot run or does not prove itself fails, named; --without is the
# only way to leave one out, and the receipt says NOT TAKEN for it.
#
# Usage:
#   backup-final.sh <provider> [--role management] [--kubeconfig F] [--without step,step] [--execute --confirm <cluster_name>]
#   steps, in order: openbao dump etcd base wal replicate verify store state
#
# Exit 0 every step that was not left out is taken and verified, 1 a step failed (do not destroy), 2 usage.
# Needs (execute): kubectl, aws (step store), task (step state), the S3 keys of both stores as for task restore-artifacts.
# Rung: mocked (scripts/dev/test-backup-final.sh, a kubectl double); NOT run on a cluster.
# ==============================================================================
set -uo pipefail

usage() { sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -n -1; }
PROVIDER="${1:-}"
case "$PROVIDER" in "" | -h | --help | -*) usage >&2; exit 2 ;; esac
shift
ROLE=management; KCFG=""; WITHOUT=""; EXECUTE=0; CONFIRM=""
need_arg() { [ $# -ge 2 ] || { echo "✗ $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --role) need_arg "$@"; ROLE="$2"; shift 2 ;;
    --kubeconfig) need_arg "$@"; KCFG="$2"; shift 2 ;;
    --without) need_arg "$@"; WITHOUT="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --dry-run) EXECUTE=0; shift ;;
    --confirm) need_arg "$@"; CONFIRM="$2"; shift 2 ;;
    *) echo "✗ unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done
STEPS=(openbao dump etcd base wal replicate verify store state)
declare -A DEP=([wal]=base [replicate]=wal [store]=replicate)   # a step whose input failed is NOT RUN, never OK
declare -A RES NOTE SKIP
for x in ${WITHOUT//,/ }; do
  case " ${STEPS[*]} " in *" $x "*) SKIP[$x]=1 ;; *) echo "✗ --without: '$x' is not a step (${STEPS[*]})" >&2; exit 2 ;; esac
done
for s in "${STEPS[@]}"; do [ -z "${DEP[$s]:-}" ] || [ -z "${SKIP[${DEP[$s]}]:-}" ] || SKIP[$s]=1; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
TFVARS="${OA_ENVS_DIR:-$CLUSTER_DIR/envs}/${ROLE}-${PROVIDER}.tfvars"   # OA_ENVS_DIR: a test sandbox
[ -f "$TFVARS" ] || { echo "✗ no $TFVARS" >&2; exit 1; }
CN="$(tfv "$TFVARS" cluster_name)"; ENVN="$(tfv "$TFVARS" environment)"
[ -n "$CN" ] && [ -n "$ENVN" ] || { echo "✗ could not read cluster_name/environment from ${TFVARS##*/}" >&2; exit 1; }
CID="${CN}-${ENVN}-${PROVIDER}"   # CLUSTER_NAME of cluster-identity (main.tf cluster_id)
BKT_P="$(oa_backup_bucket "$(oa_project "$CN" "$(tfv "$TFVARS" bucket_suffix)")" "$PROVIDER" "$ENVN")"; BKT_R="${BKT_P}-backup"
EP_P="$(tfv "$TFVARS" s3_primary_endpoint)"; REGION_P="$(tfv "$TFVARS" s3_primary_region)"
EP_R="$(tfv "$TFVARS" s3_replica_endpoint)"; EP_R="${EP_R:-$EP_P}"
REGION_R="$(tfv "$TFVARS" s3_replica_region)"; REGION_R="${REGION_R:-$REGION_P}"
KCFG="${KCFG:-$CLUSTER_DIR/kubeconfig}"
TASK="${OA_BF_TASK:-task}"; POLL="${OA_BF_POLL:-10}"; TRIES="${OA_BF_WAIT_TRIES:-750}"; API_TRIES="${OA_BF_API_TRIES:-6}"
WAL_TRIES="${OA_BF_WAL_TRIES:-30}"; SKEW="${OA_BF_SKEW:-120}"
DB=foundation-databases; VAULT=foundation-vault; VERIFY_CM=oa-backup-verify-metrics
K() { kubectl --kubeconfig "$KCFG" "$@"; }
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
say() { printf '%s\n' "$*"; }
mark() { RES[$1]="$2"; NOTE[$1]="$3"; }   # <step> OK|FAILED|NOT RUN|NOT TAKEN <note>
api_err() { head -c 300 "$ERR" | tr '\n' ' '; }

declare -A JOB_NS=([openbao]=$VAULT [dump]=$DB [etcd]=$DB [replicate]=$DB [verify]=$DB)
declare -A JOB_CJ=([openbao]=openbao-snapshot [dump]=cnpg-dump [etcd]=etcd-snapshot [replicate]=cnpg-store-replicate [verify]=backup-verify)
declare -A DATASET=([openbao]=openbao [dump]=cnpg-dump [etcd]=etcd [base]=cnpg)   # backup-verify's dataset of each step

show() {
  case "$1" in
    openbao | dump | etcd | replicate | verify)
      say "  \$ kubectl -n ${JOB_NS[$1]} create job --from=cronjob/${JOB_CJ[$1]} final-${JOB_CJ[$1]}   # an earlier final-* is deleted first, the owner reference dropped" ;;&
    verify) say "  check: PASS on both stores for every dataset taken here, no FAIL line, and the ages in $VERIFY_CM younger than this run" ;;
    base) say "  \$ kubectl -n $DB apply Backup final-base-<cluster> (method plugin) for each Cluster that archives; wait until completed" ;;
    wal) say "  \$ kubectl -n $DB exec <primary> -c postgres -- psql -c 'SELECT pg_walfile_name(pg_switch_wal() - 1)'; wait until pg_stat_archiver.last_archived_wal reaches it" ;;
    store) say "  \$ aws s3api list-objects-v2 --bucket $BKT_P / $BKT_R --prefix cnpg/<cluster>/<serverName>/wals/…/<segment>   # the switched segment, size > 0, from here; head-object prints its sse= header" ;;
    state) say "  \$ $TASK backup-state PROVIDER=$PROVIDER ROLE=$ROLE" ;;
  esac
}

# ── Jobs ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
start_job() { # <step>: prints why on failure
  local ns="${JOB_NS[$1]}" cj="${JOB_CJ[$1]}" j="final-${JOB_CJ[$1]}"
  if ! K -n "$ns" get cronjob "$cj" -o name >/dev/null 2>"$ERR"; then
    grep -q NotFound "$ERR" && { echo "the CronJob $ns/$cj does not exist here (its brick is not in this profile? then --without $1)"; return 1; }
    echo "could not read the CronJob $ns/$cj: $(api_err)"; return 1
  fi
  # a retry must neither stop on AlreadyExists nor read the old run
  K -n "$ns" delete job "$j" --ignore-not-found >/dev/null 2>"$ERR" || { echo "could not delete the earlier Job $ns/$j: $(api_err)"; return 1; }
  K -n "$ns" create job --from="cronjob/$cj" "$j" >/dev/null 2>"$ERR" || { echo "could not create the Job $ns/$j: $(api_err)"; return 1; }
  # the CronJob's history limit would prune a Job it owns before it is read (infra #427)
  K -n "$ns" patch job "$j" --type merge -p '{"metadata":{"ownerReferences":null}}' >/dev/null 2>&1 \
    || echo "  (warning: the owner reference of $ns/$j stays: the CronJob may prune it)" >&2
}
# poll <what> <decide-fn> <kubectl args...>: decide reads the value, returns 0 done, 1 failed (prints why), 2 not yet.
# An API error is retried API_TRIES times in a row, then it is the answer: an unknown result is never a success.
poll() {
  local what="$1" decide="$2" o r errs=0 i; shift 2
  for ((i = 0; i < TRIES; i++)); do
    if o="$(K "$@" 2>"$ERR")"; then
      errs=0; "$decide" "$o"; r=$?
      [ "$r" -eq 2 ] || return "$r"
    else
      grep -q NotFound "$ERR" && { echo "$what is gone (NotFound) before it was seen done"; return 1; }
      errs=$((errs + 1))
      [ "$errs" -lt "$API_TRIES" ] || { echo "the API did not answer about $what ($(api_err)): its result is unknown"; return 1; }
    fi
    sleep "$POLL"
  done
  echo "$what did not finish within $((TRIES * POLL)) s"; return 1
}
job_state() { case "$1" in True/*) return 0 ;; */True/*) echo "FAILED (${1##*/})"; return 1 ;; *) return 2 ;; esac; }
wait_job() { # <step>
  local ns="${JOB_NS[$1]}" j="final-${JOB_CJ[$1]}" m
  m="$(poll "the Job $ns/$j" job_state -n "$ns" get job "$j" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}/{.status.conditions[?(@.type=="Failed")].status}/{.status.conditions[?(@.type=="Failed")].reason}')" \
    || { echo "the Job $ns/$j: $m; read kubectl -n $ns logs job/$j --all-containers"; return 1; }
  echo "Job $ns/$j Complete"
}

# ── CNPG ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
declare -A SERVER SEG
CLUSTERS=()
list_clusters() {
  local out name srv
  out="$(K -n "$DB" get clusters.postgresql.cnpg.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.plugins[?(@.isWALArchiver==true)].parameters.serverName}{"\n"}{end}' 2>"$ERR")" \
    || { echo "could not list the CNPG Clusters of $DB: $(api_err)"; return 1; }
  while IFS=$'\t' read -r name srv; do
    [ -n "$name" ] || continue
    [ -n "$srv" ] || { say "  note: $name has no WAL archiver: only the dump covers it" >&2; continue; }
    CLUSTERS+=("$name"); SERVER[$name]="$srv"
  done <<<"$out"
  [ "${#CLUSTERS[@]}" -gt 0 ] || { echo "no archiving CNPG Cluster in $DB (none in this profile? then --without base)"; return 1; }
}
start_base() {
  local c
  list_clusters || return 1
  for c in "${CLUSTERS[@]}"; do
    K -n "$DB" delete backups.postgresql.cnpg.io "final-base-$c" --ignore-not-found >/dev/null 2>"$ERR" \
      || { echo "could not delete the earlier Backup final-base-$c: $(api_err)"; return 1; }
    printf '{"apiVersion":"postgresql.cnpg.io/v1","kind":"Backup","metadata":{"name":"final-base-%s","namespace":"%s"},"spec":{"cluster":{"name":"%s"},"method":"plugin","pluginConfiguration":{"name":"barman-cloud.cloudnative-pg.io"}}}\n' "$c" "$DB" "$c" \
      | K apply -f - >/dev/null 2>"$ERR" || { echo "could not create the Backup final-base-$c: $(api_err)"; return 1; }
  done
}
backup_state() { case "$1" in completed/*) return 0 ;; failed/*) echo "failed (${1#*/})"; return 1 ;; *) return 2 ;; esac; }
wait_base() {
  local c m names=""
  for c in "${CLUSTERS[@]}"; do
    m="$(poll "the Backup $DB/final-base-$c" backup_state -n "$DB" get backups.postgresql.cnpg.io "final-base-$c" -o jsonpath='{.status.phase}/{.status.error}')" \
      || { echo "the Backup final-base-$c: $m"; return 1; }
    names="$names final-base-$c"
  done
  echo "completed:$names (not a restore point until step wal)"
}
q() { K -n "$DB" exec "$1" -c postgres -- psql -U postgres -X -At -c "$2" 2>"$ERR"; }
run_wal() {
  local c p seg r i notes=""
  for c in "${CLUSTERS[@]}"; do
    p="$(K -n "$DB" get clusters.postgresql.cnpg.io "$c" -o jsonpath='{.status.currentPrimary}' 2>"$ERR")" && [ -n "$p" ] \
      || { echo "$c: no current primary ($(api_err))"; return 1; }
    seg="$(q "$p" 'SELECT pg_walfile_name(pg_switch_wal() - 1)')" || { echo "$c: the WAL switch on $p failed: $(api_err)"; return 1; }
    [[ "$seg" =~ ^[0-9A-F]{24}$ ]] || { echo "$c: the WAL switch on $p answered '$seg', not a segment name"; return 1; }
    for ((i = 0; i < WAL_TRIES; i++)); do
      r="$(q "$p" "SELECT last_archived_wal COLLATE \"C\" >= '$seg' FROM pg_stat_archiver")" && [ "$r" = t ] && break
      sleep "${OA_BF_WAL_POLL:-2}"
    done
    if [ "$r" != t ]; then
      echo "$c: segment $seg is not archived ($(q "$p" 'SELECT last_archived_wal, last_failed_wal FROM pg_stat_archiver' | tr '|' ' ')): archiving fails, do not destroy (apps backup README, 'If the forced segment does not get archived')"
      return 1
    fi
    SEG[$c]="$seg"; notes="$notes $c $seg archived;"
  done
  echo "${notes# } switched at $(date -u +%H:%M:%SZ): a later commit is in no store"
}

# ── backup-verify: the lines, not the Job ────────────────────────────────────────────────────────────────────────────────────
check_verify() {
  local log s ds st need=() bad metrics last age
  log="$(K -n "$DB" logs job/final-backup-verify --all-containers 2>"$ERR")" || { echo "could not read the log of final-backup-verify: $(api_err)"; return 1; }
  bad="$(grep -E '^FAIL ' <<<"$log" | head -n 3)"
  [ -z "$bad" ] || { echo "backup-verify printed $(tr '\n' ' ' <<<"$bad")"; return 1; }
  for s in openbao dump etcd base; do [ "${RES[$s]:-}" = "NOT TAKEN" ] || need+=("${DATASET[$s]}"); done
  for ds in "${need[@]}"; do for st in primary replica; do
    grep -qE "^PASS $ds/$st: " <<<"$log" || { echo "no PASS for $ds/$st ($(grep -E "^SKIP $ds/$st:" <<<"$log" | head -n 1 || true))"; return 1; }
  done; done
  # the ages prove the PASS is about the backups of THIS run, not an older one
  metrics="$(K -n "$DB" get configmap "$VERIFY_CM" -o jsonpath='{.data.metrics}' 2>"$ERR")" || { echo "could not read $DB/$VERIFY_CM: $(api_err)"; return 1; }
  last="$(sed -n 's/^oa_backup_verify_last_run_timestamp_seconds \([0-9]*\).*/\1/p' <<<"$metrics")"
  [ -n "$last" ] && [ "$last" -ge $((T0 - SKEW)) ] || { echo "$VERIFY_CM was not published by this run (last run ${last:-absent})"; return 1; }
  for ds in "${need[@]}"; do for st in primary replica; do
    age="$(sed -n "s/^oa_backup_verify_newest_backup_age_seconds{dataset=\"$ds\",store=\"$st\"} \([0-9]*\).*/\1/p" <<<"$metrics")"
    [ -n "$age" ] || { echo "no age for $ds/$st in $VERIFY_CM"; return 1; }
    [ "$age" -le $((last - T0 + SKEW)) ] || { echo "the newest $ds backup on $st is ${age}s old: older than this run, so not the one just taken"; return 1; }
  done; done
  echo "PASS on both stores for ${need[*]}; every newest backup younger than this run"
}

# ── the switched segment, listed from here in both stores ────────────────────────────────────────────────────────────────────
run_store() {
  local c st b ep rg kind ak sk out key size sse notes=""
  command -v aws >/dev/null 2>&1 || { echo "aws is not on PATH"; return 1; }
  oa_aws_compat
  for c in "${CLUSTERS[@]}"; do for st in primary replica; do
    if [ "$st" = primary ]; then b="$BKT_P"; ep="$EP_P"; rg="$REGION_P"; kind=primary; else b="$BKT_R"; ep="$EP_R"; rg="$REGION_R"; kind=backup; fi
    ak="$(s3_cred "$PROVIDER" "$kind" ak "$ep" 2>/dev/null)"; sk="$(s3_cred "$PROVIDER" "$kind" sk "$ep" 2>/dev/null)"
    [ -n "$ak" ] && [ -n "$sk" ] || { echo "no S3 keys for the $st store ($ep)"; return 1; }
    out="$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" aws s3api list-objects-v2 --bucket "$b" --endpoint-url "$ep" ${rg:+--region "$rg"} \
      --prefix "cnpg/$c/${SERVER[$c]}/wals/${SEG[$c]:0:16}/${SEG[$c]}" --query 'Contents[].[Key,Size]' --output text 2>"$ERR")" \
      || { echo "could not list $st s3://$b: $(api_err)"; return 1; }
    read -r key size <<<"$(awk '$2 > 0 { print; exit }' <<<"$out")"
    [ -n "${key:-}" ] || { echo "$c: segment ${SEG[$c]} is not in the $st store (s3://$b) with a size: $(head -c 120 <<<"$out")"; return 1; }
    # Whether the store applied the SSE request is not otherwise observable (infra #406): reported, never a pass or a fail.
    sse="$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" aws s3api head-object --bucket "$b" --key "$key" --endpoint-url "$ep" ${rg:+--region "$rg"} \
      --query ServerSideEncryption --output text 2>"$ERR")" || sse=unread
    [ "$sse" != None ] || sse=none
    notes="$notes $c/$st ${size}B sse=$sse;"
  done; done
  echo "${notes# }"
}
run_state() { ( cd "$ROOT" && $TASK backup-state PROVIDER="$PROVIDER" ROLE="$ROLE" ) >&2 || { echo "task backup-state failed (its output is above)"; return 1; }; echo "tfstate replicated"; }

# ── the run ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
say "OpenAether final backups — cluster $CID — stores s3://$BKT_P ($EP_P), s3://$BKT_R ($EP_R)"
say "$([ "$EXECUTE" = 1 ] && echo 'MODE: EXECUTE' || echo 'MODE: DRY-RUN (nothing is run; --execute --confirm <cluster_name> takes the backups)')"
say "Stop the writers first: a commit after the WAL switch of step wal is in no store."
for s in "${STEPS[@]}"; do
  say ""; say "── step $s$([ -n "${SKIP[$s]:-}" ] && echo '  [NOT TAKEN: --without]')"; show "$s"
done
if [ "$EXECUTE" = 0 ]; then exit 0; fi
[ "$CONFIRM" = "$CN" ] || { echo "✗ --execute needs --confirm $CN (the cluster_name of ${TFVARS##*/}); got '${CONFIRM:-nothing}'" >&2; exit 2; }
[ -s "$KCFG" ] || { echo "✗ no kubeconfig at $KCFG (task kubeconfig PROVIDER=$PROVIDER, or --kubeconfig)" >&2; exit 1; }
live="$(K -n flux-system get configmap cluster-identity -o jsonpath='{.data.CLUSTER_NAME}' 2>"$ERR")" \
  || { echo "✗ could not read flux-system/cluster-identity through $KCFG: $(api_err)" >&2; exit 1; }
[ "$live" = "$CID" ] || { echo "✗ the kubeconfig reaches cluster '${live:-unnamed}', not $CID: nothing was started" >&2; exit 1; }

T0="$(date +%s)"
for s in "${STEPS[@]}"; do [ -z "${SKIP[$s]:-}" ] || mark "$s" "NOT TAKEN" "--without"; done
# Each step runs in this shell (CLUSTERS and SEG carry to the next ones); its message goes through a file, not $().
call() { "$@" >"$ERR.out"; local r=$?; m="$(cat "$ERR.out")"; return "$r"; }
# The independent backups start together, then each is waited for.
for s in openbao dump etcd; do
  [ -z "${RES[$s]:-}" ] || continue
  if call start_job "$s"; then RES[$s]=started; else mark "$s" FAILED "$m"; fi
done
if [ -z "${RES[base]:-}" ]; then if call start_base; then RES[base]=started; else mark base FAILED "$m"; fi; fi
for s in openbao dump etcd; do
  [ "${RES[$s]:-}" = started ] || continue
  if call wait_job "$s"; then mark "$s" OK "$m"; else mark "$s" FAILED "$m"; fi
done
if [ "${RES[base]:-}" = started ]; then if call wait_base; then mark base OK "$m"; else mark base FAILED "$m"; fi; fi
job_step() { start_job "$1" && wait_job "$1"; }
verify_step() { start_job verify && wait_job verify >/dev/null && check_verify; }
for s in wal replicate verify store state; do
  [ -z "${RES[$s]:-}" ] || continue
  d="${DEP[$s]:-}"; [ "$s" != verify ] || [ -n "${SKIP[replicate]:-}" ] || d=replicate
  if [ -n "$d" ] && [ "${RES[$d]}" != OK ]; then mark "$s" "NOT RUN" "step $d is ${RES[$d]}"; continue; fi
  case "$s" in wal) f=run_wal ;; replicate) f="job_step replicate" ;; verify) f=verify_step ;; store) f=run_store ;; state) f=run_state ;; esac
  # shellcheck disable=SC2086
  if call $f; then mark "$s" OK "$m"; else mark "$s" FAILED "$m"; fi
done
rm -f "$ERR.out"

say ""; say "── receipt: final backups of $CID, $(date -u -d "@$T0" +%Y-%m-%dT%H:%M:%SZ) to $(date -u +%H:%M:%SZ)"
failed=()
for s in "${STEPS[@]}"; do
  printf '  %-10s %-10s %s\n' "$s" "${RES[$s]}" "${NOTE[$s]}"
  case "${RES[$s]}" in OK | "NOT TAKEN") ;; *) failed+=("$s") ;; esac
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "✗ RESULT: INCOMPLETE — ${failed[*]} did not complete: do NOT destroy. Fix it and run again (an earlier final-* Job or Backup is replaced)." >&2
  exit 1
fi
not=""; for s in "${STEPS[@]}"; do [ "${RES[$s]}" != "NOT TAKEN" ] || not="$not $s"; done
say "✓ RESULT: COMPLETE$([ -z "$not" ] || echo " except what --without left out:$not")"
