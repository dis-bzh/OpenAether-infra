# Day 1 — admin initialisation after `task cluster-up` (management)

🇫🇷 [Version française](admin-access.fr.md)

The manual post-deployment steps for a cluster carrying the **application
platform**, in order: any cluster built with `deploy_flux = true`. A cluster built
with `deploy_flux = false` (the default) runs none of it, and nothing below
applies. On a `deploy_flux = true` cluster `task cluster-up` ends green (the verifier then
requires Flux and the application load balancer), but Flux sits below its full
Kustomization count until § 3 has run: that is expected, and § 3 is the remedy.
Convention: `KC=infrastructure/opentofu/cluster/kubeconfig`.

OpenBao keeps **no root token and no unseal key in a log or a readable Secret**:
it unseals itself with a static key, and what operators hold are *recovery* shares
(production: encrypted to their PGP keys, from `openbao_recovery_pgp_keys`).
Design and runbooks: `OpenAether-apps/apps/base/foundation/vault/README.md`. This
page needs apps 0.1.1 or later; a cluster still on apps 0.1.0 keeps the older
bootstrap and the older instructions of infra 0.2.0.

For the commands below, the helper that exchanges a ServiceAccount token for an
OpenBao token *inside the pod* (no OpenBao token ever crosses your terminal):

```bash
bao_admin() {
  kubectl --kubeconfig $KC -n foundation-vault create token openaether-admin --duration=15m \
  | kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c \
      'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=openaether-admin jwt=-)" exec bao "$@"' sh "$@"
}
```

## 1. Escrow (IMMEDIATE)

Four things off the cluster, in your password manager or vault, then wiped from local output.
**Losing the seal key loses every secret in OpenBao**: it is the master key of its data.

| What | Where it comes from | Why |
|---|---|---|
| Seal key | `openbao-seal-key.gpg`, encrypted to at least two custodians (`task escrow`, below) | OpenBao DR: a raft snapshot is encrypted by it |
| Recovery shares | `openbao-share-N.b64`, copied by `task escrow` (PGP-encrypted: safe to store anywhere) | break-glass root token and DR; the Secret dies with the cluster |
| restic password | `restic-password.gpg`, read through `bao_admin`'s path and encrypted to the same custodians | without it the backups are undecryptable the day OpenBao is lost |
| `TF_VAR_encryption_passphrase` | already in your vault (two places, `key-management.md`) | tfstate (+ gpg artifacts + etcd snapshots unless `TF_VAR_artifact_passphrase` is set) |

`task escrow` (`scripts/ops/escrow-openbao.sh`) does the first three and **proves** them. It needs a kubeconfig and the tunnels, and `gpg`:

```bash
task escrow -- export --out ~/oa-escrow-$(date +%F) -r <custodian-a> -r <custodian-b>   # or --recipients-from-tfvars envs/management-<p>.tfvars
task escrow -- verify --from ~/oa-escrow-<date>      # each custodian, on their own machine, with their own key
task escrow -- attest --from ~/oa-escrow-<date>      # only after the proof: writes openbao-escrow-ack and the annotation
```

