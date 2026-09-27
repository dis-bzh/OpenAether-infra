# Day 1 — admin initialisation after `task cluster-up` (management)

🇫🇷 [Version française](admin-access.fr.md)

The manual post-deployment steps for a cluster carrying the **application
platform**, in order. **0.1.0 deploys none of it** — on an infrastructure-only
cluster `task cluster-verify` is the whole day-1 path and nothing below applies.
Validated on Scaleway, 2026-07-25.
Convention: `KC=infrastructure/opentofu/cluster/kubeconfig`.

## 1. Escrow (IMMEDIATE)

Three secrets into Bitwarden EU, then wiped from local output:

| What | Where | Why |
|---|---|---|
| Shamir shares (5/3) + root token | `kubectl logs -n foundation-vault job/openbao-init` (also Secret `openbao-recovery`) | OpenBao unseal/DR — the truth must live offline |
| restic password | `kubectl logs -n foundation-vault job/openbao-vault-bootstrap` (printed ONCE) | without it the backups are undecryptable the day OpenBao is lost |
| `TF_VAR_encryption_passphrase` | already in your vault | tfstate + gpg artifacts + etcd snapshots |

## 2. Sign the PKI intermediate (unblocks HTTPS)

The bootstrap Job prints the CSR. Sign it **offline** with the root CA, then:

```bash
# https, and skip-verify: the listener holds the cluster's own self-signed pair.
# This said `http://` until 2026-08-14 and answered "Client sent an HTTP request
# to an HTTPS server" — the command as written could never have worked.
kubectl --kubeconfig $KC exec -i openbao-0 -n foundation-vault -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN=<root_token> \
  bao write pki/intermediate/set-signed certificate=@- < intermediate-signed.pem
```

`openaether-tls` then goes Ready on its own and the 443 listener is programmed.
Runbook: `OpenAether-apps/apps/base/foundation/vault/pki-root-offline-runbook.md`.

## 3. Seed the backup destinations

**`scripts/ops/seed-openbao.sh <provider>` does all of this**, write-if-absent so
a re-run cannot rotate `backup/restic` and orphan every existing backup. Use it;
the commands below are what it runs and why.

This is not optional polish: without `backup/s3-primary` alone, six Kustomizations
stay not-Ready and the DAG never converges — measured on Scaleway 2026-08-14,
where all 35 went Ready within two minutes of seeding. A deploy is not finished
until this has run.

Buckets must **pre-exist** (restic does not create them), on different providers
in production.

```bash
bao kv put secret/backup/s3-primary endpoint=… bucket=… access_key=… secret_key=…
bao kv put secret/backup/s3-replica endpoint=… bucket=… access_key=… secret_key=…
bao kv put secret/observability/loki-s3 endpoint=… bucket=… accessKey=… secretKey=…
# Slack incoming webhook — Alertmanager will not start without it, on purpose
bao kv put secret/observability/alertmanager-slack webhook-url=https://hooks.slack.com/services/…
# On a throwaway cluster ANY value works: Alertmanager starts, delivery just fails.
# Dead-man's switch — the ONLY signal that survives this cluster dying.
# Alertmanager will not start without it either. Slack-only? Then drop the
# Watchdog route from vm-customresources/vmalert.yaml, deliberately.
bao kv put secret/observability/alertmanager-deadmansswitch url=https://hc-ping.com/<uuid>
# Also required (missed on a first pass, found live 2026-07-30): the CNPG app
# DB passwords and Longhorn's volume-encryption passphrase. Without these the
# grafana-db/zitadel-db Cluster still becomes Ready (bootstrap generates ITS
# OWN placeholder if the secret is absent at initdb time) but the app can't
# actually connect — auth fails silently until this is seeded AND the
# Postgres role is aligned (ALTER ROLE ... WITH PASSWORD, once, if initdb
# already ran with a different placeholder).
bao kv put secret/grafana/db password=$(openssl rand -base64 24 | tr -d '=+/')
bao kv put secret/zitadel/db username=zitadel password=$(openssl rand -base64 24 | tr -d '=+/')
bao kv put secret/backup/restic password=$(openssl rand -base64 36 | tr -d '=+/')
bao kv put secret/longhorn/encryption passphrase=$(openssl rand -base64 48 | tr -d '=+/')
```

`s3-primary` feeds three mechanisms at once: restic, CNPG PITR and Longhorn
volume backups. **Loki gets its own destination** so it never has write access to
the backup bucket.

Until seeded, the ExternalSecrets stay NotReady, the CronJobs idle and Loki does
not install — deliberate. Test with
`kubectl create job --from=cronjob/openbao-snapshot test -n foundation-vault`.

## 4. Preflight the quotas — before deploying

```bash
source .env.sh
task preflight-quotas PROVIDER=outscale -- --add-vms 7 --add-cores 14 --add-ram-gb 44
```

Exits non-zero if the topology overflows. It matters: Outscale caps at 40 GB RAM
while an HA management needs 44, and the overrun is tolerated at creation before
every later VM is silently refused. OVH caps at 10 instances — management (7)
plus one child (2). See `docs/status.md`; the flags for each shipped example
are in [`capacity.md`](capacity.md).

## 5. Schedule the etcd snapshot

An RTO shortcut, not the reference backup: Flux rebuilds cluster content, this
covers what lives only in etcd.

```bash
40 3 * * * <repo>/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/<key> >> <log> 2>&1
```

Use the wrapper, not the task directly — the reasons are in its header. It runs
on the machine holding both the repo and the credentials.

## 6. Admin access to the UIs

The gateway sits on a **private VPC IP** with the bastion SG restricted to
`admin_ip` — nothing public. Routes: `vault|grafana|zitadel|longhorn.openaether.local`.

```bash
# HTTPS (after step 2)
ssh -i <bastion key> -L 8443:<gateway IP>:443 bastion@<bastion IP> -N
# /etc/hosts: 127.0.0.1 grafana.openaether.local zitadel… vault… longhorn…
```

Import the root CA into the browser. Without TLS, for troubleshooting:
`./scripts/ops/local-admin-portforward.sh`.

**Do not use the OpenBao root token day to day** — it never expires and appears
in no audit trail under a human's name. Two named policies exist:

```bash
bao token create -policy=openaether-admin  -ttl=8h -display-name=<name>
bao token create -policy=openaether-reader -ttl=8h -display-name=<name>
```

`openaether-admin` covers daily operations but explicitly denies seal, rekey and
key rotation — those stay with the offline root token, deliberate and rare.

⚠️ If your public IP changes: update `admin_ip` then `task infra-apply`, or the bastion
becomes unreachable. `admin_ip` refuses an empty list, a bare address and a `/0`
since it validates — it is the allowlist in front of both bastion sshd and 6443.

⚠️ **The kubeconfig cannot be revoked.** `talosctl kubeconfig` issues a client
certificate for `O=system:masters`, which bypasses RBAC, and Kubernetes has no
revocation for client certificates: a leaked kubeconfig is valid until it
expires, and the only remedy is rotating the cluster CA. Treat the file as the
secret it is — it is also in the tfstate and in both artifact stores. For
read-only work, carry less: `task talosconfig-new PROVIDER=… ` issues an
`os:reader` talosconfig that expires in hours and cannot mint an admin one
(proven by `task local-rbac`).

## 7. Grafana SSO through Zitadel (OIDC)

Once per cluster, in Zitadel: a **Web** application, **Code** + PKCE, redirect
`https://grafana.openaether.local/login/generic_oauth`, a `grafana-admin` project
role, and "User Info inside ID Token" enabled. Then:

