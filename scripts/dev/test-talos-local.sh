#!/usr/bin/env bash
# ==============================================================================
# OpenAether — Local Talos Deployment Test (3 control planes + 3 workers, Docker)
#
# Exercises the PRODUCTION modules/talos (config generation, bootstrap,
# kubeconfig) on a real 3-CP etcd quorum with 3 dedicated (schedulable) workers,
# then deploys Cilium + Flux + the GitOps Kustomizations — no cloud creds.
#
# Config is delivered via USERDATA (the Talos Docker platform mechanism); the
# only modules/talos resource not exercised locally is talos_machine_configuration_apply
# (maintenance-mode gRPC apply, which is cloud-only per the Talos Docker docs).
#
# Usage:
#   ./scripts/dev/test-talos-local.sh             # full 3-CP deploy + verify
#   ./scripts/dev/test-talos-local.sh --destroy   # tear down
#
# Prerequisites: docker (Desktop + WSL2 integration), tofu, talosctl, kubectl, helm, nc
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/../.."
TOFU_DIR="${ROOT_DIR}/infrastructure/opentofu-local"
MANIFESTS_DIR="${ROOT_DIR}/infrastructure/opentofu/cluster/bootstrap-manifests"

# APPS_DIR points to the OpenAether-apps repository (apps/ tree with Flux Kustomizations).
# After the infra/apps split, clone dis-bzh/OpenAether-apps next to OpenAether-infra.
# Override with: APPS_DIR=/path/to/OpenAether-apps task local-test
APPS_DIR="${APPS_DIR:-${ROOT_DIR}/../OpenAether-apps}"
if [[ ! -d "${APPS_DIR}/apps/flux/local" ]]; then
  # Fallback: apps/ still lives in this repo (pre-split or monorepo layout)
  if [[ -d "${ROOT_DIR}/apps/flux/local" ]]; then
    APPS_DIR="${ROOT_DIR}"
  elif [[ "${1:-}" != "--destroy" ]]; then
    echo "ERROR: Cannot find apps/flux/local in APPS_DIR=${APPS_DIR}" >&2
    echo "       Clone dis-bzh/OpenAether-apps next to this repo, or set APPS_DIR." >&2
    exit 1
  fi
  # --destroy is deliberately exempt: it never reads APPS_DIR, and a teardown
  # that demands a SECOND repository is one that refuses exactly when a failed
  # deploy has left containers, volumes and state behind.
fi

