#!/usr/bin/env bash
# scripts/ops/restore-state.sh: seeds a failover cluster's state from the replica of the provider
# that is gone, and the Taskfile entry that runs it. A stub tofu stands for the state and a stub aws
# for the two stores; each case runs the real script (SUT overrides its path). What this cannot say:
# that a real store, a real state or a real root behave like the stubs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/restore-state.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null 2>&1 || { echo "↷ jq absent — restore-state cannot be tested here"; exit 0; }

# The shipped examples, so the inline comments that once poisoned the tfvars reader are in the fixtures.
# A = an Outscale cluster whose replica sits on OVH; B = the failover on Scaleway: the replica store is
# neither A's cloud (gone) nor B's, so the key that opens it is a third pair, and its region is a third one.
ENVS="$ROOT/infrastructure/opentofu/cluster/envs"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
A="$TMP/management-outscale.tfvars"; B="$TMP/failover-scaleway.tfvars"
sed -E -e 's#^(s3_replica_endpoint[[:space:]]*=).*#\1 "https://s3.gra.io.cloud.ovh.net"#' \
       -e 's#^(s3_replica_region[[:space:]]*=).*#\1 "gra"#' "$ENVS/management-outscale.tfvars.example" >"$A"
cp "$ENVS/failover-scaleway.tfvars.example" "$B"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
SRC="$(oa_state_bucket "$(oa_project "$(tfv "$A" cluster_name)" "$(tfv "$A" bucket_suffix)")" outscale "$(tfv "$A" environment)")-backup"
DST="$(oa_state_bucket "$(oa_project "$(tfv "$B" cluster_name)" "$(tfv "$B" bucket_suffix)")" scaleway "$(tfv "$B" environment)")"
KEY_A="$(tfv "$A" cluster_name).tfstate"; KEY_B="$(tfv "$B" cluster_name).tfstate"
A_EP="$(tfv "$A" s3_replica_endpoint)"; A_REGION="$(tfv "$A" s3_replica_region)"; B_EP="$(tfv "$B" s3_primary_endpoint)"; B_REGION="$(tfv "$B" s3_primary_region)"
[ "$A_REGION" != "$B_REGION" ] && [ "$A_REGION" != "$(tfv "$A" s3_primary_region)" ] || { echo "✗ the fixtures must give each store a region of its own"; exit 1; }
# The three aws calls a run may make, as the stub logs them (<state> is the local copy): the replica is only ever read.
READ="replica-cloud|s3 cp s3://${SRC}/${KEY_A} <state> --endpoint-url ${A_EP} --region ${A_REGION}"
WRITE="target-own|s3 cp <state> s3://${DST}/${KEY_B} --endpoint-url ${B_EP} --region ${B_REGION}"
RM="target-own|s3 rm s3://${DST}/${KEY_B} --endpoint-url ${B_EP} --region ${B_REGION}"

mkdir -p "$TMP/bin"
# tofu: the target is empty until the stub aws has "uploaded" to it; `state rm` records what it was given.
# The OA_STUB_* switches make one step fail, or deliver a signal, the way a lock error or Ctrl-C would.
cat >"$TMP/bin/tofu" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "state list")
    if [ -f "$OA_STUB_UP" ]; then
      if [ -n "${OA_STUB_COPY_UNREADABLE:-}" ]; then echo "Error: decryption failed for all provided methods" >&2; exit 1; fi
      cat "$OA_STUB_LIST"
    elif [ -n "${OA_STUB_TARGET_ERR:-}" ]; then echo "$OA_STUB_TARGET_ERR" >&2; exit 1
    elif [ -n "${OA_STUB_TARGET_LIST:-}" ]; then printf '%s\n' "$OA_STUB_TARGET_LIST"
    else echo "Error: No state file was found!" >&2; exit 1; fi ;;
  "state pull") [ -z "${OA_STUB_PULL_FAIL:-}" ] || exit 1
    printf '{"resources":[{"module":"module.talos","type":"talos_machine_secrets","instances":[{"attributes":{"talos_version":"%s"}}]}]}' "${OA_STUB_RECORDED:-v1.14.2}" ;;
  "state rm") printf 'rm-called\n' >>"$OA_STUB_LOG"
    [ -z "${OA_STUB_RM_FAIL:-}" ] || exit 1
    if [ -n "${OA_STUB_RM_SIG:-}" ]; then kill "-$OA_STUB_RM_SIG" "$PPID"; sleep 0.3; fi
    shift 2; printf '%s\n' "$@" | grep -v '^-' >"$OA_STUB_RM" ;;
  *) exit 99 ;;
