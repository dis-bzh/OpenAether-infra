#!/usr/bin/env bash
# scripts/ops/replaced-node-cleanup.py against a fake kubectl that serves JSON fixtures and logs every call. Fixtures follow lab 21
# (worker replaced; 2 CNPG instances, an OpenBao member, loki-0 and vmselect-0 on local-path volumes of the old disk); node and
# object names are placeholders. What it pins: only volumes pinned to THE replaced node and created BEFORE its new Node are
# touched; the default prints and deletes nothing; --clean deletes only the safe cases (CNPG replica with a healthy primary, OpenBao
# with a raft majority left, Loki/VM with another Ready replica) and refuses the primary of record, a lost majority, an unknown
# workload; one deletion per workload per run; a Ready pod is left alone; nothing happens before the new Node is Ready.
# Usage: test-replaced-node-cleanup.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/replaced-node-cleanup.py}"
W="$(mktemp -d)"; trap 'rm -rf "${W:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
mkdir -p "$W/bin" "$W/fx"; export ST="$W/fx" CALLS="$W/calls.log"
cat >"$W/bin/kubectl" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case " $* " in
  *" delete "*) exit 0 ;;
  *" get crd volumes.longhorn.io "*) [ -f "$ST/volumes.longhorn.io.json" ] ;;
  *" get nodes "*) cat "$ST/nodes.json" ;;
  *" get pv "*) cat "$ST/pv.json" ;;
  *" get pvc "*) cat "$ST/pvc.json" ;;
  *" get pods "*) cat "$ST/pods.json" ;;
  *" get clusters.postgresql.cnpg.io "*) cat "$ST/clusters.json" ;;
  *" get statefulsets "*) cat "$ST/sts.json" ;;
  *" get volumes.longhorn.io "*) cat "$ST/volumes.longhorn.io.json" ;;
  *" get replicas.longhorn.io "*) echo '{"items":[]}' ;;
  *) exit 1 ;;
esac
S
chmod +x "$W/bin/kubectl"