```bash
bao kv put secret/grafana/oidc client-id=… client-secret=…
```

⚠️ The roles scope `urn:zitadel:iam:org:projects:roles` is **mandatory** —
without it Zitadel emits no role claim at all and everyone falls back to
`Viewer`. Measured, and already set in `apps/base/observability/grafana.yaml`.

Grafana starts even unseeded (the OIDC env vars are `optional`): only the Zitadel
button is inert. The local login form stays enabled as the safety net — disable
it only once SSO is proven.

## 8. Browser tests

Everything else is checkable from the CLI. These three are not, because they
rely on redirects and cookies. **Blocking prerequisite: step 2** — until the
intermediate is signed, the HTTPS listener stays `Programmed=False`. Check with:

```bash
kubectl get gateway -n services-gateway openaether-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
```

1. **Grafana SSO** — the only genuinely open point. The button must appear,
   login must succeed, and an account holding `grafana-admin` must come out as
   **Admin**. If everyone stays `Viewer`, Zitadel is emitting the
   project-ID-prefixed claim: decode the token
   (`curl -H "Authorization: Bearer <token>" …/oidc/v1/userinfo | jq 'keys'`) and
   put that ID into `role_attribute_path`. The claim *structure* is confirmed.
2. **OpenBao UI** behind the gateway — validates `credentialName`, i.e. that the
   gateway speaks **verified** TLS to OpenBao. A 503 with `client sent an HTTP
   request to an HTTPS server` means the DestinationRule is not applied.
3. **Public ingress without the tunnel** — `curl -kv --resolve
   grafana.openaether.local:443:<app LB IP> https://grafana.openaether.local/login`,
   which confirms the LB → nodePorts 30080/30443 path end to end.

## 9. CAPI children (if the layer is picked)

Before enabling a file in `apps/clusters/`, place the secrets **outside git**:

```bash
kubectl create secret generic scaleway-capi-credentials -n capi-clusters \
  --from-literal=SCW_ACCESS_KEY=… --from-literal=SCW_SECRET_KEY=…
kubectl create secret generic <child>-substitutes -n flux-system \
  --from-literal=SCW_PROJECT_ID=…
# child kubeconfig, generated by CAPI:
kubectl get secret <child>-kubeconfig -n capi-clusters \
  -o jsonpath='{.data.value}' | base64 -d > <child>.kubeconfig
```

⚠️ **Never change the Cilium values of a live child.** The Helm upgrade rolls the
CNI on a 2-node cluster with no headroom; on 2026-07-26 both edges came out
degraded. Recreating the child (`task edge-down`, then re-enable its file) is
faster and safer. The correct values are already in `apps/clusters/*.yaml` and
`task apps-validate` checks that alignment.

A healthy child on the `workload` profile shows **19/19 Kustomizations**. That
count moves with every brick added to the DAG — check it with
`python3 scripts/pick.py vault eso certs gateway`, do not read a change as a
regression.

## Checklist

- [ ] Shamir shares + root token escrowed
- [ ] restic password escrowed
- [ ] Intermediate signed (HTTPS working)
- [ ] Backup buckets created + destinations seeded
- [ ] First snapshot tested against both destinations
- [ ] Root CA imported, tunnel tested
- [ ] (CAPI) child secrets placed, kubeconfig extracted
