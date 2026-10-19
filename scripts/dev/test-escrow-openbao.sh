#!/usr/bin/env bash
# scripts/ops/escrow-openbao.sh against REAL gpg keys and a stub kubectl that plays the cluster: what it refuses (one custodian,
# a git work tree, a development bootstrap), that the escrow opens for each custodian and to the live key, that a rotated key,
# a damaged copy or a machine without a custodian key is never attested, and that no secret value reaches the output or a
# command line. Needs gpg; without it the harness says so and exits 0 (a skip is not a pass). SUT overrides the script (mutants).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v gpg >/dev/null 2>&1 || { echo "↷ test-escrow-openbao not run: gpg is missing (a skip is not a pass)"; exit 0; }
SUT="${SUT:-$PWD/scripts/ops/escrow-openbao.sh}"

SB="$(mktemp -d)"
cleanup() { local h; for h in "$SB"/gnupg*; do GNUPGHOME="$h" gpgconf --kill gpg-agent 2>/dev/null; done; rm -rf "$SB"; }
trap cleanup EXIT
mk_home() { mkdir -m 700 "$SB/$1"; }
mk_home gnupg                       # the operator's keyring: alice, bob (custodians) and dave
export GNUPGHOME="$SB/gnupg"
for u in alice bob dave; do gpg --batch --quiet --passphrase '' --quick-gen-key "$u@example.invalid" default default never 2>/dev/null; done
fpr() { gpg --with-colons --list-keys "$1@example.invalid" | awk -F: '/^fpr/{print $10; exit}'; }
FA="$(fpr alice)"; FB="$(fpr bob)"
mk_home gnupg-bob                   # a machine that holds bob's private key only
gpg --export-secret-keys bob@example.invalid | GNUPGHOME="$SB/gnupg-bob" gpg --batch --quiet --import 2>/dev/null
mk_home gnupg-none                  # a machine that holds no custodian key at all

# ---- the cluster: a directory of files the stub answers from -------------------------------------------------------------
CL="$SB/cluster"; mkdir -p "$CL"
KEY_RAW="$SB/key.raw"; head -c 32 /dev/urandom >"$KEY_RAW"          # random bytes may hold NULs: that is the point
base64 -w0 <"$KEY_RAW" >"$CL/seal_b64"
RESTIC='r3st1c-PASSWORD-fixture-0123456789abcdefghijklmnop'; printf '%s' "$RESTIC" >"$CL/restic"
mkdir -p "$CL/shares"
printf 'SHARE-ONE-ciphertext-text' | base64 -w0 >"$CL/shares/share-1"
printf 'SHARE-TWO-ciphertext-text' | base64 -w0 >"$CL/shares/share-2"
mkdir -p "$SB/bin"
cat >"$SB/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  "-n foundation-vault get secret openbao-seal-key -o jsonpath={.data.key}") cat "$STUB_CL/seal_b64"; exit 0 ;;
  "-n foundation-vault get secret openbao-seal-key") [ -z "${STUB_NO_SEAL:-}" ]; exit $? ;;
  "-n foundation-vault get secret openbao-recovery-dev") [ -n "${STUB_DEV:-}" ]; exit $? ;;
  "-n foundation-vault get secret openbao-recovery-shares -o json")
    printf '{"data":{'; sep=""
    for f in "$STUB_CL"/shares/share-*; do printf '%s"%s":"%s"' "$sep" "$(basename "$f")" "$(cat "$f")"; sep=","; done
    printf '}}'; exit 0 ;;
  "-n foundation-vault create token openaether-admin"*) printf 'jwt-STUB-TOKEN'; exit 0 ;;
  "-n foundation-vault exec -i openbao-0 -- sh -c "*)
    IFS= read -r jwt; printf 'stdin-jwt:%s\n' "$jwt" >>"$STUB_LOG"
    cat "$STUB_CL/restic"; exit 0 ;;
  "-n foundation-vault create configmap openbao-escrow-ack "*) printf 'CONFIGMAP %s\n' "$*"; exit 0 ;;
  "apply -f -") printf 'APPLIED:%s\n' "$(cat)" >>"$STUB_LOG"; exit 0 ;;
  "-n foundation-vault annotate secret openbao-seal-key "*) exit 0 ;;
