# Disaster recovery — one ordered chain, from nothing to a working platform

🇫🇷 [Version française](disaster-recovery.fr.md)

> Written to answer ANSSI rules on a documented recovery plan, time targets and a recovery test (audit id F-BKP-16). It links the
> existing pieces in the order that works, and since 0.4.0 `task dr-restore-plan` runs them in that order; **the chain as a whole has never been run on a cluster**: the pieces were
> each exercised (the rung is said for each step), the joins between them were not. The time targets are proposals, not
> measurements. It claims no compliance with any ANSSI document.

Read `backup-policy.md` first for what is copied, and `incident-response.md` if the reason for the recovery is an attack (choose a
restore point older than T0, close the door first, rotate after restoring).

## 1. Which disaster

| Situation | Path |
|---|---|
| One node lost or misbehaving | `rolling-replace` (`upgrade.md`, "Replacing a node"): not this page |
| The cluster is gone, the provider and the buckets are fine | sections 2 and 3, on the same provider |
| The provider is gone (account, region, the primary store) | sections 2 and 3, starting from the replica on the other provider: `cluster/README.md`, "Cross-provider failover" |
| The state lost its Talos secrets but the nodes live | `cluster/README.md`, "Lost the Talos secrets": not a rebuild |
| Only OpenBao lost its data | section 3 from step 5 |
| An attack | `incident-response.md` first |

## 2. Prerequisites: what must already be outside the cluster

If one of these is missing, the corresponding step cannot be done; the recovery objective then changes to "rebuild without that data".

