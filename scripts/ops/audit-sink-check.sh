#!/usr/bin/env bash
# Proves what the in-cluster delivery check cannot: that the audit sink holds an UNBROKEN, READABLE copy, and that it is locked as asked
# (infra #318, docs/audit-sink.md, sections 3 and 6). Run it from the operator's machine with the escrowed repository password, at least
# weekly and after any outage of the sink or of a shipper. Read-only: it lists, reads and decrypts into a scratch directory it removes.
#
#   1. LOCK        the bucket's versioning, lock mode and default retention, read back from the store, equal the tfvars.
#   2. SEQUENCE    for every node and every UTC day in the window: the snapshots are ranges `oa-pos=<inode>:<from>:<to>[:eof]` of the apiserver's
#                  files. Per inode they must start at 0 and chain with no hole (`from` <= what is covered so far; a repeat is counted, not
#                  a failure), nothing may follow an `eof`, and a new inode must follow a closed one (an inode number reused by a later file, a chunk at 0 after an eof, is a new file). An `oa-gap` snapshot is a LOSS the shipper
#                  recorded (the apiserver deleted a file before it was shipped).
#   3. READABLE    the newest chunks (--sample, default 3) are decrypted with the password and every line must be a JSON audit Event.
#
# Usage: audit-sink-check.sh <cluster.tfvars> [--sink primary|secondary] [--days N] [--sample N]
#   --days N     UTC days to read, today included (default 2: the last 24 hours always fall in them)
# Environment:
#   OA_AUDIT_SINK_PASSWORD_FILE   file holding the repository password (decrypt audit-sink-password.gpg of the escrow into it, mode 0600)
#   OA_AUDIT_SINK_PASSWORD        the password itself (a file is preferred: an environment is visible to the machine's other users)
#   S3 keys: those of the cloud that HOLDS the sink (as for ensure-buckets.sh: <PU>_AWS_*, <PU>_BACKUP_AWS_*), or the sink pair
#            OA_AUDIT_SINK_S3_ACCESS_KEY_ID / OA_AUDIT_SINK_S3_SECRET_ACCESS_KEY (the secondary: OA_AUDIT_SINK_SECONDARY_S3_*)
#   OA_AUDIT_SINK_LOCAL_ROOT      tests: restic repositories under this directory instead of the object store (the lock check still uses `aws`)
# Exit: 0 unbroken, readable and locked as asked; 1 a defect (printed); 2 usage or configuration.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/bucket-protection.sh"
source "$ROOT/scripts/lib/audit-sink.sh"

die() { echo "✗ $*" >&2; exit 2; }
USAGE="usage: audit-sink-check.sh <cluster.tfvars> [--sink primary|secondary] [--days N] [--sample N]"
TFVARS="${1:-}"; [ -n "$TFVARS" ] && [ -f "$TFVARS" ] || die "$USAGE"; shift
SINK=primary; DAYS=2; SAMPLE=3
while [ $# -gt 0 ]; do
  case "$1" in
    --sink) SINK="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --sample) SAMPLE="${2:-}"; shift 2 ;;
    *) die "$USAGE" ;;
  esac
done
case "$SINK" in primary | secondary) ;; *) die "--sink must be primary or secondary" ;; esac
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 60 ] || die "--days must be 1 to 60"
[[ "$SAMPLE" =~ ^[0-9]+$ ]] || die "--sample must be a number"
for t in restic jq; do command -v "$t" >/dev/null 2>&1 || die "$t is required"; done
command -v aws >/dev/null 2>&1 || die "aws CLI is required (the lock check reads the bucket)"

oa_audit_sink_load "$TFVARS" || exit 2
[ "$AS_PLACEMENT" != off ] || die "audit_sink_placement is off in $TFVARS: there is no sink to check"
if [ "$SINK" = primary ]; then EP="$AS_EP1"; RG="$AS_RG1"; PRE=OA_AUDIT_SINK_S3; else EP="$AS_EP2"; RG="$AS_RG2"; PRE=OA_AUDIT_SINK_SECONDARY_S3; fi
[ -n "$EP" ] || die "this tfvars has no $SINK sink (audit_sink_placement = $AS_PLACEMENT)"

PW_FILE="${OA_AUDIT_SINK_PASSWORD_FILE:-}"
if [ -n "$PW_FILE" ]; then [ -s "$PW_FILE" ] || die "OA_AUDIT_SINK_PASSWORD_FILE is empty or missing"
elif [ -z "${OA_AUDIT_SINK_PASSWORD:-}" ]; then die "give the repository password: OA_AUDIT_SINK_PASSWORD_FILE (decrypt the escrow's audit-sink-password.gpg into a 0600 file)"; fi

