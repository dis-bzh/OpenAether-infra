#!/usr/bin/env bash
# ==============================================================================
# The three scripts that stand between a cluster and a lost state or etcd,
# measured offline: backup-state.sh (and its dated generations, #267),
# etcd-snapshot.sh, resolve-s3-cred.sh.
#
# None of them had a harness. Each is a data-loss path that reports ✓ on the
# strength of its own exit code, and two defects were found writing this file:
# etcd-snapshot's retention slice went NEGATIVE with fewer than $KEEP snapshots
# (jq counts a negative end from the END — 28 of 29 deleted at KEEP=30), and a
# swapped <kind>/<type> to s3_cred printed the secret where an id was expected.
#
# Stub `tofu`, `aws`, `talosctl` on PATH record their argv AND the credential
# they ran with; `gpg` and `jq` are real. No cloud, no account, no bill.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT="$PWD"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { # <label> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"
}

SB="$(mktemp -d)"; LOG="$SB/calls.log"; CAP="$SB/captured"; mkdir -p "$CAP"
trap 'rm -rf "$SB"' EXIT

SCW_EP=https://s3.fr-par.scw.cloud
OSC_EP=https://oos.eu-west-2.outscale.com

# --- stubs --------------------------------------------------------------------
# tofu: `output -json backup_targets` answers from a file, or fails the way the
# real one does — a missing output and a broken backend are DIFFERENT failures.
cat >"$SB/tofu" <<'STUB'
#!/usr/bin/env bash
printf 'tofu:%s\n' "$*" >>"$OA_STUB_LOG"
case "$*" in
  "output -json backup_targets")
    case "${OA_STUB_TOFU_MODE:-ok}" in
      ok)     cat "$OA_STUB_TARGETS" ;;
      absent) echo 'Error: Output "backup_targets" not found' >&2; exit 1 ;;
      broken) echo 'Error: Failed to load state: AccessDenied: Access Denied' >&2; exit 1 ;;
    esac ;;
  "output -json")
    printf '{"control_plane_private_ips":{"value":%s}}\n' "${OA_STUB_CP_IPS:-[]}" ;;
  "state list -no-color") # the state's addresses, from a file; empty when none is given
    # OA_STUB_STATE_FAIL_FROM=2: unreadable from the second read on (the first is the guard's, the second is ours).
    [ -z "${OA_STUB_STATE_FAIL_FROM:-}" ] || [ "$(grep -c '^tofu:state list' "$OA_STUB_LOG")" -lt "$OA_STUB_STATE_FAIL_FROM" ] \
      || { echo 'Error: Failed to load state: AccessDenied' >&2; exit 1; }
    [ -z "${OA_STUB_STATE:-}" ] || cat "$OA_STUB_STATE" ;;
esac
exit 0
STUB
# aws: logs the access key it was handed (that is the whole cross-provider
# question), captures every upload, fabricates every download. With OA_STUB_STORE
# it is also a small object store (one file per s3://bucket/key) that serves
# list, put and delete, so retention is checked on what a bucket would hold.
cat >"$SB/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws:%s|%s\n' "${AWS_ACCESS_KEY_ID:-<unset>}" "$*" >>"$OA_STUB_LOG"
obj() { printf '%s/%s' "$OA_STUB_STORE" "${1#s3://}"; }
case "$1 $2" in
  "s3 cp")
    if [ -f "$3" ]; then
      ! grep -Eq -- "${OA_STUB_PUT_FAIL:-@no-such-key@}" <<<"$4" || exit 1
      cp "$3" "$OA_STUB_CAP/$(basename "$4")"
      [ -z "${OA_STUB_STORE:-}" ] || { mkdir -p "$(dirname "$(obj "$4")")"; cp "$3" "$(obj "$4")"; }
    else [ "${OA_STUB_DL_EXIT:-0}" = 0 ] || exit "$OA_STUB_DL_EXIT"; printf '%s' "${OA_STUB_BODY:-CIPHERTEXT-FROM-PRIMARY}" >"$4"; fi ;;
  "s3 rm") [ -z "${OA_STUB_RM_FAIL:-}" ] || exit 1; [ -z "${OA_STUB_STORE:-}" ] || rm -f "$(obj "$3")" ;;
  "s3api list-objects-v2")
    [ -z "${OA_STUB_LIST_FAIL:-}" ] || exit 1
    if [ -n "${OA_STUB_STORE:-}" ]; then
      while [ $# -gt 0 ]; do case "$1" in --bucket) bucket="$2" ;; --prefix) prefix="$2" ;; esac; shift; done
      ( cd "$OA_STUB_STORE/$bucket" 2>/dev/null && find . -type f | sed 's#^\./##' | LC_ALL=C sort ) \
        | while IFS= read -r k; do case "$k" in "$prefix"*) printf '%s\n' "$k" ;; esac; done \
        | jq -Rn '[inputs | [., "2026-10-06T00:00:00+00:00", 1]] | if length == 0 then null else . end'
    else printf '%s\n' "${OA_STUB_LIST:-null}"; fi ;;
