# Audit sink — a second copy of the audit and security logs, outside the cluster

🇫🇷 [Version française](audit-sink.fr.md)

> Design for infra #318. **Status: designed and tested offline (mocked/static). No cloud, no cluster, no provider has run it.**
> The lab pass criteria are in section 9. It claims no compliance with any ANSSI document.

## 1. Why, and the class of the data

The Kubernetes audit log, the node logs and the network-flow logs live in the cluster they describe, so a cluster-admin attacker
(or a lost cluster) takes them with it. The maintainer's decision of 2026-10-22 puts the **audit and security logs in class A:
zero loss**. The ordinary metrics and logs stay in **class B** (bounded loss, unchanged: Loki and VictoriaMetrics as before).

Class A here means: the stream is copied, **before anything is deleted at the source**, to object storage **outside the cluster**,
with an object lock and client-side encryption, and a check says when the copy stops arriving. It is opt-in: with
`audit_sink_placement = "off"` (the default) nothing in this repository or in the apps changes.

What is in scope today: the **Kubernetes API audit log** of the control planes (the apps opt-in component `audit-log-sink`, which
sits beside `audit-log-collector`). The node (Talos service and kernel) logs and the Cilium flow logs are **not shipped by this
component yet**; section 8 says why and what is missing. The bastion logs already go to both backup stores
(`bastion-logs-pull.sh`).

## 2. Where the sink lives: a choice, with its guarantees

`audit_sink_placement` in the tfvars. The default **proposal** when you turn the sink on is `other_provider`.

| Choice | The sink is | Survives | Does not survive | Cost and effort |
|---|---|---|---|---|
| `other_provider` (proposed) | on another cloud than the cluster (a Scaleway cluster: OVH; same pairing as the backup replica store) | loss of a site or region, a provider outage, **an event on the cluster's cloud account** (suspension, stolen credentials, control-plane incident) | an event on the sink's own account; a stolen sink key pair can add objects (not remove locked ones) | a second cloud account and its keys; egress to another provider |
| `same_provider_other_region` | on the same provider, in another region | loss of a site or region | **an account-level event reaches both copies**, unless the lock is `COMPLIANCE`, which even the account owner cannot lift before it ends | cheaper, one account to protect, nothing new to learn |
| `both` | on both of the above, two independent copies | the union | the loss of both accounts at once | two shippers, double the storage |

Rules the tooling enforces (`scripts/lib/audit-sink.sh`, read by `ensure-buckets.sh`, `seed-openbao.sh` and
`backup-key-recipe.sh`, and by a `check` block of the cluster root):

- `other_provider`: the sink endpoint must not be on the cluster's own provider; refused before any bucket is created.
- `same_provider_other_region`: the endpoint must be on the cluster's provider and the region must differ from `s3_primary_region`.
- `both`: `audit_sink_endpoint` is the other provider, `audit_sink_secondary_endpoint` the same provider in another region.
- `COMPLIANCE` is refused unless `audit_sink_compliance_ack = true`: a compliance lock cannot be undone before the retention
  ends, by anyone, and the bucket cannot be emptied or deleted until then.
- `GOVERNANCE` is the default. A key that holds the bypass right can still remove a version; the sink pair is never given it.
- Outscale is accepted as a sink **only after infra #377** (dedicated key pairs were refused by the store in lab 15B); until then
  the operator's own keys would be the only ones that work there, which defeats the dedicated pair.
- COMPLIANCE was proven to be enforced on Scaleway, OVH and Outscale (lab 22, part B: delete of a version and both retention
  changes refused). That a locked bucket can be emptied once the retention ends was not proven.

## 3. The data path

```
kube-apiserver --writes--> /var/log/audit/kube/kube-apiserver.log (+ rotated files)   (Talos default policy, Metadata level)
        |  read-only hostPath, byte offsets, never the apiserver's write path
        v
audit-sink-shipper (DaemonSet, control planes only)  --restic backup --stdin-->  s3:<endpoint>/<bucket>/<prefix>/<node>/<YYYY-MM-DD>
        |                                                                          (one restic repository per node and per day)
        v
audit-sink-check (Deployment) lists the prefix every 5 minutes --> oa_audit_sink_ok, oa_audit_sink_last_object_age_seconds
```

- **Which logs, which format.** The audit file exactly as the apiserver wrote it (JSON lines, whole lines only). No parsing, no
  filtering, no rewriting: what the sink holds is what the apiserver said.
