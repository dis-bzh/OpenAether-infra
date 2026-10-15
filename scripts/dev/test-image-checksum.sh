#!/usr/bin/env bash
# The Talos image checksum lane (images.lock), offline: the verifier in its three modes, the lock writer and its --check
# against a fake Image Factory served from file://, the committed lock held to its format, and the three local-exec
# modules held to calling the verifier between the download and the first use of the file.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$ROOT/scripts/internal/verify-image-checksum.sh"
LOCKER="$ROOT/scripts/bootstrap/talos-image-lock.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
rc_of() { local want="$1" label="$2"; shift 2; "$@" >"$TMP/out" 2>&1; local rc=$?; [ "$rc" -eq "$want" ] && ok "$label" || bad "$label (exit $rc, wanted $want): $(tr '\n' '|' <"$TMP/out")"; }
says() { grep -qF -- "$1" "$TMP/out" && ok "$2" || bad "$2 — no '$1' in: $(tr '\n' '|' <"$TMP/out")"; }

echo "=== verify-image-checksum.sh ==="
printf 'talos' >"$TMP/img"
GOOD="$(sha256sum "$TMP/img" | awk '{print $1}')"
BAD=0000000000000000000000000000000000000000000000000000000000000000
rc_of 0 "enforce, matching hash: passes" "$VERIFY" "$TMP/img" "$GOOD" enforce lbl; says "matches images.lock" "…and says it matched"
rc_of 1 "enforce, wrong hash: fails" "$VERIFY" "$TMP/img" "$BAD" enforce lbl; says "images.lock records" "…naming both hashes"
rc_of 1 "enforce, nothing recorded: fails" "$VERIFY" "$TMP/img" "" enforce lbl; says "no sha256 recorded" "…and says what to run"
rc_of 0 "warn, wrong hash: builds on" "$VERIFY" "$TMP/img" "$BAD" warn lbl; says "⚠ lbl" "…but warns"
rc_of 0 "warn, nothing recorded: builds on" "$VERIFY" "$TMP/img" "" warn lbl; says "no sha256 recorded" "…but warns"
rc_of 0 "off, wrong hash: silent pass" "$VERIFY" "$TMP/img" "$BAD" off lbl
[ ! -s "$TMP/out" ] && ok "…and prints nothing" || bad "off printed: $(cat "$TMP/out")"
rc_of 2 "an unknown mode is refused" "$VERIFY" "$TMP/img" "$GOOD" strict lbl
rc_of 1 "a missing file is an error in every mode" "$VERIFY" "$TMP/none" "$GOOD" warn lbl

echo "=== talos-image-lock.sh against a fake Factory ==="
SCH=613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245
FAKE="$TMP/factory/image/$SCH/v9.9.9"; mkdir -p "$FAKE"
for p in scaleway openstack aws nocloud; do printf 'body-%s' "$p" >"$FAKE/$p-amd64.raw.zst"; done
export OA_FACTORY_BASE="file://$TMP/factory" OA_IMAGES_LOCK="$TMP/images.lock"
printf '%s  %s\n' "$BAD" "$SCH/v1.0.0/scaleway-amd64" >"$OA_IMAGES_LOCK"
rc_of 0 "records the four platforms of a version" "$LOCKER" --version v9.9.9 --arch amd64
n="$(grep -c "/v9.9.9/" "$OA_IMAGES_LOCK")"; [ "$n" = 4 ] && ok "four lines for v9.9.9" || bad "lines for v9.9.9: $n"
grep -q "/v1.0.0/scaleway-amd64" "$OA_IMAGES_LOCK" && ok "an older version's line is kept" || bad "the older line was dropped"
want="$(sha256sum "$FAKE/aws-amd64.raw.zst" | awk '{print $1}')"
grep -q "^$want  $SCH/v9.9.9/aws-amd64$" "$OA_IMAGES_LOCK" && ok "the recorded hash is the file's" || bad "wrong hash for aws-amd64"
cp "$OA_IMAGES_LOCK" "$TMP/first"; "$LOCKER" --version v9.9.9 --arch amd64 >/dev/null 2>&1
cmp -s "$TMP/first" "$OA_IMAGES_LOCK" && ok "a second run changes nothing" || bad "the lock is not stable across runs"
rc_of 0 "--check passes on an untouched Factory" "$LOCKER" --check --version v9.9.9 --arch amd64
printf 'tampered' >"$FAKE/nocloud-amd64.raw.zst"
rc_of 1 "--check fails when the Factory serves other bytes" "$LOCKER" --check --version v9.9.9 --arch amd64; says "nocloud-amd64" "…naming the file"
cp "$TMP/first" "$OA_IMAGES_LOCK"; grep -v "aws-amd64" "$TMP/first" >"$OA_IMAGES_LOCK"
rc_of 1 "--check fails on a platform the lock lacks" "$LOCKER" --check --version v9.9.9 --arch amd64; says "is not in" "…and says so"
rc_of 2 "an unknown arch is refused" "$LOCKER" --arch riscv
unset OA_FACTORY_BASE OA_IMAGES_LOCK

echo "=== the committed lock and the modules ==="
LOCK="$ROOT/infrastructure/opentofu/talos-image/images.lock"
body="$(grep -Ev '^#|^[[:space:]]*$' "$LOCK")"
[ -n "$body" ] && ! grep -Evq '^[0-9a-f]{64}  [0-9a-f]{64}/v[0-9][^/ ]*/(scaleway|openstack|aws|nocloud)-(amd64|arm64)$' <<<"$body" \
  && ok "every line of images.lock is '<sha256>  <schematic>/<version>/<platform>-<arch>'" || bad "images.lock has a malformed line"
[ "$(awk '{print $2}' <<<"$body" | sort | uniq -d | wc -l)" = 0 ] && ok "no key is listed twice" || bad "a key appears twice"
PIN="$(awk '/variable "talos_installer_schematic_id"/,/^}/' "$ROOT/infrastructure/opentofu/cluster/variables.tf" | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([0-9a-f]{64})".*/\1/p' | head -1)"
grep -q "$PIN" "$ROOT/infrastructure/opentofu/talos-image/tests/images-lock.tftest.hcl" && ok "the tofu test uses the cluster's pinned schematic" || bad "tests/images-lock.tftest.hcl names another schematic than cluster/variables.tf"
VER="$("$ROOT/scripts/internal/talos-version.sh")"
miss=""; for pl in scaleway-amd64 openstack-amd64 aws-amd64 nocloud-amd64; do grep -q " $PIN/$VER/$pl$" <<<"$body" || miss="$miss $pl"; done
[ -z "$miss" ] && ok "the lock covers the cluster's Talos version ($VER) on all four platforms" || bad "images.lock has no line for $VER:$miss — run scripts/bootstrap/talos-image-lock.sh"
for m in scaleway ovh outscale; do
  f="$ROOT/infrastructure/opentofu/modules/talos-image/$m/main.tf"
  c="$(grep -n 'curl -fL' "$f" | head -1 | cut -d: -f1)"; v="$(grep -n 'verify-image-checksum.sh' "$f" | head -1 | cut -d: -f1)"; z="$(grep -n 'zstd -f -d' "$f" | head -1 | cut -d: -f1)"
  { [ -n "$c" ] && [ -n "$v" ] && [ -n "$z" ] && [ "$c" -lt "$v" ] && [ "$v" -lt "$z" ]; } \
    && ok "$m: the download is verified before it is decompressed" || bad "$m: curl at ${c:-none}, verifier at ${v:-none}, zstd at ${z:-none}"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
