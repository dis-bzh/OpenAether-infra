#!/usr/bin/env bash
# The backup path had no inverse. Until 2026-08-17 this repository could encrypt
# a kubeconfig and a talosconfig to two object stores and had no way to read them
# back: no script, no documented command, and the nearest thing
# — stands up a NEW cluster rather than recovering access to the one you have.
#
# A backup nobody has restored is a hypothesis. This is the round trip, offline:
# the exact `enc()` from backup-artifacts.sh, the exact `dec()` from
# restore-artifacts.sh, no S3 and no cluster. What it does NOT prove is the
# transport — that a real object exists in a real bucket is a cloud-run claim,
# and infra-verify.sh owns it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

command -v gpg >/dev/null 2>&1 || { echo "↷ gpg absent — the round trip cannot be tested here"; exit 0; }

WORK="$(mktemp -d)"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
trap 'rm -rf "$WORK" "$GNUPGHOME"' EXIT

# Extracted from the two scripts rather than retyped, so a change to either side
# is exercised here. If the awk range misses, the functions are undefined and
# every check below would score a pass from "command not found" — hence the
# assertion right after.
eval "$(awk '/^enc\(\) \{/,/^\}/' "$ROOT/scripts/ops/backup-artifacts.sh")"
eval "$(awk '/^dec\(\) \{/,/^\}/' "$ROOT/scripts/ops/restore-artifacts.sh")"
if ! declare -F enc >/dev/null || ! declare -F dec >/dev/null; then
  echo "✗ enc()/dec() could not be extracted — every check below would have passed on rc 127" >&2
  exit 1
fi

echo "=== the round trip: what is encrypted comes back byte for byte ==="

PASSPHRASE="a-passphrase-long-enough-to-be-accepted-32+"
PAYLOAD='apiVersion: v1
kind: Config
clusters:
- cluster: {server: "https://10.0.0.1:6443"}
  name: openaether'
printf '%s' "$PAYLOAD" >"$WORK/original"

# `base64 -w0 <<<"$PAYLOAD"` would encode a trailing newline the here-string adds
# and the original file does not have, and the comparison below would fail on one
# byte for a reason that has nothing to do with the scripts.
enc "$(printf '%s' "$PAYLOAD" | base64 -w0)" "$WORK/sealed.gpg"
[ -s "$WORK/sealed.gpg" ] && ok "enc() produced a file" || bad "enc() produced nothing"

# The whole point of client-side encryption: what leaves the machine must not be
# the payload. Checked, not assumed — this is the one claim the repository makes
# about the backups that nothing else verifies.
if grep -q 'apiVersion' "$WORK/sealed.gpg" 2>/dev/null; then
  bad "the sealed file still contains the plaintext — it is not encrypted"
else
  ok "the sealed file is not the plaintext"
fi

if dec "$WORK/sealed.gpg" "$WORK/restored" 2>/dev/null; then
  ok "dec() accepted the file written by enc()"
else
  bad "dec() could not read what enc() wrote — the two are not inverses"
fi
if cmp -s "$WORK/original" "$WORK/restored"; then
  ok "restored byte for byte"
else
  bad "the restored file differs from the original"
fi

echo "=== a wrong passphrase must FAIL, not return something ==="
# The failure that matters: a silent partial success would write a corrupt
# kubeconfig over a working one.
( PASSPHRASE="the-wrong-passphrase-entirely-and-long-enough"
  if dec "$WORK/sealed.gpg" "$WORK/wrong" 2>/dev/null; then
    printf 'BAD\n'
  else
    printf 'GOOD\n'
  fi ) | grep -q GOOD \
  && ok "the wrong passphrase is refused" \
  || bad "the wrong passphrase decrypted the object"

echo "=== restore-artifacts.sh refuses to start without the passphrase ==="
# It is the ONLY thing that can decrypt; discovering it is unset after the
# download turns a missing key into what looks like a corrupt backup.
out="$(env -u TF_VAR_encryption_passphrase "$ROOT/scripts/ops/restore-artifacts.sh" scaleway 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'TF_VAR_encryption_passphrase' <<<"$out"; then
  ok "it stops early and names the missing passphrase"
else
  bad "it did not refuse a run with no passphrase (rc=${rc})"
fi

