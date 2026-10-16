#!/usr/bin/env bash
# ==============================================================================
# s3-isolation-check.sh against a fake store (testdata/fake-aws-s3.sh) whose identities can be limited to one bucket and
# denied DeleteObjectVersion. What this pins:
#   - a dedicated pair that lists its own bucket, nothing else, and cannot delete a version: exit 0;
#   - the same pair with the operator's reach (no limit): exit 1, and the line names the bucket it should not open;
#   - a key the store does not know is a failure, not a quiet "denied";
#   - nothing dedicated in scope is exit 2 (the cluster runs on the operator's keys), never a green;
#   - bucket settings are compared with backup_immutability, so a lock that went missing is seen;
#   - the probes never delete: the version they name does not exist, and nothing else is written.
# Offline: no cloud, no account, no bill.
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
P=s3-example-scaleway
BK="$P-backups-dev"; LG="$P-logs-dev"; ST="$P-tfstate-dev"

mk_tfvars() {
  sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#;
          s#^s3_primary_endpoint.*#s3_primary_endpoint = "https://primary.example"#;
          s#^s3_primary_region.*#s3_primary_region = "r1"#;
          s#^s3_replica_endpoint.*#s3_replica_endpoint = "https://replica.example"#;
          s#^s3_replica_region.*#s3_replica_region = "r2"#' \
    infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
  printf '%s\n' "$@" >>"$SB/t.tfvars"
}
BASE=(PATH="$SB:$PATH" SCW_AWS_ACCESS_KEY_ID=OPKEY SCW_AWS_SECRET_ACCESS_KEY=OPSECRET BACKUP_AWS_ACCESS_KEY_ID=REPKEY BACKUP_AWS_SECRET_ACCESS_KEY=REPSECRET)
check() { env "${BASE[@]}" "$@" ./scripts/ops/s3-isolation-check.sh "$SB/t.tfvars" 2>&1; }
DED=(OA_LOKI_S3_ACCESS_KEY_ID=LOKIAK OA_LOKI_S3_SECRET_ACCESS_KEY=LOKISK
     OA_BACKUP_S3_ACCESS_KEY_ID=BKPAK OA_BACKUP_S3_SECRET_ACCESS_KEY=BKPSK
     OA_BACKUP_REPLICA_S3_ACCESS_KEY_ID=BKRAK OA_BACKUP_REPLICA_S3_SECRET_ACCESS_KEY=BKRSK)
limit() { printf 'bucket %s\n' "$2" >"$FAKE_S3/id/$1"; [ "${3:-}" = keep-vd ] || echo no-version-delete >>"$FAKE_S3/id/$1"; }
fresh() { # a protected world ($MODE, governance by default), every dedicated identity limited to its bucket
  rm -rf "$FAKE_S3"; mkdir -p "$FAKE_S3/buckets" "$FAKE_S3/id" "$FAKE_S3/refuse" "$FAKE_S3/ignore"; : >"$FAKE_S3/calls.log"
  mk_tfvars "backup_immutability = \"${MODE:-governance}\"" 'backup_retention_days = 30'
  env "${BASE[@]}" ./scripts/internal/ensure-buckets.sh "$SB/t.tfvars" >/dev/null 2>&1
  # off creates no backups bucket (the operator does, by hand): the identities need theirs to exist
  mkdir -p "$FAKE_S3/buckets/$BK" "$FAKE_S3/buckets/$BK-backup"
  limit LOKIAK "$LG"; limit BKPAK "$BK"; limit BKRAK "$BK-backup"
}

