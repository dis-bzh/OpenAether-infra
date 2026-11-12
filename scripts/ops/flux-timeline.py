#!/usr/bin/env python3
"""Per-Kustomization / HelmRelease timeline of a Flux install (0.5.0, M0; apps #128).

Reads the output of
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A -o json
from a file or from standard input (read-only, no cluster call is made here) and prints a TSV, one line per object:
  kind  name  created_s  ready_s  wait_s  dependsOn
created_s and ready_s are seconds since the first object was created; wait_s is ready_s - created_s. Ready is the
lastTransitionTime of the Ready=True condition: an object that turned Ready again later (a re-reconcile after a
failure) shows its LAST transition, so run this once the install has settled and read an incident as an incident.
Then the critical path: the dependsOn chain that ends last, with the time each link added. An object that is not
Ready is printed with ready_s "-" and left out of the path.

Usage: flux-timeline.py [FILE|-]      Exit 0 fine, 2 usage or unreadable input.
"""
import json
import sys
from datetime import datetime


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").timestamp()


def collect(doc):
    objs = {}
    for it in doc.get("items", []):
        kind = it.get("kind", "?")
        meta = it.get("metadata", {})
        ns, name = meta.get("namespace", ""), meta.get("name", "")
        ready = None
        for c in it.get("status", {}).get("conditions", []):
            if c.get("type") == "Ready" and c.get("status") == "True":
                ready = ts(c["lastTransitionTime"])
        deps = [
            (d.get("namespace") or ns) + "/" + d["name"]
            for d in it.get("spec", {}).get("dependsOn", [])
        ]
        objs[ns + "/" + name] = {
            "kind": kind, "created": ts(meta["creationTimestamp"]), "ready": ready, "deps": deps,
        }
    return objs


def critical_path(objs):
    done = {k: v for k, v in objs.items() if v["ready"] is not None}
    if not done:
        return []
    cur = max(done, key=lambda k: done[k]["ready"])
    path = [cur]
    while True:
        deps = [d for d in objs[cur]["deps"] if d in done]
        if not deps:
            return path[::-1]
        cur = max(deps, key=lambda d: done[d]["ready"])
        path.append(cur)


def main(argv):
    if len(argv) > 1 or argv[:1] in (["-h"], ["--help"]):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        src = sys.stdin if not argv or argv[0] == "-" else open(argv[0])
        objs = collect(json.load(src))
    except (OSError, ValueError, KeyError) as e:
        print("✗ flux-timeline: cannot read the input: %s" % e, file=sys.stderr)
        return 2
    if not objs:
        print("✗ flux-timeline: no Kustomization or HelmRelease in the input", file=sys.stderr)
        return 2
    t0 = min(v["created"] for v in objs.values())
    print("kind\tname\tcreated_s\tready_s\twait_s\tdependsOn")
    for k, v in sorted(objs.items(), key=lambda kv: (kv[1]["ready"] is None, kv[1]["ready"] or 0, kv[0])):
        if v["ready"] is None:
            r, w = "-", "-"
        else:
            r, w = "%d" % (v["ready"] - t0), "%d" % (v["ready"] - v["created"])
        print("%s\t%s\t%d\t%s\t%s\t%s" % (v["kind"], k, v["created"] - t0, r, w, ",".join(v["deps"])))
    path = critical_path(objs)
    print("\ncritical path (ends at ready_s %d):" % (objs[path[-1]]["ready"] - t0))
    prev = t0
    for k in path:
        print("  %-60s +%ds" % (k, objs[k]["ready"] - prev))
        prev = objs[k]["ready"]
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