esac
STUB
# aws: logs the key it was handed (the cross-provider question) and every argument, serves the replica, records the upload.
cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
args=("$@"); for i in "${!args[@]}"; do case "${args[i]}" in */state) args[i]='<state>' ;; esac; done
printf '%s|%s\n' "${AWS_ACCESS_KEY_ID:-<unset>}" "${args[*]}" >>"$OA_STUB_LOG"
printf '%s\n' "${AWS_REQUEST_CHECKSUM_CALCULATION:-unset}" >>"$OA_STUB_LOG.compat"
case "$1 $2" in
  "s3 cp") case "$3" in
      s3://*) printf '%s' "$OA_STUB_BODY" >"$4" ;;
      *) : >"$OA_STUB_UP"; [ -z "${OA_STUB_PUT_FAIL:-}" ] || exit 1 ;;   # a failed write may still have landed
    esac ;;
  "s3 rm") [ -z "${OA_STUB_UNDO_FAIL:-}" ] || exit 1; rm -f "$OA_STUB_UP" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/tofu" "$TMP/bin/aws"
# What the stores hold, shaped like the real thing: an encrypted state carries serial and lineage too, so a check
# that looks for those cannot tell the two apart.
ENCRYPTED='{"serial":3,"lineage":"0b6c1f0e","meta":{"key_provider.pbkdf2.default":"x"},"encrypted_data":"x","encryption_version":"v0"}'
PLAIN='{"version":4,"terraform_version":"1.12.6","serial":3,"lineage":"0b6c1f0e","outputs":{},"resources":[]}'

FULL=$'module.ovh[0].openstack_compute_instance_v2.cp[0]\nmodule.ovh[0].openstack_networking_network_v2.net\nmodule.talos.data.talos_client_configuration.this\nmodule.talos.random_bytes.etcd_encryption_secret\nmodule.talos.random_password.disk_encryption_secret\nmodule.talos.talos_machine_bootstrap.this[0]\nmodule.talos.talos_machine_secrets.this[0]\nmodule.talos.terraform_data.machine_config_version[0]'
printf '%s\n' "$FULL" >"$TMP/full"
printf '%s\n' "$FULL" | grep -v 'secrets.this\|etcd_encryption\|disk_encryption' >"$TMP/nosecrets"

run() { # <list-file> [env assignments…]: one run of the script with the shell a failover operator has (TFA/TFB: other fixtures)
  local list="$1"; shift
  rm -f "$TMP/up" "$TMP/rm" "$TMP/log" "$TMP/log.compat"; : >"$TMP/log"
  OUT="$(cd "$CLUSTER_DIR" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP" OA_STUB_LIST="$list" OA_STUB_UP="$TMP/up" OA_STUB_RM="$TMP/rm" OA_STUB_LOG="$TMP/log" OA_STUB_BODY="$ENCRYPTED" \
    TF_VAR_encryption_passphrase=x OVH_AWS_ACCESS_KEY_ID=replica-cloud OVH_AWS_SECRET_ACCESS_KEY=s \
    SCW_AWS_ACCESS_KEY_ID=target-own SCW_AWS_SECRET_ACCESS_KEY=s "$@" "$SUT" "${TFA:-$A}" "${TFB:-$B}" 2>&1)"; RC=$?
}
calls() { grep -c "$1" "$TMP/log" || true; }
log_is() { [ "$(grep -v '^rm-called$' "$TMP/log")" = "$(printf '%s\n' "$@")" ]; }   # the aws calls, in order, and no other

