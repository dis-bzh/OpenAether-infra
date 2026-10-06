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

# --- a pin the RUNNING Talos cannot host is refused before anything is planned (#278) ------------
echo
echo "=== converge-versions.sh: the pair the running Talos can host ==="

# Talos 1.13 supports Kubernetes 1.31 to 1.36 (cluster/version-support.json): 1.37.1 on 1.13.9 is the
# 0.1.0 -> 0.2.0 climb, and the node refuses it only after the apply has started.
for mode in --check apply; do
  out="$(run v1.14.2 v1.37.1 v1.13.9 v1.36.3 ${mode/apply/})"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'supports Kubernetes 1.31 to 1.36' <<<"$out"; then
    ok "Talos 1.13.9 with a Kubernetes 1.37.1 pin is refused, with the supported range (${mode/apply/the roll}, rc=${rc})"
  else bad "Talos 1.13.9 with a Kubernetes 1.37.1 pin was not refused as such (${mode/apply/the roll}, rc=${rc}): ${out:0:200}"; fi
  grep -q 'task cluster-upgrade' <<<"$out" && ok "…and names task cluster-upgrade" || bad "the refusal does not name task cluster-upgrade"
  [ -s "$STUB_DIR/task.log" ] && bad "task ran despite the refusal (${mode/apply/the roll})" || ok "…and nothing was applied or rolled"
done

out="$(run v1.14.2 v1.37.1 v1.13.9,v1.14.2 v1.36.3 --check)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'Talos v1.13.9' <<<"$out"; } && ok "a mixed fleet is refused on its LOWEST Talos" || bad "a mixed fleet with one Talos 1.13 node was not refused (rc=${rc})"

out="$(run v1.14.2 v1.37.1 v1.14.2 v1.36.3)"
grep -q 'supports Kubernetes' <<<"$out" && bad "a valid pair (Talos 1.14.2 hosts Kubernetes 1.37.1) was refused" || ok "a valid pair is not refused"
grep -q 'infra-apply' "$STUB_DIR/task.log" && ok "…and reaches the apply" || bad "a valid pair never reached infra-apply"

out="$(run v1.13.9 v1.36.3 v1.13.8 v1.36.3 --check)"; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q 'supports Kubernetes' <<<"$out"; } && ok "a Talos-patch-only lag is not touched by the guard" || bad "a Talos-patch-only lag was refused (rc=${rc})"

out="$(run v1.99.1 v1.37.1 v1.99.0 v1.36.3 --check)"; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q 'supports Kubernetes' <<<"$out"; } && ok "a Talos minor the matrix does not know is left to the plan-time guard" || bad "an unknown Talos minor was refused here (rc=${rc})"

# A matrix that cannot be read is a question not answered, so a refusal, never a pass.
printf '#!/usr/bin/env bash\nexit 2\n' >"$STUB_DIR/jq"; chmod +x "$STUB_DIR/jq"
out="$(run v1.14.2 v1.37.1 v1.13.9 v1.36.3 --check)"; rc=$?
rm -f "$STUB_DIR/jq"
{ [ "$rc" -ne 0 ] && grep -q 'UNKNOWN' <<<"$out"; } && ok "an unreadable support matrix refuses (rc=${rc})" || bad "an unreadable support matrix was read as a pass (rc=${rc})"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