esac
echo "stub kubectl: unexpected call: $*" >&2; exit 99
STUB
chmod +x "$SB/bin/kubectl"
export STUB_CL="$CL" STUB_LOG="$SB/calls.log" KUBECONFIG="$SB/kubeconfig"
run() { : >"$STUB_LOG"; OUT="$(PATH="$SB/bin:$PATH" bash "$SUT" "$@" 2>&1)"; RC=$?; }
sha() { sha256sum | cut -d' ' -f1; }
SEALSHA="$(sha <"$KEY_RAW")"

echo "=== export: refusals ==="
run export --out "$SB/e0" -r alice@example.invalid
[ "$RC" -ne 0 ] && grep -q 'at least two' <<<"$OUT" && [ ! -e "$SB/e0/escrow-receipt.json" ] && ok "one custodian is refused" || bad "one recipient: rc=$RC $OUT"
run export --out "$SB/e0" -r alice@example.invalid -r "$FA"
[ "$RC" -ne 0 ] && grep -q 'at least two' <<<"$OUT" && ok "the same key under two names is still one custodian" || bad "alias counted twice: rc=$RC $OUT"
run export --out "$SB/e0"
[ "$RC" -ne 0 ] && grep -q 'no recipient' <<<"$OUT" && ok "no recipient is refused" || bad "no recipient: rc=$RC $OUT"
mkdir -p "$SB/repo" && git -C "$SB/repo" init -q 2>/dev/null
run export --out "$SB/repo/escrow" -r alice@example.invalid -r bob@example.invalid
[ "$RC" -ne 0 ] && grep -q 'git work tree' <<<"$OUT" && [ ! -e "$SB/repo/escrow" ] && ok "a directory inside a git work tree is refused, and not created" || bad "git tree: rc=$RC $OUT"
mkdir -p "$SB/full" && touch "$SB/full/x"
run export --out "$SB/full" -r alice@example.invalid -r bob@example.invalid
[ "$RC" -ne 0 ] && grep -q 'not empty' <<<"$OUT" && ok "a non-empty directory is refused (a second escrow is a new directory)" || bad "non-empty: rc=$RC $OUT"
STUB_DEV=1 run export --out "$SB/dev" -r alice@example.invalid -r bob@example.invalid
[ "$RC" -ne 0 ] && grep -q 'development bootstrap' <<<"$OUT" && ok "a development bootstrap is refused" || bad "dev: rc=$RC $OUT"
STUB_NO_SEAL=1 run export --out "$SB/noseal" -r alice@example.invalid -r bob@example.invalid
[ "$RC" -ne 0 ] && grep -q 'openbao-seal-key' <<<"$OUT" && ok "no seal-key Secret is refused" || bad "no seal: rc=$RC $OUT"
run export --out "$SB/amb" -r example.invalid -r bob@example.invalid
[ "$RC" -ne 0 ] && grep -q 'matches 3 keys' <<<"$OUT" && ok "an ambiguous recipient is refused" || bad "ambiguous: rc=$RC $OUT"

echo "=== export: two custodians ==="
E="$SB/e1"
run export --out "$E" -r alice@example.invalid -r bob@example.invalid
[ "$RC" = 0 ] && ok "export succeeds" || bad "export: rc=$RC $OUT"
[ "$(stat -c %a "$E")" = 700 ] && ok "the directory is mode 700" || bad "mode $(stat -c %a "$E")"
for f in openbao-seal-key.gpg restic-password.gpg openbao-share-1.b64 openbao-share-2.b64 escrow-receipt.json; do
  [ -s "$E/$f" ] || bad "missing $f"
done; [ -s "$E/escrow-receipt.json" ] && [ -s "$E/openbao-share-2.b64" ] && ok "the key, the password, both shares and the receipt are there"
[ "$(jq -r .seal_key_sha256 "$E/escrow-receipt.json")" = "$SEALSHA" ] && ok "the receipt holds the hash of the 32 key bytes (NULs and all)" || bad "receipt hash"
[ "$(jq -r '.recipients|sort|join(",")' "$E/escrow-receipt.json")" = "$(printf '%s\n' "$FA" "$FB" | sort | paste -sd,)" ] && [ "$(jq .holders "$E/escrow-receipt.json")" = 2 ] \
  && ok "…and the two fingerprints, holders 2" || bad "receipt recipients: $(cat "$E/escrow-receipt.json")"
