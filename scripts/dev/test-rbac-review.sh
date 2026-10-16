#!/usr/bin/env bash
# scripts/ops/rbac-review.sh on fixture bindings through a stub kubectl: what it flags, what it lets through,
# and that an empty or failed listing is never a clean review. SUT overrides the script under test (mutants).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/rbac-review.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The script finds rbac-review.jq next to itself: run a copy of the script under test beside the real filter.
mkdir -p "$TMP/s"; cp "$SUT" "$TMP/s/rbac-review.sh"; cp "$ROOT/scripts/ops/rbac-review.jq" "$TMP/s/"; SUT="$TMP/s/rbac-review.sh"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_FAIL:-}" = 1 ] && exit 1
cat "$FIXTURE"
STUB
chmod +x "$TMP/bin/kubectl"

CRB() { printf '{"kind":"ClusterRoleBinding","metadata":{"name":"%s"},"roleRef":{"name":"%s"},"subjects":%s}' "$1" "$2" "$3"; }
RB()  { printf '{"kind":"RoleBinding","metadata":{"name":"%s","namespace":"%s"},"roleRef":{"name":"%s"},"subjects":%s}' "$1" "$2" "$3" "$4"; }
SA='[{"kind":"ServiceAccount","name":"flux","namespace":"flux-system"}]'
list() { local IFS=,; printf '{"kind":"List","items":[%s]}' "$*"; }
run() { OUT="$(cd "$TMP" && PATH="$TMP/bin:$PATH" FIXTURE="$TMP/fx.json" bash "$SUT" "$TMP/out" 2>&1)"; RC=$?; }

echo "=== clean ==="
list "$(CRB cluster-admin cluster-admin '[{"kind":"Group","name":"system:masters"}]')" \
     "$(CRB cluster-reconciler cluster-admin "$SA")" \
     "$(CRB cnpg-manager cluster-admin "$SA")" \
     "$(RB reader platform view '[{"kind":"ServiceAccount","name":"x","namespace":"platform"}]')" >"$TMP/fx.json"
run
[ "$RC" = 0 ] && grep -q 'nothing flagged' <<<"$OUT" && ok "system:masters, Flux, a vendor prefix and a ServiceAccount view binding: clean" || bad "clean case: rc=$RC $OUT"
F="$(ls "$TMP"/out/rbac-review-*.tsv 2>/dev/null)"
[ -n "$F" ] && [ "$(head -1 "$F" | cut -f7)" = verdict ] && grep -q 'flux-system/flux' "$F" \
  && ok "a dated .tsv is written, with the namespace-qualified subject" || bad "no usable output file: $F"

echo "=== flagged ==="
list "$(CRB oncall-admins cluster-admin '[{"kind":"Group","name":"oidc:oa-admins"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q '\[HUMAN,ADMIN\].*oncall-admins' <<<"$OUT" && ok "a Group bound to cluster-admin is both HUMAN and ADMIN, and fails the run" || bad "group admin: rc=$RC $OUT"
list "$(RB dev-edit platform edit '[{"kind":"User","name":"alice@example.org"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q '\[HUMAN\] namespace binding platform/dev-edit' <<<"$OUT" && ! grep -q ADMIN <<<"$OUT" \
  && ok "a named User on a namespace edit role is HUMAN only" || bad "user edit: rc=$RC $OUT"
list "$(CRB anon-view view '[{"kind":"User","name":"system:anonymous"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q '\[ANON\]' <<<"$OUT" && ! grep -q HUMAN <<<"$OUT" && ok "system:anonymous bound to anything is ANON (and a system: name is not HUMAN)" || bad "anon: rc=$RC $OUT"
list "$(CRB system:public-info-viewer system:public-info-viewer '[{"kind":"Group","name":"system:unauthenticated"}]')" >"$TMP/fx.json"
run
[ "$RC" = 0 ] && ok "the stock system:public-info-viewer binding to system:unauthenticated is not flagged (it is on every cluster)" || bad "stock public-info-viewer flagged: rc=$RC $OUT"
list "$(CRB system:public-info-viewer cluster-admin '[{"kind":"Group","name":"system:unauthenticated"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q '\[ANON' <<<"$OUT" && ok "...but the same binding name to another role is still flagged" || bad "disguised binding passed: rc=$RC $OUT"
list "$(CRB sneaky cluster-admin "$SA")" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q '\[ADMIN\].*sneaky' <<<"$OUT" && ok "a ServiceAccount with cluster-admin outside the allowlist is ADMIN" || bad "sa admin: rc=$RC $OUT"
list "$(CRB nobody view null)" >"$TMP/fx.json"
run
[ "$RC" = 0 ] && grep -q 'nobody' "$(ls "$TMP"/out/rbac-review-*.tsv)" && ok "a binding without subjects is still listed (and harmless)" || bad "no subjects: rc=$RC $OUT"

echo "=== the platform-rbac bindings of named operators ==="
list "$(CRB oa-admins cluster-admin '[{"kind":"Group","name":"oa:admins"}]')" \
     "$(CRB oa-readers view '[{"kind":"Group","name":"oa:readers"}]')" >"$TMP/fx.json"
run
[ "$RC" = 0 ] && ok "oa-admins (oa:admins -> cluster-admin) and oa-readers (oa:readers -> view) are not flagged" || bad "platform-rbac flagged: rc=$RC $OUT"
list "$(CRB oa-admins cluster-admin '[{"kind":"Group","name":"oa:admins"},{"kind":"User","name":"mallory"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q 'mallory' <<<"$OUT" && ! grep -q 'oa:admins' <<<"$OUT" && ok "an extra subject on oa-admins is flagged, the group line is not" || bad "extra subject: rc=$RC $OUT"
list "$(CRB oa-admins cluster-admin '[{"kind":"Group","name":"oa:readers"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && grep -q '\[HUMAN,ADMIN\]' <<<"$OUT" && ok "oa-admins bound to another group is flagged" || bad "wrong group: rc=$RC $OUT"
list "$(CRB oa-readers cluster-admin '[{"kind":"Group","name":"oa:readers"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && ok "oa-readers escalated to cluster-admin is flagged" || bad "readers escalated: rc=$RC $OUT"
list "$(RB oa-admins platform cluster-admin '[{"kind":"Group","name":"oa:admins"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && ok "the same name as a namespaced RoleBinding is flagged" || bad "rolebinding disguise: rc=$RC $OUT"
list "$(CRB oa-admins2 cluster-admin '[{"kind":"Group","name":"oa:admins"}]')" >"$TMP/fx.json"
run
[ "$RC" = 1 ] && ok "another binding name for the group is flagged" || bad "renamed: rc=$RC $OUT"

echo "=== a broken answer is never a clean review ==="
STUB_FAIL=1 run
[ "$RC" = 2 ] && ok "kubectl failing exits 2, not 0" || bad "kubectl failure: rc=$RC $OUT"
printf '{"kind":"List","items":[]}' >"$TMP/fx.json"
run
[ "$RC" = 2 ] && ok "an empty listing exits 2: every cluster has bindings" || bad "empty list: rc=$RC $OUT"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
