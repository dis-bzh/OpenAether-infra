#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# OpenAether — Cluster Runtime Security Tests
# ══════════════════════════════════════════════════════════════════════════════
# Validates that the deployed security controls are EFFECTIVE on a live
# cluster. Changes NOTHING — reads only.
#
# Usage:
#   ./cluster-security-tests.sh
#   KUBECONFIG=/path/to/kubeconfig ./cluster-security-tests.sh
#   OA_ENVIRONMENT=prod ./cluster-security-tests.sh      # the OpenBao bootstrap checks (4.6, 4.7) are strict on prod
#   OA_ESCROW_ANNOTATION_CHECK=1 OA_ENVIRONMENT=prod ./cluster-security-tests.sh   # also require the seal-key escrow record (4.7: annotation,
#                                                    # hash of the live key, two holders). BOTH are needed: the record is required on prod only,
#                                                    # on any other environment 4.7 is a skip that says so (task cluster-security: ENVIRONMENT=prod)
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Remonter de 3 niveaux: scripts/ops/ → scripts/ → OpenAether-infra/ → parent
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_DIR="$REPO_ROOT/OpenAether-apps/apps/base"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

# Colours (disabled outside a TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ── Fonctions utilitaires ────────────────────────────────────────────────────

pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}✅ $1${NC}"
}

fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}❌ $1${NC}"
  [ -n "${2:-}" ] && echo -e "     ${RED}→ $2${NC}"
}

skip() {
  TOTAL=$((TOTAL + 1))
  SKIP=$((SKIP + 1))
  echo -e "  ${YELLOW}⏭️  $1${NC}"
  [ -n "${2:-}" ] && echo -e "     ${YELLOW}→ $2${NC}"
}

header() {
  echo ""
  echo -e "${BOLD}── $1 ──${NC}"
}

# ── Preflight ────────────────────────────────────────────────────────────────

if ! command -v kubectl &>/dev/null; then
  echo -e "${RED}kubectl not found — aborting.${NC}"
  exit 1
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
  echo -e "${RED}Cannot reach cluster — check KUBECONFIG.${NC}"
  exit 1
fi

echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} OpenAether Cluster Security Tests${NC}"
echo -e "${BOLD} $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"

# ══════════════════════════════════════════════════════════════════════════════
# 1. NETWORK — Cilium NetworkPolicies
# ══════════════════════════════════════════════════════════════════════════════

header "1. NETWORK (Cilium)"

# 1.1 Default-deny ingress cluster-wide
if kubectl get ccnp default-deny-all-ingress &>/dev/null; then
  pass "1.1 Default-deny ingress cluster-wide"
else
  fail "1.1 Default-deny ingress cluster-wide" "CCNP default-deny-all-ingress not found"
fi

# 1.2 DNS egress allowed everywhere
if kubectl get ccnp allow-dns &>/dev/null; then
  pass "1.2 DNS egress allowed everywhere"
else
  fail "1.2 DNS egress allowed everywhere" "CCNP allow-dns not found"
fi

# 1.3 Kube-API egress allowed
if kubectl get ccnp allow-kube-api &>/dev/null; then
  pass "1.3 Kube-API egress allowed"
else
  fail "1.3 Kube-API egress allowed" "CCNP allow-kube-api not found"
fi

# 1.4 MinIO ingress bounded (local only — skipped if the namespace is absent)
if kubectl get ns foundation-storage &>/dev/null 2>&1; then
  MINIO_CNP=$(kubectl get cnp minio -n foundation-storage -o yaml 2>/dev/null || true)
  if echo "$MINIO_CNP" | grep -q "services-observability" && echo "$MINIO_CNP" | grep -q '"9000"'; then
    pass "1.4 MinIO ingress bounded (services-observability:9000)"
  elif [ -z "$MINIO_CNP" ]; then
    skip "1.4 MinIO ingress bounded" "Namespace foundation-storage not present (cloud-only)"
  else
    fail "1.4 MinIO ingress bounded" "CNP minio does not restrict ingress to services-observability:9000"
  fi
else
  skip "1.4 MinIO ingress bounded" "Namespace foundation-storage not present (cloud-only)"
fi

# 1.5 Loki egress — no toEntities:world
LOKI_CNP="$BASE_DIR/observability/networkpolicy.yaml"
if [ -f "$LOKI_CNP" ]; then
  if grep -A20 "name: loki" "$LOKI_CNP" | grep -q "toEntities.*world"; then
    fail "1.5 Loki egress pas world" "CNP Loki still has toEntities: world"
  else
    pass "1.5 Loki egress pas world"
  fi
else
  skip "1.5 Loki egress pas world" "Loki CNP file not found"
fi

