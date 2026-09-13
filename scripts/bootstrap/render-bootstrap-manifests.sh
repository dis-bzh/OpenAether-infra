#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OpenAether — Render Bootstrap Manifests
# Generates static Cilium + Flux manifests for Talos
# inlineManifests injection.
#
# Prerequisites: helm, curl
# Usage:
#   ./scripts/bootstrap/render-bootstrap-manifests.sh           # production
#   ./scripts/bootstrap/render-bootstrap-manifests.sh --local   # local Docker testing
#   ./scripts/bootstrap/render-bootstrap-manifests.sh --check   # writes NOTHING: checks
#                                                     # that the committed artifacts
#                                                     # match the generator
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for --check (render into a throwaway directory, then diff).
# ⚠️ TWO levels: this script lives in scripts/bootstrap/. With a single `..`
# it wrote into scripts/infrastructure/… — a PHANTOM directory created by the
# `mkdir -p` below and never read by OpenTofu. `task render-manifests`
# therefore appeared to work while NEVER regenerating the committed
# artifacts: that is the origin of their drift away from the generator
# (observed 2026-07-27).
MANIFESTS_DIR="${OPENAETHER_MANIFESTS_DIR:-${SCRIPT_DIR}/../../infrastructure/opentofu/cluster/bootstrap-manifests}"

# Mode: production (default) or local Docker testing
LOCAL_MODE=false
if [[ "${1:-}" == "--local" ]]; then
  LOCAL_MODE=true
  shift
fi

# Versions — update these when upgrading.
# FLUX_VERSION MUST stay pinned: `latest` once bumped Flux with nothing asking
# for it and nothing reporting it. It is also what --check compares the
# committed flux-install.yaml against, so bump the pin and the artifact together.
# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io/
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
# renovate: datasource=github-releases depName=fluxcd/flux2
FLUX_VERSION="${FLUX_VERSION:-v2.9.5}"
FLUX_URL="https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml"

# The chart version is pinned, but the RENDERER is a second input nobody had
# declared: helm 3 and helm 4 emit different YAML for the same chart — helm 4
# prunes empty values, so helm 3 adds three empty config keys and an empty
# `--k8s-api-server-urls=`. Rendering on the other major silently produces a
# different artifact, which CI then rejects. Keep this equal to HELM_VERSION in
# .github/workflows/ci.yml.
HELM_MAJOR_EXPECTED="${HELM_MAJOR_EXPECTED:-4}"
helm_major="$(helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v?([0-9]+).*/\1/')"
if [[ -n "$helm_major" && "$helm_major" != "$HELM_MAJOR_EXPECTED" ]]; then
  echo "✗ helm major ${helm_major} — this artifact is rendered with helm ${HELM_MAJOR_EXPECTED}." >&2
  echo "  Rendering here would produce a file CI rejects. Install helm ${HELM_MAJOR_EXPECTED}," >&2
  echo "  or set HELM_MAJOR_EXPECTED=${helm_major} here AND in .github/workflows/ci.yml." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# --check: anti-drift guardrail
#
# A generated artifact can diverge from its generator SILENTLY — it happened:
# the committed cilium*.yaml carried three `--set` flags missing from this
# script, so a plain `task render-manifests` broke Istio ambient with nothing
# reporting it. This mode replays the render into a throwaway dir and compares.
#
# cilium*.yaml are replayed through the generator; flux-install.yaml is a stock
# upstream asset, so checking it means confirming it is still exactly
# FLUX_VERSION upstream.
# ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
  command -v diff >/dev/null 2>&1 || { echo "✗ diff required" >&2; exit 1; }
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "🔍 Checking the committed artifacts against the generator…"
  OPENAETHER_MANIFESTS_DIR="$tmp" OPENAETHER_SKIP_FLUX=1 "$0" >/dev/null
  OPENAETHER_MANIFESTS_DIR="$tmp" OPENAETHER_SKIP_FLUX=1 "$0" --local >/dev/null
  # helm's raw render carries trailing whitespace; the committed artifact has
  # been through the pre-commit hooks (`trim trailing whitespace`,
  # `fix end of files`). Comparing them as-is would keep the check permanently
  # red — so we normalise BOTH sides, exactly like the hook does.
  norm() { sed -e 's/[[:space:]]*$//' "$1"; }
  drift=0
  for f in cilium.yaml cilium-local.yaml; do
    # cilium-local.yaml is gitignored on purpose — it is rendered on demand by
    # `task local-up`, never committed. On a fresh checkout (CI) it is absent, and
    # comparing against it made this check die on every run instead of passing.
    # Nothing committed means nothing to drift from.
    if [[ ! -f "${MANIFESTS_DIR}/${f}" ]]; then
      echo "  ↷ ${f} — not committed (gitignored); nothing to compare"
      continue
    fi
    if ! diff -q <(norm "${MANIFESTS_DIR}/${f}") <(norm "${tmp}/${f}") >/dev/null 2>&1; then
      echo "  ❌ ${f} differs from the render (excerpt):"
      diff <(norm "${MANIFESTS_DIR}/${f}") <(norm "${tmp}/${f}") | head -20 | sed 's/^/      /'
      drift=1
    else
      echo "  ✓ ${f}"
    fi
  done
  # Offline is a legitimate case (`task validate` runs without credentials), so
  # an unreachable upstream warns instead of failing the whole check.
  if curl -sfL "${FLUX_URL}" -o "${tmp}/flux-install.yaml"; then
    if diff -q <(norm "${MANIFESTS_DIR}/flux-install.yaml") <(norm "${tmp}/flux-install.yaml") >/dev/null 2>&1; then
      echo "  ✓ flux-install.yaml (${FLUX_VERSION})"
    else
      echo "  ❌ flux-install.yaml is not upstream ${FLUX_VERSION} (excerpt):"
      diff <(norm "${MANIFESTS_DIR}/flux-install.yaml") <(norm "${tmp}/flux-install.yaml") | head -10 | sed 's/^/      /'
      drift=1
    fi
  elif [ "${RENDER_CHECK_ALLOW_OFFLINE:-0}" = 1 ]; then
    echo "  ⚠ flux-install.yaml NOT checked — ${FLUX_VERSION} unreachable, and"
    echo "    RENDER_CHECK_ALLOW_OFFLINE=1 says to accept that."
  else
    # Warning-and-continue is how this check went quiet: it printed one line
    # mid-scroll and `task preflight` still announced "every free rung passed".
    # NOT drift=1 — "could not check" is not "does not match", and reporting the
    # second for the first sends the reader to regenerate an artifact that may
    # be perfectly correct.
    cat >&2 <<EOT

