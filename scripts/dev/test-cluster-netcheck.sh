#!/usr/bin/env bash
# scripts/ops/cluster-netcheck.sh against a stub kubectl: what it concludes from each curl exit code, that a
# broken probe invalidates the run, and that the temporary namespace is always removed. SUT overrides the
# script under test (how the mutants run).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/cluster-netcheck.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
# CURL_<ip with dots as _> = the exit code curl gives for that address; CURL_API for the control.
# SVC_<namespace with - as _> = "name ip port" of its Service (empty = none). CALLS logs every command.
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$*" in
  cluster-info*) exit 0 ;;
  apply*) cat >/dev/null; exit 0 ;;
  *"wait --for=condition=Ready"*) [ "${POD_NOT_READY:-}" = 1 ] && exit 1; exit 0 ;;
  *"exec probe -- curl"*)
    url="${*: -1}"
    if [[ "$url" == https://kubernetes.default.svc ]]; then exit "${CURL_API:-0}"; fi
    ip="${url#http://}"; ip="${ip%%:*}"; v="CURL_${ip//./_}"; exit "${!v:-28}" ;;
  "get svc -n "*) ns="$4"; v="SVC_${ns//-/_}"; read -r n i p <<<"${!v:-}"
    [ -n "$n" ] && printf '{"items":[{"metadata":{"name":"headless"},"spec":{"clusterIP":"None","ports":[{"port":1}]}},{"metadata":{"name":"%s"},"spec":{"clusterIP":"%s","ports":[{"port":%s}]}}]}' "$n" "$i" "$p" || printf '{"items":[]}'
    exit 0 ;;
  *"delete namespace"*) exit 0 ;;
  *"get pod probe"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
export CALLS="$TMP/calls"
run() { : >"$CALLS"; OUT="$(PATH="$TMP/bin:$PATH" bash "$SUT" "$@" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')"; RC=${PIPESTATUS[0]}; }
export OA_NETCHECK_NAMESPACES="ns-a ns-b" OA_NETCHECK_TIMEOUT=1
export SVC_ns_a="svc-a 10.0.0.1 8200" SVC_ns_b="svc-b 10.0.0.2 5432"

echo "=== the verdicts ==="
run
[ "$RC" = 0 ] && grep -q 'ns-a/svc-a:8200: timed out' <<<"$OUT" && grep -q 'ns-b/svc-b:5432: timed out' <<<"$OUT" && grep -q 'control: the probe reaches' <<<"$OUT" \
  && ok "control answers, both targets time out: green" || bad "green case: rc=$RC $OUT"

CURL_10_0_0_2=0 run
[ "$RC" != 0 ] && grep -q '✗ ns-b/svc-b:5432: answered' <<<"$OUT" && ! grep -q 'ns-a.*answered' <<<"$OUT" \
  && ok "a target that ANSWERS fails the run, by namespace and port" || bad "answering target: rc=$RC $OUT"

CURL_10_0_0_1=7 run
[ "$RC" != 0 ] && grep -q '? ns-a/svc-a:8200: connection REFUSED' <<<"$OUT" \
  && ok "'connection refused' is UNCHECKED, not a pass: the packet was not dropped" || bad "refused: rc=$RC $OUT"

CURL_API=7 run
[ "$RC" != 0 ] && grep -q 'the probe is broken' <<<"$OUT" && ! grep -q 'timed out' <<<"$OUT" \
  && ok "a probe that cannot reach the API server invalidates every timeout (none is reported as a pass)" || bad "broken control: rc=$RC $OUT"

CURL_API=22 run
[ "$RC" = 0 ] && ok "an HTTP error from the API server (401/403) still proves the path is open" || bad "curl 22 as control: rc=$RC $OUT"

POD_NOT_READY=1 run
[ "$RC" != 0 ] && grep -q 'did not become Ready' <<<"$OUT" && ok "a pod that never starts is UNCHECKED" || bad "pod not ready: rc=$RC $OUT"

SVC_ns_a="" SVC_ns_b="" run
[ "$RC" != 0 ] && grep -q 'ns-a: no Service' <<<"$OUT" && ok "no Service anywhere: skipped, and with nothing proven the run is not green" || bad "no services: rc=$RC $OUT"

echo "=== it cleans up ==="
run
grep -q '^delete namespace oa-netcheck' "$CALLS" && ok "the temporary namespace is deleted at the end" || bad "no delete on a normal run: $(cat "$CALLS")"
CURL_API=7 run
grep -q '^delete namespace oa-netcheck' "$CALLS" && ok "…and also when the control fails" || bad "no delete after a failed control"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