esac
exit 0
STUB
# date: the generation name is the clock, so a case sets it; every other use goes through.
cat >"$SB/date" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-u +%Y%m%dT%H%M%SZ" ] && [ -n "${OA_STUB_NOW:-}" ]; then echo "$OA_STUB_NOW"; else command -p date "$@"; fi
STUB
# talosctl: writes a snapshot unless the endpoint is one declared down.
cat >"$SB/talosctl" <<'STUB'
#!/usr/bin/env bash
printf 'talosctl:%s\n' "$*" >>"$OA_STUB_LOG"
out="${!#}"; ep=""
while [ $# -gt 0 ]; do [ "$1" = -e ] && ep="$2"; shift; done
case ",${OA_STUB_TALOS_DOWN:-}," in *",$ep,"*|*",all,"*) exit 1 ;; esac
printf 'ETCD-PLAINTEXT-%s' "$ep" >"$out"
exit 0
STUB
chmod +x "$SB/tofu" "$SB/aws" "$SB/talosctl" "$SB/date"

targets() { # <provider|""> <replica-endpoint> — writes the backup_targets JSON
  cat >"$SB/targets.json" <<EOF
{ $( [ -n "$1" ] && printf '"provider": "%s",' "$1" )
  "state_bucket_primary": "s3-example-scaleway-tfstate-test",
  "state_bucket_replica": "s3-example-scaleway-tfstate-test-backup",
  "state_key": "cluster/terraform.tfstate",
  "artifact_bucket_primary": "s3-example-scaleway-management-test",
  "artifact_bucket_replica": "s3-example-scaleway-management-test-backup",
  "primary_endpoint": "$SCW_EP", "primary_region": "fr-par",
  "replica_endpoint": "$2", "replica_region": "eu-west-2" }
EOF
}
# Every run: the env is EXACTLY what is listed — no key leaks in from the
# developer's own shell, which is how a wrong-provider copy hid on 2026-08-19.
run_raw() { # <script> [args...] — env from $ENV_EXTRA (space-separated k=v)
  : >"$LOG"; rm -f "$CAP"/*
  # shellcheck disable=SC2086
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_LOG="$LOG" OA_STUB_CAP="$CAP" \
      OA_STUB_TARGETS="$SB/targets.json" $ENV_EXTRA "$@" </dev/null
}
run()    { run_raw "$@" 2>&1; }          # everything the operator would see
stdout() { run_raw "$@" 2>/dev/null; }   # what a Taskfile `env: sh:` would capture
calls()  { grep -c "^$1" "$LOG"; }
uploads() { grep -E '^aws:[^|]*\|s3 cp [^s]' "$LOG"; }   # local → s3://
downloads() { grep -E '^aws:[^|]*\|s3 cp s3://' "$LOG"; }
rms() { grep -E '^aws:[^|]*\|s3 rm ' "$LOG"; }
key_of() { sed -E 's/^aws:([^|]*)\|.*/\1/' <<<"$1"; }

# =============================================================================
echo "=== backup-state.sh ==="
BS=scripts/ops/backup-state.sh

echo "--- same provider: download from primary, upload to replica, SSE on, same key ---"
targets scaleway "$SCW_EP"
ENV_EXTRA="AWS_ACCESS_KEY_ID=AMBIENT-AK AWS_SECRET_ACCESS_KEY=AMBIENT-SK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "the script completes" 0 "$RC"
is "one download" 1 "$(downloads | wc -l)"
is "one upload" 1 "$(uploads | wc -l)"
DL="$(downloads)"; UP="$(uploads)"
grep -q "s3://s3-example-scaleway-tfstate-test/cluster/terraform.tfstate" <<<"$DL" \
  && ok "the download names the primary bucket and the state key" \
  || bad "download: $DL"
grep -q -- "--endpoint-url $SCW_EP" <<<"$DL" && ok "…against the primary endpoint" || bad "download endpoint: $DL"
grep -q "s3://s3-example-scaleway-tfstate-test-backup/cluster/terraform.tfstate" <<<"$UP" \
  && ok "the upload lands in the replica bucket under the SAME key" \
  || bad "upload: $UP"
grep -q -- "--sse AES256" <<<"$UP" && ok "server-side encryption is layered on the copy" || bad "no --sse on the upload: $UP"
is "the download authenticates as the ambient (cluster) keys" AMBIENT-AK "$(key_of "$DL")"
is "same provider, no backup keys: the upload falls back to the primary keys" PRIMARY-AK "$(key_of "$UP")"
grep -q "SAME provider" <<<"$OUT" && ok "and the result says the copy is on the SAME provider" || bad "no SAME-provider warning: $OUT"

echo "--- cross-provider: the copy signs with the keys of the cloud that HOLDS the bucket ---"
targets scaleway "$OSC_EP"
ENV_EXTRA="AWS_ACCESS_KEY_ID=AMBIENT-AK AWS_SECRET_ACCESS_KEY=AMBIENT-SK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK OUTSCALE_BACKUP_AWS_ACCESS_KEY_ID=OSC-BK-AK OUTSCALE_BACKUP_AWS_SECRET_ACCESS_KEY=OSC-BK-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "the script completes" 0 "$RC"
is "the upload authenticates with the Outscale backup keys, not the cluster's" OSC-BK-AK "$(key_of "$(uploads)")"
grep -q -- "--endpoint-url $OSC_EP" <<<"$(uploads)" && ok "…against the replica endpoint" || bad "upload endpoint: $(uploads)"
grep -q "on $OSC_EP" <<<"$OUT" && ok "and the result names where the copy went" || bad "result does not name the replica endpoint: $OUT"

echo "--- provider missing from the output: derived from the bucket name ---"
targets "" "$SCW_EP"
ENV_EXTRA="AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "the script completes without a provider field" 0 "$RC"
is "and still resolves the Scaleway keys for the upload" PRIMARY-AK "$(key_of "$(uploads)")"

echo "--- no backup_targets output: 'nothing to replicate yet' is exit 0 and no aws call ---"
targets scaleway "$SCW_EP"
ENV_EXTRA="OA_STUB_TOFU_MODE=absent AWS_ACCESS_KEY_ID=AMBIENT-AK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "exit 0" 0 "$RC"
is "zero aws calls" 0 "$(calls aws:)"
grep -q "Skipping state backup" <<<"$OUT" && ok "and it says it skipped" || bad "silent skip: $OUT"

echo "--- the backend cannot be read: that is NOT 'no backup configured' ---"
ENV_EXTRA="OA_STUB_TOFU_MODE=broken AWS_ACCESS_KEY_ID=AMBIENT-AK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "exit 1" 1 "$RC"
is "zero aws calls" 0 "$(calls aws:)"
grep -q "AccessDenied" <<<"$OUT" && ok "tofu's own error is shown" || bad "the cause is hidden: $OUT"
grep -q "not 'no backup configured'" <<<"$OUT" && ok "and the two answers are told apart" || bad "$OUT"

echo "--- a state that lost its secrets never replaces the replica (#66) ---"
# What infra-down-plan leaves behind: the bootstrap is tracked, the machine secrets are not. The replica holds
# the pre-untrack copy, and replicating now would turn the undo into the same lost state.
printf 'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.talos_machine_bootstrap.this[0]\n' >"$SB/lost.state"
printf '%s\nmodule.talos.talos_machine_secrets.this[0]\n' "$(cat "$SB/lost.state")" >"$SB/kept.state"
ENV_EXTRA="OA_STUB_STATE=$SB/lost.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "a state without its secrets was replicated: $OUT"
is "no download and no upload" 0 "$(calls aws:)"
grep -q "talos_machine_secrets" <<<"$OUT" && grep -q "nothing was replicated" <<<"$OUT" \
  && ok "and it says why, and that nothing moved" || bad "silent or vague refusal: $OUT"
ENV_EXTRA="OA_STUB_STATE=$SB/kept.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "the same state with its secrets is replicated" 0 "$RC"
is "…by two uploads: the dated generation, then the current object" 2 "$(uploads | wc -l)"

echo "--- the download fails: no upload, no ✓ ---"
ENV_EXTRA="OA_STUB_DL_EXIT=1 AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
[ "$RC" -ne 0 ] && ok "a failed download fails the script (rc=$RC)" || bad "rc=0 after a failed download"
is "nothing was uploaded" 0 "$(uploads | wc -l)"
grep -q "✓" <<<"$OUT" && bad "a ✓ was printed for a copy that never happened" || ok "no ✓ printed"

# =============================================================================
echo "--- generations: a dated copy first, then the current object, the same bytes (#267) ---"
REPL=s3-example-scaleway-tfstate-test-backup; KEYP=cluster/terraform.tfstate; ST="$SB/store"
GEN_ENV="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/kept.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
ts()   { printf '202610%02dT000000Z' "$1"; }                       # the n-th day of a made-up October
seed() { mkdir -p "$ST/$REPL/$(dirname "$KEYP")"; printf '%s' "${2:-SEEDED-$1}" >"$ST/$REPL/$KEYP${3:-}"; }   # <ts> [body] [.suffix]: one object
held() { (cd "$ST/$REPL" 2>/dev/null && find . -type f | sed 's#^\./##' | LC_ALL=C sort); }              # every key the replica holds
gens() { held | grep -E '\.[0-9]{8}T[0-9]{6}Z$' | sed "s#^$KEYP\.##" | tr '\n' ' '; }                     # the timestamps among them
want() { local t; for t in "$@"; do printf '%s ' "$(ts "$t")"; done; }                                  # gens' answer for days n…
bak()  { ENV_EXTRA="$GEN_ENV OA_STUB_NOW=${2:-$(ts "$1")} OA_STUB_BODY=STATE-$1 ${3:-}"; OUT="$(run "$BS" "$ROOT")"; RC=$?; }  # <n> [ts] [env]
body() { cat "$ST/$REPL/$KEYP${1:-}" 2>/dev/null; }

rm -rf "$ST"; bak 1
is "the run completes" 0 "$RC"
is "two uploads" 2 "$(uploads | wc -l)"
grep -qF "s3://$REPL/$KEYP.$(ts 1) --sse AES256" <<<"$(uploads | sed -n 1p)" \
  && ok "the FIRST upload is the dated generation, <key>.<UTC timestamp>, with SSE" || bad "first upload: $(uploads | sed -n 1p)"
grep -qF "s3://$REPL/$KEYP --sse AES256" <<<"$(uploads | sed -n 2p)" \
  && ok "the SECOND is the current object, so it is only replaced once its dated twin is stored" || bad "second upload: $(uploads | sed -n 2p)"
is "the generation is signed with the replica's keys, like the current object" PRIMARY-AK "$(key_of "$(uploads | sed -n 1p)")"
is "the generation holds exactly the bytes of the current object" STATE-1 "$(body ".$(ts 1)")"
is "…and so does the current object" STATE-1 "$(body)"
! grep -qE '[^A-Za-z0-9./_-]' <<<"$(held)" && ok "the key names use letters, digits and . / _ - only (no colon, no space)" || bad "key names: $(held)"
grep -q "generation $KEYP.$(ts 1) kept" <<<"$OUT" && ok "and the result names the generation and where to list them" || bad "$OUT"

echo "--- retention: the N+1th run removes the oldest generation and nothing else ---"
for n in 2 3 4 5; do bak "$n"; done
is "five generations are all kept" "$(want 1 2 3 4 5)" "$(gens)"
is "…and nothing was removed on the way (fewer than N is never a negative slice)" 0 "$(rms | wc -l)"
bak 6
is "the sixth run removes exactly one object" 1 "$(rms | wc -l)"
grep -qF "s3://$REPL/$KEYP.$(ts 1) " <<<"$(rms)" && ok "…the oldest generation" || bad "removed: $(rms)"
is "the five newest remain" "$(want 2 3 4 5 6)" "$(gens)"
is "the current object is untouched by the prune and holds the latest state" STATE-6 "$(body)"
bak 7
is "the seventh removes the next oldest, one per run" "$(want 3 4 5 6 7)" "$(gens)"
bak 8 "" "STATE_GENERATIONS=2"
is "STATE_GENERATIONS=2 keeps the two newest" "$(want 7 8)" "$(gens)"
bak 9 "" "STATE_GENERATIONS=7"
is "a larger STATE_GENERATIONS keeps what it is told to" "$(want 7 8 9)" "$(gens)"

echo "--- retention: the newest generation is never a victim, whatever the names say ---"
rm -rf "$ST"; for n in 1 2 3 4 5 6 7 8 9; do seed "$(ts "$n")" "" ".$(ts "$n")"; done
bak 10
is "nine generations plus the new one, five kept: the five oldest go" "$(want 6 7 8 9 10)" "$(gens)"
is "five removals" 5 "$(rms | wc -l)"
! grep -qF "$(ts 10)" <<<"$(rms)" && ! grep -qF "$(ts 9)" <<<"$(rms)" && ok "neither the new generation nor the one before it was removed" || bad "removed: $(rms)"
# A machine whose clock is behind writes a name that sorts BEFORE every other: by name alone it is the oldest and
# would be pruned the moment it is written, taking the newest state with it.
rm -rf "$ST"; for n in 1 2 3 4 5; do seed "$(ts "$n")" "" ".$(ts "$n")"; done
bak 6 20200101T000000Z
is "a generation with an old clock survives its own run" "20200101T000000Z $(want 2 3 4 5)" "$(gens)"
is "…it holds the newest state" STATE-6 "$(body .20200101T000000Z)"

echo "--- only a generation is ever removed ---"
rm -rf "$ST"; for n in 1 2 3 4 5 6; do seed "$(ts "$n")" "" ".$(ts "$n")"; done
for stray in .bak .20261001 ".$(ts 1).bak" .old 2; do seed x "KEEP-ME" "$stray"; done
bak 7
is "the oldest two generations go" "$(want 3 4 5 6 7)" "$(gens)"
for stray in .bak .20261001 ".$(ts 1).bak" .old 2; do
  [ "$(body "$stray")" = KEEP-ME ] && ok "$KEYP$stray was not touched" || bad "$KEYP$stray was removed or changed"
done

echo "--- a state without the secrets writes no generation and prunes none ---"
rm -rf "$ST"; for n in 1 2 3; do seed "$(ts "$n")" "" ".$(ts "$n")"; done; seed x OLD-CURRENT
BEFORE="$(held)|$(cat "$ST/$REPL"/cluster/* | md5sum)"
ENV_EXTRA="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/lost.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK OA_STUB_NOW=$(ts 9)"
OUT="$(run "$BS" "$ROOT")"; RC=$?
[ "$RC" -ne 0 ] && ok "the refused state is refused (rc=$RC)" || bad "replicated a state without its secrets"
is "no aws call at all: no generation, no replacement, no prune" 0 "$(calls aws:)"
is "the store is byte for byte what it was, the current object included" "$BEFORE" "$(held)|$(cat "$ST/$REPL"/cluster/* | md5sum)"
# A state with no Talos resources passes the guard (nothing to lose) and still replicates, but it is not a generation.
: >"$SB/empty.state"; rm -rf "$ST"; for n in 1 2 3 4 5 6 7; do seed "$(ts "$n")" "" ".$(ts "$n")"; done; seed x OLD-CURRENT
ENV_EXTRA="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/empty.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK OA_STUB_NOW=$(ts 9) OA_STUB_BODY=EMPTY-STATE"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "a state with no Talos resources still replicates, by one upload" "0 1" "$RC $(uploads | wc -l)"
is "…it replaces the current object" EMPTY-STATE "$(body)"
is "…but adds no generation and prunes none, even with more than N held" "$(want 1 2 3 4 5 6 7)" "$(gens)"
is "…and lists nothing" 0 "$(calls 'aws:[^|]*|s3api')"
grep -q "no generation written" <<<"$OUT" && ok "and the result says no generation was written" || bad "$OUT"
# Talos resources that are not the secrets (and not the bootstrap, a config or the kubeconfig, which the guard refuses) are not them.
printf 'module.scw[0].scaleway_instance_server.worker[0]\nmodule.talos.random_bytes.etcd_encryption_secret\n' >"$SB/partial.state"
rm -rf "$ST"; ENV_EXTRA="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/partial.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK OA_STUB_NOW=$(ts 9)"
OUT="$(run "$BS" "$ROOT")"; RC=$?
is "a state with other module.talos resources but not the secrets writes no generation" "0 1 " "$RC $(uploads | wc -l) $(gens)"
# The guard read the state and passed; if the second read fails nobody knows whether this state holds them, so nothing moves.
ENV_EXTRA="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/kept.state OA_STUB_STATE_FAIL_FROM=2 AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" "$ROOT")"; RC=$?
[ "$RC" -ne 0 ] && [ "$(calls aws:)" = 0 ] && grep -q "cannot read the state" <<<"$OUT" && grep -q AccessDenied <<<"$OUT" \
  && ok "a state that cannot be read the second time moves nothing and shows tofu's error" || bad "unreadable state: rc=$RC aws=$(calls aws:) $OUT"
