#!/usr/bin/env bash
# ==============================================================================
# cluster-netcheck.sh — does a DENIED flow actually get dropped?
#
# cluster-security-tests.sh proves the network policies EXIST; this sends traffic. It starts one throwaway,
# non-root, capability-less curl pod in a namespace of its own (no policy allows it anything) and tries:
#
#   control   https://kubernetes.default.svc          must ANSWER (allow-kube-api) — otherwise the probe
#                                                     itself is broken and every "blocked" below means nothing
#   targets   a Service of each platform namespace     must TIME OUT (ingress default-deny): curl exit 28
#
# "Connection refused" (7) is NOT a pass: the packet got through to a closed port, the policy did not drop it.
# A namespace or Service that does not exist is skipped. WRITES (a temporary namespace, deleted on exit).
#
# Usage:  cluster-netcheck.sh [--cilium]
#   --cilium   also run `cilium connectivity test` (needs the cilium CLI). OFF by default: it deploys its own
#              namespace into a cluster with a cluster-wide default-deny, and has not been run here.
# Env: KUBECONFIG; OA_NETCHECK_IMAGE (default below, pinned by digest); OA_NETCHECK_NAMESPACES to override the
#      targets (space-separated); OA_NETCHECK_TIMEOUT seconds per attempt (default 5).
# ==============================================================================
set -uo pipefail

NS="oa-netcheck"
IMAGE="${OA_NETCHECK_IMAGE:-docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
TARGET_NS="${OA_NETCHECK_NAMESPACES:-foundation-vault foundation-databases foundation-pki-management cert-manager longhorn-system kyverno}"
TMO="${OA_NETCHECK_TIMEOUT:-5}"
CILIUM=0; [ "${1:-}" = "--cilium" ] && CILIUM=1

PASS=0; FAIL=0; UNKNOWN=0; SKIPPED=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
unk()  { printf '  \033[33m?\033[0m %s\n' "$*"; UNKNOWN=$((UNKNOWN + 1)); }
skip() { printf '  ~ %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }

for t in kubectl jq; do command -v "$t" >/dev/null 2>&1 || { echo "✗ $t not found" >&2; exit 2; }; done
kubectl cluster-info >/dev/null 2>&1 || { echo "✗ cannot reach the cluster — check KUBECONFIG" >&2; exit 2; }

cleanup() { kubectl delete namespace "$NS" --wait=false --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "▶ Network behaviour (a denied flow must time out)"
kubectl apply -f - >/dev/null <<YAML || { echo "✗ could not create the probe namespace/pod" >&2; exit 2; }
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: ${NS}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
YAML
if ! kubectl -n "$NS" wait --for=condition=Ready pod/probe --timeout=120s >/dev/null 2>&1; then
  unk "the probe pod did not become Ready in 120s (image pull blocked, admission policy?): $(kubectl -n "$NS" get pod probe -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null)"
  printf '\n%s passed, %s failed, %s could not be checked\n' "$PASS" "$FAIL" "$UNKNOWN"; exit 1
fi

# curl exit code of one attempt; prints it. -k: only reachability matters, not the certificate.
attempt() { kubectl -n "$NS" exec probe -- curl -sk -o /dev/null --connect-timeout "$TMO" --max-time "$((TMO + 3))" "$1" >/dev/null 2>&1; echo $?; }

rc="$(attempt https://kubernetes.default.svc)"
if [ "$rc" = 0 ] || [ "$rc" = 22 ]; then
  ok "control: the probe reaches the API server (allow-kube-api works), so a timeout below is the policy"
else
  unk "control: the probe cannot reach https://kubernetes.default.svc (curl exit $rc) — the probe is broken, nothing below is meaningful"
  printf '\n%s passed, %s failed, %s could not be checked\n' "$PASS" "$FAIL" "$UNKNOWN"; exit 1
fi

for ns in $TARGET_NS; do
  # First Service of the namespace that has a ClusterIP and a port, and one of its ports.
  line="$(kubectl get svc -n "$ns" -o json 2>/dev/null |
          jq -r '[.items[] | select(.spec.clusterIP != "None" and (.spec.ports | length) > 0)][0] // empty
                 | "\(.metadata.name) \(.spec.clusterIP) \(.spec.ports[0].port)"' 2>/dev/null)"
  if [ -z "$line" ]; then skip "${ns}: no Service to aim at"; continue; fi
  read -r name ip port <<<"$line"
  rc="$(attempt "http://${ip}:${port}/")"
  case "$rc" in
    28) ok "${ns}/${name}:${port}: timed out from an unlisted namespace (dropped)" ;;
    7)  unk "${ns}/${name}:${port}: connection REFUSED — the packet arrived at a closed port; the policy did not drop it, or nothing listens" ;;
    *)  bad "${ns}/${name}:${port}: answered (curl exit ${rc}) from a namespace no policy allows — the default-deny does not hold here" ;;
  esac
done

if [ "$CILIUM" = 1 ]; then
  if command -v cilium >/dev/null 2>&1; then
    echo "▶ cilium connectivity test"
    if cilium connectivity test; then ok "cilium connectivity test"; else bad "cilium connectivity test failed"; fi
  else
    unk "--cilium asked for, the cilium CLI is not installed"
  fi
fi

printf '\n%s passed, %s failed, %s could not be checked, %s skipped\n' "$PASS" "$FAIL" "$UNKNOWN" "$SKIPPED"
[ "$FAIL" -eq 0 ] && [ "$UNKNOWN" -eq 0 ] && [ "$PASS" -gt 1 ]
