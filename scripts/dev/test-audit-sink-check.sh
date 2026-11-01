#!/usr/bin/env bash
# scripts/ops/audit-sink-check.sh against REAL restic repositories (local backend, built with the tags the apps shipper writes) and the fake
# S3 store for the lock check (infra #318): an unbroken chain passes; a hole, a loss recorded by the shipper, a chunk after an eof, a wrong
# password, an unlocked or differently locked bucket and lines that are not audit events are all defects; a repeated range is counted and is
# not one; no decrypted line and no password outlives the run. Offline. Rung: mocked/static (real restic, no object store).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
command -v restic >/dev/null 2>&1 || { echo "↷ test-audit-sink-check not run: restic is missing (a skip is not a pass)"; exit 0; }
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export FAKE_S3="$SB/s3"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$PWD/scripts/dev/testdata/fake-aws-s3.sh" >"$SB/aws"; chmod +x "$SB/aws"
PWF="$SB/pw"; printf 'fixture-password-not-a-secret' >"$PWF"; chmod 600 "$PWF"
AUD=s3-example-scaleway-audit-dev; LOC="$SB/loc"; TODAY="$(date -u +%F)"
sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#;
        s#^s3_primary_endpoint.*#s3_primary_endpoint = "https://s3.fr-par.scw.cloud"#; s#^s3_primary_region.*#s3_primary_region = "fr-par"#' \
  infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
printf '%s\n' 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"' 'audit_sink_region = "gra"' >>"$SB/t.tfvars"

line() { printf '{"kind":"Event","level":"Metadata","verb":"get","user":{"username":"u%s"},"stageTimestamp":"2026-10-22T10:00:%02d.000001Z"}\n' "$1" "$(( $1 % 60 ))"; }
reset() { rm -rf "$LOC" "$FAKE_S3"; mkdir -p "$LOC" "$FAKE_S3/buckets" "$FAKE_S3/id" "$FAKE_S3/refuse" "$FAKE_S3/ignore"; : >"$FAKE_S3/calls.log"; lock GOVERNANCE 365; }
lock() { # <mode> <days> — the sink bucket as the store would report it
  local b="$FAKE_S3/buckets/$AUD"; mkdir -p "$b"; touch "$b/lock_enabled"; printf Enabled >"$b/versioning"
  printf '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"%s","Days":%s}}}' "$1" "$2" >"$b/lock.json"
}
chunk() { # <node> <day> <inode> <from> <to> [eof] [content: ok|junk|word] — one snapshot, tagged as the shipper tags it
  local repo="$LOC/audit/$1/$2" tag="oa-pos=$3:$4:$5${6:+:$6}"
  [ -d "$repo" ] || RESTIC_PASSWORD_FILE="$PWF" restic -r "$repo" init --quiet >/dev/null 2>&1
  case "${7:-ok}" in ok) line "$4" ;; junk) echo 'this is not json' ;; word) echo eof-marker ;; esac |
    RESTIC_PASSWORD_FILE="$PWF" restic -r "$repo" --no-lock --quiet backup --stdin --stdin-filename "audit/$1/$2/$3-$4-$5.log" --host "$1" --tag "$tag" --tag "node=$1" >/dev/null 2>&1
}
gapsnap() { local repo="$LOC/audit/$1/$2"; [ -d "$repo" ] || RESTIC_PASSWORD_FILE="$PWF" restic -r "$repo" init --quiet >/dev/null 2>&1
  echo gap | RESTIC_PASSWORD_FILE="$PWF" restic -r "$repo" --no-lock --quiet backup --stdin --stdin-filename "audit/$1/$2/gap" --tag "oa-gap=$3:$4:file-gone" --tag "node=$1" >/dev/null 2>&1; }
