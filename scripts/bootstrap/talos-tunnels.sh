#!/usr/bin/env bash
# OpenAether — Talos API SSH tunnels (Phase 2 bootstrap)
#
# Talos nodes have no SSH, so the bastion relays the TCP to their API (50000).
# One tunnel per node, IPs read from the tofu state: control planes on
# localhost 50000+i, workers on 50100+i (local Docker uses 52000+ to avoid
# clashes). Detached so they survive the `tofu apply` that follows; PIDs tracked
# for a clean teardown. What each ssh says is appended to .talos-tunnel-<port>.log
# beside the pidfile (gitignored: it names the bastion); `open` and `ensure` quote it.
#
# TALOS_TUNNEL_OFFSET shifts that whole block, so a second cluster can be
# bootstrapped from the same workstation instead of colliding on the ports —
# see oa_tunnel_offset() in scripts/lib/common.sh.
#
# Usage:
#   SSH_KEY=~/.ssh/mykey ./scripts/bootstrap/talos-tunnels.sh open|close [tofu_dir]
#
#   open-direct --bastion <ip> --user <user> --cps <ip,…> [--workers <ip,…>]
#     EXPERIMENTAL, for the single-apply path (var.auto_tunnels): takes IPs as
#     arguments because there is no state to read yet. Never exercised for real.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ACTION="${1:-open}"
# Absolute path to this script: `ensure` re-execs it after cd-ing elsewhere.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
KEY="${KEY/#\~/$HOME}"

OFFSET="$(oa_tunnel_offset)" || exit 1
CP_BASE=$((50000 + OFFSET))
WK_BASE=$((50100 + OFFSET))
API_PORT=$((6443 + OFFSET))

# The one place a tunnel is started. Its ssh output is APPENDED to a per-port log (never truncated: concurrent
# opens share it), because the last lines are the only record of how a tunnel ended (#65); the marker line tells
# one generation from the next. Uses KEY BASTION BUSER BASTION_KH LOG_PREFIX.
spawn_tunnel() { # <pidfile> <local-port> <host:port behind the bastion>
  local log="${LOG_PREFIX}${2}.log"
  printf '%s spawn :%s\n' "$(date '+%F %T')" "$2" >>"$log"
  nohup ssh -o LogLevel=VERBOSE -o UserKnownHostsFile="$BASTION_KH" -o StrictHostKeyChecking=accept-new \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -o TCPKeepAlive=yes \
    -i "$KEY" -N -L "$2:$3" "${BUSER}@${BASTION}" >>"$log" 2>&1 &
  echo $! >>"$1"
}

# What ssh last wrote for a port. It says how the process ended, not who asked it to: a bastion-side close
# ends with the same "Transferred:" lines as a TERM.
log_tail() { # <local-port>
  local l="${LOG_PREFIX}${1}.log"
  [[ -s "$l" ]] || { echo "no transcript at $l"; return; }
  echo "log, last written $(date -r "$l" '+%F %T' 2>/dev/null), ends: $(tail -n3 "$l" | paste -sd'|' -)"
}

