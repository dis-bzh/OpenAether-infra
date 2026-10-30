#!/usr/bin/env python3
"""Critical-path pods that share a node while another node has none: find them (--check) and put them back (--apply).

Lab 27 part C (E4): after a node loss or a drain the pods of a Deployment are rescheduled onto the nodes that are left, which is
legal at that moment, and they STAY there when the node returns: a spread constraint is read when a pod is scheduled, never
afterwards (the descheduler, which would do it, is not part of the platform). Measured: two Gateway pods on one node and none on
another; both Barman Cloud plugin pods on one node twice, and a partition of that node blocked the failover of a primary for 204 s
(target 75 s) because the CNPG operator cannot reconcile a plugin-enabled Cluster without a reachable plugin.

What it checks, per group below: the pods that are not terminating, the nodes that are Ready, not cordoned and whose NoSchedule /
NoExecute taints the group's pods tolerate. A group is WRONG when one node holds two of its pods while an eligible node holds none.
A cluster with fewer eligible nodes than replicas is NOT wrong (a drain on a 3-node cluster legitimately stacks).
CoreDNS is also judged per ZONE (lab 28, I2: after an install all three replicas sat in one zone, on three different nodes, so a zone
loss could take every DNS replica): wrong when one zone holds two of its pods while another zone that has an eligible node holds none,
but only when THREE or more zones have an eligible node (below that the spread over zones is a preference, as in the Deployment) and
only for nodes that carry the zone label.

--apply evicts ONE pod of a stacked node at a time (the newest, through the Eviction API, so the PodDisruptionBudget is honoured; a
429 is retried), waits until the group has all its replicas Ready again and reads the placement back. The replacement lands on
the empty node because the hard spread (Gateway, Barman Cloud, CoreDNS) or the scheduler's spread scoring (CNPG operator, istiod) puts it
there. Bounded: at most 2 x replicas evictions per group and OA_REBALANCE_TIMEOUT seconds (300) per eviction; a group that is still
wrong afterwards FAILS the run.

Usage: cluster-rebalance.py [--check | --apply]       (default --check; KUBECTL overrides the kubectl command line, the tests use it)
Exit: 0 every group is placed (or was made so); 3 --check found a stacked group (nothing written); 1 --apply could not fix it or a
read failed; 2 usage.
"""
import json
import os
import shlex
import subprocess
import sys
import time

# (title, namespace, label selector, judged per zone too). Pods WITHOUT local data only: a database instance is pinned to its volume's node.
GROUPS = [
    ("Istio Gateway", "services-gateway", "gateway.networking.k8s.io/gateway-name=openaether-gateway", False),
    ("Barman Cloud plugin", "cnpg-system", "app=barman-cloud", False),
    ("CNPG operator", "cnpg-system", "app.kubernetes.io/name=cloudnative-pg", False),
    ("istiod", "istio-system", "istio=pilot", False),
    ("CoreDNS", "kube-system", "k8s-app=kube-dns", True),
    ("Cilium operator", "kube-system", "io.cilium/app=operator", False),
]
ZONE = "topology.kubernetes.io/zone"
MIN_ZONES = 3  # fewer zones with an eligible node: the zone spread is a preference (modules/talos/coredns.yaml.tftpl, cluster-coredns-ha.sh)
TIMEOUT = int(os.environ.get("OA_REBALANCE_TIMEOUT", "300"))
POLL = float(os.environ.get("OA_REBALANCE_POLL", "5"))


def kubectl_cmd():
    return shlex.split(os.environ.get("KUBECTL") or "kubectl --kubeconfig ./kubeconfig --request-timeout=30s")


def run(args, stdin=None):
    return subprocess.run(kubectl_cmd() + args, capture_output=True, text=True, input=stdin)


def kget(*args):
    r = run(["get", *args, "-o", "json"])
    if r.returncode:
        sys.exit("kubectl get %s failed: %s" % (" ".join(args), r.stderr.strip()[-200:]))
    return json.loads(r.stdout or "{}")


def ready(obj):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in obj.get("status", {}).get("conditions", []))


def tolerates(tols, taint):
    for t in tols:
        if t.get("effect") not in (None, "", taint.get("effect")):
            continue
        if t.get("operator") == "Exists" and not t.get("key"):
            return True
        if t.get("key") != taint.get("key"):
            continue
        if t.get("operator") == "Exists" or t.get("value", "") == taint.get("value", ""):
            return True
    return False


def eligible_nodes(nodes, pod):
    """Ready, schedulable nodes whose blocking taints the pod tolerates."""
    tols = pod.get("spec", {}).get("tolerations") or []
    out = []
    for n in nodes:
        if n.get("spec", {}).get("unschedulable") or not ready(n):
            continue
        taints = [t for t in n.get("spec", {}).get("taints") or [] if t.get("effect") in ("NoSchedule", "NoExecute")]
        if all(tolerates(tols, t) for t in taints):
            out.append(n["metadata"]["name"])
    return out


def placement(ns, sel):
    """(pods by node, eligible nodes, pods, zone of every node) for one group; pods that terminate or have no node are skipped."""
    pods = [p for p in kget("pods", "-n", ns, "-l", sel).get("items", [])
            if not p["metadata"].get("deletionTimestamp") and p.get("spec", {}).get("nodeName")
            and p.get("status", {}).get("phase") in ("Running", "Pending")]
    if not pods:
        return {}, [], [], {}
    by = {}
    for p in pods:
        by.setdefault(p["spec"]["nodeName"], []).append(p)
    nodes = kget("nodes").get("items", [])
    zone_of = {n["metadata"]["name"]: (n["metadata"].get("labels") or {}).get(ZONE, "") for n in nodes}
    return by, eligible_nodes(nodes, pods[0]), pods, zone_of


