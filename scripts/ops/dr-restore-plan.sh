#!/usr/bin/env bash
# ==============================================================================
# OpenAether — the disaster-recovery chain, in order, with a check after each step and a timing report.
#
# docs/disaster-recovery.md section 3 is the reference; this script is that table as a command. It does NOT add a mechanism: every
# step calls something that exists (task restore-artifacts, task cluster-up, restic, kubectl, talosctl). What it adds is the order,
# a check after each step that stops the chain at the first failure, and the clock: the first time the chain is run, the numbers
# replace the proposed targets. What OpenTofu manages stays OpenTofu (task cluster-up); what runs in the cluster is restored in it.
#
#   scenario rebuild (default)  the cluster is gone: new cluster, then the data, one brick at a time
#   scenario etcd               the cluster is rebuilt in place from an etcd snapshot (talosctl bootstrap --recover-from)
#
# DRY-RUN IS THE DEFAULT: it prints every step with the exact commands for THIS cluster, the inputs each step needs and which of them
# are missing, runs nothing, changes nothing. Run it before the day you need it (--strict makes a missing input an error). --execute
# runs the chain and needs --confirm <cluster_name>: a command typed against the wrong environment refuses instead of restoring there.
#
# Usage:
#   dr-restore-plan.sh <provider> [--role management] [--from primary|replica] [--scenario rebuild|etcd]
#                      [--db-source pitr|dump] [--pitr-time 'YYYY-MM-DD HH:MM:SS+00']
#                      [--seal-key-file F] [--restic-password-file F] [--bao-token-file F] [--recovery-shares-dir D]
#                      [--out DIR] [--work DIR] [--report FILE] [--only a,b] [--from-step a] [--strict]
#                      [--execute --confirm <cluster_name>]
#
# Secrets are only ever read from files and passed on stdin or as file arguments, never in argv or in the output.
# Needs (execute): task, kubectl, restic, python3; talosctl for the etcd scenario; the passphrase and the surviving store's keys as for
# task restore-artifacts. Rung of the whole chain: offline tests with stubs; NOT run on a cluster (docs/disaster-recovery.md says what).
# ==============================================================================
set -euo pipefail

usage() { sed -n '/^# Usage:/,/^# Secrets/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -n -1; }
PROVIDER="${1:-}"
case "$PROVIDER" in "" | -h | --help) usage >&2; exit 2 ;; esac
shift
ROLE=management; FROM=primary; SCENARIO=rebuild; DBSRC=pitr; PITR=""
SEALKEY=""; RPW=""; BAOTOK=""; SHARES=""; OUT=""; WORK=""; REPORT=""; ONLY=""; FROMSTEP=""; STRICT=0; EXECUTE=0; CONFIRM=""
need_arg() { [ $# -ge 2 ] || { echo "✗ $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --role) need_arg "$@"; ROLE="$2"; shift 2 ;;
    --from) need_arg "$@"; FROM="$2"; shift 2 ;;
    --scenario) need_arg "$@"; SCENARIO="$2"; shift 2 ;;
    --db-source) need_arg "$@"; DBSRC="$2"; shift 2 ;;
    --pitr-time) need_arg "$@"; PITR="$2"; shift 2 ;;
    --seal-key-file) need_arg "$@"; SEALKEY="$2"; shift 2 ;;
    --restic-password-file) need_arg "$@"; RPW="$2"; shift 2 ;;
    --bao-token-file) need_arg "$@"; BAOTOK="$2"; shift 2 ;;
    --recovery-shares-dir) need_arg "$@"; SHARES="$2"; shift 2 ;;
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --work) need_arg "$@"; WORK="$2"; shift 2 ;;
    --report) need_arg "$@"; REPORT="$2"; shift 2 ;;
    --only) need_arg "$@"; ONLY="$2"; shift 2 ;;
    --from-step) need_arg "$@"; FROMSTEP="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    --dry-run) EXECUTE=0; shift ;;
    --confirm) need_arg "$@"; CONFIRM="$2"; shift 2 ;;
    *) echo "✗ unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$FROM" in primary | replica) ;; *) echo "✗ --from must be primary or replica" >&2; exit 2 ;; esac