- **Batching.** Every `SHIP_INTERVAL` seconds (default 300) the shipper reads what was appended since its last acknowledged
  offset, cut at the last newline, at most `SHIP_MAX_BYTES` (default 16 MiB) per chunk. One chunk is one restic snapshot, tagged
  `oa-pos=<inode>:<from>:<to>[:eof]` and the node name. `eof` marks the last chunk of a file that the apiserver has rotated.
- **Compression and encryption.** restic: compression (repository format 2) and client-side encryption (AES-256 with
  Poly1305-AES, scrypt-derived key). The provider's own server-side encryption is on top and is not a control we assess.
- **Object keys.** One repository per node and per UTC day, `<prefix>/<node>/<YYYY-MM-DD>/`. restic names its objects by content
  (`data/`, `index/`, `snapshots/`, `keys/`, `config`), so the *date* is in the key prefix and the *sequence* is in the
  encrypted-but-listable snapshot tags, not in the object names. A reader finds a day with a prefix listing.
- **Acknowledgement before the position moves.** `restic backup` returns 0 only after the snapshot object is stored. The
  shipper keeps no local copy and no local cursor that outlives the pod: on start it reads the last `oa-pos` back from the sink
  (up to 8 days of repositories), so **the sink is the cursor**. A chunk is therefore never skipped because a pod restarted, and
  re-sent at most once (a snapshot written whose acknowledgement was lost is a duplicate range, which the verifier accepts and counts).
- **No lock file.** `--no-lock` on every write: restic would otherwise write and then delete lock objects, and the pair would need
  `DeleteObject`. With it the pair needs no delete right at all.
- **Object lock and retention.** The bucket is created with object lock and a default retention (`audit_sink_lock_mode`,
  `audit_sink_retention_days`, default 365 days), versioning on, read back from the store by `oa_protect_bucket`. A refusal by the
  provider is a hard error for this bucket, not a warning: class A.

## 4. Keys and custody

- **Repository password.** A dedicated 48-character password, generated by `seed-openbao.sh` the first time (create-only, never
  rotated by a re-run), written at `secret/audit/sink` next to the endpoint, bucket, region and the S3 pair. It is **not** the
  password of the backup repositories (`secret/backup/restic`): a compromised shipper must not open the backups.
- **Escrow.** `escrow-openbao.sh export` also encrypts it to the custodians' OpenPGP keys (`audit-sink-password.gpg`, hash in the
  receipt) when `secret/audit/sink` exists, and `verify` compares it with the live one. Same custody as the restic password and
  the same offline holders. Without the escrow, a lost OpenBao makes the sink unreadable: the sink is as readable as that copy.
- **S3 key pair.** A separate pair for the sink (`OA_AUDIT_SINK_S3_ACCESS_KEY_ID` / `..._SECRET_ACCESS_KEY`; for the second sink
  `OA_AUDIT_SINK_SECONDARY_S3_*`), created by the operator from the recipe
  (`scripts/ops/backup-key-recipe.sh <tfvars> audit-sink`). Rights: list, get, put, multipart upload only. **Withheld:** every
  delete, `DeleteObjectVersion`, versioning, lifecycle, lock and retention changes, bucket deletion, every other bucket. Without a
  dedicated pair the seed falls back to the operator's keys and says so loudly.
- **OVH has no bucket policy through its S3 API**: the key pair of an OVH user cannot be limited to one bucket, so on an OVH sink
  the "dedicated" pair still reaches the other buckets of that OVH project. Isolate it by giving the sink its own OVH project/user,
  and read the rights in the OVH API (not verified). The recipe prints this.

## 5. Failure behaviour

- **The audit path is never blocked.** The shipper only reads files. The apiserver keeps writing to its local file whatever the
  sink does: no webhook audit backend is configured, and none must be (a webhook backend in blocking mode can slow the apiserver).
- **Sink unreachable.** The shipper retries on each interval, keeps nothing extra on disk (its restic cache is an `emptyDir` capped at
  256 MiB), and keeps reading from the offset it has acknowledged. **The buffer is the apiserver's own rotated files on the node**,
  bounded by the apiserver's rotation settings, not by us. While the sink is down the lag grows.