# scenario builder: python writes the fixtures; $1 names the variant
mk() {
  rm -f "${ST:?}"/*.json "${CALLS:?}"; : >"$CALLS"
  python3 -I - "$ST" "$1" <<'PY'
import json, sys
st, v = sys.argv[1], sys.argv[2]
OLD, NEW, NODE = "2026-10-21T10:00:00Z", "2026-10-21T16:40:00Z", "worker-3"
def ready(b=True): return [{"type": "Ready", "status": "True" if b else "False"}]
def pv(name, node, claim, ns, cls="local-path-retain", created=OLD, phase="Bound", retain=True):
    return {"metadata": {"name": name, "creationTimestamp": created}, "status": {"phase": phase},
            "spec": {"storageClassName": cls, "persistentVolumeReclaimPolicy": "Retain" if retain else "Delete",
                     "claimRef": {"namespace": ns, "name": claim} if claim else None,
                     "nodeAffinity": {"required": {"nodeSelectorTerms": [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": [node]}]}]}}}}
def pvc(ns, name): return {"metadata": {"namespace": ns, "name": name}}
def pod(ns, name, claim, ok=False, labels=None, sts=None, state="CrashLoopBackOff"):
    p = {"metadata": {"namespace": ns, "name": name, "labels": labels or {}}, "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": claim}}] if claim else []},
         "status": {"phase": "Running", "conditions": ready(ok), "containerStatuses": [] if ok else [{"state": {"waiting": {"reason": state}}}]}}
    if sts: p["metadata"]["ownerReferences"] = [{"kind": "StatefulSet", "name": sts}]
    return p
def cn(ns, cl, i, ok=True): return pod(ns, f"{cl}-{i}", f"{cl}-{i}", ok, {"cnpg.io/cluster": cl, "cnpg.io/instanceName": f"{cl}-{i}"})
nodes = [{"metadata": {"name": NODE, "creationTimestamp": NEW}, "status": {"conditions": ready(v != "notready")}}]
pvs = [pv("pv-g1", NODE, "grafana-db-1", "foundation-databases"), pv("pv-z2", NODE, "zitadel-db-2", "foundation-databases"),
       pv("pv-other", "worker-1", "zitadel-db-1", "foundation-databases"),                       # another node
       pv("pv-fresh", NODE, "fresh-0", "apps", created="2026-10-21T17:00:00Z")]                    # created after the replacement
pvcs = [pvc("foundation-databases", n) for n in ("grafana-db-1", "grafana-db-2", "zitadel-db-1", "zitadel-db-2")] + [pvc("apps", "fresh-0")]
pods = [cn("foundation-databases", "grafana-db", 1, False), cn("foundation-databases", "grafana-db", 2),
        cn("foundation-databases", "zitadel-db", 1), cn("foundation-databases", "zitadel-db", 2, False),
        pod("apps", "fresh-0", "fresh-0", True)]
clusters = [{"metadata": {"namespace": "foundation-databases", "name": "grafana-db"}, "status": {"currentPrimary": "grafana-db-2"}},
            {"metadata": {"namespace": "foundation-databases", "name": "zitadel-db"}, "status": {"currentPrimary": "zitadel-db-1"}}]
sts = []
if v == "primary-on-old-disk":
    clusters[0]["status"]["currentPrimary"] = "grafana-db-1"
if v == "primary-not-ready":
    pods[1] = cn("foundation-databases", "grafana-db", 2, False)
if v == "two-in-one-cluster":
    pvs.append(pv("pv-z3", NODE, "zitadel-db-3", "foundation-databases")); pvcs.append(pvc("foundation-databases", "zitadel-db-3"))
    pods.append(cn("foundation-databases", "zitadel-db", 3, False))
if v == "ready-pod":
    pods[0] = cn("foundation-databases", "grafana-db", 1, True)
if v in ("openbao-ok", "openbao-lost-majority"):
    pvs.append(pv("pv-bao", NODE, "data-openbao-1", "foundation-vault")); pvcs.append(pvc("foundation-vault", "data-openbao-1"))
    pods.append(pod("foundation-vault", "openbao-1", "data-openbao-1", False, sts="openbao"))
    pods.append(pod("foundation-vault", "openbao-0", "data-openbao-0", True, sts="openbao"))
    pods.append(pod("foundation-vault", "openbao-2", "data-openbao-2", v == "openbao-ok", sts="openbao"))
    sts.append({"metadata": {"namespace": "foundation-vault", "name": "openbao"}, "spec": {"replicas": 3}})
if v in ("loki-alone", "loki-ok", "vmselect-ok"):
    name = "vmselect-victoria-metrics" if v == "vmselect-ok" else "loki"
    pvs.append(pv("pv-x", NODE, "data-%s-0" % name, "services-observability", cls="local-path", retain=False)); pvcs.append(pvc("services-observability", "data-%s-0" % name))
    pods.append(pod("services-observability", name + "-0", "data-%s-0" % name, False, sts=name, state="Pending"))
    pods.append(pod("services-observability", name + "-1", "data-%s-1" % name, v != "loki-alone", sts=name))
    sts.append({"metadata": {"namespace": "services-observability", "name": name}, "spec": {"replicas": 2}})
if v == "unknown":
    pvs.append(pv("pv-app", NODE, "data-app-0", "apps")); pvcs.append(pvc("apps", "data-app-0"))
    pods.append(pod("apps", "app-0", "data-app-0", False, sts="app"))
if v == "orphan":
    pvs.append(pv("pv-orphan", NODE, "gone-0", "apps", phase="Released"))
if v == "none":
    pvs = [pv("pv-other", "worker-1", "zitadel-db-1", "foundation-databases")]
if v == "longhorn-faulted":
    json.dump({"items": [{"metadata": {"name": "pvc-abc"}, "status": {"robustness": "faulted"}}]}, open(st + "/volumes.longhorn.io.json", "w"))
for name, items in (("nodes", nodes), ("pv", pvs), ("pvc", pvcs), ("pods", pods), ("clusters", clusters), ("sts", sts)):
    json.dump({"items": items}, open("%s/%s.json" % (st, name), "w"))
PY
}
run() { KUBECTL="$W/bin/kubectl" python3 -I "$SUT" "$@" >"$W/out.txt" 2>&1; echo $? >"$W/rc"; }
deleted() { grep -c " delete " "$CALLS"; }
rc() { cat "$W/rc"; }
has() { grep -q -- "$1" "$W/out.txt"; }
called() { grep -q -- "$1" "$CALLS"; }

mk base; run --node worker-3
{ [ "$(rc)" = 0 ] && [ "$(deleted)" = 0 ] && has "grafana-db-1" && has "not run"; } && ok_ "default: lists the stale volumes and the commands, deletes nothing" || bad "default mode ($(rc), $(deleted) deletes)"
has "STALE=2 CLEAN=2 REFUSED=0 DEFERRED=0" && ok_ "only the 2 volumes of the replaced node created before it are stale (another node's and a fresh one are not)" || bad "stale count: $(tail -1 "$W/out.txt")"

mk base; run --node worker-3 --clean
{ [ "$(rc)" = 0 ] && called "-n foundation-databases delete pod grafana-db-1 pvc grafana-db-1" && called "delete pv pv-g1" && called "delete pod zitadel-db-2 pvc zitadel-db-2" && called "delete pv pv-z2"; } && ok_ "--clean drops the 2 CNPG replicas (pod, claim, retained volume)" || bad "--clean CNPG ($(rc)): $(cat "$CALLS")"
{ ! called "pv-other" && ! called "pv-fresh" && ! called "fresh-0" && ! called "zitadel-db-1" && ! called "grafana-db-2"; } && ok_ "--clean touches nothing of another node, a newer volume, or a healthy instance" || bad "--clean touched too much: $(cat "$CALLS")"

mk primary-on-old-disk; run --node worker-3 --clean
{ [ "$(rc)" = 1 ] && has "primary of record" && ! called "delete pod grafana-db-1"; } && ok_ "the primary of record is refused (rc 1), nothing deleted for it" || bad "primary refusal ($(rc))"
called "delete pod zitadel-db-2" && ok_ "the other cluster's safe replica is still cleaned" || bad "other cluster not cleaned"

mk primary-not-ready; run --node worker-3 --clean
{ [ "$(rc)" = 1 ] && has "without a healthy" && ! called "delete pod grafana-db-1"; } && ok_ "a replica is kept while its primary is not Ready" || bad "primary-not-ready ($(rc))"

mk two-in-one-cluster; run --node worker-3 --clean
{ called "delete pod zitadel-db-2" && ! called "delete pod zitadel-db-3" && has "DEFERRED=1" && [ "$(rc)" = 1 ]; } && ok_ "two instances of one cluster: one per run, the other deferred" || bad "defer ($(rc)): $(cat "$CALLS")"

mk ready-pod; run --node worker-3 --clean
{ ! called "delete pod grafana-db-1" && has "nothing to do"; } && ok_ "a Ready pod on a re-created volume is left alone" || bad "ready pod touched"

mk openbao-ok; run --node worker-3 --clean
{ called "-n foundation-vault delete pod openbao-1 pvc data-openbao-1" && called "delete pv pv-bao"; } && ok_ "OpenBao: 2 of 3 Ready (a raft majority) -> the member, its claim and the retained volume are dropped" || bad "openbao-ok ($(rc)): $(cat "$CALLS")"
mk openbao-lost-majority; run --node worker-3 --clean
{ ! called "delete pod openbao-1" && has "only 1 other Ready"; } && ok_ "OpenBao: 1 other Ready of 3 is no majority -> refused" || bad "openbao-lost-majority"

mk loki-ok; run --node worker-3 --clean
{ called "-n services-observability delete pod loki-0 pvc data-loki-0" && ! called "delete pv pv-x"; } && ok_ "Loki with another Ready replica: pod and claim dropped, no retained volume to delete (class local-path)" || bad "loki-ok: $(cat "$CALLS")"
mk loki-alone; run --node worker-3 --clean
{ ! called "delete pod loki-0" && has "REFUSED=1"; } && ok_ "Loki with no other Ready replica is refused" || bad "loki-alone"
mk vmselect-ok; run --node worker-3 --clean
called "delete pod vmselect-victoria-metrics-0" && ok_ "vmselect with another Ready replica is dropped" || bad "vmselect-ok"

mk unknown; run --node worker-3 --clean
{ ! called "app-0" && has "not a known safe case" && [ "$(rc)" = 1 ]; } && ok_ "an unknown workload is listed and refused" || bad "unknown"

mk orphan; run --node worker-3 --clean
called "delete pv pv-orphan" && ok_ "a Released retained volume of the old disk with no claim is deleted" || bad "orphan"

mk none; run --node worker-3
{ [ "$(rc)" = 0 ] && has "nothing to clean"; } && ok_ "nothing stale: says so, rc 0" || bad "none"

mk notready; run --node worker-3 --clean
{ [ "$(rc)" = 1 ] && [ "$(deleted)" = 0 ] && has "not Ready"; } && ok_ "the replacement Node not Ready: nothing is deleted" || bad "notready"
mk base; run --node worker-9
{ [ "$(rc)" = 1 ] && [ "$(deleted)" = 0 ] && has "does not exist"; } && ok_ "an unknown Node: refused, nothing deleted" || bad "unknown node"
mk longhorn-faulted; run --node worker-3
has "FAULTED" && ok_ "a faulted Longhorn volume is reported, never touched" || bad "longhorn faulted"
python3 -I "$SUT" >/dev/null 2>&1; [ $? = 2 ] && ok_ "no --node: usage, rc 2" || bad "usage"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
