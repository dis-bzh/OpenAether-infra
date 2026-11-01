#!/usr/bin/env bash
# scripts/ops/dr-restore-plan.sh (task dr-restore-plan), offline: the recovery chain in order with a check after each step, against a
# stateful kubectl double (testdata/fake-kubectl-dr.py) and stub task/restic/talosctl. Dry-run runs nothing; --execute needs the cluster
# name; a failing check stops the chain; no secret reaches argv, the output or the double's call log; the timing report is written.
# What this cannot show: that the real kubectl, restic, talosctl and OpenBao do what the doubles do (docs/disaster-recovery.md says what
# is proven). SUT overrides the script (mutants).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/dr-restore-plan.sh}"
TMP="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 2; }

# The script derives its root from its own path: a copy in a tree that has the real lib and an envs sandbox.
mkdir -p "$TMP/tree/scripts/ops" "$TMP/tree/scripts/lib" "$TMP/tree/infrastructure/opentofu/cluster/envs" "$TMP/bin"
cp "$SUT" "$TMP/tree/scripts/ops/dr-restore-plan.sh"; cp "$ROOT"/scripts/lib/*.sh "$TMP/tree/scripts/lib/"
DR="$TMP/tree/scripts/ops/dr-restore-plan.sh"
cat >"$TMP/tree/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars" <<'TF'
cluster_name = "oa-test"
environment = "prod"
bucket_suffix = "zz"
deploy_flux = false
s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
s3_primary_region = "fr-par"
s3_replica_endpoint = "https://s3.gra.io.cloud.ovh.net"
s3_replica_region = "gra"
node_distribution = {
  scaleway = {
    control_planes = 3
    workers        = 3
  }
}
TF
export OA_ENVS_DIR="$TMP/tree/infrastructure/opentofu/cluster/envs"
cp "$OA_ENVS_DIR/management-scaleway.tfvars" "$TMP/tfvars.orig"

# stubs
cp "$ROOT/scripts/dev/testdata/fake-kubectl-dr.py" "$TMP/bin/kubectl"; chmod +x "$TMP/bin/kubectl"
cat >"$TMP/bin/task" <<'STUB'
#!/usr/bin/env bash
echo "task $*" >>"$FAKE_DR/calls.log"
case "$1" in
  restore-artifacts)
    for a in "$@"; do case "$a" in OUT=*) o="${a#OUT=}"; mkdir -p "$o"; echo "apiVersion: v1" >"$o/kubeconfig"; echo "context: x" >"$o/talosconfig" ;; esac; done ;;
  cluster-up) [ -z "${FAKE_FAIL_CLUSTER:-}" ] || exit 7
    [ -z "${FAKE_NEW_IDENTITY:-}" ] || { echo "apiVersion: v1 # NEW-PKI" >infrastructure/opentofu/cluster/kubeconfig; echo "context: new # NEW-PKI" >infrastructure/opentofu/cluster/talosconfig; } ;;
esac
exit 0
STUB
cat >"$TMP/bin/restic" <<'STUB'
#!/usr/bin/env bash
# restic -r REPO restore latest --host H --target DIR ; the password is read from the file, the keys from the environment
echo "restic $* | passfile=${RESTIC_PASSWORD_FILE:+set} ak=${AWS_ACCESS_KEY_ID:+set} region=${AWS_DEFAULT_REGION:-}" >>"$FAKE_DR/calls.log"
repo="$2"; target=""; while [ $# -gt 0 ]; do [ "$1" = --target ] && target="$2"; shift; done
mkdir -p "$target/backup"
case "$repo" in
  */openbao) head -c 3000 /dev/zero | tr '\0' 's' >"$target/backup/openbao-raft.snap" ;;
  */cnpg) for d in zitadel-db grafana-db; do head -c 500 /dev/zero | tr '\0' 'd' >"$target/backup/$d.dump"; done ;;
  */etcd) head -c "${FAKE_ETCD_SIZE:-8224}" /dev/zero >"$target/backup/etcd.snap" ;;