echo "=== a replica on ANOTHER cloud is read with that cloud's keys, region and bucket (the file's cluster_role) ==="
# Runs the script against a stub aws on the shipped failover example, whose inline comments and cluster_role
# (management under a failover-* name) are what broke the reader. The stub logs the key, arguments and checksum setting.
SB="$(mktemp -d)"; trap 'rm -rf "$WORK" "$GNUPGHOME" "$SB"' EXIT
mkdir "$SB/envs"
cp "$ROOT/infrastructure/opentofu/cluster/envs/failover-scaleway.tfvars.example" "$SB/envs/failover-scaleway.tfvars"
cat >"$SB/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "${AWS_ACCESS_KEY_ID:-<unset>}" "$*" >>"$OA_STUB_LOG"
printf '%s\n' "${AWS_REQUEST_CHECKSUM_CALCULATION:-unset}" >>"$OA_STUB_LOG.compat"
[ -z "${OA_STUB_ERR:-}" ] || echo "$OA_STUB_ERR" >&2
exit 9
STUB
chmod +x "$SB/aws"
run_restore() { # <from> then env assignments: the keys in the shell
  local from="$1"; shift; : >"$SB/log"; : >"$SB/log.compat"
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_LOG="$SB/log" OA_ENVS_DIR="$SB/envs" \
    TF_VAR_encryption_passphrase=x "$@" \
    "$ROOT/scripts/ops/restore-artifacts.sh" scaleway --role failover --from "$from" --out "$SB/out" >"$SB/said" 2>&1 || true
  grep 'talosconfig.gpg' "$SB/log" | head -1
}
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
EX="$SB/envs/failover-scaleway.tfvars"
REPL_EP="$(tfv "$EX" s3_replica_endpoint)"; REPL_REGION="$(tfv "$EX" s3_replica_region)"
PRIM_EP="$(tfv "$EX" s3_primary_endpoint)"; PRIM_REGION="$(tfv "$EX" s3_primary_region)"
# The replica cloud's key variable follows the example's endpoint, wherever the example points it.
RPU="$(provider_pu "$(provider_of_endpoint "$REPL_EP")")"
[ -n "$RPU" ] && [ "$RPU" != SCW ] && [ "$REPL_REGION" != "$PRIM_REGION" ] && ok "the example's replica is on another cloud (${RPU}) and signs with its own region" ||
  bad "the example's replica is not on another cloud or shares the primary's region: this case would prove nothing"
REPLICA_KEYS=("${RPU}_AWS_ACCESS_KEY_ID=replica-cloud" "${RPU}_AWS_SECRET_ACCESS_KEY=s")
BUCKET=s3-openaether-scaleway-management-prod
got="$(run_restore replica SCW_AWS_ACCESS_KEY_ID=cluster-own SCW_AWS_SECRET_ACCESS_KEY=s "${REPLICA_KEYS[@]}")"
case "$got" in replica-cloud\|"s3 cp s3://${BUCKET}-backup/backups/talosconfig.gpg "*" --endpoint-url ${REPL_EP} --region ${REPL_REGION}")
    ok "the replica read carries the replica cloud's key, the -management- bucket, the file's endpoint and the replica's region" ;;
  *) bad "the replica read is wrong: ${got:-no aws call at all}" ;; esac
got="$(run_restore replica "${REPLICA_KEYS[@]}")"
case "$got" in replica-cloud\|*) ok "with only the replica cloud's keys in the shell it still reads (the cluster's cloud is gone)" ;;
  *) bad "no read with only the replica cloud's keys: ${got:-no aws call at all}" ;; esac
sort -u "$SB/log.compat" | grep -qx when_required && [ "$(sort -u "$SB/log.compat" | wc -l)" = 1 ] &&
  ok "the aws call carries the checksum setting the S3 stores need" || bad "aws ran without oa_aws_compat: $(sort -u "$SB/log.compat" | tr '\n' ' ')"
got="$(run_restore primary "${REPLICA_KEYS[@]}")"
[ -z "$got" ] && ok "the primary store is NOT read with the replica cloud's keys: no aws call without its own" ||
  bad "the primary was read with the wrong cloud's key: ${got}"
got="$(run_restore primary SCW_AWS_ACCESS_KEY_ID=cluster-own SCW_AWS_SECRET_ACCESS_KEY=s)"
case "$got" in cluster-own\|"s3 cp s3://${BUCKET}/backups/talosconfig.gpg "*" --endpoint-url ${PRIM_EP} --region ${PRIM_REGION}") ok "the primary read uses the cluster's own key, bucket, endpoint and region" ;;
  *) bad "the primary read is wrong: ${got:-no aws call at all}" ;; esac
# A refused read and a missing object are different repairs; each token a store may use for "missing" is its own case.
for miss in 'An error occurred (404) when calling the HeadObject operation: Key "backups/talosconfig.gpg" does not exist' \
            'An error occurred (NoSuchKey) when calling the GetObject operation: gone' 'A client error: Not Found'; do
  run_restore replica "${REPLICA_KEYS[@]}" OA_STUB_ERR="$miss" >/dev/null
  grep -q 'talosconfig.gpg not found in' "$SB/said" && ok "a missing object is reported as not found (${miss:0:40}...)" || bad "missing object ($miss): $(cat "$SB/said")"
done
run_restore replica "${REPLICA_KEYS[@]}" OA_STUB_ERR='An error occurred (403) when calling the HeadObject operation: Forbidden' >/dev/null
grep -q 'could not be fetched.*Forbidden' "$SB/said" && ! grep -q 'not found in' "$SB/said" &&
  ok "a refused read says what the store said, not 'not found'" || bad "refused read: $(cat "$SB/said")"

# The task passes --out only when OUT= is given (a live cluster's own kubeconfig sits in the cluster dir).
if command -v task >/dev/null 2>&1; then
  tdry() { (cd "$ROOT" && env -i PATH="$PATH" HOME="$SB" task -n "$@" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'); }
  with="$(tdry restore-artifacts PROVIDER=scaleway ROLE=failover FROM=replica OUT=/abs/dir)"; without="$(tdry restore-artifacts PROVIDER=scaleway ROLE=failover FROM=replica)"
  [ "$with" = "task: [restore-artifacts] ../../../scripts/ops/restore-artifacts.sh scaleway --role failover --from replica --out /abs/dir" ] && ! grep -q -- '--out' <<<"$without" &&
    ok "task restore-artifacts passes OUT= as --out, and only then" || bad "OUT= rendering: with=[$with] without=[$without]"
else
  echo "  ↷ task is not installed: the Taskfile entry is not exercised here"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
