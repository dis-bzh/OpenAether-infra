#!/usr/bin/env bash
# ==============================================================================
# The OVH pool members move from one resource per member to one per pool (#418) without leaving a pool empty.
#
# A `tofu test` cannot start from a state, and the upgrade is all about the state, so this runs a REAL `tofu plan`
# of the OVH module (provider from the committed lock) against a fake OpenStack (scripts/dev/fake-openstack.py)
# with -refresh=false. The state is the one a cluster built before #418 holds: the module as it is, with the
# per-member resources it had then put back, its plans folded until it has nothing left to create.
# What it cannot prove: what Octavia does with the batch call. That is the lab's (docs/upgrade.md).
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
for bin in tofu jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required and not on PATH — nothing was checked" >&2; exit 1; }
done

W="$(mktemp -d)"; SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/root" "$W/now" "$W/before"
cp -r infrastructure/opentofu/modules/providers/ovh infrastructure/opentofu/modules/providers/_shared "$W/now/"
cp -r "$W/now/." "$W/before/"

# The module of a cluster built before #418: the per-pool sets and the removed blocks out, the per-member resources in.
python3 -I - "$W/before/ovh" <<'PY' || { echo "✗ could not build the pre-#418 module" >&2; exit 1; }
import re, sys
d = sys.argv[1]
block = lambda head: re.compile(r'(?ms)^(?:#[^\n]*\n)*' + head + r'.*?^\}\n')
lb = open(f"{d}/lb.tf").read()
lb, sets = block(r'resource "openstack_lb_members_v2" ').subn("", lb)
lb, gone = block(r'removed \{').subn("", lb)
assert sets == 3 and gone == 3, (sets, gone)
lb += '''
resource "openstack_lb_member_v2" "k8s_api" {
  count         = var.k8s_lb_mode == "managed" ? var.control_plane_count : 0
  pool_id       = openstack_lb_pool_v2.k8s_api[0].id
  address       = try(openstack_networking_port_v2.control_plane[count.index].all_fixed_ips[0], "0.0.0.0")
  protocol_port = 6443
  subnet_id     = openstack_networking_subnet_v2.private.id
}
resource "openstack_lb_member_v2" "http" {
  count         = var.deploy_app_lb ? var.worker_count : 0
  pool_id       = openstack_lb_pool_v2.http[0].id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = var.app_lb_node_ports.http
  subnet_id     = openstack_networking_subnet_v2.private.id
}
resource "openstack_lb_member_v2" "https" {
  count         = var.deploy_app_lb ? var.worker_count : 0
  pool_id       = openstack_lb_pool_v2.https[0].id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = var.app_lb_node_ports.https
  subnet_id     = openstack_networking_subnet_v2.private.id
}
'''
open(f"{d}/lb.tf", "w").write(lb)
out = open(f"{d}/outputs.tf").read()
out, n = block(r'output "lb_member_sets" ').subn("", out)
assert n == 1
open(f"{d}/outputs.tf", "w").write(out)
PY

# Only the openstack provider, at the version the cluster root locks.
awk '/^provider "registry.opentofu.org\/terraform-provider-openstack\/openstack"/{p=1} p{print} p&&/^}/{p=0}' \
  infrastructure/opentofu/cluster/.terraform.lock.hcl >"$W/root/.terraform.lock.hcl"
cat >"$W/root/main.tf" <<'EOF'
terraform {
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack" }
  }
}
variable "auth_url" { type = string }
provider "openstack" {
  auth_url            = var.auth_url
  user_name           = "u"
  password            = "p"
  tenant_name         = "t"
  user_domain_name    = "Default"
  project_domain_name = "Default"
  region              = "R"
}
module "ovh" {
  source              = "./mods/ovh"
  cluster_name        = "oa-test"
  control_plane_count = 3
  worker_count        = 2
  admin_ip            = ["192.0.2.1/32"]
  image_id            = "talos-image"
  deploy_app_lb       = true
  k8s_lb_mode         = "managed"
}
EOF
# The addresses a cloud would have given the nodes.
cat >"$W/seed.json" <<'EOF'
{"module.ovh.openstack_networking_port_v2.control_plane[0]": {"all_fixed_ips": ["10.0.0.10"]},
 "module.ovh.openstack_networking_port_v2.control_plane[1]": {"all_fixed_ips": ["10.0.0.11"]},
 "module.ovh.openstack_networking_port_v2.control_plane[2]": {"all_fixed_ips": ["10.0.0.12"]},
 "module.ovh.openstack_compute_instance_v2.worker[0]": {"access_ip_v4": "10.0.0.20"},
 "module.ovh.openstack_compute_instance_v2.worker[1]": {"access_ip_v4": "10.0.0.21"}}
