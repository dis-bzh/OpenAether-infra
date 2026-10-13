#!/usr/bin/env bash
# check-host-overlay-fd.sh against a stubbed docker, uname and kernel probe — never a
# real container, since the whole point is to answer this WITHOUT spending ten minutes
# on one (#291). The last case asks THIS host's real kernel.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/dev/check-host-overlay-fd.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

stub_docker() { # <KernelVersion the daemon reports, or "-" for a daemon that does not answer>
  if [ "$1" = - ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/docker"
  else
    printf '#!/usr/bin/env bash\n[ "$1" = info ] && { echo "%s"; exit 0; }\nexit 1\n' "$1" >"$STUB_DIR/docker"
  fi
  chmod +x "$STUB_DIR/docker"
}
stub_uname() { printf '#!/usr/bin/env bash\n[ "$1" = -r ] && { echo "%s"; exit 0; }\nexec /usr/bin/uname "$@"\n' "$1" >"$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"; }
stub_probe() { printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$STUB_DIR/probe"; chmod +x "$STUB_DIR/probe"; }
run() { PATH="$STUB_DIR:$PATH" OA_OVERLAY_PROBE="$STUB_DIR/probe" "$CHECK" 2>&1; }
run_talos() { TF_VAR_talos_version="$1" run; } # the lane's Talos, as the operator sets it

echo "=== a kernel at or above 6.15: silent, exit 0, the kernel is not even asked ==="
stub_docker "6.17.0-1022-azure"; stub_uname "6.17.0-1022-azure"; stub_probe REFUSED
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "6.17: exit 0, nothing printed" || bad "6.17: rc=$rc out=$out"
stub_docker "7.0.1"; out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "7.0: a higher major is not mistaken for a lower minor" || bad "7.0: rc=$rc out=$out"
stub_docker "6.15.0"; out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "6.15 exactly: accepted" || bad "6.15: rc=$rc out=$out"

echo "=== an older kernel the daemon shares with this machine, which refuses: refuses in seconds, names the cause ==="
stub_docker "6.12.107+deb13-cloud-amd64"; stub_uname "6.12.107+deb13-cloud-amd64"; stub_probe REFUSED
start=$(date +%s); out="$(run)"; rc=$?; elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] && ok "exit 1" || bad "exit $rc, want 1"
[ "$elapsed" -lt 5 ] && ok "answered in ${elapsed}s, not ten minutes" || bad "took ${elapsed}s"
grep -q "FSCONFIG_SET_FD" <<<"$out" && grep -q "6.15" <<<"$out" && grep -q "#291" <<<"$out" && ok "names the call, the kernel it needs and the issue" || bad "message incomplete: $out"
grep -q "6.12.107" <<<"$out" && ok "quotes the kernel it found" || bad "does not quote the kernel: $out"

for k in 5.15.0-1 6.14.11 6.8.0-45-generic; do
  stub_docker "$k"; stub_uname "$k"; stub_probe REFUSED; out="$(run)"; rc=$?
  [ "$rc" -eq 1 ] && ok "$k: below 6.15 and refusing — refused (a lower major, and 6.14 just under the line)" || bad "$k: rc=$rc, want 1"
done
stub_docker "6.12.107+deb13-cloud-amd64"; stub_uname "6.12.107+deb13-cloud-amd64"

echo "=== only Talos 1.14 and later asks for it: the version the lane runs decides ==="
stub_docker "6.12.107+deb13-cloud-amd64"; stub_uname "6.12.107+deb13-cloud-amd64"; stub_probe REFUSED
out="$(run_talos v1.13.9)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "v1.13.9 on a refusing kernel: silent, exit 0 (it boots there, measured)" || bad "v1.13.9: rc=$rc out=$out"
for v in v1.14.0 v1.14.2 v1.15.1 v2.0.0 latest; do
  out="$(run_talos "$v")"; rc=$?
  [ "$rc" -eq 1 ] && ok "$v on a refusing kernel: refused (a version it cannot read counts as new)" || bad "$v: rc=$rc, want 1"
done
out="$(PATH="$STUB_DIR:$PATH" OA_OVERLAY_PROBE="$STUB_DIR/probe" "$CHECK" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "no TF_VAR_talos_version: the default of opentofu-local/variables.tf is read, and it is 1.14 or later" || bad "default: rc=$rc"
grep -q "TF_VAR_talos_version=v1.13.9" <<<"$out" && ok "the refusal names the measured remedy" || bad "no remedy in: $out"

echo "=== an older version string whose kernel accepts the call (a backport): not refused ==="
stub_probe ACCEPTED; out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "exit 0, silent: the kernel's own answer wins over its version string" || bad "rc=$rc out=$out"

echo "=== an older kernel it cannot ask (not this machine's kernel, or the probe cannot tell): warns, does not block ==="
stub_probe UNKNOWN; out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "probe cannot tell: exit 0" || bad "probe cannot tell: exit $rc, want 0"
grep -q "could not ask" <<<"$out" && grep -q "#291" <<<"$out" && ok "…with a warning that names the symptom" || bad "no warning: $out"
stub_docker "6.6.87-microsoft-standard-WSL2"; stub_uname "5.15.0-other"; stub_probe REFUSED
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "could not ask" <<<"$out" && ok "a daemon on another kernel (a VM): not asked, warned, not refused" || bad "VM case: rc=$rc out=$out"

echo "=== no Docker answer, or garbage: fails open, silently ==="
stub_docker -; out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no daemon: exit 0, nothing to say" || bad "rc=$rc out=$out"
stub_docker "not-a-kernel"; out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unparsable version: exit 0" || bad "rc=$rc out=$out"

echo "=== wired into task local-up and test-talos-local.sh, not just documented ==="
grep -q 'check-host-overlay-fd.sh' "$ROOT/Taskfile.yml" && ok "Taskfile (local-up) calls it" || bad "Taskfile does not call it"
grep -q 'check-host-overlay-fd.sh' "$ROOT/scripts/dev/test-talos-local.sh" && ok "test-talos-local.sh calls it before its etcd-quorum wait" || bad "test-talos-local.sh does not call it"

echo "=== THIS host's real kernel, not a stub ==="
if command -v docker >/dev/null 2>&1 && real_kernel="$(docker info --format '{{.KernelVersion}}' 2>/dev/null)" && [ -n "$real_kernel" ]; then
  real_out="$("$CHECK" 2>&1)"; real_rc=$?
  maj="${real_kernel%%.*}"; min="${real_kernel#*.}"; min="${min%%[!0-9]*}"
  if [ "$maj" -gt 6 ] || { [ "$maj" -eq 6 ] && [ "$min" -ge 15 ]; }; then
    [ "$real_rc" -eq 0 ] && ok "kernel $real_kernel is 6.15 or newer — the check agrees" || bad "kernel $real_kernel but the check said no"
  elif [ "$real_kernel" = "$(uname -r)" ] && command -v unshare >/dev/null 2>&1 && unshare -Urm true 2>/dev/null; then
    [ "$real_rc" -ne 0 ] && ok "kernel $real_kernel is older and refuses the call — the check refuses in real time" \
      || ok "kernel $real_kernel is older but accepts the call (a backport) — the check agrees"
  else
    [ "$real_rc" -eq 0 ] && ok "kernel $real_kernel is older and cannot be asked here — the check warns and goes on" || bad "could not be asked, but the check refused"
  fi
else
  echo "  (no Docker daemon on this host — real-environment case not exercised)"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