case "$SCENARIO" in rebuild | etcd) ;; *) echo "✗ --scenario must be rebuild or etcd" >&2; exit 2 ;; esac
case "$DBSRC" in pitr | dump) ;; *) echo "✗ --db-source must be pitr or dump" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
TFVARS="${OA_ENVS_DIR:-$CLUSTER_DIR/envs}/${ROLE}-${PROVIDER}.tfvars"   # OA_ENVS_DIR: a test sandbox
[ -f "$TFVARS" ] || { echo "✗ no $TFVARS — rebuild it from the .example with the cluster name, environment, bucket_suffix and replica endpoint first" >&2; exit 1; }
CN="$(tfv "$TFVARS" cluster_name)"; ENVN="$(tfv "$TFVARS" environment)"
[ -n "$CN" ] && [ -n "$ENVN" ] || { echo "✗ could not read cluster_name/environment from ${TFVARS##*/}" >&2; exit 1; }
PRIM_EP="$(tfv "$TFVARS" s3_primary_endpoint)"; PRIM_REGION="$(tfv "$TFVARS" s3_primary_region)"
REPL_EP="$(tfv "$TFVARS" s3_replica_endpoint)"; REPL_REGION="$(tfv "$TFVARS" s3_replica_region)"
DEPLOY_FLUX="$(tfv "$TFVARS" deploy_flux)"
CPS="$(tfv "$TFVARS" control_planes)"; WKS="$(tfv "$TFVARS" workers)"
NODES_EXPECTED=""; { [[ "$CPS" =~ ^[0-9]+$ ]] && [[ "$WKS" =~ ^[0-9]+$ ]]; } && NODES_EXPECTED=$((CPS + WKS))
# The restic prefix is CLUSTER_NAME of the cluster-identity ConfigMap, which OpenTofu sets to "<cluster_name>-<environment>-<provider>"
# (main.tf cluster_id), NOT the bare cluster_name of the tfvars (lab 20: the repositories were looked for under "openaether").
CID="${CN}-${ENVN}-${PROVIDER}"
PROJECT="$(oa_project "$CN" "$(tfv "$TFVARS" bucket_suffix)")"
BKT="$(oa_backup_bucket "$PROJECT" "$PROVIDER" "$ENVN")"          # restic (OpenBao, CNPG dumps, etcd) and Longhorn
if [ "$FROM" = replica ]; then
  BKT="${BKT}-backup"; EP="${REPL_EP:-$PRIM_EP}"; REGION="${REPL_REGION:-$PRIM_REGION}"; KIND=backup; STORE=replica
else
  EP="$PRIM_EP"; REGION="$PRIM_REGION"; KIND=primary; STORE=primary
fi
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-$CLUSTER_DIR/dr-$CN}"
WORK="${WORK:-$OUT/work}"
REPORT="${REPORT:-$OUT/dr-report-$TS.tsv}"
KCFG="$OUT/kubeconfig"; TCFG="$OUT/talosconfig"
TASK="${OA_DR_TASK:-task}"
K() { kubectl --kubeconfig "$KCFG" "$@"; }

# Targets, in minutes, from docs/disaster-recovery.md section 3 (proposed, not measured). Their sum is checked against RTO_MIN.
RTO_MIN=480
declare -A TARGET=([artifacts]=30 [cluster]=120 [seedkey]=15 [flux]=15 [hold]=5 [openbao]=60 [shares]=15 [resume]=15 [dbs]=60 [identity]=30 [verify]=30
                   [etcd-fetch]=15 [etcd-recover]=30 [etcd-check]=15)
declare -A TITLE=(
  [artifacts]="Access to the old cluster's identity (talosconfig, kubeconfig) from the ${STORE} store"
  [cluster]="New cluster (task cluster-up), Flux held (deploy_flux = false)"
  [seedkey]="OpenBao seal key Secret from the escrow, BEFORE any OpenBao pod exists"
  [flux]="Flux on (deploy_flux = true, task cluster-up again), OpenBao deployed and initialised empty"
  [hold]="Hold every Kustomization outside OpenBao's own dependency closure"
  [openbao]="OpenBao raft snapshot: restic restore from the ${STORE} store, then bao operator raft snapshot restore"
  [shares]="The source cluster's recovery shares back"
  [resume]="Resume the held Kustomizations except identity; External Secrets rebuilds every Secret from the restored OpenBao"
  [dbs]="Databases: restore into the empty Clusters (${DBSRC}${PITR:+ to $PITR})"
  [identity]="Resume identity and the rest; wait for the whole DAG"
  [verify]="Verify: cluster-verify, a backup run, a restore test on the rebuilt cluster"
  [etcd-fetch]="etcd snapshot: restic restore of the newest one from the ${STORE} store"
  [etcd-recover]="talosctl bootstrap --recover-from on the control plane that lost its etcd"
  [etcd-check]="etcd members healthy, Kubernetes API up, Flux reconciles"
)
declare -A DESTRUCTIVE=([openbao]=1 [shares]=1 [dbs]=1 [etcd-recover]=1)
if [ "$SCENARIO" = rebuild ]; then STEPS=(artifacts cluster seedkey flux hold openbao shares resume dbs identity verify)
else STEPS=(artifacts etcd-fetch etcd-recover etcd-check); fi

# ── the clock and the report ──────────────────────────────────────────────────────────────────────────────────────────────
NOW_S() { date +%s; }
ROWS=()   # id <TAB> status <TAB> seconds <TAB> target seconds <TAB> note
STOPPED=""
say() { printf '%s\n' "$*"; }

