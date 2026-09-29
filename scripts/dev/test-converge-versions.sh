#!/usr/bin/env bash
# Unit tests for converge-versions.sh's downgrade guard (#90).
#
# Before this guard, converge-versions.sh had none of its own: it only
# survived a downgrade attempt by accident, on two layers upstream of it that
# are not its to depend on (the talos provider's forced PKI replacement below
# a lower version, caught only because secrets_prevent_destroy turns that into
# a hard refusal — and that variable is explicitly false in `tofu test`). This
# proves the guard directly: a pin below what the fleet runs is refused, with
# a message naming both, BEFORE either `task infra-apply` or `task
# cluster-roll` is called — never inferred from what those tasks would have
# done.
#
# No cluster, no cloud: kubectl and task are stubbed on PATH, and the tfvars
# read is a fixture in a sandbox envs dir (OA_ENVS_DIR), never the operator's.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/internal/converge-versions.sh"
STUB_DIR="$(mktemp -d)"
ROLE=stubtest
PROVIDER=fixture
TFVARS="$STUB_DIR/${ROLE}-${PROVIDER}.tfvars"
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

PASS=0 FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# --- stubs ----------------------------------------------------------------
# kubectl answers only the two fields oa_fleet_versions asks for, from
# STUB_TALOS / STUB_K8S (comma-separated for a mixed fleet). task records
# every invocation and does nothing else — the guard must never let one
# through on a downgrade.
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *osImage*)
    IFS=',' read -ra vs <<<"${STUB_TALOS:-}"
    for v in "${vs[@]}"; do printf 'Talos (%s)\n' "$v"; done
    ;;
  *kubeletVersion*)
    IFS=',' read -ra vs <<<"${STUB_K8S:-}"
    for v in "${vs[@]}"; do printf '%s\n' "$v"; done
    ;;
  *) exit 1 ;;
esac
STUB
cat >"$STUB_DIR/task" <<STUB
#!/usr/bin/env bash
echo "task \$*" >>"$STUB_DIR/task.log"
exit 0
STUB
chmod +x "$STUB_DIR/kubectl" "$STUB_DIR/task"

# <pin-talos> <pin-k8s> <running-talos> <running-k8s> [--check]
run() {
  : >"$STUB_DIR/task.log"
  cat >"$TFVARS" <<EOF
talos_version      = "$1"
kubernetes_version = "$2"
EOF
  PATH="$STUB_DIR:$PATH" OA_ENVS_DIR="$STUB_DIR" STUB_TALOS="$3" STUB_K8S="$4" \
    "$SCRIPT" "$PROVIDER" "$ROLE" /dev/null ${5:+--check} 2>&1
}

echo "=== converge-versions.sh: the downgrade guard is its own, not borrowed ==="

# --- Talos downgrade --------------------------------------------------------
out="$(run v1.13.8 v1.36.3 v1.13.9 v1.36.3)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "Talos pin below the running fleet is refused (rc=${rc})"
else bad "Talos pin below the running fleet was NOT refused"; fi
grep -qi 'downgrade' <<<"$out" && ok "the refusal is named a downgrade" ||
  bad "the refusal never says 'downgrade'"
grep -q 'v1.13.8' <<<"$out" && grep -q 'v1.13.9' <<<"$out" &&
  ok "the message names both the pin and the running version" ||
  bad "the message does not name both versions"
[ -s "$STUB_DIR/task.log" ] && bad "task was invoked despite the downgrade — the guard ran too late" ||
  ok "neither infra-apply nor cluster-roll was called"

# --- Kubernetes downgrade ----------------------------------------------------
out="$(run v1.13.9 v1.36.2 v1.13.9 v1.36.3)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "Kubernetes pin below the running fleet is refused (rc=${rc})"
else bad "Kubernetes pin below the running fleet was NOT refused"; fi
[ -s "$STUB_DIR/task.log" ] && bad "task was invoked despite the Kubernetes downgrade" ||
  ok "neither infra-apply nor cluster-roll was called (Kubernetes case)"

# --- mixed fleet: pin matches the LOWER node, still a downgrade from the other
out="$(run v1.13.8 v1.36.3 v1.13.8,v1.13.9 v1.36.3)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a pin below even one node of a mixed fleet is refused (rc=${rc})"
else bad "a mixed fleet with one node above the pin was NOT refused"; fi

# --- --check also refuses, before any approval is asked ---------------------
out="$(run v1.13.8 v1.36.3 v1.13.9 v1.36.3 --check)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "--check refuses a downgrade too (rc=${rc})"
else bad "--check let a downgrade through"; fi

# --- a legitimate upgrade is not blocked by the guard ------------------------
out="$(run v1.13.9 v1.36.3 v1.13.8 v1.36.2)"; rc=$?
grep -qi 'downgrade' <<<"$out" && bad "an upgrade (pin above running) was misread as a downgrade" ||
  ok "an upgrade (pin above running) is not flagged as a downgrade"
[ -s "$STUB_DIR/task.log" ] && ok "the guard let a real upgrade proceed to infra-apply/cluster-roll" ||
  bad "a legitimate upgrade never reached infra-apply/cluster-roll"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
