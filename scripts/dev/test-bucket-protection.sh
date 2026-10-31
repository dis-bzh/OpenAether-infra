#!/usr/bin/env bash
# ==============================================================================
# backup_immutability in ensure-buckets.sh, against a fake S3 store (testdata/fake-aws-s3.sh) that keeps what was set on
# each bucket and refuses object lock on a bucket not created with it, the way the providers do.
#
# What this pins, and why each is here:
#   - off (the default) protects nothing (no versioning, lifecycle or lock call) but still creates the application-backups
#     pair, so the second copy of the CNPG archive has its bucket on a default install (infra #391).
#   - versioned / governance / compliance do what they say on the right buckets, and READ IT BACK; a call a store accepts
#     and ignores is the failure this guards against.
#   - a lifecycle rule someone else set (the CNPG WAL expiry, say) survives: the API replaces the whole set.
#   - a refusal is a loud warning naming the bucket, not a silent pass; STRICT turns it into a failure.
#   - a bucket that exists without object lock is reported, never "fixed" by deleting it.
# Offline: no cloud, no account, no bill. The providers' real answers are in LAB-CHECKLIST (B16).
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export FAKE_S3="$SB/s3"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$PWD/scripts/dev/testdata/fake-aws-s3.sh" >"$SB/aws"; chmod +x "$SB/aws"
reset() { rm -rf "$FAKE_S3"; mkdir -p "$FAKE_S3/buckets" "$FAKE_S3/id" "$FAKE_S3/refuse" "$FAKE_S3/ignore"; : >"$FAKE_S3/calls.log"; }

P=s3-example-scaleway          # <project>-<provider> of the fixture below
BK="$P-backups-dev"; LG="$P-logs-dev"; ST="$P-tfstate-dev"; AR="$P-management-dev"
ALL="$ST $AR $BK $LG $ST-backup $AR-backup $BK-backup"
LOCKED="$BK $LG $ST-backup $AR-backup $BK-backup"
UNLOCKED="$ST $AR"

mk_tfvars() { # [extra lines...] — the example, one provider, a replica elsewhere
  sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#;
          s#^s3_primary_endpoint.*#s3_primary_endpoint = "https://primary.example"#;
          s#^s3_primary_region.*#s3_primary_region = "r1"#;
          s#^s3_replica_endpoint.*#s3_replica_endpoint = "https://replica.example"#;
          s#^s3_replica_region.*#s3_replica_region = "r2"#' \
    infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
  printf '%s\n' "$@" >>"$SB/t.tfvars"
}
# shellcheck disable=SC2120  # "$@" is the extra environment of a few calls
run() { env PATH="$SB:$PATH" SCW_AWS_ACCESS_KEY_ID=OPKEY SCW_AWS_SECRET_ACCESS_KEY=OPSECRET \
  BACKUP_AWS_ACCESS_KEY_ID=REPKEY BACKUP_AWS_SECRET_ACCESS_KEY=REPSECRET "$@" ./scripts/internal/ensure-buckets.sh "$SB/t.tfvars" 2>&1; }
b() { printf '%s/buckets/%s' "$FAKE_S3" "$1"; }
writes() { grep -cE ' (put-|create-bucket)' "$FAKE_S3/calls.log" | tr -d ' '; }

echo "--- off (the default): the application-backups pair exists (infra #391), and nothing is protected ---"
reset; mk_tfvars
OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
is "seven buckets: the five of 0.2.1 and the application-backups pair" "7" "$(ls "$FAKE_S3/buckets" | wc -l | tr -d ' ')"
[ -d "$(b "$BK")" ] && ok "the application-backups bucket is created ($BK)" || bad "$BK was not created with the protection off"
[ -d "$(b "$BK-backup")" ] && ok "…and its replica twin, the second copy of the CNPG archive ($BK-backup)" || bad "$BK-backup (the replica cnpg-store-replicate writes to) was not created with the protection off"
grep -q "^OPKEY create-bucket $BK$" "$FAKE_S3/calls.log" && grep -q "^REPKEY create-bucket $BK-backup$" "$FAKE_S3/calls.log" \
  && ok "the primary with the primary's key, the replica with the replica store's" || bad "wrong keys: $(head -40 "$FAKE_S3/calls.log")"
