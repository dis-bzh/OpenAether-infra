#!/usr/bin/env bash
# scan-all-refs.sh against a throwaway remote: a leak served only by a pull-request head or a tag is caught (the
# branch scan of security.yml does not see it), a listed one is not, and a scan that cannot run is never a pass.
# Needs gitleaks: run by `task security` and by the History scan workflow, not by `task test-scripts`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/dev/scan-all-refs.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v gitleaks >/dev/null || { echo "✗ gitleaks not on PATH" >&2; exit 1; }

# RFC 1112 "reserved for future use": routable to the rule, allocated to no one. Assembled here, never written.
ADDR="$(printf '%d.%d.%d.%d' 240 0 0 7)"
g() { git -C "$TMP/work" -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/work"; g remote add origin "$TMP/origin.git"
echo 'region = "fr-par"' >"$TMP/work/main.tf"; g add -A; g commit -q -m base; g push -q origin main

export KNOWN="$TMP/known.sha256"
run() { OUT="$(bash "$SUT" "$@" 2>&1)"; RC=$?; }

run "$TMP/origin.git"
[ "$RC" = 0 ] && grep -q '0 finding(s)' <<<"$OUT" && ok "a clean remote passes, and says what it scanned" || bad "clean: rc=$RC $OUT"

# A leak on a pull-request head only: what GitHub keeps after a purge of the branches.
g checkout -q -b pr; printf 'admin_ip = ["%s/32"]\n' "$ADDR" >"$TMP/work/main.tf"; g commit -q -am leak
g push -q origin pr:refs/pull/1/head; g checkout -q main; g branch -q -D pr
git clone -q "$TMP/origin.git" "$TMP/clone"
gitleaks git --no-banner -c "$ROOT/.gitleaks-envdata.toml" "$TMP/clone" >/dev/null 2>&1 \
  && ok "the branch scan (security.yml's shape, on a clone) does not see it: the gap this closes" \
  || bad "a plain clone already saw the pull-request head"
run "$TMP/origin.git"
[ "$RC" = 1 ] && grep -q '✗ new: .*openaether-public-ipv4' <<<"$OUT" && ok "the pull-request head is scanned: the leak FAILS" || bad "PR head: rc=$RC $OUT"
grep -qF "$ADDR" <<<"$OUT" && bad "the address was printed" || ok "…and the address is not printed"

run --update "$TMP/origin.git"
grep -qF "$ADDR" "$KNOWN" && bad "the list holds the address" || ok "--update lists it by hash: the list holds no address"
run "$TMP/origin.git"
[ "$RC" = 0 ] && grep -q '1 already listed' <<<"$OUT" && ok "a listed finding passes" || bad "listed: rc=$RC $OUT"

g tag v0 "$(g rev-parse HEAD)"; printf 's3 = "s3-%s-scaleway-backups-dev"\n' acme >"$TMP/work/b.tf"; g add -A; g commit -q -m b
g tag v1; g reset -q --hard v0; g push -q origin v1
run "$TMP/origin.git"
[ "$RC" = 1 ] && grep -q '✗ new: .*openaether-bucket-name' <<<"$OUT" && ok "a commit served only by a tag is scanned: FAILS" || bad "tag: rc=$RC $OUT"

git -C "$TMP/origin.git" update-ref -d refs/pull/1/head; git -C "$TMP/origin.git" tag -d v1 >/dev/null
run "$TMP/origin.git"
[ "$RC" = 0 ] && grep -q '1 listed finding(s) no longer served' <<<"$OUT" && ok "a listed finding gone from every ref is counted, not failed" || bad "gone: rc=$RC $OUT"

CONFIG="$TMP/missing.toml" run "$TMP/origin.git"
[ "$RC" != 0 ] && ok "gitleaks that cannot run is a FAIL, not a pass" || bad "missing config passed: $OUT"
run "$TMP/nowhere.git"
[ "$RC" != 0 ] && ok "a remote that cannot be cloned is a FAIL" || bad "no remote passed: $OUT"
git init -q --bare "$TMP/empty.git"
run "$TMP/empty.git"
[ "$RC" != 0 ] && ok "a remote that serves no ref is a FAIL (nothing was scanned)" || bad "empty remote passed: $OUT"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