`export` refuses fewer than two distinct keys (one person's laptop is one point of loss and one leak), a directory inside a git work tree, a
non-empty directory and a development bootstrap, and writes a receipt of hashes (no secret) beside the files. With several recipients **any one**
of them opens the key: it survives losing a person, not one leak. For "no single custodian can open it", split the key by hand (apps `vault/README.md`,
Day 0, step 1: neither `ssss` nor `gfsplit` was tried on this platform) and prove it with `verify --key-file <the raw 32 bytes reconstructed from the shares>`;
this tool does not split. `verify` reconstructs the key from the escrow alone and compares its sha256 with the receipt **and** with the live Secret, and does the same for
the restic password and the share copies; a rotated key is a MISMATCH, which is the case the apps CronJob cannot see. `attest` runs `verify`, then writes what the apps
CronJob `openbao-escrow-check` and `cluster-security` check 4.7 read (the ConfigMap `openbao-escrow-ack` and the annotation `openaether.io/escrowed-at`). It is the operator's word
backed by a hash: it does not prove that every custodian can open their copy, so have each one run `verify`. Redo all three after every seal-key rotation (the rotation runbook deletes both
records). Work in a RAM-backed directory where you can, copy the result to its places, and keep it out of the cluster and of every repository. Not run on a cluster: `LAB-CHECKLIST.md`.

A cluster without `openbao_recovery_pgp_keys` is a **development** bootstrap: one plaintext share in
`openbao-recovery-dev`, labelled as such, and it can not be turned into a production one (re-initialise it). Do not put anything that
matters on it. `task cluster-up` checks every key for a usable encryption subkey before it bills and prints its fingerprint: compare
it with yours (`scripts/internal/check-openbao-keys.sh <env file>` runs the same check alone).

## 2. Sign the PKI intermediate (unblocks HTTPS)

The first `openbao-vault-bootstrap` run stores the CSR (public data) in KV, because the Job and its log are removed an hour
after it ends and offline signing takes longer. Read it with the admin helper above:
`bao_admin kv get -field=csr secret/pki/intermediate-csr > intermediate.csr`.
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
With `backup_immutability` set in the tfvars, `ensure-buckets.sh` creates that pair too (and versions or locks the buckets: `backup-policy.md`, section 3).

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
secret/observability/loki-s3                  endpoint bucket accessKey secretKey     (its own bucket, `s3-<project>-<provider>-logs-<env>`, created by `ensure-buckets.sh`; its own keys when you give them, see below)
secret/observability/alertmanager-slack       webhook-url   (Alertmanager will not start without it; on a throwaway cluster any value works)
secret/observability/alertmanager-deadmansswitch   url      (the only signal that survives this cluster dying; Slack-only? drop the Watchdog route from vm-customresources/vmalert.yaml, deliberately)
```

**Loki has a bucket of its own (#302).** The seed points `observability/loki-s3` at `s3-<project>-<provider>-logs-<env>`, which
`ensure-buckets.sh` creates beside the artifacts bucket (a pre-existing cluster creates it by hand). Loki gets the primary store's
keys unless you export **both** `OA_LOKI_S3_ACCESS_KEY_ID` and `OA_LOKI_S3_SECRET_ACCESS_KEY`: a pair that reaches that bucket and
nothing else, which you create with your provider's own tools (the providers' S3 keys are account-wide by default). With the
shared keys the separate bucket protects the backups from a mistake in Loki, **not** from a compromised Loki, and the script says
so. Clusters seeded before this change keep a Loki entry that points at the backups bucket (create-only).

**The backups can have pairs of their own too.** Export **both** of `OA_BACKUP_S3_ACCESS_KEY_ID` / `OA_BACKUP_S3_SECRET_ACCESS_KEY` (for `backup/s3-primary`) and, for the
`-backup` twin on the replica store, `OA_BACKUP_REPLICA_S3_ACCESS_KEY_ID` / `OA_BACKUP_REPLICA_S3_SECRET_ACCESS_KEY`, each limited to its bucket (the shape: `backup-policy.md`,
section 4). Unset, the cluster holds the operator's keys, which open the state, artifact and logs buckets too, and the script says so. `scripts/ops/s3-isolation-check.sh <tfvars>`,
with the same variables exported, shows who opens what. To change an entry that exists, `task rotate-secret -- <path> --apply` writes a new version and nudges the ExternalSecrets (`incident-response.md`, section 7).

Clusters seeded before this change keep what they have (create-only): if `backup/s3-replica`
holds the primary's keys for a replica on another cloud (#296), correct it with
`task rotate-secret -- backup/s3-replica --apply` (or by hand: `bao_admin kv put -mount=secret backup/s3-replica …`).

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

The administration path reaches the gateway on a **private VPC IP**, through the bastion (its security group is restricted to
`admin_ip`). Routes: `vault|grafana|zitadel.openaether.local`, and `longhorn.openaether.local` only where the Longhorn route was added by hand (it has no login and is
not in the default kustomization).

⚠️ **That private path is not the whole exposure.** With `deploy_app_lb = true` the application load balancer forwards public 80/443 to the same
Gateway's NodePorts, with no source filter: every route then answers anyone who sets its Host header, and the route's own login is its only protection
(the register is `OpenAether-apps/docs/public-exposure.md`; the filtering picture is [`network.md`](network.md), section 6). Off by default.

**Optional source filter, `app_lb_allowed_cidrs`** (a list of IPv4 CIDRs, empty = no filter = what a cluster did before it existed; on Outscale that is an explicit `0.0.0.0/0` rule on 80 and 443, since a security group admits nothing unlisted: until 0.4.0-rc1 the Outscale load balancer was closed to everybody when the list was empty, lab 27 part C). Set it in the tfvars and run the usual `tofu plan`:
the plan must show an **update in place** of the Scaleway frontends / OVH listeners (or new Outscale rules) and no `must be replaced`: a replaced load balancer changes the public IP.
The list must hold every public client you want to keep (an office, a CI runner, an uptime monitor); the cluster's own egress address is added for you, because pods reach
`https://zitadel.openaether.local` through the load balancer. Roll it out in stages: empty, then `["0.0.0.0/0"]` (machinery on, still open: the plan shows the in-place update),
then your CIDRs on ONE provider, check, then the others. Rollback is the empty list. Not run on a cloud: the checks are in the lab checklist; it filters addresses and authenticates nothing.

```bash
# HTTPS (after step 2)
ssh -i <bastion key> -L 8443:<gateway IP>:443 bastion@<bastion IP> -N
# /etc/hosts: 127.0.0.1 grafana.openaether.local zitadel… vault…
```

⚠️ **This forward is refused by the bastion as shipped**: its `PermitOpen` lists 6443 and 50000 (and 8200 on the legacy egress) and not 443, so ssh answers
`administratively prohibited`. The repository offers no switch to open 443; widening `PermitOpen` is a deliberate decision to take and document (`hardening.md`, section 2).
Not run on a cloud since this note was written: check it on the first cluster. What works through the 6443 tunnel: `./scripts/ops/local-admin-portforward.sh`
(kubectl port-forward to OpenBao, Flux and Grafana on 127.0.0.1, no TLS, no Host routing).
If you do open 443, import the root CA into the browser.

**There is no OpenBao root token to use day to day**: it is revoked at bootstrap, and a break-glass one takes a quorum of recovery-share holders
(apps `vault/README.md`). A named human works through a ServiceAccount identity, exchanged inside the pod for a token that lasts hours: `bao_admin` above is
`openaether-admin`; the read-only identity is the same helper with the ServiceAccount and role `openaether-reader`:

```bash
bao_reader() {
  kubectl --kubeconfig $KC -n foundation-vault create token openaether-reader --duration=15m \
  | kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c \
      'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=openaether-reader jwt=-)" exec bao "$@"' sh "$@"
}
```

`openaether-admin` covers daily operations but explicitly denies seal, rekey, key rotation, minting tokens and writing policies, mounts or roles — those stay with the
recovery-share quorum (or git, for the configuration), deliberate and rare. The administration paths and who holds them: [`security-architecture.md`](security-architecture.md).

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
Revisit with two or more operators, or a stateful service whose restore has been run. (Opt-ins for several operators, an SSH CA
the bastion trusts and a closed Internet egress came after; none of them operates a CA or makes the bastion ephemeral.)

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

**Named, short-lived identities (`task kubeconfig-new`).** For day-to-day work, do not carry the shared file: with the tunnels open,
`task kubeconfig-new PROVIDER=… NAME=alice` files a CertificateSigningRequest (signer `kubernetes.io/kube-apiserver-client`,
`expirationSeconds`, default 8 h, accepted 10 min to 24 h) for `CN=alice`, `O=oa:readers`, and writes a 0600 kubeconfig outside the repository
(`~/.kube/oa-alice-reader.kubeconfig`; a path inside the repository is refused). `ACCESS=admin` asks for `O=oa:admins` instead (cluster-admin through the
group). The private key is generated on your machine; the `system:masters` file only files and approves the request, and stays the escrowed break-glass
credential, not the routine one. What each group may do is the apps `platform-rbac` brick (`oa-admins` to `cluster-admin`, `oa-readers` to `view`): a certificate
carrying a group no binding names can do nothing. Revoking one person before the certificate expires means deleting or narrowing the binding of their
group (it takes effect at once, the certificate stays valid but is refused); a group binding cannot single out one holder, so for per-person revocation
bind the user by name instead (`rbac-review` flags it for you to record). `rbac-review` and `cluster-security` 3.7 allow exactly these two bindings and nothing else under those names.
Not run on a cloud yet: the checks are in the lab checklist. It does not add OIDC, MFA or an audit shipping pipeline: the apiserver audit log stays on the control plane.

**Review at staff change.** Whoever joins or leaves, run `task rbac-review` (a read-only `kubectl`, `KUBECONFIG` set):
it lists every binding with its subjects in `rbac-review/rbac-review-<date>.tsv` and flags a named User/Group, an anonymous
binding and a `cluster-admin` outside the allowlist (the one of `cluster-security-tests.sh` 3.7). Where the apps `platform-rbac` brick is reconciled the two bindings above are not flagged; the expected
answer is otherwise "nothing flagged", so a flagged line is a decision to record or a binding to
delete. Revoking the shared certificate still means rotating the CA; the review only finds what else grants access.
Beyond RBAC, `task cluster-exposure PROVIDER=…` probes the public addresses (run it once from an address that is not in
`admin_ip` with `FROM=denied`: 22 and 6443 must then be closed) and `task cluster-netcheck PROVIDER=…` sends traffic the
policies must drop. `task cluster-security` takes `ENVIRONMENT=prod` to fail on an `openbao-recovery-dev` Secret.

### Bastion OS baseline (opt-in, `bastion_baseline`)

Off by default: the cloud-init is byte for byte what 0.1.0 shipped. Turn it on in the tfvars:

```hcl
bastion_baseline = { enabled = true }   # + audit_logging (default true), restrict_ssh_source, time_servers, revoked_keys
```

⚠️ **This changes the bastion's `user_data`, which replaces the VM on OVH and Outscale** (new public IP, new host key, the
Talos tunnels die with it) and on Scaleway and Proxmox the plan decides (cloud-init only runs at first boot, so a running VM keeps its old one until it is
recreated): read it. Apply it on a fresh cluster or in a planned window,
never during a bootstrap or an upgrade, with a second session or the provider console open. Read the plan: the bastion must be
the only thing replaced.