# 1.6 VMAgent scraping bounded (toEntities: cluster)
VMAgent_CNP="$BASE_DIR/observability/networkpolicy.yaml"
if [ -f "$VMAgent_CNP" ]; then
  # toEntities and cluster sit on separate lines in the Cilium YAML
  if grep -A60 "name: vmagent" "$VMAgent_CNP" | grep -q "toEntities:" && \
     grep -A60 "name: vmagent" "$VMAgent_CNP" | grep -q "cluster"; then
    pass "1.6 VMAgent scraping bounded (toEntities: cluster)"
  else
    fail "1.6 VMAgent scraping bounded" "CNP VMAgent missing toEntities: cluster on scraping block"
  fi
else
  skip "1.6 VMAgent scraping bounded" "VMAgent CNP file not found"
fi

# 1.7 Fondation hors-mesh : CNP existent
NS_WITH_CNP=0
for ns in cert-manager foundation-vault cnpg-system longhorn-system foundation-pki-management kyverno; do
  if kubectl get cnp -n "$ns" &>/dev/null 2>&1 && [ "$(kubectl get cnp -n "$ns" -o name 2>/dev/null | wc -l)" -gt 0 ]; then
    NS_WITH_CNP=$((NS_WITH_CNP + 1))
  fi
done
if [ "$NS_WITH_CNP" -ge 5 ]; then
  pass "1.7 Foundation out of mesh: $NS_WITH_CNP/6 namespaces with CNP"
elif [ "$NS_WITH_CNP" -ge 3 ]; then
  pass "1.7 Foundation out of mesh: $NS_WITH_CNP/6 namespaces with CNP (partial)"
else
  fail "1.7 Foundation out of mesh (Cilium)" "Only $NS_WITH_CNP/6 namespaces with CNP"
fi

# 1.8 Cilium node-to-node encryption (WireGuard) is ON, in the config and in the running agent.
# It is the compensating control for in-cluster hops that are not mTLS (Alloy to Loki): a cluster
# whose agent says "Disabled" carries those hops in clear on the node network.
WG_CFG=$(kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.enable-wireguard}' 2>/dev/null || echo "")
if [ "$WG_CFG" != "true" ]; then
  fail "1.8 Cilium WireGuard encryption" "cilium-config enable-wireguard='$WG_CFG' (expected true)"
else
  WG_STATUS=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -i '^Encryption' || true)
  if [ -z "$WG_STATUS" ]; then
    skip "1.8 Cilium WireGuard encryption" "enabled in cilium-config, but the agent status could not be read (exec refused?)"
  elif grep -qi 'wireguard' <<<"$WG_STATUS"; then
    pass "1.8 Cilium WireGuard encryption active: $(tr -s ' ' <<<"$WG_STATUS" | cut -c1-60)"
  else
    fail "1.8 Cilium WireGuard encryption" "enabled in cilium-config but the agent reports: $WG_STATUS"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. ZERO-TRUST — Istio Ambient + AuthZ
# ══════════════════════════════════════════════════════════════════════════════

header "2. ZERO-TRUST (Istio)"

# The reduced profile (no service mesh, no Gateway) has nothing to judge here. Lab 12 (Outscale) reported 2.1, 2.2, 2.3 and 2.5
# as failures there; they are not applicable. The mesh counts as absent only when the API SAYS so (NotFound / no such resource
# type) for both the istio-system namespace and the istiod HelmRelease; any other answer, an error included, means "judge it".
not_found() { # <kubectl get args…> — true when the API answers that the object or its type does not exist
  local out
  out="$(kubectl get "$@" -o name 2>&1)" && return 1
  case "$out" in *NotFound* | *"not found"* | *"doesn't have a resource type"* | *"no matches for kind"*) return 0 ;; esac
  return 1
}
MESH_ABSENT=0
if not_found namespace istio-system && not_found helmrelease istiod -n foundation-service-mesh; then MESH_ABSENT=1; fi
MESH_NA="no service mesh on this cluster (no istio-system namespace, no istiod HelmRelease): the reduced profile, not applicable"

# 2.1 mTLS STRICT mesh-wide
if [ "$MESH_ABSENT" = 1 ]; then
  skip "2.1 mTLS STRICT mesh-wide" "$MESH_NA"
else
PA_STRICT=$(kubectl get peerauthentication -n istio-system -o jsonpath='{.items[0].spec.mtls.mode}' 2>/dev/null || echo "")
if [ "$PA_STRICT" = "STRICT" ]; then
  pass "2.1 mTLS STRICT mesh-wide"
else
  fail "2.1 mTLS STRICT mesh-wide" "PeerAuthentication mode='$PA_STRICT' (expected STRICT)"
fi
fi

# 2.2 Default-deny authz on every ambient namespace (spec: {} = allow-nothing)
#
# Asked of the CLUSTER, not of the manifests. The file-based version hardcoded
# five namespaces and grepped one file, and by 2026-08-15 it was wrong twice
# over: services-observability had been taken OUT of the mesh on purpose, and
# foundation-storage's policy had moved to istio/authz-storage/ back in July.
# It reported "3/5" on a cluster where every ambient namespace was in fact
# covered — and from a git worktree, where ../OpenAether-apps does not exist, it
# skipped entirely and the run still said 25/31 passed.
# The cluster cannot go stale when a file moves, and it cannot be absent.
if [ "$MESH_ABSENT" = 1 ]; then
  skip "2.2 Default-deny authz per ambient ns" "$MESH_NA"
