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
| etcd snapshot (Secrets written by Jobs, PVC bindings, whatever lives only in etcd) | The apps `etcd-snapshot` CronJob, daily 04:10 UTC, through the Talos API with the role `os:etcd:backup` only (`etcd_snapshot_api_access`, on by default), restic to both stores; `etcd-snapshot.sh` stays the operator's command (gpg, `cluster-upgrade` takes a `pre-upgrade` one) | RPO 24 h / RTO 2 h | restic: 14 d, 8 w, 12 m per store; the operator's labelled snapshots are never pruned | both stores: the restic repository `<cluster>/etcd` of the backups bucket, and `backups/etcd/` for the operator's | the restic password (OpenBao + offline escrow) for the CronJob's, K6 if set else K5 for the operator's (the content is protected by K3 inside) | The apps verifier reads it daily (restic data check, the file is a bolt database whose meta pages and hash hold); not yet restored into an etcd (that is the restore tests, M3). Restored on OVH during the upgrade drill (`upgrade.md`) | section 3 |
| Bastion logs (journal, audit log) | `bastion-logs-pull.sh` by the operator's cron, `OA_LOGS_UPLOAD=1` | RPO: the interval between pulls (daily proposed); the logs on the VM are not tamper-proof / n/a | no rule: kept until deleted | both stores, `backups/bastion-logs/` | `OA_LOGS_PASSPHRASE` | Reading one back checked on a hand-built export only (`admin-access.md`) | section 3 |
| OpenBao (raft: KV, PKI intermediate, policies) | apps `openbao-snapshot` CronJob, daily 02:17 UTC, restic | 24 h / 4 h | 14 d, 8 w, 12 m | the 2 restic repositories (`s3-primary`, `s3-replica` in OpenBao) | restic password AND the OpenBao seal key, both in offline escrow | apps: monthly `openbao-snapshot-restore-test`; a full restore: manual, measured pieces only (apps vault README) | section 3, and apps README "Decommissioning a bucket" |
| CNPG databases (zitadel, grafana): dump | apps `cnpg-dump` CronJob, daily 02:47 UTC, restic | 24 h / 4 h | 14 d, 8 w, 12 m | the 2 restic repositories | restic password | apps: monthly `cnpg-dump-restore-test` (`pg_restore --list`) | as above |
| CNPG databases: WAL archive | apps CNPG with the Barman Cloud plugin (`ObjectStore` objects) and `ScheduledBackup` (method plugin) | WAL: minutes on the primary store, up to 15 min more on the replica / 4 h | 30 d (Barman retention; the replica keeps an object 45 d after it left the primary) | the primary store, copied to the replica store every 15 min by `cnpg-store-replicate` with the replica key pair | S3 credentials; **no client-side encryption** of the WAL and base backups: server-side (SSE-S3 requested) and TLS only, and the copy on the replica store is the same bytes (SSE-S3 header read back on OVH objects in lab 19). The client-side encrypted copy is the daily restic dump above | The verifier reads the latest base backup to its end and checks the WAL chain on both stores, daily. A recovery with the plugin has not been run (M3) | bucket lifecycle at the provider |
| Longhorn volumes | apps opt-in RecurringJob group | per job / not set | per job | the environment's `backupTarget`, **one store**: no copy on the replica store yet | LUKS passphrase | The verifier checks the newest backup of each volume is Completed with a size; the blocks are not read | at the provider |
| Kubernetes resources | none: Flux re-applies the repository | n/a / the DAG converging (35 Kustomizations measured, about 2 minutes after the seed on Scaleway) | Git history | Git | n/a | the DAG on a fresh cluster, every lab | n/a |

Proposed overall targets: **RPO 24 h, RTO one working day (8 h)** for a full recovery by `disaster-recovery.md`. No full recovery has
been timed from an empty account; the sum of the pieces measured above is lower, but the pieces were measured separately.

## 2. What is not backed up, and why

