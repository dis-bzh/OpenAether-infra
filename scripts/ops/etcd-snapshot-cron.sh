#!/usr/bin/env bash
# OpenAether — cron wrapper for the etcd snapshot
#
# `task etcd-snapshot` works by hand but not under cron: minimal PATH (tools are
# split between /usr/local/bin and /snap/bin), no inherited credentials, and it
# opens SSH tunnels without closing them (fine interactively, they would pile up
# under cron). This wrapper fixes the three, plus a flock against overlap.
#
# Usage: etcd-snapshot-cron.sh <provider> [ssh-key]
#   Crontab needs an ABSOLUTE path; cron mails the output = poor man's alerting.
#     40 3 * * * <repo>/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/<key> >> <log> 2>&1
#   Env: OPENAETHER_ENV_FILE (default <repo>/.env.sh), KEEP (default 30).
#
# ⚠️ RTO shortcut, not the reference backup: Flux rebuilds cluster content. This
# covers what lives ONLY in etcd (Secrets written by Jobs, PVC bindings…).
set -euo pipefail

PROVIDER="${1:?usage: etcd-snapshot-cron.sh <scaleway|ovh|outscale|proxmox> [ssh-key]}"
SSH_KEY="${2:-$HOME/.ssh/id_ed25519}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${OPENAETHER_ENV_FILE:-$ROOT/.env.sh}"
KEEP="${KEEP:-30}"

log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# 1. Full PATH — see reason 1 above.
export PATH="/usr/local/bin:/snap/bin:$HOME/.local/bin:$PATH"

# 2. Environnement (credentials S3/provider + TF_VAR_encryption_passphrase).
if [ -r "$ENV_FILE" ]; then
  # Warn, never refuse: a cron that starts failing overnight is worse than a mode to fix. The file holds the cloud and S3 keys.
  case "$(stat -c %a "$ENV_FILE" 2>/dev/null)" in ""|?00) ;; *) log "⚠ $ENV_FILE is readable by others (chmod 600 it)" ;; esac
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  log "✗ environment file not found: $ENV_FILE"
  log "  (set it through OPENAETHER_ENV_FILE if the repo lives elsewhere)"
  exit 1
fi

for bin in task tofu talosctl aws gpg; do
  command -v "$bin" >/dev/null 2>&1 || { log "✗ outil absent du PATH : $bin"; exit 1; }
done

# 3. Close the tunnels whatever happens.
cleanup() {
  local rc=$?
  "$ROOT/scripts/bootstrap/talos-tunnels.sh" close "$ROOT/infrastructure/opentofu/cluster" >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then log "✓ etcd snapshot complete ($PROVIDER)"; else log "✗ failed (code $rc) — etcd snapshot $PROVIDER"; fi
  exit "$rc"
}
trap cleanup EXIT

# 4. Lock: never two runs in parallel.
LOCK="/tmp/openaether-etcd-snapshot-${PROVIDER}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "⚠ a run is already in progress ($LOCK) — aborting"
  exit 0
fi

log "▶ snapshot etcd — provider=$PROVIDER keep=$KEEP"
cd "$ROOT"
KEEP="$KEEP" task etcd-snapshot PROVIDER="$PROVIDER" KEY="$SSH_KEY"