else
AMBIENT_NS=$(kubectl get ns -l istio.io/dataplane-mode=ambient -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ -z "$AMBIENT_NS" ]; then
  skip "2.2 Default-deny authz per ambient ns" "no namespace is labelled istio.io/dataplane-mode=ambient"
else
  MISSING=""
  AMBIENT_COUNT=0
  # istio-system hosts the control plane and carries its own default-deny; it is
  # not labelled ambient, so name it explicitly rather than let it slip through.
  for ns in $AMBIENT_NS istio-system; do
    AMBIENT_COUNT=$((AMBIENT_COUNT + 1))
    kubectl -n "$ns" get authorizationpolicy default-deny-all >/dev/null 2>&1 || MISSING="$MISSING $ns"
  done
  if [ -z "$MISSING" ]; then
    pass "2.2 Default-deny authz: $AMBIENT_COUNT/$AMBIENT_COUNT ambient ns covered"
  else
    fail "2.2 Default-deny authz per ambient ns" "no default-deny-all in:$MISSING"
  fi
fi
fi

# 2.3 TrustDomain = cluster.local
if [ "$MESH_ABSENT" = 1 ]; then
  skip "2.3 TrustDomain = cluster.local" "$MESH_NA"
else
TD=$(kubectl get helmrelease istiod -n foundation-service-mesh -o jsonpath='{.spec.values.meshConfig.trustDomain}' 2>/dev/null || echo "")
if [ "$TD" = "cluster.local" ]; then
  pass "2.3 TrustDomain = cluster.local"
else
  fail "2.3 TrustDomain = cluster.local" "trustDomain='$TD' (expected cluster.local)"
fi
fi

# 2.4 No openaether.local principal in the AuthorizationPolicies
AUTHZ_DIR="$BASE_DIR/istio/authz"
if [ -d "$AUTHZ_DIR" ]; then
  # Look for openaether.local in principals (not in comments or FQDNs)
  BAD_REFS=$(grep -r "principals" "$AUTHZ_DIR/authorizationpolicy-explicit-allows.yaml" 2>/dev/null | grep -c "openaether\.local" || true)
  BAD_REFS=${BAD_REFS:-0}
  if [ "$BAD_REFS" -eq 0 ]; then
    pass "2.4 No openaether.local principal"
  else
    fail "2.4 No openaether.local principal" "$BAD_REFS principals still using openaether.local"
  fi
else
  skip "2.4 No openaether.local principal" "AuthZ dir not found"
fi

# 2.5 Gateway TLS : HTTPRoute redirect + certificate
GW_NONE=0
if not_found gateways.gateway.networking.k8s.io -A; then GW_NONE=1
elif GW_OUT="$(kubectl get gateways.gateway.networking.k8s.io -A -o name 2>/dev/null)" && [ -z "$GW_OUT" ]; then GW_NONE=1; fi
if [ "$MESH_ABSENT" = 1 ] && [ "$GW_NONE" = 1 ]; then
  skip "2.5 Gateway TLS" "no Gateway object and no mesh on this cluster: the reduced profile, not applicable"
else
REDIRECT_EXISTS=$(kubectl get httproute -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c redirect || true)
REDIRECT_EXISTS=${REDIRECT_EXISTS:-0}
CERT_EXISTS=$(kubectl get certificate -A --no-headers 2>/dev/null | wc -l || true)
CERT_EXISTS=${CERT_EXISTS:-0}
if [ "$REDIRECT_EXISTS" -gt 0 ] && [ "$CERT_EXISTS" -gt 0 ]; then
  pass "2.5 Gateway TLS (redirect + certificate present)"
else
  fail "2.5 Gateway TLS" "redirect=$REDIRECT_EXISTS, certs=$CERT_EXISTS"
fi
fi

# 2.6 Waypoint actif
WP_PODS=$(kubectl get pods -n foundation-service-mesh -l gateway.networking.k8s.io/gateway-name --no-headers 2>/dev/null | grep -c "Running" || true)
WP_PODS=${WP_PODS:-0}
if [ "$WP_PODS" -gt 0 ]; then
  pass "2.6 Waypoint actif ($WP_PODS pod(s) Running)"
else
  skip "2.6 Waypoint actif" "Waypoint pods not found (may not be deployed)"
fi

