#!/usr/bin/env python3
"""After `task cluster-replace-node`: the pods that cannot start because their volume stayed pinned to the OLD disk (0.4.0, lab 21).

A replaced node keeps its name and gets a new, empty disk. A local-path volume (a PV with a hostname node affinity to that name)
created BEFORE the new Node object points at data that no longer exists: the pod mounts an empty directory, owned by root, and
crash-loops or stays Pending. Lab 21 met it for 2 CNPG instances, an OpenBao member, loki-0 and vmselect-0. The databases and the
raft peer re-sync from their healthy peers once the stale volume is dropped; nothing else does it for them.

Default: print what is stale and the exact commands. --clean runs them, for the SAFE cases only:
  * a CNPG instance whose Cluster has a healthy primary elsewhere (never the primary of record);
  * an OpenBao member while the others still hold a raft quorum (they must be Ready, which means unsealed);
  * Loki, vmstorage, vmselect while at least one other replica is Ready;
and only for volumes created before the replacement Node. Everything else is listed and refused. One deletion per workload per run
(the next waits for the first to be Ready: rerun). Longhorn replicas are reported, never deleted (Longhorn rebuilds them).

Usage: replaced-node-cleanup.py --node NAME [--clean]    (KUBECTL overrides the kubectl command line; the tests use it)
Exit: 0 nothing to do, or printed, or cleaned; 1 something refused or deferred or failed under --clean; 2 usage.
"""
import json
import os
import shlex
import subprocess
import sys

HOST = "kubernetes.io/hostname"
# workload -> how many OTHER ready replicas it needs before a member may be dropped ("quorum" = a raft majority without it)
SAFE_STS = {
    ("foundation-vault", "openbao"): "quorum",
    ("services-observability", "loki"): 1,
    ("services-observability", "vmselect-victoria-metrics"): 1,
    ("services-observability", "vmstorage-victoria-metrics"): 1,
}


def kubectl_cmd():
    return shlex.split(os.environ.get("KUBECTL") or "kubectl --kubeconfig ./kubeconfig --request-timeout=30s")


def kget(*args, required=True):
    r = subprocess.run(kubectl_cmd() + ["get", *args, "-o", "json"], capture_output=True, text=True)
    if r.returncode:
        if required:
            sys.exit("kubectl get %s failed: %s" % (" ".join(args), r.stderr.strip()[-200:]))
        return None
    return json.loads(r.stdout or "{}")


def ready(pod):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in pod.get("status", {}).get("conditions", []))


def pinned_to(pv, node):
    terms = pv.get("spec", {}).get("nodeAffinity", {}).get("required", {}).get("nodeSelectorTerms", [])
    return any(e.get("key") == HOST and node in e.get("values", []) for t in terms for e in t.get("matchExpressions", []))


def owner_sts(pod):
    return next((o["name"] for o in pod["metadata"].get("ownerReferences", []) if o.get("kind") == "StatefulSet"), None)


def pod_state(pod):
    for cs in pod.get("status", {}).get("containerStatuses", []):
        w = cs.get("state", {}).get("waiting")
        if w and w.get("reason"):
            return w["reason"]
    return pod.get("status", {}).get("phase", "Unknown")


