# Incident response — recognise, preserve, contain, rotate, restore, record

🇫🇷 [Version française](incident-response.fr.md)

> Written to answer ANSSI hygiene measure 40 and the compromise-recovery rules of PG-078 (audit ids LOG-17,
> F-BKP-10, DP-07, ADM/F11). It is a **procedure written from the code and the tools' documentation; no step was
> exercised against an incident or a drill**, and none of the timings is measured. It claims no compliance with any ANSSI document.
> Reporting a vulnerability *in this project* is a different thing: `SECURITY.md`.

The platform has **one operator today** (`admin-access.md`). So there is no second person to call, no 24/7 cover and no
separation of duties in what follows: the order of the steps is what protects you, and the register (section 10) is what makes a
single-person response reviewable later. If you are not alone, split the roles in section 2 and keep the order.

## 1. Detection sources

None of these pages anyone by itself unless an alert route is set (Alertmanager to Slack, `seed-openbao.sh`; the dead-man's switch
is the only signal that survives the cluster dying). Read them on a schedule as well (`release-checklist.md`, "Quarterly security review").

| Source | What it shows | How to read it |
|---|---|---|
| Alerts of the application platform (VMAlert) | Flux objects not Ready or suspended, Kyverno violations, OpenBao sealed or without an active node, escrow not attested, backup jobs failed or missing, node clock and disk, policy-denial bursts | Alertmanager; the list and what is *not* covered: `OpenAether-apps/docs/detection.md` (apps ANSSI work; apps 0.2.0 has the rules but not that page) |
| `task cluster-security PROVIDER=…` | The security posture read back from the cluster (policies, mTLS, encryption at rest, the escrow annotation) | Run it after any suspicion and quarterly; `ENVIRONMENT=prod` fails on a development OpenBao |
| `task rbac-review` | Every RBAC binding with its subjects; flags a named User/Group, anonymous binding, an unexpected `cluster-admin` | Read-only; compare with the previous `rbac-review/rbac-review-<date>.tsv` |
| `task cluster-exposure PROVIDER=…` and `task cluster-netcheck PROVIDER=…` | Which public addresses answer, and which flows the policies drop | From an address that is not in `admin_ip` (`FROM=denied`) |
| Bastion logs | `Accepted publickey … SHA256:<fingerprint>` lines, sudo, nftables drops | `scripts/ops/bastion-logs-pull.sh` (daily, `OA_LOGS_UPLOAD=1`), then `scripts/ops/bastion-fingerprints.sh --find SHA256:…` to name the key's owner. On the VM they die with the VM and are not tamper-proof |
| Cloud audit trails | Who changed IAM, security groups, buckets, instances | Scaleway Audit Trail, OVH Activity logs, Outscale API logs, Proxmox syslog: **not exported by anything here**; export by hand |
| OpenBao audit log | Logins, token use, secret reads | It reaches Loki; no rule reads it. Search Loki by hand; the sealed-state alert is the only automatic one |
| Kubernetes API audit | `kubectl exec`, new bindings, who read a Secret | Talos writes the kube-apiserver audit log on the control-plane node (upstream default `/var/log/audit/kube/kube-apiserver.log`; check it exists on your version); **it is not collected off the node**, so it must be read before the node is replaced |
| GitHub | Dependabot and secret-scanning alerts, the daily `repo-settings` workflow (rulesets drift), the Cléa report | Repository security tab and Actions |
| Provider and upstream notices | Account notices, Talos/Kubernetes/Cilium advisories | `patching.md`, `hardening.md` (the watch routine) |

**Signs that call for this procedure**: a login line whose fingerprint no one recognises; a login outside the hours you work; an `rbac-review`
line you did not create; a Secret read, `exec` or new `ClusterRoleBinding` in the API audit log with no matching change; a Flux object
suspended or a Kyverno policy flipped to Audit that you did not do; objects or keys you did not create at the provider; a bucket object deleted;
a laptop, token or `.env.sh` lost; a published secret (the gitleaks job, or any public place).

## 2. Roles and contacts