if [[ "$ACTION" == "open-direct" ]]; then
  shift
  BASTION=""; BUSER="root"; CPS_CSV=""; WKS_CSV=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bastion) BASTION="$2"; shift 2 ;;
      --user) BUSER="$2"; shift 2 ;;
      --cps) CPS_CSV="$2"; shift 2 ;;
      --workers) WKS_CSV="$2"; shift 2 ;;
      --key) KEY="$2"; shift 2 ;;
      *) echo "✗ open-direct: unknown argument $1"; exit 1 ;;
    esac
  done
  KEY="${KEY/#\~/$HOME}"
  [[ -n "$BASTION" ]] || { echo "✗ open-direct requires --bastion <ip>"; exit 1; }
  command -v nc >/dev/null 2>&1 || { echo "✗ nc is required"; exit 1; }
  [[ -f "$KEY" ]] || { echo "✗ SSH key not found: $KEY (set --key or SSH_KEY=/path/to/key)"; exit 1; }

  # Runs as a local-exec provisioner with cwd = the cluster root (Terraform's
  # own working directory) — a plain relative pidfile name is stable there,
  # same convention as the state-driven `open` path's ${TOFU_DIR}-relative one.
  DIRECT_PIDFILE=".talos-tunnels-direct.pids"
  if [[ -f "$DIRECT_PIDFILE" ]]; then
    while read -r pid; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done <"$DIRECT_PIDFILE"
  fi
  : >"$DIRECT_PIDFILE"

  # Dedicated known_hosts, reset per run — see the state-driven path below for why
  # ssh-keygen -R is not enough (reused bastion IP + hashed entries).
  BASTION_KH=".talos-bastion-known-hosts"
  : >"$BASTION_KH"

  IFS=',' read -ra CPS <<<"$CPS_CSV"
  IFS=',' read -ra WKS <<<"${WKS_CSV:-}"

  LOG_PREFIX=".talos-tunnel-direct-"
  open_direct_one() { spawn_tunnel "$DIRECT_PIDFILE" "$1" "$2:50000"; } # localport nodeip

  echo "▶ [open-direct] opening tunnels via ${BUSER}@${BASTION} (key: $KEY)"
  i=0; for ip in "${CPS[@]}"; do [[ -n "$ip" ]] && open_direct_one "$((CP_BASE + i))" "$ip"; i=$((i + 1)); done
  i=0; for ip in "${WKS[@]}"; do [[ -n "$ip" ]] && open_direct_one "$((WK_BASE + i))" "$ip"; i=$((i + 1)); done

  sleep 4
  ports=()
  for j in "${!CPS[@]}"; do ports+=("$((CP_BASE + j))"); done
  [[ -n "${WKS_CSV:-}" ]] && for j in "${!WKS[@]}"; do ports+=("$((WK_BASE + j))"); done
  ok=0
  for p in "${ports[@]}"; do nc -z 127.0.0.1 "$p" 2>/dev/null && ok=$((ok + 1)); done
  echo "✓ [open-direct] ${ok}/${#ports[@]} tunnels up"
  [[ "$ok" -eq "${#ports[@]}" ]] || { echo "⚠ some tunnels failed — see 'open' path's troubleshooting notes"; exit 1; }
  exit 0
fi

# Absolute, because `ensure` re-execs this script AFTER the `cd "$TOFU_DIR"`
# below — and because PIDFILE is otherwise resolved a second time after that cd,
# so the pidfile lands somewhere that does not exist while the run still reports
# "✓ N/N tunnels up" with nothing tracked.
TOFU_DIR="$(cd "${2:-infrastructure/opentofu/cluster}" 2>/dev/null && pwd)" ||
  { echo "✗ no such directory: ${2:-infrastructure/opentofu/cluster}"; exit 1; }
PIDFILE="${TOFU_DIR}/.talos-tunnels.pids"
LOG_PREFIX="${TOFU_DIR}/.talos-tunnel-"

close_tunnels() {
  # Primary: kill tracked PIDs from pidfile
  if [[ -f "$PIDFILE" ]]; then
    while read -r pid; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done <"$PIDFILE"
    rm -f "$PIDFILE"
  fi
  # Fallback: kill orphaned tunnels from failed/interrupted runs. Scoped to THIS
  # offset's block — a blanket pkill on 5[01][0-9][0-9][0-9] would tear down the
  # tunnels of another cluster being brought up beside this one, which is the
  # whole thing TALOS_TUNNEL_OFFSET exists to allow.
  local lo=$CP_BASE hi=$((WK_BASE + 99)) pid cmd port
  while read -r pid cmd; do
    [[ "$cmd" == ssh\ * ]] || continue
    port="${cmd#*-L }"; port="${port%%:*}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    if (( port >= lo && port <= hi )) || (( port == API_PORT )); then
      kill "$pid" 2>/dev/null || true
    fi
  done < <(pgrep -a -f 'ssh .*-L [0-9]+:' 2>/dev/null || true)
}