What it adds, each item named by the ANSSI requirement it addresses (BP-028 is the GNU/Linux guide, NT-007 the SSH one, NT-006
the filtering one; nothing here claims compliance): sysctl (R9, R11, R12 without the ARP options, R14), auditd with execve,
`/etc`, mount, module and ptrace rules and no `-e 2` (R73), a persistent journald capped at 200 MB / 90 days, `LogLevel VERBOSE`
and a second sshd drop-in with the directives NT-007 R14/R15/R23 ask for, `authorized_keys.d` owned by root (R50), `/var/tmp`
noexec (R28), `/boot` 700 (R29), umask 0077 (R36), sudo restricted to its group and the bastion user out of it (R38), no tcpdump/netcat (R58, new VMs only),
and in the VM's own nftables: logged drops and ICMP limited to echo-request and fragmentation-needed (NT-006 R3/R6).
`restrict_ssh_source = true` also limits port 22 to `admin_ip` inside the VM (Proxmox has no security group), but then
`admin_ip` is part of the user_data: changing it replaces the bastion, and a running one keeps the old list - leave it off where
that is not acceptable. Port 22 stays on 22 because the cloud security group is the real allowlist and the tunnels
(`talos-tunnels.sh`) and this guide all use it; the key, the user and the `PermitOpen` forwards are untouched.

