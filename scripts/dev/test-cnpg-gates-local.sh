#!/usr/bin/env bash
# Rung ONE for the DATABASE gates: roll-gates.sh's cnpg_* logic against a
# REAL CloudNativePG, on the local Docker cluster.
#
# test-gates-local.sh is the real-apiserver rung for everything else, but it only
# ever proved CNPG ABSENT — so the whole cnpg_* branch, the most intricate code in
# the repo, was covered by a stub keyed on argv and by one incident on a paying
# cluster. A stub answers the query it is asked: it does not tell you kubectl
# cannot parse that query (2026-08-15, eleven green assertions on a jsonpath the
# apiserver refuses), and it does not tell you a patch that returned 0 left the
# budgets untouched (OVH 2026-08-15). Only a real operator answers those.
#
# What it CANNOT cover: an eviction genuinely failing a primary over. That needs
# node-local storage and a real drain, so it stays cloud-only.
#
# Installs, idempotently and cluster-wide, what the local cluster does not ship:
# rancher local-path-provisioner (there is no storage class at all) and the CNPG
# operator at the version OpenAether-apps vendors.
#
# Needs: `task local-up`.
# Usage: test-cnpg-gates-local.sh [--skip-deadlock]
#   RR_SRC=<file>  extract the gates from this copy of lib/roll-gates.sh instead.
#                  Mutating a copy and re-running is how each assertion below is
#                  shown to be able to fail.
#   LAB_NS=<ns>    reuse and KEEP this lab namespace instead of making one, so a
#                  mutation run costs seconds. Only sound with --skip-deadlock:
#                  the deadlock phase wrecks the cluster on purpose.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/infrastructure/opentofu-local/kubeconfig}"
RR_SRC="${RR_SRC:-$ROOT/scripts/lib/roll-gates.sh}"
# Pinned, never `latest`: a gate proven against some other operator proves nothing
# about the one that runs in production (OpenAether-apps apps/base/cnpg/).
CNPG_VERSION="1.23.1"
LPP_VERSION="v0.0.31"
CL="gate-db"
SKIP_DEADLOCK=0
[ "${1:-}" = "--skip-deadlock" ] && SKIP_DEADLOCK=1

PASS=0
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
step() { printf '▶ %s\n' "$*"; }
report() { printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]; }

# --- the functions under test, with a REAL kubectl -----------------------------
# Same extraction as test-gates-local.sh: the gates are read out of the ops script
# so this harness can never drift into testing its own copy of them.
eval "$(awk '
  BEGIN { split("cnpg_installed,cnpg_flux_owners,cnpg_clusters,cnpg_flux_suspend," \
                "cnpg_maintenance,cnpg_budgets,cnpg_pod_state,cnpg_deadlocked," \
                "cnpg_pending,wait_cnpg_whole", a, ",")
          for (i in a) want[a[i]] = 1 }
  /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
  inside { print }
  inside && /^\}/ { inside = 0 }
' "$RR_SRC")"
for f in cnpg_installed cnpg_flux_owners cnpg_clusters cnpg_flux_suspend \
         cnpg_maintenance cnpg_budgets cnpg_pod_state cnpg_deadlocked cnpg_pending \
         wait_cnpg_whole; do
  declare -F "$f" >/dev/null || { echo "✗ $f was not extracted from $RR_SRC" >&2; exit 1; }
done
KCTL=(kubectl)
# The gates log through these. `ok` must be a no-op and NOT the pass counter:
# sharing the name is how a gate's own log line scores itself a passing assertion.
info() { :; }
warn() { :; }
ok()   { :; }
die()  { printf 'die: %s\n' "$*" >&2; return 1; }
DRAIN_TIMEOUT=60s
CNPG_TIMEOUT=20         # a whole cluster must return on the FIRST poll, not wait
CNPG_UNSTICK_AFTER=300  # never reached here: the timing test must not delete pods

kubectl cluster-info >/dev/null 2>&1 || { echo "✗ no local cluster — run: task local-up" >&2; exit 1; }

# --- prerequisites -------------------------------------------------------------
if ! kubectl get sc local-path >/dev/null 2>&1; then
  step "installing local-path-provisioner ${LPP_VERSION} — the local cluster ships no storage class"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LPP_VERSION}/deploy/local-path-storage.yaml" >/dev/null || exit 1
fi
# Talos enforces PodSecurity `baseline` on every namespace, and the provisioner's
# helper pod mounts a hostPath — without this every PVC stays Pending for ever on
# "violates PodSecurity baseline: hostPath volumes", with the failure only in the
# provisioner's log.
kubectl label ns local-path-storage pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s >/dev/null || exit 1

if ! kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  step "installing the CNPG operator ${CNPG_VERSION}"
  kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml" >/dev/null || exit 1
fi
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s >/dev/null || exit 1

NS="${LAB_NS:-cnpg-lab-$$}"
KEEP="${LAB_NS:+1}"
# cnpg_maintenance patches EVERY cluster and then waits for EVERY cnpg budget in
# the cluster to disappear, so a database belonging to someone else would both be
# patched by this test and make it hang.
foreign="$(kubectl get clusters.postgresql.cnpg.io -A --no-headers 2>/dev/null | awk -v ns="$NS" '$1 != ns {print $1"/"$2}')"
[ -z "$foreign" ] || { echo "✗ another CNPG cluster is present (${foreign}) — this test patches all of them; refusing" >&2; exit 1; }

cleanup() {
  # Unconditional: the deadlock phase scales the operator down, and leaving it
  # there would quietly break every later run against this cluster.
  kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=1 >/dev/null 2>&1
  [ -n "$KEEP" ] || kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# Wait for the operator to report <n>/<n> instances ready.
wait_ready() {
  local want="$1" i st
  for i in $(seq 1 96); do
    st="$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.status.readyInstances}/{.status.instances}' 2>/dev/null)"
    [ "$st" = "$want/$want" ] && return 0
    sleep 5
  done
  return 1
}

# Is the primary's budget in the apiserver? Asked of the apiserver every time —
# the whole point of the maintenance assertions is to never trust a patch's rc.
pdb_wait() { # <present|gone>
  local want="$1" i
  for i in $(seq 1 24); do
    if kubectl get pdb -A -l cnpg.io/cluster \
         -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null |
       grep -qx "${NS}/${CL}-primary"
    then [ "$want" = present ] && return 0
    else [ "$want" = gone ] && return 0
    fi
    sleep 5
  done
  return 1
}

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null
if ! kubectl -n "$NS" get cluster "$CL" >/dev/null 2>&1; then
  step "creating a 2-instance CNPG cluster in ${NS} (first run pulls the postgres image)"
  kubectl apply -f - >/dev/null <<EOF || exit 1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: $CL, namespace: $NS}
spec:
  instances: 2
  storage: {size: 512Mi, storageClass: local-path}
  resources:
    requests: {cpu: 50m, memory: 200Mi}
  postgresql:
    parameters: {shared_buffers: 16MB, max_connections: "20"}
EOF
fi
wait_ready 2 || { echo "✗ the lab cluster never reached 2/2 ready — nothing below would mean anything" >&2; exit 1; }

echo "=== roll-gates.sh's CNPG gates against CloudNativePG ${CNPG_VERSION} ==="

if cnpg_installed; then
  pass "cnpg_installed: the CRD is there and it says so"
else
  bad "cnpg_installed: a real CNPG reads as absent — the roll would skip every database gate and drain blind"
fi

got="$(cnpg_clusters)"
if [ "$got" = "$NS $CL" ]; then
  pass "cnpg_clusters: enumerates '$NS $CL'"
else
  bad "cnpg_clusters: expected '$NS $CL', got '$got'"
fi

# The owner lookup's jsonpath escapes the dots in a Flux label key; nothing but a
# real apiserver says whether that parses.
if owners="$(cnpg_flux_owners)"; then
  if [ -z "${owners//[[:space:]]/}" ]; then
    pass "cnpg_flux_owners: parses, and a cluster Flux does not own yields no owner"
  else
    bad "cnpg_flux_owners: invented an owner for an unlabelled cluster: '$owners'"
  fi
else
  bad "cnpg_flux_owners: the escaped-dot label jsonpath did not execute"
fi

prim="$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"
st="$(cnpg_pod_state "$NS" "$prim")"
[ "$st" = ready ] && pass "cnpg_pod_state: the running primary ${prim} reads ready" \
                  || bad "cnpg_pod_state: running pod ${prim} read as '$st'"
st="$(cnpg_pod_state "$NS" "${CL}-no-such-pod")"
[ "$st" = absent ] && pass "cnpg_pod_state: a pod that does not exist reads absent" \
                   || bad "cnpg_pod_state: a NotFound pod read as '$st'"

# The dangerous direction. A gate that fires here deletes the pod of a live primary.
d="$(cnpg_deadlocked)"
[ -z "$d" ] && pass "cnpg_deadlocked: silent on a healthy cluster" \
            || bad "cnpg_deadlocked: FIRED on a healthy cluster ('$d') — that deletes a live primary"

t0=$SECONDS
wait_cnpg_whole >/dev/null 2>&1
el=$((SECONDS - t0))
[ "$el" -lt 15 ] && pass "wait_cnpg_whole: returned in ${el}s on a whole cluster" \
                 || bad "wait_cnpg_whole: took ${el}s on a cluster that is already whole"