echo "=== the replica is read with its own cloud's key and written with the target's ==="
run "$TMP/full"
[ "$RC" = 0 ] && ok "a replica holding the PKI is restored (rc 0)" || bad "restore failed: rc=$RC $OUT"
grep -qxF "$READ" "$TMP/log" &&
  ok "the replica of A is read from its -backup bucket with the cloud that holds it, at its endpoint and region" || bad "replica read: $(head -1 "$TMP/log")"
grep -qxF "$WRITE" "$TMP/log" &&
  ok "it lands in B's own state bucket, at B's endpoint and region, with B's key" || bad "target write: $(sed -n 2p "$TMP/log")"
log_is "$READ" "$WRITE" && ok "those are the only two aws calls: the replica store is read once, never written to or deleted from" ||
  bad "aws calls: $(grep -v '^rm-called$' "$TMP/log" | tr '\n' ';')"
[ -f "$TMP/up" ] && ! grep -q 'is empty again' <<<"$OUT" &&
  ok "a successful run leaves the seeded state in place" || bad "the seeded state was removed on success: $OUT"

[ -s "$TMP/log.compat" ] && ! grep -qvx when_required "$TMP/log.compat" &&
  ok "every aws call carries the checksum setting the S3 stores need (oa_aws_compat), the write included" || bad "aws ran without oa_aws_compat: $(sort -u "$TMP/log.compat" 2>&1 | tr '\n' ' ')"

echo "=== exactly the Talos secrets survive, in ONE state write ==="
KEPT=$'module.talos.random_bytes.etcd_encryption_secret\nmodule.talos.random_password.disk_encryption_secret\nmodule.talos.talos_machine_secrets.this[0]'
WANT="$(grep -vxF "$KEPT" "$TMP/full" | sort)"
[ "$(calls rm-called)" = 1 ] && ok "one tofu state rm" || bad "state rm called $(calls rm-called) times"
[ "$(sort "$TMP/rm" 2>/dev/null)" = "$WANT" ] && ok "it untracks every resource that is not one of the three" ||
  bad "untracked: $(tr '\n' ' ' <"$TMP/rm" 2>/dev/null)"
grep -qE 'talos_machine_secrets|etcd_encryption|disk_encryption' "$TMP/rm" 2>/dev/null && bad "a secret was untracked" || ok "no secret is among them"
# A state that already holds only the three: `tofu state rm` with no address is an error, so it must not be called.
printf '%s\n' "$KEPT" >"$TMP/allkept"; run "$TMP/allkept"
[ "$RC" = 0 ] && [ "$(calls rm-called)" = 0 ] && [ -f "$TMP/up" ] && ok "a state that holds only the three is kept as it is, with no state rm" || bad "all-kept state: rc=$RC rm=$(calls rm-called) $OUT"

# A failed run after the copy: the aws calls are the read, the write and ONE delete of B's key, nothing of the replica's.
undone() { [ "$RC" -ne 0 ] && [ ! -f "$TMP/up" ] && log_is "$READ" "$WRITE" "$RM"; }

echo "=== STATE_GENERATION reads an older generation of the replica, and only a well-formed one ==="
GEN=20261006T120000Z
run "$TMP/full" STATE_GENERATION="$GEN"
READ_GEN="replica-cloud|s3 cp s3://${SRC}/${KEY_A}.${GEN} <state> --endpoint-url ${A_EP} --region ${A_REGION}"
[ "$RC" = 0 ] && log_is "$READ_GEN" "$WRITE" &&
  ok "the object read is <key>.<timestamp> with the replica cloud's key, and the write is B's own key as before" || bad "generation read: rc=$RC $(grep -v '^rm-called$' "$TMP/log" | tr '\n' ';')"
