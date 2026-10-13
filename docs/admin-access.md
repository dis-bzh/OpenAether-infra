# Day 1 — admin initialisation after `task cluster-up` (management)

🇫🇷 [Version française](admin-access.fr.md)

The manual post-deployment steps for a cluster carrying the **application
platform**, in order: any cluster built with `deploy_flux = true`. A cluster built
with `deploy_flux = false` (the default) runs none of it, and nothing below
applies. On a `deploy_flux = true` cluster `task cluster-up` still ends red, by
design (the verifier asserts that Flux is absent), and Flux sits at 29 of 35
Kustomizations until § 3 has run: that is expected, and § 3 is the remedy.
Convention: `KC=infrastructure/opentofu/cluster/kubeconfig`.

OpenBao keeps **no root token and no unseal key in a log or a readable Secret**:
it unseals itself with a static key, and what operators hold are *recovery* shares
(production: encrypted to their PGP keys, from `openbao_recovery_pgp_keys`).
Design and runbooks: `OpenAether-apps/apps/base/foundation/vault/README.md`. This
page needs apps 0.2.0 or later; a cluster still on apps 0.1.0 keeps the older
bootstrap and the older instructions of infra 0.2.0.

For the commands below, the helper that exchanges a ServiceAccount token for an
OpenBao token *inside the pod* (no OpenBao token ever crosses your terminal):

```bash
bao_admin() {
  kubectl --kubeconfig $KC -n foundation-vault create token openaether-admin --duration=15m \
  | kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c \
      'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=openaether-admin jwt="$(cat)")" exec bao "$@"' sh "$@"
}
```

## 1. Escrow (IMMEDIATE)

Four things off the cluster, in your password manager or vault, then wiped from local output.
**Losing the seal key loses every secret in OpenBao**: it is the master key of its data.

| What | How | Why |
|---|---|---|
| Seal key | `kubectl -n foundation-vault get secret openbao-seal-key -o jsonpath='{.data.key}' \| base64 -d \| gpg --encrypt -r <you> -o openbao-seal-key.gpg` | OpenBao DR: a raft snapshot is encrypted by it |
| Recovery shares | `kubectl -n foundation-vault get secret openbao-recovery-shares -o yaml > openbao-recovery-shares.yaml` (PGP-encrypted: safe to store anywhere) | break-glass root token and DR; the Secret dies with the cluster |
| restic password | `bao_admin kv get -mount=secret -field=password backup/restic` | without it the backups are undecryptable the day OpenBao is lost |
| `TF_VAR_encryption_passphrase` | already in your vault | tfstate + gpg artifacts + etcd snapshots |

A cluster without `openbao_recovery_pgp_keys` is a **development** bootstrap: one plaintext share in
`openbao-recovery-dev`, labelled as such. Do not put anything that matters on it.

## 2. Sign the PKI intermediate (unblocks HTTPS)

The first `openbao-vault-bootstrap` run prints the CSR (public data):
`kubectl --kubeconfig $KC -n foundation-vault logs job/openbao-vault-bootstrap | sed -n '/BEGIN CERTIFICATE REQUEST/,/END CERTIFICATE REQUEST/p'`.
Sign it **offline** with the root CA, then:

```bash
kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c 'cat > /tmp/int.crt' < intermediate-signed.pem
bao_admin write pki/intermediate/set-signed certificate=@/tmp/int.crt
```

`openaether-tls` then goes Ready on its own and the 443 listener is programmed.
Runbook: `OpenAether-apps/apps/base/foundation/vault/pki-root-offline-runbook.md`.

## 3. Seed the backup destinations

**`source .env.sh && scripts/ops/seed-openbao.sh <provider>` does all of this.** It needs the
S3 keys of the primary store and, when the replica is on another cloud, of that cloud
(`<CLOUD>_BACKUP_AWS_*`: the replica is opened with the keys of whoever holds it), and
reads `OA_SLACK_WEBHOOK_URL` / `OA_DEADMANSSWITCH_URL` (placeholders are seeded, with a
warning, when unset). The buckets must **pre-exist** (restic does not create them), on
different providers in production: the application backups bucket
`s3-<project>-<provider>-backups-<env>` and its `-backup` twin; the script announces the first.