`time_servers` swaps the image's time service for chrony on those servers. `revoked_keys` is **the offboarding procedure**:
remove the key from `bastion_ssh_keys` AND list it there, so it is refused even on a bastion that is not rebuilt. Changing
either replaces the bastion, as above. Map each key to a person in a file kept next to the tfvars (`ssh-keygen -lf <key>.pub`
prints the fingerprint that the login line `Accepted publickey ... SHA256:<fingerprint>` carries).

The logs die with the VM: `scripts/ops/bastion-logs-pull.sh <ip> bastion <key>` copies the journal (ssh, sudo, nft drops;
incremental) and the audit log off it (with `audit_logging = false` there is no audit log: the journal alone is exported and the script says
the audit part was skipped; an account that cannot read the journal is refused with the reason), encrypted when `OA_LOGS_PASSPHRASE` is set, and with `OA_LOGS_UPLOAD=1` stored in the artifacts bucket of both object stores
(next section). Cloud-side audit trails and a Proxmox host's syslog are separate and not exported by anything here.

Check a deployed bastion with `BASTION_BASELINE=1 scripts/ops/bastion-harden-check.sh <ip> bastion <key> [<control plane ip>]`; add
`BASTION_AUDIT=0` when the bastion has `audit_logging = false` (closed egress forces it): auditd is then not asserted, since it is not
installed, while the persistent journal, the `adm` / `systemd-journal` groups and the login fingerprint line still are (they need no package).
Before
spending anything, `task bastion-baseline-check` runs the rendered files on Ubuntu 22.04 and 24.04 in Docker (a real sshd
login, tunnels through `PermitOpen`, revoked keys, the loaded firewall rules, sysctl names, audit-rule syntax).

