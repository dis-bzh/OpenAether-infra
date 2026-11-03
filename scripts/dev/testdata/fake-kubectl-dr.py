#!/usr/bin/env python3
"""A stateful kubectl double for test-dr-restore-plan.sh: the cluster the chain restores into, as far as the chain looks at it.

FAKE_DR    state directory (calls.log: one line of argv per call, no stdin; state/ holds what the chain created)
FAKE_*     failure injections: FAKE_FAIL_SECRET=1 (the seal key Secret is refused), FAKE_BROKEN_CHAIN=1 (the restored canary chain is
           broken), FAKE_APPLY_STALE=1 (Flux never gives the Clusters the new archive name), FAKE_BACKUP_FAIL=1 (the base backup of the new archive
           fails), FAKE_NO_ARCHIVING=1 (ContinuousArchiving stays False), FAKE_VERIFY_FAIL=1 (the restore test of the rebuilt cluster fails), FAKE_NODES=n (nodes of the cluster),
           FAKE_KS_SLOW=n (a Kustomization is NotReady for the first n polls)
           FAKE_CRON_PRUNE=1 (the CronJob history limit prunes the Jobs made from it that still carry its owner reference), FAKE_JOB_GONE=<job> (that Job is
           NotFound), FAKE_JOB_PATCH_FAIL=1 (patching a Job is refused)
           FAKE_BAO_NOLEADER=<pod,...> (those OpenBao pods know no active node until the step restarts the pod alone: the delete of openbao-1
           and -2 together, which the step always does, does not cure them), FAKE_BAO_STUCK=1 (...not even then),
           FAKE_BAO_NOANSWER=<pod,...> (those pods do not answer sys/leader), FAKE_BAO_DOWN=<pod> (that pod does not answer exec at all),
           FAKE_BAO_SEALED=<pod> (that pod stays sealed until the step restarts it alone; FAKE_BAO_STUCK=1: not even then),
           FAKE_BAO_DOWNTIME=<n> (a pod restarted alone does not answer its next n `bao status`; a restart while another pod is down is written
           to quorum-lost.log: the raft quorum is gone)
           FAKE_BAO_MOVE=<n> (after n sys/leader calls the active node moves from openbao-0 to openbao-2 and openbao-0 follows no one until its
           pod is restarted: the check had passed when a proof lab's leader moved), FAKE_BAO_FLAP=1 (the active node changes at every survey)
           FAKE_ES_LATE=bad,unseeded,oidc-elsewhere,slow:n,none (a comma list; ExternalSecrets of observability: loki's never syncs / grafana-oidc, whose OpenBao key
           is never seeded, is NotReady / the same name is NotReady in ANOTHER namespace / the first n polls / the list is empty),
           FAKE_ES_EARLY_BAD=1 (an ExternalSecret that exists before the late group is NotReady)
           FAKE_HOLD_RESET=<ks> (the first read-back after the hold finds that Kustomization not suspended: a parent reconcile in flight;
           FAKE_HOLD_RESET_ALWAYS=1: every read-back does), FAKE_HOLD_READ_FAIL=1 (the first read-back fails: a transient API error)
           FAKE_CILIUM=stuck|stuck-forever|slow (the Cilium rollout does not finish: an agent stuck Terminating, which a force-delete frees / which
           stays Terminating, or is replaced by another that does / no pod Terminating at all)
           Grafana: a pg_restore into grafana-db after the Kustomization observability was released fails with the three dependency errors of lab 28B.
           A Kustomization is released by its own resume patch, AND by every resume of its parent openaether-platform: the parent re-applies its
           children, whose manifests carry no spec.suspend (a proof lab: a suspended child was reset within 10 s of the parent's reconcile)
Secrets are never written to calls.log: stdin is summarised (a length), --from-file contents are not copied there.
"""
import base64
import hashlib
import json
import os
import sys

D = os.environ["FAKE_DR"]
S = os.path.join(D, "state")
os.makedirs(S, exist_ok=True)


# Every file is opened in a `with`: nothing is left to the garbage collector to close.
def put(path, data, mode="w"):
    with open(path, mode) as fh:
        fh.write(data)