esac
STUB
cat >"$TMP/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
echo "talosctl $*" >>"$FAKE_DR/calls.log"
[ "$1 $2" = "--talosconfig x" ] && true
case "$*" in *"config info"*) echo "{\"endpoints\":[\"${FAKE_TALOS_ENDPOINT:-203.0.113.10}\"]}" ;; esac
exit 0
STUB
cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
# aws s3api list-objects-v2 --bucket B --prefix P --delimiter / ... : the "directories" under FAKE_STORES/B/P (no network, no secret in the log)
b=""; p=""; ep=""; while [ $# -gt 0 ]; do case "$1" in --bucket) b="$2" ;; --prefix) p="$2" ;; --endpoint-url) ep="$2" ;; esac; shift; done
echo "aws s3api bucket=$b prefix=$p endpoint=$ep ak=${AWS_ACCESS_KEY_ID:+set}" >>"$FAKE_DR/calls.log"
case "$b" in *"${FAKE_AWS_FAIL:-@@none@@}") echo "An error occurred (AccessDenied)" >&2; exit 254 ;; esac
d="$FAKE_STORES/$b/$p"; [ -d "$d" ] || { echo None; exit 0; }
out=""; for x in "$d"*/; do [ -d "$x" ] && out="${out:+$out	}${p}$(basename "$x")/"; done
echo "${out:-None}"
STUB
chmod +x "$TMP/bin/task" "$TMP/bin/restic" "$TMP/bin/talosctl" "$TMP/bin/aws"
export PATH="$TMP/bin:$PATH" OA_DR_TASK=task OA_DR_POLL=0 OA_DR_WAIT_TRIES=3
export SCW_AWS_ACCESS_KEY_ID=AKIAEXAMPLE SCW_AWS_SECRET_ACCESS_KEY=secretvalue OVH_AWS_ACCESS_KEY_ID=ovhak OVH_AWS_SECRET_ACCESS_KEY=ovhsk
export TF_VAR_encryption_passphrase="a-passphrase-long-enough-to-be-accepted-32+"
SEAL="$TMP/seal.key"; head -c 32 /dev/urandom | base64 >"$SEAL"
RPW="$TMP/restic.pw"; echo "RESTIC-PASSWORD-CANARY-9f3" >"$RPW"
TOK="$TMP/token"; echo "BAO-TOKEN-CANARY-77a" >"$TOK"
SH="$TMP/shares"; mkdir -p "$SH"; for i in 1 2 3; do echo "share-$i-CANARY" >"$SH/openbao-share-$i.b64"; done
ALL=(--seal-key-file "$SEAL" --restic-password-file "$RPW" --bao-token-file "$TOK" --recovery-shares-dir "$SH")