echo "--- every dedicated pair limited to its bucket and refused DeleteObjectVersion: it holds ---"
fresh
OUT="$(check "${DED[@]}")"; RC=$?
is "exit 0" 0 "$RC"
grep -q "assertion(s) held" <<<"$OUT" && ok "and it says how many" || bad "$OUT"
grep -q "✓ $LG list" <<<"$OUT" && grep -q "✓ $ST list" <<<"$OUT" && ok "Loki lists its own bucket (✓ allowed) and not the state bucket (✓ denied)" || bad "$OUT"
grep -q "operator, primary store" <<<"$OUT" && grep -q "· $ST list" <<<"$OUT" && ok "the operator's reach is shown for contrast and not asserted" || bad "no operator block"
grep -qE 'OPSECRET|REPSECRET|LOKISK|BKPSK|BKRSK' <<<"$OUT" && bad "a secret was printed" || ok "no secret in the output"
grep -E ' (delete|put-)' "$FAKE_S3/calls.log" | grep -vE ' delete-object [^ ]+$|put-bucket|put-object-lock' | grep -q . && bad "an unexpected write" || ok "the only delete call is delete-object --version-id, on a numeric version that does not exist"
grep -q "✓ $BK-backup list" <<<"$OUT" && ok "the replica pair is checked on the replica store" || bad "no replica check"

echo "--- Loki with the operator's reach: the bucket it should not open is named ---"
fresh; rm "$FAKE_S3/id/LOKIAK"
OUT="$(check "${DED[@]}")"; RC=$?
is "exit 1" 1 "$RC"
grep -q "✗ $BK list *expected denied *observed allowed" <<<"$OUT" && ok "the backups bucket: expected denied, observed allowed" || bad "$OUT"

echo "--- a pair that may delete versions: caught when the buckets are protected, informational when not ---"
fresh; limit LOKIAK "$LG" keep-vd
OUT="$(check "${DED[@]}")"; RC=$?
is "exit 1" 1 "$RC"
grep -q "✗ $LG delete-version *expected denied *observed allowed" <<<"$OUT" && ok "named" || bad "$OUT"
OUT="$(check "${DED[@]}" OA_EXPECT_NO_VERSION_DELETE=0)"; RC=$?
is "OA_EXPECT_NO_VERSION_DELETE=0 makes it a note (exit 0)" 0 "$RC"
MODE=off fresh; limit LOKIAK "$LG" keep-vd
OUT="$(check "${DED[@]}")"; RC=$?
is "with backup_immutability = off it is not asserted" 0 "$RC"

echo "--- a key the store does not know is a failure ---"
fresh; echo invalid >"$FAKE_S3/id/BKPAK"
OUT="$(check "${DED[@]}")"; RC=$?
is "exit 1" 1 "$RC"
grep -q "the store does not accept this key" <<<"$OUT" && ok "and says that, not 'denied'" || bad "$OUT"

echo "--- nothing dedicated: exit 2, never green ---"
fresh
OUT="$(check)"; RC=$?
is "exit 2" 2 "$RC"
grep -q "nothing is isolated" <<<"$OUT" && ok "and says the cluster runs on the operator's keys" || bad "$OUT"
OUT="$(check OA_LOKI_S3_ACCESS_KEY_ID=LOKIAK)"; RC=$?
is "half a pair: exit 1" 1 "$RC"

echo "--- the buckets are compared with backup_immutability ---"
fresh; rm "$FAKE_S3/buckets/$LG/lock.json"
OUT="$(check "${DED[@]}")"; RC=$?
is "a lock rule that went missing: exit 1" 1 "$RC"
grep -q "✗ $LG .*object lock missing" <<<"$OUT" && ok "the bucket and the missing lock" || bad "$OUT"
fresh; rm "$FAKE_S3/buckets/$ST/versioning"
OUT="$(check "${DED[@]}")"; RC=$?
is "versioning that went missing: exit 1" 1 "$RC"

echo "--- the identity's own bucket is gone: a failure, not a skip ---"
fresh; rm -rf "${FAKE_S3:?}/buckets/$BK-backup"
OUT="$(check "${DED[@]}")"; RC=$?
is "exit 1" 1 "$RC"
grep -q "✗ $BK-backup list" <<<"$OUT" && ok "named" || bad "$OUT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
