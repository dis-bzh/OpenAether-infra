# Disaster recovery — one ordered chain, from nothing to a working platform

🇫🇷 [Version française](disaster-recovery.fr.md)

> Written to answer ANSSI rules on a documented recovery plan, time targets and a recovery test (audit id F-BKP-16). It links the
> existing pieces in the order that works; **it adds no mechanism, and the chain as a whole has never been run**: the pieces were
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
| 8 | **Databases (CNPG)** | **Before Zitadel serves**, hold the `identity` Kustomization (or scale Zitadel to 0). Restore from the restic dump (`pg_restore … --clean --if-exists`) or by point in time into a new Cluster (apps `backup/README.md`) | The masterkey in OpenBao (step 5) must already be in place: a database restored under a different masterkey is unusable | The dump path is written; `pg_restore --list` tested monthly; **the PITR and the dump restore into a live database have not been run**. 1 h |
| 9 | Zitadel and the rest of the DAG | Resume `identity`; wait for the DAG (the number of Kustomizations moves with the bricks picked) | Identity needs its database and masterkey | Convergence measured at install (35 Kustomizations about 2 minutes after the seed, Scaleway). 30 min |
| 10 | What lives only in etcd | Only if needed: the etcd snapshot (`talosctl bootstrap --recover-from`; the scheduled one is the restic repository `<bucket>/<CLUSTER_NAME>/etcd`, `restic restore latest` with the escrowed restic password, and the file is passed with `--recover-skip-hash-check` only if it has no sha256 trailer; the operator's gpg ones are `backups/etcd/`), which **replaces** the current etcd and everything written since | A last resort: Flux rebuilds the cluster's content | Run on OVH in the upgrade drill (`upgrade.md`). Not part of the normal chain |
| 11 | Verify | `task cluster-verify`, `task cluster-security`, `task rbac-review`, a login to each UI, a backup run, then re-seed what is outside OpenBao (`seed-openbao.sh`) if the snapshot predates it | Declare done on evidence | Targets of the commands, not of the chain. 30 min |
| 12 | After an attack only | Rotate (`incident-response.md`, section 7), then erase the old cluster's state generations | A restore returns the old secrets | n/a |

**Proposed time target for the whole chain: 8 hours of work, one working day (RTO), data as of the last good backup (RPO 24 h).** The sum of the
step targets above is about 6.5 hours. No drill has timed it.

**Points where the chain has an unsettled join**: (a) how step 3 is won against Flux on a cluster brought up with Flux on (suspend `flux-system`
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
| _none yet_ | | | | | | |

The first drill is the dry run of this chain (`LAB-CHECKLIST.md`, B13 and B17): it settles the three joins above and replaces the proposed targets with numbers.
Whoever runs it writes the row, corrects this page, and states in the CHANGELOG the rung reached.

## 6. Review

Re-read with every change to the DAG order, a backup mechanism, the OpenBao seal or the cluster-up flow; after each drill; at least yearly.
