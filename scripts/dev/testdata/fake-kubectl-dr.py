#!/usr/bin/env python3
"""A stateful kubectl double for test-dr-restore-plan.sh: the cluster the chain restores into, as far as the chain looks at it.

FAKE_DR    state directory (calls.log: one line of argv per call, no stdin; state/ holds what the chain created)
FAKE_*     failure injections: FAKE_FAIL_SECRET=1 (the seal key Secret is refused), FAKE_BROKEN_CHAIN=1 (the restored canary chain is
           broken), FAKE_VERIFY_FAIL=1 (the restore test of the rebuilt cluster fails), FAKE_NODES=n (nodes of the cluster)
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
a = sys.argv[1:]
if a[:1] == ["--kubeconfig"]:
    a = a[2:]
open(os.path.join(D, "calls.log"), "a").write(" ".join(a) + "\n")
A = " ".join(a)


def out(x):
    sys.stdout.write(x if isinstance(x, str) else json.dumps(x))
    sys.exit(0)


def f(*p):
    return os.path.join(S, *p)


def opt(flag):
    return a[a.index(flag) + 1] if flag in a else None


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
        open(f("applied.jsonl"), "a").write(json.dumps(d) + "\n")
    sys.exit(0)
if "create secret generic openbao-seal-key" in A:
    if os.environ.get("FAKE_FAIL_SECRET"):
        sys.stderr.write("error: refused\n")
        sys.exit(1)
    path = [x for x in a if x.startswith("--from-file=key=")][0].split("=", 2)[2]
    open(f("sealkey"), "wb").write(open(path, "rb").read())
    sys.exit(0)
if "get secret openbao-seal-key" in A:
    out(base64.b64encode(open(f("sealkey"), "rb").read()).decode() if os.path.exists(f("sealkey")) else "")
if "delete secret openbao-recovery-shares" in A:
    sys.exit(0)
if "create secret generic openbao-recovery-shares" in A:
    json.dump({x.split("=", 2)[1]: "x" for x in a if x.startswith("--from-file=")}, open(f("shares.json"), "w"))
    sys.exit(0)
if "get secret openbao-recovery-shares" in A:
    out({"data": json.load(open(f("shares.json")))})
if "get pod openbao-0" in A:
    out("Running")
if "get job openbao-init" in A:
    out("1")
if a[:3] == ["-n", "flux-system", "get"] and opt("-o") == "json":
    ks = {"foundation-vault": ["namespaces", "platform"], "namespaces": [], "platform": ["namespaces"], "external-secrets-stores": ["foundation-vault"],
          "cnpg": ["external-secrets-stores"], "backup-databases": ["cnpg"], "identity": ["cnpg"], "identity-gateway": ["identity"], "observability": []}
    out({"items": [{"metadata": {"name": k}, "spec": {"dependsOn": [{"name": d} for d in v]}} for k, v in ks.items()]})
if a[:3] == ["-n", "flux-system", "get"] and "--no-headers" in a:
    out("foundation-vault True\nplatform True\n")
if a[:3] == ["-n", "flux-system", "patch"]:
    open(f("patches.log"), "a").write(a[4] + " " + ("suspend" if '"suspend":true' in A else "resume") + "\n")
    sys.exit(0)
if a[:2] == ["-n", "foundation-vault"] and a[2:4] == ["exec", "-i"]:
    data = sys.stdin.buffer.read()
    first, _, rest = data.partition(b"\n")
    open(f("restore.log"), "w").write(f"token_bytes={len(first)} snapshot_bytes={len(rest)} sha={hashlib.sha256(rest).hexdigest()[:12]}\n")
    sys.exit(0)
if "exec openbao-0 -- bao status" in A:
    out('{"initialized": true, "sealed": false}')
if a[:3] == ["-n", "foundation-vault", "delete"] and "pod" in a:
    sys.exit(0)
if a[:2] == ["get", "externalsecret"]:
    out("ns es True\n" * 3)
if "get cluster " in A + " ":  # the bare name is the CAPI Cluster on a management cluster (lab 20): nothing is there
    sys.stderr.write('Error from server (NotFound): clusters.cluster.x-k8s.io not found\n')
    sys.exit(1)
if "get clusters.postgresql.cnpg.io" in A:
    name = a[a.index("clusters.postgresql.cnpg.io") + 1]
    jp = opt("-o") or ""
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
    open(f("pg_restore.log"), "a").write(f"{pod} bytes={len(data)}\n")
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
if "delete job" in A or "delete clusters.postgresql.cnpg.io" in A:
    sys.exit(0)
if "create job --from=cronjob/cnpg-recovery-restore-test" in A:
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