# shellcheck disable=SC2120  # "$@" is the arguments of a few calls
check() { env -i HOME="$HOME" PATH="$SB:$PATH" FAKE_S3="$FAKE_S3" OVH_AWS_ACCESS_KEY_ID=STUB-AK OVH_AWS_SECRET_ACCESS_KEY=STUB-SK OA_AUDIT_SINK_LOCAL_ROOT="$LOC" \
  OA_AUDIT_SINK_PASSWORD_FILE="${PWFILE:-$PWF}" ${EXTRA:-} ./scripts/ops/audit-sink-check.sh "$SB/t.tfvars" "$@" 2>&1; }

echo "--- an unbroken copy: two nodes, a rotation, one repeated range ---"
reset
chunk cp-1 "$TODAY" 101 0 300; chunk cp-1 "$TODAY" 101 300 650; chunk cp-1 "$TODAY" 101 650 900 eof; chunk cp-1 "$TODAY" 202 0 200; chunk cp-1 "$TODAY" 202 200 410
chunk cp-1 "$TODAY" 202 200 410   # the acknowledgement of the previous one was lost: the same range again
chunk cp-2 "$TODAY" 303 0 500; chunk cp-2 "$TODAY" 303 500 777
OUT="$(check)"; RC=$?
is "exit 0" 0 "$RC"
grep -q "no gap in the sequence over 8 chunk(s); 1 repeated" <<<"$OUT" && ok "no gap, the repeated range is counted and is not a defect" || bad "summary: $OUT"
grep -q "object lock GOVERNANCE, default retention 365 days" <<<"$OUT" && ok "the lock mode and retention are read back and equal the tfvars" || bad "lock line: $OUT"
grep -q "all JSON audit events" <<<"$OUT" && ok "a sample is decrypted and parses as audit events" || bad "no sample: $OUT"
grep -q "fixture-password" <<<"$OUT" && bad "the password was printed" || ok "the password is not printed"
grep -q '"username"' <<<"$OUT" && bad "an audit line was printed" || ok "no audit line is printed"

echo "--- a hole in the sequence ---"
reset
chunk cp-1 "$TODAY" 101 0 300; chunk cp-1 "$TODAY" 101 650 900   # 300-650 never arrived
OUT="$(check)"; RC=$?
is "exit 1" 1 "$RC"
grep -q "inode 101: bytes 300-650 are missing" <<<"$OUT" && ok "it names the inode and the missing byte range" || bad "gap not named: $OUT"

echo "--- a loss the shipper itself recorded ---"
reset
chunk cp-1 "$TODAY" 101 0 300; gapsnap cp-1 "$TODAY" 101 300; chunk cp-1 "$TODAY" 202 0 100
OUT="$(check)"; RC=$?
is "exit 1" 1 "$RC"
grep -q "recorded a LOSS: 101:300:file-gone" <<<"$OUT" && ok "the recorded loss is a defect, with its inode and offset" || bad "loss not reported: $OUT"

echo "--- structure: a chunk after eof, a file left open ---"
reset
chunk cp-1 "$TODAY" 101 0 300 eof; chunk cp-1 "$TODAY" 101 300 400
OUT="$(check)"; RC=$?
is "a chunk after eof: exit 1" 1 "$RC"
grep -q "after its eof" <<<"$OUT" && ok "named" || bad "$OUT"
reset
chunk cp-1 "$TODAY" 101 0 300; chunk cp-1 "$TODAY" 202 0 100
OUT="$(check)"; RC=$?
is "a new inode after a file that never got its eof: exit 1" 1 "$RC"
grep -q "without eof" <<<"$OUT" && ok "named" || bad "$OUT"