PROVIDER="$(tfv_provider "$TFVARS")"
PROJECT="$(oa_project "$(tfv "$TFVARS" cluster_name)" "$(tfv "$TFVARS" bucket_suffix)")"
BUCKET="$(oa_audit_bucket "$PROJECT" "$PROVIDER" "$(tfv "$TFVARS" environment)")"
v="${PRE}_ACCESS_KEY_ID"; AK="${!v:-}"; v="${PRE}_SECRET_ACCESS_KEY"; SK="${!v:-}"
if [ -z "$AK" ] || [ -z "$SK" ]; then AK="$(oa_audit_sink_operator_cred "$PROVIDER" "$EP" ak || true)"; SK="$(oa_audit_sink_operator_cred "$PROVIDER" "$EP" sk || true)"; fi
[ -n "$AK" ] && [ -n "$SK" ] || die "no S3 keys in scope for $EP (the keys of the cloud that holds the sink, or ${PRE}_*)"

SCRATCH="$(mktemp -d)"; chmod 700 "$SCRATCH"; trap 'rm -rf "$SCRATCH"' EXIT   # decrypted audit lines live here, and only here
FAIL=0; NOTE=()
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
ok() { echo "  ✓ $*"; }
export AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION="$RG"
if [ -n "$PW_FILE" ]; then export RESTIC_PASSWORD_FILE="$PW_FILE"; else export RESTIC_PASSWORD="$OA_AUDIT_SINK_PASSWORD"; fi
export RESTIC_CACHE_DIR="$SCRATCH/cache"

echo "▶ Audit sink (${SINK}): ${EP} bucket ${BUCKET}, prefix ${AS_PREFIX}, window ${DAYS} UTC day(s)"

# --- 1. lock ----------------------------------------------------------------------------------------------------------
echo "▶ 1. Lock, read back from the store"
STATE="$(oa_protection_state "$BUCKET" "$EP" "$RG" "$AK" "$SK")"
case "$STATE" in *"versioning=Enabled"*) ok "versioning enabled" ;; *) bad "versioning is not enabled [$STATE]" ;; esac
case "$STATE" in
  *"lock=${AS_MODE}:${AS_DAYS}"*) ok "object lock ${AS_MODE}, default retention ${AS_DAYS} days (as the tfvars ask)" ;;
  *"lock=none"*) bad "NO object lock on the bucket [$STATE]: the sink can be emptied by whoever holds a key with the right" ;;
  *) bad "lock is not ${AS_MODE}:${AS_DAYS} [$STATE]" ;;
esac

# --- 2. sequence ------------------------------------------------------------------------------------------------------
repo_of() { # <node> <day>
  if [ -n "${OA_AUDIT_SINK_LOCAL_ROOT:-}" ]; then printf '%s/%s/%s/%s' "$OA_AUDIT_SINK_LOCAL_ROOT" "$AS_PREFIX" "$1" "$2"
  else printf 's3:%s/%s/%s/%s/%s' "$EP" "$BUCKET" "$AS_PREFIX" "$1" "$2"; fi
}
list_children() { # <relative prefix under AS_PREFIX, "" or "<node>"> -> names
  if [ -n "${OA_AUDIT_SINK_LOCAL_ROOT:-}" ]; then ls -1 "$OA_AUDIT_SINK_LOCAL_ROOT/$AS_PREFIX/$1" 2>/dev/null
  else
    aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$AS_PREFIX/${1:+$1/}" --delimiter / --endpoint-url "$EP" --output json 2>/dev/null |
      jq -r '.CommonPrefixes[]?.Prefix' | sed -E 's#/$##; s#.*/##'
  fi
}
echo "▶ 2. Sequence of the ranges, per node and inode"
NODES="$(list_children "")"
[ -n "$NODES" ] || bad "the sink holds no node under ${AS_PREFIX}/ (nothing has ever been delivered, or the prefix is wrong)"
WANT_DAYS=""; for i in $(seq 0 $((DAYS - 1))); do WANT_DAYS+="$(date -u -d "-$i day" +%F) "; done
GAPS=0; DUPS=0; LOSSES=0; CHUNKS=0; FAIL_BEFORE_SEQ="$FAIL"
for node in $NODES; do
  : >"$SCRATCH/snaps.$node"
  for day in $(list_children "$node"); do
    case " $WANT_DAYS" in *" $day "*) ;; *) continue ;; esac
    out="$(restic -r "$(repo_of "$node" "$day")" --no-lock --quiet snapshots --json 2>"$SCRATCH/err")" || {
      bad "$node $day: cannot open the repository ($(tail -n 1 "$SCRATCH/err" | cut -c1-160)): wrong password, or damaged"; continue; }
    # one line per snapshot: time id day tag...   (tags of ours only)
    jq -r --arg d "$day" '.[] | [.time, .id, $d] + [.tags[]? | select(startswith("oa-"))] | @tsv' <<<"$out" >>"$SCRATCH/snaps.$node"
  done
  [ -s "$SCRATCH/snaps.$node" ] || { echo "  ~ $node: no snapshot in the window"; continue; }
  sort -o "$SCRATCH/snaps.$node" "$SCRATCH/snaps.$node"
  res="$(awk -F'\t' '
    { time = $1; id = $2; tag = ""; kind = ""
      for (i = 4; i <= NF; i++) { if ($i ~ /^oa-pos=/) { tag = substr($i, 8); kind = "pos" } else if ($i ~ /^oa-gap=/) { tag = substr($i, 8); kind = "gap" } }
      if (kind == "gap") { printf "LOSS %s\n", tag; next }
      if (kind != "pos") { next }
      n = split(tag, a, ":"); ino = a[1]; from = a[2] + 0; to = a[3] + 0; eof = (a[4] == "eof")
      chunks++
      if (ino != last && last != "" && !closed[last]) printf "UNCLOSED inode %s was followed by inode %s without eof\n", last, ino
      last = ino
      # An inode number is reused once its file has been deleted (the apiserver keeps 10 rotated files): a chunk that starts at 0 after
      # an eof is a NEW file that got the number, not a continuation (lab 23: 10 false defects on a 5 hour window).
      if (closed[ino] && from == 0 && to > from) { delete closed[ino]; delete cov[ino] }
      if (closed[ino] && !(from == to)) { printf "AFTEREOF inode %s: chunk %s-%s after its eof\n", ino, from, to; next }
      if (!(ino in cov)) { cov[ino] = from; if (from > 0) printf "MIDFILE inode %s first seen at offset %s (earlier than the window, or a loss)\n", ino, from }
      if (from > cov[ino]) { printf "GAP inode %s: bytes %d-%d are missing (next chunk starts at %d)\n", ino, cov[ino], from, from; gaps++ }
      if (to <= cov[ino] && from < to) { dups++ }
      if (to > cov[ino]) cov[ino] = to
      if (eof) closed[ino] = 1
    }
    END { printf "TOTAL %d chunks, %d repeated\n", chunks, dups }' "$SCRATCH/snaps.$node")"
  while IFS= read -r l; do
    case "$l" in
      LOSS*) bad "$node: the shipper recorded a LOSS: ${l#LOSS } (a file was deleted by the apiserver before it was shipped)"; LOSSES=$((LOSSES + 1)) ;;
      GAP*|AFTEREOF*|UNCLOSED*) bad "$node: ${l#* }"; GAPS=$((GAPS + 1)) ;;
      MIDFILE*) NOTE+=("$node: ${l#* }") ;;
      TOTAL*) echo "  ~ $node: ${l#TOTAL }"; n="${l#TOTAL }"; CHUNKS=$((CHUNKS + ${n%% chunks*})); DUPS=$((DUPS + $(sed -E 's/.*, ([0-9]+) repeated/\1/' <<<"$l"))) ;;
    esac
  done <<<"$res"
