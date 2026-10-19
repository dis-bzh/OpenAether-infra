#!/usr/bin/env bash
# Unit tests for #112: a `--set` typo in render-bootstrap-manifests.sh passes
# `helm template` silently (rc 0, empty stderr — an unknown key is just
# another value in .Values), so neither `task render-check` (diffs the
# render against itself) nor check-cilium-parity.py (skips a key it cannot
# resolve) ever see it. Both checks here read the EFFECTIVE result instead.
#
# Offline throughout: synthetic ConfigMap fixtures for
# check-cilium-effective-config.py, no helm and no network; a temp copy of
# the render script's production block, with the exact typo from the issue,
# for check-cilium-parity.py's new missing-key guard.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "=== check-cilium-effective-config.py: reads the ConfigMap, not the flags ==="

configmap() { # <data-block-lines...> -> a one-ConfigMap manifest on stdout
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-config\n  namespace: kube-system\ndata:\n'
  printf '  %s\n' "$@"
}

# The exact reproduction from the issue: socketLB.hostNamespaceOnly misspelled
# one character short, so the chart never writes bpf-lb-sock-hostns-only —
# bpf-lb-sock stays "true", which is the state the render script's own
# comment says breaks hostNetwork pods.
configmap 'ipam: "kubernetes"' 'kube-proxy-replacement: "true"' 'bpf-lb-sock: "true"' \
  'cni-exclusive: "false"' 'enable-bpf-masquerade: "true"' 'enable-host-legacy-routing: "false"' \
  'enable-wireguard: "true"' 'enable-node-selector-labels: "true"' \
  >"$TMP/typo.yaml"

out="$(python3 "$ROOT/scripts/ops/check-cilium-effective-config.py" "$TMP/typo.yaml" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "the typo's effect (bpf-lb-sock-hostns-only absent) is caught (rc=${rc})"
else bad "the typo's effect went undetected — exited 0"; fi
grep -q 'bpf-lb-sock-hostns-only' <<<"$out" && ok "the missing key is named" ||
  bad "the missing key is never named"

# The correct spelling: same fixture, the one key added.
configmap 'ipam: "kubernetes"' 'kube-proxy-replacement: "true"' 'bpf-lb-sock: "true"' \
  'bpf-lb-sock-hostns-only: "true"' 'cni-exclusive: "false"' 'enable-bpf-masquerade: "true"' \
  'enable-host-legacy-routing: "false"' 'enable-wireguard: "true"' 'enable-node-selector-labels: "true"' \
  >"$TMP/correct.yaml"

out="$(python3 "$ROOT/scripts/ops/check-cilium-effective-config.py" "$TMP/correct.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the correct spelling passes (rc=0)" || bad "a correct ConfigMap was rejected (rc=${rc}): ${out}"

# A wrong VALUE (not just a missing key) is caught too.
configmap 'ipam: "kubernetes"' 'kube-proxy-replacement: "true"' 'bpf-lb-sock: "true"' \
  'bpf-lb-sock-hostns-only: "false"' 'cni-exclusive: "false"' 'enable-bpf-masquerade: "true"' \
  'enable-host-legacy-routing: "false"' 'enable-wireguard: "true"' 'enable-node-selector-labels: "true"' \
  >"$TMP/wrong-value.yaml"
out="$(python3 "$ROOT/scripts/ops/check-cilium-effective-config.py" "$TMP/wrong-value.yaml" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a wrong (not just missing) effective value is caught (rc=${rc})" ||
  bad "a wrong effective value went undetected"

# Proof against reality, not only fixtures: the actual committed artifact —
# what render-bootstrap-manifests.sh produces today — must pass.
out="$(python3 "$ROOT/scripts/ops/check-cilium-effective-config.py" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the committed production cilium.yaml passes (default path, no arg)" ||
  bad "the committed cilium.yaml failed its own effective-config check: ${out}"