✗ flux-install.yaml was NOT checked — ${FLUX_VERSION} unreachable.
  This says nothing about the artifact: it says the comparison did not happen.
  Re-run with network, or RENDER_CHECK_ALLOW_OFFLINE=1 to accept a render-check
  that skipped the vendored manifest.
EOT
    exit 1
  fi
  if [[ "$drift" -eq 1 ]]; then
    cat >&2 <<'EOT'

✗ The committed artifacts no longer match the generator.
  Before regenerating, decide WHICH is right:
    • the artifact (a `--set` was hand-added and must move into the script);
    • the script (the artifact is simply stale → regenerate and commit).
  Regenerating erases the difference without showing it — that is how Istio
  ambient was broken on 2026-07-26.
EOT
    exit 1
  fi
  echo "OK — bootstrap artifacts up to date with the generator."
  exit 0
fi

mkdir -p "${MANIFESTS_DIR}"

# ─────────────────────────────────────────────────────
# 1. Render Cilium manifest via helm template
# ─────────────────────────────────────────────────────
if [[ "$LOCAL_MODE" == "true" ]]; then
  CILIUM_OUTPUT="${MANIFESTS_DIR}/cilium-local.yaml"
  echo "🔧 Rendering Cilium ${CILIUM_VERSION} manifest (LOCAL mode — simplified for Docker)..."
else
  CILIUM_OUTPUT="${MANIFESTS_DIR}/cilium.yaml"
  echo "🔧 Rendering Cilium ${CILIUM_VERSION} manifest (PRODUCTION mode)..."
fi

helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null 2>&1
helm repo update cilium >/dev/null 2>&1

if [[ "$LOCAL_MODE" == "true" ]]; then
  # Local mode: simplified Cilium for Docker/WSL2
  # - kubeProxyReplacement=false: use iptables (no eBPF kube-proxy replacement)
  # - encryption=false: no WireGuard (simpler for single-node Docker)
  #
  # ⚠️ socketLB.enabled=true is MANDATORY here, even though kubeProxyReplacement
  # is false. Without it the chart emits `bpf-lb-sock: "false"`, which makes
  # `bpf-lb-sock-hostns-only` INOPERATIVE: hostNetwork pods (kube-apiserver)
  # can then no longer reach ClusterIPs and Flux dry-runs time out on the
  # webhooks. The fix lived in the committed artifact, not in this script —
  # so regenerating reintroduced the bug (caught by --check on 2026-07-27).
  helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=false \
    --set socketLB.enabled=true \
    --set cni.exclusive=false \
    --set socketLB.hostNamespaceOnly=true \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set prometheus.enabled=true \
    --set operator.prometheus.enabled=true \
    --set operator.replicas=1 \
    --set encryption.enabled=false \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    > "${CILIUM_OUTPUT}"
  echo "  ✅ Written to bootstrap-manifests/cilium-local.yaml"