PB=s3-oa-zz-scaleway-backups-prod; RB="$PB-backup"     # the primary and the replica bucket of the test tfvars
store() { mkdir -p "$FAKE_STORES/$1/cnpg/$2/$3"; }       # <bucket> <cluster> <serverName>: an archive generation in a store
new() { # fresh double state and work dir; sets FAKE_DR, OUTD; the stores hold the dead cluster's archive (generation 1) on both sides
  FAKE_DR="$TMP/dr.$RANDOM"; mkdir -p "$FAKE_DR"; export FAKE_DR; OUTD="$TMP/out.$RANDOM"
  FAKE_STORES="$TMP/stores.$RANDOM"; export FAKE_STORES
  for b in "$PB" "$RB"; do for c in zitadel-db grafana-db; do store "$b" "$c" "$c"; done; done
  cp "$TMP/tfvars.orig" "$OA_ENVS_DIR/management-scaleway.tfvars"; rm -f "$OA_ENVS_DIR"/*.dr-bak
}
run() { bash "$DR" scaleway --out "$OUTD" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; RC=$?; }
calls() { cat "$FAKE_DR/calls.log" 2>/dev/null; }
order() { # every pattern appears in calls.log, in this order
  local last=0 n p
  for p in "$@"; do n="$(calls | awk -v l="$last" -v p="$p" 'NR > l && $0 ~ p { print NR; exit }')"; [ -n "$n" ] || { echo "out of order or missing: $p" >&2; return 1; }; last="$n"; done
}

echo "=== arguments ==="
new; bash "$DR" >/dev/null 2>&1; chk "no provider: usage, exit 2" "[ $? = 2 ]"
run --bogus; chk "an unknown flag is refused (exit 2)" "[ $RC = 2 ]"
run --scenario sideways; chk "an unknown scenario is refused" "[ $RC = 2 ]"
run --only nonsense; chk "an unknown step is refused" "[ $RC = 2 ] && grep -q 'not a step' '$TMP/stderr'"
OA_ENVS_DIR="$TMP/none" bash "$DR" scaleway >/dev/null 2>"$TMP/stderr"; chk "no tfvars: refused with the way out" "[ $? = 1 ] && grep -q 'no .*tfvars' '$TMP/stderr'"

echo "=== dry-run (the default) ==="
new; run "${ALL[@]}"
chk "exit 0 and every step of the chain is printed" "[ $RC = 0 ] && for s in artifacts cluster seedkey flux hold generation openbao shares resume dbs identity verify; do grep -q \"── step \$s:\" '$TMP/stdout' || exit 1; done"
chk "the commands name THIS cluster's store and repositories" "grep -q 's3:https://s3.fr-par.scw.cloud/s3-oa-zz-scaleway-backups-prod/oa-test-prod-scaleway/openbao' '$TMP/stdout' && grep -q 'FROM=primary' '$TMP/stdout'"
chk "it says it is a dry-run and that nothing ran" "grep -q 'MODE: DRY-RUN' '$TMP/stdout'"
chk "nothing was run: no stub was called, no directory created" "[ ! -s '$FAKE_DR/calls.log' ] && [ ! -e '$OUTD' ]"
chk "the targets and the RTO are stated, with the RPO of each data set" "grep -q '480 min RTO' '$TMP/stdout' && grep -q 'RPO' '$TMP/stdout'"
chk "the report table has every step as dry-run" "[ \"\$(grep -c ' dry-run ' '$TMP/stdout')\" = 12 ]"
run "${ALL[@]}" --from replica
chk "--from replica reads the -backup bucket on the replica endpoint with the replica store's keys" "grep -q 's3:https://s3.gra.io.cloud.ovh.net/s3-oa-zz-scaleway-backups-prod-backup/oa-test-prod-scaleway/openbao' '$TMP/stdout'"

echo "=== missing inputs ==="
new; run; chk "without inputs: exit 0 (a plan to read), the missing ones listed" "[ $RC = 0 ] && grep -q 'needs: --seal-key-file' '$TMP/stdout' && grep -q 'needs: --bao-token-file' '$TMP/stdout' && grep -q 'needs: --recovery-shares-dir' '$TMP/stdout'"
run --strict; chk "--strict turns them into an error" "[ $RC = 1 ]"
run "${ALL[@]}" --strict; chk "--strict passes when everything is in place" "[ $RC = 0 ]"
sed -i 's/^deploy_flux = false/deploy_flux = true/' "$OA_ENVS_DIR/management-scaleway.tfvars"
run "${ALL[@]}" --strict; chk "deploy_flux = true is a missing input of the cluster step (Flux would race the seal key)" "[ $RC = 1 ] && grep -q 'deploy_flux = false' '$TMP/stdout'"
new; run "${ALL[@]}" --only etcd-fetch --scenario etcd --restic-password-file /nonexistent --strict
chk "a restic password file that is not there is a missing input" "[ $RC = 1 ] && grep -q 'restic-password-file' '$TMP/stdout'"

echo "=== --execute is guarded ==="
new; run "${ALL[@]}" --execute; chk "no --confirm: refused, nothing run" "[ $RC = 2 ] && [ ! -s '$FAKE_DR/calls.log' ]"
run "${ALL[@]}" --execute --confirm other-cluster; chk "the wrong cluster name: refused, nothing run" "[ $RC = 2 ] && [ ! -s '$FAKE_DR/calls.log' ] && grep -q 'oa-test' '$TMP/stderr'"

echo "=== the whole chain, in order ==="
new; run "${ALL[@]}" --execute --confirm oa-test
chk "exit 0 and the chain says complete" "[ $RC = 0 ] && grep -q 'chain complete' '$TMP/stdout'"
chk "the steps ran in the documented order" "order 'task restore-artifacts' 'task cluster-up' 'create secret generic openbao-seal-key' 'task cluster-up' 'patch kustomization' 'aws s3api' 'restic -r s3:.*/openbao' 'exec -i openbao-0' 'create secret generic openbao-recovery-shares' 'get externalsecret' 'isWALArchiver' 'pg_dump' 'pg_restore' 'task cluster-verify' 'pg_switch_wal' 'create job --from=cronjob/cnpg-store-replicate' 'create job --from=cronjob/cnpg-recovery-restore-test'"
chk "the seal key Secret is created before Flux is switched on (the second cluster-up)" "[ \"\$(calls | grep -n 'create secret generic openbao-seal-key' | cut -d: -f1)\" -lt \"\$(calls | grep -n 'task cluster-up' | tail -1 | cut -d: -f1)\" ]"
chk "deploy_flux is true afterwards, and the previous file is kept next to it" "grep -q '^deploy_flux = true' '$OA_ENVS_DIR/management-scaleway.tfvars' && grep -q '^deploy_flux = false' '$OA_ENVS_DIR/management-scaleway.tfvars.dr-bak'"
chk "the held list excludes foundation-vault and what it needs, and includes identity" "! grep -qE '^(foundation-vault|namespaces|platform)\$' '$OUTD/work/held.txt' && grep -q '^identity\$' '$OUTD/work/held.txt' && grep -q '^cnpg\$' '$OUTD/work/held.txt'"
chk "everything held is suspended first, identity is resumed last" "head -n \$(wc -l <'$OUTD/work/held.txt') '$FAKE_DR/state/patches.log' | grep -q suspend && tail -n 2 '$FAKE_DR/state/patches.log' | grep -q '^identity'"
chk "the OpenBao restore received a token and the snapshot on stdin (3000 bytes)" "grep -q 'snapshot_bytes=3000' '$FAKE_DR/state/restore.log' && grep -q 'token_bytes=2[0-9]' '$FAKE_DR/state/restore.log'"
chk "the source's three shares are back" "grep -c 'share-' '$FAKE_DR/state/shares.json' | grep -q 1 && python3 -c \"import json; assert len(json.load(open('$FAKE_DR/state/shares.json')))==3\""
chk "both databases are recovered into a scratch Cluster from the ${STORE:-primary} ObjectStore, which never archives" "python3 - '$FAKE_DR/state/applied.jsonl' <<'PY'
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
assert [x['metadata']['name'] for x in c] == ['zitadel-db-dr', 'grafana-db-dr'], c
for x in c:
    assert 'plugins' not in x['spec'] and x['spec']['instances'] == 1
    assert x['spec']['externalClusters'][0]['plugin']['parameters']['barmanObjectName'].endswith('-primary')
PY"
chk "the dump of each scratch Cluster was loaded into the live primary" "[ \"\$(grep -c 'bytes=1005' '$FAKE_DR/state/pg_restore.log')\" = 2 ] && grep -q '^zitadel-db-1 ' '$FAKE_DR/state/pg_restore.log'"
chk "the scratch Clusters are deleted" "calls | grep -q 'delete clusters.postgresql.cnpg.io zitadel-db-dr' && calls | grep -q 'delete clusters.postgresql.cnpg.io grafana-db-dr'"
chk "the report is written with every step ok and a target" "[ \"\$(grep -c -P '\tok\t' '$OUTD/dr-report-'*.tsv)\" = 12 ] && head -1 '$OUTD/dr-report-'*.tsv | grep -q target_seconds"
chk "the report states the wall clock against the RTO" "grep -qE 'chain: [0-9]+s wall clock.*RTO target 28800s — within' '$TMP/stdout'"

echo "=== secrets stay out of argv and output ==="
chk "no secret value in the double's call log (argv)" "! calls | grep -qE 'RESTIC-PASSWORD-CANARY|BAO-TOKEN-CANARY|share-[0-9]-CANARY|secretvalue|ovhsk|$(head -c 20 "$SEAL" | sed 's/[^A-Za-z0-9]//g')'"
chk "no secret value in the output" "! cat '$TMP/stdout' '$TMP/stderr' | grep -qE 'RESTIC-PASSWORD-CANARY|BAO-TOKEN-CANARY|share-[0-9]-CANARY|secretvalue|ovhsk'"
chk "restic got its password as a file and its keys from the environment" "calls | grep -q 'passfile=set ak=set region=fr-par'"

echo "=== the CNPG archive generation (apps #153) ==="
cmget() { python3 -c "import json,sys; d=json.load(open('$FAKE_DR/state/cm-generation.json')); print(d['data'].get(sys.argv[1], d['metadata']['annotations'].get(sys.argv[1], 'MISSING')))" "$1"; }
new; run "${ALL[@]}" --execute --confirm oa-test
chk "the dead cluster's archive is generation 1: the rebuilt Clusters get the suffix -g2, the previous one is the bare name" "[ \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" = -g2 ] && [ -z \"\$(cmget CNPG_ARCHIVE_PREVIOUS_SUFFIX)\" ] && [ \"\$(cmget openaether.io/archive-generation)\" = 2 ]"
chk "both stores and both clusters were listed (the surviving store is not the only witness)" "[ \"\$(calls | grep -c '^aws s3api ')\" = 4 ] && calls | grep -q 'aws s3api bucket=$PB prefix=cnpg/zitadel-db/ ' && calls | grep -q 'aws s3api bucket=$RB prefix=cnpg/grafana-db/ '"
chk "the stores were only read, with the keys in the environment and not in argv" "calls | grep '^aws s3api ' | grep -q 'ak=set' && ! calls | grep -qE 'aws .*(secretvalue|ovhsk|AKIAEXAMPLE)'"
chk "the scratch recovery Clusters read the OLD path (the bare cluster name), never the new one" "python3 - '$FAKE_DR/state/applied.jsonl' <<'PY'
import json, sys
for l in open(sys.argv[1]):
    x = json.loads(l)
    assert x['spec']['externalClusters'][0]['plugin']['parameters']['serverName'] == x['metadata']['name'][:-3], x
PY"
chk "the load is archived: Flux gave the Clusters the new name before the data was loaded (step dbs asks)" "order 'task cluster-up' 'aws s3api' 'get externalsecret' 'isWALArchiver' 'pg_restore'"
chk "the new archive gets a base backup of each cluster, a segment switch, and a copy to the replica store before the restore test" "[ \"\$(wc -l <'$FAKE_DR/state/backups.jsonl')\" = 2 ] && grep -q '\"pluginConfiguration\"' '$FAKE_DR/state/backups.jsonl' && order 'pg_switch_wal' 'cnpg-store-replicate' 'cnpg-recovery-restore-test'"
new; store "$PB" zitadel-db zitadel-db-g2; store "$RB" zitadel-db zitadel-db-g2; store "$RB" grafana-db grafana-db-g2; store "$PB" grafana-db grafana-db-g2
run "${ALL[@]}" --execute --confirm oa-test --from replica
chk "a second rebuild finds generation 2 and archives as generation 3; the recovery reads -g2" "[ \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" = -g3 ] && [ \"\$(cmget CNPG_ARCHIVE_PREVIOUS_SUFFIX)\" = -g2 ] && python3 - '$FAKE_DR/state/applied.jsonl' <<'PY'
import json, sys
for l in open(sys.argv[1]):
    x = json.loads(l)
    assert x['spec']['externalClusters'][0]['plugin']['parameters']['serverName'] == x['metadata']['name'][:-3] + '-g2', x
PY"
new; store "$PB" zitadel-db zitadel-db-g4
run "${ALL[@]}" --execute --confirm oa-test --from replica
chk "a newer generation only in the PRIMARY store (the replica is behind) still counts: the new one is -g5, never an existing path" "[ \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" = -g5 ] && [ \"\$(cmget CNPG_ARCHIVE_PREVIOUS_SUFFIX)\" = -g4 ]"
new; FAKE_AWS_FAIL=backup run "${ALL[@]}" --execute --confirm oa-test --from replica
chk "the surviving store cannot be listed: the generation step fails, nothing after it ran (no OpenBao restore)" "[ $RC = 1 ] && grep -q '✗ generation FAILED' '$TMP/stdout' && cat '$TMP/stdout' '$TMP/stderr' | grep -q 'archive-generation N' && ! calls | grep -q 'restic -r' && [ ! -e '$FAKE_DR/state/cm-generation.json' ]"
new; FAKE_AWS_FAIL=prod run "${ALL[@]}" --execute --confirm oa-test --only generation --from replica
chk "the other store being unreadable (the dead provider) is only a note: the replica's listing decides" "[ $RC = 0 ] && cat '$TMP/stdout' '$TMP/stderr' | grep -q 'cannot be listed: its generations are not counted' && [ \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" = -g2 ]"
new; run "${ALL[@]}" --execute --confirm oa-test --only generation --archive-generation 7
chk "--archive-generation N sets it without listing the stores (no aws call), the previous one is N-1" "[ $RC = 0 ] && [ \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" = -g7 ] && [ \"\$(cmget CNPG_ARCHIVE_PREVIOUS_SUFFIX)\" = -g6 ] && ! calls | grep -q '^aws s3api '"
run "${ALL[@]}" --execute --confirm oa-test --only generation
chk "a re-run of the step keeps the recorded value (the new cluster may already have written its own path)" "[ $RC = 0 ] && grep -q 'kept, this is a re-run' '$TMP/stdout' && [ \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" = -g7 ]"
run "${ALL[@]}" --archive-generation 120; chk "a generation outside 1..99 is refused" "[ $RC = 2 ]"
new; rm -rf "$FAKE_STORES"; mkdir -p "$FAKE_STORES"; run "${ALL[@]}" --execute --confirm oa-test --only generation
chk "stores that hold no archive at all: generation 1, the empty suffix (the historical name), nothing moves" "[ $RC = 0 ] && [ -z \"\$(cmget CNPG_ARCHIVE_SUFFIX)\" ] && [ -z \"\$(cmget CNPG_ARCHIVE_PREVIOUS_SUFFIX)\" ]"
new; mkdir -p "$OUTD/work"; printf 'cnpg\nidentity\n' >"$OUTD/work/held.txt"; FAKE_APPLY_STALE=1 run "${ALL[@]}" --execute --confirm oa-test --from-step generation
chk "if Flux does not give the Clusters the new name, the load is NOT done into the old path (step dbs fails first)" "[ $RC = 1 ] && grep -q '✗ dbs FAILED' '$TMP/stdout' && grep -q 'not .zitadel-db-g2.' '$TMP/stdout' && ! cat '$FAKE_DR/state/pg_restore.log' 2>/dev/null | grep -q ."
new; mkdir -p "$OUTD/work"; printf 'cnpg\nidentity\n' >"$OUTD/work/held.txt"; FAKE_BACKUP_FAIL=1 run "${ALL[@]}" --execute --confirm oa-test --from-step generation
chk "a base backup of the new archive that does not complete fails the verify step" "[ $RC = 1 ] && grep -q '✗ verify FAILED' '$TMP/stdout' && grep -q 'base backup of the new archive did not complete' '$TMP/stdout'"
new; mkdir -p "$OUTD/work"; printf 'cnpg\nidentity\n' >"$OUTD/work/held.txt"; FAKE_NO_ARCHIVING=1 run "${ALL[@]}" --execute --confirm oa-test --from-step generation
chk "ContinuousArchiving not True on the rebuilt cluster fails the verify step (the lab 20 symptom is no longer silent)" "[ $RC = 1 ] && grep -q 'ContinuousArchiving is not True' '$TMP/stdout'"
new; run "${ALL[@]}"
chk "the dry-run explains the generation and where the old path stays" "grep -q 'step generation' '$TMP/stdout' && grep -q 'OLD path' '$TMP/stdout' && grep -q 'NEW serverName' '$TMP/stdout' && [ ! -s '$FAKE_DR/calls.log' ]"
mv "$TMP/bin/aws" "$TMP/bin/aws.off"; new; PATH="$TMP/bin:/usr/bin:/bin" run "${ALL[@]}" --only generation --strict
chk "without aws and without --archive-generation the step lists a missing input" "[ $RC = 1 ] && grep -q 'aws on PATH' '$TMP/stdout'"
PATH="$TMP/bin:/usr/bin:/bin" run "${ALL[@]}" --only generation --strict --archive-generation 2
chk "--archive-generation 2 needs no aws" "[ $RC = 0 ]"
mv "$TMP/bin/aws.off" "$TMP/bin/aws"

