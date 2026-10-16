#!/usr/bin/env bash
# cluster-security-tests.sh's checks on Cilium WireGuard (1.8) and the OpenBao bootstrap (4.6 development
# share, 4.7 seal-key escrow record and its proof), run against a stub kubectl: the verdict of each line, failure cases
# included. SUT overrides the script under test (how the mutants run).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/cluster-security-tests.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
# Every answer comes from an environment variable. Anything not listed answers with nothing and exit 0, so the
# script runs to its end (its other checks fail or skip on that, which this test does not read).
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  cluster-info*) exit 0 ;;
  *"configmap cilium-config"*) [ -n "${STUB_WG_CFG+x}" ] && printf '%s' "$STUB_WG_CFG"; exit 0 ;;
  *"exec ds/cilium"*) [ "${STUB_EXEC_FAIL:-}" = 1 ] && exit 1; printf 'Cilium: Ok\n%s\n' "${STUB_WG_STATUS:-}"; exit 0 ;;
  *"secret loki-s3-credentials"*"{.data.bucket}"*) printf '%s' "${STUB_LOKI_BUCKET:-}"; exit 0 ;;
  *"secret loki-s3-credentials"*"{.data.accessKey}"*) printf '%s' "${STUB_LOKI_KEY:-}"; exit 0 ;;
  *"secret backup-restic-env"*"{.data.PRIMARY_BUCKET}"*) printf '%s' "${STUB_BKP_BUCKET:-}"; exit 0 ;;
  *"secret backup-restic-env"*"{.data.PRIMARY_ACCESS_KEY}"*) printf '%s' "${STUB_BKP_KEY:-}"; exit 0 ;;
  *"secret openbao-recovery-dev"*) [ "${STUB_DEV:-}" = 1 ] && exit 0; exit 1 ;;
  *"secret openbao-recovery-shares"*) [ "${STUB_SHARES:-}" = 1 ] && exit 0; exit 1 ;;
  *"secret openbao-seal-key -o jsonpath={.data.key}"*) printf '%s' "${STUB_SEAL_B64:-}"; exit 0 ;;
  *"secret openbao-seal-key -o jsonpath"*) printf '%s' "${STUB_ESCROWED:-}"; exit 0 ;;
  *"configmap openbao-escrow-ack"*"{.data.escrowed-at}"*) printf '%s' "${STUB_ACK_AT:-}"; exit 0 ;;
  *"configmap openbao-escrow-ack"*"{.data.seal-key-sha256}"*) printf '%s' "${STUB_ACK_SHA:-}"; exit 0 ;;
  *"configmap openbao-escrow-ack"*"{.data.holders}"*) printf '%s' "${STUB_ACK_N:-}"; exit 0 ;;
  *"secret openbao-seal-key"*) [ "${STUB_SEAL:-}" = 1 ] && exit 0; exit 1 ;;
  *"get secret"*) exit 1 ;;
  "get clusterrolebinding -o json"*) [ -n "${STUB_CRB+x}" ] && printf '%s' "$STUB_CRB"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

run() { OUT="$(PATH="$TMP/bin:$PATH" bash "$SUT" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')"; }
line() { grep -F "$1" <<<"$OUT" | head -1; }
# <line prefix> <❌|✅|⏭️> — the verdict marker of the line that starts with that number
verdict() { line "$1" | grep -q "$2"; }

echo "=== 1.8 Cilium WireGuard ==="
STUB_WG_CFG=true STUB_WG_STATUS='Encryption:  Wireguard   [cilium_wg0 (Pubkey: x, Port: 51871, Peers: 2)]' run
verdict "1.8" "✅" && ok "enabled in the config and reported by the agent passes" || bad "green case: $(line 1.8)"
STUB_WG_CFG=true STUB_WG_STATUS='Encryption:  Disabled' run
verdict "1.8" "❌" && ok "the agent saying Disabled FAILS" || bad "Disabled passed: $(line 1.8)"
STUB_WG_CFG=false run
verdict "1.8" "❌" && ok "enable-wireguard false in the config FAILS" || bad "config false passed: $(line 1.8)"
run
verdict "1.8" "❌" && ok "no cilium-config at all FAILS (never a pass)" || bad "absent config passed: $(line 1.8)"
STUB_WG_CFG=true STUB_EXEC_FAIL=1 run
verdict "1.8" "⏭" && ok "config on but the agent unreadable is SKIPPED, not green" || bad "unreadable agent: $(line 1.8)"

