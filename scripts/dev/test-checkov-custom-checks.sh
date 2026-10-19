#!/usr/bin/env bash
# Unit tests for #123: the checkov-custom-checks/ policies (CKV_OA_1, CKV_OA_2, CKV_OA_3).
#
# Mutates REAL tracked files under a trap that always restores them, rather
# than a synthetic fixture repo: a custom check keys on exact resource types
# and attribute shapes (__address__, the nested lifecycle/ignore_changes
# wrapping checkov's own HCL parser produces), and a hand-built minimal .tf
# risks testing the fixture's idea of that shape instead of the real one.
# check-provider-contract.sh has no dedicated test file for the same reason —
# proof against the real tree, mutated and restored, is what these two rows
# in provider-contract.md actually need.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
CHECKS_DIR="infrastructure/opentofu/checkov-custom-checks"
SCW_MAIN="infrastructure/opentofu/modules/providers/scw/main.tf"
SCW_SECURITY="infrastructure/opentofu/modules/providers/scw/security.tf"
OSC_SECURITY="infrastructure/opentofu/modules/providers/outscale/security.tf"

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cp "$SCW_MAIN" "$TMP/scw-main.tf.orig"
cp "$SCW_SECURITY" "$TMP/scw-security.tf.orig"
cp "$OSC_SECURITY" "$TMP/osc-security.tf.orig"
restore() {
  cp "$TMP/scw-main.tf.orig" "$SCW_MAIN"
  cp "$TMP/scw-security.tf.orig" "$SCW_SECURITY"
  cp "$TMP/osc-security.tf.orig" "$OSC_SECURITY"
  [ -f "$TMP/init.py.bak" ] && mv "$TMP/init.py.bak" "$CHECKS_DIR/__init__.py"
  rm -rf "$TMP"
}
trap restore EXIT

run() { checkov -d infrastructure/opentofu --external-checks-dir "$CHECKS_DIR" --check CKV_OA_1,CKV_OA_2,CKV_OA_3 2>/dev/null; }

echo "=== the real, unmodified tree passes both custom checks ==="

out="$(run)"
grep -qE 'Passed checks: 34, Failed checks: 0' <<<"$out" && ok "34 passed, 0 failed (8 node resources + 4 bastions x2 checks, 4 security groups x1 check, 18 Outscale rules x1 check)" ||
  bad "unexpected result on the real tree: $(grep -E 'Passed checks|Failed checks' <<<"$out")"

echo
echo "=== CKV_OA_1: removing a control_plane's ignore_changes is caught ==="

python3 - "$SCW_MAIN" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '''  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  lifecycle {
    ignore_changes = [image]
  }
  zone       = element(var.additional_zones, count.index)
  project_id = var.project_id

  root_volume {
    volume_type           = var.root_volume_type
    size_in_gb            = 20
    delete_on_termination = true
  }

  # No public IP - private network only'''
replacement = '''  zone       = element(var.additional_zones, count.index)
  project_id = var.project_id

  root_volume {
    volume_type           = var.root_volume_type
    size_in_gb            = 20
    delete_on_termination = true
  }

  # No public IP - private network only'''
assert needle in text, "fixture text not found — has scw/main.tf changed shape?"
open(path, "w").write(text.replace(needle, replacement, 1))
PY

out="$(run)"
grep -q 'CKV_OA_1' <<<"$out" && grep -q 'FAILED for resource: module.scw.scaleway_instance_server.control_plane' <<<"$out" &&
  ok "the mutated control_plane is named FAILED under CKV_OA_1" ||
  bad "the missing lifecycle block was not caught: $(grep -E 'Passed checks|Failed checks' <<<"$out")"
grep -q 'FAILED for resource: module.scw.scaleway_instance_server.worker' <<<"$out" &&
  bad "the untouched worker was flagged too — false positive" ||
  ok "the untouched worker (same file, same resource type) is not flagged"

cp "$TMP/scw-main.tf.orig" "$SCW_MAIN"

echo
echo "=== CKV_OA_2: flipping the security group's default policy is caught ==="

sed -i 's/inbound_default_policy = "drop"/inbound_default_policy = "accept"/' "$SCW_SECURITY"
out="$(run)"
grep -q 'CKV_OA_2' <<<"$out" && grep -q 'FAILED for resource: module.scw.scaleway_instance_security_group.this' <<<"$out" &&
  ok "the flipped security group is named FAILED under CKV_OA_2" ||
  bad "the flipped default policy was not caught: $(grep -E 'Passed checks|Failed checks' <<<"$out")"

cp "$TMP/scw-security.tf.orig" "$SCW_SECURITY"

echo
echo "=== CKV_OA_3: a literal /0 on an Outscale inbound rule is caught ==="

sed -i '0,/ip_range          = each.value/s//ip_range          = "0.0.0.0\/0"/' "$OSC_SECURITY"
out="$(run)"
grep -q 'CKV_OA_3' <<<"$out" && grep -q 'FAILED for resource: module.outscale.outscale_security_group_rule.k8s_api_admin' <<<"$out" &&
  ok "the world-open admin rule is named FAILED under CKV_OA_3" ||
  bad "the literal /0 inbound rule was not caught: $(grep -E 'Passed checks|Failed checks' <<<"$out")"

cp "$TMP/osc-security.tf.orig" "$OSC_SECURITY"

echo
echo "=== the tree is clean again after all mutations ==="

out="$(run)"
grep -qE 'Passed checks: 34, Failed checks: 0' <<<"$out" && ok "back to 34 passed, 0 failed" ||
  bad "restore left the tree dirty: $(grep -E 'Passed checks|Failed checks' <<<"$out")"

echo
echo "=== missing __init__.py is the documented false-green trap, guarded by its presence ==="

mv "$CHECKS_DIR/__init__.py" "$TMP/init.py.bak"
out="$(run)"
grep -q 'CKV_OA_1\|CKV_OA_2\|CKV_OA_3' <<<"$out" &&
  bad "a directory with no __init__.py still registered a check — the guard comment is now wrong" ||
  ok "with no __init__.py, checkov finds neither check (registers nothing) — exactly why the file must stay"
mv "$TMP/init.py.bak" "$CHECKS_DIR/__init__.py"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