echo "=== a failing check stops the chain ==="
new; FAKE_BROKEN_CHAIN=1 run "${ALL[@]}" --execute --confirm oa-test
chk "a broken canary chain after the database load: exit 1, dbs failed" "[ $RC = 1 ] && grep -q '✗ dbs FAILED' '$TMP/stdout' && grep -q 'canary chain broken' '$TMP/stdout'"
chk "identity is NOT resumed and the later steps are skipped" "! grep -q '^identity resume' '$FAKE_DR/state/patches.log' && grep -q ' skipped ' '$TMP/stdout' && ! calls | grep -q 'task cluster-verify'"
chk "it says where to resume" "grep -q 'from-step dbs' '$TMP/stderr'"
chk "the report still lists every step" "[ \"\$(grep -c -P '\t(ok|failed|skipped)\t' '$OUTD/dr-report-'*.tsv)\" = 12 ]"
new; FAKE_FAIL_SECRET=1 run "${ALL[@]}" --execute --confirm oa-test
chk "a command that fails inside a step fails the step (errexit in the step's own shell): seedkey failed, nothing after it ran" "[ $RC = 1 ] && grep -q '✗ seedkey FAILED' '$TMP/stdout' && ! calls | grep -q 'restic -r'"
new; FAKE_FAIL_CLUSTER=1 run "${ALL[@]}" --execute --confirm oa-test
chk "a failing cluster-up stops before the seal key" "[ $RC = 1 ] && ! calls | grep -q 'openbao-seal-key'"
new; FAKE_NEW_IDENTITY=1 run "${ALL[@]}" --execute --confirm oa-test --only artifacts,cluster
chk "a new cluster's kubeconfig and talosconfig replace the restored ones (the PKI is new), the old ones stay as .old" "grep -q NEW-PKI '$OUTD/kubeconfig' && grep -q NEW-PKI '$OUTD/talosconfig' && [ -s '$OUTD/kubeconfig.old' ] && ! grep -q NEW-PKI '$OUTD/kubeconfig.old'"
new; FAKE_PG_RESTORE=inherited run "${ALL[@]}" --execute --confirm oa-test --only dbs
chk "pg_restore exiting 1 on the inherited-constraint errors of --clean alone (partitioned tables) does not fail the step" "[ $RC = 0 ] && grep -q 'tolerated' '$TMP/stdout'"
new; FAKE_PG_RESTORE=real run "${ALL[@]}" --execute --confirm oa-test --only dbs
chk "any other pg_restore error fails the step even next to the tolerated one" "[ $RC = 1 ]"
new; FAKE_NODES=2 run "${ALL[@]}" --execute --confirm oa-test --only cluster
chk "fewer nodes than the tfvars ask for fail the cluster check" "[ $RC = 1 ] && grep -q '2 nodes, 6 expected' '$TMP/stdout'"
new; FAKE_VERIFY_SKIP=1 run "${ALL[@]}" --execute --confirm oa-test --only verify
chk "a restore test that only skipped does not pass the verify step" "[ $RC = 1 ] && grep -q 'without proving anything' '$TMP/stderr' '$TMP/stdout'"
new; FAKE_VERIFY_FAIL=1 run "${ALL[@]}" --execute --confirm oa-test --only verify
chk "a failing restore test on the rebuilt cluster fails the last step" "[ $RC = 1 ] && grep -q 'restore test of the rebuilt cluster failed' '$TMP/stdout'"