def get(path, mode="r"):
    with open(path, mode) as fh:
        return fh.read()


def put_json(path, obj):
    with open(path, "w") as fh:
        json.dump(obj, fh)


def get_json(path):
    with open(path) as fh:
        return json.load(fh)


a = sys.argv[1:]
if a[:1] == ["--kubeconfig"]:
    a = a[2:]
put(os.path.join(D, "calls.log"), " ".join(a) + "\n", "a")
A = " ".join(a)


def out(x):
    sys.stdout.write(x if isinstance(x, str) else json.dumps(x))
    sys.exit(0)


def f(*p):
    return os.path.join(S, *p)


def opt(flag):
    return a[a.index(flag) + 1] if flag in a else None


def patched():  # "<kustomization> suspend|resume", one per patch so far
    return get(f("patches.log")).splitlines() if os.path.exists(f("patches.log")) else []


PARENT = "openaether-platform"


def suspended():  # the Kustomizations suspended now: the patches replayed, and a resume of the parent resets every child (it re-applies them)
    s = set()
    for line in patched():
        name, act = line.split()
        if act == "suspend":
            s.add(name)
        else:
            s.discard(name)
            if name == PARENT:
                s = set()
    return s


def released(ks):  # was `ks` suspended by the hold and is it running now
    return (ks + " suspend") in patched() and ks not in suspended()


if "get --raw=/readyz" in A:
    out("ok")
if a[:2] == ["get", "nodes"]:
    out("".join(f"n{i} Ready control-plane 1m v1\n" for i in range(int(os.environ.get("FAKE_NODES", "6")))))
if a[:2] == ["create", "namespace"]:
    out("apiVersion: v1\nkind: Namespace\n")
if a[:1] == ["apply"]:
    body = sys.stdin.read()
    if body.strip().startswith("{"):
        d = json.loads(body)
        if d.get("kind") == "ConfigMap":
            put_json(f("cm-generation.json"), d)
        elif d.get("kind") == "Backup":
            put(f("backups.jsonl"), json.dumps(d) + "\n", "a")
        else:
            put(f("applied.jsonl"), json.dumps(d) + "\n", "a")
    sys.exit(0)
if "create secret generic openbao-seal-key" in A:
    if os.environ.get("FAKE_FAIL_SECRET"):
        sys.stderr.write("error: refused\n")
        sys.exit(1)
    path = [x for x in a if x.startswith("--from-file=key=")][0].split("=", 2)[2]
    put(f("sealkey"), get(path, "rb"), "wb")
    sys.exit(0)
if "get secret openbao-seal-key" in A:
    out(base64.b64encode(get(f("sealkey"), "rb")).decode() if os.path.exists(f("sealkey")) else "")
if "delete secret openbao-recovery-shares" in A:
    sys.exit(0)
if "create secret generic openbao-recovery-shares" in A:
    put_json(f("shares.json"), {x.split("=", 2)[1]: "x" for x in a if x.startswith("--from-file=")})
    sys.exit(0)
if "get secret openbao-recovery-shares" in A:
    out({"data": get_json(f("shares.json"))})
if "get pod openbao-0" in A:
    out("Running")
if "get job openbao-init" in A:
    out("1")
def gen_cm():
    return get_json(f("cm-generation.json")) if os.path.exists(f("cm-generation.json")) else None


if a[:5] == ["-n", "flux-system", "get", "configmap", "cnpg-archive-generation"]:
    cm = gen_cm()
    if cm is None:
        sys.stderr.write('Error from server (NotFound): configmaps "cnpg-archive-generation" not found\n')
        sys.exit(1)
    jp = opt("-o") or ""
    if jp.startswith("jsonpath={.data."):
        out(cm["data"].get(jp[len("jsonpath={.data."):-1], ""))
    out("cnpg-archive-generation\n")