| Needed | Held by | Lost means |
|---|---|---|
| K5 (and K6 if set) | the operator's vault, two places ideally | the state, artifacts and snapshots are unreadable: **no recovery of the Talos PKI**; rebuild with a new PKI |
| Object-store keys of the **surviving** store (`<PU>_BACKUP_AWS_*` or the primary's) and provider credentials | `.env.sh`, the vault | create new ones at the provider; they are not the keys of any secret |
| The cluster's tfvars (`envs/<role>-<provider>.tfvars`, gitignored) | the operator's machine | rebuild it from the `.example` with the cluster name, environment, `bucket_suffix`, replica endpoint and region (`cluster/README.md`) |
| The OpenBao seal key (escrow, two custodians) | `docs/admin-access.md` section 1; apps Day 0 | **every OpenBao secret and every raft snapshot is lost** |
| The OpenBao recovery shares (PGP-encrypted) and the holders' private keys | the operators | no break-glass: the restore needs a root token |
| The restic password (escrow) | the vault | the application backups are unreadable |
| This repository at the tag that built the cluster, and OpenAether-apps at the `git_ref` it pinned | GitHub, and the operator's clone | build from the tag you can pull; nothing here is vendored |

## 3. The chain

Do the steps in this order. A step that fails stops the chain: do not skip ahead to "get something up".

| # | Step | How | Why this position | Rung and target (proposed) |
|---|---|---|---|---|
| 1 | Access to the old cluster's identity | `task restore-artifacts PROVIDER=<p> [FROM=replica]` for the talosconfig and kubeconfig; `task restore-state` for the state if the provider changed | Everything after needs the state (it holds the Talos PKI) and, for a cross-provider rebuild, the old kubeconfig to check against | Both measured on real stores (`backup-policy.md`). 30 min |
| 2 | Cluster | `task cluster-up PROVIDER=<p> [ROLE=…]` with the tfvars; the state, then the nodes, then Flux if `deploy_flux = true` | Nothing else exists without nodes | Measured `cluster-up`: 545 s to 1661 s on the three clouds, the longer ones including an image build (`status.md`). 1 to 2 h |
| 3 | **Seal key Secret, before the OpenBao pods start** | Create `foundation-vault` if needed, then `openbao-seal-key` from the escrow (`gpg --decrypt openbao-seal-key.gpg`, or the shares combined; apps `vault/README.md`, "Disaster recovery", step 1; `task escrow -- verify` rehearses the opening on a live cluster); suspend the Kustomizations that consume secrets | The raft snapshot is encrypted by this key; `init.sh` refuses to invent a key on a cluster that was initialised before, but on a **new** cluster it would invent one and your snapshot would be unreadable | Written, tested on a real OpenBao ("with any other key the data does not come back"); **not drilled on a cluster**. 15 min |
| 4 | OpenBao up and empty | Let `foundation-vault` deploy; `init.sh` initialises it | You restore into a running, initialised OpenBao | Measured at install on every lab. 15 min |
| 5 | **OpenBao snapshot restore** | On the operator machine: `restic restore latest` of the repository `<bucket>/<CLUSTER_NAME>/openbao` (the CronJob's value; the example in the apps README omits `<CLUSTER_NAME>`) with the restic password from escrow and the surviving store's keys (**not** from OpenBao: they live in the thing being restored); then with a break-glass root token of the fresh cluster (a quorum of share holders), `bao operator raft snapshot restore -force <file>` (apps `backup/README.md` and `vault/README.md`) | The Zitadel masterkey, the database passwords, the restic and Longhorn passphrases and the PKI intermediate all come back from here. Nothing else can start correctly before | The restore command was run on a real OpenBao; the whole step is **not drilled with standbys** (apps README). 1 h |
| 6 | Recovery shares back | Replace the fresh `openbao-recovery-shares` with the source's saved copy (apps README, DR step 4) | The restored data is under the source cluster's recovery keys | As step 5. 15 min |
| 7 | External Secrets and the rest resume | Resume the suspended Kustomizations; `kubectl get externalsecret -A` all Ready; the restic and `zitadel-masterkey` Secrets exist | The cluster's own Secrets are rebuilt from OpenBao, which is why step 5 precedes the next | Observed at install. 15 min |
| 8 | **Databases (CNPG)** | **Before Zitadel serves**, hold the `identity` Kustomization (or scale Zitadel to 0). Restore from the restic dump (`pg_restore … --clean --if-exists`) or by point in time into a new Cluster (apps `backup/README.md`) | The masterkey in OpenBao (step 5) must already be in place: a database restored under a different masterkey is unusable | `dr-restore-plan` step `dbs` (PITR through a scratch Cluster, or the dump); the recovery itself ran by hand and is now tested daily; **the load into a live Cluster has not been run on a cluster**. 1 h |
| 9 | Zitadel and the rest of the DAG | Resume `identity`; wait for the DAG (the number of Kustomizations moves with the bricks picked) | Identity needs its database and masterkey | Convergence measured at install (35 Kustomizations about 2 minutes after the seed, Scaleway). 30 min |
| 10 | What lives only in etcd | Only if needed: the etcd snapshot (`talosctl bootstrap --recover-from`; the scheduled one is the restic repository `<bucket>/<CLUSTER_NAME>/etcd`, `restic restore latest` with the escrowed restic password, and the file is passed with `--recover-skip-hash-check` only if it has no sha256 trailer; the operator's gpg ones are `backups/etcd/`), which **replaces** the current etcd and everything written since | A last resort: Flux rebuilds the cluster's content | Run on OVH in the upgrade drill (`upgrade.md`). Not part of the normal chain |
| 11 | Verify | `task cluster-verify`, `task cluster-security`, `task rbac-review`, a login to each UI, a backup run, then re-seed what is outside OpenBao (`seed-openbao.sh`) if the snapshot predates it | Declare done on evidence | Targets of the commands, not of the chain. 30 min |
| 12 | After an attack only | Rotate (`incident-response.md`, section 7), then erase the old cluster's state generations | A restore returns the old secrets | n/a |

**Proposed time target for the whole chain: 8 hours of work, one working day (RTO), data as of the last good backup (RPO below).** The sum of the
step targets above is about 6.5 hours. Lab 20 timed the chain on a throwaway cluster: 31 minutes of steps (below); the proposal stays until a drill of a production shape.

### One command

`task dr-restore-plan` is the table above as a command (`scripts/ops/dr-restore-plan.sh`; it adds no mechanism, every step calls a command that exists). It is a **dry-run by default**: it prints each step with the commands for THIS
cluster (its buckets, repositories and store), the inputs each step still needs and which are missing, and runs nothing. Run it, with `--strict`, before the day you need it. `--execute --confirm <cluster_name>` runs the
chain, a check after each step, and stops at the first failure with the step to resume from; it writes a timing report (a TSV, seconds and target per step, the wall clock against the 8 h) to fill the table of section 5.

```bash
task dr-restore-plan PROVIDER=scaleway -- --from replica                         # dry-run: ordered steps, this cluster's commands, missing inputs
task dr-restore-plan PROVIDER=scaleway -- --from replica --strict --seal-key-file F --restic-password-file F \
  --bao-token-file F --recovery-shares-dir D                                     # readiness: exits 1 if an input is missing
task dr-restore-plan PROVIDER=scaleway -- --from replica --seal-key-file F --restic-password-file F --bao-token-file F \
  --recovery-shares-dir D --execute --confirm <cluster_name>                     # the chain; --from-step <id> resumes, --only <id,id> runs a subset
```

Steps (rebuild scenario): `artifacts` (1), `cluster` (2, with `deploy_flux = false`), `seedkey` (3), `flux` (4: `deploy_flux = true`, a second `task cluster-up`; the previous tfvars is kept as `.dr-bak`), `hold` (the Kustomizations outside OpenBao's dependency
closure are suspended), `openbao` (5), `shares` (6), `resume` (7: everything held except identity), `dbs` (8), `identity` (9), `verify` (11, which ends with a restore test run on the rebuilt cluster). `--db-source pitr` (default) recovers each
CNPG database from the ObjectStore of the chosen store (optionally `--pitr-time`) into a scratch Cluster `<name>-dr`, then streams `pg_dump | pg_restore --clean` into the empty live Cluster and checks the canary chain; `--db-source dump` restores the
restic dump instead (RPO 24 h, no archive needed: the path when the other provider's archive is gone). `--scenario etcd` is step 10 alone: restic restore of the newest etcd snapshot, `talosctl bootstrap --recover-from` (with `--recover-skip-hash-check` when the
file has no sha256 trailer), and a check that the API and the nodes are back. Secrets are read from files and travel on stdin or as file arguments, never in argv or in the output.

### RPO, RTO, what was measured and what was not

| Data | RPO (worst case) | Where it comes from |
|---|---|---|
| OpenBao | 24 h | daily snapshot 02:17 UTC, restic on both stores |
| CNPG databases through the archive | minutes on the primary store; up to **15 min plus the copy** on the replica store (46 s for 22 objects, lab 19) | WAL archive and the 15-minute `cnpg-store-replicate` |
| CNPG databases through the dump | 24 h | daily dump 02:47 UTC, restic on both stores |
| etcd | 24 h | snapshot 04:10 UTC, restic on both stores |
| Longhorn volumes | per recurring job (daily 03:37 UTC when on) | one store only |
| tfstate, artifacts | since the last apply or change | both stores |

RTO target: **8 h** for the whole chain (0.4.0 decision; tighten after the first timed run). What was measured, piece by piece, with the shape of the lab: `cluster-up` 8 min 53 s (Scaleway, 3 + 3 POP2-4C-16G, lab 19) and 545 s to 1661 s on
the three clouds (`status.md`); the whole DAG Ready 23.5 min (Scaleway) and 29 min (OVH) after the start (0.3.0 final validation); CNPG recovery into a new Cluster 40 s (lab 15A), 54 s (15c), 72 s with a point in time from the primary store and 66 s from the
**replica store alone** with the primary emptied (lab 19, 150 tables = origin); Longhorn RWO, LUKS2 and RWX restored into new volumes, 82 s, sha256 identical (15c); an etcd snapshot of 97.7 MB restored from the replica store with the escrowed password
and opened in a local etcd (lab 19). All of these are nominal and separate; the chain as a whole is timed in lab 20, below.

**Measured in lab 20** (2026-10-20, Scaleway 3 + 3 POP2-4C-16G, OVH as the replica store, `--from replica`, a development OpenBao, Flux following a lab branch): the chain ran twice on a cluster that had been destroyed with `cluster-down` (buckets kept). Steps in seconds, second run, all fixes in: artifacts 4, cluster 586 (`cluster-up`, the image already built), seedkey 0, flux 502 (the second `cluster-up`), hold 6, openbao 9 (restic restore from the replica and the raft restore), shares 1, resume 46, dbs 329, identity 10, verify 348 = **1 841 s, 30.7 minutes** of steps against the 8 hours of the proposal; by the clock, from the decision to the last step, 31 minutes in the second run and 52 minutes in the first (six defects found and fixed on the way, each listed in the CHANGELOG). Between the two segments of the second run the operator minted the break-glass root token of the fresh cluster (2 s with the dev share; with a production OpenBao it is the quorum of share holders, the time of the people). Data: the databases came back with the same tables (151 and 92), the same Secrets (hashes of the Zitadel masterkey, the restic and Grafana ones equal), the canary chain intact; the rows written after the last 15-minute copy were lost (two rows, about 6 minutes: the RPO of a restore from the replica). The OpenBao raft snapshot, the CNPG PITR from the replica, the restic dump, the Longhorn backup (restored into a new volume on the rebuilt cluster, 32 s, files identical) and the etcd snapshot (fetched from the replica in 3 s) all came back. The etcd scenario was run in place on the second cluster with its own snapshot (control planes reset with EPHEMERAL wiped, `bootstrap --recover-from`): 3 members and 6 nodes Ready within 4 minutes, a ConfigMap created after the snapshot gone; the Cilium agents had to be restarted afterwards (the chain does it now).

**Not proven yet / failed in lab 20**: (1) **the verify step of the second run FAILED** (`zitadel-db` from both stores "trails the live database by 7288 s"): the rebuilt cluster archives into the dead cluster's WAL path, the plugin refuses ("Expected empty archive", `ContinuousArchiving` False) and the live canary outruns the old archive; the rebuilt cluster has no continuous archive and no base backup until the archive generation changes (apps #153); (2) an etcd snapshot of ANOTHER cluster cannot be restored into a rebuilt one: the control planes stayed NotReady (the new PKI and bootstrap token), the scenario is for the same cluster; (3) a production OpenBao (shares encrypted to PGP keys), the quorum for the break-glass token, a new cluster name, the dump source (`--db-source dump`) on a rebuilt cluster, and a provider loss with the other cloud are not drilled.
on the standard input of `kubectl exec`, `/tmp` writable in the pod); `talosctl bootstrap --recover-from` on a throwaway Talos cluster; the load of a recovered database into the live Cluster (owner and role handling); a new cluster name (the restic prefix is the
old name, so the script, which reads the name from the tfvars, expects the same name); the scheduled restore tests below have run only offline.

### The scheduled restore tests (0.4.0)

Since 0.4.0 the platform restores its own backups without a person (apps `backup/databases`, `cnpg` and the opt-in `storage-restore-test`): daily `cnpg-recovery-restore-test` recovers zitadel-db and grafana-db from the primary AND the replica store into a scratch Cluster in
`backup-restore-test` and compares a canary table (a counter and a hash chain written every 5 minutes) with the live database; weekly `cnpg-pitr-restore-test` recovers to the time of one canary row and must end exactly there; daily `cnpg-dump-load-restore-test` loads the restic dumps of
both repositories into a private PostgreSQL; the opt-in `longhorn-restore-test` restores a canary volume weekly. Results are `oa_restore_test_*` metrics with `RestoreTestFailed`, `RestoreTestNoRecentPass` and the other alerts of `vmrule-restore-test.yaml`. A scratch object is always removed, even
on failure, and a restore test can never touch a live object (namespace, names, RBAC and a Kyverno policy). The OpenBao raft snapshot is checked daily as far as its sums; it is restored into an OpenBao only by this chain.

**Points where the chain had an unsettled join** (lab 20): (a) step 3 against Flux: building with `deploy_flux = false`, creating the seal key Secret, then switching Flux on works; `hold` suspended 34 Kustomizations 6 s after the init Job completed and nothing consumed the throw-away values (the fresh bootstrap's generated Secrets were replaced by the restore); (b) the restic prefix of the surviving repositories is the cluster id `<cluster_name>-<environment>-<provider>` (not the bare name), and a new cluster name needs that prefix in the command; (c) the PITR chain is on the provider that failed in a provider loss: only the daily dump survives on the other one (RPO 24 h). Also learned: a cluster brought up after its state was destroyed has a new PKI, so the chain takes the new kubeconfig and talosconfig after each `cluster-up`; unattended, `OA_DR_TASK="task KEY=<ssh key> APPROVE=auto"` lets the chain's `cluster-up` run without a terminal; the databases are restored as the owner of the database (`--role`), not as postgres.
right after the API answers, or build with `deploy_flux = false` and enable it after the Secret exists): not tried, it is a lab step; (b) whether the surviving replica holds the
restic repository of the **cluster that died** under the prefix the new cluster expects (the repository prefix is the cluster name; a new cluster name needs the old prefix in the command);
(c) the PITR chain is on the provider that failed in a provider loss: only the daily dump survives on the other one (RPO 24 h).

## 4. Rebuild with data loss: when a prerequisite is missing

| Missing | What you can still do |
|---|---|
| The seal key | A new OpenBao, re-seeded: `seed-openbao.sh`, new Zitadel masterkey (the identity layer starts empty), new database passwords (databases restored from dumps cannot be used with them; restore the dump first, then align the role passwords), new restic password and **new repositories**; the old backups of OpenBao are unreadable |
| K5 and K6 | A new PKI: a new cluster from scratch; the old nodes cannot be administered; only the application backups (restic) remain |
| The restic password | The application backups are lost; new repositories |
| All recovery shares | No break-glass; restore needs a root token: a new OpenBao and the loss of its content |
| The surviving store | Rebuild from the Git repositories, and nothing else |

## 5. Drill: yearly, with a result table

A recovery that has not been rehearsed is a hypothesis (`restore-artifacts.sh` says it of a single script; it holds for the chain). Cadence: **once a year, and after any change to a step above**, on a throwaway cluster
of the smallest shape (1 control plane + 1 worker, `capacity.md`) in a project that holds no production data, from a real backup of a lab cluster, with a
timer started at the decision and every step noted as run, skipped or failed.

| Date | Cluster, provider | Steps run | RTO measured | RPO measured | What failed | Corrections made |
|---|---|---|---|---|---|---|
| 2026-10-20 | lab 20: Scaleway 3 + 3 POP2-4C-16G, OVH replica store, `--from replica`, development OpenBao | artifacts, cluster, seedkey, flux, hold, openbao, shares, resume, dbs, identity, verify (run 2); etcd scenario in place (own snapshot) | steps 1 841 s (30.7 min); 31 min by the clock from the decision (run 2), 52 min (run 1, six fixes on the way) | rows after the last 15-minute copy lost: 2 canary rows, about 6 min | verify FAILED: the rebuilt cluster cannot extend the old WAL archive (apps #153); 8 chain defects in run 1 (the identity, the Cluster kind, pg_restore, the owner, the verify, the node of the etcd step), fixed | infra commits of 2026-10-20 (CHANGELOG, "found by lab 20") |

The first drill is `task dr-restore-plan ... --execute` on a throwaway cluster (`LAB-CHECKLIST.md`, B13 and B17): it settles the three joins above and replaces the proposed targets with numbers; its report TSV is the source of the row.
Whoever runs it writes the row, corrects this page, and states in the CHANGELOG the rung reached.

## 6. Review

Re-read with every change to the DAG order, a backup mechanism, the OpenBao seal or the cluster-up flow; after each drill; at least yearly.