echo "--- a failed generation write leaves the current replica alone ---"
rm -rf "$ST"; for n in 1 2; do seed "$(ts "$n")" "" ".$(ts "$n")"; done; seed x OLD-CURRENT
bak 3 "" "OA_STUB_PUT_FAIL=terraform.tfstate.2026"
[ "$RC" -ne 0 ] && ok "the run fails (rc=$RC)" || bad "rc=0 although no generation was written"
is "the current object still holds the previous state" OLD-CURRENT "$(body)"
is "one upload was tried, and it was not the current object" 1 "$(uploads | wc -l)"
is "nothing was removed" 0 "$(rms | wc -l)"
is "no generation was added, none was lost" "$(want 1 2)" "$(gens)"
grep -q "left as it is" <<<"$OUT" && ! grep -q "✓" <<<"$OUT" && ok "the message says so and no ✓ is printed" || bad "$OUT"
bak 3 "" "OA_STUB_PUT_FAIL=tfstate\$"
[ "$RC" -ne 0 ] && ok "a current object that cannot be written fails the run too (rc=$RC)" || bad "rc=0 after a failed current write"
is "…its generation was written and is kept" "$(want 1 2 3)" "$(gens)"
grep -q "generation .* was written" <<<"$OUT" && ok "…and the message says which" || bad "$OUT"
is "…and no prune ran: nothing is listed or removed after a failed write" "0 0" "$(calls 'aws:[^|]*|s3api') $(rms | wc -l)"

