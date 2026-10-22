#!/usr/bin/env bash
# ensure-buckets.sh and the audit sink (infra #318), against the fake S3 store (testdata/fake-aws-s3.sh): the sink bucket is created
# WITH object lock on the right endpoint whatever backup_immutability says, its mode and retention are read back, and anything
# short of that is a failure (class A), not a warning. Offline. Rung: mocked/static.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export FAKE_S3="$SB/s3"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$PWD/scripts/dev/testdata/fake-aws-s3.sh" >"$SB/aws"; chmod +x "$SB/aws"
reset() { rm -rf "$FAKE_S3"; mkdir -p "$FAKE_S3/buckets" "$FAKE_S3/id" "$FAKE_S3/refuse" "$FAKE_S3/ignore"; : >"$FAKE_S3/calls.log"; : >"$FAKE_S3/endpoints.log"; }
AUD=s3-example-scaleway-audit-dev
OVH=https://s3.gra.io.cloud.ovh.net; SCW2=https://s3.nl-ams.scw.cloud
mk() { # [extra tfvars lines...]
  sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#;
          s#^s3_primary_endpoint.*#s3_primary_endpoint = "https://s3.fr-par.scw.cloud"#; s#^s3_primary_region.*#s3_primary_region = "fr-par"#;
          s#^s3_replica_endpoint.*#s3_replica_endpoint = "https://replica.example"#; s#^s3_replica_region.*#s3_replica_region = "r2"#' \
    infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
  printf '%s\n' "$@" >>"$SB/t.tfvars"
}
# env -i: the keys of the machine this runs on must never reach a test, whatever the fake aws is.
run() { env -i HOME="$HOME" FAKE_S3="$FAKE_S3" PATH="$SB:$PATH" SCW_AWS_ACCESS_KEY_ID=OPKEY SCW_AWS_SECRET_ACCESS_KEY=OPSECRET BACKUP_AWS_ACCESS_KEY_ID=REPKEY \
  BACKUP_AWS_SECRET_ACCESS_KEY=REPSECRET OVH_BACKUP_AWS_ACCESS_KEY_ID=OVHKEY OVH_BACKUP_AWS_SECRET_ACCESS_KEY=OVHSECRET "$@" \
  ./scripts/internal/ensure-buckets.sh "$SB/t.tfvars" 2>&1; }
PLACE='audit_sink_placement = "other_provider"'; EP="audit_sink_endpoint = \"$OVH\""; RG='audit_sink_region = "gra"'

echo "--- off (the default): no audit bucket, same buckets as before ---"
reset; mk; OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
[ ! -d "$FAKE_S3/buckets/$AUD" ] && ok "no audit bucket" || bad "an audit bucket exists with the sink off"
is "five buckets, as in 0.2.1" 5 "$(ls "$FAKE_S3/buckets" | wc -l | tr -d ' ')"

echo "--- other_provider, GOVERNANCE (default), backup_immutability off: still created WITH object lock ---"
reset; mk "$PLACE" "$EP" "$RG"; OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
[ -f "$FAKE_S3/buckets/$AUD/lock_enabled" ] && ok "the sink bucket was created with object lock" || bad "no lock on the sink bucket: $OUT"
is "default retention read back: GOVERNANCE 365 days" "GOVERNANCE 365" "$(jq -r '.Rule.DefaultRetention | "\(.Mode) \(.Days)"' "$FAKE_S3/buckets/$AUD/lock.json" 2>/dev/null)"
is "versioning enabled" Enabled "$(cat "$FAKE_S3/buckets/$AUD/versioning" 2>/dev/null)"
grep -q "^create-bucket $AUD $OVH\$" "$FAKE_S3/endpoints.log" && ok "the bucket was created on the sink's endpoint" || bad "wrong endpoint: $(grep "$AUD" "$FAKE_S3/endpoints.log" | head -3)"
grep -q "^OVHKEY create-bucket $AUD" "$FAKE_S3/calls.log" && ok "with the keys of the cloud that holds it (OVH), not the cluster's" || bad "wrong keys: $(grep "$AUD" "$FAKE_S3/calls.log" | head -2)"
! grep -q "^OPKEY .* $AUD\$" "$FAKE_S3/calls.log" && ok "the cluster's own keys never touched the sink" || bad "the primary keys reached the sink"
grep -q "Audit sink" <<<"$OUT" && ok "it says what it did" || bad "silent"