reset
chunk cp-1 "$TODAY" 101 0 300 eof; chunk cp-1 "$TODAY" 202 0 100 eof; chunk cp-1 "$TODAY" 101 0 250; chunk cp-1 "$TODAY" 101 250 400
OUT="$(check)"; RC=$?
is "an inode number reused by a later file (a chunk at 0 after an eof) is a new file: exit 0" 0 "$RC"
grep -q "no gap in the sequence" <<<"$OUT" && ok "and the sequence is called unbroken" || bad "$OUT"
reset
chunk cp-1 "$TODAY" 101 0 300 eof; chunk cp-1 "$TODAY" 202 0 100 eof; chunk cp-1 "$TODAY" 101 0 250; chunk cp-1 "$TODAY" 101 400 500
OUT="$(check)"; RC=$?
is "a hole inside the reused inode is still a gap: exit 1" 1 "$RC"
grep -q "bytes 250-400 are missing" <<<"$OUT" && ok "named" || bad "$OUT"

echo "--- a marker (from = to, a word) is not an audit event and is not sampled ---"
reset
chunk cp-1 "$TODAY" 101 0 300; chunk cp-1 "$TODAY" 101 300 300 eof word; chunk cp-1 "$TODAY" 202 0 50
OUT="$(check)"; RC=$?
is "exit 0" 0 "$RC"

echo "--- lines that are not audit events ---"
reset
chunk cp-1 "$TODAY" 101 0 300 "" junk
OUT="$(check)"; RC=$?
is "exit 1" 1 "$RC"
grep -q "not all JSON audit events" <<<"$OUT" && ok "named" || bad "$OUT"

echo "--- the wrong password ---"
reset
chunk cp-1 "$TODAY" 101 0 300
printf 'another-password' >"$SB/wrong"
OUT="$(PWFILE="$SB/wrong" check)"; RC=$?
is "exit 1" 1 "$RC"
grep -q "cannot open the repository" <<<"$OUT" && ! grep -q "no gap in the sequence" <<<"$OUT" && ok "named, and nothing is claimed about the sequence" || bad "$OUT"
OUT="$(env -i HOME="$HOME" PATH="$SB:$PATH" OVH_AWS_ACCESS_KEY_ID=A OVH_AWS_SECRET_ACCESS_KEY=B ./scripts/ops/audit-sink-check.sh "$SB/t.tfvars" 2>&1)"; RC=$?
is "no password given: exit 2" 2 "$RC"

echo "--- the lock ---"
reset; lock COMPLIANCE 365
OUT="$(check)"; RC=$?
is "a COMPLIANCE bucket where GOVERNANCE was asked: exit 1" 1 "$RC"
grep -q "lock is not GOVERNANCE:365" <<<"$OUT" && ok "the mismatch is shown" || bad "$OUT"
reset; lock GOVERNANCE 30
OUT="$(check)"; RC=$?
is "a shorter retention than asked: exit 1" 1 "$RC"
reset; rm -f "$FAKE_S3/buckets/$AUD/lock_enabled" "$FAKE_S3/buckets/$AUD/lock.json"
chunk cp-1 "$TODAY" 101 0 300
OUT="$(check)"; RC=$?
is "no object lock at all: exit 1" 1 "$RC"
grep -q "NO object lock" <<<"$OUT" && ok "said plainly" || bad "$OUT"
reset; printf '%s\n' 'audit_sink_lock_mode = "compliance"' 'audit_sink_compliance_ack = true' >>"$SB/t.tfvars"; lock COMPLIANCE 365; chunk cp-1 "$TODAY" 101 0 300
OUT="$(check)"; RC=$?
is "COMPLIANCE asked and found: exit 0" 0 "$RC"

echo "--- nothing in the sink, a sink that is off, scratch cleaned ---"
reset
OUT="$(check)"; RC=$?
is "an empty sink is a defect" 1 "$RC"
grep -q "holds no node" <<<"$OUT" && ok "named" || bad "$OUT"
sed -i '/^audit_sink_/d' "$SB/t.tfvars"
OUT="$(check)"; RC=$?
is "a tfvars without a sink: exit 2" 2 "$RC"
is "no scratch directory is left behind" 0 "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -newer "$PWF" -type d -exec test -d '{}/cache' \; -print 2>/dev/null | wc -l)"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