# ── inputs each step needs; `needs_<id>` prints one missing input per line ──────────────────────────────────────────────────
missing_file() { # <flag> <path> <what>
  [ -n "$2" ] && [ -s "$2" ] || echo "$1 <file>: $3"
}
needs_artifacts() {
  [ -n "${TF_VAR_artifact_passphrase:-}${TF_VAR_encryption_passphrase:-}" ] || echo "TF_VAR_encryption_passphrase (or TF_VAR_artifact_passphrase): the key that decrypts the artifacts (K5)"
  s3_creds_missing
}
s3_creds_missing() {
  local ak sk
  ak="$(s3_cred "$PROVIDER" "$KIND" ak "$EP" 2>/dev/null || true)"; sk="$(s3_cred "$PROVIDER" "$KIND" sk "$EP" 2>/dev/null || true)"
  { [ -n "$ak" ] && [ -n "$sk" ]; } || echo "S3 keys of the ${STORE} store (${EP:-no endpoint in the tfvars}): the surviving store's, as for task restore-artifacts"
}
needs_cluster() {
  command -v "${TASK%% *}" >/dev/null 2>&1 || echo "task on PATH"
  [ "$DEPLOY_FLUX" = false ] || echo "deploy_flux = false in ${TFVARS##*/} (now '${DEPLOY_FLUX:-unset}'): Flux must not race the seal key Secret"
}
needs_seedkey() { missing_file --seal-key-file "$SEALKEY" "the escrowed OpenBao seal key, decrypted (gpg -d openbao-seal-key.gpg), outside any repository"; }
needs_flux() { :; }
needs_hold() { :; }
needs_openbao() {
  missing_file --restic-password-file "$RPW" "the escrowed restic password"
  missing_file --bao-token-file "$BAOTOK" "a break-glass root token of the FRESH cluster (a quorum of share holders)"
  command -v restic >/dev/null 2>&1 || echo "restic on PATH"
  s3_creds_missing
}
needs_shares() { [ -d "$SHARES" ] && ls "$SHARES"/openbao-share-*.b64 >/dev/null 2>&1 || echo "--recovery-shares-dir <dir> holding openbao-share-N.b64 (the SOURCE cluster's, saved at install)"; }
needs_resume() { :; }
needs_dbs() {
  if [ "$DBSRC" = dump ]; then
    missing_file --restic-password-file "$RPW" "the escrowed restic password"; command -v restic >/dev/null 2>&1 || echo "restic on PATH"; s3_creds_missing
  fi
}
needs_identity() { :; }
needs_verify() { :; }
needs_etcd-fetch() { missing_file --restic-password-file "$RPW" "the escrowed restic password"; command -v restic >/dev/null 2>&1 || echo "restic on PATH"; s3_creds_missing; }
needs_etcd-recover() { command -v talosctl >/dev/null 2>&1 || echo "talosctl on PATH"; [ -s "$TCFG" ] || [ "$EXECUTE" = 0 ] || echo "a talosconfig (step artifacts)"; }
needs_etcd-check() { :; }

# ── restic ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
restic_env() { # runs "$@" with the surviving store's keys and the repository password; nothing in argv
  AWS_ACCESS_KEY_ID="$(s3_cred "$PROVIDER" "$KIND" ak "$EP")" AWS_SECRET_ACCESS_KEY="$(s3_cred "$PROVIDER" "$KIND" sk "$EP")" \
    AWS_DEFAULT_REGION="$REGION" RESTIC_PASSWORD_FILE="$RPW" "$@"
}
repo() { printf 's3:%s/%s/%s/%s' "$EP" "$BKT" "$CID" "$1"; }

# ── show_<id>: the commands, as the operator would type them ────────────────────────────────────────────────────────────────
show_artifacts() { say "  \$ $TASK restore-artifacts PROVIDER=$PROVIDER ROLE=$ROLE FROM=$FROM OUT=$OUT"; say "  check: kubeconfig and talosconfig exist in $OUT"; }
show_cluster() {
  say "  \$ $TASK cluster-up PROVIDER=$PROVIDER ROLE=$ROLE        # with deploy_flux = false in ${TFVARS##*/}"
  say "  check: the API answers and every node is Ready (${NODES_EXPECTED:-all})"
}
show_seedkey() {
  say "  \$ kubectl create namespace foundation-vault"
  say "  \$ kubectl -n foundation-vault create secret generic openbao-seal-key --from-file=key=<--seal-key-file>"
  say "  check: the Secret exists and is not empty; delete the decrypted file afterwards"
}
show_flux() {
  say "  \$ set deploy_flux = true in ${TFVARS##*/} (a .dr-bak copy is kept), then $TASK cluster-up PROVIDER=$PROVIDER ROLE=$ROLE"
  say "  check: the openbao-0 pod is Running and the Job openbao-init is Complete (empty, initialised OpenBao)"
}
show_hold() {
  say "  \$ kubectl -n flux-system patch kustomization <every one outside the dependency closure of foundation-vault> --type merge -p '{\"spec\":{\"suspend\":true}}'"
  say "  check: the held list is written to $WORK/held.txt; UNPROVEN join: the held ones must be suspended before foundation-vault is Ready"
}
show_openbao() {
  say "  \$ restic -r $(repo openbao) restore latest --host openbao --target $WORK/openbao      # password from --restic-password-file"
  say "  \$ kubectl -n foundation-vault exec -i openbao-0 -- sh -c 'read token; … bao operator raft snapshot restore -force /tmp/dr.snap'   # token and snapshot on stdin"
  say "  check: bao status says initialised and unsealed; standbys follow (openbao-1 and openbao-2 are deleted once if they do not)"
}
show_shares() {
  say "  \$ kubectl -n foundation-vault delete secret openbao-recovery-shares ; kubectl -n foundation-vault create secret generic openbao-recovery-shares --from-file=share-N=<dir>/openbao-share-N.b64 …"
  say "  check: the Secret holds as many shares as the directory"
}
show_resume() {
  say "  \$ kubectl -n flux-system patch kustomization <the held ones except identity*> --type merge -p '{\"spec\":{\"suspend\":false}}'"
  say "  check: every ExternalSecret is Ready (the Secrets, the restic password and zitadel-masterkey included) within 15 minutes"
}
show_dbs() {
  if [ "$DBSRC" = pitr ]; then
    say "  \$ for zitadel-db, grafana-db: apply a Cluster <name>-dr (1 instance) that recovers from the ObjectStore <name>-${STORE}${PITR:+ at $PITR}"
    say "  \$ kubectl exec <name>-dr-1 -- pg_dump -Fc | kubectl exec -i <name>-1 -- pg_restore --clean --if-exists --no-owner   # into the empty Cluster"
  else
    say "  \$ restic -r $(repo cnpg) restore latest --host cnpg --target $WORK/cnpg"
    say "  \$ kubectl exec -i <name>-1 -- pg_restore --clean --if-exists --no-owner < $WORK/cnpg/…/<name>.dump      # RPO 24 h, no archive needed"
  fi
  say "  check: the canary chain of each restored database is intact and its newest row is dated; the scratch Clusters are removed"
}
show_identity() { say "  \$ kubectl -n flux-system patch kustomization <identity*, then the rest> --type merge -p '{\"spec\":{\"suspend\":false}}'"; say "  check: no Kustomization is NotReady within 30 minutes"; }
show_verify() {
  say "  \$ $TASK cluster-verify PROVIDER=$PROVIDER ROLE=$ROLE"
  say "  \$ kubectl -n foundation-databases create job --from=cronjob/cnpg-recovery-restore-test dr-check ; wait for it"
  say "  check: both pass (the rebuilt cluster restores its own backups); then log in to each UI by hand and re-seed what lives outside OpenBao"
}
show_etcd-fetch() { say "  \$ restic -r $(repo etcd) restore latest --host etcd --target $WORK/etcd"; say "  check: a file of the snapshot exists, a bolt database (size is a multiple of 4096, or 4096n + 32 with a sha256 trailer)"; }
show_etcd-recover() {
  say "  \$ talosctl --talosconfig $TCFG -n <control-plane IP> -e <control-plane IP> bootstrap --recover-from=<snapshot> [--recover-skip-hash-check]"
  say "  note: the node must have no etcd data (wiped or new); this REPLACES the etcd of the cluster and drops everything written since the snapshot"
}
show_etcd-check() { say "  \$ talosctl etcd members ; kubectl get nodes ; kubectl -n flux-system get kustomization"; say "  check: 3 members (or the control plane count), nodes Ready"; }

