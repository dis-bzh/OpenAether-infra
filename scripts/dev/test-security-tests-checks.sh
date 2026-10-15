#!/usr/bin/env bash
# cluster-security-tests.sh's checks on Cilium WireGuard (1.8) and the OpenBao bootstrap (4.6 development
# share, 4.7 seal-key escrow record), run against a stub kubectl: the verdict of each line, failure cases
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
  *"secret openbao-seal-key -o jsonpath"*) printf '%s' "${STUB_ESCROWED:-}"; exit 0 ;;
  *"secret openbao-seal-key"*) [ "${STUB_SEAL:-}" = 1 ] && exit 0; exit 1 ;;
  *"get secret"*) exit 1 ;;
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
STUB_SEAL=1 OA_ENVIRONMENT=prod run
verdict "4.7" "⏭" && ok "off by default, even on prod, until the escrow step exists" || bad "default: $(line 4.7)"
STUB_SEAL=1 OA_ENVIRONMENT=prod OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "❌" && ok "opted in, prod, no annotation FAILS" || bad "missing annotation: $(line 4.7)"
STUB_SEAL=1 STUB_ESCROWED=2026-10-01T00:00:00Z OA_ENVIRONMENT=prod OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "✅" && ok "opted in, prod, annotation present passes" || bad "annotation present: $(line 4.7)"
STUB_SEAL=1 OA_ENVIRONMENT=dev OA_ESCROW_ANNOTATION_CHECK=1 run
verdict "4.7" "⏭" && ok "a dev cluster is skipped" || bad "dev: $(line 4.7)"
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