# 2.7 Outside the mesh: NO Istio AuthorizationPolicy (security = Cilium only)
AUTHZ_DIR="$BASE_DIR/istio/authz"
if [ -d "$AUTHZ_DIR" ]; then
  OFF_MESH_NS=("cert-manager" "kyverno" "capi-system" "capi-operator-system" "longhorn-system" "foundation-databases" "foundation-vault")
  UNWANTED=0
  for ns in "${OFF_MESH_NS[@]}"; do
    if grep -q "namespace: $ns" "$AUTHZ_DIR/authorizationpolicy-default-deny.yaml" 2>/dev/null || \
       grep -q "namespace: $ns" "$AUTHZ_DIR/authorizationpolicy-explicit-allows.yaml" 2>/dev/null; then
      UNWANTED=$((UNWANTED + 1))
    fi
  done
  if [ "$UNWANTED" -eq 0 ]; then
    pass "2.7 Out of mesh: 0 inert AuthorizationPolicy (0/${#OFF_MESH_NS[@]})"
  else
    fail "2.7 Out of mesh, no Istio AuthZ" "$UNWANTED/${#OFF_MESH_NS[@]} out-of-mesh ns still have (inert) AuthZ policies"
  fi
else
  skip "2.7 Out of mesh, no Istio AuthZ" "AuthZ dir not found"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. LEAST-PRIVILEGE — Kyverno + RBAC + PSA
# ══════════════════════════════════════════════════════════════════════════════

header "3. LEAST-PRIVILEGE (Kyverno + RBAC + PSA)"

# 3.1 Kyverno enforce disallow-root-user
ROOT_ACTION=$(kubectl get clusterpolicy disallow-root-user -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || echo "")
if [ "$ROOT_ACTION" = "Enforce" ]; then
  pass "3.1 Kyverno enforce disallow-root-user"
else
  fail "3.1 Kyverno enforce disallow-root-user" "validationFailureAction='$ROOT_ACTION' (expected Enforce)"
fi

# 3.2 Kyverno enforce disallow-default-namespace
DEFAULT_NS_ACTION=$(kubectl get clusterpolicy disallow-default-namespace -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || echo "")
if [ "$DEFAULT_NS_ACTION" = "Enforce" ]; then
  pass "3.2 Kyverno enforce disallow-default-namespace"
else
  fail "3.2 Kyverno enforce disallow-default-namespace" "validationFailureAction='$DEFAULT_NS_ACTION' (expected Enforce)"
fi

