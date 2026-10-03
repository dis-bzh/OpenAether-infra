#!/usr/bin/env bash
# infra-verify.sh's worker data-volume check (#62): the names it reads from the tfvars and the
# verdicts it draws from each worker's own Talos API. The two functions are extracted from the
# script and run against a stub talosctl and kubectl, one rung below the cloud. SUT overrides
# the script under test, which is how the mutants run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/dev/infra-verify.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
# `get nodename` answers unless the node is listed in STUB_DOWN; `get volumestatus u-<n>` answers from
# the STUB_VOLS file: "<ip> <name> <phase> <encryption>" per line. Both need the node named with -n.
node="" args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = -n ] && node="${args[$((i + 1))]}"; done
case "$*" in
  *"get nodename"*) case " ${STUB_DOWN:-} " in *" $node "*) echo "rpc error: unavailable" >&2; exit 1 ;; esac; exit 0 ;;
  *"get volumestatus u-"*)
    name="$(sed -nE 's/.*get volumestatus u-([^ ]+).*/\1/p' <<<"$*")"
    line="$(awk -v n="$node" -v v="$name" '$1 == n && $2 == v' "$STUB_VOLS")"
    [ -n "$line" ] || { echo "error getting resource: NotFound" >&2; exit 1; }
    read -r _ _ phase enc <<<"$line"
    printf '{"spec":{"phase":"%s","encryptionProvider":%s}}\n' "$phase" "$([ "$enc" = - ] && echo null || echo "\"$enc\"")" ;;
esac
STUB
chmod +x "$TMP/bin/talosctl"

# The two functions, taken from the script itself so the test cannot drift from it.
FN="$TMP/fn.sh"
{ awk '/^worker_volume_names\(\) \{/,/^}/' "$SUT"; awk '/^worker_volume_check\(\) \{/,/^}/' "$SUT"; } >"$FN"
[ "$(grep -c '^worker_volume_' "$FN")" = 2 ] && ok "both functions were found in the script under test" \
  || { bad "could not extract the functions from $SUT"; printf '%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

echo "=== the names the tfvars ask for ==="
names() { ( source "$FN"; worker_volume_names "$1" ) | tr '\n' ' ' | sed 's/ $//'; }
cat >"$TMP/two.tfvars" <<'TF'
cluster_name = "demo"
worker_storage = {
  disks = [{ size_gb = 50 }]
  volumes = [
    { name = "local-path-provisioner", disk_match = "!system_disk", min_size = "20GB" }, # name = "ignored"
    { name = "longhorn", disk_match = "!system_disk", grow = true },
  ]
}
other = { name = "not-a-volume" }
TF
[ "$(names "$TMP/two.tfvars")" = "local-path-provisioner longhorn" ] \
  && ok "two volumes are read, a comment and a block after the storage block are not" \
  || bad "names read as: [$(names "$TMP/two.tfvars")]"
printf 'worker_storage = { disks = [{ size_gb = 50 }], volumes = [{ name = "longhorn", disk_match = "x" }] }\nother = { name = "no" }\n' >"$TMP/one.tfvars"
[ "$(names "$TMP/one.tfvars")" = "longhorn" ] && ok "a one-line block is read, and stops at its closing brace" || bad "one-line block: [$(names "$TMP/one.tfvars")]"
printf '# worker_storage = {\n#   volumes = [{ name = "commented" }]\n# }\ncluster_name = "x"\n' >"$TMP/none.tfvars"
[ -z "$(names "$TMP/none.tfvars")" ] && ok "a commented-out example yields no volume" || bad "a comment was read: [$(names "$TMP/none.tfvars")]"
printf 'worker_storage = {\n  volumes = [{ cluster_name = "decoy", name = "real" }]\n}\n' >"$TMP/decoy.tfvars"
[ "$(names "$TMP/decoy.tfvars")" = "real" ] && ok "a key that merely ends in 'name' is not a volume" || bad "decoy: [$(names "$TMP/decoy.tfvars")]"
[ -z "$(names "$TMP/does-not-exist")" ] && ok "a missing file yields nothing, not an error" || bad "a missing file produced output"

echo "=== the verdicts ==="
# K stands for kubectl: the workers' InternalIPs, one per line, or what STUB_K says it failed with.
run() { # <names> — runs worker_volume_check; sets OUT and RC
  OUT="$( ( ok() { echo "OK: $*"; }; bad() { echo "BAD: $*"; }; warn() { echo "WARN: $*"; }; unk() { echo "UNK: $*"; }
            K() { printf '%s' "$STUB_WORKERS"; }
            PROVIDER=stubcloud; PATH="$TMP/bin:$PATH"; source "$FN"; worker_volume_check "$1" ) 2>&1 )"; RC=$?
}
W1=10.0.0.1 W2=10.0.0.2
export STUB_VOLS="$TMP/vols"
printf '%s longhorn ready luks2\n%s longhorn ready luks2\n' $W1 $W2 >"$STUB_VOLS"
STUB_WORKERS=$'10.0.0.1\n10.0.0.2\n' STUB_DOWN="" run longhorn
grep -q '^OK: every worker carries' <<<"$OUT" && ! grep -q '^BAD' <<<"$OUT" \
  && ok "every worker ready and LUKS2 passes, and says how many reads it made" || bad "the green case: $OUT"