echo "=== subsets and the other sources ==="
new; mkdir -p "$OUTD/work"; printf 'cnpg\nidentity\n' >"$OUTD/work/held.txt"
run "${ALL[@]}" --execute --confirm oa-test --from-step resume
chk "--from-step resume runs resume and everything after it, nothing before" "[ $RC = 0 ] && ! calls | grep -q 'task restore-artifacts' && calls | grep -q 'task cluster-verify' && grep -q '^cnpg resume' '$FAKE_DR/state/patches.log'"
new; mkdir -p "$OUTD/work"; printf 'cnpg\nidentity\n' >"$OUTD/work/held.txt"
run "${ALL[@]}" --execute --confirm oa-test --only dbs --db-source dump --from replica
chk "--db-source dump restores the cnpg dumps from the replica repository and loads them (no scratch Cluster)" "[ $RC = 0 ] && calls | grep -q 'restic -r s3:https://s3.gra.io.cloud.ovh.net/.*-backup/oa-test-prod-scaleway/cnpg' && [ ! -e '$FAKE_DR/state/applied.jsonl' ] && [ \"\$(grep -c 'bytes=500' '$FAKE_DR/state/pg_restore.log')\" = 2 ]"
new; run "${ALL[@]}" --execute --confirm oa-test --only dbs --from replica --pitr-time '2026-10-20 09:00:00+00'
chk "--pitr-time is the recovery target of the scratch Cluster, from the replica ObjectStore" "python3 - '$FAKE_DR/state/applied.jsonl' <<'PY'
import json, sys
for l in open(sys.argv[1]):
    x = json.loads(l)
    assert x['spec']['bootstrap']['recovery']['recoveryTarget']['targetTime'] == '2026-10-20 09:00:00+00'
    assert x['spec']['externalClusters'][0]['plugin']['parameters']['barmanObjectName'].endswith('-replica')
