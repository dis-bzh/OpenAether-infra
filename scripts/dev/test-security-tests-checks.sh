#!/usr/bin/env bash
# cluster-security-tests.sh's checks on the Loki and VMAgent egress (1.5, 1.6), Cilium WireGuard (1.8), the Istio
# AuthorizationPolicies (2.4, 2.7), Git-delivered Secret data (4.1) and the OpenBao bootstrap (4.6 development share, 4.7
# seal-key escrow record and its proof), run against a stub kubectl: the verdict of each line, failure cases included. SUT overrides the script under test (how the mutants run).
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
  *"get cnp vmagent -n services-observability"*)
    case "${STUB_VMA:-}" in
      notfound) echo 'Error from server (NotFound): ciliumnetworkpolicies.cilium.io "vmagent" not found' >&2; exit 1 ;;
      error) echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1 ;;
    esac
    # Only the exact queries of the script are answered: a changed jsonpath is an error, not the same answer.
    case "$*" in
      *"-o name") echo ciliumnetworkpolicy.cilium.io/vmagent ;;
      *"-o jsonpath={.spec.egress[*].toEntities[*]}") printf '%s' "${STUB_VMA_ENT:-}" ;;
      *) echo "stub: unexpected query: $*" >&2; exit 1 ;;
    esac
    exit 0 ;;
  *"get cnp loki -n services-observability"*)
    case "${STUB_LOKI:-}" in
      notfound) echo 'Error from server (NotFound): ciliumnetworkpolicies.cilium.io "loki" not found' >&2; exit 1 ;;
      error) echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1 ;;
    esac
    case "$*" in
      *"-o name") echo ciliumnetworkpolicy.cilium.io/loki ;;
      *"-o jsonpath={.spec.egress[*].toEntities[*]}") printf '%s' "${STUB_LOKI_ENT:-}" ;;
      *) echo "stub: unexpected query: $*" >&2; exit 1 ;;
    esac
    exit 0 ;;
  *"get helmrelease loki -n services-observability"*"-o name"*)
    case "${STUB_LOKI_HR:-absent}" in
      present) echo helmrelease.helm.toolkit.fluxcd.io/loki; exit 0 ;;
      *) echo 'Error from server (NotFound): helmreleases.helm.toolkit.fluxcd.io "loki" not found' >&2; exit 1 ;;
    esac ;;
  "get authorizationpolicies.security.istio.io -A -o jsonpath={range .items[*]}{.metadata.namespace}{\"/\"}{.metadata.name}{\"\\t\"}{.spec.rules[*].from[*].source.principals[*]}{\"\\n\"}{end}")
    [ "${STUB_AP:-}" = error ] && { echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1; }
    printf '%b' "${STUB_AP_LINES:-}"; exit 0 ;;
  "get secrets -A --show-managed-fields -o jsonpath={range .items[*]}{.metadata.namespace}{\"/\"}{.metadata.name}{\"\\t\"}{.metadata.managedFields}{\"\\n\"}{end}")
    [ "${STUB_SEC:-}" = error ] && { echo 'Error from server (Forbidden): secrets is forbidden' >&2; exit 1; }
    printf '%s' "${STUB_SEC_LINES:-}"; exit 0 ;;
  *"get helmrelease victoria-metrics-operator -n services-observability"*"-o name"*)
    case "${STUB_VMA_HR:-absent}" in
      present) echo helmrelease.helm.toolkit.fluxcd.io/victoria-metrics-operator; exit 0 ;;
      error) echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1 ;;
      *) echo 'Error from server (NotFound): helmreleases.helm.toolkit.fluxcd.io "victoria-metrics-operator" not found' >&2; exit 1 ;;
    esac ;;
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
  *"get namespace istio-system"*) [ "${STUB_MESH:-}" = absent ] && { echo 'Error from server (NotFound): namespaces "istio-system" not found' >&2; exit 1; }; [ "${STUB_MESH:-}" = error ] && { echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1; }; echo namespace/istio-system; exit 0 ;;
  *"get helmrelease istiod"*"-o name"*) [ "${STUB_MESH:-}" = absent ] && { echo 'error: the server doesn'"'"'t have a resource type "helmrelease"' >&2; exit 1; }; echo helmrelease/istiod; exit 0 ;;
  *"get gateways.gateway.networking.k8s.io"*) [ "${STUB_MESH:-}" = absent ] && { echo 'error: the server doesn'"'"'t have a resource type "gateways"' >&2; exit 1; }; exit 0 ;;
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

