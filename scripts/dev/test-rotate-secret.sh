#!/usr/bin/env bash
# scripts/ops/rotate-secret.sh through a stub kubectl that plays OpenBao and the ExternalSecrets: a dry run writes nothing;
# --apply writes a check-and-set new version that keeps the fields it was not given; the paths that would break their
# consumers are refused with a reason; a failed write nudges and restarts nothing; no value reaches an output or a command
# line. SUT overrides the script under test (how the mutants run).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
SUT="${SUT:-$PWD/scripts/ops/rotate-secret.sh}"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export STUB_LOG="$SB/calls.log" KUBECONFIG="$SB/kubeconfig"

mkdir "$SB/bin"
cat >"$SB/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl:%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  "-n foundation-vault create token openaether-admin"*) [ -z "${STUB_NO_TOKEN:-}" ] || { echo "Error: not found" >&2; exit 1; }; printf 'jwt-STUB-TOKEN'; exit 0 ;;
  "-n foundation-vault exec -i openbao-0 -- sh -c "*)
    mode="${*: -2:1}"; IFS= read -r jwt; printf 'stdin-jwt:%s\n' "$jwt" >>"$STUB_LOG"
    if [ "$mode" = read ]; then
      [ -z "${STUB_MISSING:-}" ] || { echo "No value found" >&2; exit 2; }
      printf '{"data":{"data":{"endpoint":"https://s3.example.invalid","bucket":"b-example","access_key":"OLD-AK","secret_key":"OLD-SK","webhook-url":"https://old.example.invalid/x"},"metadata":{"version":%s}}}' "${STUB_VERSION:-3}"
    else
      doc="$(cat)"; printf 'put:%s\n' "$doc" >>"$STUB_LOG"
      [ -z "${STUB_CAS_FAIL:-}" ] || { echo "check-and-set parameter did not match the current version" >&2; exit 2; }
      printf '{"data":{"version":%s}}' "$(( ${STUB_VERSION:-3} + 1 ))"
    fi
    exit 0 ;;
  "get externalsecrets -A -o jsonpath"*) printf 'backup restic-env\nobservability loki\n'; exit 0 ;;
  "get externalsecrets -A -o json")
    printf '{"items":[{"status":{"refreshTime":"%s"}},{"status":{"refreshTime":"%s"}}]}' "${STUB_REFRESH:-2999-01-01T00:00:00Z}" "${STUB_REFRESH:-2999-01-01T00:00:00Z}"; exit 0 ;;
  "annotate externalsecret"*) exit 0 ;;
  "-n "*" rollout restart "*) exit 0 ;;
esac
echo "stub kubectl: unexpected call: $*" >&2; exit 99
STUB
chmod +x "$SB/bin/kubectl"
run() { : >"$STUB_LOG"; OUT="$(PATH="$SB/bin:$PATH" OA_ROTATE_POLL=0 OA_ROTATE_WAIT=1 bash "$SUT" "$@" 2>&1 </dev/null)"; RC=$?; }
puts()  { grep '^put:' "$STUB_LOG" | head -1 | sed 's/^put://'; }
wrote() { grep -q '^put:' "$STUB_LOG"; }

AK='NEW-AK-fixture-0001'; SK='NEW-SK-fixture-secret-0002'
S3=(OA_ROTATE_ACCESS_KEY_ID="$AK" OA_ROTATE_SECRET_ACCESS_KEY="$SK")

echo "=== dry run ==="
export "${S3[@]}"
run backup/s3-primary
[ "$RC" = 0 ] && ! wrote && grep -q 'dry run: nothing written' <<<"$OUT" && grep -q 'version 3' <<<"$OUT" && ok "no --apply: reads, plans, writes nothing" || bad "dry run: rc=$RC $OUT"
grep -q 'keeps: bucket, endpoint, webhook-url' <<<"$OUT" && ok "…and names the fields it keeps" || bad "kept fields: $OUT"
grep -q 'annotate externalsecret' "$STUB_LOG" && bad "a dry run nudged ExternalSecrets" || ok "…and nudges nothing"

echo "=== apply: an S3 pair ==="
run backup/s3-primary --apply
[ "$RC" = 0 ] && wrote && ok "--apply writes" || bad "apply: rc=$RC $OUT"
[ "$(puts | jq -r .options.cas)" = 3 ] && ok "check-and-set on the version it read (3)" || bad "cas: $(puts)"
[ "$(puts | jq -r '.data.access_key + "|" + .data.secret_key')" = "$AK|$SK" ] && ok "the new pair replaces the old" || bad "pair: $(puts)"
[ "$(puts | jq -r '.data.endpoint + "|" + .data.bucket')" = "https://s3.example.invalid|b-example" ] && ok "the endpoint and bucket are kept" || bad "kept: $(puts)"
grep -q 'version 4 written' <<<"$OUT" && ok "the new version is reported" || bad "version: $OUT"
[ "$(grep -c 'annotate externalsecret' "$STUB_LOG")" = 2 ] && grep -q 'force-sync=' "$STUB_LOG" && ok "every ExternalSecret is nudged" || bad "nudge: $(cat "$STUB_LOG")"
grep -q 'rollout' "$STUB_LOG" && bad "restarted without being asked" || ok "no restart unless --restart"
for v in "$AK" "$SK" OLD-AK OLD-SK; do
  if grep -v '^put:' "$STUB_LOG" | grep -qF "$v" || grep -qF "$v" <<<"$OUT"; then bad "$v reached an output or a kubectl command line"; else ok "$v is on neither (only in the stdin document)"; fi