grep -q "^create-bucket $BK-backup https://replica.example$" "$FAKE_S3/endpoints.log" \
  && ok "the replica twin is created on the replica endpoint" || bad "the replica twin went to another endpoint: $(grep "$BK-backup" "$FAKE_S3/endpoints.log")"
for x in $BK $BK-backup; do
  [ -f "$(b "$x")/lock_enabled" ] && bad "  $x has an object lock with the protection off" || ok "  $x is not locked (off adds no lock, as before)"
done
grep -qE ' put-(bucket|object)' "$FAKE_S3/calls.log" && bad "a put-* call was made with the protection off" || ok "no versioning, lifecycle or lock call"
: >"$FAKE_S3/calls.log"; OUT="$(run)"; RC=$?
is "a re-run completes" 0 "$RC"
grep -q ' create-bucket ' "$FAKE_S3/calls.log" && bad "a re-run created a bucket again" || ok "…and creates nothing: every bucket answers 'exists'"
grep -q "✓ $BK-backup (exists)" <<<"$OUT" && ok "the replica twin is reported as existing" || bad "no 'exists' line for the replica twin: $OUT"
reset; mk_tfvars; mkdir -p "$(b "$BK")"; : >"$FAKE_S3/calls.log"
OUT="$(run)"; RC=$?
is "a primary the operator created by hand is kept, and the missing replica twin is added" "0 yes" "$RC $([ -d "$(b "$BK-backup")" ] && echo yes || echo no)"
grep -q "^OPKEY create-bucket $BK$" "$FAKE_S3/calls.log" && bad "the operator's own bucket was created again" || ok "the existing primary was not touched"
echo "--- off: a provider that refuses the replica twin is a warning that names it, not a refused deploy ---"
reset; mk_tfvars; printf 'AccessDenied' >"$FAKE_S3/refuse/create-bucket.$BK-backup"
OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
grep -q "$BK-backup not ready" <<<"$OUT" && ok "the warning names the bucket and what it costs" || bad "no warning: $OUT"
grep -q 'nothing here stops' <<<"$OUT" && bad "the prod advisory is printed for a dev cluster" || ok "no advisory on dev"
sed -i 's#^environment.*#environment = "prod"#' "$SB/t.tfvars"; reset
OUT="$(run)"
grep -q 'backup_immutability = off: nothing here stops a stolen S3 key' <<<"$OUT" && ok "prod with it off says so, in one line" || bad "no prod advisory: $OUT"

echo "--- versioned: every bucket versioned, old versions expire, no lock anywhere ---"
reset; mk_tfvars 'backup_immutability = "versioned"'
OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
is "seven buckets (the application-backups pair is created)" "7" "$(ls "$FAKE_S3/buckets" | wc -l | tr -d ' ')"
for x in $ALL; do
  [ "$(cat "$(b "$x")/versioning" 2>/dev/null)" = Enabled ] && ok "  $x versioned" || bad "  $x not versioned"
  [ "$(jq -r '.Rules[] | select(.ID=="oa-noncurrent-expiry") | .NoncurrentVersionExpiration.NoncurrentDays' "$(b "$x")/lifecycle.json" 2>/dev/null)" = 60 ] \
    && ok "  $x: old versions expire after the default 60 days" || bad "  $x: no 60-day rule"
  [ -f "$(b "$x")/lock_enabled" ] && bad "  $x has an object lock in versioned mode"
