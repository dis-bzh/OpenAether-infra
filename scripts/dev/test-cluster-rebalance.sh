#!/usr/bin/env bash
# scripts/ops/cluster-rebalance.py against a fake kubectl (lab 27 part C, E4): two replicas of a critical pod on one node while
# another node has none is FOUND (--check, exit 3) and FIXED (--apply: evicts the newest pod of the stacked node, the "scheduler"
# of the stub puts the replacement on the empty node). Pinned: a shape with fewer eligible nodes than replicas is NOT wrong; a
# cordoned, NotReady or tainted node is not an empty node; one eviction at a time, through the Eviction API; a refused eviction
# (PDB) is retried then fails the run; a group that cannot be fixed fails the run; an absent group is not an error. What a real
# scheduler and PDB do is NOT reproduced here (UNPROVEN until a lab: drain a node, bring it back, run the task).
# Zones (lab 28, I2): CoreDNS is also judged per ZONE: two replicas in one zone while another zone that has an eligible node holds
# none is wrong, but only when three or more zones have eligible nodes (below that the spread over zones is a preference).
# Usage: test-cluster-rebalance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/cluster-rebalance.py}"
W="$(mktemp -d)"; trap 'rm -rf "${W:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
export ST="$W/state.json" CALLS="$W/calls.log" OA_REBALANCE_POLL=0 OA_REBALANCE_TIMEOUT=2
mkdir -p "$W/bin"
cat >"$W/bin/kubectl" <<'S'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
st = json.load(open(os.environ["ST"]))
open(os.environ["CALLS"], "a").write(" ".join(a) + "\n")
def save(): json.dump(st, open(os.environ["ST"], "w"))
if a[0] == "get" and a[1] == "nodes":
    print(json.dumps({"items": st["nodes"]})); sys.exit(0)
if a[0] == "get" and a[1] == "pods":
    ns, sel = a[a.index("-n") + 1], a[a.index("-l") + 1]
    k, v = sel.split("=")
    print(json.dumps({"items": [p for p in st["pods"] if p["metadata"]["namespace"] == ns and p["metadata"]["labels"].get(k) == v]})); sys.exit(0)
if a[0] == "create" and a[1] == "--raw":
    name = a[2].split("/pods/")[1].split("/")[0]
    if st.get("refuse"):
        sys.stderr.write("Cannot evict pod as it would violate the pod's disruption budget. (TooManyRequests)\n"); sys.exit(1)
    p = next(p for p in st["pods"] if p["metadata"]["name"] == name)
    if st.get("noroom"):  # the replacement lands where it was (no empty node it may use)
        p["metadata"]["name"] = name + "-n"; p["metadata"]["creationTimestamp"] = "2026-10-28T20:00:00Z"
    else:
        free = [n["metadata"]["name"] for n in st["nodes"] if not any(q["spec"]["nodeName"] == n["metadata"]["name"] for q in st["pods"] if q["metadata"]["labels"] == p["metadata"]["labels"])
                and not n["spec"].get("unschedulable") and not n["spec"].get("taints")]
        zone = lambda nd: next((n["metadata"].get("labels", {}).get("topology.kubernetes.io/zone", "") for n in st["nodes"] if n["metadata"]["name"] == nd), "")
        held = {zone(q["spec"]["nodeName"]) for q in st["pods"] if q is not p and q["metadata"]["labels"] == p["metadata"]["labels"]}
        free = [n for n in free if zone(n) not in held] + [n for n in free if zone(n) in held]  # the zone spread: an empty zone first
        p["spec"]["nodeName"] = free[0] if free else p["spec"]["nodeName"]
        p["metadata"]["name"] = name + "-n"; p["metadata"]["creationTimestamp"] = "2026-10-28T20:00:00Z"
    save(); sys.exit(0)
sys.exit(1)
S
chmod +x "$W/bin/kubectl"
export KUBECTL="$W/bin/kubectl"