# ── run_<id>: execute ──────────────────────────────────────────────────────────────────────────────────────────────────────
HELD="$WORK/held.txt"
run_artifacts() { mkdir -p "$OUT"; ( cd "$ROOT" && $TASK restore-artifacts PROVIDER="$PROVIDER" ROLE="$ROLE" FROM="$FROM" OUT="$OUT" FORCE=1 ); }
check_artifacts() { [ -s "$KCFG" ] && [ -s "$TCFG" ] || { echo "kubeconfig or talosconfig missing in $OUT"; return 1; }; }

# A cluster brought up AFTER its state was destroyed has a new PKI: the kubeconfig and talosconfig restored from the old cluster's artifacts
# (step artifacts) no longer open it (lab 20: "the API does not answer" on a healthy cluster). After each cluster-up the chain takes the
# identity OpenTofu has just written; the old files stay as *.old.
refresh_identity() {
  local f
  for f in kubeconfig talosconfig; do
    [ -s "$CLUSTER_DIR/$f" ] || continue
    cmp -s "$CLUSTER_DIR/$f" "$OUT/$f" 2>/dev/null && continue
    [ -s "$OUT/$f" ] && cp -p "$OUT/$f" "$OUT/$f.old"
    cp -p "$CLUSTER_DIR/$f" "$OUT/$f"; chmod 600 "$OUT/$f"
    say "  ($f of the new cluster taken from ${CLUSTER_DIR##*/infrastructure/}; the restored one is $f.old)"
  done
}
run_cluster() { ( cd "$ROOT" && $TASK cluster-up PROVIDER="$PROVIDER" ROLE="$ROLE" ) && refresh_identity; }
check_cluster() {
  K get --raw=/readyz >/dev/null 2>&1 || { echo "the API does not answer"; return 1; }
  local total notready
  total="$(K get nodes --no-headers 2>/dev/null | wc -l)"
  notready="$(K get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/' | wc -l)"
  [ "$total" -gt 0 ] && [ "$notready" -eq 0 ] || { echo "$notready of $total nodes are not Ready"; return 1; }
  [ -z "$NODES_EXPECTED" ] || [ "$total" -ge "$NODES_EXPECTED" ] || { echo "$total nodes, ${NODES_EXPECTED} expected"; return 1; }
}

run_seedkey() {
  K create namespace foundation-vault --dry-run=client -o yaml | K apply -f - >/dev/null
  K -n foundation-vault create secret generic openbao-seal-key --from-file=key="$SEALKEY"
}
check_seedkey() {
  local n
  n="$(K -n foundation-vault get secret openbao-seal-key -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null | wc -c)"
  [ "$n" -gt 0 ] || { echo "openbao-seal-key is missing or empty"; return 1; }
  say "  (the Secret holds $n bytes; delete $SEALKEY from this machine now)"
}