PY"

echo "=== scenario etcd ==="
new; run "${ALL[@]}" --scenario etcd
chk "dry-run shows the four steps and the recovery command" "[ $RC = 0 ] && grep -q 'bootstrap --recover-from' '$TMP/stdout' && grep -q '── step etcd-recover' '$TMP/stdout' && ! grep -q '── step openbao' '$TMP/stdout'"
new; FAKE_ETCD_SIZE=8192 run "${ALL[@]}" --scenario etcd --execute --confirm oa-test
chk "a snapshot of 4096n bytes (no trailer) is recovered with --recover-skip-hash-check" "[ $RC = 0 ] && calls | grep -q 'bootstrap --recover-from=.*--recover-skip-hash-check'"
new; FAKE_ETCD_SIZE=8224 run "${ALL[@]}" --scenario etcd --execute --confirm oa-test
chk "a snapshot of 4096n + 32 bytes (sha256 trailer) is recovered WITHOUT skipping the hash check" "[ $RC = 0 ] && calls | grep -q 'bootstrap --recover-from=' && ! calls | grep -q 'skip-hash-check'"
new; FAKE_ETCD_SIZE=8224 FAKE_TALOS_ENDPOINT=127.0.0.1:52000 run "${ALL[@]}" --scenario etcd --execute --confirm oa-test
chk "a tunnel endpoint is refused as the node: the address of the control plane is asked for" "[ $RC = 1 ] && ! calls | grep -q 'talosctl.*bootstrap' && grep -q -- '--control-plane-ip' '$TMP/stdout' '$TMP/stderr'"
new; FAKE_ETCD_SIZE=8224 FAKE_TALOS_ENDPOINT=127.0.0.1:52000 run "${ALL[@]}" --scenario etcd --execute --confirm oa-test --control-plane-ip 172.16.0.3
chk "behind a tunnel the node is the given address and the endpoint stays the tunnel" "[ $RC = 0 ] && calls | grep -q 'talosctl.* -n 172.16.0.3 -e 127.0.0.1:52000 bootstrap --recover-from='"
chk "after the etcd restore the Cilium agents and operator are restarted (their watches predate the restored revision)" "calls | grep -q 'rollout restart ds/cilium deploy/cilium-operator'"
new; FAKE_ETCD_SIZE=1000 run "${ALL[@]}" --scenario etcd --execute --confirm oa-test
chk "a file that is not a bolt database stops the chain before talosctl is called" "[ $RC = 1 ] && ! calls | grep -q 'talosctl.*bootstrap'"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