done
grep -q 'stdin-jwt:jwt-STUB-TOKEN' "$STUB_LOG" && ok "the OpenBao identity travelled on stdin" || bad "jwt"
OA_ROTATE_BUCKET=b-new run backup/s3-replica --apply
[ "$(puts | jq -r .data.bucket)" = b-new ] && [ "$(puts | jq -r .data.endpoint)" = "https://s3.example.invalid" ] && ok "OA_ROTATE_BUCKET changes the bucket and only it" || bad "bucket: $(puts)"
run observability/loki-s3 --apply
[ "$(puts | jq -r '.data.accessKey + "|" + .data.secretKey')" = "$AK|$SK" ] && ok "Loki's field names (accessKey, secretKey) are used" || bad "loki: $(puts)"

echo "=== apply: a single value ==="
unset OA_ROTATE_ACCESS_KEY_ID OA_ROTATE_SECRET_ACCESS_KEY
OA_ROTATE_VALUE='https://hooks.example.invalid/new' run observability/alertmanager-slack --apply
[ "$(puts | jq -r '.data["webhook-url"]')" = "https://hooks.example.invalid/new" ] && ok "the webhook URL is replaced" || bad "slack: rc=$RC $OUT"
OA_ROTATE_VALUE='http://hooks.example.invalid/new' run observability/alertmanager-slack --apply
[ "$RC" -ne 0 ] && ! wrote && grep -q 'https://' <<<"$OUT" && ok "a non-https URL is refused" || bad "http url: rc=$RC $OUT"
run observability/alertmanager-slack --apply
[ "$RC" -ne 0 ] && ! wrote && grep -q 'OA_ROTATE_VALUE is required' <<<"$OUT" && ok "a missing value is refused before the cluster is touched" || bad "missing: rc=$RC $OUT"
export OA_ROTATE_ACCESS_KEY_ID="$AK"
run backup/s3-primary --apply
[ "$RC" -ne 0 ] && grep -q 'OA_ROTATE_SECRET_ACCESS_KEY is required' <<<"$OUT" && ok "half a pair is refused" || bad "half pair: rc=$RC $OUT"
OA_ROTATE_SECRET_ACCESS_KEY=$'a\nb' run backup/s3-primary --apply
[ "$RC" -ne 0 ] && ! wrote && grep -q 'line break' <<<"$OUT" && ok "a value with a line break is refused" || bad "newline: rc=$RC $OUT"
export OA_ROTATE_SECRET_ACCESS_KEY="$SK"

echo "=== refusals ==="
for p in backup/restic zitadel/masterkey longhorn/encryption zitadel/db grafana/db zitadel/admin grafana/admin minio/root; do
  run "$p" --apply
  [ "$RC" -ne 0 ] && ! wrote && ! grep -q 'kubectl:' "$STUB_LOG" && ok "$p: refused with a reason, the cluster not even asked" || bad "$p: rc=$RC $OUT"
done
run zitadel/db; grep -q 'ALTER ROLE' <<<"$OUT" && ok "the reason names what to do instead" || bad "no reason"
run secret/backup/s3-primary; [ "$RC" -ne 0 ] && ok "a path with the mount prefix is refused" || bad "secret/ prefix"
run something/else; [ "$RC" = 2 ] && grep -q 'Supported:' <<<"$OUT" && ok "an unknown path lists the supported ones" || bad "unknown: rc=$RC $OUT"
run backup/s3-primary --restart ns/pod/x; [ "$RC" = 2 ] && ok "--restart accepts only deployment/statefulset/daemonset" || bad "restart kind: rc=$RC $OUT"

echo "=== failures write and restart nothing ==="
STUB_CAS_FAIL=1 run backup/s3-primary --apply --restart observability/statefulset/loki
[ "$RC" -ne 0 ] && grep -q 'check-and-set' <<<"$OUT" && ! grep -q 'annotate externalsecret\|rollout' "$STUB_LOG" && ok "a lost check-and-set fails loudly and nudges nothing" || bad "cas fail: rc=$RC $OUT"
STUB_MISSING=1 run backup/s3-primary --apply
[ "$RC" -ne 0 ] && ! wrote && grep -q 'seed-openbao' <<<"$OUT" && ok "a path that does not exist points to the seed" || bad "missing path: rc=$RC $OUT"
STUB_NO_TOKEN=1 run backup/s3-primary --apply
[ "$RC" -ne 0 ] && ! wrote && ok "no ServiceAccount token, no write" || bad "no token: rc=$RC $OUT"

echo "=== --restart waits for the refresh ==="
run backup/s3-primary --apply --restart observability/statefulset/loki --restart foundation-databases/deployment/x
[ "$RC" = 0 ] && grep -q 'kubectl:-n observability rollout restart statefulset/loki' "$STUB_LOG" && grep -q 'kubectl:-n foundation-databases rollout restart deployment/x' "$STUB_LOG" \
  && ok "refreshed ExternalSecrets: both consumers are restarted" || bad "restart: rc=$RC $OUT"
STUB_REFRESH=2000-01-01T00:00:00Z run backup/s3-primary --apply --restart observability/statefulset/loki
[ "$RC" -ne 0 ] && grep -q 'NO consumer was restarted' <<<"$OUT" && ! grep -q 'rollout' "$STUB_LOG" && wrote && ok "ExternalSecrets that did not refresh: written, NOT restarted, and it says so" || bad "stale: rc=$RC $OUT"

echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