done
grep -q 'NOT' <<<"$OUT" && bad "warned although everything held: $OUT" || ok "no warning when everything is confirmed"
grep -q 'OPSECRET\|REPSECRET' <<<"$OUT" && bad "a secret was printed" || ok "no secret in the output"
grep -q "^OPKEY create-bucket $BK$" "$FAKE_S3/calls.log" && grep -q "^REPKEY create-bucket $BK-backup$" "$FAKE_S3/calls.log" \
  && ok "primary buckets with the primary's key, replicas with the replica store's" || bad "wrong keys: $(cat "$FAKE_S3/calls.log" | head -40)"
: >"$FAKE_S3/calls.log"; OUT="$(run)"; RC=$?
is "a re-run completes" 0 "$RC"
is "…and leaves exactly one rule of ours per bucket" "1" "$(jq '[.Rules[] | select(.ID=="oa-noncurrent-expiry")] | length' "$(b "$LG")/lifecycle.json")"

echo "--- governance, 30 days: the buckets that hold copies and logs are created WITH object lock ---"
reset; mk_tfvars 'backup_immutability = "governance"' 'backup_retention_days = 30'
OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
for x in $LOCKED; do
  [ -f "$(b "$x")/lock_enabled" ] && [ "$(jq -r '.Rule.DefaultRetention | "\(.Mode):\(.Days)"' "$(b "$x")/lock.json" 2>/dev/null)" = GOVERNANCE:30 ] \
    && ok "  $x: lock GOVERNANCE 30d" || bad "  $x: no GOVERNANCE 30d lock"
done
for x in $UNLOCKED; do
  [ -f "$(b "$x")/lock_enabled" ] && bad "  $x (primary state/artifacts) was locked" || ok "  $x is versioned, never locked (tofu writes it)"
done
is "expiry follows backup_retention_days" "30" "$(jq -r '.Rules[0].NoncurrentVersionExpiration.NoncurrentDays' "$(b "$LG")/lifecycle.json")"

echo "--- compliance ---"
reset; mk_tfvars 'backup_immutability = "compliance"'
OUT="$(run)"
is "the mode is COMPLIANCE, 60 days" "COMPLIANCE:60" "$(jq -r '.Rule.DefaultRetention | "\(.Mode):\(.Days)"' "$(b "$LG")/lock.json")"

echo "--- a lifecycle rule someone else set survives ---"
reset; mk_tfvars 'backup_immutability = "versioned"'
mkdir -p "$(b "$BK")"
printf '%s' '{"Rules":[{"ID":"cnpg-wal-30d","Status":"Enabled","Filter":{"Prefix":"cnpg/"},"Expiration":{"Days":30}}]}' >"$(b "$BK")/lifecycle.json"
OUT="$(run)"
is "their rule is still there" "cnpg-wal-30d" "$(jq -r '.Rules[] | select(.ID=="cnpg-wal-30d") | .ID' "$(b "$BK")/lifecycle.json")"
is "…beside ours" "2" "$(jq '.Rules | length' "$(b "$BK")/lifecycle.json")"

echo "--- a bucket that exists WITHOUT object lock: reported, not recreated, versioning still applied ---"
reset; mk_tfvars 'backup_immutability = "governance"'
mkdir -p "$(b "$LG")"
OUT="$(run)"; RC=$?
is "completes (a warning, not a refused deploy)" 0 "$RC"
grep -q "NOT fully protected: object lock refused" <<<"$OUT" && grep -q "$LG" <<<"$OUT" && ok "names the bucket and the refusal" || bad "$OUT"
grep -q 'CREATED with it' <<<"$OUT" && ok "…and says a bucket usually has to be created with the lock" || bad "no hint"
grep -q "NOT protected as asked: $LG" <<<"$OUT" && ok "the summary lists it" || bad "$OUT"
is "versioning was still applied" "Enabled" "$(cat "$(b "$LG")/versioning")"
[ -d "$(b "$LG")" ] && ok "the bucket was not deleted or replaced" || bad "bucket gone"
OUT="$(OA_BUCKET_PROTECTION_STRICT=1 run)"; RC=$?
[ "$RC" -ne 0 ] && ok "OA_BUCKET_PROTECTION_STRICT=1 makes it a failure (rc=$RC)" || bad "strict did not fail"

