#!/usr/bin/env bash
# ==============================================================================
# bastion-harden-check.sh — Post-deploy hardening validation for OpenAether bastion
#
# Usage:
#   ./scripts/ops/bastion-harden-check.sh <bastion_ip> <bastion_user> <ssh_key>
#
# Checks (in order):
#   1. SSH tunnel non-regression: 6443 + 50000 reachable via bastion
#   2. Root login rejected
#   3. sshd: PermitRootLogin no + PasswordAuthentication no
#   4. nftables egress DROP. BASTION_EGRESS=legacy (default, what is deployed unless bastion_internet_egress is set):
#      an arbitrary port on the Internet must time out (80/443 are open by design there). BASTION_EGRESS=closed:
#      80, 443 and a second public address must time out, 8200 to the node too, nc/curl/tcpdump must be absent and
#      the update timers off
#   5. nftables egress ALLOW: nc to cluster private on 6443 must pass (if node IP given)
#   6. ss -tlnp: only :22 listening externally
#   7. bastion-admins group exists and user is a member
#   8. SSH-CA placeholder files present
#   9. (BASTION_BASELINE=1) the opt-in bastion_baseline: sshd directives, sysctl, auditd, journald,
#      mounts, ownership of authorized_keys.d, sudo mode, umask, the key fingerprint in the login log.
#      BASTION_AUDIT=0 for a bastion with bastion_baseline.audit_logging=false (closed egress forces it): auditd
#      is then not asserted, because it is not installed. The persistent journal, the adm / systemd-journal
#      groups and the login line are still asserted: they need no package and are there with or without audit.
#
# Egress probes use bash's /dev/tcp, not nc: the baseline no longer installs netcat.
#
# Host key: never StrictHostKeyChecking=no. The pinned file (BASTION_KNOWN_HOSTS, default .talos-bastion-known-hosts,
# the one talos-tunnels.sh keeps with OA_BASTION_PIN_HOSTKEY) is used strictly when it holds this bastion; otherwise
# a private temporary file takes the first key (accept-new), its fingerprint is printed and, with
# OA_BASTION_HOSTKEY_FP=SHA256:..., compared with the one read out of band: a mismatch FAILS the run.
# ==============================================================================

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/bastion-hostkey.sh"

# One TCP attempt from the bastion: prints exit:0 (open), exit:1 (refused) or exit:124 (timed out = dropped).
# \$ and \" are for the REMOTE shell; the host and port are expanded here.
probe_cmd() { printf 'timeout %s bash -c "</dev/tcp/%s/%s" >/dev/null 2>&1; echo exit:$?' "$3" "$1" "$2"; }

BASTION_IP="${1:?Usage: $0 <bastion_ip> <bastion_user> <ssh_key> [node_private_ip]}"
BASTION_USER="${2:?}"
SSH_KEY="${3:?}"
NODE_IP="${4:-}"

OA_KH_TEMP=""; oa_bastion_oneshot_opts "${BASTION_IP}"
trap '[ "${OA_KH_TEMP:-}" = 1 ] && rm -f "${OA_KH}"' EXIT
SSH_OPTS="-i ${SSH_KEY} -o UserKnownHostsFile=${OA_KH} -o StrictHostKeyChecking=${OA_SHKC} -o HashKnownHosts=no -o ConnectTimeout=10 -o BatchMode=yes"
EGRESS_MODE="${BASTION_EGRESS:-legacy}"
case "${EGRESS_MODE}" in legacy|closed) ;; *) echo "BASTION_EGRESS is legacy or closed (got '${EGRESS_MODE}')" >&2; exit 2 ;; esac
SSH_CMD="ssh ${SSH_OPTS} ${BASTION_USER}@${BASTION_IP}"

PASS=0
FAIL=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $*"; }
sep()  { echo ""; echo "=== $* ==="; }

# --------------------------------------------------------------------------
sep "1. SSH connectivity"
# --------------------------------------------------------------------------
if ${SSH_CMD} echo "ssh-ok" 2>/dev/null | grep -q "ssh-ok"; then
  ok "SSH login as ${BASTION_USER}@${BASTION_IP}"
  if [ "${OA_KH_TEMP:-}" = 1 ]; then
    if FPMSG=$(oa_bastion_check_fp "${BASTION_IP}" 2>&1); then info "${FPMSG:-host key recorded}"; else fail "${FPMSG}"; fi
  else
    ok "host key matches the pinned one (${OA_KH})"
  fi