echo "=== 3.7 cluster-admin bindings ==="
crb() { printf '{"items":[{"metadata":{"name":"%s"},"roleRef":{"name":"%s"},"subjects":%s}]}' "$1" "$2" "$3"; }
STUB_CRB="$(crb oa-admins cluster-admin '[{"kind":"Group","name":"oa:admins"}]')" run
verdict "3.7" "✅" && ok "the platform-rbac binding oa-admins (Group oa:admins) is allowed" || bad "oa-admins: $(line 3.7)"
STUB_CRB="$(crb oa-admins cluster-admin '[{"kind":"Group","name":"oa:admins"},{"kind":"User","name":"mallory"}]')" run
verdict "3.7" "❌" && ok "...but not with an extra subject" || bad "oa-admins + user passed: $(line 3.7)"
STUB_CRB="$(crb oa-admins cluster-admin '[{"kind":"Group","name":"other:group"}]')" run
verdict "3.7" "❌" && ok "...nor bound to another group" || bad "oa-admins other group passed: $(line 3.7)"
STUB_CRB="$(crb oncall-admins cluster-admin '[{"kind":"Group","name":"oa:admins"}]')" run
verdict "3.7" "❌" && ok "another binding name to cluster-admin still FAILS" || bad "oncall-admins passed: $(line 3.7)"

echo "=== 4.6 development bootstrap ==="
STUB_DEV=1 OA_ENVIRONMENT=prod run
verdict "4.6" "❌" && ok "openbao-recovery-dev on prod FAILS" || bad "dev share on prod: $(line 4.6)"
STUB_DEV=1 OA_ENVIRONMENT=dev run
verdict "4.6" "⏭" && ok "…and is only reported on dev" || bad "dev share on dev: $(line 4.6)"
STUB_DEV=1 run
verdict "4.6" "⏭" && ok "…and when the environment is not said" || bad "dev share, env unset: $(line 4.6)"
STUB_SHARES=1 OA_ENVIRONMENT=prod run
verdict "4.6" "✅" && ok "PGP recovery shares and no dev Secret passes on prod" || bad "shares: $(line 4.6)"
OA_ENVIRONMENT=prod run
verdict "4.6" "⏭" && ok "neither Secret is a skip, not a pass" || bad "none: $(line 4.6)"