# --- the one that was logged and not true --------------------------------------
pdb_wait present || bad "precondition: ${CL}-primary never appeared, so its removal proves nothing"
step "cnpg_maintenance true — then asking the apiserver, not the patch"
cnpg_maintenance true >/dev/null 2>&1   # rc deliberately unread: on OVH it was 0
if pdb_wait gone; then
  pass "cnpg_maintenance true: ${NS}/${CL}-primary is GONE from the apiserver"
else
  bad "cnpg_maintenance true: ${CL}-primary survived enablePDB=false — the drain would evict into it for ${DRAIN_TIMEOUT}"
fi
sp="$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.spec.enablePDB}' 2>/dev/null)"
[ "$sp" = false ] && pass "cnpg_maintenance true: spec.enablePDB=false is on the object" \
                  || bad "cnpg_maintenance true: spec.enablePDB reads '$sp'"

cnpg_maintenance false >/dev/null 2>&1
if pdb_wait present; then
  pass "cnpg_maintenance false: the budget is back — the roll does not leave databases unguarded"
else
  bad "cnpg_maintenance false: ${CL}-primary never came back"
fi

[ "$SKIP_DEADLOCK" -eq 1 ] && { report; exit; }

# --- the known deadlock, built out of real pods --------------------------------
echo
echo "=== the 2026-08-15 deadlock, on real objects ==="
# Condition 4 wants a third instance that is still ready, so the phase scales up.
step "scaling to 3 instances"
kubectl -n "$NS" patch cluster "$CL" --type merge -p '{"spec":{"instances":3}}' >/dev/null 2>&1
wait_ready 3 || { echo "✗ never reached 3/3 — cannot build the deadlock" >&2; report; exit 1; }

prim="$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"
tgt=""
for p in $(kubectl -n "$NS" get pods -o name 2>/dev/null | sed 's|pod/||' | grep -E "^${CL}-[0-9]+$"); do
  [ "$p" = "$prim" ] || { tgt="$p"; break; }
done
[ -n "$tgt" ] || { echo "✗ no replica to use as the stuck target" >&2; report; exit 1; }

# Nothing may repair the cluster while the shape is being built.
kubectl -n cnpg-system scale deploy/cnpg-controller-manager --replicas=0 >/dev/null 2>&1
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=120s >/dev/null 2>&1

# Wipe the target's PGDATA and restart it. It then needs a primary that is about
# to be deleted, so it stays not-ready for real — a replica whose primary merely
# vanishes goes on serving reads and stays READY, which is not the shape.
step "breaking ${tgt} (target) and deleting ${prim} (primary)"
kubectl -n "$NS" exec "$tgt" -c postgres -- sh -c 'rm -rf /var/lib/postgresql/data/pgdata' >/dev/null 2>&1
kubectl -n "$NS" exec "$tgt" -c postgres -- sh -c 'kill 1' >/dev/null 2>&1
seen=0
for i in $(seq 1 48); do
  if [ "$(cnpg_pod_state "$NS" "$tgt")" = notready ]; then
    seen=$((seen + 1)); [ "$seen" -ge 2 ] && break   # twice: the restart blips ready
  else seen=0
  fi
  sleep 5
done
kubectl -n "$NS" delete pod "$prim" --timeout=120s >/dev/null 2>&1

# The ONE synthetic field. currentPrimary already points at the deleted pod on its
# own; targetPrimary is written here because a lab cannot reproduce the eviction
# that wrote it — and this is the exact status patch `kubectl cnpg promote` issues.
kubectl -n "$NS" patch cluster "$CL" --subresource=status --type merge \
  -p "{\"status\":{\"targetPrimary\":\"${tgt}\",\"phase\":\"Switchover in progress\"}}" >/dev/null 2>&1

st="$(cnpg_pod_state "$NS" "$tgt")"
[ "$st" = notready ] && pass "cnpg_pod_state: a pod that exists and cannot start reads notready" \
                     || bad "cnpg_pod_state: the broken target ${tgt} read as '$st'"
st="$(cnpg_pod_state "$NS" "$prim")"
[ "$st" = absent ] && pass "cnpg_pod_state: the deleted primary reads absent" \
                   || bad "cnpg_pod_state: the deleted primary read as '$st'"

d="$(cnpg_deadlocked)"
if [ "$d" = "$NS $CL $tgt $prim" ]; then
  pass "cnpg_deadlocked: fires on the real shape, naming '$d'"
else
  bad "cnpg_deadlocked: expected '$NS $CL $tgt $prim', got '$d'"
fi

report