echo "--- the provider refuses versioning: the warning carries its words ---"
reset; mk_tfvars 'backup_immutability = "versioned"'
echo "This provider does not support versioning" >"$FAKE_S3/refuse/put-bucket-versioning.$LG"
OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
grep -q "$LG: NOT fully protected: versioning refused (.*does not support versioning)" <<<"$OUT" && ok "the bucket and the provider's text" || bad "$OUT"
grep -q "✓ $BK:" <<<"$OUT" && ok "the other buckets are still protected" || bad "one refusal stopped the rest"

echo "--- a bucket created with the lock is versioned already and the store refuses the PUT (Outscale, lab 22): no warning ---"
reset; mk_tfvars 'backup_immutability = "versioned"'
mkdir -p "$(b "$LG")"; printf Enabled >"$(b "$LG")/versioning"
echo "InvalidBucketState: An Object Lock configuration is present on this bucket, so versioning cannot be changed" >"$FAKE_S3/refuse/put-bucket-versioning.$LG"
OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
grep -q "$LG: NOT fully protected" <<<"$OUT" && bad "a refused PUT on an already versioned bucket was reported: $OUT" || ok "no warning when the read-back confirms Enabled"
grep -q "✓ $LG:" <<<"$OUT" && ok "the bucket is reported protected" || bad "$OUT"

echo "--- lifecycle rules that cannot be read are not overwritten ---"
reset; mk_tfvars 'backup_immutability = "versioned"'
echo "Access Denied" >"$FAKE_S3/refuse/get-bucket-lifecycle-configuration"
OUT="$(run)"
grep -q 'put-bucket-lifecycle-configuration' "$FAKE_S3/calls.log" && bad "wrote a lifecycle it could not read the old one of" || ok "no lifecycle write after an unreadable read"
grep -q 'a write would drop the ones I cannot see' <<<"$OUT" && ok "and it says why" || bad "$OUT"

echo "--- a call the store accepts and ignores is caught by the read-back ---"
reset; mk_tfvars 'backup_immutability = "versioned"'
mkdir -p "$FAKE_S3/ignore"; touch "$FAKE_S3/ignore/put-bucket-versioning"
OUT="$(run)"
grep -q 'versioning not confirmed' <<<"$OUT" && ok "versioning not confirmed by the read-back is reported" || bad "$OUT"

echo "--- bad values are refused before any bucket is touched ---"
for v in 'backup_immutability = "locked"' 'backup_retention_days = "abc"' 'backup_retention_days = 0' 'backup_retention_days = 99999'; do
  reset; mk_tfvars "$v"
  OUT="$(run)"; RC=$?
  [ "$RC" -ne 0 ] && is "  '$v' refused, nothing created" "0" "$(ls "$FAKE_S3/buckets" | wc -l | tr -d ' ')" || bad "  '$v' accepted"
done

echo "--- cluster-verify: the application-backups replica bucket the cluster names must exist (infra #391) ---"
# app_backups_replica_check is lifted out of infra-verify.sh and run against the fake store, with its ok/bad/unk reduced to
# one line each. A bucket that is not there is a FAILURE (cnpg-store-replicate fails every 15 minutes and the second copy of the
# CNPG archive does not exist); a store that cannot answer is UNCHECKED, never a false red and never green.
SUT="${SUT:-$PWD/scripts/dev/infra-verify.sh}"
FN="$SB/verify-fn.sh"; awk '/^app_backups_replica_check\(\) \{/,/^}/' "$SUT" >"$FN"
if [ "$(grep -c '^app_backups_replica_check()' "$FN")" != 1 ]; then
  bad "app_backups_replica_check is not in $SUT: cluster-verify cannot see a missing replica bucket"