echo "--- the prune is housekeeping: its failures cost space, never the backup ---"
rm -rf "$ST"; for n in 1 2 3 4 5 6 7; do seed "$(ts "$n")" "" ".$(ts "$n")"; done
bak 8 "" "OA_STUB_LIST_FAIL=1"
is "a listing that fails still completes the backup" 0 "$RC"
grep -q "none was pruned" <<<"$OUT" && grep -q "✓ tfstate replicated" <<<"$OUT" && ok "…says nothing was pruned, and the copy is reported" || bad "$OUT"
is "…and removes nothing" "$(want 1 2 3 4 5 6 7 8)" "$(gens)"
bak 9 "" "OA_STUB_RM_FAIL=1"
is "a delete that fails still completes the backup" 0 "$RC"
grep -q "could not remove the old generation" <<<"$OUT" && ok "…and names the object it could not remove" || bad "$OUT"

echo "--- a retention that keeps nothing is refused before any call ---"
for bad_n in 0 -1 abc 2.5; do
  bak 1 "" "STATE_GENERATIONS=$bad_n"
  [ "$RC" -ne 0 ] && [ "$(calls aws:)" = 0 ] && [ "$(calls tofu:)" = 0 ] && grep -q "STATE_GENERATIONS" <<<"$OUT" \
    && ok "STATE_GENERATIONS=$bad_n: refused, naming the variable, with no call made" || bad "STATE_GENERATIONS=$bad_n: rc=$RC calls=$(wc -l <"$LOG") $OUT"
