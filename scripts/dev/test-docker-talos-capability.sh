#!/usr/bin/env bash
# check-docker-talos-capability.sh against a stubbed capsh — never a real
# container, since the whole point is to answer this WITHOUT spending 90s on
# one. See infrastructure/opentofu-local/README.md, "Host requirement:
# CAP_SYS_RESOURCE" — the exact defect this catches (#54).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/dev/check-docker-talos-capability.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

stub_capsh() { # <bounding-set-line>
  cat >"$STUB_DIR/capsh" <<EOF
#!/usr/bin/env bash
[ "\$1" = "--print" ] || exit 1
printf '%s\n' '$1'
# The negation form capsh prints alongside the bounding set — must not make a
# bare grep for the capability name see it as present.
printf '%s\n' 'Current: cap_sys_resource-ep'
EOF
  chmod +x "$STUB_DIR/capsh"
}

echo "=== capability present: silent, exit 0 ==="
stub_capsh "Bounding set =cap_chown,cap_sys_resource,cap_setuid"
out="$(PATH="$STUB_DIR:$PATH" "$CHECK" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc, want 0"
[ -z "$out" ] && ok "nothing printed (fail-open must stay silent on success)" || bad "printed: $out"

echo "=== capability missing: refuses in well under 90s, names the cause ==="
stub_capsh "Bounding set =cap_chown,cap_setuid"
start=$(date +%s)
out="$(PATH="$STUB_DIR:$PATH" "$CHECK" 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] && ok "exit 1" || bad "exit $rc, want 1"
[ "$elapsed" -lt 5 ] && ok "refused in ${elapsed}s, not 90" || bad "took ${elapsed}s — the whole point was not to wait"
grep -q "CAP_SYS_RESOURCE" <<<"$out" && ok "names the actual capability" || bad "message doesn't name it: $out"

echo "=== the negation forms in capsh's own output must not fool a bare grep ==="
# Reproduces the trap the real check's comment warns about: capsh names
# cap_sys_resource three times when it is ABSENT (twice as a negation, once in
# a Current: line) and only the Bounding set line is the real answer.
rm -f "$STUB_DIR/capsh"
cat >"$STUB_DIR/capsh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--print" ] || exit 1
cat <<'INNER'
Current: cap_chown,cap_setuid cap_sys_resource-ep
Bounding set =cap_chown,cap_setuid
Securebits: 00/0x0/1'b0
 secure-noroot: no (unlocked)
uid=0(root)
gid=0(root)
groups=
Guessed mode: UNCERTAIN (0)
INNER
EOF
chmod +x "$STUB_DIR/capsh"
out="$(PATH="$STUB_DIR:$PATH" "$CHECK" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "still refuses — a naive whole-output grep would have missed this" \
  || bad "exit $rc, want 1 (the negation form fooled it)"

echo "=== capsh absent: cannot tell, must not block a working setup ==="
# capsh lives in /usr/sbin and /sbin on this host — strip exactly those from
# PATH rather than replacing it wholesale, so env/bash/grep stay reachable.
NO_CAPSH_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE '^/(usr/)?sbin$' | paste -sd: -)"
out="$(PATH="$NO_CAPSH_PATH" "$CHECK" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "fails open when capsh is unavailable" || bad "exit $rc, want 0"

echo "=== wired into test-talos-local.sh's own preflight, not just documented ==="
if grep -q 'check-docker-talos-capability.sh' "$ROOT/scripts/dev/test-talos-local.sh"; then
  ok "test-talos-local.sh calls this check before its 90s etcd-quorum wait"
else
  bad "test-talos-local.sh does not call check-docker-talos-capability.sh"
fi

echo "=== reproduced against THIS host's real capsh, not just the stub ==="
# This sandbox is documented (infrastructure/opentofu-local/README.md) as
# missing the capability — the same claim task local-up and this session's own
# environment already make. If that ever stops being true here, this harness
# should say so rather than silently stop proving anything.
if command -v capsh >/dev/null 2>&1; then
  real_out="$("$CHECK" 2>&1)"; real_rc=$?
  if capsh --print 2>/dev/null | grep '^Bounding set' | grep -q cap_sys_resource; then
    [ "$real_rc" -eq 0 ] && ok "this host HAS the capability — check agrees" \
      || bad "this host has it but the real check said no"
  else
    [ "$real_rc" -eq 1 ] && ok "this host is missing it (as documented) — check agrees, in real time" \
      || bad "this host is missing it but the real check said yes"
  fi
else
  echo "  (no capsh on this host — real-environment case not exercised)"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