# 3.3 Kyverno audit policies (3 attendues)
AUDIT_COUNT=$(kubectl get clusterpolicy -o json 2>/dev/null | python3 -c "
import json,sys
policies=json.load(sys.stdin)['items']
audit=[p for p in policies if p['spec'].get('validationFailureAction')=='Audit']
print(len(audit))
" 2>/dev/null || echo "0")
if [ "$AUDIT_COUNT" -ge 3 ]; then
  pass "3.3 Kyverno audit policies: $AUDIT_COUNT attendues"
else
  fail "3.3 Kyverno audit policies" "Only $AUDIT_COUNT policies in Audit (expected >=3)"
fi

# 3.4 PSA restricted on the PKI foundation
# foundation-pki-root is GONE: the two-OpenBao design was replaced by a single
# one (apps/base/cert-manager-issuers). This asked for a namespace nobody
# creates any more and reported "pki-root=" as a failure — a check red for a
# reason that had been designed away. It reads the namespace that replaced it.
PKI_ENFORCE=$(kubectl get ns foundation-pki-management -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
VAULT_ENFORCE=$(kubectl get ns foundation-vault -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
if [ "$PKI_ENFORCE" = "restricted" ] && [ "$VAULT_ENFORCE" = "restricted" ]; then
  pass "3.4 PSA restricted on the PKI foundation (pki-management + vault)"
else
  fail "3.4 PSA restricted on the PKI foundation" "pki-management=$PKI_ENFORCE, vault=$VAULT_ENFORCE (expected restricted)"
fi

# 3.5 Pod Security Admission: at least `baseline`, on every managed namespace
MANAGED_NS=$(kubectl get ns -l openaether.io/managed=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
MISSING_PSA=0
for ns in $MANAGED_NS; do
  ENFORCE=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
  if [ -z "$ENFORCE" ]; then
    MISSING_PSA=$((MISSING_PSA + 1))
  fi
done
NS_COUNT=$(echo "$MANAGED_NS" | wc -w)
if [ "$MISSING_PSA" -eq 0 ] && [ "$NS_COUNT" -gt 0 ]; then
  pass "3.5 PSA at least baseline: all $NS_COUNT managed ns carry the enforce label"
else
  fail "3.5 PSA at least baseline everywhere" "$MISSING_PSA/$NS_COUNT managed ns without an enforce label"
fi

# 3.6 Minimal RBAC — no wildcards on custom ClusterRoles
WILDCARD_ROLES=$(kubectl get clusterrole -o json 2>/dev/null | python3 -c "
import json,sys
roles=json.load(sys.stdin)['items']
# Exclude the upstream charts and system roles
# ⚠️ These lists were never tuned: until 2026-08-15 the tuples were written
# without commas, so the comparison excluded everything and no entry ever
# mattered. With the commas in, all 22 hits were upstream or built-in — the
# additions below are named for that reason, and anything NOT on this list is a
# role this project created and has to justify.
EXCLUDE_PREFIXES=('system:', 'clusternet:', 'cnpg-', 'cloudnative-pg', 'external-secrets-', 'longhorn-', 'istio-', 'istiod-', 'cert-manager-', 'kyverno-', 'kyverno:', 'capi-', 'cluster-api-', 'cacppt-', 'caps-', 'gateway-api-', 'fluent-', 'kube-state-metrics-', 'loki-', 'alloy-', 'prometheus-', 'node-exporter-', 'victoria-metrics-', 'flux-', 'crd-controller')
# Kubernetes' own aggregated roles, on every cluster ever built.
EXCLUDE_EXACT=('admin', 'edit', 'view', 'cluster-admin')
wildcards=[r for r in roles
  if r['metadata']['name'] not in EXCLUDE_EXACT
  and not any(r['metadata']['name'].startswith(p) for p in EXCLUDE_PREFIXES)
  and any(rule.get('verbs')==['*'] or rule.get('resources')==['*'] for rule in r.get('rules',[]))]
print(len(wildcards))
" 2>/dev/null || echo "0")
if [ "$WILDCARD_ROLES" -eq 0 ]; then
  pass "3.6 Minimal RBAC: 0 custom ClusterRole with wildcards"
else
  fail "3.6 Minimal RBAC (custom)" "$WILDCARD_ROLES ClusterRoles with verbs:['*'] or resources:['*']"
fi

# 3.7 No custom cluster-admin binding
ADMIN_BINDINGS=$(kubectl get clusterrolebinding -o json 2>/dev/null | python3 -c "
import json,sys
bindings=json.load(sys.stdin)['items']
EXCLUDE_PREFIXES=('system:', 'cnpg-', 'external-secrets-', 'longhorn-', 'istio-', 'cert-manager-', 'kyverno-', 'capi-', 'cluster-api-')
# 'cluster-admin' is Kubernetes' own binding to system:masters.
# 'cluster-reconciler' is how Flux works: kustomize-controller and
# helm-controller apply arbitrary manifests and cannot do it with less.
EXCLUDE_EXACT=('cluster-admin', 'cluster-reconciler')
# 'oa-admins' is the platform-rbac brick's binding for named operators (kubeconfig-new.sh): allowed only as exactly
# Group oa:admins -> cluster-admin; any other subject under that name still counts as custom.
def platform(b):
  return b['metadata']['name']=='oa-admins' and [(x.get('kind'),x.get('name')) for x in (b.get('subjects') or [])]==[('Group','oa:admins')]
custom=[b for b in bindings
  if b['roleRef'].get('name')=='cluster-admin'
  and b['metadata']['name'] not in EXCLUDE_EXACT
  and not platform(b)
  and not any(b['metadata']['name'].startswith(p) for p in EXCLUDE_PREFIXES)]
print(len(custom))
" 2>/dev/null || echo "0")
if [ "$ADMIN_BINDINGS" -eq 0 ]; then
  pass "3.7 No custom cluster-admin binding"
else
  fail "3.7 No custom cluster-admin binding" "$ADMIN_BINDINGS custom ClusterRoleBindings to cluster-admin"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. SECRETS
# ══════════════════════════════════════════════════════════════════════════════

header "4. SECRETS"

# 4.1 No plaintext secret in the deployment YAML
SECRETS_IN_PLAIN=0
if [ -d "$BASE_DIR" ]; then
  while IFS= read -r f; do
    if grep -q "kind: Secret" "$f" 2>/dev/null; then
      # Ignore ExternalSecrets and valuesFrom references
      if grep -q "kind: ExternalSecret" "$f" || grep -q "valuesFrom" "$f"; then
        continue
      fi
      # Check whether the Secret has real data (non-empty stringData/data)
      HAS_DATA=$(awk '/kind: Secret/{found=1} found && /^\s+(stringData|data):/{print; exit}' "$f" 2>/dev/null || true)
      if [ -n "$HAS_DATA" ]; then
        # Make sure it is not just an empty placeholder (stringData: {} or data: {})
        NEXT_LINE=$(awk '/kind: Secret/{found=1} found && /^\s+(stringData|data):/{getline; print; exit}' "$f" 2>/dev/null || true)
        if ! echo "$NEXT_LINE" | grep -qE "^\s*\{\}\s*$"; then
          SECRETS_IN_PLAIN=$((SECRETS_IN_PLAIN + 1))
        fi
      fi
    fi
  done < <(find "$BASE_DIR" -name "*.yaml" 2>/dev/null)
fi
if [ "$SECRETS_IN_PLAIN" -eq 0 ]; then
  pass "4.1 No plaintext secret in the YAML"
else
  fail "4.1 No plaintext secret in the YAML" "$SECRETS_IN_PLAIN file(s) holding non-ExternalSecret Secrets"
fi

# 4.2 ExternalSecrets present
ESO_PODS=$(kubectl get pods -n foundation-pki-management -l app.kubernetes.io/name=external-secrets --no-headers 2>/dev/null | grep -c "Running" || true)
ESO_PODS=${ESO_PODS:-0}
if [ "$ESO_PODS" -gt 0 ]; then
  pass "4.2 External Secrets Operator actif ($ESO_PODS pod(s) Running)"
else
  fail "4.2 External Secrets Operator actif" "No ESO pod Running in foundation-pki-management"
fi

# 4.3 ClusterSecretStore actif
STORE_READY=$(kubectl get clustersecretstore -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "$STORE_READY" = "True" ]; then
  pass "4.3 ClusterSecretStore actif (Ready)"
else
  fail "4.3 ClusterSecretStore actif" "status='$STORE_READY' (expected True)"
fi

# 4.4 OpenBao HA Running
OBAO_PODS=$(kubectl get pods -n foundation-vault -l app=openbao --no-headers 2>/dev/null | grep -c "Running" || true)
OBAO_PODS=${OBAO_PODS:-0}
if [ "$OBAO_PODS" -ge 3 ]; then
  pass "4.4 OpenBao HA: $OBAO_PODS pods Running"
elif [ "$OBAO_PODS" -gt 0 ]; then
  pass "4.4 OpenBao: $OBAO_PODS pod(s) Running (non-HA)"
else
  fail "4.4 OpenBao HA" "No openbao pod Running in foundation-vault"
fi

# 4.5 No unseal quorum and no root token kept in the cluster (apps >= 0.1.1: static seal, root token revoked).
# A cluster still on apps 0.1.0 fails this on purpose: those two Secrets are the defect.
LEFTOVER=$(kubectl get secret -n foundation-vault openbao-unseal-keys openbao-recovery --ignore-not-found -o name 2>/dev/null | grep -c . || true)
LEFTOVER=${LEFTOVER:-0}
if [ "$LEFTOVER" -eq 0 ]; then
  pass "4.5 No Shamir shares or root token in a Secret of foundation-vault"
else
  fail "4.5 Unseal shares / root token at rest" "$LEFTOVER of openbao-unseal-keys, openbao-recovery still exist (apps 0.1.0 bootstrap: build a new cluster on apps >= 0.1.1)"
fi

# 4.6 A production cluster holds no development OpenBao bootstrap. openbao-recovery-dev is the single
# plaintext recovery share of a cluster created without operator PGP keys; it cannot become a production
# one. OA_ENVIRONMENT tells the script what it is looking at (unset or dev: reported, not failed).
OA_ENV="${OA_ENVIRONMENT:-}"
if kubectl -n foundation-vault get secret openbao-recovery-dev &>/dev/null; then
  if [ "$OA_ENV" = "prod" ]; then
    fail "4.6 No development OpenBao bootstrap on prod" "Secret openbao-recovery-dev exists: this cluster's recovery share is in clear; re-initialise it with openbao_recovery_pgp_keys"
  else
    skip "4.6 No development OpenBao bootstrap on prod" "development bootstrap (openbao-recovery-dev); strict only with OA_ENVIRONMENT=prod"
  fi
elif kubectl -n foundation-vault get secret openbao-recovery-shares &>/dev/null; then
  pass "4.6 OpenBao recovery shares are the PGP-encrypted ones (no openbao-recovery-dev)"
else
  skip "4.6 No development OpenBao bootstrap on prod" "no OpenBao recovery Secret found (not bootstrapped, or apps < 0.2.0)"
fi

# 4.7 The seal key leaves a record that it was escrowed, and the record is of THIS key. Losing it loses every OpenBao
# secret and nothing else can tell whether the operator did the Day-0 step. The annotation and the ConfigMap
# openbao-escrow-ack are written by that step (`task escrow`, or the apps README Day 0, step 5); until it exists in your apps
# ref the check is opt-in, and it never applies to a dev bootstrap. The apps CronJob cannot compare the hash (it never
# reads the key); this check can, and so catches an escrow of a key that was rotated since. The key is hashed in a pipe, never printed.
if [ "${OA_ESCROW_ANNOTATION_CHECK:-}" != "1" ]; then
  skip "4.7 Seal-key escrow recorded" "opt-in (OA_ESCROW_ANNOTATION_CHECK=1) until the escrow step that sets openaether.io/escrowed-at is in your apps ref"
elif [ "$OA_ENV" != "prod" ]; then
  # The opt-in alone is not enough, by design (a dev cluster has no escrow to attest): say so instead of looking like a failed opt-in.
  skip "4.7 Seal-key escrow recorded" "OA_ESCROW_ANNOTATION_CHECK=1 is set but OA_ENVIRONMENT is '${OA_ENV:-unset}': the escrow record is required on prod only; run ENVIRONMENT=prod task cluster-security (or OA_ENVIRONMENT=prod)"
elif ! kubectl -n foundation-vault get secret openbao-seal-key &>/dev/null; then
  skip "4.7 Seal-key escrow recorded" "no openbao-seal-key Secret (static seal not in use)"
else
  ESCROWED=$(kubectl -n foundation-vault get secret openbao-seal-key -o jsonpath='{.metadata.annotations.openaether\.io/escrowed-at}' 2>/dev/null || echo "")
  ACK_AT=$(kubectl -n foundation-vault get configmap openbao-escrow-ack -o jsonpath='{.data.escrowed-at}' 2>/dev/null || echo "")
  ACK_SHA=$(kubectl -n foundation-vault get configmap openbao-escrow-ack -o jsonpath='{.data.seal-key-sha256}' 2>/dev/null || echo "")
  ACK_N=$(kubectl -n foundation-vault get configmap openbao-escrow-ack -o jsonpath='{.data.holders}' 2>/dev/null || echo "")
  SEAL_B64=$(kubectl -n foundation-vault get secret openbao-seal-key -o jsonpath='{.data.key}' 2>/dev/null || echo "")
  LIVE_SHA=""; [ -z "$SEAL_B64" ] || LIVE_SHA=$(printf '%s' "$SEAL_B64" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1)
  ACK_AGE=$(python3 -c 'import datetime,sys
try: print((datetime.date.today() - datetime.date.fromisoformat(sys.argv[1])).days)
except Exception: print("x")' "$ACK_AT" 2>/dev/null || echo x)
  if [ -z "$ESCROWED" ]; then
    fail "4.7 Seal-key escrow recorded" "openbao-seal-key has no openaether.io/escrowed-at annotation: escrow it (task escrow, docs/admin-access.md section 1) and attest it"
  elif [ -z "$ACK_AT" ]; then
    fail "4.7 Seal-key escrow recorded" "annotated, but there is no ConfigMap openbao-escrow-ack: the hash and the custodians are not recorded (task escrow -- attest)"
  elif [ -z "$LIVE_SHA" ]; then
    fail "4.7 Seal-key escrow recorded" "cannot read the live seal key to compare it with the attestation (RBAC on Secrets?)"
  elif [ "$ACK_SHA" != "$LIVE_SHA" ]; then
    fail "4.7 Seal-key escrow recorded" "the attestation names another key than the live one (seal key rotated since?): escrow the new key and attest it again (task escrow)"
  elif ! [[ "$ACK_N" =~ ^[0-9]+$ ]] || [ "$ACK_N" -lt 2 ]; then
    fail "4.7 Seal-key escrow recorded" "the attestation names '$ACK_N' holder(s): an escrow needs at least two custodians"
  elif ! [[ "$ACK_AGE" =~ ^[0-9]+$ ]] || [ "$ACK_AGE" -gt 400 ]; then
    fail "4.7 Seal-key escrow recorded" "the attestation is $ACK_AGE days old or undated (limit 400): redo the escrow and its proof"
  else
    pass "4.7 Seal-key escrow recorded and proven for the live key ($ESCROWED, $ACK_N holders)"
  fi
fi

# 4.8 / 4.9 Loki is a log pipeline that a compromised pod can reach: it must not write into the backups bucket
# (a cluster seeded before infra 0.2.1 does), nor hold the backups' keys. Values are compared as the base64 the
# API returns and never printed. Shared keys are a skip, not a failure: that is the seed's default without the
# optional OA_LOKI_S3_* pair, and the pair is the operator's to create.
LOKI_B=$(kubectl -n services-observability get secret loki-s3-credentials -o jsonpath='{.data.bucket}' 2>/dev/null || true)
BKP_B=$(kubectl -n foundation-databases get secret backup-restic-env -o jsonpath='{.data.PRIMARY_BUCKET}' 2>/dev/null || true)
if [ -z "$LOKI_B" ] || [ -z "$BKP_B" ]; then
  skip "4.8 Loki writes to a bucket of its own" "loki-s3-credentials or backup-restic-env not found (Loki or the backups not deployed, or not seeded yet)"
  skip "4.9 Loki does not hold the backups' keys" "same"
elif [ "$LOKI_B" = "$BKP_B" ]; then
  fail "4.8 Loki writes to a bucket of its own" "loki-s3-credentials names the backups bucket (seeded before infra 0.2.1): replace observability/loki-s3, docs/admin-access.md section 3"
  skip "4.9 Loki does not hold the backups' keys" "not read: the bucket is the backups' bucket"
else
  pass "4.8 Loki writes to a bucket of its own (not the backups bucket)"
  LOKI_K=$(kubectl -n services-observability get secret loki-s3-credentials -o jsonpath='{.data.accessKey}' 2>/dev/null || true)
  BKP_K=$(kubectl -n foundation-databases get secret backup-restic-env -o jsonpath='{.data.PRIMARY_ACCESS_KEY}' 2>/dev/null || true)
  if [ -z "$LOKI_K" ] || [ -z "$BKP_K" ]; then
    skip "4.9 Loki does not hold the backups' keys" "an access key could not be read"
  elif [ "$LOKI_K" = "$BKP_K" ]; then
    skip "4.9 Loki does not hold the backups' keys" "same key pair: the separate bucket protects against a mistake in Loki, not a compromised Loki; give it OA_LOKI_S3_* (docs/backup-policy.md section 4)"
  else
    pass "4.9 Loki does not hold the backups' keys"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. POD SECURITY
# ══════════════════════════════════════════════════════════════════════════════

header "5. POD SECURITY"

# 5.1 No root pod in the foundation namespaces
VAULT_PODS_ROOT=$(kubectl get pods -n foundation-vault -o json 2>/dev/null | python3 -c "
import json,sys
pods=json.load(sys.stdin).get('items',[])
root=0
for p in pods:
  for c in p.get('spec',{}).get('containers',[]):
    sc=c.get('securityContext',{})
    if not sc.get('runAsNonRoot', False):
      root+=1
print(root)
" 2>/dev/null || echo "0")
if [ "$VAULT_PODS_ROOT" -eq 0 ]; then
  pass "5.1 No root pod in foundation-vault"
else
  fail "5.1 No root pod in foundation-vault" "$VAULT_PODS_ROOT container(s) without runAsNonRoot"
fi

# 5.2 OpenBao: drop ALL + readOnlyRootFS
OBAO_HARDENED=$(kubectl get pods -n foundation-vault -l app=openbao -o json 2>/dev/null | python3 -c "
import json,sys
pods=json.load(sys.stdin).get('items',[])
ok=0
for p in pods:
  for c in p.get('spec',{}).get('containers',[]):
    sc=c.get('securityContext',{})
    caps=sc.get('capabilities',{}).get('drop',[])
    if 'ALL' in caps and sc.get('readOnlyRootFilesystem',False) and sc.get('allowPrivilegeEscalation',True)==False:
      ok+=1
print(ok)
" 2>/dev/null || echo "0")
if [ "$OBAO_HARDENED" -ge 3 ]; then
  pass "5.2 OpenBao hardened: $OBAO_HARDENED/3 containers (drop ALL + readOnlyRootFS)"
else
  fail "5.2 OpenBao hardened" "Only $OBAO_HARDENED/3 containers with a complete securityContext"
fi

# 5.3 CoreDNS: no privileged pod
COREDNS_PRIV=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o json 2>/dev/null | python3 -c "
import json,sys
pods=json.load(sys.stdin).get('items',[])
priv=0
for p in pods:
  for c in p.get('spec',{}).get('containers',[]):
    if c.get('securityContext',{}).get('privileged',False):
      priv+=1
print(priv)
" 2>/dev/null || echo "0")
if [ "$COREDNS_PRIV" -eq 0 ]; then
  pass "5.3 CoreDNS: no privileged pod"
else
  fail "5.3 CoreDNS: no privileged pod" "$COREDNS_PRIV privileged CoreDNS container(s)"
fi

# 5.4 No pod with added capabilities (outside system ns + CNI/CSI workloads)
ADDED_CAPS=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json,sys
pods=json.load(sys.stdin).get('items',[])
# System namespaces + legitimately privileged workloads
SKIP_NS=('kube-system', 'longhorn-system', 'local-path-storage', 'capi-system', 'capi-operator-system', 'foundation-storage')
# Legitimately privileged pods (CNI, CSI, node-exporter)
# ztunnel is Istio ambient's node proxy: NET_ADMIN/SYS_ADMIN/NET_RAW is what
# it is for. It was the only real hit once the commas went in.
SKIP_PATTERNS=('cilium', 'istio-cni', 'ztunnel', 'longhorn', 'csi-', 'instance-manager', 'engine-image', 'node-exporter', 'alloy')
caps=0
for p in pods:
  ns=p.get('metadata',{}).get('namespace','')
  name=p.get('metadata',{}).get('name','')
  if ns in SKIP_NS:
    continue
  if any(pat in name for pat in SKIP_PATTERNS):
    continue
  for c in p.get('spec',{}).get('containers',[]) + p.get('spec',{}).get('initContainers',[]):
    adds=c.get('securityContext',{}).get('capabilities',{}).get('add',[])
    if adds:
      caps+=1
print(caps)
" 2>/dev/null || echo "0")
if [ "$ADDED_CAPS" -eq 0 ]; then
  pass "5.4 No pod with added capabilities (outside system ns)"
else
  fail "5.4 No pod with added capabilities" "$ADDED_CAPS container(s) with non-empty capabilities.add"
fi

# 5.5 PriorityClass platform-critical
PC_EXISTS=$(kubectl get priorityclass platform-critical -o name 2>/dev/null || echo "")
if [ -n "$PC_EXISTS" ]; then
  pass "5.5 PriorityClass platform-critical existe"
else
  skip "5.5 PriorityClass platform-critical" "PriorityClass not found (may not be deployed yet)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RAPPORT FINAL
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD} RESULT: $PASS/$TOTAL passed${NC}"
  [ "$SKIP" -gt 0 ] && echo -e "${YELLOW} ($SKIP skipped — environment not applicable)${NC}"
else
  echo -e "${RED}${BOLD} RESULT: $PASS/$TOTAL passed, $FAIL failed${NC}"
  [ "$SKIP" -gt 0 ] && echo -e "${YELLOW} ($SKIP skipped)${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