done

echo "--- --list: what the replica holds, newest first, readable, read-only ---"
rm -rf "$ST"; for n in 1 3 2; do seed "$(ts "$n")" "" ".$(ts "$n")"; done; seed x CURRENT
for stray in .bak 2 ".$(ts 1).bak"; do seed x STRAY "$stray"; done
ENV_EXTRA="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/kept.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" --list "$ROOT")"; RC=$?
is "the listing completes" 0 "$RC"
is "current object first, then the generations newest first, no stray key" \
  "$KEYP $KEYP.$(ts 3) $KEYP.$(ts 2) $KEYP.$(ts 1)" "$(awk -F'\t' '/^  (current|generation)/ {printf "%s ", $4}' <<<"$OUT" | sed 's/ $//')"
grep -qP '^  generation\t' <<<"$OUT" && grep -qP '\t2026-10-06T00:00:00\+00:00\t1\t' <<<"$OUT" && ok "each row carries its kind, its date and its size" || bad "row layout: $OUT"
is "one aws call, a read: no download, no upload, no delete" "1 0 0 0" "$(calls aws:) $(downloads | wc -l) $(uploads | wc -l) $(rms | wc -l)"
ENV_EXTRA="OA_STUB_STORE=$ST OA_STUB_STATE=$SB/lost.state AWS_ACCESS_KEY_ID=AMBIENT-AK SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(run "$BS" --list "$ROOT")"; RC=$?
is "with the secrets gone from the state, which is when it is wanted, it still lists" "0 4" "$RC $(grep -cE '^  (current|generation)' <<<"$OUT")"
rm -rf "$ST"; OUT="$(run "$BS" --list "$ROOT")"; RC=$?
grep -q "no state object under $KEYP" <<<"$OUT" && [ "$RC" = 0 ] && ok "an empty replica is said to be empty" || bad "empty replica: rc=$RC $OUT"

