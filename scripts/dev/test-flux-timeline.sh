#!/usr/bin/env bash
# flux-timeline.py, offline, on a synthetic list (no cluster). Each check has a twin that must fail.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/scripts/ops/flux-timeline.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# a: created 00:00, Ready 00:10. b dependsOn a: created 00:00, Ready 00:40. c dependsOn b: created 00:00, Ready 01:30.
# d is not Ready. e dependsOn a (other namespace form), Ready 00:20.
cat >"$TMP/in.json" <<'J'
{"items":[
 {"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"a","creationTimestamp":"2026-01-01T00:00:00Z"},"spec":{},
  "status":{"conditions":[{"type":"Ready","status":"True","lastTransitionTime":"2026-01-01T00:00:10Z"}]}},
 {"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"b","creationTimestamp":"2026-01-01T00:00:00Z"},"spec":{"dependsOn":[{"name":"a"}]},
  "status":{"conditions":[{"type":"Ready","status":"True","lastTransitionTime":"2026-01-01T00:00:40Z"}]}},
 {"kind":"HelmRelease","metadata":{"namespace":"obs","name":"c","creationTimestamp":"2026-01-01T00:00:00Z"},"spec":{"dependsOn":[{"name":"b","namespace":"flux-system"}]},
  "status":{"conditions":[{"type":"Ready","status":"True","lastTransitionTime":"2026-01-01T00:01:30Z"}]}},
 {"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"d","creationTimestamp":"2026-01-01T00:00:05Z"},"spec":{},
  "status":{"conditions":[{"type":"Ready","status":"False","lastTransitionTime":"2026-01-01T00:00:50Z"}]}},
 {"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"e","creationTimestamp":"2026-01-01T00:00:00Z"},"spec":{"dependsOn":[{"name":"a"}]},
  "status":{"conditions":[{"type":"Ready","status":"True","lastTransitionTime":"2026-01-01T00:00:20Z"}]}}
]}
J
out="$(python3 -I "$T" "$TMP/in.json" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a valid list exits 0" || bad "exit $rc"
grep -qP 'HelmRelease\tobs/c\t0\t90\t90\tflux-system/b' <<<"$out" && ok "cross-namespace dependency and wait of 90 s" || bad "line of obs/c"
grep -qP 'Kustomization\tflux-system/d\t5\t-\t-' <<<"$out" && ok "a not-Ready object is shown with '-'" || bad "line of d"
path="$(sed -n '/^critical path/,$p' <<<"$out")"
grep -q 'ends at ready_s 90' <<<"$path" && ok "the path ends at the last Ready" || bad "path end"
[ "$(grep -c '^  ' <<<"$path")" -eq 3 ] && grep -q '+30s' <<<"$path" && ok "path a -> b -> c, b adds 30 s" || bad "path links: $path"
grep -q 'flux-system/d\|flux-system/e' <<<"$path" && bad "d or e leaked into the path" || ok "an unrelated or not-Ready object is not on the path"
python3 -I "$T" /nonexistent >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unreadable input exits 2" || bad "missing file"
echo '{"items":[]}' >"$TMP/empty.json"; python3 -I "$T" "$TMP/empty.json" >/dev/null 2>&1; [ $? -eq 2 ] && ok "an empty list exits 2" || bad "empty list"
[ "$FAIL" -eq 0 ] && { echo "flux-timeline: all passed"; exit 0; } || { echo "flux-timeline: $FAIL failed"; exit 1; }