### Bastion identity, host key and Internet egress (opt-in)

Four independent opt-ins, all off by default: a cluster that sets none gets the cloud-init byte for byte (hash pinned in
`test-cluster-checks.sh`). Rung reached: mocked (`task test`, the stub harnesses) and local Docker (`task bastion-identity-check`: a
real sshd and a real nftables on Ubuntu 22.04 and 24.04). **None of it has run on a cloud image yet.** Like the baseline, each
one that changes `user_data` replaces the bastion on OVH and Outscale (new host key) and is ignored by a running instance
elsewhere: apply in a planned window, never during a bootstrap or an upgrade. On Proxmox they reach only the bastion VM
(`enable_bastion = true`); the default host-as-bastion path is untouched.

**Named operators (`bastion_admins`).** `bastion_ssh_keys` and the shared `bastion` account stay: they are the automation and
break-glass path (CI, `auto_tunnels`, the `bootstrap-phase2` key). Each entry below is one more unix account in `bastion-admins`
(no sudo, no password, its own `/etc/ssh/authorized_keys.d/<name>`), so the sshd login line names a person:

```hcl
bastion_admins = {
  alice = { ssh_keys = ["sk-ssh-ed25519@openssh.com AAAA… alice-token"] }
  dave  = { ssh_keys = [] }          # certificate-only: needs bastion_ssh_ca_public_key
}
bastion_require_hardware_key = true  # every key in bastion_admins must be sk-*; bastion_ssh_keys is NOT checked
```

Log in as a person with `SSH_USER=alice task tunnels-up PROVIDER=… KEY=…` (`talos-tunnels.sh` reads `SSH_USER`; the state's
`bastion_user` stays the shared account, and the single-apply tunnels keep it). `bastion_require_hardware_key` is a plan-time
check only: it cannot make the shared account hardware-backed (a CI key cannot touch a token), so restrict who holds that key. For
a PIN on every use, generate the key with `ssh-keygen -O verify-required` and put the option `verify-required` in front of the key
line (the key validation accepts an options prefix); no FIDO token was available to test that. `scripts/ops/bastion-fingerprints.sh`
prints `account / fingerprint / type / comment` for every key in the state (`tofu output bastion_access_keys`): `--find SHA256:…`
answers "whose key was that login". SSH-CA principals: a certificate for a named operator must carry **the account name** as its
only principal, so it cannot be used as another person (proven on a real sshd).

**Offboarding.** `user_data` is read once, at first boot, so removing a person from the tfvars changes nothing on a running bastion.
In order of preference:

1. **Short-lived certificates.** Set `bastion_ssh_ca_public_key` (the CA's `.pub`, one line) and give the operators no key
   (`ssh_keys = []`). Sign for a working day: `ssh-keygen -s <ca> -I alice-$(date +%F) -n alice -V +8h -O permit-port-forwarding alice.pub`
   (keep `permit-port-forwarding`: without it the login works and every `-L` tunnel is refused). Offboarding is *not signing any more*;
   the access ends within 8 hours and no bastion has to change. The CA private key is the new crown jewel: keep it offline or in
   OpenBao's SSH secrets engine with the same 8 h maximum TTL. Nothing here operates the CA.
2. **Replace the bastion** (`tofu apply -replace=<address>`, see the patching paragraph) with the person removed from the map and, with
   `bastion_baseline`, their key listed in `revoked_keys`. Measured: a key in `revoked_keys` is refused AND so is every certificate
   issued for that key; revoking one person leaves the others in.
3. A compromised operator key is the second case plus a look at `bastion-logs-pull.sh` output for what it did.

The drill run offline (`task bastion-identity-check`): a key in `revoked_keys` is refused while the other operators still log in, and an
expired 8 h certificate (`-V -2h:-1h`) is refused. On a real bastion it has not been run.

**Bastion host key (`OA_BASTION_PIN_HOSTKEY`).** The host key is born on the VM, so it cannot be known before the first contact.
Private host keys are deliberately **not** injected through cloud-init (they would sit in the state and the user_data). What the
scripts can do is keep the key once seen and refuse any other:

```bash
OA_BASTION_PIN_HOSTKEY=1      task tunnels-up PROVIDER=… KEY=…   # first contact accepted ONCE, its fingerprint printed; later runs strict
OA_BASTION_PIN_HOSTKEY=verify OA_BASTION_HOSTKEY_FP=SHA256:… task tunnels-up …       # a first contact is refused unless this fingerprint matches
```

Read the fingerprint out of band: cloud-init prints the host keys of the new VM (a `-----BEGIN SSH HOST KEY FINGERPRINTS-----`
block) to the instance console, which a provider shows as a console or serial log where it has one (whether each of the four does,
and when in the boot it appears, is a lab check). The key is kept in `.talos-bastion-known-hosts` (gitignored), one entry per
bastion address, written only after a successful login, so after cloud-init is done. A replaced bastion that **reuses its public
address** (the usual case: the IP is its own resource) presents a new key and is **refused**; once the new fingerprint is checked,
`OA_BASTION_FORGET=1 OA_BASTION_HOSTKEY_FP=SHA256:… task tunnels-up …` re-pins it. Without the variable nothing changes: the file is
emptied at every run and the first key accepted, as before. `bastion-harden-check.sh` and `bastion-logs-pull.sh` no longer take a key
blindly either (the check used `StrictHostKeyChecking=no`): they use the pinned file when it holds the bastion and otherwise print the
fingerprint, and `OA_BASTION_HOSTKEY_FP` makes the check fail on a mismatch. A host *certificate* from the SSH CA would remove the
first-contact step; it is not done.

**Closing the Internet egress (`bastion_internet_egress`).** The bastion's nftables and security group allow 80/443 to any address
(`unattended-upgrades` needed them). Opt in:

```hcl
bastion_internet_egress = {
  mode        = "closed"
  dns_servers = ["<provider resolver IP>"]   # optional: DNS only to these; empty = DNS stays open to any address
  ntp_servers = ["<NTP server IP>"]          # optional, addresses only: a chrony source by NAME resolves to addresses this cannot list
}
```

Closed means: no 80/443 in the VM's firewall or the security group (Scaleway, OVH, Outscale), the cluster rule narrows to TCP
6443 and 50000 on the real cluster subnet (Scaleway: the subnet the private network actually uses, not the whole 172.16.0.0/12;
OVH: the subnet resource's CIDR, not a literal; Outscale: the Net), ICMP only inside that subnet, **8200 is gone** from the firewall
and from `PermitOpen` (nothing in this repository or in OpenAether-apps forwards 8200 through the bastion; OpenBao is reached with
`bao_admin` and port-forwards), the instance metadata addresses stay reachable on port 80 (cloud-init and the provider agents need
them), and `curl`, `wget` (the image ships it), `netcat` and `tcpdump` are purged (a dpkg operation, no mirror needed) while `unattended-upgrades` is neither installed
nor enabled. **First boot cannot install packages:** the security group is closed from the bastion's creation, so no mirror is reachable.
That is why `closed` together with `bastion_baseline` is refused at plan time unless `audit_logging = false` and `time_servers` is empty
(auditd and chrony would never be installed; a real OVH run showed cloud-init ending in error with no auditd). Needing them closed means
needing an image that already ships them. The Proxmox bastion has no security group: only the in-VM rules apply there.

**This is the trade-off: a closed bastion is not patched in place.** Patch by replacing it, on a schedule or on a security notice:
close the tunnels (`scripts/bootstrap/talos-tunnels.sh close`), then `TF_VAR_skip_health_check=true tofu apply -replace=<address>` (the health
check needs the tunnels you just closed and fails after its 15 minutes, seen on OVH 2026-10-17; the replacement itself took under a minute) with the address of the
`…bastion` instance resource of the provider module (`module.scw[0].scaleway_instance_server.bastion`,
`module.ovh[0].openstack_compute_instance_v2.bastion`, `module.outscale[0].outscale_vm.bastion`,
`module.proxmox[0].proxmox_virtual_environment_vm.bastion[0]`), never during a bootstrap or upgrade (the tunnels die with it). The
public IP is its own resource and survives; the host key does not (see above). On Outscale the `outscale_public_ip_link` does not always come back in the same run (seen in lab 11, infra #360: the new bastion was unreachable until a second apply), so finish every `-replace` of the bastion with a plain `tofu plan`: it must say `No changes`, and if it shows the link to create, `tofu apply` once more before `tunnels-up`. The OVH floating-IP association and the Scaleway equivalent have not been checked for the same gap. A bake-and-replace image pipeline or an ephemeral jump
host is not built. To open the egress again for a window, set the mode back to `legacy` and replace the bastion. `BASTION_EGRESS=closed
scripts/ops/bastion-harden-check.sh …` asserts the result (80, 443, another public address and 8200 refused, tools absent, update timers
off); without it the check expects the legacy state, where 80/443 are open by design (it used to expect port 80 blocked, which the
shipped rules never did).

**Logs off the VM and who is behind a login.** `scripts/ops/bastion-logs-pull.sh <ip> <user> <key>` pulls the journal (ssh, sudo, nft
drops) and the audit log, encrypted with `OA_LOGS_PASSPHRASE`. With `OA_LOGS_UPLOAD=1` it also stores them in the artifacts bucket of
both object stores under `backups/bastion-logs/`, with the journal cursor as a watermark kept there too (a pull from another machine
resumes where the last stopped; a store that was down is retried, not skipped). Run it from cron or CI, daily; between pulls the logs
live on the VM and are not tamper-proof. Read one back: `gpg -d journal-<ts>.export.gpg | systemd-journal-remote -o r.journal -` then
`journalctl --file r.journal` (checked on a hand-built export; the first real one is a lab step). Keep
`scripts/ops/bastion-fingerprints.sh` output with the logs: the login line carries the key fingerprint, the table says whose it is.
Cloud-side audit trails (Scaleway Audit Trail, OVH Activity logs, Outscale's API logs) and a Proxmox host's syslog are not exported by
anything here: until someone owns that, export them by hand for the retention period you need and store them encrypted next to the
bastion logs; who may change IAM and security groups is part of the same question.

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

- [ ] OpenBao seal key + recovery shares escrowed to two custodians, proved and attested (`task escrow`)
- [ ] restic password escrowed (the same command)
- [ ] Intermediate signed (HTTPS working)
- [ ] Backup buckets created + destinations seeded
- [ ] First snapshot tested against both destinations
- [ ] Root CA imported, tunnel tested
- [ ] (CAPI) child secrets placed, kubeconfig extracted