echo "--- the Taskfile lets the flag through ---"
if command -v task >/dev/null 2>&1; then
  got="$(cd "$ROOT" && env -i PATH="$PATH" HOME="$SB" task -n backup-state PROVIDER=ovh -- --list 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -F 'backup-state.sh')"
  grep -qE 'backup-state\.sh +--list +\.$' <<<"$got" && ok "task backup-state PROVIDER=<p> -- --list runs backup-state.sh --list ." || bad "rendered: $got"
else
  echo "  ↷ task is not installed: the Taskfile entry is not exercised here"
fi

# =============================================================================
echo
echo "=== etcd-snapshot.sh ==="
ES="$ROOT/scripts/ops/etcd-snapshot.sh"
WD="$SB/cluster"; mkdir -p "$WD"; printf 'context: stub\n' >"$WD/talosconfig"
targets scaleway "$OSC_EP"
CP_IPS='["10.0.1.10","10.0.1.11"]'
BASE="TF_VAR_encryption_passphrase=correct-horse-battery-staple-32chars OA_STUB_CP_IPS=$CP_IPS SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK OUTSCALE_BACKUP_AWS_ACCESS_KEY_ID=OSC-BK-AK OUTSCALE_BACKUP_AWS_SECRET_ACCESS_KEY=OSC-BK-SK"
runes() { (cd "$WD" && run "$ES"); }   # the script wants ./talosconfig and cwd = cluster root