else
  fail "SSH login failed — aborting further checks"
  echo ""
  echo "RESULT: 0 passed, 1 failed — bastion unreachable"
  exit 1
fi

# --------------------------------------------------------------------------
sep "2. Root login rejected"
# --------------------------------------------------------------------------
if ! ssh ${SSH_OPTS} root@"${BASTION_IP}" echo "root-ok" 2>/dev/null | grep -q "root-ok"; then
  ok "Root login rejected (expected)"
else
  fail "Root login SUCCEEDED — PermitRootLogin not effective"
fi

# --------------------------------------------------------------------------
sep "3. sshd config"
# --------------------------------------------------------------------------
# `|| true`: a bastion with bastion_baseline has no sudo for this account and root-only (0600) sshd drop-ins, so the read
# below fails there; under `set -e` that used to END THE WHOLE CHECK in silence after "=== 3" (seen on a real OVH bastion).
SSHD_CONF=$(${SSH_CMD} "sudo sshd -T 2>/dev/null || cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null" || true)

if ! printf '%s' "${SSHD_CONF}" | grep -qiE "^[[:space:]]*permitrootlogin"; then
  # Judge by behaviour instead of by file: root was refused above, and a password must not be offered.
  info "sshd configuration is not readable without root (the baseline removes sudo by design): judged from outside"
  PWOUT=$(ssh ${SSH_OPTS} -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=0 "${BASTION_USER}@${BASTION_IP}" true 2>&1 || true)
  # sshd lists the methods that could still succeed: exactly "(publickey)" when no password or keyboard-interactive is on offer.
  if echo "${PWOUT}" | grep -qiE "Permission denied \(publickey\)"; then
    ok "password authentication is not offered (only publickey)"
  else
    fail "password authentication may be offered: ${PWOUT}"
  fi
else
if echo "${SSHD_CONF}" | grep -qi "permitrootlogin.*no"; then
  ok "PermitRootLogin no"
else
  fail "PermitRootLogin is NOT 'no'"
fi

if echo "${SSHD_CONF}" | grep -qi "passwordauthentication.*no"; then
  ok "PasswordAuthentication no"
else
  fail "PasswordAuthentication is NOT 'no'"
fi

if echo "${SSHD_CONF}" | grep -qi "allowgroups.*bastion-admins"; then
  ok "AllowGroups bastion-admins"
else
  fail "AllowGroups bastion-admins not found"
fi

if echo "${SSHD_CONF}" | grep -qi "allowtcpforwarding.*yes"; then
  ok "AllowTcpForwarding yes"
else
  fail "AllowTcpForwarding not 'yes'"
fi
fi

# --------------------------------------------------------------------------
sep "4. nftables egress DROP (internet) - mode ${EGRESS_MODE}"
# --------------------------------------------------------------------------
# blocked <host> <port>: the probe must not connect (exit:124 = dropped, exit:1 = refused); anything else is an open path.
blocked() { # <label> <host> <port>
  local res; res=$(${SSH_CMD} "$(probe_cmd "$2" "$3" 3)" || true)
  if echo "${res}" | grep -q "exit:1$\|exit:124"; then ok "$1: egress to $2:$3 blocked"; else fail "$1: egress to $2:$3 NOT blocked (${res:-no answer})"; fi
}
if [ "${EGRESS_MODE}" = closed ]; then
  blocked closed 1.1.1.1 80
  blocked closed 1.1.1.1 443
  blocked closed 9.9.9.9 443
  [ -n "${NODE_IP}" ] && blocked closed "${NODE_IP}" 8200
  TOOLS=$(${SSH_CMD} 'for c in nc ncat curl tcpdump; do command -v "$c" >/dev/null 2>&1 && echo "$c"; done; true' || true)
  if [ -z "${TOOLS}" ]; then ok "closed: no nc, curl or tcpdump on the bastion"; else fail "closed: tools still installed: $(echo "${TOOLS}" | tr '\n' ' ')"; fi
  TIMER=$(${SSH_CMD} 'systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null; true' || true)
  if echo "${TIMER}" | grep -q "^enabled"; then fail "closed: apt-daily-upgrade.timer is still enabled (no mirror is reachable: patching is replacing the bastion)"; else ok "closed: the update timer is off (${TIMER:-not present})"; fi