It is **create-only**: every secret is written with `cas=0`, so a re-run cannot overwrite
one (a rotated value does not fail, it breaks whatever holds the old one). Its identity is
the ServiceAccount `openbao-seeder`: Kubernetes issues a 10-minute token, OpenBao exchanges it
inside the pod for a token whose policy `secret-seeder` can **create** the five paths below
and read their metadata, nothing else. Neither the token nor a value is on a command line;
the script prints paths, never values. The restic password, the database passwords and
Longhorn's passphrase are **not** seeded here: `openbao-vault-bootstrap` generates them
inside OpenBao and prints none.

This is not optional polish: without `backup/s3-primary` alone, six Kustomizations stay
not-Ready and the DAG never converges (measured on Scaleway: 29 of 35 until seeded, all 35
within about two minutes after). A deploy is not finished until this has run.

```text
secret/backup/s3-primary                      endpoint bucket access_key secret_key
secret/backup/s3-replica                      endpoint bucket access_key secret_key   (the replica cloud's keys)
secret/observability/loki-s3                  endpoint bucket accessKey secretKey     (its own destination: Loki never writes to the backup bucket)
secret/observability/alertmanager-slack       webhook-url   (Alertmanager will not start without it; on a throwaway cluster any value works)
secret/observability/alertmanager-deadmansswitch   url      (the only signal that survives this cluster dying; Slack-only? drop the Watchdog route from vm-customresources/vmalert.yaml, deliberately)
```

Clusters seeded before this change keep what they have (create-only): if `backup/s3-replica`
holds the primary's keys for a replica on another cloud (#296), correct it by hand with
`bao_admin kv put -mount=secret backup/s3-replica …`.

`s3-primary` feeds three mechanisms at once: restic, CNPG PITR and Longhorn volume backups.
Until seeded, the ExternalSecrets stay NotReady, the CronJobs idle and Loki does not install:
deliberate. Test with `kubectl create job --from=cronjob/openbao-snapshot test -n foundation-vault`.

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

⚠️ If your public IP changes, the bastion stops letting you in, and a plain `task infra-apply` stops
at its tunnel check: the tunnels cannot be rebuilt until the apply lands. Put the new address in
`admin_ip` and run it with the check off and the health read skipped:
`OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true task infra-apply PROVIDER=… APPROVE=auto`. Measured on
Scaleway, 2026-10-04: the bastion's security group and the load balancer's ACL were updated, the apply took
under four minutes, SSH to the bastion worked again and `cluster-verify` passed 13/13. `admin_ip` refuses an
empty list, a bare address and a `/0` since it validates — it is the allowlist in front of both bastion sshd and 6443.

**The bastion stays, hardened in place (decision, #82, 2026-10-03).** An OIDC issuer
for the apiserver, an SSH CA or a WireGuard control plane would each need an always-on
host outside every cluster. OpenAether has one operator today, and no restore tested
end to end on a real cloud yet (#57), so that host would be one more thing to keep
alive for nothing. The four `bastion.tf` and `admin_ip` stay in the provider contract.
Revisit with two or more operators, or a stateful service whose restore has been run.

⚠️ **The kubeconfig cannot be revoked.** `talosctl kubeconfig` issues a client
certificate for `O=system:masters`, which bypasses RBAC, and Kubernetes has no
revocation for client certificates: a leaked kubeconfig is valid until it
expires, and the only remedy is rotating the cluster CA. Treat the file as the
secret it is — it is also in the tfstate and in both artifact stores. For
read-only work, carry less: `task talosconfig-new PROVIDER=… ` issues an
`os:reader` talosconfig that expires in hours and cannot mint an admin one
(proven by `task local-rbac`). Also run through the tunnels on a real OVH cluster
(2026-10-03): `TALOSCONFIG=<that file> task cluster-verify PROVIDER=…` passes 13/13
with it, while `talosctl get machineconfig` is refused. Mint one and reuse it until it
expires rather than one per run: minting is a write against the Talos API, and a read
should not need one.

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

- [ ] OpenBao seal key + recovery shares escrowed
- [ ] restic password escrowed
- [ ] Intermediate signed (HTTPS working)
- [ ] Backup buckets created + destinations seeded
- [ ] First snapshot tested against both destinations
- [ ] Root CA imported, tunnel tested
- [ ] (CAPI) child secrets placed, kubeconfig extracted