| Data | Why |
|---|---|
| Metrics (VictoriaMetrics, local-path, 30 days) | Reproducible telemetry; its loss costs history, not service |
| Logs (Loki chunks) | Own bucket `s3-<project>-<provider>-logs-<env>`, no replica, one-year retention at Loki: a **log store, not a backup**. Its own key pair when you give one (section 4), versioned or locked with `backup_immutability` |
| `local-path` volumes and Alertmanager silences | Ephemeral by decision; the Alertmanager configuration comes from Git, the silences are lost |
| Longhorn volumes outside the backup group | No platform component uses Longhorn today |
| Node disks and the Talos image | Nodes are replaced, not restored; the image is rebuilt from the Image Factory (the sha256 lock pins what it should be) |
| Anything in a namespace the DAG does not create | Not known to this repository |
| The CI runners and the maintainer's laptop (`.env.sh`, tfvars, vault of K5/K6) | Outside the platform: **the loss of K5 and K6 is not recoverable** and their escrow is the operator's (`key-management.md`) |

## 3. Destruction, expiry and decommissioning

**There is no automatic expiry beyond the counts above, unless `backup_immutability` is set.** By default (`off`) no bucket has versioning, a lifecycle rule or an object lock set by this repository: an
object that left the retention count is deleted, but a **version** of it, if the provider's bucket is versioned, is not; and an attacker holding K7 can delete the lot. Turning the protection on is opt-in
and **not verified on any provider** (support and cost differ; the lab checklist of the hardening work lists what to try):

| `backup_immutability` | What `ensure-buckets.sh` sets, then reads back | What it gives | What it does not |
|---|---|---|---|
| `off` (default) | nothing | nothing changes on a deployed cluster | a stolen S3 key deletes the copies |
| `versioned` | versioning on seven buckets; a rule `oa-noncurrent-expiry` expires non-current versions after `backup_retention_days` (60) | a delete or a restic prune by an in-cluster key leaves a version behind | a key allowed `DeleteObjectVersion`, or `PutBucketVersioning` or `PutLifecycleConfiguration`, undoes it: that is the key policy of section 4 |
| `governance` | as `versioned`, and an object lock with a default retention of `backup_retention_days` on the five buckets that hold copies or logs, created with it | an ordinary key cannot remove a version before the retention ends | a key allowed the bypass permission can; the bucket cannot be emptied meanwhile |
| `compliance` | as `governance` | nobody can remove a locked version before the retention ends, the account owner included | it cannot be undone either: the bucket cannot be emptied or deleted until then, and the cost of the versions is owed |

- **Which buckets.** Locked (created with the lock): the application backups and their `-backup` twin, the state and artifact replicas, Loki's logs. Only versioned: the state and artifact primaries, which tofu writes.
  The application-backups pair, until now created by hand, is created by the script in any mode but `off`. Object lock usually has to be set when a bucket is **created**: on one that exists without it the call is refused,
  reported, and the bucket is neither deleted nor replaced (create a new one, or accept `versioned`; changing `bucket_suffix` renames all of them).
- **Rule of thumb for the retention.** Loki deletes its chunks at 365 days (apps) and a delete under versioning leaves a marker and a version for `backup_retention_days` more; restic prune does the same for the
  repositories. Storage grows by about the churn of that many days. A deleted log or backup therefore stays physically present for the retention: not a fit for data that must be gone at once.
- **A restore from versions is not rehearsed.** After a malicious prune the repository is recovered by restoring the previous versions of its objects, which is not the same as a restic restore and has not been run.

- **Expiry**: generations and snapshots are pruned by the scripts. After a **key change**, delete the old objects yourself
  (`key-management.md`, section 4): the old passphrase opens everything written under it.
- **Replacing a repository or a bucket** (a leaked restic password, a provider left): confirm the other copy restores, revoke the access key at the provider, delete **every object
  version and delete marker**, delete the bucket, and check at the provider that it is gone. A snapshot you can no longer read is not erased; only deleting the object is.