else
  blocked legacy 1.1.1.1 25
  info "legacy mode: 80/443 to the Internet are open by design; bastion_internet_egress = { mode = \"closed\" } closes them (BASTION_EGRESS=closed checks that)"
fi

# --------------------------------------------------------------------------
sep "5. nftables egress ALLOW (cluster private)"
# --------------------------------------------------------------------------
if [ -n "${NODE_IP}" ]; then
  if ${SSH_CMD} "$(probe_cmd "${NODE_IP}" 6443 5)" | grep -q "exit:0"; then
    ok "Egress to ${NODE_IP}:6443 allowed (cluster reachable)"
  else
    fail "Egress to ${NODE_IP}:6443 blocked — check nftables private_cidr + node is up"
  fi
else
  info "Skipping cluster egress test (no NODE_IP provided)"
fi

# --------------------------------------------------------------------------
sep "6. Only :22 listening externally"
# --------------------------------------------------------------------------
LISTENING=$(${SSH_CMD} "ss -tlnp 2>/dev/null | grep LISTEN || netstat -tlnp 2>/dev/null | grep LISTEN || true")
# Loopback listeners (systemd-resolved's stub on 127.0.0.53%lo:53 among them) are not reachable from outside.
NON_SSH=$(echo "${LISTENING}" | grep -v ":22 " | grep -vE "127\.[0-9]+\.[0-9]+\.[0-9]+(%lo)?:" | grep -v "::1:" | grep LISTEN || true)
if [ -z "${NON_SSH}" ]; then
  ok "Only :22 listening on external interfaces"
else
  fail "Unexpected listening ports: ${NON_SSH}"
fi

# --------------------------------------------------------------------------
sep "7. bastion-admins group + user membership"
# --------------------------------------------------------------------------
if ${SSH_CMD} "getent group bastion-admins" | grep -q "bastion-admins"; then
  ok "Group bastion-admins exists"
else
  fail "Group bastion-admins missing"
fi

if ${SSH_CMD} "groups ${BASTION_USER}" | grep -q "bastion-admins"; then
  ok "${BASTION_USER} is member of bastion-admins"
else
  fail "${BASTION_USER} is NOT member of bastion-admins"
fi

# --------------------------------------------------------------------------
sep "8. SSH-CA placeholder files present"
# --------------------------------------------------------------------------
if ${SSH_CMD} "test -f /etc/ssh/trusted_user_ca.pub && echo ok" | grep -q "ok"; then
  ok "/etc/ssh/trusted_user_ca.pub exists (SSH-CA ready)"
else
  fail "/etc/ssh/trusted_user_ca.pub missing"
fi

if ${SSH_CMD} "test -d /etc/ssh/auth_principals && echo ok" | grep -q "ok"; then
  ok "/etc/ssh/auth_principals/ exists (SSH-CA ready)"
else
  fail "/etc/ssh/auth_principals/ missing"
fi