if a[:3] == ["-n", "flux-system", "get"] and opt("-o") == "json":
    ks = {"foundation-vault": ["namespaces", "platform"], "namespaces": [], "platform": ["namespaces"], "external-secrets-stores": ["foundation-vault"],
          "cnpg": ["external-secrets-stores"], "backup-databases": ["cnpg"], "identity": ["cnpg"], "identity-gateway": ["identity"], "observability": [],
          PARENT: []}  # the parent is a Kustomization of the same namespace, outside OpenBao's closure, as on a cluster (it was in the held list of a proof lab)
    if os.environ.get("FAKE_HOLD_READ_FAIL") and any(x.endswith(" suspend") for x in patched()) and not os.path.exists(f("hold-read-fail")):
        put(f("hold-read-fail"), "1")  # the first read after the hold: a transient API error
        sys.stderr.write("Unable to connect to the server: net/http: TLS handshake timeout\n")
        sys.exit(1)
    sus = suspended()
    rst = os.environ.get("FAKE_HOLD_RESET")
    if rst and any(x.endswith(" suspend") for x in patched()) and (os.environ.get("FAKE_HOLD_RESET_ALWAYS") or not os.path.exists(f("hold-reset"))):
        put(f("hold-reset"), "1")
        sus.discard(rst)
    out({"items": [{"metadata": {"name": k}, "spec": dict({"dependsOn": [{"name": d} for d in v]}, **({"suspend": True} if k in sus else {}))}
                   for k, v in ks.items()]})
if a[:3] == ["-n", "flux-system", "get"] and "--no-headers" in a:
    n = int(get(f("ks-polls")) or 0) if os.path.exists(f("ks-polls")) else 0
    put(f("ks-polls"), str(n + 1))
    out("foundation-vault True\nplatform True\n" + ("observability False\n" if n < int(os.environ.get("FAKE_KS_SLOW", "0")) else ""))
if a[:3] == ["-n", "flux-system", "patch"]:
    put(f("patches.log"), a[4] + " " + ("suspend" if '"suspend":true' in A else "resume") + "\n", "a")
    sys.exit(0)
if a[:2] == ["-n", "foundation-vault"] and a[2:4] == ["exec", "-i"]:
    data = sys.stdin.buffer.read()
    first, _, rest = data.partition(b"\n")
    put(f("restore.log"), f"token_bytes={len(first)} snapshot_bytes={len(rest)} sha={hashlib.sha256(rest).hexdigest()[:12]}\n")
    sys.exit(0)
def pods_deleted():
    return get(f("pods-deleted.log")).split() if os.path.exists(f("pods-deleted.log")) else []


def restarted():  # the pods the step restarted ONE AT A TIME (a delete of a single pod); the first delete, openbao-1 and -2 together, is not one
    return get(f("pods-restarted.log")).split() if os.path.exists(f("pods-restarted.log")) else []


def down_left(pod):  # `bao status` calls left that this pod does not answer, after a restart alone (FAKE_BAO_DOWNTIME)
    return int(get(f("down-" + pod))) if os.path.exists(f("down-" + pod)) else 0


def sealed(pod):
    return os.environ.get("FAKE_BAO_SEALED") == pod and (pod not in restarted() or bool(os.environ.get("FAKE_BAO_STUCK")))


def in_list(var, pod):
    return pod in os.environ.get(var, "").split(",")


if a[:3] == ["-n", "foundation-vault", "exec"] and a[3:4] and a[3].startswith("openbao-") and "bao status" in A:
    pod = a[3]
    if os.environ.get("FAKE_BAO_DOWN") == pod:
        sys.stderr.write("error: unable to upgrade connection: container not found\n")
        sys.exit(1)
    if down_left(pod) > 0:
        put(f("down-" + pod), str(down_left(pod) - 1))
        sys.stderr.write("error: unable to upgrade connection: container not found\n")
        sys.exit(1)
    if sealed(pod):
        sys.stdout.write('{"initialized": true, "sealed": true}')  # `bao status` prints this and exits 2 on a sealed node
        sys.exit(2)
    out('{"initialized": true, "sealed": false}')
if a[:3] == ["-n", "foundation-vault", "delete"] and "pod" in a:
    names = [n for n in a[a.index("pod") + 1:] if n.startswith("openbao-")]
    for n in names:
        put(f("pods-deleted.log"), n + "\n", "a")
        if len(names) == 1:
            others = [p for p in ("openbao-0", "openbao-1", "openbao-2") if p != n]
            gone = [p for p in others if down_left(p) > 0 or sealed(p) or os.environ.get("FAKE_BAO_DOWN") == p]
            if gone:
                put(f("quorum-lost.log"), f"{n} deleted while {' '.join(gone)} down\n", "a")
            put(f("pods-restarted.log"), n + "\n", "a")
            put(f("down-" + n), os.environ.get("FAKE_BAO_DOWNTIME", "0"))
    sys.exit(0)