- **Decommissioning a cluster for good**: `cluster-down` leaves the buckets and the image on purpose. After the last restore you might need: empty (versions included) and delete the four
  buckets of the cluster on both providers and the logs bucket (a locked bucket cannot be emptied before its retention ends), delete the Talos image and its snapshots (`purge-orphans`, the image retention), revoke K7 and K8,
  destroy K5 and K6, and remove the cluster's files from the operator machine and the CI `sandbox` secrets. List what remains by asking the provider, not the state file.
- **Media**: a disk, a laptop or a USB stick that held a key is erased by destroying it or its volume key, not by `shred` (`key-management.md`, section 4).

## 4. Who can open which bucket

One identity per store, limited to its bucket by the **operator** (the providers' S3 keys are account-wide by default, and this repository ships no policy: the shape below is what the check expects, not something verified on
Scaleway, OVH or Outscale). Without the pairs the cluster runs on the operator's keys, which open every bucket of the cluster and may delete in all of them; `seed-openbao.sh` says so.
The state and artifact buckets are written only from the operator's machine and CI, so no identity of the cluster is meant to reach them.

| Identity (seed variable, OpenBao path) | May open | Needs | Must be refused |
|---|---|---|---|
| Operator K7 (`<PU>_AWS_*`, `<PU>_BACKUP_AWS_*`; never in the cluster) | all buckets of its store | everything | n/a |
| Application backups, primary (`OA_BACKUP_S3_*`, `backup/s3-primary`: restic, Longhorn, CNPG) | `s3-<project>-<provider>-backups-<env>` | list, get, put, `DeleteObject`, multipart upload and its abort | `DeleteObjectVersion`, bucket versioning, lifecycle, object-lock or retention changes, bucket deletion, every other bucket |
| Application backups, replica (`OA_BACKUP_REPLICA_S3_*`, `backup/s3-replica`) | the same name with `-backup`, on the replica store | as above | as above |
| Loki (`OA_LOKI_S3_*`, `observability/loki-s3`) | `s3-<project>-<provider>-logs-<env>` | as above | as above, and the backups bucket |

`DeleteObject` stays allowed: on a versioned bucket it writes a marker, and restic, Barman, Longhorn and Loki delete as part of their work (not tried against a key without `DeleteObjectVersion`).
`scripts/ops/s3-isolation-check.sh <tfvars>` reads, with the pairs in the environment, which identity lists which bucket, whether each dedicated pair is refused `DeleteObjectVersion` (a version that does not exist is named:
nothing is deleted), and whether the buckets carry the `backup_immutability` you set. Exit 0 held, 1 did not, 2 no dedicated pair in scope. The seed is create-only: to **rotate** a pair, create the new one at the provider, write it with `task rotate-secret -- <path> --apply`
(`admin-access.md`, section 3), let the ExternalSecret refresh, confirm a backup or a log flush, then revoke the old one.

**Scaleway: a bucket without a bucket policy is open to every dedicated pair.** The IAM permission sets a pair needs (the three
`ObjectStorage*` object sets, plus `ObjectStorageBucketsRead` for HeadBucket, see the apps backup README) are project-wide, so the pair's reach
is whatever the bucket policies leave open. Lab 12 measured it: with policies only on the backups and logs buckets, the pairs listed the state and
management buckets (`s3-isolation-check.sh`: 4 of 8 assertions failed); with an **operator-only policy on every other bucket** of the project
(state, artifact, management, the `-backup` twins and the image buckets), 10 of 10 held, the delete of a real object version included
(`OA_ISOLATION_REAL_VERSION=1`). So the recipe for a pair, which this repository does not apply for you (the providers' IAM is the operator's): create the
application and its IAM policy, put the operator-only policy on every OTHER bucket, the pair's own policy on its bucket, then run the check. OVH and Outscale: not verified.