def plan(node, nodes, pvs, pvcs, pods, clusters, stss, longhorn):
    """Returns (items, notes). An item: dict(kind, ns, pod, pvc, pv, state, verdict, why, group, cmds)."""
    n = next((x for x in nodes if x["metadata"]["name"] == node), None)
    if n is None:
        return None, ["the Node %s does not exist: the replacement is not registered yet" % node]
    if not any(c.get("type") == "Ready" and c.get("status") == "True" for c in n["status"].get("conditions", [])):
        return None, ["the Node %s is not Ready: wait for the replacement, then run this again" % node]
    born = n["metadata"]["creationTimestamp"]
    stale = [p for p in pvs if pinned_to(p, node) and p["metadata"]["creationTimestamp"] < born]
    claims = {(c["metadata"]["namespace"], c["metadata"]["name"]): c for c in pvcs}
    items, notes = [], []
    for pv in sorted(stale, key=lambda p: p["metadata"]["name"]):
        ref = pv["spec"].get("claimRef") or {}
        ns, claim = ref.get("namespace"), ref.get("name")
        pvn = pv["metadata"]["name"]
        retain = pv["spec"].get("persistentVolumeReclaimPolicy") == "Retain"
        if not claim or (ns, claim) not in claims:
            if retain and pv.get("status", {}).get("phase") in ("Released", "Available"):
                items.append(dict(kind="orphan-pv", ns=ns or "-", pod="-", pvc=claim or "-", pv=pvn, state=pv["status"]["phase"],
                                  verdict="clean", why="a retained volume of the old disk, no claim: nothing can use it", group=None,
                                  cmds=[["delete", "pv", pvn, "--wait=false"]]))
            continue
        users = [p for p in pods if p["metadata"]["namespace"] == ns and any(
            v.get("persistentVolumeClaim", {}).get("claimName") == claim for v in p["spec"].get("volumes", []))]
        if not users:
            items.append(dict(kind="claim", ns=ns, pod="-", pvc=claim, pv=pvn, state="no pod", verdict="info",
                              why="a claim on the old disk with no pod (an instance being re-created?)", group=None, cmds=[]))
            continue
        for pod in users:
            name = pod["metadata"]["name"]
            it = dict(kind="", ns=ns, pod=name, pvc=claim, pv=pvn, state=pod_state(pod), verdict="", why="", group=None, cmds=[])
            if ready(pod):
                it.update(kind="running", verdict="info", why="Ready on a re-created empty volume: nothing to do")
                items.append(it)
                continue
            drop = [["-n", ns, "delete", "pod/" + name, "pvc/" + claim, "--wait=false"]] + ([["delete", "pv", pvn, "--wait=false"]] if retain else [])
            labels = pod["metadata"].get("labels", {})
            cl = labels.get("cnpg.io/cluster")
            sts = owner_sts(pod)
            if cl:
                it.update(kind="cnpg", group=("cnpg", ns, cl))
                cr = next((c for c in clusters if c["metadata"]["namespace"] == ns and c["metadata"]["name"] == cl), None)
                inst = labels.get("cnpg.io/instanceName", name)
                primary = (cr or {}).get("status", {}).get("currentPrimary")
                pp = next((p for p in pods if p["metadata"]["namespace"] == ns and p["metadata"].get("labels", {}).get("cnpg.io/cluster") == cl
                           and p["metadata"].get("labels", {}).get("cnpg.io/instanceName", p["metadata"]["name"]) == primary), None)
                if cr is None:
                    it.update(verdict="refuse", why="the Cluster %s/%s cannot be read" % (ns, cl))
                elif primary == inst:
                    it.update(verdict="refuse", why="%s is the primary of record: its data was on the replaced disk. Promote another "
                              "instance or restore (docs/resilience.md); nothing is deleted" % inst)
                elif pp is None or not ready(pp):
                    it.update(verdict="refuse", why="the primary %s is not Ready: dropping %s would leave the cluster without a healthy "
                              "member" % (primary, inst))
                else:
                    it.update(verdict="clean", why="replica of %s, healthy primary %s elsewhere; CNPG clones it again" % (cl, primary), cmds=drop)
            elif sts and (ns, sts) in SAFE_STS:
                need = SAFE_STS[(ns, sts)]
                it.update(kind="sts", group=("sts", ns, sts))
                s = next((x for x in stss if x["metadata"]["namespace"] == ns and x["metadata"]["name"] == sts), None)
                total = (s or {}).get("spec", {}).get("replicas", 0)
                others = [p for p in pods if p["metadata"]["namespace"] == ns and owner_sts(p) == sts and p["metadata"]["name"] != name and ready(p)]
                if need == "quorum":
                    need_n = total // 2 + 1
                    msg = "raft quorum is %d of %d" % (need_n, total)
                else:
                    need_n, msg = need, "needs %d other Ready replica(s)" % need
                if s is None or len(others) < need_n:
                    it.update(verdict="refuse", why="only %d other Ready member(s) of %s, %s: dropping %s would leave it without enough "
                              "healthy replicas" % (len(others), sts, msg, name))
                else:
                    it.update(verdict="clean", why="%d other member(s) of %s Ready (%s); it re-syncs from them" % (len(others), sts, msg), cmds=drop)
            else:
                it.update(kind="other", verdict="refuse",
                          why="not a known safe case (%s): look at the pod and its data before deleting anything" % (sts or "no StatefulSet"))
            items.append(it)
    # one deletion per workload per run
    seen = set()
    for it in items:
        if it["verdict"] == "clean" and it["group"]:
            if it["group"] in seen:
                it.update(verdict="defer", why="another member of %s/%s is dropped first; rerun when it is Ready" % it["group"][1:], cmds=[])
            seen.add(it["group"])
    for v in (longhorn or {}).get("volumes", []):
        if v.get("status", {}).get("robustness") == "faulted":
            notes.append("Longhorn volume %s is FAULTED: no healthy replica. Nothing is done here; see docs/resilience.md (restore)"
                         % v["metadata"]["name"])
    gone = [r for r in (longhorn or {}).get("replicas", []) if r.get("spec", {}).get("nodeID") == node and r.get("status", {}).get("currentState") in ("error", "stopped")]
    if gone:
        notes.append("%d Longhorn replica(s) on %s are failed or stopped: Longhorn rebuilds them from healthy replicas, nothing to delete"
                     % (len(gone), node))
    return items, notes