- **Alerts** (apps `vmrule-audit-sink.yaml`): `AuditSinkDown` (the check cannot list the sink for 10 minutes), `AuditSinkStale`
  (a node's newest object is older than 20 minutes), `AuditSinkShipperUnavailable` (a control plane has no running shipper),
  `AuditSinkCheckAbsent`. A cluster whose control planes are all down cannot alert: only the heartbeat covers that.
- **Nothing lost after recovery** holds as long as the outage is shorter than the rotation window of the apiserver file. After a
  longer one, the oldest rotated file is gone: the shipper writes an explicit gap snapshot (`oa-gap=<inode>`), the verifier reports
  it, and the alert has long fired.
- **First start.** The shipper ships what it finds (rotated files first, oldest first), not only new lines: a sink that begins at
  install time begins with the history that is still on the node.

## 6. Delivery check

Two layers. In the cluster, `audit-sink-check` lists the sink prefix with the sink key pair and exports `oa_audit_sink_ok` and, per
node, `oa_audit_sink_last_object_age_seconds` (from the `LastModified` of the newest snapshot object, no decryption). That proves
delivery, not integrity. Off the cluster, `scripts/ops/audit-sink-check.sh` (operator, with the escrowed password) lists a time
window, reads the snapshot tags, checks **no gap in the sequence of ranges per node and inode**, decrypts and parses a sample, and
reads back the lock mode and the retention. Run it at least weekly, and after any outage.

## 7. Honest limits

- The password and the S3 pair are **in the cluster** (the shipper needs them to write). A cluster-admin who reaches them can
  **read** the sink and **add** objects, including forged snapshots. They cannot delete or shorten a locked version. A public-key
  design (write-only cryptography, e.g. age) would close the read side; it needs an image with that tool and the S3 client, which
  the pinned images do not have. Not done.
- The sink is a copy of what the apiserver wrote. If the control planes are compromised **before** the line is shipped, the line can
  be changed first. The window is the shipping interval (300 s by default).
- A compressed rotated file (`.gz`) is not shipped; Talos does not compress audit rotation by default. The lab reads the flags.
- Cost: storage is retention × volume (the audit log of a small cluster is of the order of tens of MiB per node and day: UNVERIFIED,
  measure it in the lab) plus the per-request price of about 3 snapshots × 288 intervals × nodes per day.
- Time: object `LastModified` is the provider's clock; the age metric trusts it and the cluster's clock for `time()`.
- Not an ANSSI compliance claim. The lock proves retention at the storage layer, not the integrity of what was written.

## 8. Not covered yet

- **Node logs.** `node_log_forwarding` sends Talos service and kernel logs over plain TCP to a receiver: there is no file with a stable
  offset to acknowledge, so the same ack-before-delete guarantee needs a receiver that writes files, run by the operator. Not built.
- **Flow logs.** Cilium's Hubble export is a rotating file per node; the shipper could read it with a different `SOURCE_GLOB`, but its
  rotation and volume are unmeasured. Not built.
- **A second shipper for the secondary sink** is the component `audit-log-sink-secondary` (apps), identical and independent.

## 9. Lab pass criteria

1. **Delivery within 10 minutes** of enabling: every control-plane node has a repository for today and a snapshot younger than
   `SHIP_INTERVAL` + 2 minutes; `oa_audit_sink_ok` is 1 and the age is below 600 s for each node.
2. **No gap over a window**: `audit-sink-check.sh` over 24 hours reports 0 gaps and 0 missing ranges per node and inode, including
   across at least one apiserver file rotation (force one by lowering the rotation size on a throwaway cluster) and one shipper pod restart.
3. **Lock read back**: the mode and the days read from the store equal the tfvars, on each sink; a version delete and a retention
   shortening with the sink pair are refused.
4. **Rights**: with the sink pair, a delete, `put-bucket-versioning` and `put-object-lock-configuration` are refused; an upload works.
5. **Decrypt**: with the escrowed password only (not the OpenBao copy), the script restores a snapshot and the lines parse as audit events.
6. **Sink outage drill** (block the sink FQDN with a throwaway policy for 40 minutes): `AuditSinkDown` fires within 15 minutes and
   `AuditSinkStale` within 25; `kubectl` keeps working (the apiserver path is not blocked; its audit file keeps growing); the shipper
   disk use stays under its cap; after unblocking, the backlog is shipped and the script reports no gap over the outage window.
7. **Rotation window**: read the apiserver's audit flags on a Talos control plane and record the maximum outage the node can absorb.
8. **Network**: a connection from the shipper to any other host than the sink is dropped; the policy denies a different bucket host.
9. **Both**: with `both`, stop one sink only: its alert fires, the other keeps receiving.
