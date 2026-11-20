# Drill plan — the first disaster-recovery drill and the first incident drill

🇫🇷 [Version française](drill-plan.fr.md)

> Plan for the 0.6.0 Scaleway lab. **Nothing here has run.** Results go to the table of [`disaster-recovery.md`](disaster-recovery.md) section 5, a row of
> [`audit-register.md`](audit-register.md) section 2, and the status of its section 3 (F-BKP-16, LOG-17). Run through the `lab-cloud` guard-rails (GO/NO-GO,
> watchdog, teardown, final check that nothing remains).

## What is already proven, and what a drill adds

The recovery chain ran four times (lab 20, lab 28B and the two 0.4.1 proof labs) and its steps have numbers. Those runs used a **development OpenBao**, a replica
store at the **same** provider in one case, inputs left on the lab host, and no pass criteria written beforehand. [`disaster-recovery.md`](disaster-recovery.md)
lists what they did not show: a production-style OpenBao restore (the quorum of recovery shares), the end-to-end sign-in to Grafana through Zitadel, a replica
at **another** provider. The incident page has never been run at all. A **drill** here means: criteria written before, inputs only from what a stranger to the
lab host would have (the escrow), a timer from the decision, and a row at the end, passed or failed.

## Order inside the lab

Install (3 control planes + 3 workers, Flux, audit sink on, OVH as the sink and the replica store) → **I1 incident drill** → **D1 recovery drill** → teardown.
I1 first: it rotates keys, so D1 then proves that the escrow follows a rotation. D1 last: it destroys the cluster.

## I1 — incident drill (mock S1: a leaked store key and a cluster-admin acting)

**Scenario.** The report: "the primary backup store's key pair was seen in a paste". The lab then plays the attacker with a lab-only key: from outside the
cluster it lists and deletes a canary object in the lab's own backup bucket (never real data), and from inside it deletes the in-cluster audit file and
the `AuditSink*` rules. The operator follows [`incident-response.md`](incident-response.md) from the top, with the timer running, writing the register row as it goes.

| # | Criterion | Pass |
|---|---|---|
| 1 | Register entry opened (section 10 fields) | within 5 min of T0 |
| 2 | Backups protected first (section 5): the leaked pair replaced with `task rotate-secret`, the store checked afterwards | within 30 min; every command works as written, or the page is corrected |
| 3 | Evidence kept (section 4) before any node is replaced | the listed files exist with their hashes |
| 4 | The attacker's actions rebuilt **from the audit sink alone**, the in-cluster audit being gone (`audit-sink-check.sh`, [`audit-sink.md`](audit-sink.md) 11.5 item 4) | the deleted object and the rule deletion appear in the restored audit lines |
| 5 | The off-cluster watcher raised on the cut of the sink and on the delete marker | within 15 min, with no in-cluster rule |
| 6 | Rotation table (section 7) run for the keys concerned; `cluster-verify` and `cluster-security` green afterwards | rc 0, and 31 of 36 or better |
| 7 | Restore point chosen and written with its reason; cause and the change that closes it | in the row |

Failures are findings: each becomes a correction to the page or an issue. The row says which criterion failed.

## D1 — recovery drill (the chain, from the escrow, from another provider)

**Inputs, from the escrow only:** the seal key, the restic password and the recovery shares, decrypted with the custodians' OpenPGP keys (two throwaway keys in the
lab: there is no real second custodian yet, `key-management.md` section 3, and the row says so). `task escrow` verify must be green beforehand.

| # | Criterion | Pass |
|---|---|---|
| 1 | `task dr-restore-plan ... --strict` before the destruction | rc 0 |
| 2 | `task backup-final` before it; a canary row written afterwards | receipt COMPLETE |
| 3 | The cluster destroyed (`cluster-down`, buckets kept), then the chain `--from replica` (OVH store), a timer from the decision | every step rc 0, or the hand step named; RTO below the 8 h target (the 0.4.1 labs: about 31 min of steps) |
| 4 | **Production-style OpenBao**: a break-glass token minted from a quorum of recovery shares, not the development share | done and timed |
| 5 | RPO: the canary rows lost | at most 15 min plus the copy (the stated worst case) |
| 6 | `iam-admin` rebuilt as documented, then **a sign-in to Grafana through Zitadel** shown by a request | the sign-in succeeds |
| 7 | `cluster-verify` and `cluster-security` | rc 0, 31 of 36 or better |
| 8 | A second, short run: `--scenario etcd` on the new cluster | API and 6 nodes back, `cluster-verify` green |

A failed step stops the chain and is resumed from the step the tool names, as in the labs; the row lists every hand step.

## Cost and risk

About 3 hours of cluster for both drills (I1 about 1.5 h, D1 chain about 1 h plus the rebuild's install). The sink and replica store need an OVH key and a dedicated OVH project
for the sink. The lab runs the sink's cut and the key rotation on the lab cluster only; the OVH buckets used are the lab's own suffix and are purged by the
standard teardown. Not drilled: a real second custodian, a provider-account loss (the replica store is another provider, the account is the same operator's), a compromise that predates the shipping window.

## After the lab

Fill the two rows (DR section 5, audit register section 2), set the two actions of the register's section 3 to done **with the rung and the criteria that failed**, correct the pages the
drill proved wrong, and open one issue per defect found (not a batch).
