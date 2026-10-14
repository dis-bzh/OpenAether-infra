#!/usr/bin/env bash
# scripts/ops/bastion-harden-check.sh against a stub ssh: the egress probes (now bash /dev/tcp, not nc), the
# opt-in baseline section (section 9) and what each wrong fact does to the verdict. The stub answers from a table;
# nothing here connects anywhere. SUT overrides the script under test (how the mutants run).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/bastion-harden-check.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="$*"
case "$cmd" in
  *"echo root-ok"*) exit 1 ;;
  *"echo ssh-ok"*|"echo ssh-ok") echo ssh-ok ;;
  *"sshd -T"*) printf 'permitrootlogin no\npasswordauthentication no\nallowgroups bastion-admins\nallowtcpforwarding yes\n' ;;
  *"/dev/tcp/1.1.1.1/80"*) echo "exit:${STUB_EGRESS:-124}" ;;
  *"/dev/tcp/"*) echo "exit:${STUB_NODE:-0}" ;;
  *"ss -tlnp"*) echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*" ;;
  *"getent group"*) echo "bastion-admins:x:1001:bastion" ;;
  *"groups "*) echo "bastion : bastion bastion-admins" ;;
  *"trusted_user_ca.pub"*|*"auth_principals"*) echo ok ;;
  *DROPIN=*) cat "$FACTS" ;;
esac
STUB
chmod +x "$TMP/bin/ssh"

GOOD_FACTS='DROPIN=LogLevel VERBOSE;StrictModes yes;PermitUserEnvironment no;PermitEmptyPasswords no;AllowStreamLocalForwarding no;GatewayPorts no;RevokedKeys /etc/ssh/revoked_keys;
PTRACE=1
SUIDDUMP=0
PROTREG=2
KPTR=2
RPF=1
FWD=0
AKOWN=root:644
VARTMP=rw,nosuid,nodev,noexec,relatime,size=65536k
BOOT=700
SUDOMODE=4750
UMASK=0077
AUDITD=active
JOURNAL=persistent
SUDON=no
GROUPS=bastion bastion-admins sudo adm systemd-journal
FP=3'
export FACTS="$TMP/facts"
run() { # <env assignments…> — sets OUT and RC
  OUT="$(env PATH="$TMP/bin:$PATH" "$@" bash "$SUT" 192.0.2.10 bastion /dev/null 10.0.0.5 2>&1)"; RC=$?
}
# the same facts with one line replaced by "<KEY>=<value>"
facts_with() { printf '%s\n' "$GOOD_FACTS" | sed -E "s|^$1=.*|$1=$2|" >"$FACTS"; }

echo "=== sections 1-8 with the probe that replaced nc ==="
printf '%s\n' "$GOOD_FACTS" >"$FACTS"
run STUB_EGRESS=124
grep -q 'Egress to 1.1.1.1:80 blocked' <<<"$OUT" && grep -q 'Egress to 10.0.0.5:6443 allowed' <<<"$OUT" && [ "$RC" = 0 ] \
  && ok "timed-out egress (exit:124) counts as blocked, the node port as reachable; baseline section skipped" || bad "default run: rc=$RC $OUT"
grep -q '9. OS baseline' <<<"$OUT" && bad "section 9 ran without BASTION_BASELINE=1" || ok "section 9 is opt-in"
run STUB_EGRESS=0
grep -q 'FAIL.*Egress to 1.1.1.1:80 not blocked' <<<"$OUT" && [ "$RC" != 0 ] && ok "an egress probe that connects FAILS the run" || bad "open egress passed: rc=$RC $OUT"
run STUB_NODE=124
grep -q 'FAIL.*10.0.0.5:6443 blocked' <<<"$OUT" && ok "a node port that times out FAILS" || bad "blocked node passed: $OUT"

echo "=== section 9 (BASTION_BASELINE=1) ==="
printf '%s\n' "$GOOD_FACTS" >"$FACTS"
run BASTION_BASELINE=1
[ "$RC" = 0 ] && grep -q '9. OS baseline' <<<"$OUT" && grep -q 'PASSED: 3[0-9]' <<<"$OUT" && ok "good facts: every baseline check passes ($(grep -o 'PASSED: [0-9]*' <<<"$OUT"))" || bad "good facts: rc=$RC $OUT"

mutant() { # <label> <key> <bad value> <expected FAIL text>
  facts_with "$2" "$3"; run BASTION_BASELINE=1
  [ "$RC" != 0 ] && grep -q "FAIL.*$4" <<<"$OUT" && ok "$1 FAILS" || bad "$1 passed or was misreported: rc=$RC $(grep FAIL <<<"$OUT" | head -2)"
}
mutant "ptrace_scope 0"            PTRACE 0 "kernel.yama.ptrace_scope"
mutant "suid_dumpable 2"           SUIDDUMP 2 "fs.suid_dumpable"
mutant "rp_filter 2"               RPF 2 "rp_filter"
mutant "ip_forward 1"              FWD 1 "ip_forward"
mutant "authorized_keys owned by the login user" AKOWN bastion:600 "authorized_keys.d"
mutant "/var/tmp without noexec"   VARTMP rw,relatime "/var/tmp"
mutant "/boot world-readable"      BOOT 755 "/boot"
mutant "sudo at 4755"              SUDOMODE 4755 "sudo is mode"
mutant "umask 0022"                UMASK 0022 "umask"
mutant "auditd inactive"           AUDITD inactive "auditd"
mutant "volatile journal"          JOURNAL volatile "journal"
mutant "passwordless sudo"         SUDON yes "passwordless sudo"
mutant "no adm group"              GROUPS "bastion bastion-admins sudo" "adm or systemd-journal"
mutant "no fingerprint line"       FP 0 "SHA256"
printf '%s\n' "$GOOD_FACTS" | sed 's/AllowStreamLocalForwarding no;//' >"$FACTS"; run BASTION_BASELINE=1
[ "$RC" != 0 ] && grep -q "FAIL.*AllowStreamLocalForwarding no" <<<"$OUT" && ok "a missing sshd directive FAILS, named" || bad "missing directive: rc=$RC $(grep FAIL <<<"$OUT" | head -2)"
: >"$FACTS"; run BASTION_BASELINE=1
[ "$RC" != 0 ] && ok "no facts at all (ssh failed) FAILS rather than passes" || bad "empty facts passed"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
