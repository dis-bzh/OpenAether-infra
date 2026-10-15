#!/usr/bin/env bash
# ==============================================================================
# exposure-scan.sh — what do the PUBLIC addresses actually answer on?
#
# The plan-time tests pin the security-group port lists; this asks the network. Run it from OUTSIDE the
# cluster (an operator laptop, a CI runner) and it probes each public address over TCP:
#
#   bastion   22 open from an allowed source          (admin_ip)
#   api LB    6443 open from an allowed source        (admin_ip)
#   app LB    80 and 443 open from anywhere           (the Gateway; absent when deploy_app_lb=false)
#   everything else on the list below CLOSED, on every address.
#
# --from denied: the run is made from a source that is NOT in admin_ip (a cloud shell, a phone hotspot),
# and 22 and 6443 must be CLOSED too. That is the half that proves "to the right sources".
#
# Read-only: opens TCP connections, changes nothing. TCP only; UDP (WireGuard 51871) is not probed.
#
# Usage:
#   exposure-scan.sh <provider> [role]                      addresses from `tofu output` (backend initialised)
#   exposure-scan.sh --bastion IP [--api-lb IP] [--app-lb IP] [--from allowed|denied] [--full]
#   task cluster-exposure PROVIDER=…                        the first form
#
# --full adds an nmap top-1000 sweep (needs nmap) and fails on any open port outside the expected set.
# OA_PROBE=<exe> replaces the TCP probe (called as: exe HOST PORT; exit 0 = open) — the test harness uses it.
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TIMEOUT="${OA_SCAN_TIMEOUT:-4}"
# Ports that must never answer from the Internet: admin and data-plane services of a Talos/Kubernetes node.
# 22/6443/80/443 are judged per address below, so they are not in this list.
SENSITIVE_PORTS="${OA_SCAN_SENSITIVE:-21 23 25 111 2379 2380 2381 3306 4240 5432 6379 7445 8200 8201 8443 9100 10250 10256 30080 30443 50000 50001}"

PASS=0; FAIL=0; UNKNOWN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
unk()  { printf '  \033[33m?\033[0m %s\n' "$*"; UNKNOWN=$((UNKNOWN + 1)); }

probe() { # <host> <port> — 0 when a TCP connection is accepted
  if [ -n "${OA_PROBE:-}" ]; then "$OA_PROBE" "$1" "$2"; return; fi
  timeout "$TIMEOUT" bash -c ">/dev/tcp/$1/$2" 2>/dev/null
}

# <label> <host> <expected-open ports> — every expected port must answer, every other probed port must not.
scan_target() {
  local label="$1" host="$2" want="$3" p bad_open="" bad_closed=""
  for p in $want; do probe "$host" "$p" || bad_closed="$bad_closed $p"; done
  for p in $SENSITIVE_PORTS 22 6443 80 443; do
    case " $want " in *" $p "*) continue ;; esac
    if probe "$host" "$p"; then bad_open="$bad_open $p"; fi
  done
  [ -z "$bad_closed" ] || bad "${label}: expected open but unreachable:${bad_closed} (wrong source, or the rule is missing)"
  [ -z "$bad_open" ] || bad "${label}: reachable but must not be:${bad_open}"
  if [ -z "$bad_closed$bad_open" ]; then
    ok "${label}: ${want:-no port} open, nothing else of $(wc -w <<<"$SENSITIVE_PORTS 22 6443 80 443") probed ports answers"
  fi
}

full_sweep() { # <label> <host> <expected-open ports>
  local label="$1" host="$2" want="$3" open p extra=""
  command -v nmap >/dev/null 2>&1 || { unk "${label}: --full asked for, nmap is not installed"; return; }
  open="$(nmap -Pn -n --top-ports 1000 --open -oG - "$host" 2>/dev/null | grep -oE '[0-9]+/open/tcp' | cut -d/ -f1)"
  for p in $open; do case " $want " in *" $p "*) ;; *) extra="$extra $p" ;; esac; done
  if [ -n "$extra" ]; then bad "${label}: nmap top-1000 finds open:${extra}"; else ok "${label}: nmap top-1000 finds only the expected ports"; fi
}

usable() { case "${1:-}" in "" | N/A | null) return 1 ;; *) return 0 ;; esac; }

BASTION="" API_LB="" APP_LB="" FROM=allowed FULL=0 PROVIDER="" ROLE=management
while [ $# -gt 0 ]; do
  case "$1" in
    --bastion) BASTION="${2:?}"; shift 2 ;;
    --api-lb)  API_LB="${2:?}"; shift 2 ;;
    --app-lb)  APP_LB="${2:?}"; shift 2 ;;
    --from)    FROM="${2:?}"; shift 2 ;;
    --full)    FULL=1; shift ;;
    -h | --help) sed -n 2,28p "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) if [ -z "$PROVIDER" ]; then PROVIDER="$1"; else ROLE="$1"; fi; shift ;;
  esac
done
case "$FROM" in allowed | denied) ;; *) echo "--from is allowed or denied" >&2; exit 2 ;; esac

if [ -n "$PROVIDER" ]; then
  dir="$ROOT/infrastructure/opentofu/cluster"
  out() { (cd "$dir" && timeout 60 tofu output -raw "$1" 2>/dev/null); }
  BASTION="$(out bastion_ip)" || BASTION=""
  API_LB="$(out k8s_lb_ip)" || API_LB=""
  APP_LB="$(out app_lb_ip)" || APP_LB=""
  [ -n "$BASTION$API_LB" ] || { echo "✗ could not read bastion_ip/k8s_lb_ip from the state of ${PROVIDER}/${ROLE} (backend initialised? credentials exported?)" >&2; exit 2; }
fi
[ -n "$BASTION$API_LB$APP_LB" ] || { echo "usage: $0 <provider> [role] | --bastion IP [--api-lb IP] [--app-lb IP]" >&2; exit 2; }

echo "▶ Exposure scan (source: ${FROM} on the admin_ip allowlist)"
if [ "$FROM" = allowed ]; then admin_open_bastion="22"; admin_open_api="6443"; else admin_open_bastion=""; admin_open_api=""; fi
if usable "$BASTION"; then
  scan_target "bastion" "$BASTION" "$admin_open_bastion"
  [ "$FULL" = 1 ] && full_sweep "bastion" "$BASTION" "$admin_open_bastion"
else unk "no bastion address — it is UNCHECKED"; fi
if usable "$API_LB"; then
  scan_target "api LB" "$API_LB" "$admin_open_api"
  [ "$FULL" = 1 ] && full_sweep "api LB" "$API_LB" "$admin_open_api"
else unk "no API load balancer address — it is UNCHECKED"; fi
if usable "$APP_LB"; then
  scan_target "app LB" "$APP_LB" "80 443"
  [ "$FULL" = 1 ] && full_sweep "app LB" "$APP_LB" "80 443"
else printf '  ~ no application load balancer address (deploy_app_lb=false): nothing to probe\n'; fi

echo
printf '%s passed, %s failed, %s could not be checked\n' "$PASS" "$FAIL" "$UNKNOWN"
[ "$FAIL" -eq 0 ] && [ "$UNKNOWN" -eq 0 ]