if a[:3] == ["-n", "foundation-vault", "exec"] and a[3:4] and a[3].startswith("openbao-") and "sys/leader" in A:
    pod = a[3]
    if in_list("FAKE_BAO_NOANSWER", pod):
        sys.stderr.write("error: unable to upgrade connection: container not found\n")
        sys.exit(1)
    if sealed(pod):
        sys.stderr.write("Error making API request.\n\nCode: 503. Errors:\n\n* Vault is sealed\n")
        sys.exit(2)
    # FAKE_BAO_NOLEADER=<pods>: those standbys know no active node until the step restarts the pod (FAKE_BAO_STUCK=1: not even then; lab 28B, apps #184)
    none = in_list("FAKE_BAO_NOLEADER", pod) and (pod not in restarted() or os.environ.get("FAKE_BAO_STUCK"))
    leader = "" if none else "https://openbao-1.openbao-internal.foundation-vault.svc:8200"
    move = os.environ.get("FAKE_BAO_MOVE")
    if os.environ.get("FAKE_BAO_FLAP"):  # the active node changes at every survey (three calls): the state never settles
        n = int(get(f("leader-calls")) or 0) + 1 if os.path.exists(f("leader-calls")) else 1
        put(f("leader-calls"), str(n))
        leader = f"https://openbao-{((n - 1) // 3) % 2}.openbao.foundation-vault.svc.cluster.local:8200"
    if move:  # openbao-0 is the active node for the first <move> calls, then openbao-2 is, and openbao-0 (a standby now) does not follow it
        n = int(get(f("leader-calls")) or 0) + 1 if os.path.exists(f("leader-calls")) else 1
        put(f("leader-calls"), str(n))
        who = "openbao-0" if n <= int(move) else "openbao-2"
        leader = f"https://{who}.openbao.foundation-vault.svc.cluster.local:8200"
        if n > int(move) and pod == "openbao-0" and ("openbao-0" not in restarted() or os.environ.get("FAKE_BAO_STUCK")):
            leader = ""
    out(json.dumps({"request_id": "", "lease_id": "", "lease_duration": 0, "renewable": False, "warnings": None,
                    "data": {"ha_enabled": True, "is_self": False, "leader_address": leader, "leader_cluster_address": leader.replace("8200", "8201")}}, indent=2))
LATE_ES = ["grafana-admin", "grafana-db-credentials", "grafana-oidc", "loki-s3-credentials"]
if a[:2] == ["get", "externalsecret"]:
    rows = "ns es True\n" * 3
    if os.environ.get("FAKE_ES_EARLY_BAD"):  # one that exists before the late group does, and never syncs
        rows = "ns es-early True\nns es-early2 True\nns es-broken SecretSyncedError False\n"
    if "observability resume" in patched():  # Grafana's and Loki's ExternalSecrets are created by the Kustomization (infra #426: late)
        modes = os.environ.get("FAKE_ES_LATE", "").split(",")
        slow = [int(m[5:]) for m in modes if m.startswith("slow:")]
        n = int(get(f("es-polls")) or 0) if os.path.exists(f("es-polls")) else 0
        put(f("es-polls"), str(n + 1))
        # bad: a real failure (Loki's S3 keys never sync); unseeded: grafana/oidc was never put in OpenBao (rung 3, a console step), which is the
        # state of every default install (a proof lab: SecretSyncedError "could not get secret data from provider" since the first install)
        for name in LATE_ES:
            ready = not (("bad" in modes and name == "loki-s3-credentials") or ("unseeded" in modes and name == "grafana-oidc")
                         or (slow and n < slow[0]))
            rows += f"services-observability {name} ClusterSecretStore openbao 1h " + ("SecretSynced True\n" if ready else "SecretSyncedError False\n")
        if "oidc-elsewhere" in modes:  # the same name in another namespace is not the optional one
            rows += "tenant-a grafana-oidc ClusterSecretStore openbao 1h SecretSyncedError False\n"
        if "none" in modes:  # the list comes back empty (kubectl prints "No resources found" on stderr): nothing to be not Ready is not a pass
            rows = ""
    out(rows)