| Role | Who | Contact |
|---|---|---|
| Incident lead (decides, owns the register) | the maintainer | `<placeholder: private channel>` |
| Executor (runs the commands) | the maintainer, or a second operator if any | `<placeholder>` |
| Security contact for reports | GitHub private vulnerability reporting | the link in `SECURITY.md` |
| Provider support, per cloud | `<placeholder: support URL and account reference>` | keep in the private copy |
| National CERT, if the project hosts a regulated service | `<placeholder: CERT-FR or the sector's CERT>` | keep in the private copy |

The contacts live in a **private copy** of this table next to the tfvars, never in this repository (it is public).
If personal data may be involved, assess the notification duty at once (a personal-data breach is notifiable to the supervisory authority within 72 hours of awareness under GDPR art. 33); that clock is not this page's to manage.

**Severity** (a proposal; decide it in the first minutes and revise it):

| Level | Meaning | Examples | Target (proposed, not measured) |
|---|---|---|---|
| S1 | Control of the cluster, the state or the backups is, or may be, in hostile hands | leaked `system:masters` kubeconfig, K5 or K7 leaked, bastion compromised, root CA key exposed | start containment within 1 hour; secrets replaced within about a day (PG-078 R26) |
| S2 | A credential with limited reach leaked, or an unexplained access | one S3 pair, a departed operator, a suspicious pod, an unexplained login | within one working day |
| S3 | A weakness, no sign of use | a vulnerable pin, a missing alert, a published non-secret identifier | the patch deadline (`patching.md`) |

## 3. The first hour, in this order

1. **Open a register entry** (section 10): time, who noticed, what, severity. Write as you go, not afterwards.
2. **Stop making it worse, and do not rebuild yet.** Do not `cluster-down`, `rolling-replace`, `tofu apply`, `task teardown-all`
   or restart nodes to "see if it goes away": a replaced node takes its disk, memory, audit log and the evidence with it.
3. **Protect the backups first** (section 5). The attacker who has an S3 key can delete the state and the snapshots, and no object lock exists to stop them.
4. **Preserve evidence** (section 4) from the nodes in question.
5. **Contain** (section 6), **rotate** (section 7), **find and fix the cause**, only then **restore** (section 8).

## 4. Preserve evidence before any node is replaced

Open the tunnels (`task tunnels-up PROVIDER=…`). `dmesg`, `logs`, `list`, `processes`, `service` work with a short-lived `os:reader` file
(`task talosconfig-new`); `read` of a file is refused to `os:reader` (measured, `talosconfig-new.sh` header) and the etcd snapshot is an admin call, so
those two need the admin `talosconfig`, which may be the stolen one: do them early, and expect the attacker to see you. Per node of interest, into a directory outside the repository on an encrypted volume:

```bash
N=<node ip>; D=evidence/$(date -u +%FT%H%MZ)-$N; mkdir -p "$D"
talosctl -n "$N" dmesg                       > "$D/dmesg.txt"
talosctl -n "$N" logs machined               > "$D/machined.log"       # likewise apid, kubelet, containerd, etcd on a control plane
talosctl -n "$N" list /var/log               > "$D/var-log.txt"
talosctl -n "$N" read /var/log/audit/kube/kube-apiserver.log > "$D/kube-apiserver-audit.log"   # control planes
talosctl -n "$N" processes                   > "$D/processes.txt"
talosctl -n "$N" netstat --all --programs    > "$D/netstat.txt"        # check the flags with `talosctl netstat --help`
talosctl -n "$N" service                     > "$D/services.txt"
# once, from one control plane: the store of record of what the cluster believed
talosctl -n <control plane ip> etcd snapshot "evidence/etcd-$(date -u +%F).snap"
kubectl get events -A -o json > evidence/events.json; kubectl get clusterrolebindings,rolebindings -A -o json > evidence/bindings.json
( cd evidence && find . -type f -exec sha256sum {} + > SHA256SUMS )     # then keep SHA256SUMS apart from the files
gpg --symmetric --cipher-algo AES256 -o evidence.tar.gpg <(tar c evidence)    # under the artifact passphrase (K6), not in the repo
```

Every command above is read-only on the node. The etcd snapshot contains every Secret **encrypted under K3, whose key is in the machine config**:
it is as sensitive as the cluster, so encrypt it and treat K3 as part of the incident. What disappears when a node is replaced: memory
(processes, network connections), `/var` (EPHEMERAL, local-path volumes, audit log) and its LUKS key. Take images at the provider (a snapshot of the instance
volume) when the provider offers it and the node is not yet destroyed. The Kubernetes events and the Alloy/Loki logs live in the cluster, so copy what you need from them first.