TFBAK=""
run_flux() {
  TFBAK="${TFVARS}.dr-bak"; cp -p "$TFVARS" "$TFBAK"
  if grep -qE '^[[:space:]]*deploy_flux[[:space:]]*=' "$TFVARS"; then sed -i -E 's/^([[:space:]]*deploy_flux[[:space:]]*=[[:space:]]*)false/\1true/' "$TFVARS"
  else printf '\ndeploy_flux = true\n' >>"$TFVARS"; fi
  ( cd "$ROOT" && $TASK cluster-up PROVIDER="$PROVIDER" ROLE="$ROLE" ) || return 1
  refresh_identity
  # run_flux is the only step that edits the operator's file; the copy is the way back, kept next to it
  echo "  (${TFVARS##*/} now says deploy_flux = true; the previous file is ${TFBAK##*/})"
}
check_flux() {
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    [ "$(K -n foundation-vault get pod openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] \
      && [ "$(K -n foundation-vault get job openbao-init -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] && return 0
    sleep "${OA_DR_POLL:-10}"
  done
  echo "openbao-0 is not Running or the openbao-init Job did not complete"; return 1
}

# Kustomizations outside the dependency closure of foundation-vault: the ones that would consume throw-away values.
closure_json() { K -n flux-system get kustomization -o json; }
HOLD_PY='
import json, sys
d = json.load(sys.stdin)
deps = {k["metadata"]["name"]: [x["name"] for x in (k["spec"].get("dependsOn") or [])] for k in d["items"]}
keep, todo = set(), ["foundation-vault"]
while todo:
    n = todo.pop()
    if n not in keep:
        keep.add(n)
        todo += deps.get(n, [])
for n in sorted(deps):
    if n not in keep and n != "flux-system":
        print(n)'
run_hold() {
  mkdir -p "$WORK"
  closure_json | python3 -c "$HOLD_PY" >"$WORK/hold.plan"
  : >"$HELD"
  local name
  while read -r name; do
    [ -n "$name" ] || continue
    K -n flux-system patch kustomization "$name" --type merge -p '{"spec":{"suspend":true}}' >/dev/null
    echo "$name" >>"$HELD"
  done <"$WORK/hold.plan"
}
check_hold() {
  [ -s "$HELD" ] || { echo "no Kustomization was held: the list is empty"; return 1; }
  say "  ($(wc -l <"$HELD") Kustomizations held: $HELD)"
}

run_openbao() {
  mkdir -p "$WORK/openbao"
  restic_env restic -r "$(repo openbao)" restore latest --host openbao --target "$WORK/openbao"
  local snap
  snap="$(find "$WORK/openbao" -type f -name '*.snap' | head -n 1)"
  [ -n "$snap" ] || { echo "no raft snapshot in the restored repository"; return 1; }
  # token first line, snapshot after it: neither is in argv
  { printf '%s\n' "$(cat "$BAOTOK")"; cat "$snap"; } | K -n foundation-vault exec -i openbao-0 -- sh -c \
    'IFS= read -r BAO_TOKEN; export BAO_TOKEN; cat > /tmp/dr.snap && bao operator raft snapshot restore -force /tmp/dr.snap; rc=$?; rm -f /tmp/dr.snap; exit $rc'
}
check_openbao() {
  local st
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    st="$(K -n foundation-vault exec openbao-0 -- bao status -format=json 2>/dev/null || true)"
    if grep -q '"initialized": *true' <<<"$st" && grep -q '"sealed": *false' <<<"$st"; then
      # standbys that do not follow the restored leader: delete them once (the PVCs stay)
      [ "${OA_DR_NO_STANDBY_FIX:-0}" = 1 ] || K -n foundation-vault delete pod openbao-1 openbao-2 --ignore-not-found >/dev/null 2>&1 || true
      return 0
    fi
    sleep "${OA_DR_POLL:-10}"
  done
  echo "bao status: not initialised and unsealed after the restore"; return 1
}

# A development OpenBao keeps its single share in openbao-recovery-dev (labelled), a production one in openbao-recovery-shares: put the
# source's shares back where the FRESH cluster keeps its own (lab 20: the cluster was a development one and the chain wrote the other Secret).
shares_secret() { if K -n foundation-vault get secret openbao-recovery-dev >/dev/null 2>&1; then echo openbao-recovery-dev; else echo openbao-recovery-shares; fi; }
run_shares() {
  local sec; sec="$(shares_secret)"
  K -n foundation-vault delete secret "$sec" --ignore-not-found >/dev/null
  local args=() f n
  for f in "$SHARES"/openbao-share-*.b64; do n="${f##*openbao-share-}"; n="${n%.b64}"; args+=("--from-file=share-$n=$f"); done
  K -n foundation-vault create secret generic "$sec" "${args[@]}"
  if [ "$sec" = openbao-recovery-dev ]; then K -n foundation-vault label secret openbao-recovery-dev openaether.io/dev-bootstrap=true --overwrite >/dev/null; fi
}
check_shares() {
  local want have sec
  sec="$(shares_secret)"
  want="$(find "$SHARES" -maxdepth 1 -name 'openbao-share-*.b64' | wc -l)"
  have="$(K -n foundation-vault get secret "$sec" -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data", {})))' 2>/dev/null || echo 0)"
  [ "$want" -gt 0 ] && [ "$want" = "$have" ] || { echo "the Secret $sec holds $have shares, the directory $want"; return 1; }
}