for g in 20261006 latest 2026-10-06T12:00:00Z '../x' "${GEN}.bak"; do
  run "$TMP/full" STATE_GENERATION="$g"
  [ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q 'STATE_GENERATION' <<<"$OUT" &&
    ok "STATE_GENERATION=${g}: refused before any S3 call, naming the variable" || bad "STATE_GENERATION=${g}: rc=$RC calls=$(calls 's3 ') out=$OUT"
done
run "$TMP/nosecrets"
grep -q 'STATE_GENERATION' <<<"$OUT" && grep -q 'backup-state.sh --list' <<<"$OUT" &&
  ok "a replica with no PKI points at the older generations" || bad "no pointer to the generations: $OUT"

echo "=== it refuses, and leaves nothing behind ==="
run "$TMP/full" OA_STUB_TARGET_LIST=module.scw[0].something
[ "$RC" -ne 0 ] && [ "$(calls 's3 cp')" = 0 ] && ok "a target that already holds resources is refused before any copy" || bad "live target: rc=$RC cp=$(calls 's3 cp')"
run "$TMP/nosecrets"
undone && [ "$(calls rm-called)" = 0 ] &&
  ok "a replica with no Talos PKI is refused and the copy is removed" || bad "no-PKI replica: rc=$RC rm=$(calls rm-called) log=$(tr '\n' ';' <"$TMP/log")"
run "$TMP/full" OA_STUB_RECORDED=v1.99.0
undone && [ "$(calls rm-called)" = 0 ] &&
  ok "a pin below the version the PKI was made for is refused and the copy is removed" || bad "version guard: rc=$RC out=$OUT"
# The pin that counts is B's own file: A pins high and B low is refused, A low and B high is not.
printf '\ntalos_version = "v1.10.0"\n' | cat "$B" - >"$TMP/b-low.tfvars"; printf '\ntalos_version = "v1.99.0"\n' | cat "$A" - >"$TMP/a-high.tfvars"
printf '\ntalos_version = "v1.99.0"\n' | cat "$B" - >"$TMP/b-high.tfvars"; printf '\ntalos_version = "v1.0.0"\n' | cat "$A" - >"$TMP/a-low.tfvars"
TFA="$TMP/a-high.tfvars" TFB="$TMP/b-low.tfvars" run "$TMP/full"
undone && ok "B's pin is what is compared: A pinning high does not save a B pinned below" || bad "B low, A high: rc=$RC out=$OUT"
TFA="$TMP/a-low.tfvars" TFB="$TMP/b-high.tfvars" run "$TMP/full"
[ "$RC" = 0 ] && ok "...and A pinning low does not refuse a B pinned at or above" || bad "B high, A low: rc=$RC out=$OUT"
run "$TMP/full" OA_STUB_BODY="$PLAIN"
[ "$RC" -ne 0 ] && [ "$(calls "s3 cp .* s3://${DST}/")" = 0 ] && ok "a plaintext state (serial and lineage and all) is never uploaded" || bad "plaintext: rc=$RC"
for k in cluster_name s3_replica_endpoint s3_replica_region; do
  sed -E "/^[[:space:]]*${k}[[:space:]]*=/d" "$A" >"$TMP/a-no.tfvars"; TFA="$TMP/a-no.tfvars" run "$TMP/full"
  [ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q "$k" <<<"$OUT" && ok "A without ${k}: refused before any S3 call, naming it" || bad "A without ${k}: rc=$RC calls=$(calls 's3 ') out=$OUT"
done
for k in cluster_name s3_primary_endpoint s3_primary_region; do
  sed -E "/^[[:space:]]*${k}[[:space:]]*=/d" "$B" >"$TMP/b-no.tfvars"; TFB="$TMP/b-no.tfvars" run "$TMP/full"
  [ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q "$k" <<<"$OUT" && ok "B without ${k}: refused before any S3 call, naming it" || bad "B without ${k}: rc=$RC calls=$(calls 's3 ') out=$OUT"
done
run "$TMP/full" TF_VAR_encryption_passphrase=
[ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q 'TF_VAR_encryption_passphrase' <<<"$OUT" && ok "no passphrase: refused up front, naming it" || bad "no passphrase: rc=$RC"
run "$TMP/full" OVH_AWS_ACCESS_KEY_ID= OVH_AWS_SECRET_ACCESS_KEY=
[ "$RC" -ne 0 ] && [ "$(calls 's3 cp')" = 0 ] && ok "no keys for the replica's cloud: refused before any copy" || bad "no replica keys: rc=$RC cp=$(calls 's3 cp')"
run "$TMP/full" SCW_AWS_ACCESS_KEY_ID= SCW_AWS_SECRET_ACCESS_KEY=
[ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q 'SCW_AWS' <<<"$OUT" && ok "no keys for B's own store: refused before any call, naming them" || bad "no target keys: rc=$RC calls=$(calls 's3 ') out=$OUT"

echo "=== it will not read the replica onto itself, nor guess what an unreadable target holds ==="
# One object named by two files: a target whose environment spells the replica's bucket. Only a pair like
# that reaches the guard, and there the undo below would delete the replica, the only copy of the PKI.
SA="$TMP/same-a.tfvars"; SB="$TMP/same-b.tfvars"
sed -E 's#^(s3_replica_endpoint[[:space:]]*=[[:space:]]*)"[^"]*"#\1"https://s3.fr-par.scw.cloud"#' "$B" >"$SA"
sed -E 's#^(environment[[:space:]]*=[[:space:]]*)"prod"#\1"prod-backup"#' "$SA" >"$SB"
[ "$(oa_state_bucket "$(oa_project "$(tfv "$SA" cluster_name)" "$(tfv "$SA" bucket_suffix)")" scaleway "$(tfv "$SA" environment)")-backup" = \
  "$(oa_state_bucket "$(oa_project "$(tfv "$SB" cluster_name)" "$(tfv "$SB" bucket_suffix)")" scaleway "$(tfv "$SB" environment)")" ] &&
  ok "the two fixtures name one bucket (so the next case cannot pass by accident)" || bad "the same-object fixtures name two buckets"
TFA="$SA" TFB="$SB" run "$TMP/full"
[ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q 'same object' <<<"$OUT" &&
  ok "a replica that is its own target is refused before a single read, write or delete" || bad "same object: rc=$RC calls=$(calls 's3 ')"
# Same bucket, another key: a different object, so a cluster named like A's neighbour is not refused.
SB2="$TMP/same-b2.tfvars"; sed -E 's#^(cluster_name[[:space:]]*=[[:space:]]*)"[^"]*"#\1"openaether-other"#' "$SB" >"$SB2"
TFA="$SA" TFB="$SB2" run "$TMP/full"
[ "$RC" = 0 ] && grep -q "s3://$(oa_state_bucket "$(oa_project "$(tfv "$SB2" cluster_name)" "$(tfv "$SB2" bucket_suffix)")" scaleway "$(tfv "$SB2" environment)")/$(tfv "$SB2" cluster_name).tfstate" "$TMP/log" &&
  ok "the same bucket under another key is another object: not refused" || bad "same bucket, other key: rc=$RC $OUT"
run "$TMP/full" OA_STUB_TARGET_ERR='Error: Failed to load state: decryption failed for all provided methods'
[ "$RC" -ne 0 ] && [ "$(calls 's3 ')" = 0 ] && grep -q 'is unknown' <<<"$OUT" &&
  ok "a target state that cannot be read is treated as live, never as empty" || bad "unreadable target: rc=$RC calls=$(calls 's3 ')"

echo "=== whatever stops the run after the copy takes the copy out again ==="
run "$TMP/full" OA_STUB_COPY_UNREADABLE=1
undone && [ "$(calls rm-called)" = 0 ] && grep -q 'TF_VAR_encryption_passphrase' <<<"$OUT" &&
  ok "a copy that cannot be read (wrong passphrase) is removed, and the passphrase is named" || bad "unreadable copy: rc=$RC undo=$(calls 's3 rm') out=$OUT"
run "$TMP/full" OA_STUB_RM_FAIL=1
undone && [ "$(calls rm-called)" = 1 ] && ok "a failing tofu state rm (a lock error) removes the copy" || bad "state rm failure: rc=$RC undo=$(calls 's3 rm')"
run "$TMP/full" OA_STUB_PULL_FAIL=1
undone && [ "$(calls rm-called)" = 0 ] && ok "a failing state pull removes the copy before anything is untracked" || bad "state pull failure: rc=$RC undo=$(calls 's3 rm')"
run "$TMP/full" OA_STUB_PUT_FAIL=1
undone && ok "a write that errored but landed is removed too" || bad "failed write: rc=$RC undo=$(calls 's3 rm')"
for sig in TERM INT; do
  if [ "$sig" = INT ] && [ "$(bash -c 'kill -INT $$; echo ignored' 2>/dev/null)" = ignored ]; then
    echo "  ↷ SIGINT is ignored in this shell (it is a background job's): the Ctrl-C case is not run here"; continue
  fi
  run "$TMP/full" OA_STUB_RM_SIG="$sig" 2>/dev/null
  undone && ok "SIG${sig} during the untrack removes the copy" || bad "SIG${sig}: rc=$RC undo=$(calls 's3 rm')"
done
run "$TMP/nosecrets" OA_STUB_UNDO_FAIL=1
[ "$RC" -ne 0 ] && grep -q 'could not remove the copy' <<<"$OUT" && ! grep -q 'is empty again' <<<"$OUT" &&
  ok "a delete that fails is said so, with the key to remove by hand" || bad "failed undo: rc=$RC out=$OUT"

echo "=== the task hands the script A's file, then B's, after B's backend is inited and the prod rule armed ==="
# Dry run of the real Taskfile: what it would execute, not what the script then does.
if command -v task >/dev/null 2>&1; then
  tdry() { (cd "$ROOT" && env -i PATH="$PATH" HOME="$TMP" task -n "$@" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'); }
  WANT_TASK='task: [restore-state] ../../../scripts/internal/ensure-buckets.sh envs/failover-ovh.tfvars --preflight
task: [restore-state] tofu init -reconfigure $(../../../scripts/internal/tf-backend.sh envs/failover-ovh.tfvars)
task: [restore-state] ../../../scripts/ops/restore-state.sh envs/management-scaleway.tfvars envs/failover-ovh.tfvars'
  got="$(tdry restore-state PROVIDER=ovh ROLE=failover FROM=management-scaleway)"
  [ "$got" = "$WANT_TASK" ] && ok "preflight armed on B's file, init on B's file, then restore-state.sh <A's file> <B's file>" || bad "rendered: $got"
  for missing in 'FROM=x:PROVIDER' 'PROVIDER=ovh:FROM'; do
    got="$(tdry restore-state "${missing%%:*}")"
    grep -q "missing required variables: ${missing##*:}" <<<"$got" && ! grep -q 'restore-state\.sh' <<<"$got" && ok "without ${missing##*:}: refused before anything is rendered" || bad "without ${missing##*:}: $got"
  done
  got="$(tdry restore-state PROVIDER=local FROM=x)"
  grep -qE "unknown provider 'local'|not for this family" <<<"$got" && ! grep -q 'restore-state\.sh' <<<"$got" && ok "PROVIDER=local is refused" || bad "PROVIDER=local: $got"
else
  echo "  ↷ task is not installed: the Taskfile entry is not exercised here"
fi

echo "=== the three kept addresses are still resources of modules/talos ==="
# The script keeps an allowlist: a renamed secret would be untracked (the PKI is guarded, the secretbox key is not).
while IFS= read -r addr; do
  t="${addr#module.talos.}"; n="${t#*.}"; t="${t%%.*}"; n="${n%%[*}"
  grep -qE "^resource \"${t}\" \"${n}\"" "$ROOT/infrastructure/opentofu/modules/talos/main.tf" &&
    ok "modules/talos declares ${t}.${n}" || bad "modules/talos no longer declares ${t}.${n}: the keep list is stale"
done <<<"$KEPT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