## 5. Protect the backups first

A copy that cannot be read after the incident is not a backup; a copy the attacker can delete is not one either.

1. Check, from a machine that is **not** involved, that the last good set exists on **both** stores: `task backup-state PROVIDER=<p> -- --list`,
   `aws s3 ls` on the artifact buckets (endpoint and the holder's credentials), `restic snapshots` on the two repositories. Note the dates.
2. **Copy the replica out** (the other provider's bucket, read with its own key) to media you control, before you change anything.
3. **Replace the object-store keys** (K7): create a new pair at the provider, put it in `.env.sh` and in OpenBao (`secret/backup/s3-primary`, `s3-replica`), confirm a backup run succeeds,
   **then** revoke the old pair. Order matters: revoke last, or backups stop. The Loki pair too (`OA_LOKI_S3_*`).
4. If the leaked thing is the **restic password**, a copy of the bucket already has the data; see the rotation table (new repository).
5. No object lock is configured. Turning on versioning or an object-lock retention at the provider before the next incident is a decision recorded in `backup-policy.md` ("What is not done").

## 6. Contain

- **Do not power nodes off.** Isolate instead: tighten the provider security group or the bastion allowlist (`admin_ip`) to your own address, or remove the suspect
  node's group; on Scaleway the group only filters public traffic (`network.md`), so isolating a node on its private network needs the host or the CNI, not the group.
  `kubectl cordon` the node; suspend the Flux Kustomization that applies the suspect change (`flux suspend kustomization <name>`) so nothing reverts your evidence.
- **A suspicious pod**: label and cordon, keep the pod (do not delete it), copy its logs and filesystem metadata, then isolate it with a Cilium policy; the default is deny on ingress cluster-wide, **egress is not denied cluster-wide** (`network.md`).
- **The bastion**: if it is the suspect, replace it (`admin-access.md`, "Closing the Internet egress", the `-replace` addresses) after taking its logs with `bastion-logs-pull.sh`; the tunnels die with it.
- **A departed operator** (a planned event that is handled like S2): section 7, last rows.

## 7. Rotation table

Order: what lets the attacker back in first, what protects the rest next. Commands live where the key's page puts them; "Who decides" is the incident lead.
All procedures are written, **not run**; time targets are not measured.

| Secret (key id) | When | How | Then |
|---|---|---|---|
| Object-store keys (K7), provider keys (K8) | any suspicion of the machine holding `.env.sh` | section 5 step 3; at the provider for K8 | search the cloud audit trail for what the old key did |
| Bastion SSH key of a person (K9) | departed or compromised operator | `admin-access.md`, "Offboarding": stop signing, or replace the bastion with the key in `revoked_keys` | read `bastion-logs-pull.sh` output for what the key did |
| SSH CA private key (K9) | CA exposed | generate a new CA, set `bastion_ssh_ca_public_key`, replace the bastion | re-sign for everyone |
| Admin `kubeconfig` / `talosconfig` (K2), Talos PKI (K1) | leaked file, or a node under attacker control | `key-management.md` section 3: new cluster (tested route) or `talosctl rotate-ca` (upstream route, not run) | reissue every file, erase old state generations |
| State / artifact passphrase (K5, K6) | leaked, or the vault holding it lost | `key-management.md` section 3 | delete the objects under the old one |
| etcd Secrets key (K3), disk passphrase (K4) | leaked with a snapshot, a disk or the state | `key-management.md` section 3 (rebuild) | treat every Secret as leaked: rotate what they contain |
| OpenBao seal key (K11) | leaked with a raft snapshot or the PVC | apps `vault/README.md`, "Seal key rotation" (run on a cluster twice) | redo the escrow and its attestation |
| Recovery shares (K10) | an operator leaves, or loses a key | `OpenAether-apps/docs/key-inventory.md`, "Replacing a key": generate a root token with a quorum, `bao operator rekey` to the new PGP set, revoke the token | update `openbao_recovery_pgp_keys` for future clusters |
| restic password | leaked, with the bucket readable | `restic key add` / `remove`; or a **new repository** if the old one was readable by the attacker | empty and delete the old path (`backup-policy.md`) |
| Zitadel masterkey, database passwords, Longhorn passphrase, Grafana/MinIO passwords | per the apps inventory | `OpenAether-apps/docs/key-inventory.md`, "Replacing a key" | restart the consumers; note that the masterkey has no supported rotation and the Longhorn one must not change under encrypted volumes |
| CI secrets: `CI_BASTION_SSH_PRIVATE_KEY`, sandbox provider keys, `CLEA_WORKFLOW_TOKEN`, the GitHub account | the repository or an account is suspect | revoke and reissue at the issuer; `supply-chain.md` lists them | review workflow runs and the rulesets (`repo-settings` workflow) |
| Anything published (a token or an address in a commit) | gitleaks, or you noticed | revoke first; a history purge limits the tail but "a published datum is published" (`CLAUDE.md`) | rotate everything the leaked file listed |
| Zitadel human accounts | an account is suspect | disable the user in the console; MFA is forced by the apps policy on a new instance | check Grafana roles |

`seed-openbao.sh` is create-only (`cas=0`): a rotated value is written by the operator as a new version of the path
(apps inventory), not by re-running it. A rotate-secret task and a replace mode are tooling work, not in this page's scope.

## 8. Restore: choose the point, fix the cause first

1. **Do not restore over the cause.** Know how they got in and close that door before data comes back, or you restore the vulnerability with it.
2. **Find T0**, the earliest evidence of hostile activity. Choose restore points **older than T0**: `restic snapshots` (OpenBao, databases), a CNPG point in time, a state generation or `pre-upgrade` copy
   (`task backup-state … -- --list`), an etcd snapshot (`etcd-*.snap.gpg`).
3. A restore brings back the secrets of its day, including leaked ones. **Rotate after restoring** (section 7), and treat a
   restored OpenBao as a store whose every value may be known to the attacker if T0 is earlier than the snapshot.
4. Follow `disaster-recovery.md` for the order. A rebuilt cluster has a new PKI; that is the cleanest answer to a compromised Talos PKI.
5. Verify before you declare done: `task cluster-security`, `task rbac-review` against the pre-incident file, `task cluster-exposure`, a login to each UI.

## 9. When the usual access is down

- **Zitadel down**: only Grafana's SSO depends on it; the local Grafana login stays enabled. Cluster access is Talos and Kubernetes
  client certificates, and OpenBao is reached by a ServiceAccount token inside the pod (`bao_admin`). None of them goes through Zitadel.
- **The cluster API down, the bastion up**: the tunnels and `talosctl` still reach the nodes (Talos API on 50000): `dmesg`, `logs`, `service`, `etcd status`.
- **The bastion down**: the provider console, then a replacement bastion (`tofu apply -replace=…`). No state or `talosconfig` is on the bastion.
- **Lost the `kubeconfig` / `talosconfig`**: `task restore-artifacts PROVIDER=… [FROM=replica]` (needs K5 or K6 and the store's key).
- **OpenBao sealed or lost**: the break-glass root token needs a quorum of recovery-share holders (apps `vault/README.md`); a restore needs the escrowed seal key.
- **Everything lost but the buckets and the passphrases**: `disaster-recovery.md`.

## 10. Incident register

One row per incident, in a private file next to the tfvars (it holds names and times). A closed incident without "cause fixed" and "lessons" is not closed.

| Field | Content |
|---|---|
| ID, severity, opened (UTC), closed (UTC) | `IR-2026-001`, S1/S2/S3 |
| Detected by, and how | source from section 1 |
| T0 (earliest evidence) and scope | which keys, nodes, data |
| Evidence kept | file, SHA-256, where stored |
| Containment actions, with times | what, who |
| Secrets rotated (list of key ids), with times | K-numbers from `key-management.md` |
| Restore point chosen and why | snapshot or generation id |
| Cause, and the change that closes it | issue or PR |
| Notifications made or ruled out | who, when, why |
| Lessons, and what changes in the documents | |

After every incident, correct this page, `key-management.md` and the alerts that missed it, and put the incident in `audit-register.md`.
A drill of the whole page (a mock S1 on a lab cluster, timed) has **not** been run; the first one is a lab task (`LAB-CHECKLIST.md`, B13).