echo "=== 4.7 seal-key escrow record ==="
# The live key is 32 raw bytes in the Secret (base64 in the API); the attestation holds the sha256 of those bytes.
SEAL_B64="$(printf 'a-32-byte-seal-key-fixture-00000' | base64 -w0)"
SEAL_SHA="$(printf 'a-32-byte-seal-key-fixture-00000' | sha256sum | cut -d' ' -f1)"
TODAY="$(date +%F)"; OLD_DAY="$(python3 -c 'import datetime;print(datetime.date.today()-datetime.timedelta(days=401))')"
esc() { STUB_SEAL=1 OA_ENVIRONMENT=prod OA_ESCROW_ANNOTATION_CHECK=1 STUB_SEAL_B64="$SEAL_B64" "$@"; }
STUB_SEAL=1 OA_ENVIRONMENT=prod run
verdict "4.7" "⏭" && ok "off by default, even on prod, until the escrow step exists" || bad "default: $(line 4.7)"
esc run
verdict "4.7" "❌" && ok "opted in, prod, no annotation FAILS" || bad "missing annotation: $(line 4.7)"
STUB_ESCROWED=2026-10-01T00:00:00Z esc run
verdict "4.7" "❌" && grep -q 'no ConfigMap openbao-escrow-ack' <<<"$OUT" && ok "the annotation alone FAILS: the hash and the custodians are not recorded" || bad "annotation only: $(line 4.7)"
STUB_ESCROWED=2026-10-01T00:00:00Z STUB_ACK_AT=$TODAY STUB_ACK_SHA=$SEAL_SHA STUB_ACK_N=2 esc run
verdict "4.7" "✅" && ok "annotation + attestation of the live key, 2 holders, today: passes" || bad "complete record: $(line 4.7)"
grep -qF "$SEAL_SHA$SEAL_B64" <<<"$OUT" && bad "the key or its encoding was printed" || ok "…and neither the key nor its encoding is printed"
STUB_ESCROWED=x STUB_ACK_AT=$TODAY STUB_ACK_SHA=$(printf 'another key' | sha256sum | cut -d' ' -f1) STUB_ACK_N=2 esc run
verdict "4.7" "❌" && grep -q 'another key than the live one' <<<"$OUT" && ok "an attestation of ANOTHER key (a rotation since) FAILS" || bad "old key: $(line 4.7)"
STUB_ESCROWED=x STUB_ACK_AT=$TODAY STUB_ACK_SHA=$SEAL_SHA STUB_ACK_N=1 esc run
verdict "4.7" "❌" && grep -q 'at least two' <<<"$OUT" && ok "one holder FAILS" || bad "one holder: $(line 4.7)"
STUB_ESCROWED=x STUB_ACK_AT=$TODAY STUB_ACK_SHA=$SEAL_SHA STUB_ACK_N=two esc run
verdict "4.7" "❌" && ok "a holders value that is not a number FAILS" || bad "holders text: $(line 4.7)"
STUB_ESCROWED=x STUB_ACK_AT=$OLD_DAY STUB_ACK_SHA=$SEAL_SHA STUB_ACK_N=2 esc run
verdict "4.7" "❌" && grep -q 'limit 400' <<<"$OUT" && ok "an attestation older than 400 days FAILS" || bad "stale: $(line 4.7)"
STUB_ESCROWED=x STUB_ACK_AT=not-a-date STUB_ACK_SHA=$SEAL_SHA STUB_ACK_N=2 esc run
verdict "4.7" "❌" && ok "an undated attestation FAILS" || bad "undated: $(line 4.7)"
STUB_ESCROWED=x STUB_ACK_AT=$TODAY STUB_ACK_SHA=$SEAL_SHA STUB_ACK_N=2 STUB_SEAL=1 OA_ENVIRONMENT=prod OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "❌" && grep -q 'cannot read the live seal key' <<<"$OUT" && ok "a live key that cannot be read is a FAIL, not a pass" || bad "unreadable key: $(line 4.7)"
STUB_SEAL=1 OA_ENVIRONMENT=dev OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "⏭" && ok "a dev cluster is skipped" || bad "dev: $(line 4.7)"
# Lab 11: the opt-in alone looked like it had been ignored. The skip names both switches and the environment it saw.
grep -q "OA_ESCROW_ANNOTATION_CHECK=1 is set but OA_ENVIRONMENT is 'dev'" <<<"$OUT" && grep -q 'ENVIRONMENT=prod task cluster-security' <<<"$OUT" \
  && ok "…and the skip says that the opt-in needs prod, with the command" || bad "dev skip text: $(line 4.7)"
STUB_SEAL=1 OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "⏭" && grep -q "OA_ENVIRONMENT is 'unset'" <<<"$OUT" && ok "an unset environment is named as unset in the skip" || bad "unset skip text: $(line 4.7)"
OA_ENVIRONMENT=prod OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "⏭" && ok "no seal-key Secret (static seal not in use) is a skip" || bad "no seal key: $(line 4.7)"

echo "=== 4.8 / 4.9 Loki's bucket and keys ==="
# The API returns Secret values base64-encoded; the script compares them as they come.
b64() { printf '%s' "$1" | base64; }
LB="$(b64 loki-bucket)"; BB="$(b64 backups-bucket)"; LK="$(b64 loki-access)"; BK="$(b64 backups-access)"
STUB_LOKI_BUCKET=$LB STUB_BKP_BUCKET=$BB STUB_LOKI_KEY=$LK STUB_BKP_KEY=$BK run
verdict "4.8" "✅" && ok "its own bucket passes" || bad "own bucket: $(line 4.8)"
verdict "4.9" "✅" && ok "…with its own key pair passes" || bad "own keys: $(line 4.9)"
STUB_LOKI_BUCKET=$BB STUB_BKP_BUCKET=$BB STUB_LOKI_KEY=$LK STUB_BKP_KEY=$BK run
verdict "4.8" "❌" && ok "the backups bucket FAILS (a cluster seeded before infra 0.2.1)" || bad "same bucket passed: $(line 4.8)"
STUB_LOKI_BUCKET=$LB STUB_BKP_BUCKET=$BB STUB_LOKI_KEY=$BK STUB_BKP_KEY=$BK run
verdict "4.8" "✅" && verdict "4.9" "⏭" && ok "own bucket but the backups' key pair is a SKIP naming the residual risk, not a pass" || bad "shared keys: $(line 4.9)"
grep -qF "$BK" <<<"$OUT" && bad "an encoded key was printed" || ok "no secret value in the output"
run
verdict "4.8" "⏭" && ok "neither Secret found is a skip" || bad "absent: $(line 4.8)"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
