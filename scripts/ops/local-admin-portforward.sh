#!/usr/bin/env bash
# ==============================================================================
# OpenAether — Local admin GUI access (port-forward, localhost-only)
#
# Exposes the admin GUIs on 127.0.0.1 ONLY (kubectl port-forward binds loopback),
# i.e. they are inherently IP-filtered to this host — no LAN/other host can reach
# them. This is the LOCAL equivalent of the cloud "admin = IP allowlist" rule.
#
# Cloud exposure (Gateway + CiliumNetworkPolicy fromCIDR / LB source-ranges) is a
# separate concern — see docs/admin-access.md.
#
# Usage:
#   export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
#   ./scripts/ops/local-admin-portforward.sh           # start all, foreground (Ctrl-C to stop)
#   ./scripts/ops/local-admin-portforward.sh --stop     # kill any running forwards
# ==============================================================================
set -uo pipefail

KUBECONFIG="${KUBECONFIG:-$PWD/infrastructure/opentofu-local/kubeconfig}"
export KUBECONFIG
# Not in /tmp: --stop kills every pid listed here, so the file must not be
# writable (or replaceable by a symlink) by another local user.
# One fixed place, not $XDG_RUNTIME_DIR: cron has none and an SSH session has one, so two lock (or pid) files would let a
# cron run and a manual run go in parallel, and --stop from another environment would not find the pids.
STATE_DIR="${HOME:?}/.cache/openaether"
mkdir -p -m 700 "$STATE_DIR"
PIDFILE="$STATE_DIR/admin-pf.pids"

# name  ns  svc  localport:remoteport
TARGETS=(
  "openbao-root    foundation-pki-root     svc/openbao-pki-root-ui  8210:8200"
  "openbao-work    foundation-vault        svc/openbao-ui           8220:8200"
  "flux          management-gitops       svc/flux-server        8080:443"
  "grafana         services-observability  svc/grafana              3000:3000"
)

stop() {
  if [[ -f "$PIDFILE" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDFILE"
    rm -f "$PIDFILE"
    echo "stopped port-forwards"
  else
    pkill -f "kubectl.*port-forward.*(openbao|flux|grafana)" 2>/dev/null || true
    echo "no pidfile; best-effort pkill done"
  fi
}

[[ "${1:-}" == "--stop" ]] && { stop; exit 0; }

: > "$PIDFILE"
echo "Starting admin GUI port-forwards (127.0.0.1 only)…"
for t in "${TARGETS[@]}"; do
  read -r name ns svc map <<< "$t"
  if ! kubectl get "$svc" -n "$ns" >/dev/null 2>&1; then
    echo "  ⚠ $name: $svc not found in $ns — skipped (not deployed)"
    continue
  fi
  kubectl port-forward -n "$ns" "$svc" "$map" --address 127.0.0.1 >/dev/null 2>&1 &
  echo "$!" >> "$PIDFILE"
  echo "  ✓ $name → http://127.0.0.1:${map%%:*}   ($ns/$svc)"
done

cat <<EOF

  ─────────────────────────────────────────────
  OpenBao root      → http://127.0.0.1:8210/ui
  OpenBao workload  → http://127.0.0.1:8220/ui
  Flux            → https://127.0.0.1:8080
  Grafana           → http://127.0.0.1:3000   (if deployed)
  ─────────────────────────────────────────────
  OpenBao login: token (root token in Secret openbao-{root,workload}-recovery).
  Flux admin pw:
    kubectl -n management-gitops get secret flux-initial-admin-secret \\
      -o jsonpath='{.data.password}' | base64 -d; echo
  ─────────────────────────────────────────────
  Stop: ./scripts/ops/local-admin-portforward.sh --stop
EOF

# Keep forwards alive in foreground unless backgrounded by caller.
wait