else
  ok "the check was found in the script under test"
  check() { # <bucket> <access key> — sets VOUT
    # shellcheck disable=SC1090  # $FN is the function lifted out of the script under test just above
    VOUT="$( ( ok() { echo "OK: $*"; }; bad() { echo "BAD: $*"; }; unk() { echo "UNK: $*"; }
               PATH="$SB:$PATH"; source "$FN"
               app_backups_replica_check "$1" https://replica.example "$2" REPSECRET ) 2>&1 )"
  }
  reset; mkdir -p "$(b "$BK-backup")"
  check "$BK-backup" REPKEY
  grep -q "^OK: .*$BK-backup" <<<"$VOUT" && ! grep -qE '^(BAD|UNK)' <<<"$VOUT" && ok "the bucket is there: one OK line naming it" || bad "present bucket: $VOUT"
  grep -q "^REPKEY head-bucket $BK-backup$" "$FAKE_S3/calls.log" && grep -q "^head-bucket $BK-backup https://replica.example$" "$FAKE_S3/endpoints.log" \
    && ok "…asked of the replica endpoint with the replica store's key" || bad "wrong endpoint or key: $(cat "$FAKE_S3/calls.log" "$FAKE_S3/endpoints.log")"
  reset
  check "$BK-backup" REPKEY
  grep -q "^BAD: .*$BK-backup" <<<"$VOUT" && grep -q 'https://replica.example' <<<"$VOUT" && grep -q 'second copy' <<<"$VOUT" && ! grep -q '^OK' <<<"$VOUT" \
    && ok "the bucket is absent: a FAILURE that names the bucket, the endpoint and what is lost" || bad "absent bucket did not fail: $VOUT"
  grep -q 'task cluster-up' <<<"$VOUT" && ok "…and says what creates it" || bad "no remedy named: $VOUT"
  reset; mkdir -p "$(b "$BK-backup")"; printf 'invalid\n' >"$FAKE_S3/id/BADKEY"
  check "$BK-backup" BADKEY
  grep -q '^UNK:' <<<"$VOUT" && ! grep -qE '^(OK|BAD)' <<<"$VOUT" && ok "a key the store rejects is UNCHECKED, not a false red" || bad "rejected key: $VOUT"
  reset; mkdir -p "$(b "$BK-backup")" "$(b other)"; printf 'bucket other\n' >"$FAKE_S3/id/ONLYOTHER"
  check "$BK-backup" ONLYOTHER
  grep -q '^UNK:' <<<"$VOUT" && ! grep -qE '^(OK|BAD)' <<<"$VOUT" && ok "access denied on an existing bucket is UNCHECKED" || bad "denied: $VOUT"
  # Wired in: after the state replica check, only where there is a provider, with the BACKUP credentials of the replica endpoint.
  SECT="$(awk '/^info "The state is backed up"/{f=1} f{print} /^printf .%s passed/ && f{exit}' "$SUT")"
  LN_ELSE="$(grep -n '^else$' <<<"$SECT" | head -1 | cut -d: -f1)"; LN_CALL="$(grep -n 'app_backups_replica_check' <<<"$SECT" | head -1 | cut -d: -f1)"
  [ -n "$LN_ELSE" ] && [ -n "$LN_CALL" ] && [ "$LN_CALL" -gt "$LN_ELSE" ] \
    && ok "the section calls it only on the non-local branch (the Docker lane has no S3)" || bad "not wired after the PROVIDER = local branch: else $LN_ELSE, call $LN_CALL"
  grep -q 'oa_backup_bucket .*-backup"' <<<"$SECT" \
    && ok "…on the name oa_backup_bucket() gives plus -backup, the twin ensure-buckets.sh creates" || bad "the bucket name is not derived from oa_backup_bucket: $SECT"
  grep -q 'REPL_AK=.*resolve-s3-cred.sh.* ak backup ' <<<"$SECT" && grep -q 'REPL_SK=.*resolve-s3-cred.sh.* sk backup ' <<<"$SECT" \
    && ok "…with the replica store's credentials (backup), not the primary's" || bad "the replica check does not use the backup credentials"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