[ "$(cat "$E/openbao-share-1.b64")" = "SHARE-ONE-ciphertext-text" ] && ok "a recovery share is the Secret's value decoded once" || bad "share content"
GNUPGHOME="$SB/gnupg" gpg --quiet --decrypt "$E/openbao-seal-key.gpg" 2>/dev/null | cmp -s - "$KEY_RAW" && ok "alice opens the seal key (the exact bytes)" || bad "alice cannot open it"
GNUPGHOME="$SB/gnupg-bob" gpg --quiet --decrypt "$E/openbao-seal-key.gpg" 2>/dev/null | cmp -s - "$KEY_RAW" && ok "bob, on a machine without alice's key, opens it too" || bad "bob cannot open it"
[ "$(GNUPGHOME="$SB/gnupg-bob" gpg --quiet --decrypt "$E/restic-password.gpg" 2>/dev/null)" = "$RESTIC" ] && ok "the restic password is escrowed to both" || bad "restic password"
GNUPGHOME="$SB/gnupg-none" gpg --quiet --decrypt "$E/openbao-seal-key.gpg" >/dev/null 2>&1 && bad "a stranger opened the escrow" || ok "a keyring without a custodian cannot open it"
if grep -qF "$(cat "$CL/seal_b64")" "$STUB_LOG" || grep -qF "$(cat "$CL/seal_b64")" <<<"$OUT" || grep -qF "$RESTIC" "$STUB_LOG" || grep -qF "$RESTIC" <<<"$OUT"; then bad "a secret value reached the output or a kubectl call"; else ok "neither the key nor the restic password is in the output or on a kubectl command line"; fi
grep -q 'stdin-jwt:jwt-STUB-TOKEN' "$STUB_LOG" && ok "the OpenBao identity travelled on the stdin of exec, not in its arguments" || bad "jwt not on stdin"

echo "=== export: recipients from the tfvars ==="
{ echo 'openbao_recovery_pgp_keys = ['; for u in alice bob dave; do echo "  \"$(gpg --export "$u@example.invalid" | base64 -w0)\",  # $u"; done; echo ']'; } >"$SB/env.tfvars"
run export --out "$SB/e2" --recipients-from-tfvars "$SB/env.tfvars"
[ "$RC" = 0 ] && [ "$(jq .holders "$SB/e2/escrow-receipt.json")" = 3 ] && ok "the three keys of the tfvars are the custodians" || bad "tfvars: rc=$RC $OUT"
printf 'environment = "dev"\n' >"$SB/empty.tfvars"
run export --out "$SB/e3" --recipients-from-tfvars "$SB/empty.tfvars"
[ "$RC" -ne 0 ] && grep -q 'at least two' <<<"$OUT" && ok "a tfvars without keys is refused" || bad "empty tfvars: rc=$RC $OUT"

echo "=== verify / attest ==="
run verify --from "$E"
[ "$RC" = 0 ] && grep -q 'seal key: reconstructed' <<<"$OUT" && grep -q 'restic password: escrow opens, same' <<<"$OUT" && ok "verify: seal key, restic password and shares agree with the cluster" || bad "verify: rc=$RC $OUT"
grep -q 'openbao-share-2.b64: present' <<<"$OUT" && ok "…and so do the shares" || bad "shares not checked: $OUT"
run attest --from "$E"
[ "$RC" = 0 ] && grep -q 'APPLIED' "$STUB_LOG" && grep -q 'annotate secret openbao-seal-key openaether.io/escrowed-at=' "$STUB_LOG" \
  && ok "attest writes the ConfigMap and the annotation" || bad "attest: rc=$RC $OUT"
CMC="$(grep -m1 'create configmap' "$STUB_LOG")"
grep -q "seal-key-sha256=$SEALSHA" <<<"$CMC" && grep -q 'holders=2' <<<"$CMC" && grep -q 'escrowed-at=20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] ' <<<"$CMC" \
  && ok "…with the date, the hash and holders=2 the CronJob parses" || bad "configmap args: $CMC"
