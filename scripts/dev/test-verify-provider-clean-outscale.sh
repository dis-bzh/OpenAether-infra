#!/usr/bin/env bash
# verify-provider-clean.py, Outscale network objects (lab 27 part C, E5): a Net, subnet, route table, internet service, NAT service,
# load balancers and security groups named after the cluster (or inside its Net) are leftovers; the Net's default group is not; another
# cluster's objects are not; OA_CLEAN_IGNORE skips a stuck Net and everything in it. In-process, the API is a fake `call`.
# Usage: test-verify-provider-clean-outscale.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

res="$(python3 -I - "$ROOT/scripts/ops/verify-provider-clean.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("vpc", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def tag(n): return [{"Key": "Name", "Value": n}]
DB = {
 "ReadNets": {"Nets": [{"NetId": "vpc-mine", "Tags": tag("openaether-dev-net")}, {"NetId": "vpc-other", "Tags": tag("someone-else-net")},
                       {"NetId": "vpc-stuck", "Tags": tag("openaether-dev-net")}]},
 "ReadLoadBalancers": {"LoadBalancers": [{"LoadBalancerName": "openaether-dev-k8s-lb", "NetId": "vpc-mine"}, {"LoadBalancerName": "openaether-dev-app-lb", "NetId": "vpc-mine"},
                                         {"LoadBalancerName": "other-lb", "NetId": "vpc-other"}, {"LoadBalancerName": "stuck-lb", "NetId": "vpc-stuck"}]},
 "ReadSubnets": {"Subnets": [{"SubnetId": "subnet-1", "NetId": "vpc-mine", "Tags": tag("openaether-dev-public-subnet")}, {"SubnetId": "subnet-o", "NetId": "vpc-other"},
                             {"SubnetId": "subnet-s", "NetId": "vpc-stuck"}]},
 "ReadRouteTables": {"RouteTables": [{"RouteTableId": "rtb-1", "NetId": "vpc-mine", "Tags": tag("openaether-dev-public-rt")}, {"RouteTableId": "rtb-o", "NetId": "vpc-other"}]},
 "ReadInternetServices": {"InternetServices": [{"InternetServiceId": "igw-1", "NetId": "vpc-mine"}, {"InternetServiceId": "igw-o", "NetId": "vpc-other"}]},
 "ReadNatServices": {"NatServices": [{"NatServiceId": "nat-1", "NetId": "vpc-mine", "State": "available"}, {"NatServiceId": "nat-2", "NetId": "vpc-mine", "State": "deleted"}]},
 "ReadSecurityGroups": {"SecurityGroups": [{"SecurityGroupId": "sg-d", "SecurityGroupName": "default", "NetId": "vpc-mine"},
                                           {"SecurityGroupId": "sg-1", "SecurityGroupName": "openaether-dev-cluster-sg", "NetId": "vpc-mine"}]},
}
def call(action, payload=None): return DB.get(action, {})
os.environ["OA_CLEAN_IGNORE"] = "vpc-stuck"
got = m.outscale_network_leftovers("openaether-dev", call)
print("\n".join(sorted(got)))
print("---")
os.environ["OA_CLEAN_IGNORE"] = ""
print("stuck-listed" if any("vpc-stuck" in x or "stuck-lb" in x or "subnet-s" in x for x in m.outscale_network_leftovers("openaether-dev", call)) else "stuck-not-listed")
print("---")
DB2 = {k: {kk: [] for kk in v} for k, v in DB.items()}
print(len(m.outscale_network_leftovers("openaether-dev", lambda a, p=None: DB2.get(a, {}))))
PY
)"
first="$(sed -n '1,/^---$/p' <<<"$res" | sed '$d')"
want='NAT service nat-1
internet service igw-1
load balancer openaether-dev-app-lb
load balancer openaether-dev-k8s-lb
net vpc-mine (openaether-dev-net)
route table rtb-1 (openaether-dev-public-rt)
security group sg-1 (openaether-dev-cluster-sg)
subnet subnet-1 (openaether-dev-public-subnet)'
[ "$first" = "$want" ] && ok_ "the cluster's Net, LBs, subnet, route table, internet and NAT service and its own group are listed; nothing else" \
  || bad "leftovers differ: $(tr '\n' '|' <<<"$first")"
grep -q '^stuck-listed$' <<<"$res" && ok_ "without OA_CLEAN_IGNORE the stuck Net and what is in it are listed" || bad "stuck Net not listed without the ignore: $res"
[ "$(tail -1 <<<"$res")" = 0 ] && ok_ "an account with none of it is clean" || bad "empty account: $(tail -1 <<<"$res")"
grep -q 'scripts/ops/verify-provider-clean.py' "$ROOT/scripts/ops/fleet-down.sh" && ok_ "fleet-down runs the check after the destroy" || bad "fleet-down does not call verify-provider-clean.py"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