def stacked(by, elig):
    """Nodes holding 2+ pods, when an eligible node holds none (else the stacking is forced)."""
    empty = [n for n in elig if n not in by]
    return ([n for n, ps in by.items() if len(ps) > 1], empty) if empty else ([], empty)


def zone_stacked(by, elig, zone_of):
    """Zones holding 2+ pods, when another zone with an eligible node holds none and MIN_ZONES or more zones have one (else it is a
    preference, or forced). Nodes without the zone label are no zone."""
    zones = {zone_of.get(n, "") for n in elig} - {""}
    if len(zones) < MIN_ZONES:
        return [], []
    held = {}
    for n, ps in by.items():
        z = zone_of.get(n, "")
        if z:
            held[z] = held.get(z, 0) + len(ps)
    empty = sorted(z for z in zones if z not in held)
    return (sorted(z for z, c in held.items() if c > 1), empty) if empty else ([], empty)


def wrong_shape(by, elig, zone_of, zoned):
    """(kind, stacked, empty) of the first problem: a node before a zone; None when the group is placed."""
    bad, empty = stacked(by, elig)
    if bad:
        return "node", sorted(bad), sorted(empty)
    if zoned:
        bad, empty = zone_stacked(by, elig, zone_of)
        if bad:
            return "zone", bad, empty
    return None


def victim_of(by, zone_of, kind, name):
    """The newest pod of the stacked node (or zone)."""
    pods = by[name] if kind == "node" else [p for n, ps in by.items() if zone_of.get(n) == name for p in ps]
    return max(pods, key=lambda p: p["metadata"].get("creationTimestamp", ""))["metadata"]["name"]


def evict(ns, name):
    body = json.dumps({"apiVersion": "policy/v1", "kind": "Eviction", "metadata": {"name": name, "namespace": ns}})
    deadline = time.time() + TIMEOUT
    while True:
        r = run(["create", "--raw", "/api/v1/namespaces/%s/pods/%s/eviction" % (ns, name), "-f", "-"], stdin=body)
        if r.returncode == 0:
            return True
        if "NotFound" in r.stderr or "not found" in r.stderr:
            return True
        if time.time() > deadline:
            print("  x eviction of %s/%s refused for %d s: %s" % (ns, name, TIMEOUT, r.stderr.strip()[-160:]))
            return False
        time.sleep(POLL)  # 429: the PodDisruptionBudget allows no disruption yet; wait for the group to be whole


def wait_whole(ns, sel, want):
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        pods = [p for p in kget("pods", "-n", ns, "-l", sel).get("items", []) if not p["metadata"].get("deletionTimestamp")]
        if len(pods) >= want and all(ready(p) for p in pods):
            return True
        time.sleep(POLL)
    return False


def main(argv):
    if len(argv) > 1 or (argv and argv[0] not in ("--check", "--apply")):
        print(__doc__.split("Usage:")[1].split("\n")[0].strip(), file=sys.stderr)
        return 2
    apply_ = bool(argv) and argv[0] == "--apply"
    wrong = 0
    for title, ns, sel, zoned in GROUPS:
        by, elig, pods, zone_of = placement(ns, sel)
        if not pods:
            print("  ~ %s: no pod (not installed yet): nothing to place" % title)
            continue
        found = wrong_shape(by, elig, zone_of, zoned)
        if not found:
            print("  ok %s: %d pod(s) on %d node(s), none shares a node while another eligible node is empty%s"
                  % (title, len(pods), len(by), "; none shares a zone while another zone is empty" if zoned else ""))
            continue
        kind, bad, empty = found
        msg = "%s: %s(s) %s hold 2 or more of its pods while %s hold none" % (title, kind, ", ".join(bad), ", ".join(empty))
        if not apply_:
            print("  x " + msg)
            wrong += 1
            continue
        print("  ~ " + msg + ": evicting one at a time")
        want = len(pods)
        for _ in range(2 * want):
            by, elig, pods, zone_of = placement(ns, sel)
            found = wrong_shape(by, elig, zone_of, zoned)
            if not found:
                break
            kind, bad, empty = found
            victim = victim_of(by, zone_of, kind, bad[0])
            print("    evict %s/%s (newest pod of %s%s)" % (ns, victim, "zone " if kind == "zone" else "", bad[0]))
            if not evict(ns, victim) or not wait_whole(ns, sel, want):
                break
        by, elig, pods, zone_of = placement(ns, sel)
        found = wrong_shape(by, elig, zone_of, zoned)
        if found:
            print("  x %s: still stacked on %s %s after the rebalance (is the capacity there? kubectl -n %s get pods -l %s -o wide)"
                  % (title, found[0], ", ".join(found[1]), ns, sel))
            wrong += 1
        else:
            print("  ok %s: now one pod per node%s" % (title, " and per zone" if zoned else ""))
    if wrong:
        print("%d group(s) share a node or a zone. Run: task cluster-rebalance PROVIDER=... APPLY=1" % wrong if not apply_ else "%d group(s) not rebalanced" % wrong)
        return 1 if apply_ else 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