run attest --from "$E" --holders 1
[ "$RC" -ne 0 ] && grep -q 'integer >= 2' <<<"$OUT" && ! grep -q 'APPLIED' "$STUB_LOG" && ok "holders 1 is refused, nothing written" || bad "holders 1: rc=$RC $OUT"
run attest --from "$E" --holders 5
[ "$RC" -ne 0 ] && grep -q 'more than the 2 recipient' <<<"$OUT" && ! grep -q 'APPLIED' "$STUB_LOG" && ok "--holders above the receipt's recipients is refused, nothing written" || bad "holders 5: rc=$RC $OUT"
GNUPGHOME="$SB/gnupg-bob" run verify --from "$E"
[ "$RC" = 0 ] && ok "verify works on bob's machine alone" || bad "bob verify: rc=$RC $OUT"
GNUPGHOME="$SB/gnupg-none" run verify --from "$E"
[ "$RC" -ne 0 ] && grep -q 'none of its keys' <<<"$OUT" && ok "a machine without a custodian key cannot verify" || bad "stranger verify: rc=$RC $OUT"
GNUPGHOME="$SB/gnupg-none" run attest --from "$E"
[ "$RC" -ne 0 ] && ! grep -q 'APPLIED\|annotate' "$STUB_LOG" && ok "…and cannot attest: nothing is written" || bad "stranger attest: rc=$RC $(cat "$STUB_LOG")"
GNUPGHOME="$SB/gnupg-none" run verify --from "$E" --key-file "$KEY_RAW"
[ "$RC" = 0 ] && grep -q 'seal key: reconstructed' <<<"$OUT" && grep -q 'cannot open restic-password.gpg' <<<"$OUT" && ok "a key reconstructed from a split (--key-file) proves the seal key alone" || bad "key-file: rc=$RC $OUT"
head -c 32 /dev/urandom >"$SB/wrong.raw"
GNUPGHOME="$SB/gnupg-none" run attest --from "$E" --key-file "$SB/wrong.raw"
[ "$RC" -ne 0 ] && grep -q 'MISMATCH' <<<"$OUT" && ! grep -q 'APPLIED' "$STUB_LOG" && ok "a wrong reconstructed key is a MISMATCH and attests nothing" || bad "wrong key-file: rc=$RC $OUT"
xxd -p -c 64 "$KEY_RAW" >"$SB/hex.txt" 2>/dev/null && { GNUPGHOME="$SB/gnupg-none" run verify --from "$E" --key-file "$SB/hex.txt"
  [ "$RC" -ne 0 ] && grep -q MISMATCH <<<"$OUT" && ok "a HEX key file is a MISMATCH (decode it first, as the README says)" || bad "hex key file: rc=$RC $OUT"; }

echo "=== what must not be attested ==="
cp "$CL/seal_b64" "$CL/seal_b64.orig"; head -c 32 /dev/urandom | base64 -w0 >"$CL/seal_b64"
run attest --from "$E"
[ "$RC" -ne 0 ] && grep -q 'NOT the live seal key' <<<"$OUT" && ! grep -q 'APPLIED' "$STUB_LOG" && ok "after a seal-key rotation the old escrow is refused (this is what the CronJob cannot see)" || bad "rotated: rc=$RC $OUT"
mv "$CL/seal_b64.orig" "$CL/seal_b64"
cp "$E/escrow-receipt.json" "$SB/receipt.bak"
jq '.seal_key_sha256 = ("0" * 64)' "$E/escrow-receipt.json" >"$SB/r.json" && cp "$SB/r.json" "$E/escrow-receipt.json"
run attest --from "$E"
[ "$RC" -ne 0 ] && grep -q 'not what its receipt says' <<<"$OUT" && ok "a receipt that does not match the escrow is refused" || bad "bad receipt: rc=$RC $OUT"
cp "$SB/receipt.bak" "$E/escrow-receipt.json"
printf 'RESTIC-ROTATED' >"$CL/restic.new"; cp "$CL/restic" "$CL/restic.orig"; cp "$CL/restic.new" "$CL/restic"
run verify --from "$E"
[ "$RC" -ne 0 ] && grep -q 'secret/backup/restic changed' <<<"$OUT" && ok "a restic password rotated since the escrow fails verify" || bad "restic rotated: rc=$RC $OUT"
mv "$CL/restic.orig" "$CL/restic"
printf 'tampered' >"$E/openbao-share-1.b64"
run verify --from "$E"
[ "$RC" -ne 0 ] && grep -q 'openbao-share-1.b64: missing, altered' <<<"$OUT" && ok "an altered recovery-share copy fails verify" || bad "share altered: rc=$RC $OUT"
rm -f "$E/escrow-receipt.json"
run verify --from "$E"
[ "$RC" -ne 0 ] && grep -q 'no .*escrow-receipt.json' <<<"$OUT" && ok "no receipt, no verification" || bad "no receipt: rc=$RC $OUT"

echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