mk() { # <variant>
  : >"$CALLS"
  python3 -I - "$ST" "$1" <<'PY'
import json, sys
st_path, v = sys.argv[1:3]
def node(n, ready=True, cordon=False, taints=None, zone=None):
    return {"metadata": {"name": n, "labels": {"topology.kubernetes.io/zone": zone} if zone else {}}, "spec": {"unschedulable": cordon, "taints": taints or []},
            "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}}
def pod(ns, name, nd, labels, created="2026-10-28T10:00:00Z", tols=None):
    return {"metadata": {"namespace": ns, "name": name, "labels": labels, "creationTimestamp": created},
            "spec": {"nodeName": nd, "tolerations": tols or []}, "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}
BARMAN = {"app": "barman-cloud"}
GW = {"gateway.networking.k8s.io/gateway-name": "openaether-gateway"}
cp = node("cp-0", taints=[{"key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule"}])
nodes = [cp, node("w-0"), node("w-1"), node("w-2")]
pods = [pod("services-gateway", "gw-a", "w-0", GW), pod("services-gateway", "gw-b", "w-1", GW), pod("services-gateway", "gw-c", "w-2", GW),
        pod("cnpg-system", "bar-a", "w-0", BARMAN), pod("cnpg-system", "bar-b", "w-1", BARMAN)]
st = {}
if v == "ok": pass
elif v == "stacked":  # both plugin pods on w-0 (lab 27 part C), the third gateway pod joined w-1 and w-2 is empty
    pods[4]["spec"]["nodeName"] = "w-0"; pods[4]["metadata"]["creationTimestamp"] = "2026-10-28T11:00:00Z"
    pods[2]["spec"]["nodeName"] = "w-1"; pods[2]["metadata"]["creationTimestamp"] = "2026-10-28T11:00:00Z"
elif v == "forced":  # w-1 and w-2 are gone: two pods on one node is the only legal shape
    pods[4]["spec"]["nodeName"] = "w-0"; pods = [p for p in pods if p["metadata"]["namespace"] == "cnpg-system"]
    nodes = [cp, node("w-0"), node("w-1", ready=False), node("w-2", cordon=True)]
elif v == "tainted-empty":  # the only empty node is the control plane, which the pods do not tolerate
    pods[4]["spec"]["nodeName"] = "w-0"; pods = [p for p in pods if p["metadata"]["namespace"] == "cnpg-system"]
    nodes = [cp, node("w-0")]
elif v == "refused":
    pods[4]["spec"]["nodeName"] = "w-0"; st["refuse"] = True
elif v == "noroom":
    pods[4]["spec"]["nodeName"] = "w-0"; st["noroom"] = True
elif v == "absent": pods = []
elif v.startswith("zones"):  # CoreDNS only (the lab 28 install: 3 pods on 3 DIFFERENT nodes, all in zone b); the control planes are eligible (tolerated)
    DNS = {"k8s-app": "kube-dns"}
    tol = [{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}]
    cpt = [{"key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule"}]
    z = {"cp-0": "a", "cp-1": "b", "cp-2": "c", "w-0": "a", "w-1": "b", "w-2": "c", "w-3": "a", "w-4": "b", "w-5": "c"}
    nodes = [node(n, taints=cpt if n.startswith("cp") else None, zone=z[n]) for n in z]
    where = ["cp-1", "w-1", "w-4"]  # zone b three times: one pod per node, the hard spread over nodes is met
    if v == "zones-ok": where = ["cp-0", "w-1", "w-2"]
    elif v == "zones-two":  # only two zones have an eligible node (c is NotReady and cordoned): {2, 1} is the best that fits
        nodes = [node(n, ready=n[-1] not in "25", taints=cpt if n.startswith("cp") else None, zone=z[n]) for n in z]
        where = ["cp-0", "w-3", "w-1"]
    elif v == "zones-nolabel":  # the third zone's nodes carry no label: only two ZONES are known
        nodes = [node(n, taints=cpt if n.startswith("cp") else None, zone=z[n] if z[n] != "c" else None) for n in z]
    pods = [pod("kube-system", "dns-%d" % i, nd, DNS, created="2026-10-28T1%d:00:00Z" % i, tols=tol) for i, nd in enumerate(where)]
    if v == "zones-noroom": st["noroom"] = True
st.update(nodes=nodes, pods=pods)
json.dump(st, open(st_path, "w"))
PY
}
out=""; rc=0
run() { out="$(python3 -I "$SUT" "$@" 2>&1)"; rc=$?; }
evictions() { grep -c -- '--raw' "$CALLS"; }
nodes_of() { python3 -I -c 'import json,sys; st=json.load(open(sys.argv[1])); print(" ".join(sorted(p["spec"]["nodeName"] for p in st["pods"] if p["metadata"]["labels"].get(sys.argv[2])==sys.argv[3])))' "$ST" "$1" "$2"; }

mk ok; run --check
{ [ "$rc" = 0 ] && [ "$(evictions)" = 0 ]; } && ok_ "one pod per node: --check passes" || bad "placed cluster: rc $rc / $out"
mk ok; run
[ "$rc" = 0 ] && ok_ "the default is --check" || bad "default mode rc $rc"

mk stacked; run --check
{ [ "$rc" = 3 ] && [ "$(evictions)" = 0 ] && grep -q "Barman Cloud plugin: node(s) w-0 hold 2" <<<"$out" && grep -q "Istio Gateway: node(s) w-1 hold 2" <<<"$out" \
  && grep -q "task cluster-rebalance" <<<"$out"; } && ok_ "stacked plugin pair and stacked Gateway: --check exits 3, names the nodes, writes nothing" || bad "stacked --check rc $rc / $out"

mk stacked; run --apply
{ [ "$rc" = 0 ] && [ "$(evictions)" = 2 ] && [ "$(nodes_of app barman-cloud)" = "w-0 w-1" ] \
  && [ "$(nodes_of gateway.networking.k8s.io/gateway-name openaether-gateway)" = "w-0 w-1 w-2" ]; } \
  && ok_ "--apply: exactly two evictions, the plugin pair is on 2 nodes and the Gateway on 3" || bad "stacked --apply rc $rc / evictions $(evictions) / $out"
grep -q "evict cnpg-system/bar-b" <<<"$out" && ok_ "the NEWEST pod of the stacked node is the one evicted" || bad "wrong victim: $out"
run --check; [ "$rc" = 0 ] && ok_ "after --apply, --check passes" || bad "check after apply rc $rc"

mk forced; run --check
{ [ "$rc" = 0 ] && [ "$(evictions)" = 0 ]; } && ok_ "NotReady and cordoned nodes are not empty nodes: a forced stack is not wrong" || bad "forced rc $rc / $out"
mk tainted-empty; run --apply
{ [ "$rc" = 0 ] && [ "$(evictions)" = 0 ]; } && ok_ "a control plane the pods do not tolerate is not an empty node" || bad "tainted rc $rc / $out"

mk refused; run --apply
{ [ "$rc" = 1 ] && grep -q "refused" <<<"$out"; } && ok_ "an eviction the PDB refuses is retried, then the run FAILS" || bad "refused rc $rc / $out"
mk noroom; run --apply
{ [ "$rc" = 1 ] && [ "$(evictions)" -le 4 ] && grep -q "still stacked" <<<"$out"; } && ok_ "a group that stays stacked fails the run after a bounded number of evictions ($(evictions))" || bad "noroom rc $rc / $out"
zones_of() { python3 -I -c 'import json,sys; st=json.load(open(sys.argv[1])); z={n["metadata"]["name"]: n["metadata"].get("labels",{}).get("topology.kubernetes.io/zone","") for n in st["nodes"]}; print(" ".join(sorted(z[p["spec"]["nodeName"]] for p in st["pods"] if p["metadata"]["labels"].get(sys.argv[2])==sys.argv[3])))' "$ST" "$1" "$2"; }

mk zones-ok; run --check
{ [ "$rc" = 0 ] && [ "$(evictions)" = 0 ] && grep -q "ok CoreDNS: 3 pod(s) on 3 node(s)" <<<"$out"; } && ok_ "CoreDNS one per zone: --check passes" || bad "zones-ok rc $rc / $out"
mk zones; run --check
{ [ "$rc" = 3 ] && [ "$(evictions)" = 0 ] && grep -q "x CoreDNS: zone(s) b hold 2 or more of its pods while a, c hold none" <<<"$out" && grep -q "task cluster-rebalance" <<<"$out"; } \
  && ok_ "lab 28: three CoreDNS pods on three nodes of ONE zone while two zones are empty: --check exits 3, names the zones, writes nothing" || bad "zones --check rc $rc / $out"
mk zones; run --apply
{ [ "$rc" = 0 ] && [ "$(evictions)" = 2 ] && [ "$(zones_of k8s-app kube-dns)" = "a b c" ] && grep -q "evict kube-system/dns-2 (newest pod of zone b)" <<<"$out"; } \
  && ok_ "--apply: two evictions, the newest pod of the stacked zone each time, one CoreDNS pod per zone at the end" || bad "zones --apply rc $rc / evictions $(evictions) / $out"
run --check; [ "$rc" = 0 ] && ok_ "after --apply, --check passes" || bad "zones check after apply rc $rc"
mk zones-two; run --check
{ [ "$rc" = 0 ] && [ "$(evictions)" = 0 ]; } && ok_ "only two zones have an eligible node (the third is NotReady): two pods in one zone are not wrong, the zone spread is a preference" || bad "zones-two rc $rc / $out"
mk zones-nolabel; run --check
{ [ "$rc" = 0 ] && [ "$(evictions)" = 0 ]; } && ok_ "nodes without a zone label are not a zone: two known zones, nothing judged" || bad "zones-nolabel rc $rc / $out"
mk zones-noroom; run --apply
{ [ "$rc" = 1 ] && grep -q "CoreDNS: still stacked" <<<"$out"; } && ok_ "a zone stack that cannot be fixed fails the run" || bad "zones-noroom rc $rc / $out"

mk absent; run --apply
{ [ "$rc" = 0 ] && grep -q "not installed yet" <<<"$out"; } && ok_ "absent groups are not an error" || bad "absent rc $rc / $out"
run --bogus; [ "$rc" = 2 ] && ok_ "an unknown argument is a usage error" || bad "usage rc $rc"

# wiring: the callers and the verdict (a static check; the flows themselves are proven on a cluster)
for f in scripts/ops/rolling-replace.sh scripts/ops/node-recovery.sh; do
  grep -q 'cluster-rebalance.py' "$ROOT/$f" && ok_ "$f runs the rebalance after the node is back" || bad "$f does not run cluster-rebalance.py"
done
grep -q 'cluster-rebalance.py" --check' "$ROOT/scripts/dev/infra-verify.sh" && ok_ "cluster-verify fails on a stacked critical pod" || bad "infra-verify.sh lacks the rebalance check"
python3 -I - "$ROOT/Taskfile.yml" <<'PY' && ok_ "cluster-up runs cluster-rebalance APPLY=1 before cluster-verify" || bad "cluster-up does not rebalance before its verify"
import re, sys
t = open(sys.argv[1]).read()
up = t[t.index("\n  cluster-up:"):t.index("\n  infra-apply:")]
a, v = up.index("task: cluster-rebalance"), up.rindex("task: cluster-verify")
sys.exit(0 if a < v and 'APPLY: "1"' in up[a:a + 200] else 1)
PY

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