done
[ "$GAPS$LOSSES" = 00 ] && [ -n "$NODES" ] && [ "$FAIL" = "$FAIL_BEFORE_SEQ" ] && ok "no gap in the sequence over ${CHUNKS} chunk(s); ${DUPS} repeated range(s) (a lost acknowledgement, harmless)"
for n in "${NOTE[@]+"${NOTE[@]}"}"; do echo "  ~ $n"; done

# --- 3. readable ------------------------------------------------------------------------------------------------------
echo "▶ 3. The newest chunks decrypt and are audit events"
READ=0
for node in $NODES; do
  [ -s "$SCRATCH/snaps.$node" ] || continue
  NREAD=0   # --sample is per node: a silent node must not hide behind a talkative one
  while IFS=$'\t' read -r _ id day tags; do
    [ "$NREAD" -lt "$SAMPLE" ] || break
    case "$tags" in oa-pos=*) ;; *) continue ;; esac
    rng="${tags#oa-pos=}"; rng="${rng%%$'\t'*}"; IFS=: read -r _ f t _ <<<"$rng"; [ "$f" != "$t" ] || continue   # a marker holds a word
    path="$(restic -r "$(repo_of "$node" "$day")" --no-lock --quiet ls "$id" --json 2>/dev/null | jq -rs '[.[] | select(.type == "file") | .path][0]')"
    if restic -r "$(repo_of "$node" "$day")" --no-lock --quiet dump "$id" "$path" >"$SCRATCH/chunk" 2>"$SCRATCH/err"; then
      if [ -s "$SCRATCH/chunk" ] && jq 'select(.kind != "Event") | halt_error(1)' "$SCRATCH/chunk" >/dev/null 2>&1; then ok "$node ${id:0:8} ($rng): $(wc -l <"$SCRATCH/chunk") lines, all JSON audit events"
      else bad "$node ${id:0:8} ($rng): decrypts, but its lines are not all JSON audit events (kind=Event)"; fi
    else bad "$node ${id:0:8}: cannot be read ($(tail -n 1 "$SCRATCH/err" | cut -c1-160))"; fi
    READ=$((READ + 1)); NREAD=$((NREAD + 1)); rm -f "$SCRATCH/chunk"
  done < <(sort -r "$SCRATCH/snaps.$node")
done
[ "$READ" -gt 0 ] || [ -z "$NODES" ] || bad "no chunk could be sampled"

echo
if [ "$FAIL" -eq 0 ]; then echo "✓ the audit sink is unbroken, readable and locked as asked (this is a proof about the window read, not about earlier days)"; exit 0; fi
echo "✗ ${FAIL} defect(s). A gap or a loss means audit lines are NOT in the sink: keep the node's rotated files, read docs/audit-sink.md, section 5." >&2
exit 1