echo "--- without the passphrase nothing is taken, nothing is uploaded ---"
ENV_EXTRA="OA_STUB_CP_IPS=$CP_IPS SCW_AWS_ACCESS_KEY_ID=PRIMARY-AK SCW_AWS_SECRET_ACCESS_KEY=PRIMARY-SK"
OUT="$(runes)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "ran without a passphrase"
grep -q "TF_VAR_encryption_passphrase" <<<"$OUT" && ok "and names the missing variable" || bad "$OUT"
is "zero aws calls" 0 "$(calls aws:)"

echo "--- without a talosconfig: refused before any call ---"
mv "$WD/talosconfig" "$WD/talosconfig.away"
ENV_EXTRA="$BASE"
OUT="$(runes)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "ran without a talosconfig"
grep -q "talosconfig not found" <<<"$OUT" && ok "and says so" || bad "$OUT"
mv "$WD/talosconfig.away" "$WD/talosconfig"

echo "--- no control-plane IPs in the state: refused before a snapshot is tried ---"
ENV_EXTRA="${BASE//$CP_IPS/[]}"
OUT="$(runes)"; RC=$?
[ "$RC" -ne 0 ] && ok "refused (rc=$RC)" || bad "ran with no CP"
is "zero talosctl calls" 0 "$(calls talosctl:)"

echo "--- the snapshot: first CP through its tunnel, encrypted, to both stores ---"
ENV_EXTRA="$BASE"
OUT="$(runes)"; RC=$?
is "the script completes" 0 "$RC"
grep -q "^talosctl:-e 127.0.0.1:50000 -n 10.0.1.10 etcd snapshot" "$LOG" \
  && ok "cp-0 is asked through local port 50000 with its own node IP" \
  || bad "talosctl call: $(grep '^talosctl:' "$LOG")"
is "two uploads (primary + replica)" 2 "$(uploads | wc -l)"
UP_P="$(uploads | grep 's3-example-scaleway-management-test/')"
UP_R="$(uploads | grep 's3-example-scaleway-management-test-backup/')"
[ -n "$UP_P" ] && [ -n "$UP_R" ] && ok "one to the primary artifact bucket, one to the replica" || bad "$(uploads)"
grep -qE 'backups/etcd/etcd-[0-9]{8}T[0-9]{6}Z\.snap\.gpg' <<<"$UP_P" \
  && ok "the key is timestamped so names sort chronologically" || bad "key: $UP_P"
is "the primary upload signs with the primary keys" PRIMARY-AK "$(key_of "$UP_P")"
is "the replica upload signs with the keys of the cloud holding it" OSC-BK-AK "$(key_of "$UP_R")"
[ "$(grep -c -- '--sse AES256' <<<"$(uploads)")" = 2 ] && ok "both uploads carry --sse AES256" || bad "$(uploads)"
grep -q "via cp-0 (10.0.1.10)" <<<"$OUT" && ok "the result says which CP answered" || bad "$OUT"

echo "--- the artifact is ciphertext, and only the tfstate passphrase opens it ---"
ART="$(ls "$CAP"/etcd-*.snap.gpg 2>/dev/null | head -1)"
[ -n "$ART" ] && ok "the uploaded artifact was captured: $(basename "$ART")" || bad "no artifact captured"
grep -q "ETCD-PLAINTEXT" "$ART" 2>/dev/null \
  && bad "the snapshot went up in CLEAR" || ok "the plaintext marker is not in the artifact"
G="$(mktemp -d)"
DEC="$(GNUPGHOME="$G" gpg --batch --quiet --pinentry-mode loopback \
        --passphrase correct-horse-battery-staple-32chars -d "$ART" 2>/dev/null)"
is "it decrypts with the tfstate passphrase to the bytes talosctl wrote" "ETCD-PLAINTEXT-127.0.0.1:50000" "$DEC"
GNUPGHOME="$G" gpg --batch --quiet --pinentry-mode loopback --passphrase wrong -d "$ART" >/dev/null 2>&1 \
  && bad "a wrong passphrase decrypted it" || ok "a wrong passphrase does not"
rm -rf "$G"

echo "--- cp-0 is down: cp-1 through the next port, and the result says so ---"
ENV_EXTRA="$BASE OA_STUB_TALOS_DOWN=127.0.0.1:50000"
OUT="$(runes)"; RC=$?
is "the script completes" 0 "$RC"
grep -q "^talosctl:-e 127.0.0.1:50001 -n 10.0.1.11 " "$LOG" && ok "cp-1 was asked on port 50001" || bad "$(grep '^talosctl:' "$LOG")"
grep -q "via cp-1 (10.0.1.11)" <<<"$OUT" && ok "and the result names cp-1" || bad "$OUT"