EOF

python3 -I scripts/dev/fake-openstack.py serve "$W/port" "$W/requests.log" & SRV=$!
for _ in $(seq 50); do [ -s "$W/port" ] && break; sleep 0.1; done
[ -s "$W/port" ] || { echo "✗ the fake OpenStack did not start" >&2; exit 1; }
export TF_VAR_auth_url="http://127.0.0.1:$(cat "$W/port")/v3" TF_IN_AUTOMATION=1
use() { rm -rf "$W/root/mods" && mkdir "$W/root/mods" && cp -r "$W/$1/." "$W/root/mods/"; } # <now|before>
( cd "$W/root" && use before && tofu init -backend=false -lockfile=readonly -input=false >"$W/init.log" 2>&1 ) \
  || { tail -n 15 "$W/init.log" >&2; echo "✗ tofu init failed — nothing was checked" >&2; exit 1; }
tofu -chdir="$W/root" providers schema -json \
  | jq '[.provider_schemas[].resource_schemas | to_entries[] | {key, value: (.value.block.attributes // {} | map_values(.type))}] | from_entries' \
  >"$W/types.json" || { echo "✗ could not read the provider schema" >&2; exit 1; }

plan() { # <now|before> <json-out> [plan flags]: a plan of that module against $W/state.json, as JSON
  use "$1"
  tofu -chdir="$W/root" plan "${@:3}" -refresh=false -lock=false -input=false -no-color -state="$W/state.json" -out="$W/p.tfplan" \
    >"$W/plan.log" 2>&1 || { tail -n 20 "$W/plan.log" >&2; return 1; }
  tofu -chdir="$W/root" show -json "$W/p.tfplan" >"$2"
}
fold() { python3 -I scripts/dev/fake-openstack.py fold "$W/state.json" "$1" "$W/seed.json" "$W/types.json"; }
changes() { jq -r '.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | "\(.change.actions | join(",")) \(.address)"' "$1"; }
# Every change but one: a hand-built state leaves the provider planning an "update" of each instance that changes no value.
structural() { changes "$1" | grep -vE '^update module\.ovh\.openstack_compute_instance_v2\.' || true; }
converge() { # <now|before>: fold its plans until it would create and delete nothing
  local n
  for n in 1 2 3 4 5 6 7 8 9 10; do
    plan "$1" "$W/c.json" || return 1
    [ -z "$(structural "$W/c.json")" ] && return 0
    fold "$W/c.json" || return 1
  done
  structural "$W/c.json" >&2; return 1
}

echo "=== a cluster built before #418 ==="
rm -f "$W/state.json"
if converge before; then
  n="$(jq '[.resources[] | select(.type == "openstack_lb_member_v2") | .instances[]] | length' "$W/state.json")"
  [ "$n" = 7 ] && ok "the pre-#418 module converges, its state holding the 7 per-member resources (3 API, 2 http, 2 https)" \
    || bad "the pre-#418 state holds ${n} per-member resources, not 7"
else
  bad "the pre-#418 module does not converge on the fake: no model to upgrade from"
fi
cp "$W/state.json" "$W/state.before.json"

