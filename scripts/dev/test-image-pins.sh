#!/usr/bin/env bash
# check-image-pins.sh against fixtures: each class counted, and the exit code seen
# both ways. A classifier that counts nothing would print "0 tag only" forever.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/dev/check-image-pins.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
printf 'registry.example/team/rec:v1.0.0 %s\n' "$DIGEST" >"$TMP/lock"
cat >"$TMP/m.yaml" <<YAML
spec:
  containers:
    - name: a
      image: registry.example/team/pinned:1.2.3@${DIGEST}
    - name: b
      image: "registry.example/team/rec:v1.0.0"
    - name: c
      image: registry.example/team/loose:2.0.0
    - name: d
      image: \${templated}
    - name: e
      imagePullPolicy: Always
YAML
printf 'k: v\n' >"$TMP/none.yaml"

out="$("$CHECK" --lock "$TMP/lock" "$TMP/m.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "report mode exits 0 with an unpinned image" || bad "report mode exited $rc"
grep -q '4 image reference(s): 1 pinned by digest, 1 tag with a recorded digest, 1 tag only' <<<"$out" \
  && ok "counts: 1 digest, 1 recorded, 1 tag only; the templated one and imagePullPolicy are not images" \
  || bad "wrong counts: $out"
grep -q 'loose:2.0.0' <<<"$out" && ok "the unpinned image is named" || bad "unpinned image not named"
grep -q 'pinned:1.2.3' <<<"$out" && bad "a pinned image was listed as a problem" || ok "a pinned image is not listed"

"$CHECK" --enforce --lock "$TMP/lock" "$TMP/m.yaml" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "--enforce exits 1 on the unpinned image" || bad "--enforce exited $rc"
"$CHECK" --enforce --lock "$TMP/lock" "$TMP/none.yaml" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "--enforce exits 0 when nothing is unpinned" || bad "--enforce exited $rc on a clean file"
: >"$TMP/empty-lock"
"$CHECK" --enforce --lock "$TMP/empty-lock" "$TMP/m.yaml" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "an image whose digest is not recorded is unpinned" || bad "empty lock exited $rc"
out="$(GITHUB_ACTIONS=true "$CHECK" --lock "$TMP/lock" "$TMP/m.yaml" 2>&1)"
grep -q "::warning file=$TMP/m.yaml,line=8::image registry.example/team/loose:2.0.0" <<<"$out" \
  && ok "under GitHub Actions an unpinned image is an annotation with file and line" || bad "no annotation: $out"

echo "=== the real repository ==="
"$CHECK" --enforce >/dev/null 2>&1 && ok "no tracked manifest pins an image by tag alone" || bad "the repository has an unpinned image: run $CHECK"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