if "get ds cilium" in A:
    out("daemonset.apps/cilium\n")
# FAKE_CILIUM=stuck: one agent pod is Terminating until it is force-deleted, the rollout cannot finish before; stuck-forever: the replacement does not come up
# either; slow: the rollout does not finish and no pod is Terminating (lab 28B, infra #428)
cilium = os.environ.get("FAKE_CILIUM", "")
forced = os.path.exists(f("cilium-forced"))
if a[:3] == ["-n", "kube-system", "delete"] and "pod" in a:
    put(f("cilium-forced"), a[a.index("pod") + 1] + "\n", "a")
    sys.exit(0)
if "get pods -l k8s-app=cilium" in A:
    stuck = cilium == "stuck-forever" or (cilium == "stuck" and not forced)  # stuck-forever: the pod is still Terminating after the force-delete
    rows = "cilium-aaaaa 1/1 Running 0 9m\n" + ("cilium-bbbbb 1/1 Terminating 0 9m\n" if stuck else "")
    out(rows)
if "rollout status ds/cilium" in A and (cilium == "slow" or cilium == "stuck-forever" or (cilium == "stuck" and not forced)):
    sys.stderr.write("error: timed out waiting for the condition\n")
    sys.exit(1)
if "rollout" in A:
    sys.exit(0)
if "get cluster " in A + " ":  # the bare name is the CAPI Cluster on a management cluster (lab 20): nothing is there
    sys.stderr.write('Error from server (NotFound): clusters.cluster.x-k8s.io not found\n')
    sys.exit(1)
if "get clusters.postgresql.cnpg.io" in A:
    name = a[a.index("clusters.postgresql.cnpg.io") + 1]
    jp = opt("-o") or ""
    if "isWALArchiver" in jp:  # the archive name the Cluster has been given by Flux
        cm = gen_cm()
        out(name + ("" if os.environ.get("FAKE_APPLY_STALE") or cm is None else cm["data"]["CNPG_ARCHIVE_SUFFIX"]))
    if "ContinuousArchiving" in jp:
        out("False" if os.environ.get("FAKE_NO_ARCHIVING") else "True")
    for key, val in (("status.phase", "Cluster in healthy state"), ("currentPrimary", name + "-1"), ("imageName", "ghcr.io/cloudnative-pg/postgresql:18.6"),
                     ("storage.size", "5Gi")):
        if key in jp:
            out(val)
if "exec" in a and "pg_dump" in a:
    sys.stdout.buffer.write(b"PGDMP" + b"d" * 1000)
    sys.exit(0)
if "exec" in a and "psql" in a and "pg_database" in A and "datdba" in A:
    out("appowner\n")
if "exec" in a and "pg_restore" in a:
    if "--role=appowner" not in A:  # the restore must run as the owner of the database
        sys.stderr.write("pg_restore without --role=<database owner>\n")
        sys.exit(2)
    data = sys.stdin.buffer.read()
    i = a.index("exec") + 1
    pod = a[i + 1] if a[i] == "-i" else a[i]
    put(f("pg_restore.log"), f"{pod} bytes={len(data)}\n", "a")
    if "-d grafana" in A and released("observability"):
        # Grafana was released before the load: it created its schema in the empty database (lab 28B, infra #426)
        sys.stderr.write('pg_restore: error: could not execute query: ERROR:  cannot drop sequence short_url_id_seq because other objects depend on it\n'
                         'pg_restore: error: could not execute query: ERROR:  relation "short_url_id_seq" already exists\n'
                         'pg_restore: error: could not execute query: ERROR:  relation "short_url_pkey" already exists\n'
                         'pg_restore: warning: errors ignored on restore: 3\n')
        sys.exit(1)
    if os.environ.get("FAKE_PG_RESTORE") == "inherited":
        sys.stderr.write('pg_restore: error: could not execute query: ERROR:  cannot drop inherited constraint "x_pkey" of relation "x"\npg_restore: warning: errors ignored on restore: 1\n')
        sys.exit(1)
    if os.environ.get("FAKE_PG_RESTORE") == "real":
        sys.stderr.write('pg_restore: error: could not execute query: ERROR:  role "zitadel" does not exist\npg_restore: error: could not execute query: ERROR:  cannot drop inherited constraint "x_pkey" of relation "x"\n')
        sys.exit(1)
    sys.exit(0)