CLUSTER_NAME="openaether-local-dev"
CP_IPS=("10.5.0.10" "10.5.0.11" "10.5.0.12")
# Host ports, derived from the same base local-up publishes rather than hardcoded:
# 50000 is the CONTAINER-internal port, and pinning it here made every endpoint
# unreachable while the checks below degraded to warnings and the run still ended green.
PORT_BASE="${TALOS_API_PORT_BASE:-45000}"
CP_ENDPOINTS=("127.0.0.1:$((PORT_BASE))" "127.0.0.1:$((PORT_BASE + 1))" "127.0.0.1:$((PORT_BASE + 2))")
# Dedicated workers (worker_count=3 in opentofu-local/variables.tf): IPs at .20+,
# host ports at base+10+i. Schedulable/untainted, for HA and real workload scheduling tests.
WORKER_IPS=("10.5.0.20" "10.5.0.21" "10.5.0.22")
WORKER_ENDPOINTS=("127.0.0.1:$((PORT_BASE + 10))" "127.0.0.1:$((PORT_BASE + 11))" "127.0.0.1:$((PORT_BASE + 12))")
TOTAL_NODES=$(( ${#CP_IPS[@]} + ${#WORKER_IPS[@]} ))

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}" >&2; }

# ==============================================================================
# Destroy
# ==============================================================================
if [[ "${1:-}" == "--destroy" ]]; then
  info "Destroying local Talos cluster..."
  cd "${TOFU_DIR}"
  export TF_VAR_cilium_manifest="placeholder"
  tofu destroy -auto-approve 2>/dev/null || true
  # Belt-and-suspenders cleanup (covers both roles by name prefix, so it doesn't
  # depend on the configured CP/worker counts).
  for c in $(docker ps -aq --filter "name=${CLUSTER_NAME}-" 2>/dev/null); do
    docker rm -f "$c" 2>/dev/null || true
  done
  for vol in $(docker volume ls -q --filter "name=${CLUSTER_NAME}-" 2>/dev/null); do
    docker volume rm "$vol" 2>/dev/null || true
  done
  docker network rm "${CLUSTER_NAME}-net" 2>/dev/null || true
  # The glob matters: `talosconfig-new.sh` writes role-scoped siblings
  # (talosconfig.reader), and naming only the two files left one behind — a
  # live credential on disk under a teardown that reported clean.
  rm -f "${TOFU_DIR}/kubeconfig" "${TOFU_DIR}"/talosconfig*
  # Wipe the ephemeral local state too: `tofu destroy` leaves it populated
  # (machine_secrets is prevent_destroy'd), and a stale state breaks the next
  # fresh apply (CA mismatch / skipped bootstrap). No backend, so this is safe.
  rm -f "${TOFU_DIR}/terraform.tfstate" "${TOFU_DIR}/terraform.tfstate.backup"

  # ASK DOCKER, do not assume. Everything above is best-effort by design —
  # `tofu destroy` has its stderr discarded and its exit code ignored, each
  # `docker rm` ends in `|| true`, and the state file is deleted rather than
  # emptied, so "0 resources in the state" afterwards proves only that the file
  # is gone. Until this check, `✓ Local cluster destroyed` printed whatever
  # happened; a sweep that removed nothing looked exactly like a clean teardown.
  # Credentials count as "left behind" too. The sweep above is `rm -f`, which
  # cannot fail and so cannot report — and the whole point of this block is
  # that best-effort cleanup must still be ASKED whether it worked.
  cred=0
  for f in "${TOFU_DIR}/kubeconfig" "${TOFU_DIR}"/talosconfig*; do
    [ -e "$f" ] && cred=$((cred + 1))
  done
  left=""
  for kind in "container:$(docker ps -aq --filter "name=${CLUSTER_NAME}-" 2>/dev/null | wc -l)" \
    "volume:$(docker volume ls -q --filter "name=${CLUSTER_NAME}-" 2>/dev/null | wc -l)" \
    "network:$(docker network ls -q --filter "name=${CLUSTER_NAME}-net" 2>/dev/null | wc -l)" \
    "credential:${cred}"; do
    [ "${kind##*:}" -gt 0 ] && left="${left}${kind%%:*}=${kind##*:} "
  done
  if [ -n "$left" ]; then
    echo "✗ still present after the teardown: ${left}— remove them by hand." >&2
    echo "  A docker leftover means the next deploy inherits half a cluster (a stale" >&2
    echo "  container answers and the bootstrap skips); a credential leftover means a" >&2
    echo "  key to a cluster that no longer exists is sitting on this disk." >&2
    exit 1
  fi
  success "Local cluster destroyed — no container, volume or network in docker, no credential on disk"
  exit 0
fi

# ==============================================================================
# Preflight
# ==============================================================================
info "Preflight checks..."
MISSING=()
for cmd in docker tofu talosctl kubectl helm nc flux; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
[[ ${#MISSING[@]} -gt 0 ]] && { error "Missing tools: ${MISSING[*]}"; exit 1; }
docker ps >/dev/null 2>&1 || { error "Docker is not running (start Docker Desktop, enable WSL2 integration)."; exit 1; }
# Fail in ~10ms on a host that can never bootstrap Talos-in-Docker, instead of
# a silent 90s hang in Step 3 below ending on an unrelated-looking timeout.
"${SCRIPT_DIR}/check-docker-talos-capability.sh" || exit 1
"${SCRIPT_DIR}/check-host-overlay-fd.sh" || exit 1
export TF_VAR_encryption_passphrase="${TF_VAR_encryption_passphrase:-local-test-passphrase-32chars-minimum}"

# Flux reconciles from GitHub — the current branch must be pushed so the GitRepository can clone it.
CURRENT_BRANCH="$(git -C "${ROOT_DIR}" symbolic-ref --short HEAD 2>/dev/null || echo "main")"
UNPUSHED=$(git -C "${ROOT_DIR}" log "origin/${CURRENT_BRANCH}..HEAD" --oneline 2>/dev/null | wc -l || echo 0)
if [[ "${UNPUSHED}" -gt 0 ]]; then
  warn "Branch '${CURRENT_BRANCH}' has ${UNPUSHED} unpushed commit(s). Flux will reconcile from GitHub"
  warn "and will not see local changes until pushed. Run: git push origin ${CURRENT_BRANCH}"
  warn "Proceeding — GitRepository will wait for the branch to become available."
fi

success "Preflight passed"

# ==============================================================================
# Step 1 — Render simplified Cilium manifest for local
# ==============================================================================
info "Step 1 — Rendering local Cilium manifest..."
if [[ ! -f "${MANIFESTS_DIR}/cilium-local.yaml" ]] || grep -q "CILIUM-MANIFEST-PLACEHOLDER" "${MANIFESTS_DIR}/cilium-local.yaml" 2>/dev/null; then
  "${SCRIPT_DIR}/../bootstrap/render-bootstrap-manifests.sh" --local
fi
export TF_VAR_cilium_manifest="$(cat "${MANIFESTS_DIR}/cilium-local.yaml")"
success "Cilium manifest ready"

# ==============================================================================
# Step 2 — Deploy the 3-CP cluster via the production modules/talos
# (config generation → USERDATA containers → bootstrap → kubeconfig)
# ==============================================================================
info "Step 2 — Deploying Talos cluster: 3 CP + 3 workers (OpenTofu + modules/talos)..."
cd "${TOFU_DIR}"
tofu init -upgrade >/dev/null 2>&1 || tofu init >/dev/null
# If no live cluster is running, any pre-existing local state is stale: its
# containers are gone, and `--destroy` can't fully clear state because
# machine_secrets is prevent_destroy'd. Reusing that half-state either mixes an
# old CA with freshly-created containers (bootstrap fails the TLS handshake:
# "certificate signed by unknown authority") or skips the already-recorded
# bootstrap so the new etcd hangs at "waiting to join". Local state is ephemeral
# (no backend), so wipe it for a clean, CA-consistent apply rather than reuse it.
if ! docker ps --format '{{.Names}}' | grep -q "^${CLUSTER_NAME}-cp-0$"; then
  rm -f terraform.tfstate terraform.tfstate.backup
fi
# Docker Desktop's WSL2 port-forwarder 500s when too many `docker run --publish`
# register at once ("ports are not available … /forwards/expose … 500"); 5 nodes
# in parallel tripped it. modules/providers/local serializes this in two waves
# (workers depend_on the control planes) — capping concurrency without a global
# -parallelism=1, which would deadlock the (container-independent) bootstrap.
tofu apply -var talos_bootstrap=true -auto-approve
success "Cluster provisioned (config generated, containers up, etcd bootstrapped, kubeconfig retrieved)"

export KUBECONFIG="${TOFU_DIR}/kubeconfig"
export TALOSCONFIG="${TOFU_DIR}/talosconfig"

# ==============================================================================
# Step 3 — Verify 3-CP etcd quorum + Talos health (talosctl, out-of-band)
# ==============================================================================
info "Step 3 — Verifying etcd quorum and Talos health..."
MEMBERS=0
for i in $(seq 1 18); do
  # grep -c prints "0" AND exits 1 on no match; `|| echo 0` would then append a
  # second line ("0\n0") and break the arithmetic `[[ ]]` below. `|| true` keeps
  # grep's own single-line count (incl. its "0") under `set -o pipefail`.
  MEMBERS=$(talosctl --nodes "${CP_IPS[0]}" --endpoints "${CP_ENDPOINTS[0]}" etcd members 2>/dev/null | grep -c "${CLUSTER_NAME}-cp-" || true)
  [[ "$MEMBERS" -eq 3 ]] && break
  sleep 5
done
if [[ "$MEMBERS" -eq 3 ]]; then
  success "etcd quorum: 3 members"
else
  error "etcd members found: $MEMBERS (expected 3)"
  exit 1
fi

CP_LIST=$(IFS=,; echo "${CP_IPS[*]}")
WORKER_LIST=$(IFS=,; echo "${WORKER_IPS[*]}")
if talosctl --nodes "${CP_IPS[0]}" --endpoints "${CP_ENDPOINTS[0]}" health \
     --control-plane-nodes "${CP_LIST}" \
     --worker-nodes "${WORKER_LIST}" --wait-timeout 5m >/dev/null 2>&1; then
  success "Talos cluster reports healthy"
else
  error "Talos health check did not pass within the timeout"
  exit 1
fi

# ==============================================================================
# Step 4 — Verify Kubernetes nodes + Cilium
# ==============================================================================
info "Step 4 — Verifying Kubernetes nodes and Cilium..."
for i in $(seq 1 60); do
  # `|| true`: grep -c exits 1 on 0 matches (no node Ready yet on early loops),
  # which under set -e + pipefail would abort the script here.
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  [[ "$READY" -eq "$TOTAL_NODES" ]] && break
  sleep 5
done
echo "Nodes:"
kubectl get nodes -o wide 2>/dev/null | sed 's/^/    /'
# Fatal, all four post-Cilium-fix checks: nodes and Cilium here, schedulable
# workers (Step 5) and Flux controllers (Step 6) below. All four were still
# `|| warn` while the header above claimed the degrade-to-warning bug was
# fixed — it was, for etcd and the Talos health check only. A cluster with no
# working CNI, no schedulable workers, or no Flux reached the green banner.
if [[ "$READY" -eq "$TOTAL_NODES" ]]; then
  success "All ${TOTAL_NODES} nodes Ready (${#CP_IPS[@]} CP + ${#WORKER_IPS[@]} workers)"
else
  error "Nodes Ready: ${READY}/${TOTAL_NODES}"
  exit 1
fi
# Cilium gets the same bounded wait as the nodes above: sampled once, a check
# this strict would go red on a cluster that was merely a few seconds behind.
for i in $(seq 1 60); do
  CILIUM=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  [[ "$CILIUM" -ge "$TOTAL_NODES" ]] && break
  sleep 5
done
if [[ "$CILIUM" -ge "$TOTAL_NODES" ]]; then
  success "Cilium running on all ${CILIUM} nodes"
else
  error "Cilium pods running: ${CILIUM}/${TOTAL_NODES} — the cluster has no working CNI"
  exit 1
fi

# ==============================================================================
# Step 5 — Scheduling: with dedicated workers the control planes stay tainted
# (workloads land on the untainted workers). Only when there are no workers do
# we untaint the control planes so the single-role cluster can schedule pods.
# ==============================================================================
if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
  info "Step 5 — Removing control-plane taint (no dedicated workers)..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  success "Taint removed (control planes are schedulable)"
else
  info "Step 5 — Keeping control-plane taint (${#WORKER_IPS[@]} dedicated workers are schedulable)..."
  SCHED=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | grep -c " Ready " || true)
  if [[ "$SCHED" -eq ${#WORKER_IPS[@]} ]]; then
    success "${SCHED} schedulable worker node(s) Ready"
  else
    error "Schedulable workers Ready: ${SCHED}/${#WORKER_IPS[@]}"
    exit 1
  fi
fi

# ==============================================================================
# Step 6 — Install Flux controllers
#   Flux is too large for Talos USERDATA → deployed post-bootstrap.
#   Uses flux CLI pinned to the same version as flux-install.yaml in the repo.
# ==============================================================================
info "Step 6 — Installing Flux controllers (flux install)..."
# flux install reports failure if any deployment is not ready within its own timeout,
# but pods may still be starting (Kyverno audit policy can add ~15s delay in Docker).
# The pod-wait loop below is the real readiness gate — don't abort on flux install timeout.
flux install --kubeconfig "${TOFU_DIR}/kubeconfig" >/dev/null 2>&1 || true
for i in $(seq 1 36); do
  R=$(kubectl -n flux-system get pods --no-headers 2>/dev/null | grep -c "Running" || true)
  [[ "$R" -ge 4 ]] && break
  sleep 5
done
R=$(kubectl -n flux-system get pods --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "$R" -ge 4 ]]; then
  success "Flux controllers running (${R} pods)"
else
  error "Flux pods running: ${R}/4"
  exit 1
fi

# ==============================================================================
# Step 7 — Apply Flux Kustomizations (local overlay)
#   Suspended groups: cert-manager, istio, storage, observability (HelmRelease)
#   Active groups: namespaces, platform, vault, eso, cnpg, kyverno
# ==============================================================================
info "Step 7 — Applying Flux Kustomizations (apps/flux/local)..."
kubectl apply -k "${APPS_DIR}/apps/flux/local" --server-side=true --force-conflicts >/dev/null 2>&1

# The GitRepository in apps/flux/local/gitrepository.yaml points to branch: main (default for
# cloud/production). In local dev, commits may be on a feature branch not yet merged to main.
# Patch the branch to match the current HEAD so Flux can pull the right code.
CURRENT_BRANCH="$(git -C "${ROOT_DIR}" symbolic-ref --short HEAD 2>/dev/null || echo "main")"
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
  info "  Patching GitRepository branch: main → ${CURRENT_BRANCH} (local dev branch)"
  kubectl patch gitrepository openaether -n flux-system \
    --type='merge' -p "{\"spec\":{\"ref\":{\"branch\":\"${CURRENT_BRANCH}\"}}}" >/dev/null 2>&1 || true
fi
sleep 5
for i in $(seq 1 24); do
  READY=$(flux get kustomizations --kubeconfig "${TOFU_DIR}/kubeconfig" --no-header 2>/dev/null \
    | grep -v "True\s*False\|suspended" | grep -c "True" || true)
  TOTAL=$(flux get kustomizations --kubeconfig "${TOFU_DIR}/kubeconfig" --no-header 2>/dev/null \
    | grep -v "suspended\|True     False" | wc -l || true)
  [[ "$READY" -ge 3 ]] && break
  sleep 5
done
info "Flux Kustomizations status:"
flux get kustomizations --kubeconfig "${TOFU_DIR}/kubeconfig" 2>/dev/null | sed 's/^/    /' || true

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
success "Local Talos cluster is up: ${#CP_IPS[@]} CP + ${#WORKER_IPS[@]} workers (modules/talos validated end-to-end)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  export KUBECONFIG=${TOFU_DIR}/kubeconfig"
echo "  export TALOSCONFIG=${TOFU_DIR}/talosconfig"
echo "  kubectl get nodes"
echo "  talosctl --nodes ${CP_IPS[0]} --endpoints ${CP_ENDPOINTS[0]} etcd members"
echo ""
echo "  Flux status:  flux get kustomizations --kubeconfig \${KUBECONFIG}"
echo "  Tear down:  $0 --destroy   (or: task local-down)"