echo "--- TALOS_TUNNEL_OFFSET shifts the port block ---"
ENV_EXTRA="$BASE TALOS_TUNNEL_OFFSET=200"
OUT="$(runes)"; RC=$?
is "the script completes" 0 "$RC"
grep -q "^talosctl:-e 127.0.0.1:50200 " "$LOG" && ok "cp-0 is asked on 50200" || bad "$(grep '^talosctl:' "$LOG")"

echo "--- every CP is down: nothing uploaded, and the tunnels are named ---"
ENV_EXTRA="$BASE OA_STUB_TALOS_DOWN=all"
OUT="$(runes)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 with no snapshot"
is "zero uploads" 0 "$(uploads | wc -l)"
grep -q "tunnels open" <<<"$OUT" && ok "and the message points at the tunnels" || bad "$OUT"

echo "--- retention: exactly the oldest beyond KEEP, never the newest ---"
keys() { python3 -c "import json,sys;print(json.dumps(['backups/etcd/etcd-2026%04dT000000Z.snap.gpg'%i for i in range(int(sys.argv[1]))],separators=(',',':')))" "$1"; }
ENV_EXTRA="$BASE KEEP=30 OA_STUB_LIST=$(keys 33)"
OUT="$(runes)"; RC=$?
is "33 snapshots, KEEP=30: three removals per store" 6 "$(rms | wc -l)"
for i in 0 1 2; do
  grep -q "etcd-2026000${i}T" <<<"$(rms)" && ok "…the oldest: etcd-2026000${i}T" || bad "did not remove etcd-2026000${i}T"
done
grep -q "etcd-20260032T" <<<"$(rms)" && bad "the NEWEST snapshot was removed" || ok "…and the newest is kept"
ENV_EXTRA="$BASE KEEP=30 OA_STUB_LIST=$(keys 29)"
OUT="$(runes)"; RC=$?
is "29 snapshots, KEEP=30: nothing removed (a negative slice end counts from the END in jq)" 0 "$(rms | wc -l)"
ENV_EXTRA="$BASE KEEP=30 OA_STUB_LIST=$(keys 30)"
OUT="$(runes)"; RC=$?
is "exactly KEEP snapshots: nothing removed" 0 "$(rms | wc -l)"
ENV_EXTRA="$BASE KEEP=3 OA_STUB_LIST=$(keys 5)"
OUT="$(runes)"; RC=$?
is "5 snapshots, KEEP=3: two removals per store" 4 "$(rms | wc -l)"
ENV_EXTRA="$BASE KEEP=30 OA_STUB_LIST=null"
OUT="$(runes)"; RC=$?
is "an empty bucket (null listing) removes nothing and still succeeds" "0 0" "$(rms | wc -l) $RC"

# =============================================================================
echo
echo "=== resolve-s3-cred.sh ==="
RS=scripts/internal/resolve-s3-cred.sh
# <provider> <ak|sk> [primary|backup] [endpoint] — the CLI order differs from
# s3_cred's, and every Taskfile `env: sh:` line depends on this mapping.
ENV_EXTRA="SCW_AWS_ACCESS_KEY_ID=P-AK SCW_AWS_SECRET_ACCESS_KEY=P-SK SCW_BACKUP_AWS_ACCESS_KEY_ID=SCW-BK-AK OUTSCALE_BACKUP_AWS_SECRET_ACCESS_KEY=OSC-BK-SK"
is "<provider> <ak>: the primary access key"            P-AK      "$(stdout "$RS" scaleway ak)"
is "<provider> <sk>: the primary secret"                P-SK      "$(stdout "$RS" scaleway sk)"
is "… backup, no endpoint: the cluster-namespaced key"  SCW-BK-AK "$(stdout "$RS" scaleway ak backup)"
is "… backup + Outscale endpoint: the endpoint decides"  OSC-BK-SK "$(stdout "$RS" scaleway sk backup "$OSC_EP")"
OUT="$(stdout "$RS")"; RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "no arguments: non-zero and NOTHING on stdout" || bad "rc=$RC stdout='$OUT'"
OUT="$(stdout "$RS" nimbus ak)"; RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "unknown provider: non-zero and nothing on stdout (seed-openbao relies on the empty answer)" || bad "rc=$RC stdout='$OUT'"
OUT="$(stdout "$RS" scaleway primary ak)"; RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] \
  && ok "swapped <kind>/<type>: refused rather than printing the SECRET as an access-key id" \
  || bad "swapped arguments answered rc=$RC stdout='$OUT'"

echo
echo "--- floors: the stubs really ran (all of the above is vacuous otherwise) ---"
ENV_EXTRA="$BASE"
OUT="$(runes)"
[ "$(calls tofu:)" -ge 2 ] && [ "$(calls aws:)" -ge 2 ] && [ "$(calls talosctl:)" -ge 1 ] \
  && ok "tofu, aws and talosctl all went through the stubs ($(wc -l <"$LOG") calls)" \
  || bad "a stub was never reached: $(cat "$LOG")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