if "exec" in a and "psql" in a:
    rows, prev = [], ""
    for i in range(1, 30):
        ts = f"2026-10-20T10:{i:02d}:00.000000"
        sha = hashlib.sha256(f"{prev}|{i}|{ts}".encode()).hexdigest()
        rows.append((i, ts, "f" * 64 if (os.environ.get("FAKE_BROKEN_CHAIN") and i == 20) else sha))
        prev = sha
    out("".join(f"{i}\t{t}\t{s}\n" for i, t, s in rows))
if "get backups.postgresql.cnpg.io" in A:
    out("failed" if os.environ.get("FAKE_BACKUP_FAIL") else "completed")
def jobs():
    return get_json(f("jobs.json")) if os.path.exists(f("jobs.json")) else {}


if "create job --from=cronjob/" in A:
    if os.environ.get("FAKE_JOB_CREATE_FAIL") == a[-1]:
        sys.stderr.write("Error from server (Forbidden): jobs.batch is forbidden\n")
        sys.exit(1)
    j = jobs()
    j[a[-1]] = {"owned": True}  # a Job made from a CronJob is owned by it, and its history limit prunes the finished ones
    put_json(f("jobs.json"), j)
    sys.exit(0)
if a[:4] == ["-n", "foundation-databases", "patch", "job"]:
    if os.environ.get("FAKE_JOB_PATCH_FAIL"):
        sys.stderr.write("Error from server (Forbidden): jobs.batch is forbidden\n")
        sys.exit(1)
    j = jobs()
    if "ownerReferences" in A and a[4] in j:
        j[a[4]]["owned"] = False
    put_json(f("jobs.json"), j)
    sys.exit(0)
if "delete job" in A:
    j = jobs()
    for n in a[a.index("job") + 1:]:
        j.pop(n, None)
    put_json(f("jobs.json"), j)
    sys.exit(0)
if os.environ.get("FAKE_KUBECTL_WARN") and a[:4] == ["-n", "foundation-databases", "get", "job"]:
    sys.stderr.write("Warning: the client is older than the server (a warning only: the command succeeds)\n")
if a[:5] == ["-n", "foundation-databases", "get", "job", "dr-replicate"] or a[:5] == ["-n", "foundation-databases", "get", "job", "dr-check"]:
    j = jobs()
    # FAKE_CRON_PRUNE=1: the next scheduled run of the CronJob has finished and pruned every Job it still owns (lab 28B, infra #427);
    # FAKE_JOB_GONE=<job>: somebody deleted that Job
    if a[4] not in j or os.environ.get("FAKE_JOB_GONE") == a[4] or (os.environ.get("FAKE_CRON_PRUNE") and j[a[4]]["owned"]):
        j.pop(a[4], None)
        put_json(f("jobs.json"), j)
        sys.stderr.write('Error from server (NotFound): jobs.batch "' + a[4] + '" not found\n')
        sys.exit(1)
if "get job dr-replicate" in A:
    out("1")
if "delete backups.postgresql.cnpg.io" in A or "delete clusters.postgresql.cnpg.io" in A:
    sys.exit(0)
if "logs job/dr-check" in A:
    if os.environ.get("FAKE_VERIFY_SKIP"):
        out("SKIP zitadel-db/primary/latest: the live database has no canary row yet (writer not run)\n")
    out("PASS zitadel-db/primary/latest: canary identical to the live chain\n")
if "get job dr-check" in A:
    key = "failed" if "failed" in A else "succeeded"
    out("1" if (key == "failed") == bool(os.environ.get("FAKE_VERIFY_FAIL")) else "")
sys.stderr.write("fake kubectl: unhandled " + A + "\n")
sys.exit(1)