else
  # Production mode: full Cilium with WireGuard encryption + kube-proxy replacement
  #
  # prometheus.enabled / operator.prometheus.enabled: the agent and the operator
  # serve no metrics at all without them, so the CNI — the one component every
  # other one depends on — was the last blind spot in the stack. No Service is
  # created (serviceMonitor stays off): the scrape is a VMPodScrape, see
  # apps/base/observability/vm-customresources/vmscapes.yaml.
  #
  # ⚠️ Both settings are REQUIRED by Istio ambient (apps/base/istio) — do not
  # remove them without removing the mesh, or istio-cni never becomes Ready:
  #  - cni.exclusive=false: otherwise Cilium rewrites 05-cilium.conflist in a
  #    loop and strips the chained istio-cni plugin ("conflicting component
  #    constantly reverting our work") → /readyz 503 → Helm install timeout →
  #    ztunnel, services-gateway and istio-authorizationpolicies stuck in turn;
  #  - socketLB.hostNamespaceOnly=true: without it the socket-LB short-circuits
  #    the ambient redirection for host-network processes.
  helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set socketLB.enabled=true \
    --set cni.exclusive=false \
    --set socketLB.hostNamespaceOnly=true \
    --set nodeSelectorLabels=true \
    --set bpf.hostLegacyRouting=false \
    --set bpf.masquerade=true \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set prometheus.enabled=true \
    --set operator.prometheus.enabled=true \
    --set operator.replicas=1 \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    > "${CILIUM_OUTPUT}"
  echo "  ✅ Written to bootstrap-manifests/cilium.yaml"
fi

# helm leaves trailing whitespace; the `trim trailing whitespace` pre-commit
# hook strips it at commit time. Without normalising HERE, every render dirties
# the working tree and the committed artifact can never be identical to the
# render — which forced --check to compare "modulo whitespace".
sed -i 's/[[:space:]]*$//' "${CILIUM_OUTPUT}"

# ─────────────────────────────────────────────────────
# 1b. Regenerate the upstream artifacts lock (production only)
# ─────────────────────────────────────────────────────
# cilium.yaml pins its images by digest; flux-install.yaml pins seven by tag
# only, so a tag force-moved upstream changes not one byte of either committed
# file and nothing here would notice (#119). This lock records what THIS
# render actually wrote, offline-verifiable by
# check-upstream-artifacts-lock.sh. Gated on OPENAETHER_SKIP_FLUX (already set
# by --check's own recursive calls above): those render into a throwaway dir
# that never holds flux-install.yaml, and cilium-local.yaml is gitignored —
# neither belongs in a lock committed alongside the production artifacts.
if [[ "$LOCAL_MODE" == "false" && "${OPENAETHER_SKIP_FLUX:-0}" != "1" ]]; then
  (cd "${MANIFESTS_DIR}" && sha256sum cilium.yaml flux-install.yaml > upstream-artifacts.lock)
  echo "  🔒 upstream-artifacts.lock regenerated"
fi

# ─────────────────────────────────────────────────────
# 2. Download Flux install manifest
# ─────────────────────────────────────────────────────
# ⚠️ Opt-in (OPENAETHER_REFRESH_FLUX=1): re-downloading is an upgrade, not a
# render. Bump FLUX_VERSION first — otherwise this just rewrites the same file.
if [[ "$LOCAL_MODE" == "false" && "${OPENAETHER_SKIP_FLUX:-0}" != "1" \
      && "${OPENAETHER_REFRESH_FLUX:-0}" == "1" ]]; then
  echo "🔧 Downloading Flux install manifest (${FLUX_VERSION})..."
  curl -sL "${FLUX_URL}" > "${MANIFESTS_DIR}/flux-install.yaml"
  if [ ! -s "${MANIFESTS_DIR}/flux-install.yaml" ] || [ "$(wc -c < "${MANIFESTS_DIR}/flux-install.yaml")" -lt 1000 ]; then
    echo "  ❌ Flux manifest download failed or is too small"
    exit 1
  fi
  echo "  ✅ Written to bootstrap-manifests/flux-install.yaml"
fi

# ─────────────────────────────────────────────────────
# 3. Summary
# ─────────────────────────────────────────────────────
echo ""
echo "📋 Bootstrap manifests rendered:"
echo "   Cilium: ${CILIUM_VERSION} ($([ "$LOCAL_MODE" == "true" ] && echo "local — simplified" || echo "production — WireGuard"))"
[[ "$LOCAL_MODE" == "false" ]] && echo "   Flux:   ${FLUX_VERSION}"
echo ""
echo "   Files:"
ls -lh "${MANIFESTS_DIR}"/*.yaml 2>/dev/null || true
ls -lh "${MANIFESTS_DIR}"/*.tftpl 2>/dev/null || true
echo ""
if [[ "$LOCAL_MODE" == "true" ]]; then
  echo "💡 Local manifests generated. Drive the 3-CP Docker cluster with:"
  echo "   ./scripts/dev/test-talos-local.sh        # or: task local-test"
  echo "   (it reads bootstrap-manifests/cilium-local.yaml into TF_VAR_cilium_manifest)"
else
  echo "💡 Commit these files to the repository."
  echo "   Re-run this script when upgrading Cilium or Flux versions."
fi