resume_list() { # held names; $1 = only|except identity
  [ -s "$HELD" ] || { echo "no held list at $HELD (step hold did not run in this work directory)" >&2; return 1; }
  if [ "$1" = except ]; then grep -v '^identity' "$HELD" || true; else grep '^identity' "$HELD" || true; fi
}
unsuspend() { local n; while read -r n; do [ -z "$n" ] || K -n flux-system patch kustomization "$n" --type merge -p '{"spec":{"suspend":false}}' >/dev/null; done; }
run_resume() { resume_list except | unsuspend; }
check_resume() {
  local bad
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    bad="$(K get externalsecret -A --no-headers 2>/dev/null | awk '$0 !~ /True/' | wc -l)"
    [ "$bad" -eq 0 ] && [ "$(K get externalsecret -A --no-headers 2>/dev/null | wc -l)" -gt 0 ] && return 0
    sleep "${OA_DR_POLL:-10}"
  done
  echo "$bad ExternalSecrets are not Ready"; return 1
}

# the canary chain of a restored database, evaluated on the operator machine from the rows the database prints
CANARY_PY='
import hashlib, sys
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
if not rows: print("no canary row"); sys.exit(1)
bad = [rows[i][0] for i in range(1, len(rows)) if int(rows[i][0]) != int(rows[i-1][0]) + 1 or rows[i][2] != hashlib.sha256(f"{rows[i-1][2]}|{rows[i][0]}|{rows[i][1]}".encode()).hexdigest()]
if bad: print("canary chain broken at " + ",".join(bad[:3])); sys.exit(1)
print(f"canary chain intact, newest row {rows[-1][1]}")'
CANARY_SQL="SELECT counter, to_char(written_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US'), sha FROM public.oa_canary ORDER BY counter"
DBS=("zitadel-db:zitadel" "grafana-db:grafana")
db_healthy() { # cluster
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    [ "$(K -n foundation-databases get clusters.postgresql.cnpg.io "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ] && return 0
    sleep "${OA_DR_POLL:-10}"
  done
  return 1
}
dr_manifest() { # cluster image size: the scratch Cluster that recovers the archive; it never archives
  python3 - "$1" "$2" "$3" "$STORE" "$PITR" <<'PY'
import json, sys
c, img, size, store, pitr = sys.argv[1:6]
rec = {"source": "origin"}
if pitr:
    rec["recoveryTarget"] = {"targetTime": pitr}
print(json.dumps({"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster",
                  "metadata": {"name": c + "-dr", "namespace": "foundation-databases", "labels": {"openaether.io/dr-restore": "true"}},
                  "spec": {"instances": 1, "imageName": img, "storage": {"size": size, "storageClass": "local-path"},
                           "bootstrap": {"recovery": rec},
                           "externalClusters": [{"name": "origin", "plugin": {"name": "barman-cloud.cloudnative-pg.io",
                                                 "parameters": {"barmanObjectName": f"{c}-{store}", "serverName": c}}}]}}))
PY
}
# pg_restore --clean on Zitadel's partitioned cache tables cannot drop the partitions' inherited constraints and exits 1 although the
# data is loaded (lab 20: 6 such errors, then the canary chain intact). That one error is harmless; any other is a failure.
load_dump() { # live-pod database; the dump (custom format) on stdin
  local err="$WORK/pg_restore-$2.err" rc=0 own
  # The objects must belong to the role that owns the database (the application's), not to postgres that runs pg_restore: with plain
  # --no-owner every table was postgres's and Zitadel logged "permission denied for schema queue" on the rebuilt cluster (lab 20).
  own="$(K -n foundation-databases exec "$1" -c postgres -- psql -U postgres -d postgres -X -At -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$2'" | head -n 1)"
  [ -n "$own" ] || { echo "cannot read the owner of the database $2"; return 1; }
  K -n foundation-databases exec -i "$1" -c postgres -- pg_restore -U postgres -d "$2" --clean --if-exists --no-owner --role="$own" 2>"$err" || rc=$?
  cat "$err" >&2
  [ "$rc" -eq 0 ] && return 0
  if grep -q '^pg_restore: error:' "$err" && ! grep '^pg_restore: error:' "$err" | grep -vq 'cannot drop inherited constraint'; then
    say "  (pg_restore exited $rc on $(grep -c '^pg_restore: error:' "$err") inherited-constraint error(s) of --clean on partitioned tables: tolerated, the data is checked below)"
    return 0
  fi
  return "$rc"
}
run_dbs() {
  mkdir -p "$WORK"
  local pair c db live img size
  if [ "$DBSRC" = dump ]; then
    mkdir -p "$WORK/cnpg"; restic_env restic -r "$(repo cnpg)" restore latest --host cnpg --target "$WORK/cnpg"
  fi
  for pair in "${DBS[@]}"; do
    c="${pair%%:*}"; db="${pair##*:}"
    db_healthy "$c" || { echo "$c is not healthy (the live Cluster must exist and be empty before the load)"; return 1; }
    live="$(K -n foundation-databases get clusters.postgresql.cnpg.io "$c" -o jsonpath='{.status.currentPrimary}')"
    if [ "$DBSRC" = pitr ]; then
      img="$(K -n foundation-databases get clusters.postgresql.cnpg.io "$c" -o jsonpath='{.spec.imageName}')"
      size="$(K -n foundation-databases get clusters.postgresql.cnpg.io "$c" -o jsonpath='{.spec.storage.size}')"
      dr_manifest "$c" "$img" "$size" | K apply -f - >/dev/null
      db_healthy "$c-dr" || { echo "$c-dr (recovery from ${STORE}) did not become healthy"; return 1; }
      K -n foundation-databases exec "$c-dr-1" -c postgres -- pg_dump -U postgres -Fc "$db" \
        | load_dump "$live" "$db"
    else
      local f
      f="$(find "$WORK/cnpg" -type f -name "$c.dump" | head -n 1)"
      [ -n "$f" ] || { echo "$c.dump is not in the restored snapshot"; return 1; }
      load_dump "$live" "$db" <"$f"
    fi
  done
}
check_dbs() {
  local pair c db live out rc=0
  for pair in "${DBS[@]}"; do
    c="${pair%%:*}"; db="${pair##*:}"
    live="$(K -n foundation-databases get clusters.postgresql.cnpg.io "$c" -o jsonpath='{.status.currentPrimary}')"
    if out="$(K -n foundation-databases exec "$live" -c postgres -- psql -U postgres -d "$db" -X -At -F "$(printf '\t')" -c "$CANARY_SQL" | python3 -c "$CANARY_PY" 2>&1)"; then
      say "  ✓ $c: $out"
    else
      echo "$c: $out"; rc=1
    fi
    K -n foundation-databases delete clusters.postgresql.cnpg.io "$c-dr" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  return "$rc"
}