echo "=== 1.5 Loki egress has no world entity: asked of the CLUSTER ==="
STUB_LOKI_ENT='kube-apiserver cluster' run
verdict "1.5" "✅" && ok "a loki CNP without world passes" || bad "green case: $(line 1.5)"
STUB_LOKI_ENT='kube-apiserver world' run
verdict "1.5" "❌" && ok "toEntities: world on the cluster FAILS, whatever YAML style it was written in" || bad "world passed: $(line 1.5)"
STUB_LOKI_ENT='all' run
verdict "1.5" "❌" && ok "toEntities: all (world included) FAILS" || bad "all passed: $(line 1.5)"
STUB_LOKI=notfound run
verdict "1.5" "⏭" && ok "no loki CNP and no loki HelmRelease is a skip" || bad "absent: $(line 1.5)"
STUB_LOKI=notfound STUB_LOKI_HR=present run
verdict "1.5" "❌" && ok "no loki CNP on a cluster that runs Loki FAILS (egress unbounded)" || bad "CNP lost, Loki there: $(line 1.5)"
STUB_LOKI=error run
verdict "1.5" "❌" && ok "an API error is a FAIL, not a pass" || bad "API error: $(line 1.5)"

echo "=== 1.6 VMAgent egress is bounded to the cluster: asked of the CLUSTER ==="
STUB_VMA_ENT='kube-apiserver cluster host remote-node' run
verdict "1.6" "✅" && ok "a vmagent CNP with a toEntities: cluster rule passes" || bad "green case: $(line 1.6)"
STUB_VMA_ENT='kube-apiserver' run
verdict "1.6" "❌" && ok "no cluster entity (the scraping block gone) FAILS" || bad "no cluster entity passed: $(line 1.6)"
STUB_VMA_ENT='kube-apiserver world' run
verdict "1.6" "❌" && ok "world is not cluster: FAILS" || bad "world passed: $(line 1.6)"
STUB_VMA_ENT='' run
verdict "1.6" "❌" && ok "a CNP with no toEntities at all FAILS" || bad "empty passed: $(line 1.6)"
STUB_VMA=notfound run
verdict "1.6" "⏭" && ok "no vmagent CNP and no operator HelmRelease (two signals) is a skip, not a pass" || bad "NotFound: $(line 1.6)"
STUB_VMA=notfound STUB_VMA_HR=present run
verdict "1.6" "❌" && ok "no vmagent CNP on a cluster that runs the stack FAILS (one signal is no skip)" || bad "CNP lost, stack there: $(line 1.6)"
STUB_VMA=notfound STUB_VMA_HR=error run
verdict "1.6" "❌" && ok "no vmagent CNP and a HelmRelease that cannot be read FAILS (an error is not 'absent')" || bad "HR API error: $(line 1.6)"
STUB_VMA=error run
verdict "1.6" "❌" && ok "an API error is a FAIL, not a skip and not a pass" || bad "API error: $(line 1.6)"
# The file this check used to read (a sibling OpenAether-apps checkout, here a decoy next to a copy of the script) must not
# decide the verdict, whatever it says, however big it is: `grep -A60 … | grep -q …` under pipefail took SIGPIPE when the
# match came early and the file was long (a proof lab: test 1.6 red on a correct cluster, about 1 run in 100).
mkdir -p "$TMP/root/OpenAether-infra/scripts/ops" "$TMP/root/OpenAether-apps/apps/base/observability"
cp "$SUT" "$TMP/root/OpenAether-infra/scripts/ops/cluster-security-tests.sh"
DECOY="$TMP/root/OpenAether-apps/apps/base/observability/networkpolicy.yaml"
decoy_run() { SUT="$TMP/root/OpenAether-infra/scripts/ops/cluster-security-tests.sh" run; }
printf 'metadata:\n  name: vmagent\nspec:\n  egress:\n    - toEntities:\n        - cluster\n' >"$DECOY"
STUB_VMA_ENT='kube-apiserver' decoy_run
verdict "1.6" "❌" && ok "a file that says cluster does not rescue a cluster that does not" || bad "stale file decided: $(line 1.6)"
printf 'metadata:\n  name: vmagent\nspec:\n  egress:\n    - toEntities:\n        - kube-apiserver\n' >"$DECOY"
STUB_VMA_ENT='kube-apiserver cluster' decoy_run
verdict "1.6" "✅" && ok "a file that lacks cluster does not fail a cluster that has it" || bad "stale file decided: $(line 1.6)"
{ printf 'metadata:\n  name: vmagent\nspec:\n  egress:\n    - toEntities:\n        - cluster\n'; yes 'name: vmagent' | head -n 10000; } >"$DECOY"
STUB_VMA_ENT='kube-apiserver cluster' decoy_run
verdict "1.6" "✅" && ok "a long file, which made the old pipeline fail every time, changes nothing" || bad "long file: $(line 1.6)"
# 1.5, 2.4, 2.7 and 4.1 read the same sibling tree: a decoy that fails all four must not fail a clean cluster.
printf 'kind: CiliumNetworkPolicy\nmetadata:\n  name: loki\nspec:\n  egress:\n    - toEntities: [world]\n' >"$DECOY"
mkdir -p "$TMP/root/OpenAether-apps/apps/base/istio/authz"
printf 'metadata:\n  namespace: kyverno\nspec:\n  rules:\n    - from:\n        - source:\n            principals: ["openaether.local/ns/a/sa/b"]\n' \
  | tee "$TMP/root/OpenAether-apps/apps/base/istio/authz/authorizationpolicy-explicit-allows.yaml" >"$TMP/root/OpenAether-apps/apps/base/istio/authz/authorizationpolicy-default-deny.yaml"