# RFC1918 check (k8s_lb_mode = "vip": k8s_lb_ip is a private address instead of
# a public managed LB, so the API needs its own tunnel through the bastion).
is_private_ip() {
  [[ "$1" =~ ^10\. ]] && return 0
  [[ "$1" =~ ^192\.168\. ]] && return 0
  [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

if [[ "$ACTION" == "close" ]]; then
  close_tunnels
  echo "✓ Talos tunnels closed"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "✗ nc is required"; exit 1; }
[[ -f "$KEY" ]] || { echo "✗ SSH key not found: $KEY (set SSH_KEY=/path/to/key)"; exit 1; }

cd "$TOFU_DIR"

# Read all outputs once and parse with jq, so an empty state (infra not deployed)
# fails clearly instead of capturing tofu's "No outputs found" warning.
OUTPUTS="$(tofu output -json 2>/dev/null || echo '{}')"
BASTION="$(jq -r '.bastion_ip.value // empty' <<<"$OUTPUTS")"
if [[ -z "$BASTION" || "$BASTION" == "<bastion-ip>" ]]; then
  echo "✗ No bastion_ip in the state — deploy the infrastructure first:"
  echo "    task infra-apply ROLE=management PROVIDER=... APPROVE=auto   (or ROLE=workload)"
  exit 1
fi
BUSER="$(jq -r '.bastion_user.value // "root"' <<<"$OUTPUTS")"
mapfile -t CPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WKS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
K8S_LB_IP="$(jq -r '.k8s_lb_ip.value // empty' <<<"$OUTPUTS")"

# ── ensure: the idempotent front door ───────────────────────────────────────
# `open` is DESTRUCTIVE — close_tunnels sweeps the whole port block before
# rebuilding — which is right for bootstrap-phase2 and rolling-replace, where
# node IPs may have changed, and wrong for anything that just needs the tunnels
# to be there. Callers that only need them working call `ensure`: it touches
# nothing when the set answers, and rebuilds only what is actually broken.
#
# It asks for a TLS answer, not a bound port. `ssh -L` keeps listening after the
# connection through it dies, so `nc -z` would skip exactly the rebuild it
# needed. scripts/dev/test-endpoint-probe.sh measures that difference.
if [[ "$ACTION" == "ensure" ]]; then
  BAD=()
  probe_all() { # fills BAD with the ports that do not answer
    local i p
    BAD=()
    for i in "${!CPS[@]}"; do p=$((CP_BASE + i)); oa_talos_endpoint_ok 127.0.0.1 "$p" || BAD+=("$p"); done
    for i in "${!WKS[@]}"; do p=$((WK_BASE + i)); oa_talos_endpoint_ok 127.0.0.1 "$p" || BAD+=("$p"); done
  }
  TOTAL=$(( ${#CPS[@]} + ${#WKS[@]} ))
  probe_all
  if [[ ${#BAD[@]} -eq 0 ]]; then
    echo "✓ ${TOTAL}/${TOTAL} Talos tunnels answering — leaving them alone"
    exit 0
  fi
  echo "▶ ${#BAD[@]}/${TOTAL} Talos tunnel(s) not answering (${BAD[*]}) — rebuilding" >&2
  for p in "${BAD[@]}"; do
    pgrep -f "[s]sh .*-L ${p}:" >/dev/null && st="ssh running, the node behind it is not answering" || st="ssh EXITED"
    echo "    :${p}  ${st}; $(log_tail "$p")" >&2
  done
  "$SELF" open "$TOFU_DIR" || exit 1
  for _ in 1 2 3 4 5 6; do
    probe_all
    [[ ${#BAD[@]} -eq 0 ]] && { echo "✓ Talos tunnels rebuilt and answering"; exit 0; }
    sleep 5
  done
  echo "✗ still nothing answering on 127.0.0.1: ${BAD[*]}" >&2
  echo "  A port can be BOUND while the node behind it is down — this probe wants a" >&2
  echo "  TLS answer, not a listener. Check the nodes before blaming the tunnels." >&2
  exit 1
fi

close_tunnels # drop any stale tunnels (old IPs) before reopening
: >"$PIDFILE"

# The bastion is re-created by `tofu apply` and its public IP is frequently
# REUSED across clusters, so its host key legitimately changes between deploys.
# `ssh-keygen -R` does NOT reliably drop *hashed* known_hosts entries (HashKnownHosts),
# so accept-new would then refuse every tunnel with a host-key mismatch — which
# surfaces as a partial/zero "N/M tunnels up" and a failed bootstrap-phase2. Pin
# the bastion in a DEDICATED known_hosts file, reset each run: this keeps
# in-session host-key pinning without ever carrying a stale key across redeploys.
BASTION_KH=".talos-bastion-known-hosts"
: >"$BASTION_KH"

open_one() { spawn_tunnel "$PIDFILE" "$1" "$2:50000"; } # localport nodeip

# The bastion has often just been created: its cloud-init installs packages and
# only reloads sshd (AuthorizedKeysFile + AllowGroups) at the end. Attempting
# the tunnels before that gives "Permission denied (publickey)" and 0/N tunnels
# — seen on all three providers. So we wait for the bastion to accept the key.
echo "▶ Waiting for bastion ${BUSER}@${BASTION} to accept SSH (cloud-init)…"
BASTION_WAIT="${BASTION_WAIT:-300}"
__deadline=$(( SECONDS + BASTION_WAIT ))
until ssh -o UserKnownHostsFile="$BASTION_KH" -o StrictHostKeyChecking=accept-new \
          -o BatchMode=yes -o ConnectTimeout=8 -i "$KEY" \
          "${BUSER}@${BASTION}" true 2>/dev/null; do
  if (( SECONDS >= __deadline )); then
    echo "⚠ bastion still unreachable after ${BASTION_WAIT}s — trying anyway."
    echo "  (check: cloud-init finished? right key? admin_ip up to date?)"
    break
  fi
  sleep 10
done

# WAIT for the ports close_tunnels just freed. `kill` is asynchronous: the old
# ssh has not released its listener when the new one tries to bind, so the new
# one dies on ExitOnForwardFailure while the old one is still listening — and the
# `nc -z` count below then reads that dying forward as "up". A Scaleway deploy
# reported 4/6 that way on 2026-08-14 and failed with a healthy bastion.
# It also catches someone else holding this offset's block — that one will not
# clear, and says so.
__ports=()
for __i in "${!CPS[@]}"; do __ports+=("$((CP_BASE + __i))"); done
for __i in "${!WKS[@]}"; do __ports+=("$((WK_BASE + __i))"); done
for _ in $(seq 1 20); do
  __busy=()
  for __p in "${__ports[@]}"; do nc -z 127.0.0.1 "$__p" 2>/dev/null && __busy+=("$__p"); done
  [[ ${#__busy[@]} -eq 0 ]] && break
  sleep 1
done
if [[ ${#__busy[@]} -gt 0 ]]; then
  echo "✗ ports still in use after 20s: ${__busy[*]}" >&2
  echo "  Something outside this run holds them — another cluster's tunnels on" >&2
  echo "  this machine, most likely. Close them:  $0 close" >&2
  echo "  Or give this cluster its own block: TALOS_TUNNEL_OFFSET=200 (400, …)" >&2
  exit 1
fi

echo "▶ Opening tunnels via ${BUSER}@${BASTION} (key: $KEY)"
i=0; for ip in "${CPS[@]}"; do open_one "$((CP_BASE + i))" "$ip"; i=$((i + 1)); done
i=0; for ip in "${WKS[@]}"; do open_one "$((WK_BASE + i))" "$ip"; i=$((i + 1)); done

# k8s_lb_mode = "vip": k8s_lb_ip is a private Talos VIP, not a public managed
# LB — open a dedicated tunnel to reach the API from the operator's machine.
K8S_API_TUNNELED=false
if [[ -n "$K8S_LB_IP" ]] && is_private_ip "$K8S_LB_IP"; then
  spawn_tunnel "$PIDFILE" "$API_PORT" "${K8S_LB_IP}:6443"
  K8S_API_TUNNELED=true
fi

# Give SSH a moment to establish the forwards, then verify.
sleep 4
ports=()
for j in "${!CPS[@]}"; do ports+=("$((CP_BASE + j))"); done
for j in "${!WKS[@]}"; do ports+=("$((WK_BASE + j))"); done
[[ "$K8S_API_TUNNELED" == true ]] && ports+=("$API_PORT")
ok=0; down=()
for p in "${ports[@]}"; do nc -z 127.0.0.1 "$p" 2>/dev/null && ok=$((ok + 1)) || down+=("$p"); done

echo "✓ ${ok}/${#ports[@]} tunnels up — CPs on ${CP_BASE}+i, workers on ${WK_BASE}+i"
if [[ "$K8S_API_TUNNELED" == true ]]; then
  echo "  k8s_lb_mode=vip: API tunneled — kubectl --server https://127.0.0.1:${API_PORT} get nodes"
fi
if [[ "$ok" -ne "${#ports[@]}" ]]; then
  echo "⚠ some tunnels failed. Check: SSH_KEY is correct, the bastion is reachable"
  echo "  (ssh -i $KEY ${BUSER}@${BASTION}), and its routing fix has converged."
  for p in "${down[@]}"; do echo "    :${p}  $(log_tail "$p")"; done
  exit 1
fi
