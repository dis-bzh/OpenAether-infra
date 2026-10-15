# Backup policy — what is copied, how often, for how long, who can open it, and what is not copied

🇫🇷 [Version française](backup-policy.fr.md)

> Written to answer ANSSI rules on backup policy, restore tests and destruction of media (audit ids F-BKP-07, with
> GH-M37-8). It is one table over mechanisms that exist, not a new mechanism. **RPO and RTO figures are targets
> proposed by the maintainer, not measurements**: where something was measured the date and the place are given. It claims no
> compliance with any ANSSI document.

Two layers keep data. The infrastructure layer (this repository) copies the state, the access artifacts, the etcd
snapshots and the bastion logs. The application layer (`OpenAether-apps`, `apps/base/backup/README.md`, "Backup policy") copies OpenBao,
the databases and, on request, Longhorn volumes. The application table is the master for its rows; they are repeated here
only so that the policy reads in one place, and the DR order is `disaster-recovery.md`.

Terms: **RPO** is the data you can lose (the worst gap between two copies); **RTO** is the time to be usable again, from the decision to restore.
**Primary** is the store of the cluster's own provider; **replica** is the `-backup` store, in production another provider's.

## 1. Policy, per dataset

| Data | Mechanism and frequency | RPO / RTO target | Retention | Destination | Key and holder | Restore test | Destruction |
|---|---|---|---|---|---|---|---|
| tfstate (holds the Talos PKI K1, K3, K4) | Written to the primary by every `tofu apply` (client-encrypted); `backup-state.sh` copies it to the replica after each apply, with a dated **generation** when the state holds Talos secrets | RPO: since the last apply (state changes only on apply) / RTO 2 h | current object, the newest `STATE_GENERATIONS` (5) generations, and `STATE_LABEL` copies (`pre-upgrade`) never pruned | primary and replica buckets `s3-<project>-<provider>-tfstate-<env>[-backup]` | K5, held by the operator(s); the S3 keys K7 | A full failover was run once, OVH to Scaleway, 2026-10-05 (`status.md`); the generation recipes on two real stores, 2026-10-06 (`cluster/README.md`); `test-restore-state.sh` offline. No scheduled test | section 3 |
| `talosconfig`, `kubeconfig` | Encrypted with gpg and uploaded by `backup-artifacts.sh` during the Phase-2 apply and whenever either file changes | RPO: last change / RTO 30 min | the current object, overwritten | both stores, `s3-<project>-<provider>-<role>-<env>[-backup]` | K6 if set, else K5 | `task restore-artifacts` byte-identical from the primary and from a replica on another cloud (OVH and Scaleway, 2026-10-05), from both stores of an Outscale cluster on its own endpoint (2026-10-03) | section 3 |
| etcd snapshot (Secrets written by Jobs, PVC bindings, whatever lives only in etcd) | `etcd-snapshot.sh`, by hand or from the operator's cron (`etcd-snapshot-cron.sh`, example 03:40 UTC daily); `cluster-upgrade` takes a `pre-upgrade` one | RPO: 24 h if the cron runs, **nothing runs it for you** / RTO 2 h | the newest `KEEP` (30) per store; labelled snapshots never pruned | both stores, `backups/etcd/` | K6 if set, else K5 (and the content is protected by K3 inside) | Restored on OVH during the upgrade drill (`upgrade.md`: etcd members back 52 s after `bootstrap`, API 4.3 min after the rollback). Not drilled as a DR from an empty account | section 3 |
| Bastion logs (journal, audit log) | `bastion-logs-pull.sh` by the operator's cron, `OA_LOGS_UPLOAD=1` | RPO: the interval between pulls (daily proposed); the logs on the VM are not tamper-proof / n/a | no rule: kept until deleted | both stores, `backups/bastion-logs/` | `OA_LOGS_PASSPHRASE` | Reading one back checked on a hand-built export only (`admin-access.md`) | section 3 |
| OpenBao (raft: KV, PKI intermediate, policies) | apps `openbao-snapshot` CronJob, daily 02:17 UTC, restic | 24 h / 4 h | 14 d, 8 w, 12 m | the 2 restic repositories (`s3-primary`, `s3-replica` in OpenBao) | restic password AND the OpenBao seal key, both in offline escrow | apps: monthly `openbao-snapshot-restore-test`; a full restore: manual, measured pieces only (apps vault README) | section 3, and apps README "Decommissioning a bucket" |
| CNPG databases (zitadel, grafana): dump | apps `cnpg-dump` CronJob, daily 02:47 UTC, restic | 24 h / 4 h | 14 d, 8 w, 12 m | the 2 restic repositories | restic password | apps: monthly `cnpg-dump-restore-test` (`pg_restore --list`) | as above |
| CNPG databases: WAL archive | apps CNPG `barmanObjectStore` and `ScheduledBackup` | minutes / 4 h | 30 d | the cluster's own provider only (CNPG offers one destination) | S3 credentials; **no client-side encryption** | none automated; the apps README PITR procedure **has not been run** | bucket lifecycle at the provider |
| Longhorn volumes | apps opt-in RecurringJob group | per job / not set | per job | the environment's `backupTarget` | LUKS passphrase | none | at the provider |
| Kubernetes resources | none: Flux re-applies the repository | n/a / the DAG converging (35 Kustomizations measured, about 2 minutes after the seed on Scaleway) | Git history | Git | n/a | the DAG on a fresh cluster, every lab | n/a |