printf 'kind: Secret\nmetadata:\n  name: plain\nstringData:\n  password: hunter2\n' >"$TMP/root/OpenAether-apps/apps/base/plain-secret.yaml"
STUB_LOKI_ENT='cluster' decoy_run
for n in 1.5 2.4 2.7 4.1; do verdict "$n" "✅" && ok "$n: the sibling checkout does not decide the verdict" || bad "$n read the file: $(line $n)"; done
grep -q "OpenAether-apps" <<<"$OUT" && bad "the output still names the sibling checkout" || ok "…and the output names no checkout"

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

echo "=== 2.4 / 2.7 Istio AuthorizationPolicies: asked of the CLUSTER ==="
STUB_AP_LINES='istio-system/default-deny-all\t\nservices-gateway/allow\tcluster.local/ns/a/sa/b\n' run
verdict "2.4" "✅" && ok "cluster.local principals pass 2.4" || bad "green 2.4: $(line 2.4)"
verdict "2.7" "✅" && ok "no policy in an out-of-mesh namespace passes 2.7" || bad "green 2.7: $(line 2.7)"
STUB_AP_LINES='services-gateway/allow\tcluster.local/ns/a/sa/b openaether.local/ns/c/sa/d\n' run
verdict "2.4" "❌" && grep -q 'services-gateway/allow' <<<"$OUT" && ok "an openaether.local principal FAILS 2.4 and names the policy" || bad "openaether.local: $(line 2.4)"
STUB_AP_LINES='kyverno/default-deny-all\t\n' run
verdict "2.7" "❌" && grep -q 'kyverno' <<<"$OUT" && ok "a policy in an out-of-mesh namespace FAILS 2.7 and names it" || bad "kyverno policy: $(line 2.7)"
STUB_AP=error run
verdict "2.4" "❌" && verdict "2.7" "❌" && ok "an API error is not read as an empty list: 2.4 and 2.7 FAIL" || bad "API error: $(line 2.4) / $(line 2.7)"
STUB_MESH=absent run
verdict "2.4" "⏭" && verdict "2.7" "⏭" && ok "no mesh: 2.4 and 2.7 are not applicable" || bad "no mesh: $(line 2.4) / $(line 2.7)"