grep -q '(2 read back' <<<"$OUT" && ok "…counting reads, not workers" || bad "the count is wrong: $OUT"

printf '%s longhorn ready luks2\n' $W1 >"$STUB_VOLS"
STUB_WORKERS=$'10.0.0.1\n10.0.0.2\n' STUB_DOWN="" run longhorn
grep -q "^BAD: worker $W2 has no volume u-longhorn" <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" \
  && ok "a worker that answers and lacks the volume FAILS, by its address, and no OK line follows" \
  || bad "a missing volume was not refused: $OUT"

printf '%s longhorn ready luks2\n%s longhorn ready -\n' $W1 $W2 >"$STUB_VOLS"
STUB_WORKERS=$'10.0.0.1\n10.0.0.2\n' STUB_DOWN="" run longhorn
grep -q "^BAD: worker $W2 volume u-longhorn is 'ready none'" <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" \
  && ok "a ready volume without encryption FAILS: the config said LUKS2" || bad "an unencrypted volume passed: $OUT"

printf '%s longhorn pending luks2\n%s longhorn ready luks2\n' $W1 $W2 >"$STUB_VOLS"
STUB_WORKERS=$'10.0.0.1\n10.0.0.2\n' STUB_DOWN="" run longhorn
grep -q "^BAD: worker $W1 volume u-longhorn is 'pending luks2'" <<<"$OUT" \
  && ok "a volume that is not ready FAILS" || bad "a pending volume passed: $OUT"

printf '%s longhorn ready luks2\n%s longhorn ready luks2\n' $W1 $W2 >"$STUB_VOLS"
STUB_WORKERS=$'10.0.0.1\n10.0.0.2\n' STUB_DOWN="10.0.0.2" run longhorn
grep -q "^WARN: worker $W2: not reachable" <<<"$OUT" && ! grep -q '^BAD' <<<"$OUT" && grep -q '(1 read back' <<<"$OUT" \
  && ok "a worker no tunnel reaches is a WARNING, and the one that answered is still counted" \
  || bad "an unreachable worker was mishandled: $OUT"

STUB_WORKERS=$'10.0.0.1\n10.0.0.2\n' STUB_DOWN="10.0.0.1 10.0.0.2" run longhorn
! grep -q '^OK' <<<"$OUT" && grep -q '^WARN' <<<"$OUT" \
  && ok "with no worker reachable there is no OK line: nothing was read back" || bad "an all-unreachable run claimed success: $OUT"

STUB_WORKERS="" STUB_DOWN="" run longhorn
grep -q '^UNK:' <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" \
  && ok "no worker listed at all is UNCHECKED, never a pass" || bad "an empty worker list passed: $OUT"

printf '%s longhorn ready luks2\n%s longhorn ready luks2\n' $W1 $W2 >"$STUB_VOLS"
STUB_WORKERS=$'10.0.0.1\n' STUB_DOWN="" run $'longhorn\nghost'
grep -q "^BAD: worker $W1 has no volume u-ghost" <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" \
  && ok "two configured volumes: the one the node lacks is named, the other is not blamed" \
  || bad "the second volume was not checked: $OUT"

echo "=== it is wired in ==="
SECT="$(awk '/^info "The workers. data volumes are the ones the config names"/{f=1} f{print} /^fi$/ && f{exit}' "$SUT")"
grep -q 'worker_volume_names "\$VER_TFVARS"' <<<"$SECT" && grep -q 'worker_volume_check "\$VOLS"' <<<"$SECT" \
  && ok "the section reads the names from the tfvars and checks them" || bad "the section is not wired: $SECT"
awk '/^if \[ "\$PROVIDER" != local \]; then$/ {g=NR} /^info "The workers. data volumes/ && g && NR == g + 1 {found=1} END{exit !found}' "$SUT" \
  && ok "…and only where there is a provider (the Docker lane has no data disks)" || bad "the section is not gated on PROVIDER != local"
grep -q 'no worker data volumes configured' <<<"$SECT" && ok "…and says plainly when none are configured" || bad "no message for the no-volume case"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