Proposed overall targets: **RPO 24 h, RTO one working day (8 h)** for a full recovery by `disaster-recovery.md`. No full recovery has
been timed from an empty account; the sum of the pieces measured above is lower, but the pieces were measured separately.

## 2. What is not backed up, and why

| Data | Why |
|---|---|
| Metrics (VictoriaMetrics, local-path, 30 days) | Reproducible telemetry; its loss costs history, not service |
| Logs (Loki chunks) | Own bucket `s3-<project>-<provider>-logs-<env>`, no replica, one-year retention at Loki: a **log store, not a backup** |
| `local-path` volumes and Alertmanager silences | Ephemeral by decision; the Alertmanager configuration comes from Git, the silences are lost |
| Longhorn volumes outside the backup group | No platform component uses Longhorn today |
| Node disks and the Talos image | Nodes are replaced, not restored; the image is rebuilt from the Image Factory (the sha256 lock pins what it should be) |
| Anything in a namespace the DAG does not create | Not known to this repository |
| The CI runners and the maintainer's laptop (`.env.sh`, tfvars, vault of K5/K6) | Outside the platform: **the loss of K5 and K6 is not recoverable** and their escrow is the operator's (`key-management.md`) |

## 3. Destruction, expiry and decommissioning

**There is no automatic expiry beyond the counts above.** No bucket has versioning, a lifecycle rule or an object lock set by this repository, so an
object that left the retention count is deleted, but a **version** of it, if the provider's bucket is versioned, is not; and an attacker holding K7 can delete the lot.
That is a known gap, recorded here; turning on versioning and a retention lock is a decision per provider (support and cost differ, none verified here) and is not made.

- **Expiry**: generations and snapshots are pruned by the scripts. After a **key change**, delete the old objects yourself
  (`key-management.md`, section 4): the old passphrase opens everything written under it.
- **Replacing a repository or a bucket** (a leaked restic password, a provider left): confirm the other copy restores, revoke the access key at the provider, delete **every object
  version and delete marker**, delete the bucket, and check at the provider that it is gone. A snapshot you can no longer read is not erased; only deleting the object is.
- **Decommissioning a cluster for good**: `cluster-down` leaves the buckets and the image on purpose. After the last restore you might need: empty (versions included) and delete the four
  buckets of the cluster on both providers and the logs bucket, delete the Talos image and its snapshots (`purge-orphans`, the image retention), revoke K7 and K8,
  destroy K5 and K6, and remove the cluster's files from the operator machine and the CI `sandbox` secrets. List what remains by asking the provider, not the state file.
- **Media**: a disk, a laptop or a USB stick that held a key is erased by destroying it or its volume key, not by `shred` (`key-management.md`, section 4).

## 4. What is not done

- No object lock and no versioning (above): a stolen S3 key can delete backups.
- No scheduled restore test of the infrastructure layer; the application layer's monthly tests read dumps and unpack snapshots but load nothing into a live database.
- The etcd snapshot, the state replication on a changed state and the bastion log pull depend on the operator remembering to schedule them. `task check-alerts` and the apps backup alerts watch only the application layer.
- RPO and RTO are targets. The first timed drill (`disaster-recovery.md`, section 5) turns them into numbers.

## 5. Review

Re-read this page with every change to a backup script, a bucket, a schedule or a retention count, after every restore (to correct the targets) and at least yearly.