echo "--- COMPLIANCE with the opt-in, 30 days ---"
reset; mk "$PLACE" "$EP" "$RG" 'audit_sink_lock_mode = "compliance"' 'audit_sink_compliance_ack = true' 'audit_sink_retention_days = 30'; OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
is "COMPLIANCE 30 days read back" "COMPLIANCE 30" "$(jq -r '.Rule.DefaultRetention | "\(.Mode) \(.Days)"' "$FAKE_S3/buckets/$AUD/lock.json" 2>/dev/null)"

echo "--- an incoherent choice stops BEFORE anything is created ---"
reset; mk "$PLACE" "audit_sink_endpoint = \"$SCW2\"" 'audit_sink_region = "nl-ams"'; OUT="$(run)"; RC=$?
is "refused" 1 "$RC"
grep -q "ANOTHER provider" <<<"$OUT" && ok "says why" || bad "no reason: $OUT"
is "no bucket call at all (not even the state bucket)" 0 "$(wc -l <"$FAKE_S3/calls.log" | tr -d ' ')"
reset; mk "$PLACE" "$EP" "$RG" 'audit_sink_lock_mode = "compliance"'; OUT="$(run)"; RC=$?
is "COMPLIANCE without the opt-in is refused" 1 "$RC"
is "and nothing was created" 0 "$(wc -l <"$FAKE_S3/calls.log" | tr -d ' ')"

echo "--- class A: a refusal by the provider is a FAILURE ---"
reset; mk "$PLACE" "$EP" "$RG"; mkdir -p "$FAKE_S3/refuse"; echo "object lock is not supported" >"$FAKE_S3/refuse/put-object-lock-configuration"; OUT="$(run)"; RC=$?
is "exit 1" 1 "$RC"
grep -q "audit sink NOT ready" <<<"$OUT" && ok "says the sink is not ready" || bad "no message: $OUT"
reset; mk "$PLACE" "$EP" "$RG"; mkdir -p "$FAKE_S3/buckets/$AUD"; OUT="$(run)"; RC=$?   # exists WITHOUT object lock
is "a sink bucket that exists without object lock is a failure" 1 "$RC"
[ ! -f "$FAKE_S3/buckets/$AUD/lock_enabled" ] && ok "and it was not deleted or recreated" || bad "bucket touched"
reset; mk "$PLACE" "$EP" "$RG"; OUT="$(env -i HOME="$HOME" FAKE_S3="$FAKE_S3" PATH="$SB:$PATH" SCW_AWS_ACCESS_KEY_ID=OPKEY SCW_AWS_SECRET_ACCESS_KEY=OPSECRET BACKUP_AWS_ACCESS_KEY_ID=REPKEY BACKUP_AWS_SECRET_ACCESS_KEY=REPSECRET ./scripts/internal/ensure-buckets.sh "$SB/t.tfvars" 2>&1)"; RC=$?
# without the sink's cloud keys the cluster's own (primary) keys would be tried against OVH: s3_cred falls back to the OVH primary pair, which is empty
is "no keys for the sink's cloud: exit 1" 1 "$RC"
grep -q "no S3 credentials in scope for the audit sink" <<<"$OUT" && ok "says which store lacks keys" || bad "no message: $OUT"

echo "--- both: one bucket on each endpoint ---"
reset; mk 'audit_sink_placement = "both"' "$EP" "$RG" "audit_sink_secondary_endpoint = \"$SCW2\"" 'audit_sink_secondary_region = "nl-ams"'; OUT="$(run)"; RC=$?
is "completes" 0 "$RC"
# the fake has one namespace for buckets, so the second endpoint finds the bucket the first made: what is proved is that both were asked
grep -q "^head-bucket $AUD $OVH\$" "$FAKE_S3/endpoints.log" && grep -q "^head-bucket $AUD $SCW2\$" "$FAKE_S3/endpoints.log" && ok "both endpoints were asked for the bucket" || bad "endpoints: $(grep "$AUD" "$FAKE_S3/endpoints.log" | sort -u | head)"
grep -q "^put-object-lock-configuration $AUD $SCW2\$" "$FAKE_S3/endpoints.log" && ok "and the lock was set and read back on the second one too" || bad "no lock call on the second endpoint"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