# --------------------------------------------------------------------------
if [ "${BASTION_BASELINE:-0}" = 1 ]; then
sep "9. OS baseline (bastion_baseline.enabled)"
# --------------------------------------------------------------------------
# One round trip, KEY=VALUE per fact, judged here. Nothing needs root: the bastion user has no password to sudo with.
FACTS=$(${SSH_CMD} 'echo "DROPIN=$(cat /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr "\n" ";")"
  echo "PTRACE=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null)"
  echo "SUIDDUMP=$(sysctl -n fs.suid_dumpable 2>/dev/null)"
  echo "PROTREG=$(sysctl -n fs.protected_regular 2>/dev/null)"
  echo "KPTR=$(sysctl -n kernel.kptr_restrict 2>/dev/null)"
  echo "RPF=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
  echo "FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  echo "AKOWN=$(stat -c %U:%a /etc/ssh/authorized_keys.d/$(id -un) 2>/dev/null)"
  echo "VARTMP=$(findmnt -no OPTIONS /var/tmp 2>/dev/null)"
  echo "BOOT=$(stat -c %a /boot 2>/dev/null)"
  echo "SUDOMODE=$(stat -c %a /usr/bin/sudo 2>/dev/null)"
  echo "UMASK=$(bash -lc umask 2>/dev/null)"
  echo "AUDITD=$(systemctl is-active auditd 2>/dev/null)"
  echo "JOURNAL=$([ -d /var/log/journal ] && echo persistent || echo volatile)"
  echo "SUDON=$(sudo -n true >/dev/null 2>&1 && echo yes || echo no)"
  echo "GROUPS=$(id -nG)"
  echo "FP=$(journalctl -u ssh --no-pager --since "-10min" 2>/dev/null | grep -c "Accepted publickey.*SHA256")"' 2>/dev/null || true)
fact() { printf '%s\n' "${FACTS}" | sed -n "s/^$1=//p" | head -1; }
want() { # <label> <fact name> <expected>
  local got; got=$(fact "$2")
  if [ "${got}" = "$3" ]; then ok "$1 (${got})"; else fail "$1: got '${got:-<nothing>}', expected '$3'"; fi
}
for d in "LogLevel VERBOSE" "StrictModes yes" "PermitUserEnvironment no" "PermitEmptyPasswords no" \
         "AllowStreamLocalForwarding no" "GatewayPorts no" "RevokedKeys /etc/ssh/revoked_keys"; do
  if fact DROPIN | grep -q "${d};"; then ok "sshd: ${d}"; else fail "sshd: '${d}' not in sshd_config.d"; fi
done
want "kernel.yama.ptrace_scope" PTRACE 1
want "fs.suid_dumpable" SUIDDUMP 0
if [ -n "$(fact PROTREG)" ]; then want "fs.protected_regular" PROTREG 2; else info "fs.protected_regular is not readable without root (/proc/sys/fs is 0600): not asserted"; fi
want "kernel.kptr_restrict" KPTR 2
want "net.ipv4.conf.all.rp_filter" RPF 1
want "net.ipv4.ip_forward" FWD 0
want "authorized_keys.d file owned by root, mode 644" AKOWN "root:644"
want "/boot is mode 700" BOOT 700
want "/usr/bin/sudo is mode 4750" SUDOMODE 4750
want "login shells umask" UMASK 0077
want "no passwordless sudo for ${BASTION_USER}" SUDON no
if fact GROUPS | grep -qw sudo; then fail "${BASTION_USER} is in the sudo group"; else ok "${BASTION_USER} is not in the sudo group"; fi
if fact VARTMP | grep -q noexec; then ok "/var/tmp is mounted noexec ($(fact VARTMP))"; else fail "/var/tmp is not mounted noexec"; fi
if [ "${BASTION_AUDIT:-1}" = 0 ]; then info "auditd not asserted (BASTION_AUDIT=0: bastion_baseline.audit_logging is off)"; else want "auditd is active" AUDITD active; fi
# The persistent journal and the log-reader groups need no package: the template sets them with or without audit_logging, so they
# are asserted in both modes (that is what lets bastion-logs-pull.sh read the journal). Only auditd depends on BASTION_AUDIT.
want "the journal is persistent" JOURNAL persistent
if fact GROUPS | grep -qw adm && fact GROUPS | grep -qw systemd-journal; then ok "${BASTION_USER} can read the audit and journal logs (adm, systemd-journal)"
else fail "${BASTION_USER} is missing adm or systemd-journal: $(fact GROUPS)"; fi
if [ "$(fact FP)" -ge 1 ] 2>/dev/null; then ok "the login log shows an Accepted publickey line with a SHA256 fingerprint"
else fail "no 'Accepted publickey ... SHA256' line in the ssh journal of the last 10 minutes"; fi
info "not asserted (needs root on the bastion): auditctl -s, nft list ruleset (log rule), the AcceptEnv comment-out"
fi

# --------------------------------------------------------------------------
sep "SUMMARY"
# --------------------------------------------------------------------------
echo ""
echo "  PASSED: ${PASS}"
echo "  FAILED: ${FAIL}"
echo ""
if [ "${FAIL}" -eq 0 ]; then
  echo "  Bastion hardening: ALL CHECKS PASSED"
  exit 0
else
  echo "  Bastion hardening: ${FAIL} CHECK(S) FAILED"
  exit 1
fi