run_identity() { resume_list only | unsuspend; }
check_identity() {
  local bad
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    bad="$(K -n flux-system get kustomization --no-headers 2>/dev/null | awk '$0 !~ /True/' | wc -l)"
    [ "$bad" -eq 0 ] && return 0
    sleep "${OA_DR_POLL:-10}"
  done
  echo "$bad Kustomizations are not Ready"; return 1
}

run_verify() {
  ( cd "$ROOT" && $TASK cluster-verify PROVIDER="$PROVIDER" ROLE="$ROLE" )
  K -n foundation-databases delete job dr-check --ignore-not-found >/dev/null
  K -n foundation-databases create job --from=cronjob/cnpg-recovery-restore-test dr-check >/dev/null
}
check_verify() {
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    if [ "$(K -n foundation-databases get job dr-check -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ]; then
      # A Job that skipped every combination also "succeeds" (lab 20: the application role could not read the canary, four SKIPs, exit 0).
      local out; out="$(K -n foundation-databases logs job/dr-check --all-containers 2>/dev/null || true)"
      grep -q '^PASS ' <<<"$out" && ! grep -q '^SKIP ' <<<"$out" && return 0
      echo "the restore test of the rebuilt cluster succeeded without proving anything (SKIP or no PASS line): $(grep -E '^(SKIP|FAIL)' <<<"$out" | head -n 2 | tr '\n' ' ')"; return 1
    fi
    [ "$(K -n foundation-databases get job dr-check -o jsonpath='{.status.failed}' 2>/dev/null)" = 1 ] && { echo "the restore test of the rebuilt cluster failed (job dr-check)"; return 1; }
    sleep "${OA_DR_POLL:-10}"
  done
  echo "the restore test of the rebuilt cluster did not finish (job dr-check)"; return 1
}

run_etcd-fetch() { mkdir -p "$WORK/etcd"; restic_env restic -r "$(repo etcd)" restore latest --host etcd --target "$WORK/etcd"; }
etcd_file() { find "$WORK/etcd" -type f | head -n 1; }
check_etcd-fetch() {
  local f sz
  f="$(etcd_file)"; [ -n "$f" ] || { echo "no file in the restored etcd snapshot"; return 1; }
  sz="$(stat -c %s "$f")"
  [ $((sz % 4096)) -eq 0 ] || [ $((sz % 4096)) -eq 32 ] || { echo "the snapshot size ($sz) is neither a bolt database nor one with a sha256 trailer"; return 1; }
  say "  ($f, $sz bytes$([ $((sz % 4096)) -eq 32 ] && echo ', with sha256 trailer' || echo ', no trailer: --recover-skip-hash-check is needed'))"
}
run_etcd-recover() {
  local f sz skip="" cp
  f="$(etcd_file)"; sz="$(stat -c %s "$f")"
  [ $((sz % 4096)) -eq 32 ] || skip="--recover-skip-hash-check"
  cp="$(TALOSCONFIG="$TCFG" talosctl config info -o json 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin).get("endpoints") or [""])[0])' 2>/dev/null || true)"
  [ -n "$cp" ] || { echo "no control-plane endpoint in $TCFG"; return 1; }
  # shellcheck disable=SC2086
  talosctl --talosconfig "$TCFG" -n "$cp" -e "$cp" bootstrap --recover-from="$f" $skip
}
check_etcd-recover() { :; }
run_etcd-check() { :; }
check_etcd-check() {
  for _ in $(seq 1 "${OA_DR_WAIT_TRIES:-90}"); do
    K get --raw=/readyz >/dev/null 2>&1 && [ "$(K get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/' | wc -l)" -eq 0 ] && return 0
    sleep "${OA_DR_POLL:-10}"
  done
  echo "the API or the nodes did not come back"; return 1
}

# ── the runner ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
in_scope() { # id
  local id="$1" x
  if [ -n "$ONLY" ]; then for x in ${ONLY//,/ }; do [ "$x" = "$id" ] && return 0; done; return 1; fi
  if [ -n "$FROMSTEP" ]; then
    [ "$STARTED" = 1 ] && return 0
    [ "$id" = "$FROMSTEP" ] && { STARTED=1; return 0; }
    return 1
  fi
  return 0
}
STARTED=0
known() { local s; for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
for x in ${ONLY//,/ } $FROMSTEP; do known "$x" || { echo "✗ '$x' is not a step of the $SCENARIO scenario: ${STEPS[*]}" >&2; exit 2; }; done

total_target=0
for s in "${STEPS[@]}"; do total_target=$((total_target + TARGET[$s])); done

say "OpenAether disaster recovery — scenario $SCENARIO — cluster $CN ($ENVN) on $PROVIDER — store $STORE ($EP)"
say "$([ "$EXECUTE" = 1 ] && echo 'MODE: EXECUTE' || echo 'MODE: DRY-RUN (nothing is run or changed; --execute --confirm <cluster_name> runs the chain)')"
say "Sum of the step targets: ${total_target} min of a ${RTO_MIN} min RTO. RPO: OpenBao and the dumps 24 h, CNPG (PITR) the age of the replica copy (up to 15 min + copy) or the primary's WAL; nothing else is restored."
if [ "$EXECUTE" = 1 ]; then
  [ "$CONFIRM" = "$CN" ] || { echo "✗ --execute needs --confirm $CN (the cluster_name of ${TFVARS##*/}); got '${CONFIRM:-nothing}'" >&2; exit 2; }
  mkdir -p "$OUT" "$WORK"
fi

MISSING_ANY=0
T_ALL0="$(NOW_S)"
for id in "${STEPS[@]}"; do
  in_scope "$id" || continue
  say ""
  say "── step $id: ${TITLE[$id]}  [target ${TARGET[$id]} min$([ -n "${DESTRUCTIVE[$id]:-}" ] && echo ', DESTRUCTIVE')]"
  "show_$id"
  miss="$("needs_$id" 2>/dev/null || true)"
  if [ -n "$miss" ]; then
    MISSING_ANY=1
    while IFS= read -r m; do say "  ✗ needs: $m"; done <<<"$miss"
  else
    say "  ✓ inputs present"
  fi
  if [ "$EXECUTE" = 0 ]; then ROWS+=("$id	dry-run	0	$((TARGET[$id] * 60))	${miss:+inputs missing}"); continue; fi
  if [ -n "$STOPPED" ]; then ROWS+=("$id	skipped	0	$((TARGET[$id] * 60))	chain stopped at $STOPPED"); continue; fi
  if [ -n "$miss" ]; then
    echo "✗ step $id cannot run: $(head -n 1 <<<"$miss")" >&2
    ROWS+=("$id	failed	0	$((TARGET[$id] * 60))	missing input"); STOPPED="$id"; continue
  fi
  t0="$(NOW_S)"
  # errexit is ignored inside a function called from an `if`/`&&`: each part runs in a subshell of its own, as a plain statement
  set +e
  ( set -e; "run_$id" ); rrc=$?
  out=""; crc=1
  if [ "$rrc" -eq 0 ]; then out="$( set -e; "check_$id" 2>&1 )"; crc=$?; fi
  set -e
  if [ "$rrc" -eq 0 ] && [ "$crc" -eq 0 ]; then
    [ -z "$out" ] || say "$out"
    d=$(($(NOW_S) - t0)); ROWS+=("$id	ok	$d	$((TARGET[$id] * 60))	"); say "  ✓ $id done in ${d}s"
  else
    d=$(($(NOW_S) - t0))
    say "  ✗ $id FAILED after ${d}s${out:+: $out}"
    ROWS+=("$id	failed	$d	$((TARGET[$id] * 60))	$(head -n 1 <<<"${out:-run failed}")"); STOPPED="$id"
  fi
done

# ── the report ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
say ""
say "── report"
printf '%-14s %-9s %9s %9s  %s\n' step status seconds target note
sum=0
for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r a b c d e <<<"$r"
  printf '%-14s %-9s %9s %9s  %s\n' "$a" "$b" "$c" "$d" "$e"
  sum=$((sum + c))
done
if [ "$EXECUTE" = 1 ]; then
  wall=$(($(NOW_S) - T_ALL0))
  say "chain: ${wall}s wall clock, ${sum}s in steps, RTO target $((RTO_MIN * 60))s — $([ "$wall" -le $((RTO_MIN * 60)) ] && echo 'within' || echo 'OVER') the target; shape and incident are for the person who runs it to write down (cluster shape, nominal or with incident)"
  { printf 'step\tstatus\tseconds\ttarget_seconds\tnote\n'; printf '%s\n' "${ROWS[@]}"; } >"$REPORT"
  say "report: $REPORT"
  [ -z "$STOPPED" ] || { echo "✗ the chain stopped at '$STOPPED'; fix it and resume with --from-step $STOPPED" >&2; exit 1; }
  say "✓ chain complete. Record the row in docs/disaster-recovery.md section 5."
else
  if [ "$MISSING_ANY" = 1 ] && [ "$STRICT" = 1 ]; then echo "✗ --strict: inputs are missing (listed above)" >&2; exit 1; fi
  [ "$MISSING_ANY" = 0 ] || say "(inputs are missing: this is the list to complete BEFORE the day it is needed; --strict makes it an error)"
fi