# Hubble variant: passes as committed; a widened allow-list, a listener or an empty field mask is refused.
HV="$ROOT/infrastructure/opentofu/cluster/bootstrap-manifests/cilium-hubble-drops.yaml"
out="$(python3 "$ROOT/scripts/ops/check-cilium-effective-config.py" "$HV" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the committed dropped-flow variant passes" || bad "the dropped-flow variant failed: ${out}"
for mut in 's|hubble-export-allowlist: .*|hubble-export-allowlist: "{\"verdict\":[\"FORWARDED\",\"DROPPED\"]}"|' \
           's|hubble-listen-address: ""|hubble-listen-address: ":4244"|' \
           's|hubble-export-fieldmask: .*|hubble-export-fieldmask: ""|' \
           's|hubble-export-file-path: .*|hubble-export-file-path: "/var/run/cilium/hubble/events.log"|'; do
  sed "$mut" "$HV" >"$TMP/hv-mut.yaml"
  python3 "$ROOT/scripts/ops/check-cilium-effective-config.py" "$TMP/hv-mut.yaml" >/dev/null 2>&1 &&
    bad "a widened Hubble export went undetected (${mut%%|*})" || ok "a widened Hubble export is refused"
done

echo
echo "=== check-cilium-parity.py: a --set typo is a hard failure, not a skip ==="

# A temp copy of the render script with the issue's exact typo
# (hostNamespaceOnl, one character short), injected into the PRODUCTION
# block only — a plain sed would also mangle the LOCAL block's correct
# spelling, so this is scoped to the text after the "# Production mode"
# marker, the same marker parse_parent() splits on.
awk '
  /# Production mode/ { prod = 1 }
  prod && /--set socketLB\.hostNamespaceOnly=true \\/ {
    sub(/hostNamespaceOnly/, "hostNamespaceOnl"); print; next
  }
  { print }
' "$ROOT/scripts/bootstrap/render-bootstrap-manifests.sh" >"$TMP/render-typo.sh"

# Exactly one typo'd occurrence (production) and exactly one correct one left
# (local) — anything else means the injection missed its mark or over-reached.
typo_count="$(grep -c -- '--set socketLB.hostNamespaceOnl=true \\' "$TMP/render-typo.sh")"
correct_count="$(grep -c -- '--set socketLB.hostNamespaceOnly=true \\' "$TMP/render-typo.sh")"
if [ "$typo_count" = 1 ] && [ "$correct_count" = 1 ]; then
  ok "test setup: typo injected into the production block only, local block intact"
else
  bad "test setup: expected 1 typo'd + 1 correct occurrence, got ${typo_count} + ${correct_count}"
fi

out="$(python3 - "$TMP/render-typo.sh" <<'PY' 2>&1
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "check_cilium_parity", "scripts/ops/check-cilium-parity.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.RENDER_SH = pathlib.Path(sys.argv[1])
parent = mod.parse_parent()
missing = mod.missing_parent_keys(parent)
if missing:
    print("MISSING:", missing)
    sys.exit(1)
print("all CHECKED keys present")
PY
)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "the typo makes a CHECKED key vanish from the parent, and it's caught (rc=${rc})"
else bad "check-cilium-parity.py did not notice the typo'd key was missing"; fi
grep -q 'socketLB.hostNamespaceOnly' <<<"$out" && ok "the missing key is named" ||
  bad "the missing key is never named: ${out}"

out="$(python3 - "$ROOT/scripts/bootstrap/render-bootstrap-manifests.sh" <<'PY' 2>&1
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "check_cilium_parity", "scripts/ops/check-cilium-parity.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.RENDER_SH = pathlib.Path(sys.argv[1])
parent = mod.parse_parent()
missing = mod.missing_parent_keys(parent)
sys.exit(1 if missing else 0)
PY
)"; rc=$?
[ "$rc" -eq 0 ] && ok "the real, unmodified render script sets every CHECKED key" ||
  bad "the real render script is missing a CHECKED key: ${out}"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