def main():
    import argparse
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--node")
    ap.add_argument("--clean", action="store_true")
    try:
        args, extra = ap.parse_known_args()
    except SystemExit:
        return 2
    if not args.node or extra:
        print("usage: replaced-node-cleanup.py --node NAME [--clean]", file=sys.stderr)
        return 2
    node, clean = args.node, args.clean
    lh = None
    if subprocess.run(kubectl_cmd() + ["get", "crd", "volumes.longhorn.io"], capture_output=True).returncode == 0:
        lh = {"volumes": (kget("volumes.longhorn.io", "-n", "longhorn-system", required=False) or {}).get("items", []),
              "replicas": (kget("replicas.longhorn.io", "-n", "longhorn-system", required=False) or {}).get("items", [])}
    items, notes = plan(
        node, kget("nodes")["items"], kget("pv")["items"], kget("pvc", "-A")["items"], kget("pods", "-A")["items"],
        (kget("clusters.postgresql.cnpg.io", "-A", required=False) or {}).get("items", []), kget("statefulsets", "-A")["items"], lh)
    if items is None:
        print("✗ " + notes[0], file=sys.stderr)
        return 1
    for n in notes:
        print("⚠ " + n)
    todo = [i for i in items if i["verdict"] in ("clean", "refuse", "defer")]
    if not items:
        print("✓ no volume of %s was left on the old disk: nothing to clean" % node)
        return 0
    print("Volumes pinned to the old disk of %s (created before the replacement Node):" % node)
    for i in items:
        print("  %-7s %-26s pod %-28s pvc %-28s %s: %s" % (i["verdict"].upper(), i["ns"], i["pod"], i["pvc"], i["state"], i["why"]))
    cmds = [(i, c) for i in items if i["verdict"] == "clean" for c in i["cmds"]]
    if cmds:
        print("Commands%s:" % ("" if clean else " (printed, not run; add --clean to run them)"))
        for _, c in cmds:
            print("  kubectl " + " ".join(shlex.quote(a) for a in c))
    bad = sum(1 for i in todo if i["verdict"] in ("refuse", "defer"))
    if clean:
        for _, c in cmds:
            r = subprocess.run(kubectl_cmd() + c, capture_output=True, text=True)
            print(("✓ ran: kubectl " if r.returncode == 0 else "✗ failed: kubectl ") + " ".join(c))
            if r.returncode:
                print(r.stderr.strip()[-300:], file=sys.stderr)
                bad += 1
        if cmds:
            print("Then wait for the pods to be Ready (kubectl get pods -A) and run this again: a deferred member, if any, goes next.")
    print("STALE=%d CLEAN=%d REFUSED=%d DEFERRED=%d" % (len(items), sum(i["verdict"] == "clean" for i in items),
                                                       sum(i["verdict"] == "refuse" for i in items), sum(i["verdict"] == "defer" for i in items)))
    return 1 if (clean and bad) else 0


if __name__ == "__main__":
    sys.exit(main())