echo "=== its first plan on this module ==="
: >"$W/requests.log"
if plan now "$W/up.json"; then
  d="$(jq -r '.resource_changes[] | select(.change.actions | index("delete")) | .address' "$W/up.json")"
  [ -z "$d" ] && ok "the plan deletes nothing" || bad "the plan deletes: $(tr '\n' ' ' <<<"$d")"
  f="$(jq -r '[.resource_changes[] | select(.type == "openstack_lb_member_v2") | .change.actions | join(",")] | unique | join(" ")' "$W/up.json")"
  nf="$(jq '[.resource_changes[] | select(.type == "openstack_lb_member_v2" and .change.actions == ["forget"])] | length' "$W/up.json")"
  [ "$f" = forget ] && [ "$nf" = 7 ] && ok "the 7 per-member resources are forgotten, no API call" || bad "per-member resources: '${f}' (${nf} forgotten)"
  # The batch call keeps a member whose address and port it lists, so the set must list exactly the members there.
  for pool in k8s_api http https; do
    old="$(jq -c --arg p "$pool" '[.resources[] | select(.type == "openstack_lb_member_v2" and .name == $p) | .instances[].attributes
      | {pool_id, address, protocol_port, subnet_id}] | sort' "$W/state.before.json")"
    new="$(jq -c --arg p "$pool" '[.resource_changes[] | select(.type == "openstack_lb_members_v2" and .name == $p and .change.actions == ["create"])
      | .change.after as $a | $a.member[] | {pool_id: $a.pool_id, address, protocol_port, subnet_id}] | sort' "$W/up.json")"
    [ "$old" = "$new" ] && [ "$old" != "[]" ] && ok "pool ${pool}: one set created on the same pool, listing exactly the members it holds" \
      || bad "pool ${pool}: before ${old}, set ${new}"
  done
  w="$(grep -vE '^(GET |POST /v3/auth/tokens$)' "$W/requests.log" || true)"
  [ -z "$w" ] && ok "planning wrote nothing to the cloud" || bad "the plan sent: $(tr '\n' ' ' <<<"$w")"
else
  bad "this module does not plan against a pre-#418 state"
fi

echo "=== a teardown before that apply (task cluster-down plans with this module) ==="
if plan now "$W/down0.json" -destroy; then
  # A destroy ignores `destroy = false`: the per-member resources go through the API as they did before #418.
  k="$(jq -r '[.resource_changes[] | select(.mode == "managed") | .change.actions | join(",")] | unique | join(" ")' "$W/down0.json")"
  n="$(jq '[.resource_changes[] | select(.type == "openstack_lb_member_v2" and .change.actions == ["delete"])] | length' "$W/down0.json")"
  [ "$k" = delete ] && [ "$n" = 7 ] && ok "it deletes every resource, the 7 per-member ones included: nothing is left behind" \
    || bad "the destroy plan of a pre-#418 state: actions '${k}', ${n} per-member resources deleted"
else
  bad "no destroy plan for a pre-#418 state"
fi

echo "=== after that apply ==="
fold "$W/up.json" && plan now "$W/after.json" \
  && { s="$(structural "$W/after.json")"; [ -z "$s" ] && ok "the next plan changes nothing" || bad "the next plan still: $(tr '\n' ' ' <<<"$s")"; } \
  || bad "no plan after the upgrade"

if plan now "$W/down1.json" -destroy; then
  k="$(jq -r '[.resource_changes[] | select(.mode == "managed") | .change.actions | join(",")] | unique | join(" ")' "$W/down1.json")"
  n="$(jq '[.resource_changes[] | select(.type == "openstack_lb_members_v2" and .change.actions == ["delete"])] | length' "$W/down1.json")"
  [ "$k" = delete ] && [ "$n" = 3 ] && ok "its teardown deletes everything, the three sets included" || bad "the destroy plan after the upgrade: '${k}', ${n} sets"
else
  bad "no destroy plan after the upgrade"
fi

echo "=== a worker replaced (rolling-replace's config plan) ==="
jq '(.resources[] | select(.type == "openstack_compute_instance_v2" and .name == "worker") | .instances[] | select(.index_key == 1)
  | .attributes.access_ip_v4) = "10.0.0.31"' "$W/state.json" >"$W/s.tmp" && mv "$W/s.tmp" "$W/state.json"
if plan now "$W/roll.json"; then
  a="$(structural "$W/roll.json" | sort | tr '\n' ' ')"
  [ "$a" = "update module.ovh.openstack_lb_members_v2.http[0] update module.ovh.openstack_lb_members_v2.https[0] " ] \
    && ok "only the http and https sets change, in place: no destroy for the guard to count" || bad "the roll plan: ${a}"
  m="$(jq -c '[.resource_changes[] | select(.type == "openstack_lb_members_v2" and .name == "http") | .change.after.member[].address] | sort' "$W/roll.json")"
  [ "$m" = '["10.0.0.20","10.0.0.31"]' ] && ok "…swapping the old address for the new one in one call" || bad "http members after the roll: ${m}"
else
  bad "no plan for a replaced worker"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