echo "=== 4.1 no Secret data delivered from Git: asked of the CLUSTER ==="
mf() { printf '%s\t[{"fieldsV1":%s,"manager":"%s","operation":"%s"}]\n' "$1" "$2" "$3" "$4"; }
STUB_SEC_LINES="$(mf a/webhook '{"f:data":{}}' kustomize-controller Apply)
$(mf a/webhook-data '{"f:data":{"f:tls.crt":{}}}' external-secrets Update)
$(mf b/helm '{"f:data":{"f:release":{}}}' helm-controller Update)" run
verdict "4.1" "✅" && ok "data written by controllers, an empty data from Git: passes" || bad "green 4.1: $(line 4.1)"
STUB_SEC_LINES="$(mf a/ok '{"f:metadata":{}}' kustomize-controller Apply)
$(mf c/plain '{"f:data":{".":{},"f:password":{}}}' kustomize-controller Apply)" run
verdict "4.1" "❌" && grep -q 'c/plain' <<<"$OUT" && ok "a Secret whose data Flux applied from Git FAILS and is named" || bad "plain Secret: $(line 4.1)"
STUB_SEC_LINES="$(mf c/plain '{"f:stringData":{"f:password":{}}}' kustomize-controller Apply)" run
verdict "4.1" "❌" && ok "…and so does stringData" || bad "stringData: $(line 4.1)"
STUB_SEC_LINES="$(mf cnpg-system/plugin-barman-cloud-5kkd8f288d '{"f:data":{".":{},"f:SIDECAR_IMAGE":{}}}' kustomize-controller Apply)" run
verdict "4.1" "✅" && ok "the barman-cloud plugin's image-reference Secret is not a credential: passes" || bad "plugin Secret: $(line 4.1)"
STUB_SEC_LINES="$(mf cnpg-system/plugin-barman-cloud-5kkd8f288d '{"f:data":{".":{},"f:SIDECAR_IMAGE":{},"f:password":{}}}' kustomize-controller Apply)" run
verdict "4.1" "❌" && ok "…but any other key in it FAILS" || bad "plugin Secret with another key: $(line 4.1)"
STUB_SEC_LINES="$(mf other/plugin-barman-cloud-x '{"f:data":{"f:SIDECAR_IMAGE":{}}}' kustomize-controller Apply)" run
verdict "4.1" "❌" && ok "…and the same key in another namespace FAILS" || bad "other namespace: $(line 4.1)"
STUB_SEC=error run
verdict "4.1" "❌" && ok "an API error is not read as an empty list: 4.1 FAILS" || bad "API error: $(line 4.1)"

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

echo "=== 2.x mesh checks: not applicable only when the API says there is no mesh ==="
STUB_MESH=absent run
ok_all=1; for n in 2.1 2.2 2.3 2.5; do verdict "$n" "⏭️" || { ok_all=0; bad "$n not skipped without a mesh: $(line $n)"; }; done
[ "$ok_all" = 1 ] && ok "2.1, 2.2, 2.3 and 2.5 are skipped (not applicable) when istio-system and istiod do not exist"
STUB_MESH=present run
for n in 2.1 2.3; do verdict "$n" "❌" && ok "$n still FAILS on a cluster with a mesh and no policy" || bad "$n with a mesh: $(line $n)"; done
STUB_MESH=error run
for n in 2.1 2.3; do verdict "$n" "❌" && ok "$n is judged (fails) when the API cannot be asked: an error is not 'absent'" || bad "$n on API error: $(line $n)"; done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
