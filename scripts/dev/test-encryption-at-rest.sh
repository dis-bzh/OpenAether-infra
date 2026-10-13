#!/usr/bin/env bash
# infra-verify.sh's encryption-at-rest checks: STATE/EPHEMERAL read back from each node's Talos API and the
# apiserver's etcd encryption flag. The two functions are extracted from the script and run against stub
# talosctl/kubectl, one rung below the cloud. SUT overrides the script under test (how the mutants run).
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
# `get nodename` answers unless the node is in STUB_DOWN; `get volumestatus <ID>` answers from the STUB_VOLS
# file: "<ip> <ID> <phase> <encryption>" per line (encryption "-" = none).
node="" args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = -n ] && node="${args[$((i + 1))]}"; done
case "$*" in
  *"get nodename"*) case " ${STUB_DOWN:-} " in *" $node "*) echo "rpc error: unavailable" >&2; exit 1 ;; esac; exit 0 ;;
  *"get volumestatus "*)
    id="$(sed -nE 's/.*get volumestatus ([^ ]+).*/\1/p' <<<"$*")"
    line="$(awk -v n="$node" -v v="$id" '$1 == n && $2 == v' "$STUB_VOLS")"
    [ -n "$line" ] || { echo "error getting resource: NotFound" >&2; exit 1; }
    read -r _ _ phase enc <<<"$line"
    printf '{"spec":{"phase":"%s","encryptionProvider":%s}}\n' "$phase" "$([ "$enc" = - ] && echo null || echo "\"$enc\"")" ;;
esac
STUB
chmod +x "$TMP/bin/talosctl"

FN="$TMP/fn.sh"
{ awk '/^system_volume_check\(\) \{/,/^}/' "$SUT"; awk '/^apiserver_encryption_check\(\) \{/,/^}/' "$SUT"; } >"$FN"
[ "$(grep -cE '^(system_volume|apiserver_encryption)_check' "$FN")" = 2 ] && ok "both functions were found in the script under test" \
  || { bad "could not extract the functions from $SUT"; printf '%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

echo "=== STATE and EPHEMERAL ==="
run() { # <ips> — runs system_volume_check; sets OUT
  OUT="$( ( ok() { echo "OK: $*"; }; bad() { echo "BAD: $*"; }; warn() { echo "WARN: $*"; }; unk() { echo "UNK: $*"; }
            PROVIDER=stubcloud; PATH="$TMP/bin:$PATH"; source "$FN"; system_volume_check "$1" ) 2>&1 )"
}
export STUB_VOLS="$TMP/vols"
N1=10.0.0.1 N2=10.0.0.2
good() { printf '%s STATE ready luks2\n%s EPHEMERAL ready luks2\n' "$1" "$1"; }

{ good $N1; good $N2; } >"$STUB_VOLS"
STUB_DOWN="" run $'10.0.0.1\n10.0.0.2'
grep -q '^OK: STATE and EPHEMERAL are ready and LUKS2' <<<"$OUT" && grep -q '(4 volume' <<<"$OUT" && ! grep -qE '^(BAD|UNK)' <<<"$OUT" \
  && ok "two nodes, both volumes luks2: one OK line counting four reads" || bad "the green case: $OUT"

{ good $N1; printf '%s STATE ready luks2\n%s EPHEMERAL ready -\n' $N2 $N2; } >"$STUB_VOLS"
STUB_DOWN="" run $'10.0.0.1\n10.0.0.2'
grep -q "^BAD: node $N2 volume EPHEMERAL is 'ready none'" <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" \
  && ok "an unencrypted EPHEMERAL FAILS, by node, and no OK line follows" || bad "unencrypted EPHEMERAL passed: $OUT"

{ printf '%s STATE ready -\n%s EPHEMERAL ready luks2\n' $N1 $N1; } >"$STUB_VOLS"
STUB_DOWN="" run $N1
grep -q "^BAD: node $N1 volume STATE is 'ready none'" <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" \
  && ok "an unencrypted STATE FAILS" || bad "unencrypted STATE passed: $OUT"

{ printf '%s STATE ready luks2\n%s EPHEMERAL pending luks2\n' $N1 $N1; } >"$STUB_VOLS"
STUB_DOWN="" run $N1
grep -q "^BAD: node $N1 volume EPHEMERAL is 'pending luks2'" <<<"$OUT" && ok "a volume that is not ready FAILS" || bad "pending passed: $OUT"

printf '%s STATE ready luks2\n' $N1 >"$STUB_VOLS"
STUB_DOWN="" run $N1
grep -q "^UNK: node $N1: no volume status 'EPHEMERAL'" <<<"$OUT" && ! grep -qE '^(OK|BAD)' <<<"$OUT" \
  && ok "a volume id the node does not know is UNCHECKED, never green and never a false red" || bad "missing id: $OUT"

good $N1 >"$STUB_VOLS"
STUB_DOWN="$N1" run $N1
grep -q "^WARN: node $N1: not reachable" <<<"$OUT" && ! grep -qE '^(OK|BAD)' <<<"$OUT" \
  && ok "an unreachable node is a WARNING and there is no OK line: nothing was read back" || bad "unreachable node: $OUT"

STUB_DOWN="" run ""
grep -q '^UNK:' <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" && ok "no node listed is UNCHECKED, never a pass" || bad "empty list: $OUT"

echo "=== the apiserver's etcd encryption ==="
runk() { # sets OUT from a stub K that prints $STUB_ARGS (or fails when STUB_FAIL=1)
  OUT="$( ( ok() { echo "OK: $*"; }; bad() { echo "BAD: $*"; }; warn() { echo "WARN: $*"; }; unk() { echo "UNK: $*"; }
            K() { [ "${STUB_FAIL:-}" = 1 ] && return 1; printf '%s\n' "$STUB_ARGS"; }
            source "$FN"; apiserver_encryption_check ) 2>&1 )"
}
STUB_ARGS='["/usr/local/bin/kube-apiserver","--encryption-provider-config=/system/secrets/kubernetes/kube-apiserver/encryptionconfig.yaml","--v=2"]' runk
grep -q '^OK:' <<<"$OUT" && ok "the flag present passes" || bad "flag present: $OUT"
STUB_ARGS='["/usr/local/bin/kube-apiserver","--v=2"]' runk
grep -q '^BAD:' <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" && ok "no flag FAILS" || bad "no flag: $OUT"
STUB_ARGS='["/usr/local/bin/kube-apiserver","--encryption-provider-config-automatic-reload=true"]' runk
grep -q '^BAD:' <<<"$OUT" && ok "a flag that merely shares the prefix does not count" || bad "prefix decoy: $OUT"
STUB_FAIL=1 STUB_ARGS="" runk
grep -q '^UNK:' <<<"$OUT" && ! grep -q '^OK' <<<"$OUT" && ok "an unreadable command line is UNCHECKED" || bad "unreadable: $OUT"

echo "=== it is wired in ==="
SECT="$(awk '/^info "Encryption at rest is effective"/{f=1} f{print} /^fi$/ && f{exit}' "$SUT")"
grep -q 'system_volume_check' <<<"$SECT" && grep -q 'apiserver_encryption_check' <<<"$SECT" \
  && ok "the section calls both checks" || bad "the section is not wired: $SECT"
awk '/^if \[ "\$PROVIDER" != local \]; then$/ {g=NR} /^info "Encryption at rest is effective"/ && g && NR == g + 1 {found=1} END{exit !found}' "$SUT" \
  && ok "…and only where there is a provider (the Docker lane has no disks)" || bad "the section is not gated on PROVIDER != local"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