**HeadBucket is the first call of every WAL archive and Loki flush, and its right is separate from list (infra #356, #359).** On Scaleway a pair needs
BOTH the IAM set `ObjectStorageBucketsRead` AND `s3:ListBucket` in the bucket policy of its own bucket: a pair with only the three object sets lists and writes, yet
barman-cloud gets a 403 on HeadBucket and every WAL archive fails (measured in a lab; the isolation check passed it, because it only listed). `s3-isolation-check.sh`
now asserts `head-bucket` allowed on each dedicated pair's own bucket and exits 1 naming HeadBucket when it is denied. OVH: per-user policies need the OVH API (the S3 API
answers NotImplemented), so the rule could not be read there. Outscale: dedicated EIM keys were refused by the store (infra #377). Neither is verified; the check is
the test once a pair exists.

### The replica pair, and what to run for it

The replica pair (`backup/s3-replica`) now carries more than the restic repositories: the CNPG archive copy (`cnpg-store-replicate` writes `cnpg/<cluster>/` into the `-backup` bucket), the etcd snapshot repository, and the reads of the verifier. It is a separate pair on the replica store, never the primary's. To create and prove one:

1. Print the policies for the pair and the bucket: `scripts/ops/backup-key-recipe.sh <tfvars> replica` (the same with `primary` for the primary pair). It writes the bucket policy of the pair's own bucket, the operator-only policy for every other bucket, and the rights the pair must hold, with the real bucket names and without any identifier: you substitute your principal.
2. Create the pair at the replica provider with the rights of the recipe (Scaleway: an IAM application and policy with `ObjectStorageBucketsRead` and the three object sets, plus the bucket policies of step 1; OVH: the S3 API refuses per-user policies, so the user's policy goes through the OVH API and the recipe lists the rights to give it; Outscale: an EIM user, policy and bucket policy, but the store refused dedicated EIM keys in lab 15B, infra #377: Outscale is a source, not a replica, until that is solved). Only the Scaleway shape is measured; OVH and Outscale are expectations.
3. Prove it before seeding: `S3_ENDPOINT=... S3_BUCKET=<replica bucket> AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... check-backup-key-rights.sh` (the script of the OpenAether-apps repository, `scripts/ops/` there) (it now also tries the `AES256` server-side-encryption request that the copy and the Barman ObjectStores send; a store that refuses it must have the request removed from the ObjectStores), then seed the pair and run `scripts/ops/s3-isolation-check.sh <tfvars>` with the pair in the environment (`OA_BACKUP_REPLICA_S3_*`, and `OA_ISOLATION_REAL_VERSION=1`).
4. Cluster side, a day later: `oa_backup_verify_ok{dataset=~"cnpg|etcd|openbao|cnpg-dump"}` is 1 for the replica store (`oa_backup_verify_store_ok{store="replica"}`).

## 5. What is not done

- Object lock and versioning are opt-in, and unverified on any provider; the default leaves a stolen S3 key able to delete backups. No policy for the limited pairs is shipped.
- No copy that the cluster's keys can never reach: an operator-side sync to a third, locked bucket was not built, and `forget --prune` still runs in the cluster, with a key that must keep `DeleteObject`. The logs have no second-provider copy.
- No scheduled restore test of the infrastructure layer; the application layer's monthly tests read dumps and unpack snapshots but load nothing into a live database.
- The state replication on a changed state and the bastion log pull depend on the operator remembering to schedule them (the etcd snapshot no longer does, unless `etcd_snapshot_api_access` is false). `task check-alerts` and the apps backup alerts watch the application layer and the in-cluster etcd snapshot.
- The CNPG archive has no client-side encryption (the Barman Cloud plugin offers only the store's `AES256` / `aws:kms`), and Longhorn backups have no copy on the replica store: both are written down as open items, not hidden.
- RPO and RTO are targets. The first timed drill (`disaster-recovery.md`, section 5) turns them into numbers.

## 6. Review

Re-read this page with every change to a backup script, a bucket, a schedule or a retention count, after every restore (to correct the targets) and at least yearly.
