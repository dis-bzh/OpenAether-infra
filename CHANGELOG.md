# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file used to document 1.0.0, 1.0.0-withdrawn and 1.1.0. Those tags and
releases were deleted from both repositories and none of them ever worked; a
changelog listing releases nobody can obtain is not a changelog. That history is
in git. 0.1.0 is the first entry describing something proven.

---

## [Unreleased]

Bug fixes, documentation corrections and safety nets after 0.3.1, for the next release (a 0.3.2 patch was prepared and abandoned: there is no 0.3.2 tag, and `git_ref` still pins
OpenAether-apps `refs/tags/0.3.1`). No new scope. Rung reached by the lines below: **mocked** (self-tests and doc checks); the infra items were not observed on a cloud. Lab 18 (Scaleway,
infra 7e367d9 / apps 75e464f, on branches) ran a nominal `cluster-up` in 9 min 07 s with `cluster-verify` at 15 passed, 0 failed; it did not exercise #293 or #360. It does not fix the two
infra issues the series set out to look at: #42 (the API unreachable for seconds during a control-plane roll) and #375 (the OVH hard-reboot window) stay open for 0.4.0, see below.
Not a compliance claim. The apps-side results (#134 partial, #143, #144) are in the OpenAether-apps CHANGELOG.


### Added (0.4.0, study LAB-B2 on blocker B2: moving existing CNPG databases from the 0.3.x spec to the 0.4.0 spec; rung: mocked, offline; evidence: a REDUCED real lab, UNVERIFIED on the full platform)
- **`task cnpg-presync PROVIDER=… [ROLE=…] [APPLY=1] [SCALE=1]`** (`scripts/ops/cnpg-presync.sh`): enables the 0.4.0 `spec.postgresql.synchronous` block on the live CloudNativePG Clusters BEFORE the apps ref moves. Selects the Clusters by the
  `openaether.io/managed` label in the platform namespaces (no name in the script; profile and `rt-*` Clusters left out). Dry run by default (exit 3 on a difference, exit 0 and silence when there is no CNPG Cluster); `APPLY=1` patches only that block,
  waits for healthy, all instances ready, `synchronous_standby_names` set and the replicas in the quorum, reloads the configuration on every instance after 120 s (R1), and at the timeout prints the break-glass steps (R2) and fails. It never deletes a pod
  and never forces. Refuses on an unhealthy Cluster, no recent Backup, a Talos or Kubernetes roll (the gate of `cluster-bootstrap-sync`, now shared as `oa_roll_gate` in `scripts/lib/pins.sh`), a pod that predates the plugin sidecar, and fewer than 3
  instances unless `SCALE=1`. `cluster-up` runs its dry run after the roll and before the identity and apps-ref steps (applied at `APPROVE=auto` or a typed "yes", else it fails naming the command). `cluster-verify` gains, for every such Cluster,
  the block, ContinuousArchiving, `synchronous_standby_names`, the replicas' `quorum`/`sync` state and the FailoverQuorum object (BAD with the command, UNKNOWN when unreadable). Tests: `test-cnpg-presync.sh`, `test-cluster-up.sh`, `test-pins-verify.sh`
  (each change mutation-checked).
- **Evidence, said plainly.** The study ran on Scaleway on a REDUCED lab: one k3s node per VM, no Flux, Talos, Cilium or zones, the real Cluster specs of 0.3.2 and the 0.4.0 branch, 20-35 commits/s per database, the recipe twice. Presync 54-57 s with no
  write gap; then the one apply of the 0.4.0 content: healthy in 95-100 s, write gap 17-22 s, 0 acknowledged commits lost, WAL archive contiguous (MISSING 0), replicas in the quorum. The 0.4.0 content applied in one go, without the presync, left a Cluster
  stuck in some runs (cloudnative-pg#11627, and an enabled plugin freezes every pod that predates the sidecar). **Not proven:** the real Flux apply, Talos, Cilium policies, three zones, production load and data, a node loss in the window, Outscale and OVH.
  `docs/upgrade.md` ("From 0.3.x to 0.4.0") has the steps, the break-glass R1/R2 and the rule: no promote or switchover while a pod predates the plugin sidecar. Not a compliance claim.

### Fixed (0.4.0, lab 26 findings F1, K1, K2, K3, C1; rung: mocked, offline, UNVERIFIED on a cluster; lab 26 reproduced each defect on Scaleway)
- **F1** `task cluster-up` ran `cluster-identity-sync.sh` and `cluster-apps-ref.sh` directly, outside the task environment, so `tofu output` stopped with "Backend initialization required" after the 41-minute roll (seen twice). It now runs the tasks (`task -x`), which carry the backend, the S3 credentials and the kubeconfig step. `test-cluster-up.sh` runs the step with no `TF_DATA_DIR` and no S3 variable against a tofu stub that refuses as the real one does (33 assertions fail without the change).
- **K1** A bare `task` reports the scripts' exit 3 ("differs") as 201. The `cluster-up` messages say so and name the exact command with `PROVIDER` and `ROLE` filled in; `docs/upgrade.md` lists the codes.
- **K2** The 0.4.0 CoreDNS HA does not reach a cluster built by an older release (Talos creates inline-manifest objects only when absent). `cluster-verify` gains "CoreDNS runs the declared replica count and spread" (BAD both ways, with the command); `scripts/ops/coredns-ha-patch.json` is the documented one-time patch; `docs/resilience.md` and `docs/upgrade.md` are corrected.
- **K3** `cluster-security` and `cluster-netcheck` export the cluster's `KUBECONFIG` to their scripts.
- **C1** After a drained `cluster-roll -- --node=` the Node object is kept, so `cluster-replaced-node-cleanup` found nothing while local-path pods crash-looped. It now names those pods, exits 1 and prints `... -- --disk-replaced`, which treats every volume pinned to the node as the old disk's with every safety rule kept; `cluster-roll` prints the command after a worker replace.

### Added (0.4.0, lab 26 findings D2 and H1; rung: mocked, default unchanged, UNVERIFIED on a cluster)
- `node_monitor_grace_period_seconds` (default 0 = Kubernetes' 50 s): the kube-controller-manager's grace period and the matching kubelet heartbeat, 20 to 300 s. Nothing changes unless it is set, and it is not to be set until a lab proves a value: `docs/resilience.md` ("Failure detection time") gives the numbers, the CNPG `primaryLease` lever on the apps side and the experiment to run.

### Fixed (0.4.0, lab 25 finding D9: new `cluster-identity` values never reached a running cluster; rung: mocked, offline, UNVERIFIED on a cluster)
- **Cause, from the code and Talos's source.** The `cluster-identity` ConfigMap (and the GitRepository and Kustomization `openaether-platform`, hence `git_ref`) are objects of the Talos inline manifest `flux-bootstrap`.
  Talos's manifest-apply controller (`release-1.14`, read through a summarising fetch, not cloned) checks each object with a `Get` and applies it only when it is not found: an object that exists is never updated. The plan's
  "3 to change" is the control-plane machine configs carrying the new manifest text; the objects on the cluster keep their old data. Lab 25 saw exactly that (4 keys kept, `cnpg` and 8 dependants NotReady, `cluster-up` rc 0
  because `cluster-verify` reads neither the ConfigMap nor the Kustomizations). Not shown: a `talosctl get manifests` read, and the same test on the GitRepository and Kustomization.
- **`task cluster-identity-sync PROVIDER=… [ROLE=…] [APPLY=1]`** (`scripts/ops/cluster-identity-sync.sh`): dry run by default, shows the keys to add or change and exits 3 on a difference; `APPLY=1` merges only the rendered keys into
  the ConfigMap, reads them back, asks Flux to reconcile, and is idempotent. It reads the new non-sensitive root output `cluster_identity`, built once in `cluster/main.tf` (`local.cluster_identity`) and used by the bootstrap
  template too, so the two cannot drift (`flux-git-verify.tftest.hcl` compares them). `cluster-up` runs the dry run after the node roll and either writes (`APPROVE=auto`, or a typed "yes") or fails naming the command; it no
  longer ends green over a ConfigMap that is not what the config renders. Tests: `test-cluster-identity-sync.sh` (kubectl and tofu stubs), `test-cluster-up.sh`, the two tofu test runs. Not run on a cluster.
- **`docs/upgrade.md` (+ FR): "From 0.3.x to 0.4.0 (an existing cluster)"**: the ordered steps, the live `git_ref` patch, the identity sync, the Barman plugin note, and what lab 25 did and did not observe. Gateway API CRDs 1.6.0 and
  Istio 1.31.3 on an existing cluster are a REBUILD ASIDE, not an in-place hop; lab 25's 5-minute in-place Istio hop is reported but is not the supported path. Every step not run is marked UNVERIFIED. Still open: the `cnpg`
  Kustomization stayed "Reconciliation in progress" 10 minutes after the keys were added by hand (not investigated); the live `git_ref` command is `task cluster-apps-ref` (see Added, infra #408).
- The apps side (OpenAether-apps `CHANGELOG.md`): the replica bucket and endpoint default to a non-empty placeholder, so a missing key no longer nulls `endpointURL` and turns the database layer NotReady.

### Added (0.4.0, infra #408: every pinned thing gets a declared pin, a converging command and a verify check; rung: mocked, offline, UNVERIFIED on a cluster)
- **Supported upgrade path, owner decision 2026-10-24:** before 1.0.0 only the previous minor to the current one (0.3.x to 0.4.0). No path from older versions is built or documented. The in-place move of the 0.3.x
  apps content (Istio, Gateway API CRDs) was observed once, in lab 25; a rebuild aside stays an option; the supported, tested path is the one the release notes name.
- **`task cluster-apps-ref`** (`scripts/ops/cluster-apps-ref.sh`): dry run shows `git_ref`, the ref the live GitRepository follows and the live `GIT_REF` (exit 3 on a difference); `APPLY=1 [REF=refs/tags/X]` rewrites
  the tfvars (diff, backup `.apps-ref-bak`), patches those two fields only (never `spec.verify`), reconciles and waits for the revision of that ref with a timeout. Validates the ref like `variables.tf`; a branch is
  warned about loudly and refused as `REF=` without `ALLOW_BRANCH=1`. `cluster-up` runs the dry run after the node roll like the identity sync and ends by saying what it did NOT change.
- **`task cluster-bootstrap-sync`** (`scripts/ops/cluster-bootstrap-sync.sh`): compares Cilium and the seven Flux controllers with the lock-checked artifacts; `APPLY=1` server-side applies `flux-install.yaml` only, refusing
  a downgrade, more than one minor, a running controller the artifact dropped, and any Talos or Kubernetes roll in progress, then waits for the rollouts and re-reads. Cilium is never applied (exit 5): rebuild aside, with
  the reasons in `docs/upgrade.md`.
- **`cluster-verify`** (`infra-verify.sh`, shared readers in `scripts/lib/pins.sh`): "Cilium run the pinned version", "Flux controllers run the pinned version" and "the GitRepository and GIT_REF both follow the declared git_ref",
  each failing in both directions (behind and ahead), UNKNOWN when unreadable. Neither pin moved between 0.3.2 and this branch, so a 0.3.x cluster is not red for them.
- **`docs/upgrade.md` (+ FR)**: "Which version lives where, and how it reaches a running cluster" (table with PROVEN / UNVERIFIED) and "Cilium and Flux on a running cluster"; a release channel (semver range over signed tags) is a 1.0 option.
- Tests: `test-cluster-apps-ref.sh`, `test-cluster-bootstrap-sync.sh`, `test-pins-verify.sh` (kubectl stubs, mutation cases), `test-cluster-up.sh`. Not run on a cluster; the Talos inline-manifest rule is still to be shown on a node.
- Gap, not built: a declared-versus-running check for CAPI child clusters (`K8S_VERSION`, `TALOS_VERSION` in OpenAether-apps `apps/clusters/*.yaml`); `check-child-clusters.py` is static.

### Changed (0.4.0: the default Talos pin goes from 1.14.2 to 1.14.4; rung: mocked, offline)
- `talos_version` defaults to v1.14.4 in the cluster and local roots. 1.14.3 and 1.14.4 are patch releases (Linux 6.18.57, containerd 2.3.7, etcd 3.7.2); the only API change that could touch us is that `TimeService/TimeCheck` is no longer open to `os:reader` and PTP device paths are validated strictly: nothing in this repository calls `talosctl time --check` or sets a PTP device. **Not shown on a cluster yet:** the image build for v1.14.4 on each provider, a fresh cluster at 1.14.4, and the roll of a 1.14.2 cluster to 1.14.4 under the customer probes are checks of the final validation lab. A cluster built at 1.14.2 keeps its pin until its owner changes `talos_version`.

### Added (0.4.0, infra #318: a second sink outside the cluster for the audit log, class A, opt-in)

- **Design and settings**: `docs/audit-sink.md` (+ FR): the choice `audit_sink_placement` = `off` (default) | `other_provider` (proposed) | `same_provider_other_region` | `both` with what each survives and does not, the data path, key custody, failure behaviour, honest limits and the lab pass criteria. Variables `audit_sink_*` (endpoint and region per sink, prefix, lock mode `governance` by default or `compliance` only with `audit_sink_compliance_ack = true`, retention days); a `check` block and `scripts/lib/audit-sink.sh` refuse a sink that is not where its choice says (not another provider, the same region) before any bucket exists. Only the host names reach `cluster-identity`, and only when the sink is on.
- **Buckets**: `ensure-buckets.sh` creates the sink bucket WITH object lock on the store of the cloud that holds it, reads the mode and retention back, and **fails** (not warns) on any refusal. `backup-key-recipe.sh <tfvars> audit-sink|audit-sink-secondary`: a pair with no delete right at all; the OVH per-bucket isolation limit is stated.
- **Keys**: `seed-openbao.sh` writes `secret/audit/sink` (and `audit/sink-secondary`), create-only: endpoint, bucket, own S3 pair (`OA_AUDIT_SINK_S3_*`, else the holding cloud's keys, said loudly) and a 48-character repository password drawn there, printed nowhere, distinct from the backups'. `escrow-openbao.sh` escrows it to the custodians and `verify` compares it with the live one.
- **Proof**: `scripts/ops/audit-sink-check.sh` reads the lock back, checks per node and inode that the shipped ranges chain with no hole, reports a loss the shipper recorded, and decrypts a sample with the escrowed password into a scratch directory. Tests: `test-audit-sink-lib.sh`, `-buckets.sh`, `-check.sh` (real restic repositories), seed and escrow cases, `audit-sink.tftest.hcl`, the flux-bootstrap render. The apps side (shipper, delivery check, alerts) is in OpenAether-apps. **Rung: mocked/static; never run against a provider's object store or a cluster.** Not a compliance claim.

### Added (0.4.0, owner rule of 2026-10-22: no acknowledged data loss)

- **Databases replicate synchronously** (OpenAether-apps: `zitadel-db` and `grafana-db`, quorum, `dataDurability: required`, failover quorum; `grafana-db` at 3 instances). The write gap stays bounded, not zero (one writer; clients mask it by retrying); what is zero is the loss of acknowledged commits. Writes block, losing nothing, when no replica streams (alert `CnpgSyncReplicaMissing`). `docs/resilience.md` (+ FR): target row and the lab pass criteria of the zero-loss proof (NOT run on a cluster).
- **Capacity, honestly**: the third `grafana-db` instance adds about 100 m of CPU requests (derived +2.5 points of a worker: 4 workers about 226-231% against 300%, still passing; the two-worker zone still short, by about 1.1-1.2 vCPU instead of 1.0). `docs/capacity.md` (+ FR) say so; `check-doc-inputs.sh` fails if a capacity page stops accounting for it and no longer quotes a stale "0.45 vCPU of margin" in its 4-worker message.

### Added (0.4.0, owner decisions of 2026-10-21: signing, release tags, capacity)

- **Signer table and signed-commit policy** (#332): `docs/signed-commits.md` (+ FR) lists the VPS release key and GitHub `web-flow` with their fingerprints and public keys under `docs/signers/`
  (machine-readable: `docs/signers/signers.txt`). Policy: every commit on `main` is signed by a table key or `web-flow`, squash merges through the web interface, Renovate included. Flux has **no
  warning mode** for `spec.verify`; the warning period is the CI signature report, and `enabled = true` (refuse) is for 1.0.0. **Open: the maintainer's own key fingerprint** (placeholder, not invented).
  Rung: documentation, nothing run on a cluster.
- **Release tags are annotated and signed** (#386): `scripts/dev/check-release-tag.sh` refuses a lightweight tag, an unsigned one, and one signed by a key outside the table; the release checklist and skill
  push the signed tag first and use `gh release create --verify-tag`; `.github/workflows/release-tag.yml` repeats the check on a tag push. Rung: mocked (`test-check-release-tag.sh`, throwaway repository and keys).
- **Capacity, said plainly** (#389): the 4-worker examples survive one worker and either single-worker zone, not the zone holding two (224% requested for 200% left). A documented "5 workers zone-HA" profile (2 + 2 + 1)
  with a commented block in the Scaleway and OVH management examples; `test-failure-domain-check.sh` covers both shapes. Rung: arithmetic on stubs, no zone loss on five workers recorded.

### Added (0.4.0, milestone M4: loss of a node, a control plane or a zone, and its rebuild)

Owner rule: the OpenTofu-built management cluster has NO node self-healing and NO node autoscaling (those stay optional modules for the Cluster API clusters); it survives a loss through
spreading, budgets and replicas (OpenAether-apps `scripts/check-ha.py`), says so loudly with alerts that name the command, and is rebuilt by an operator command. Rung: **mocked** (stub tests,
fake provider API, mocked OpenTofu tests); **UNVERIFIED on a cluster**; the drills and pass criteria are in `docs/resilience.md` (EN, FR). Not a compliance claim.

- **`task cluster-node-state`, `cluster-node-recover`, `cluster-replace-node`** (`scripts/ops/node-recovery.sh`, `node-provider.py`). `state` is read-only (provider state, kubelet, Talos port, `VERDICT=`);
  `recover` hard-reboots a machine the provider says runs but is silent (OVH ACTIVE while dead, #49, #371), refuses when the tunnels rather than the node are down, bounded wait, destroys nothing;
  `replace` runs `rolling-replace.sh --dead --node=…` (new flags `--node`, `--ip`, `--dead`): a survey of the survivors (one node down only; etcd quorum without it, else `dr-restore-plan`), cordon without
  a drain, the etcd member removed BEFORE the Node object is deleted (its pods are freed at once instead of after the 5 minute toleration), the same saved-plan applies and gates as `cluster-roll`.
  Tests: `test-node-recovery.sh` (fake repository, real listeners for the tunnels), `test-dead-node-roll.sh`, `test-node-provider.sh` (fake provider API for OVH, Scaleway, Outscale). Scaleway and
  Outscale calls are written from the API documentation and UNVERIFIED against an account. A set -e trap in the `--node` lookup was found and fixed by the tests.
- **Roll gate for the API blip of a control-plane roll (#42).** After a control plane reboots the roll waits for its kube-apiserver static pod to be Ready and `/readyz` to answer, three polls in a row,
  and refuses to take a control plane down unless every apiserver serves (`wait_apiserver_ready`, `wait_apiservers_all_ready`; `test-roll-apiserver-gate.sh`, fails without the change). Whether this
  removes the 5-8 s blip is a cloud measurement. NOT done, owner decision 2026-10-21 (keep the roll gate only): HTTPS `/readyz` load-balancer checks (needs anonymous access to the health endpoints) and `--shutdown-delay-duration`; `docs/network.md` section 9.
- **Scaleway and OVH examples ship 4 workers of 4 vCPU** (owner decision 2026-10-21; 3 + 4 = 8 instances, 30 vCPU with the bastion; Scaleway 114 GB, OVH 64 GB of RAM). Lab 21 MEASURED the full platform on 4 workers at 223-228% of one worker (about 9 vCPU), 1.2 vCPU above the derivation: on 3 workers the same load is above the 8 vCPU `cluster-roll` leaves, so 3 would be refused and `cluster-roll`'s survey on the 4-worker cluster printed `223% requested, 300% available without one worker` (test fixtures now carry the measured figures; the old 7.55/7.85 derivation is gone from the docs). Losing the zone that holds two of four workers still leaves 200% for 224% (`failure-domain-check` says so; a fifth worker made it green, 243% in 300%). Quota flags, `first-cluster`, README, `check-doc-inputs` (requires 4) updated, EN and FR. The Outscale examples stay inside the 20 vCPU quota and say so. Rung: observed on Scaleway (lab 21).
- **Lab 21 (Scaleway, 3 control planes + 4 workers, 2026-10-21) drilled M4 for the first time; rung: observed on Scaleway.** Worker, control-plane and zone power-offs, undrained reboots, `cluster-roll -- --cp-only` (17 min 34 s, apiserver gate in the log between the three control planes, longest `/readyz` run 1 s), `cluster-replace-node` of a dead worker (260 s) and of a dead control plane (335 s, etcd member removed before the Node object, etcd 3/3, 3 apiservers), `cluster-node-recover` (one hard reboot; tunnels closed on purpose: nothing rebooted; kubelet silence simulated). Table in `docs/resilience.md` ("Measured in lab 21"): no data difference in any drill, HTTP longest failed run at most 3 s, but the criteria NOT met are named there: total failed HTTP samples per node loss 8-16 (target 5), database write gap 287-333 s when DNS or the primary sat on the lost node and 59 s on a reboot (target 30 s), and `NodeUnreachable` firing 6 min after a loss. Found and fixed in OpenAether-apps (NodeScrapeDown, FailureDomainLost on the kubelet scrape, AlertmanagerClusterDegraded, zone spread of the CNPG clusters and operator). Fixed here: `cluster-replace-node` now says what a CNPG instance crash-looping on the replaced disk needs (verified: delete its PVC and pod, clone in under a minute); the docs carry the measured CPU figures and the corrected Alertmanager criterion. Open, with issues: CoreDNS placement (Talos-owned), the 5 minute database failover on a lost node, the capacity of the two-worker zone.
- **`task failure-domain-check`** (`scripts/ops/failure-domain-check.sh`, read-only): for each failure domain, would its loss stop etcd, leave too few workers or too little CPU, break the OpenBao quorum, take a
  database or a Longhorn volume, or remove the Gateway. `worker_zones` joins `control_plane_zones` in the provider contract and the root outputs, and every node now carries the label
  `topology.kubernetes.io/zone` (talos module `node_zones`, `machine.nodeLabels`, folded into the replace trigger; byte-identical when a provider reports nothing). Tests: `test-failure-domain-check.sh`,
  `control-plane-zones.tftest.hcl` (workers), `node-zones.tftest.hcl`. That a Talos node accepts the label is UNVERIFIED.
- **Docs**: new `docs/resilience.md` and `resilience.fr.md`; `upgrade.md` ("A node that is already dead"), `network.md` section 9, `capacity.md` (about 345 m of CPU requests added by the HA work, derived, about 0.45 vCPU of margin left on the shipped 3 x 4 vCPU example), EN and FR.

### Observed and fixed (lab 23, Scaleway cluster + OVH buckets, 3 control planes + 5 workers, rung: observed on a cluster)

- **Synchronous replication, zero-loss proof, observed** (OpenAether-apps does the work; the table is in `docs/resilience.md`, "Measured in lab 23"): 0 acknowledged ids lost in every synchronous run; 817 and 1409 lost in the asynchronous control with a double fault. A primary lost together with a replica is not promoted (FailoverQuorum): a write outage for its whole length.
- **Audit sink (infra #318), first run on a real cluster and a real OVH store**: delivery, GOVERNANCE lock read back, decryption from the escrow, a window of 2 h 29 min without a gap, the outage drill (`AuditSinkStale` 22 min, `AuditSinkDown` 16 min 41 s: now `for: 5m` in the apps rule), the apiserver rotation window recorded. **Measured limit on OVH**: the dedicated pair lists every bucket of the project, can write a delete marker and can change the bucket's default retention (it cannot delete or shorten a locked version): `docs/audit-sink.md` sections 4 and 10 (EN, FR). The fix of the shipper that chased the growing file is in OpenAether-apps.
- `failure-domain-check`: a cluster with no Longhorn volume says so instead of printing UNCHECKED for every zone; it also named the single-instance `light` profile as losing its data with its zone. Capacity measured: 249% with the platform alone, 294% with three database profiles (`docs/capacity.md`, EN, FR).

### Observed and fixed (lab 22, Scaleway, 3 control planes + 5 workers, rung: observed on a cluster)

- The offline changes of the lab 21 follow-up below ran on a cluster: CoreDNS on three nodes (write gap 6 s when a replica's worker is lost, was 287 s), the 30 s toleration (database write gap 44-64 s for a primary on a powered-off worker), kube-state-metrics at two replicas (`NodeUnreachable` fires with one pod killed and the other lost), the 5-worker zone-HA profile (`failure-domain-check` green at 246%; each two-worker zone powered off 10 minutes, nothing Pending for lack of CPU), the replaced-node cleanup. Numbers and what stays open (a database primary inside a lost zone: 122 s) in `docs/resilience.md`, "Measured in lab 22".
- **`replaced-node-cleanup.py --clean` deleted nothing**: it ran `kubectl delete pod NAME pvc CLAIM` (three pod names) and then blocked on `kubectl delete pv`. Now `pod/NAME pvc/CLAIM` and `--wait=false`; the offline test pinned the broken string with a fake kubectl and now fails on any untyped `pvc` argument. Observed: every replica full 61 s after the command.
- `oa_protect_bucket` no longer reports a fully locked bucket as "NOT fully protected" when the store refuses to re-enable versioning on a bucket created with object lock (Outscale: `InvalidBucketState`), as long as the read-back confirms versioning. COMPLIANCE object lock itself was tried on a throwaway bucket per provider (see `docs/backup-policy.md`).
- Capacity numbers of the 5-worker profile measured (243-247%, not the derived 230%), `docs/capacity.md` EN and FR; example comments say 245%.

### Fixed (lab 21 follow-up, offline: infra #388, apps #154; to be proven by the next lab)

Rung: **mocked/static** (`tofu test`, a rendered-manifest test, a fake `kubectl`). Not a compliance claim; the lab pass criteria are in `docs/resilience.md`.

- **CoreDNS** (#388): `coredns_ha` (default on) disables the Talos-owned Deployment (`cluster.coreDNS.disabled`) and injects an inline `coredns` manifest with the same names, labels and ClusterIP:
  `min(3, nodes)` replicas on different nodes (hard hostname spread with `minDomains`, so a replica created before the other nodes exist waits instead of sharing one), a zone preference, a budget
  allowing one disruption, 30 s tolerations, requests 150 m in all (was 200 m). `coredns_image_tag` is Renovate-tracked. `tests/coredns.tftest.hcl` and `test-coredns-manifest.sh`. What a Talos upgrade does is
  written down, with what is UNVERIFIED. A NodeLocal DNS cache was evaluated and not shipped.
- **After `cluster-replace-node`**: `scripts/ops/replaced-node-cleanup.py` lists the volumes the old disk left behind (PVs pinned to the node and older than its new Node object) and the pods stuck on them,
  and prints the `kubectl` commands; `-- --clean` runs them for a CNPG replica with a healthy primary elsewhere, an OpenBao member with a raft majority left, Loki, vmstorage and vmselect with another Ready
  replica, and refuses the rest (the primary of record, an unknown workload, a lost majority). `task cluster-replaced-node-cleanup`; `test-replaced-node-cleanup.sh` (fake `kubectl`, 21 cases).

### Fixed (0.4.0, lab 20 finding, apps #153)

- **A cluster rebuilt by `dr-restore-plan` no longer archives into the dead cluster's WAL path.** New step `generation` (after `hold`): it lists `cnpg/<cluster>/` in both stores, takes the highest archive generation plus one and writes the ConfigMap `cnpg-archive-generation` (flux-system: `CNPG_ARCHIVE_SUFFIX`, `CNPG_ARCHIVE_PREVIOUS_SUFFIX`) that
  Flux substitutes into the Clusters' `serverName` (apps: `<cluster>-g2`…; no ConfigMap, no suffix, so installs and the lab 19/20 paths do not move). `--archive-generation N` forces it. Step `dbs` waits for Flux to apply the new name before the load and its PITR recovery reads the PREVIOUS path; step `verify` takes a base
  backup of each new archive, forces `pg_switch_wal`, requires `ContinuousArchiving` True and runs `cnpg-store-replicate` once before the restore test. `docs/disaster-recovery.md` (EN, FR): the RPO and the paths after a rebuild, what is UNVERIFIED and the pass criteria of the next drill. Test: `test-dr-restore-plan.sh`
  (generation from fake stores, previous path, order, failures, no aws call with `--archive-generation`). Rung: **mocked**; **UNVERIFIED on a cluster**. The apps side is in the OpenAether-apps CHANGELOG.

### Added (0.4.0, milestone M3: restore tests and disaster recovery)

- **`task dr-restore-plan`** (`scripts/ops/dr-restore-plan.sh`): the chain of `docs/disaster-recovery.md` as one command. Dry-run by default (prints the ordered steps with this cluster's commands, the inputs each step needs and which are missing; `--strict` makes
  a missing input an error, for a readiness check before the day). `--execute --confirm <cluster_name>` runs it: restore the artifacts, `cluster-up` with Flux held, the OpenBao seal key Secret, Flux on, hold the Kustomizations outside OpenBao's closure, restore the raft snapshot
  from the chosen store, put the recovery shares back, resume, restore the databases (a scratch Cluster recovered from the ObjectStore, optionally at a point in time, then `pg_dump | pg_restore` into the empty live Cluster, or the restic dump), resume identity, verify with a restore test on the rebuilt
  cluster. A check after each step stops the chain at the first failure and names the step to resume from; a TSV report gives seconds and target per step against the 8 h RTO. `--scenario etcd` restores the newest etcd snapshot with `talosctl bootstrap --recover-from`. Secrets travel on stdin or as
  files, never in argv. Offline test `scripts/dev/test-dr-restore-plan.sh` (stateful kubectl double, stub task, restic and talosctl): dry-run runs nothing, `--execute` needs the cluster name, the order, a failing step stops the chain, no secret in argv or output.
  Rung: **mocked**. The chain has not been run on a cluster; `docs/disaster-recovery.md` (EN and FR) now states the RPO of each dataset, the RTO target, the measured pieces (lab 15A, 15c, 19) and what is not proven.
- The application restore tests (daily CNPG recovery from both stores with a canary compare, weekly point in time, the dumps loaded daily, an opt-in Longhorn canary) are in the OpenAether-apps CHANGELOG; `docs/backup-policy.md` rows follow them.

### Added (0.4.0, milestone M2: backups complete, replicated, verified)

- **Talos API access for the scheduled etcd snapshot** (`etcd_snapshot_api_access`, default true): the control planes enable `machine.features.kubernetesTalosAPIAccess` with the single role `os:etcd:backup` for the namespace `foundation-databases`,
  so the apps `etcd-snapshot` CronJob can take a snapshot without a credential on the bastion. On an existing cluster the next apply re-applies the control planes' machine configuration, one at a time; a reboot is not expected (UNVERIFIED on a
  cluster); `false` keeps the configs as they were. `tofu test` in `modules/talos/tests/talos-api-access.tftest.hcl` (off renders nothing and keeps the replace trigger; on grants only that role, only on the control planes).
- **`cluster-identity` carries `BACKUP_REPLICA_S3_BUCKET` and `BACKUP_REPLICA_S3_ENDPOINT`** (the `-backup` twin of the data bucket and the replica endpoint): the ObjectStores that read the CNPG archive copy from the replica store need them.
- **`scripts/ops/backup-key-recipe.sh`** (#368): prints, for the primary, replica or Loki pair, the rights it needs, its own bucket policy and the operator-only policy of every other bucket, with the real bucket names and no identifier; `docs/backup-policy.md`
  section 4 says how to use it (Scaleway measured, OVH and Outscale expectations, Outscale a source only while #377 stands).
- Documentation (EN and FR): the etcd snapshot and CNPG archive rows of the backup policy (the CNPG archive has no client-side encryption, stated), a deviation row in the key management page, the etcd restore from the restic repository.

### Fixed (found by lab 20, 2026-10-20)

- `dr-restore-plan` looked for the restic repositories under the bare `cluster_name` of the tfvars; they live under `CLUSTER_NAME` of the cluster-identity ConfigMap, which is `<cluster_name>-<environment>-<provider>`. Found by the dry run on a lab cluster; the test now expects the full name.
- `dr-restore-plan` kept the old cluster's kubeconfig and talosconfig after rebuilding: a cluster brought up after its state was destroyed has a new PKI, so the step `cluster` ended "the API does not answer" on a healthy, verified cluster. After each `cluster-up` the chain takes the identity OpenTofu has just written (the restored files stay as `*.old`). It also puts the recovery shares into `openbao-recovery-dev` when the fresh OpenBao is a development one.
- `dr-restore-plan` asked `kubectl get cluster`, which on a management cluster is the Cluster API `Cluster`: the step `dbs` waited 30 minutes for a database that was healthy. It names `clusters.postgresql.cnpg.io`, and the kubectl double refuses the bare name.
- `dr-restore-plan` failed the step `dbs` on `pg_restore --clean` exiting 1 for six "cannot drop inherited constraint" errors on Zitadel's partitioned cache tables, although the data had been loaded (151 tables, the canary chain intact). That one error is tolerated, any other still fails the step; the canary check follows.
- `dr-restore-plan` restored the databases with `pg_restore --no-owner` as postgres, so every table of the rebuilt Zitadel belonged to postgres and Zitadel logged "permission denied for schema queue" (145 tables of one owner, caught on a real rebuild). The restore runs `--role=<owner of the database>`; the double refuses a restore without it.
- The step `verify` of `dr-restore-plan` passed when the restore test Job only skipped (four SKIPs, exit 0). It needs a PASS line and no SKIP.
- `dr-restore-plan --scenario etcd` gave `talosctl` the talosconfig endpoint as the node: behind a bastion that is a tunnel (`127.0.0.1:52000`) and the call ended "invalid target". The node is `--control-plane-ip` (or the talosconfig's first node); the chain refuses a tunnel as the node.
- After an etcd restore the Cilium agents kept the old watch and no backend for the API Service, and about twenty controllers (Flux, CNPG, cert-manager) crash-looped until the agents were restarted; the etcd check restarts the agents and operator once the API and the nodes are back.

### Fixed

- **Documentation (EN and FR, second pass on lab 19):** `docs/backup-policy` says exactly what is not client-side encrypted: the CNPG WAL and base backups, and their copy on the replica store (same bytes, SSE-S3 requested; header read back on OVH objects in lab 19); the restic datasets are. The scheduled etcd snapshot now finds the control planes itself through the Kubernetes API (apps #150, OpenAether-apps CHANGELOG); the Talos API access feature of this repository is unchanged, and its endpoint `talos.default` is not relied on. Not proven on a cluster yet. Open: apps #149.
- **The repository settings check no longer goes red on a cancelled, unexpanded matrix run** (#293): `check-required-checks.sh` skips a check run whose name still contains a literal
  `${{` AND whose conclusion is `cancelled` (what editing a PR body while CI runs leaves behind). A successful run of that name and a cancelled plain unrequired one still fail. Three
  self-test cases, the first red without the change. Rung: mocked.
- **Documentation: finish every bastion replacement with a plan that says `No changes`** (#360), EN and FR: on Outscale the public IP link did not always come back in the same run (lab 11). The
  OVH and Scaleway equivalents are written as unchecked, and the text was not checked on OVH or Scaleway (lab 18 did not replace a bastion). No script changed.

### Not fixed, on purpose

- **#42 (API unreachable during a control-plane roll)** and **#375 (hard-reboot window behind the OVH load balancer)**: nothing safe is verifiable offline. The roll already hands etcd leadership over
  and gates on etcd 3/3; the remaining candidates (HTTPS health checks on `/readyz`, `--shutdown-delay-duration`, `externalTrafficPolicy: Local`) need a cluster and, for the first, the owner's decision on
  anonymous health endpoints. Both stay open, labelled for 0.4.0.
- **#286** looks fixed already on `main` (the harness unsets `VERSION` and has a case with a hostile `VERSION`): it is for closing after a Cléa run shows a verdict that comes from the dependency.

## [0.3.1] — 2026-10-19

0.3.1 is a **patch release** of 0.3.0: no new scope, the hotfix for the problems that block the goals of 0.4.0 (resilience and monitoring). It pairs with
OpenAether-apps 0.3.1. The `git_ref` default and the twelve `envs/*.tfvars.example` now pin OpenAether-apps `refs/tags/0.3.1` (they pinned `refs/tags/0.3.0`), so
apps 0.3.1 must be tagged first. Rung reached: **mocked** (plan-level tests), then **observed on a real cloud** for the fix below, on OVH in lab 17 (2026-10-19, one cluster, 3 control planes and 3 workers, a
reduced profile, torn down). Not a compliance claim.

### Fixed

- **OVH: the application load balancer pools get a TCP health monitor** (#375): `http` and `https` each have one (5 s delay, 3 s timeout, 2 retries), so a worker that is down
  is expected to leave the pool. **Result: PARTIAL.** Observed on OVH: after `tofu apply` both pools have the monitor and all three members are `ONLINE` (they show
  `ERROR` until the Gateway NodePorts exist, never `NO_MONITOR`; with the monitor deleted by hand they show `NO_MONITOR` again). The **failure window of a hard reboot of one worker is
  not shorter**: 23 s and 25 s with the monitor, 12 s and 23 s without it (n=2 each, curl at 1 Hz through the load balancer): the window follows the node's own downtime,
  and with a 5 s delay and 3 failed checks the member leaves the pool about as late as a quick reboot ends. The monitor helps a node that stays down, not a quick reboot. A plain drain was
  not measured. Two plan-level tests (monitors present, absent without `deploy_app_lb`). Scaleway and Outscale are untouched. `cluster-verify` does not check `NO_MONITOR` yet.

### Known limitations

- #375: the Gateway Service is `externalTrafficPolicy: Cluster`, so a drained node that is still up still answers its NodePort and the monitor cannot take it out of the pool.
- #375 improvement over a quick reboot is not shown (see above); do not rely on the monitor to shorten it.
- On OVH the first `cluster-up` again met the ACTIVE-but-unreachable fault of two nodes (#371); a provider hard reboot and a second `cluster-up` fixed it.
- The OpenBao, CNPG and Flux fixes of 0.3.1 live in OpenAether-apps; their lab results are in its CHANGELOG.
- Unchanged and still open: apps #134, #133, #124 and infra #42 (the issues list what each needs).

---

## [0.3.0] — 2026-10-19

0.3.0 is the second half of the pair with OpenAether-apps 0.3.0: a wave of **security hardening, all of it opt-in and off by default**, a larger
default system disk, and the tooling to check and operate what it adds. The infra code moves no Talos or Kubernetes version (Talos 1.14.2 and
Kubernetes 1.37.1, as in 0.2.0); the version upgrades of 0.3.0 are in the apps repository (table in its CHANGELOG).
The project follows ANSSI recommendations as far as possible. **Nothing here is a claim of compliance with any ANSSI document**: each entry
below names the requirements it addresses and the rung it reached (mocked, emulated, local Docker, or real cloud).

### Summary

- **Hardening, each option off by default:** node network filtering (`rules_only`, a per-port allow-list), node kernel/kubelet baseline and time sources,
  node log forwarding and Hubble drop logs, bastion OS baseline, named bastion operators and an SSH CA, closed bastion Internet egress, bastion log upload,
  an application load balancer source filter, dedicated key pairs and versioning for the backup stores, OpenPGP verification of the commit Flux applies,
  named short-lived Kubernetes identities, passphrase hygiene for the state, OpenBao seal-key escrow and `rotate-secret`.
- **Checks and tools:** `cluster-security`, `cluster-exposure`, `cluster-netcheck`, `rbac-review`, `s3-isolation-check`, `escrow`, `rotate-secret`,
  `bastion-harden-check`, `bastion-logs-pull`, a patch-policy signal, the end-of-life calendar, SBOM, a committed provider lock.
- **A 50 GB system disk by default** (see Changed).
- **Documentation:** a security documentation set with a French twin per page (`security-architecture`, `key-management`, `backup-policy`, `hardening`,
  `incident-response`, `threat-model`, `capacity`, `upgrade`, and others).

### Changed (behaviour of an existing setup)

- **Scaleway: the system volume of every node is 50 GB by default (`scw_root_volume_size_gb`, new variable; the 0.2.x default was 20 GB).**
  At 20 GB the full application stack left about 15.6 GB usable; lab 12 saw DiskPressure and 25 Zitadel pods evicted, lab 15c saw it after hours of
  in-place hops. A validation refuses less than 40 with `deploy_flux = true` (20 stays valid without Flux). An existing cluster gets an **in-place resize
  of its `sbs_volumes` at the next apply (no node replaced)**; Talos grows EPHEMERAL at the node's next reboot, so reboot the workers one at a time,
  drained, afterwards. Pin `scw_root_volume_size_gb = 20` in the tfvars to keep the old size (a full stack will not fit). Read the plan first:
  lab 15c moving a 0.2.1 cluster to this branch with the same tfvars planned the six root volumes 20 -> 50 GB in place and a Talos machine config change.
- **Outscale: `outscale_root_volume_size_gb` (new, default `null`)** sets the BSU root of **new** nodes only (the provider does not resize a running VM's
  volume; `ignore_changes` keeps a running node from being replaced). `null` keeps the OMI's size (about 11-12 GiB), which does not hold the platform:
  set 50, a `check` warns when `deploy_flux` is on and it is null. To grow a running cluster, replace the workers one at a time with `task cluster-roll`.
  **Raise the root IOPS too** (gp2 50 GB = 150 IOPS saturated the node in lab 15b, infra #376).
- **OVH:** the flavour's disk (`b3-8`, `c3-8`: 50 GB) is read from the account and a `check` warns below 40 GB. **Proxmox:** `root_disk_gb` default 50.
- **Scaleway: the application load balancer ACLs are standalone `scaleway_lb_acl` resources** (see Fixed). An existing cluster with
  `app_lb_allowed_cidrs` set sees them created at the next apply.
- **The example tfvars carry `deploy_flux = true` and `deploy_app_lb = true`** (Proxmox: Flux only). A file copied from 0.2.x examples without them
  built an infrastructure-only cluster; `check-doc-inputs.sh` now fails an example without them.
- **`bastion_internet_egress = closed` together with `bastion_baseline` is refused at plan time** unless `audit_logging = false` and no collector is wanted (the
  closed bastion cannot reach the package mirrors that auditd needs).
- **Cluster-up and its checkpoints:** the human checkpoints are unchanged. `APPROVE=auto` is the documented unattended path (it applies the saved plan
  files, never `-auto-approve`); without it the journey stops at three checkpoints and each says nothing was applied (`docs/first-cluster.md`, EN and FR).

**BREAKING:** none for a tfvars that sets nothing new, except the 50 GB disk default above on Scaleway (a plan that resizes volumes in place) and the
new `check`/validation on the disk with `deploy_flux`. Every hardening option defaults to the 0.2.1 behaviour; the default bastion render is byte for byte unchanged.

### Upgrade notes (from 0.2.1)

1. Read the plan: `task cluster-up` stops at it. Expect the volume resize on Scaleway; nothing else changes with unchanged tfvars.
2. After the apply, reboot the Scaleway workers one at a time, **drained** (`task cluster-roll` does it; a hand-typed `talosctl reboot` does not drain, and a worker
   that carries a CNPG instance must never be rebooted undrained, infra #358).
3. The apps side of the pair (0.3.0) moves Longhorn, CNPG, cert-manager, Kyverno, Loki and Grafana across several minors. **Do the hops in the order and
   with the pre-steps of `docs/upgrade.md` and of the apps `docs/patching.md`** (Longhorn 1.9 -> 1.10 -> 1.11 -> 1.12 with the CRD conversion pre-step; Loki chart
   procedure; Kyverno per-namespace Enforce spelling; CNPG operator hops with the switchover method). The `git_ref` default and the twelve `envs/*.tfvars.example` pin OpenAether-apps `refs/tags/0.3.0`, released first.
4. Turn on hardening options one at a time (the documents `docs/hardening.md` and `docs/security-architecture.md` list them with their rollback).
5. Provision the owner-held inputs the options need (operator public keys, SSH CA public key, OpenBao recovery PGP public keys, dedicated S3 key pairs);
   the full list of what an unattended run still needs from a person is in `docs/first-cluster.md`.

### Known limitations

None of these is hidden by a green check; each has an issue.

- **OVH S3 has no bucket policies through the S3 API** (`PutBucketPolicy` answers NotImplemented); OVH runs on the operator's keys and `s3-isolation-check` exits 2
  there. A dedicated pair needs the OVH API. Documented in `docs/backup-policy.md` (infra #379).
- **Outscale does not pass the stability criteria with the full stack (lab 16, infra #376).** On 3 CP + 3 W of 3 vCPU / 6 GB (the largest shape the 20 vCPU quota allows, 50 GB gp2 roots) a fresh
  install converged and passed the first hour; then a backup and restore, and later one drained worker reboot, started an IO and memory-pressure cascade (nodes NotReady in turn, pressure above 97%) that did
  not settle in an hour. A live change to `io1 3000` did not stop it. Probable cause (not isolated): the 6 GB nodes and the shared root disk (Longhorn, etcd and images on one volume); the examples now set the root size, but a shape that
  passes was NOT run on Outscale: it needs a larger quota (3+3 of 4 vCPU, `docs/capacity.md`). OOS also refused the EIM keys of a dedicated pair (infra #377).
- **The checkpoints of `cluster-up` stay in 0.3.0 (infra #381).** Without a terminal it stops at the phase-1 checkpoint on every run; `task bootstrap-phase2` is the way on (the messages name it now), and
  `APPROVE=auto` is the one-command path. Removing them is a later decision. Time to a working platform was 16 to 29 minutes in lab 16 (budget and phases: infra #374, 0.5.0).
- **The CPU gate of `cluster-roll` is all that is checked about losing a worker (infra #378).** Replicas with a required spread (OpenBao) stay short while a worker is out; the behaviour of losing nodes under load is 0.4.0.
- **CNPG `barmanObjectStore` is removed in CNPG 1.31** and **Kyverno `kyverno.io/v1` policies are removed in Kyverno 1.20** (apps #114, #113); 0.3.0 stays on CNPG 1.30.x and Kyverno 1.19.x.
- **The history is unsigned for now** (infra #332, #333): Flux commit verification (`flux_git_verify`) exists but cannot be switched on until a signing key is
  registered, and the GitHub rulesets do not require signatures or reviews yet. The maintainer will create a dedicated signing key later.
- **In-place hops not rehearsed:** Loki chart 6.25 -> 18 and Grafana 11 -> 13 across the major steps, Alloy, the Gateway API CRDs, Flux on the children, Cilium and
  Talos patch hops (apps #121). A fresh install lands on the new versions and was run (lab 12 onward).
- **First install on Scaleway with the app load balancer allow-list needs two applies** (the ACL plan is inconsistent until the NAT address exists, infra #361).
- **MinIO (local/dev profile) is archived upstream;** its waiver runs to 2026-12-31 (apps #104, the end-of-life calendar of the apps repository).
- **Kubernetes 1.37 is outside the range the upstream projects test** (cert-manager, CNPG, Flux and others, apps #105, #120). The labs ran on it.
- **OVH:** instances can go to ERROR at creation or stay ACTIVE but unreachable (infra #371, #362), the app LB pools have no health monitor (infra #375), and the OVH
  column of the first labs never ran (infra #366).
- **Not exercised since lab 11:** `rotate-secret --apply`, the Git break-glass, PKI revocation drill, FIDO hardware keys (infra #370); COMPLIANCE object lock is an owner decision (infra #369).
- **Day-1 steps stay manual:** `seed-openbao.sh`, the PKI signing with an offline root (human by design) and the Zitadel MFA enrolment before the first Grafana login.

### Validated on (all offline suites green on the head commit; the cloud runs are on earlier heads of this branch, the fixes found were re-run by the suites)

Real clouds, with Talos 1.14.2 / Kubernetes 1.37.1, each once, by hand or by script, **never repeated for stability**:

| Lab | Date | What |
|---|---|---|
| 11 | 2026-10-16 | Wave 2 options. Scaleway full DAG, Outscale reduced; OVH did not get past the first apply (platform no-egress, Octavia ERROR). 5 defects fixed. |
| 12 | 2026-10-17 | Fresh install at the final versions. Scaleway full DAG converged (cluster-verify 16/16, cluster-security 34/36 + 2 n/a, strict plan clean); Outscale reduced. |
| 13 | 2026-10-17 | Scaleway fresh install on the **defaults** (50 GB), bastion 37/37, isolation 10/10, RWX hang reproduced then fixed. |
| 14 | 2026-10-17 | Scaleway 3 CP + 3 W, OVH reduced: Longhorn backup/restore, CNPG restore into a new cluster, drained reboot 66 s, checksums intact. |
| 15a | 2026-10-17 | OVH complete: cluster-up 817 s, verify 16/16, security 33/36, bastion with closed egress, forward and reverse node filtering swaps, control planes replaced for real. |
| 15b | 2026-10-18 | Outscale, two full clusters (3 CP + 3 W): cluster-up 805/817 s, verify 16/16, security 33/36, bastion 38/38. |
| 15c | 2026-10-18 | Scaleway lifecycle from infra 0.2.1 + apps 0.2.0: 40 upgrade hops and drills over about 6.5 h; 20896 HTTP probe samples, 135 failed (0.65 %), one 73 s episode (a drain evicting the single Gateway pod). |
| 16 | 2026-10-18 | Final validation, from the shipped example files, unattended apart from what is named. Scaleway (3 CP + 2 W): two `cluster-up` commands (the known first-install ACL error), 54/54 Flux objects Ready 23.5 min after the start, verify 16/16, security 34/36, bastion 37/37, isolation 12/12, Longhorn backup and restore, CNPG restore into a new cluster, Kyverno enforce, TLS 1.3 with a hybrid group, drained and control-plane reboots. OVH (3 CP + 2 W, checkpointed path, 21 min of which about 13 are checkpoints): the same checks passed except the dedicated pair (not possible there). **Outscale (3 CP + 3 W of 3 vCPU / 6 GB) FAILED stability** after the first hour (see Known limitations); control-plane reboot, alert drill and final acceptance were not run there. On Scaleway and OVH `cluster-roll` refused the 2-worker shapes (172% of CPU requested): the examples now ship 3 workers, **not re-run**. |

Every lab was torn down and its provider account checked clean (`purge-orphans`, `verify-provider-clean`).

**NOT run (lab 16 added):** the break-glass and escrow drills, `rotate-secret`, Loki chunk deletion, bastion replacement, node add, and the webhook-receiver leg of the alert drill (alertmanager egress is default-deny); a roll that passes its capacity gate was not run on any cloud. Also not run: an etcd snapshot restore on a second cluster; a real node replacement through `cluster-roll` on Scaleway (printed only); the Istio hops; Alloy, Grafana,
Gateway API CRD hops; the Flux (children) and Cilium/Talos patch hops; Zitadel -> Grafana interactive login (MFA, no browser); OpenBao raft snapshot restore; dedicated key
pairs on OVH and Outscale; Loki retention expiry; FIDO keys; Proxmox; the signed-history path (no signing key yet); the cloud workflow of the CI. Nothing ran for days;
the longest run is the 6.5 h of lab 15c.

---

### Detail of the 0.3.0 entries

ANSSI hardening work, not released yet. **Nothing here is a claim of compliance with any ANSSI document**: each entry names the requirements it addresses and the rung it reached.

### Validated

- **ANSSI first wave on three real clouds, 2026-10-15: once per cloud, by hand, with the apps branch `claude/anssi-wave1` followed by Flux.**
  Infra `1de00a4`, then the fixes listed under Fixed up to `030933d` (the labs were moved to each fix as it landed). Scaleway and OVH ran the
  full DAG (36 Kustomizations), Outscale the reduced apps profile only. What was seen:
  - **Escrow and rotation, on all three clouds:** `escrow export` to two custodians, `verify` (the seal key rebuilt from the escrow alone has
    the live key's sha256, the restic password and the three recovery shares match), `attest`, then `cluster-security` 4.7 green (2 holders);
    the apps CronJob `openbao-escrow-check` read the attestation ("attested 0 day(s) ago by 2 holders", Outscale). `rotate-secret` dry run,
    `--apply` (version 1 to 2, ExternalSecrets nudged) and the refusal of `backup/restic` (OVH, Outscale).
  - **Bucket protection `versioned`:** versioning and a 60-day non-current-version expiry read back on all seven buckets of each cloud.
    `s3-isolation-check` exits 2 and says nothing is isolated when no dedicated key pair is given, as designed.
  - **App load-balancer source filter (Scaleway):** the allow (admin address, the VPC ranges, the NAT gateway) and deny ACLs are on both
    frontends (read back from the provider API). With a list that excluded the admin host, the connection was reset on 80 and 443; with the
    list restored the Gateway answered `301`. Both changes were in-place updates and the public address did not change.
  - **Read-only checks:** `cluster-exposure` (22 and 6443 only, plus 80/443 on the app LB), `cluster-netcheck` (7 of 7 denied on Scaleway and
    OVH), `cluster-security` 34 of 36 on Scaleway and OVH with the escrow check on (the 2 left are skipped checks: no MinIO, shared keys).
    `rbac-review` flagged one binding on every cluster (see Fixed).
  - **Zitadel (apps B14):** the generated 32-character administrator password opens a session (201), `Password1!` does not (400).
  - **A bastion with the baseline, named operator and closed egress (OVH, replaced three times):** the operator `alice` logs in, is in
    `bastion-admins` and has no sudo; with the corrected template the hardening check passes 35 of 35 (80, 443, another address and 8200
    refused; the cluster ports on the subnet allowed; `nc`, `curl` and `tcpdump` purged; sshd directives and kernel settings as asserted).
    Before the fixes it failed 11 and then 4 checks, for the reasons under Fixed. `cloud-init status` says `done`, extended status
    `degraded`: `sudo: false` in the user list is deprecated in cloud-init 22.2 and later, and is in the 0.2.0 render too (left, to keep the
    default render byte for byte).
  - **Strict plan "No changes" on all three clouds at the end**, which also shows that the Scaleway ACL resources do not fight their frontends.
  - **Every replacement of the OVH bastion ended the first `cluster-up` as a 15-minute cluster health check failure** (the tunnels died with
    the bastion); the second run converged each time, and the failure is now explained by `explain-failure.sh`.
  - **Not run:** object lock (governance or compliance), a dedicated key pair for Loki or the backup stores (`OA_LOKI_S3_*`,
    `OA_BACKUP_S3_*`), FIDO hardware keys, the SSH CA end to end, host-key pinning on a real bastion, closed egress on Scaleway and Outscale,
    `bastion-logs-pull` upload, the `app_lb_allowed_cidrs` filter on OVH and Outscale, Proxmox. Of the apps changes only the first wave
    was in the lab (not the OpenBao TLS 1.3 and metrics work, which is on a later branch).

### Fixed

- **The shipped Scaleway and OVH examples can lose a worker and be rolled (#378, lab 16).** With the full stack, two 4 vCPU workers carried 172% of one worker's CPU requests (Scaleway 82% + 90%, OVH
  81% + 91%) and `cluster-roll` refuses above (workers - 1) x 100%. The management and failover examples now ship 3 workers (6 instances on Scaleway, 7 on OVH, 26 vCPU on both;
  quota flags and `first-cluster.md` updated, EN and FR). `docs/capacity.md` shows the arithmetic: about 90% of the limit at 3 workers, an estimate from two measured points, not run again. Outscale cannot
  reach a rollable shape inside the 20 vCPU quota (239% on 3 x 3 vCPU against 200%): its examples say so and name the smallest shape that passes on paper (3+3 of 4 vCPU, 26 vCPU), which was not run there.
  `check-doc-inputs.sh` fails on a 2-worker example.
- **The Outscale examples set `outscale_root_volume_size_gb = 50` (#376, #364).** It was commented out although `deploy_flux = true` needs it. The root volume type is fixed to gp2 in the module (no type or IOPS
  variable) and an `io1 3000` change by hand did not stop lab 16's IO and memory cascade on 6 GB nodes, so nothing here claims the cascade is cured: the examples and `capacity.md` say what was and was not shown.

- **The no-terminal stop of `cluster-up` names the command that goes on (#381, lab 16 on OVH).** Without a terminal and without `APPROVE=auto`, `cluster-up` stops at its phase-1 checkpoint
  on every re-run, even on a plan that says "No changes"; only `task bootstrap-phase2` reaches phase 2, and no message said so (three redundant stops, about 13 of 21 minutes). The stop message now
  names `task bootstrap-phase2` after the apply (and says a "No changes" plan needs no apply), and phase 2's own stop names `task kubeconfig` and `task cluster-verify`. The checkpoints themselves are
  kept for 0.3.0 on purpose (`APPROVE=auto` stays the unattended path); `docs/first-cluster.md` already described the sequence. `test-cluster-up.sh` fails without the messages.

- **`test-kubeconfig-new.sh` runs on OpenSSL 3.0 (found by CI on the 0.3.0 pull request).** The stub signer used `openssl x509 -not_after` (OpenSSL 3.4 and later) and the test read the
  subject in the 3.4 spelling; the CI image has 3.0. The stub signs with `openssl ca -enddate` and the subject is normalised. Run on 3.0.13 (a container) and 3.5.7.

- **The node roll docs warn about an undrained reboot of a worker with a CNPG instance (infra #358).** `docs/upgrade.md` (EN, FR): drain first; the roll commands do, a hand-typed
  `talosctl reboot` does not; the recovery after one. No tooling guard was added (the roll tooling does not run that reboot).

- **`s3-isolation-check.sh` asserts HeadBucket on each dedicated pair's own bucket (infra #356, #359).** A Scaleway pair without `ObjectStorageBucketsRead` and `s3:ListBucket`
  listed and wrote, passed the check, and then got a 403 on the first call of every barman-cloud WAL archive. The check now exits 1 naming HeadBucket and the IAM set to
  add; `docs/backup-policy.md` (EN, FR) states the rule and that OVH and Outscale are not verified. Tests in `test-s3-isolation.sh`.

- **`bastion-logs-pull.sh` shows tofu's error when it cannot read the backend (infra #352).** With `OA_LOGS_UPLOAD=1` and no saved copy, a tofu that could not
  initialise its backend printed "apply the infra first", which is wrong when the infra is applied. It now prints tofu's first lines and names the way out
  (the shell that applied the infra, `OA_TOFU_DIR`, or `OA_BACKUP_TARGETS_JSON`). Test case in `test-bastion-logs-pull.sh`.

- **`bastion-harden-check.sh` says which check it skipped (infra #372).** Without a control plane address (4th argument, `OA_CP_IP`, or the tofu output, which
  needs the shell that applied the infra) check 5 is skipped as before, but the summary now lists it (`SKIPPED: 5 (...)`), and `BASTION_REQUIRE_ALL=1`
  turns it into a failure for CI or an unattended entity. Test cases added to `test-bastion-harden-check.sh`.

- **`task check-alerts` no longer calls `kube_job_failed` and the volume stats blind (infra #357).** They have no series while the platform is healthy
  (a failed Job, a CSI-mounted volume), so they are printed apart as "healthy state" and never fail `--strict`; a metric nobody produces is still
  reported. Test `scripts/dev/test-check-alert-metrics.py` (in `task test-scripts`).

- **The example tfvars set the platform switches, and the unattended path is written down (lab 15c).** The management and workload examples
  of the four providers now carry `deploy_flux = true` and `deploy_app_lb = true` (Proxmox: Flux only): an entity that copied the file got
  an infrastructure-only cluster. `check-doc-inputs.sh` fails an example without them. `docs/first-cluster.md` (EN, FR) names
  `APPROVE=auto` as the one-command unattended path (it applies the saved plan files, never `-auto-approve`), the three checkpoints
  without it, and that a harness that refuses a blind apply needs the owner's permission for that command. The approval gates themselves are
  unchanged (skipping the question for a plan that changes nothing was considered and left to the owner). #361 keeps its hint: the
  two-phase ACL needs a real Scaleway apply to prove.

Found by the labs above, each with the rung it reached after the fix (mocked tests plus the real run that found it).

- **Scaleway: the app LB ACLs are standalone `scaleway_lb_acl` resources.** With the list in the frontend's inline `acl` block a real apply
  failed ("Provider produced inconsistent final plan: `.acl[0].match[0].ip_subnet` was null, but now ..."): the allow list holds the NAT
  gateway address, unknown before apply, and a mocked provider knows it, so no test saw it. The frontends ignore their `acl` attribute.
- **`rbac-review` flagged `system:public-info-viewer`**, a binding of every cluster (anonymous read of `/healthz` and `/version`). Only that
  binding to that role is exempt now; the same name bound to another role is still flagged.
- **`seed-openbao.sh` reloads the CloudNativePG clusters.** A Secret that appears after the database pods started is not seen by the instance
  manager ("failed to get envs: cache miss", `ContinuousArchiving` False) until the Cluster is annotated `cnpg.io/reloadedAt`; seen on
  Scaleway when the seeding came 30 minutes after the pods. The annotation brought archiving back in about a minute on both clusters.
- **`bastion-harden-check.sh` on a baseline bastion.** The unprivileged operator account (no sudo, by design) cannot read the 0600 sshd
  drop-ins or `/proc/sys/fs`; the check died silently after "=== 3", counted a loopback listener (the resolver stub) as an exposed port, and
  judged sshd from a commented line of the world-readable `sshd_config`. The baseline drop-in is now 0644 (directives, no secret); the check
  judges what it cannot read from outside (it must see exactly `publickey`), ignores loopback, skips `fs.protected_regular` and, with
  `BASTION_AUDIT=0`, the log-reader checks.
- **`bastion_internet_egress = closed` with `bastion_baseline` is refused at plan time unless `audit_logging = false` and no
  `time_servers`.** The security group is closed from creation, so the first boot reaches no mirror: auditd and chrony were never installed
  and cloud-init ended in error. Closed mode now purges `nc`, `curl` and `tcpdump` offline. The documentation said first boot was unaffected;
  it is corrected (EN and FR).
- **`explain-failure.sh`** explains a replaced bastion that ends as a cluster health check failure, like the refused-port shape.
- **Bastion with the baseline: `cloud-init status` says `done`, not `degraded` (lab 11, Scaleway and Outscale).** The baseline render writes `sudo: null` for the shared and named accounts (cloud-init 22.2 deprecates `false`; `null` also means "no sudoers entry"). The render without the baseline keeps `sudo: false`, byte for byte, because a changed user data replaces the bastion on OVH and Outscale (the released hash is pinned by `test-cluster-checks.sh`). Rung: render tests; `cloud-init schema` on a real image not run here.
- **A bastion without `audit_logging` can be read and pulled (lab 11, Scaleway and Outscale; closed egress forces `audit_logging = false`).** The persistent journald drop-in, `/var/log/journal` and the `adm` / `systemd-journal` membership of the shared account need no package and moved out of the `audit_logging` conditional of the baseline cloud-init (the render without the baseline, and the audit-on render apart from comments, are unchanged). `bastion-logs-pull.sh` checks what the account can read first (a denied `journalctl` used to read as "nothing new"), refuses with the reason when it is outside both groups, and skips the audit tarball with a message when `/var/log/audit` is absent (exit 0; it used to end `tar: Cannot open`, rc 2, nothing written). `bastion-harden-check.sh` with `BASTION_AUDIT=0` now skips only auditd and still asserts the journal, groups and login line; `BASTION_AUDIT=0` is documented in `docs/admin-access.md`. Rung: render tests and stub harnesses; a bastion built before this keeps the old template until it is replaced.
- **`task cluster-verify` can be green on a `deploy_flux = true` cluster (lab 11, Scaleway and Outscale).** The floor checks followed the infra-only default whatever the config said, so a seeded full-DAG cluster always ended `14 passed, 2 failed` ("flux-system exists", "an application load balancer exists and is billed"), with a message that called the first red "expected until the Day-1 seeding" (it is not). `infra-verify.sh` now reads `deploy_flux`, `deploy_app_lb` and `flux_namespace` (`TF_VAR_*`, else the env file; anything but `true` is false): asked for, Flux must exist with every controller Available and the balancer must be in the state; not asked for, Flux or a balancer still FAILS, with a message that names the variable. `.receipts/` is git-ignored, so the red run's receipt never dirtied the worktree; a green run now records rc 0. Rung: stub harness (`test-cluster-checks.sh`), not run on a cluster.
- **`bastion-fingerprints.sh` no longer says "apply the infra first" when it simply cannot read the backend (lab 11).** tofu's stderr was thrown away (`2>/dev/null || echo null`). It now keeps it: a state that cannot be read prints tofu's own last lines and the way out (the backend credentials and `TF_DATA_DIR` of the cluster exported, or `-f keys.json`); only a missing or null output says to apply the infra. Rung: stub tofu in `test-bastion-fingerprints.sh`. `bastion-logs-pull.sh` has the same pattern for `backup_targets` (unchanged here).
- **`etcd-snapshot-cron.sh`: a run that loses the lock no longer closes the winner's tunnels (lab 11).** The EXIT trap that closes the tunnels and prints "complete" was armed before the `flock`, so a second run (a cron run during a manual one) ended by closing the first run's tunnels and announcing a snapshot it never took. The cleanup trap is armed after the lock is acquired; before it, a trap only reports an early failure. New `test-etcd-snapshot-cron.sh` runs two real processes against one lock (stub `task`, tunnels and tools). Rung: stub harness.
- **Closed bastion egress also purges `wget` (lab 11).** The Ubuntu image ships it and the offline purge list (`curl`, `netcat`, `tcpdump`) left a downloader on a bastion whose point is that nothing leaves it. The closed render purges it too, and `bastion-harden-check.sh` (closed) now fails when `wget` is still there. Other tools on the image that can open a connection (`python3` and bash's `/dev/tcp`, which the check itself uses, `openssl`, the `ssh`/`scp`/`sftp` client) are not purged: they are needed by cloud-init, the checks or access, and a firewall in the VM is what closes the egress. Rung: render and stub tests; the purge itself was not run on a real image.
- **`cluster-security` 4.7: `OA_ESCROW_ANNOTATION_CHECK=1` alone is skipped on purpose, and now says so (lab 11).** The seal-key escrow record is required on `prod` only (the existing test "a dev cluster is skipped" is that intent), so the opt-in needs `ENVIRONMENT=prod` (`OA_ENVIRONMENT`) too. The skip used to read "strict only with OA_ENVIRONMENT=prod", which looked like an ignored opt-in; it now names both switches, the environment it saw (`unset` included) and the command. The header of the script and the task description say "both". Behaviour unchanged. Rung: stub harness.
- **`cluster-up` explains a failure of its second phase too (lab 11, OVH).** `bootstrap-phase2` failed with "Error bootstrapping node ... time is not in sync yet" and printed no hint, although `explain-failure.sh` knows the OVH router-without-egress shape: only `infra-apply` and `infra-plan` were wired to it. Phase 2 now drops the transcript first, tees its plan and apply into `.tofu-run.log` under `pipefail`, and defers to the explainer on failure; `test-explain-failure.sh` pins the wiring (it also checks that every deferring task tees). `grow-nodes.sh` runs tofu too but keeps its own tail-on-failure log, and `converge-versions.sh` runs none. Rung: Taskfile wiring tests and the real go-task harness (`test-cluster-up.sh`); not run on a cluster.

### Security

- **Review fixes of the first and second ANSSI waves (infra review of B10-B30). Static / mocked, not run on a cluster.**
  - `check-commit-signatures.sh` skips merge commits: on a PR run HEAD is GitHub's unsigned synthetic merge commit, so the documented `--strict`
    switch-on would have failed every PR. Its test now has a merge-commit case and expired-key/signature cases (status X/Y, throwaway key signed in the past).
  - `docs/signed-commits.md` (+ `.fr.md`) and the `flux_git_verify` comment no longer say Flux checks OpenPGP only: the vendored Flux also takes
    SSH keys (`.sshpub`). OpenPGP is this repository's choice, and SSH keys are NOT wired (the validation and the Secret take armored OpenPGP keys).
  - `kubeconfig-new.sh` no longer needs GNU `realpath -m`, `base64 -w0` or `date -d` (macOS operators); its test now checks that the temporary directory
    holding the private key is removed. The tests still run on Linux only, so the macOS path is untested.
  - `rotate-secret.sh --restart` waits only for the ExternalSecrets that read the rotated path, not every ExternalSecret of the cluster.
  - `task render-manifests` renders the dropped-flow Cilium variant too and `task render-check` runs the effective-config check on it (a Cilium bump no
    longer leaves the lock with the old variant hash).
  - The pid and lock files of `etcd-snapshot-cron.sh` and `local-admin-portforward.sh` live in `~/.cache/openaether` only (cron has no runtime dir, an
    SSH session has one: two lock files let a cron run and a manual run overlap).
  - `escrow-openbao.sh attest` refuses `--holders` above the receipt's recipients; the https-only Keystone guard is now tested in all five scripts.
  - Wording: `node_log_forwarding` is global (one apply re-applies every node; there is no "one node first"); the 192-bit passphrase threshold is 33, not 40;
    the Proxmox and Scaleway examples no longer offer `restrict_inter_node`, the Outscale one gained the `flux_git_verify` block.
  - It does NOT: add SSH signature support, a per-node switch for the log forwarding or the node baseline, or run anything on a cluster.

- **Critic follow-ups and the ops scripts that hold provider admin keys (B28, infra half). Static / mocked, not run on a cloud.**
  - `CKV_OA_3` (new Checkov custom check): an Outscale inbound `outscale_security_group_rule` with a literal `/0` range fails the hard gate.
    CKV_OA_2 cannot cover Outscale (no default-policy attribute), so such a rule used to pass unseen. Tested by mutating the real tree
    (`test-checkov-custom-checks.sh`). It reads literals only: a range coming from `admin_ip` is not judged, and Proxmox is still uncovered.
  - The five OpenStack-facing ops scripts (`purge-orphans/ovh.py`, `verify-provider-clean.py`, `delete-openstack-resource.py`, `ensure-capo-fip.py`,
    `preflight-quotas.py`) refuse an `OS_AUTH_URL` that is not `https://` (exit 2, nothing sent): the Keystone request carries the account password.
  - `local-admin-portforward.sh` and `etcd-snapshot-cron.sh` keep their pid and lock files under `~/.cache/openaether` (mode 0700; first written with `$XDG_RUNTIME_DIR` as an option, then fixed, see the review entry below)
    instead of a fixed name in `/tmp`, where another local user could plant a symlink (the lock redirection) or a pid list (`--stop` kills what it lists).
  - `disk_encryption_passphrase_length` (default 32, the released value, about 190 bits): 33 or more reaches the 192 bits the critic measured against
    PG-083's symmetric key size. For a NEW cluster only; on a live one it would replace the LUKS passphrase. Does not re-key an existing cluster.
  - Corrected a documentation defect: `docs/admin-access.md` told operators to forward `-L 8443:<gateway>:443`, which the bastion's `PermitOpen` refuses.
    The page now says so instead of promising a path that was never run. It does not open 443.

- **`flux_git_verify`: opt-in OpenPGP verification of the commit Flux applies, and a signature report in CI (default off; ANSSI SSDLC-CICD-AIP-03, SSDLC-CONT-REC06, B27).**
  `flux_git_verify = {enabled, public_keys}` makes the bootstrap manifest carry the Secret `git-signers` before the GitRepository and
  `spec.verify {mode: HEAD, secretRef: git-signers}` on it; off, the render is byte-identical (asserted). Validation refuses an empty
  key list, a non-armored or private key and a duplicate. `check-commit-signatures.sh` reports unsigned commits of a PR as a warning
  (`--strict` fails); CODEOWNERS names `.github/` and the bootstrap manifests; `docs/signed-commits.md` (+ `.fr.md`) holds the standard
  and the break-glass. Rung: mocked/static (`tofu test`, throwaway-key script test), not run on a cluster. It does NOT change any
  GitHub ruleset, check fingerprints, verify tags, or make the apps side carry the block (its component `git-verify` must be used too).

- **Named, short-lived Kubernetes identities through the CSR API, and an RBAC review that knows them (addresses ANSSI PA-022 R38/R40, PG-078 R15, NSA-12 AUTH-02/AUTH-03; audit B26, infra half: F04, F13, F20).** Rung: **mocked/static (`test-kubeconfig-new.sh` with a stub kubectl and the real openssl, `test-rbac-review.sh`, `test-security-tests-checks.sh`), not run on a cluster.**
  - `scripts/ops/kubeconfig-new.sh` and `task kubeconfig-new` (new, additive: nothing existing changes): files a CertificateSigningRequest (`kubernetes.io/kube-apiserver-client`, `expirationSeconds`, default 8 h, 10 min to 24 h accepted) for `CN=<name>`, `O=oa:readers` (default) or `O=oa:admins` (`ACCESS=admin`), using the `system:masters` kubeconfig only to file and approve it; key generated locally; request deleted afterwards; 0600 file outside the repository (a path inside it is refused); a signer that grants more than asked is refused. The groups mean nothing without the apps `platform-rbac` brick.
  - `rbac-review` and `cluster-security` 3.7 allow exactly the brick's two bindings (`oa-admins`: Group `oa:admins` to `cluster-admin`; `oa-readers`: Group `oa:readers` to `view`, cluster scope) and nothing else under those names (an extra subject, another group, another role or a RoleBinding is still flagged).
  - It does NOT: add OIDC or MFA (`apiserver_oidc` is not implemented: it needs a stable external issuer and can lock out the control plane, see the issue list of the batch), ship the apiserver audit log, revoke a single holder of a group before expiry (delete the group binding, or bind the user by name), remove or shorten the `system:masters` kubeconfig, or make anything compliant.

- **Node network filtering, explicit, a per-port allow-list, both off by default (addresses ANSSI PA-022 R16/R17/R19/R20; audit B24 OSN/F13 and ADM/F07).** Rung: **mocked/static (`tofu test`, `test-flow-matrix.sh`), not run on a cluster**.
  - One port list: the Scaleway `node_inbound_ports` map moved unchanged to `modules/providers/_shared/node-ports`, a locals-only module that Scaleway, OVH, Outscale and the Talos module all read, so the layers cannot drift. `tests/node-firewall.tftest.hcl` pins the four against it.
  - `restrict_inter_node` (new, default `false`, OVH and Outscale): `true` replaces the all-protocol `inter_node` rule and the `wireguard` rule (which named 51820 while Cilium listens on 51871) by one rule per entry of the list, members only, no DHCP. The two rules gained a `count` with `moved` blocks, so a default plan shows no change. The swap is not atomic.
  - `node_firewall_mode` (new, default `"off"`, byte-identical configs) with `node_firewall` (source CIDRs; `node_cidrs` required): `"port_allowlist"` (first named `rules_only`, renamed before any release because it promised a rule that drops nothing) appends a `NetworkDefaultActionConfig` with `ingress: accept` and one `NetworkRuleConfig` per flow, sources by subnet (nodes, bastion, pods, LB range), and changes `machine_config_version` so existing nodes receive the documents (config apply, no reboot expected).
  - It is NOT inert (lab 11, live nftables on Outscale nodes): a `NetworkRuleConfig` is an allow-list for its port even beside a default action of `accept`, so each listed port drops every source outside its listed subnets, ports that are not listed stay open, and a source missing from a list breaks the cluster. The sources per rule are in `docs/network.md` section 6; `etcd` is split so that the metrics port 2381 also admits the pod range (vmagent scrapes it from a pod). A rule with no source at all is refused at plan.
  - It does NOT: have a blocking default action (no such mode exists), filter Scaleway's private network, narrow etcd/kubelet to control planes, cover Talos services while Cilium is down (no Cilium host firewall), filter egress, or change `k8s_lb_mode`. Where a load balancer's health checks come from is unconfirmed per provider (listed in `docs/network.md`). `docs/network.md` section 5 and 6 and `LAB-CHECKLIST` B24 say what a cluster must show first.

- **Node logs and network-policy drops can leave the node, opt-in and off by default (addresses ANSSI PA-012 R2/R9, HYG-42 M36, BP-028 R71; audit B22, infra half).** Rung: **mocked/static, not run on a cluster.**
  - `node_log_forwarding` (new, default `null`): Talos service logs (`machine.logging`, `json_lines`) and, unless `kernel = false`, the kernel log (a `KmsgLogConfig`) sent over TCP to `endpoint`. TCP only (a UDP endpoint is refused at plan); the transport is **plaintext**, so private network only, and the receiver must be reachable from the host network (a ClusterIP is not, under `socketLB.hostNamespaceOnly`): a `hostNetwork` receiver on every node, or a fixed LB address. A hash of the settings is in `machine_config_version`, so an existing cluster actually receives them; unset, the machine configs and that trigger are byte-identical (tested).
  - `cilium_hubble_drop_log` (new, default `false`) boots Cilium from the new committed `cilium-hubble-drops.yaml`: the Hubble server only (no relay, no UI, no TLS material, **no TCP listener**), exporting only DROPPED/ERROR flows, field-masked (no payload), to the agent's stdout, where the existing pod-log collector reads it. `render-bootstrap-manifests.sh --hubble-drops` renders it, `--check` and `upstream-artifacts.lock` cover it, `check-cilium-effective-config.py` refuses a widened export. `cilium.yaml` is unchanged byte for byte.
  - It does NOT: ship anything by itself (the receiver and the Loki side live in OpenAether-apps), change the kube-apiserver audit policy (Talos's default Metadata policy stays; the file is collected by the apps opt-in collector), add a second sink outside the cluster, or touch the bastion. The `hubble-peer` Service and a declared (not listening) `hostPort` 4244 come with the chart.

- **Node kernel/kubelet baseline and node time sources, opt-in and off by default (addresses ANSSI BP-028 R9/R12/R13, PA-012 R5; audit B23, infra half: F18, F03, F19, F10, LOG-09, TLS-11, F14).** Rung: **mocked/static (`tofu test`, 63 runs in the talos module when written, 71 after B24/B28), not run on a cluster.**
  - `node_baseline` (new, default `null`): `sysctls` writes `machine.sysctls` on every node (`kernel.sysrq=0`, perf sampling limits, no ICMP/secure redirects or source routing in IPv4 and IPv6, `tcp_syncookies=1`, `tcp_rfc1337=1`), `sysctls_extra` adds or overrides, `panic_on_oops` is its own switch (a panic with a zero panic timeout hangs the node); `worker_default_seccomp` gives the workers the RuntimeDefault seccomp default the control planes already had; `pod_pids_limit` sets the kubelet `podPidsLimit`; `kubelet_server_tls` sets `serverTLSBootstrap`. A hash is in `machine_config_version`; unset (or all-default), configs and that trigger are byte-identical (tested).
  - `node_time_servers` (new, default `[]`): several NTP sources as `ntp.servers`, merged with the encrypted-DNS `bootTimeout` into the one `TimeSyncConfig` document. The bastion half already exists (`bastion_baseline.time_servers`).
  - `docs/hardening.md` (EN/FR): the sysctl deviation table (`ip_forward`, `rp_filter`, `pid_max`, `modules_disabled`, IPv6 kept) and a decision note on SELinux, sandboxed runtimes and `hostUsers`.
  - It does NOT: enable SELinux enforcing or mitigation kernel arguments (decision note; schematic change, not run), ship a kubelet-serving CSR approver (so `kubelet_server_tls` must stay off until the apps side has one; the `insecureSkipVerify` scrapes, Postgres `sslmode`, Istio TLS floor, LimitRange/ResourceQuota and the clock-skew alert are apps work), add NTS (Talos has none), or set `rp_filter`/`ip_forward`/`pid_max`.

- **Bastion OS baseline, opt-in: sysctl, auditd, journald, sshd directives, mounts, root-owned `authorized_keys.d`, in-VM nftables logging, key-type validation (ANSSI BP-028 R9/R11/R12/R14/R28/R29/R36/R38/R58/R73, NT-007 R14/R15/R23/R24/R26, NT-006 R3/R6, NT-SSH R8/R10; addresses the audit's F16, F04, F05, F07, F09, F03, TLS-15 and LOG-08).**
  New variable `bastion_baseline` (`enabled` default **false**; `audit_logging` default true; `restrict_ssh_source`, `time_servers`, `revoked_keys` default off/empty). With it off the cloud-init is **byte for byte
  what 0.1.0 shipped** (`test-cluster-checks.sh` pins the hash, now with the two extra template inputs), so no deployed bastion changes. **Turning `enabled` on changes `user_data`, which
  REPLACES the bastion on OVH and Outscale** (new IP, new host key, the Talos tunnels die with it; the plan decides on Scaleway and Proxmox): apply it on a fresh cluster or in a planned window with a second session
  open, never during a bootstrap or an upgrade, and read the plan first. `restrict_ssh_source` and `revoked_keys` put `admin_ip` / the revoked keys into `user_data`, so changing them replaces the bastion too.
  On: a sysctl file (R9 minus modules_disabled, R11, R12 minus the ARP options, R14), auditd with execve/`/etc`/mount/module/ptrace rules and **no `-e 2`**, a persistent journald capped at 200 MB / 90 days, a second sshd drop-in
  (`LogLevel VERBOSE`, `StrictModes`, `PermitUserEnvironment no`, `AllowStreamLocalForwarding no`, `GatewayPorts no`, `RevokedKeys`) that the runcmd deletes again if `sshd -t` rejects it, `AcceptEnv` commented out of the main file with a
  copy kept, `authorized_keys.d/<user>` root:root 0644, `/var/tmp` tmpfs noexec, `/boot` 700, umask 0077, sudo 4750 root:sudo, snapd/ModemManager masked, no tcpdump/netcat on new VMs, chrony on `time_servers`, and nftables
  rate-limited `nft-drop-in/out` log rules and ICMP in limited to echo-request and fragmentation-needed. Not changed: port 22, the user, the keys, `AllowTcpForwarding`/`PermitOpen`, the egress rules, `talos-tunnels.sh`.
  Always on (no resource changes): `bastion_ssh_keys` refuses `ssh-dss`, unknown types, a line break inside an entry and an `ssh-rsa` under `bastion_ssh_rsa_min_bits` (default 2048 so a deployed key keeps planning; 3072 selectable),
  checked on the type token (options prefixes and the truncated fixtures still pass). New: `scripts/ops/bastion-logs-pull.sh` (journal since a cursor + audit log off the VM, gpg-encrypted with `OA_LOGS_PASSPHRASE`; the upload came with the logs entry below),
  `bastion-harden-check.sh` probes with `/dev/tcp` instead of `nc` and gains section 9 (`BASTION_BASELINE=1`), and `task bastion-baseline-check`.
  Rung: **local Docker for the rendered files only** - `bastion-baseline-check.sh` runs the exact bytes on Ubuntu 22.04 and 24.04 (sshd -t, a real key login, the fingerprint in the login line, tunnels through `PermitOpen`, a revoked key refused,
  the guard removing a broken drop-in, `nft -c` and the ruleset loaded in a container network namespace accepting 22 from the admin source only, sysctl names in `/proc/sys`, audit rules parsed by libaudit, sudo mode, umask), `cloud-init schema`,
  `tofu test` for the input rules, stub harnesses for the two scripts. **Nothing booted a cloud image**: not proven are cloud-init ordering on a real first boot, auditd loading the rules in a real kernel, `journalctl` match syntax of the pull script,
  chrony taking the source file, `rp_filter=1` on a Scaleway bastion with its private NIC, that a provider keeps the admin source address, and the unattended-upgrades interaction (statoverride, masked units).
  Measured on the way: OpenSSH 8.9 already refuses unix-socket forwarding while `PermitOpen` is set, so `AllowStreamLocalForwarding no` is defence in depth, and the `Accepted publickey ... SHA256:` line already carries the fingerprint at the default log level (what `LogLevel VERBOSE` adds is the `authorized_keys` line number of the key and the session start/close).
  **Not done**: `restrict,port-forwarding` key options (they would change the interactive login path; `bastion-harden-check.sh` would need rewriting first), removing the `sudo` group from the login user (done below, with the baseline on),
  client-side `Ciphers`/`KexAlgorithms` in `talos-tunnels.sh`, `ListenAddress`, a cloud audit-trail export (documented as a manual procedure below, not automated), and the documented Grafana tunnel `-L ...:443` that `PermitOpen` refuses (a documentation defect in `docs/admin-access.md`, untouched).
  Also: the Feint lane renders the same template and now passes the two new inputs with the baseline off; `task test-scripts` runs the three 0.2.0 ops harnesses (netcheck, exposure scan, RBAC review) that `task lint`'s reachability check found unwired.

- **Bastion identity: named operators, the SSH CA from the root, a plan-time hardware-key check, `SSH_USER`, and a host key that is kept and checked (ANSSI NT-SSH R6/R21/R30, NT-007 R6, PA-022 R21/R30, HYG-M8; audit ADM/F05, TLS-13, TLS-16, OSN/F10, NET/F16).**
  New `bastion_admins` (map of account name to `{ ssh_keys }`, default **{}**): each entry is one more unix account in `bastion-admins` (no sudo, no password) with its own `authorized_keys.d/<name>`; with a CA configured
  it also gets a principals file holding its own name, so a certificate cannot be used as another person. `ssh_keys = []` makes a certificate-only account. `bastion_ssh_keys` and the shared account are unchanged (automation, `auto_tunnels`,
  break-glass). `bastion_ssh_ca_public_key` and `bastion_ssh_ca_principals` are now variables of the cluster root (the modules always had them; the root never passed them), validated so a quote or a line break cannot reach the
  YAML. `bastion_require_hardware_key` (default false) refuses at plan any key in `bastion_admins` that is not `sk-ssh-ed25519@openssh.com` / `sk-ecdsa-sha2-nistp256@openssh.com`; it does **not** cover `bastion_ssh_keys` and
  cannot see what a CA signs. `talos-tunnels.sh` reads `SSH_USER` (the state's `bastion_user` stays the shared account; the single-apply tunnels keep it). New output `bastion_access_keys` and
  `scripts/ops/bastion-fingerprints.sh` (account, SHA256 fingerprint, type, comment; `--find`) to map the fingerprint in a login line to a person. With the baseline on, the bastion user also leaves the `sudo` group.
  Host key: new `scripts/lib/bastion-hostkey.sh`; with `OA_BASTION_PIN_HOSTKEY=1` the first key seen is accepted once (fingerprint printed, flagged unverified), kept in `.talos-bastion-known-hosts` after a successful login and
  required from then on; `=verify` refuses a first contact unless `OA_BASTION_HOSTKEY_FP=SHA256:...` matches; a different key on a pinned address is refused until `OA_BASTION_FORGET=1` with the new fingerprint.
  `bastion-harden-check.sh` no longer uses `StrictHostKeyChecking=no` (pinned file when it holds the bastion, else a private file, fingerprint printed, `OA_BASTION_HOSTKEY_FP` checked) and `bastion-logs-pull.sh` takes
  the pinned file when it holds the bastion. **Everything is off by default**: with the defaults the rendered cloud-init is byte for byte the previous one (hash in `test-cluster-checks.sh`, now also asserting the new inputs render nothing);
  the scripts behave as before without the variable. Setting `bastion_admins` or the CA changes `user_data` (replaces the bastion on OVH and Outscale; ignored by a running instance elsewhere): plan window, never during a bootstrap.
  Rung: **mocked and local Docker**. `tofu test` (25 cases: names, keys, hardware, CA, egress inputs), stub harnesses (`test-talos-tunnels.sh` pinning, first contact, changed key, forget, verify, `SSH_USER`, `open-direct`;
  `test-bastion-harden-check.sh`; `test-bastion-fingerprints.sh`) and the new `task bastion-identity-check` (`scripts/dev/bastion-identity-check.sh`, Ubuntu 22.04 and 24.04): a real sshd takes each person's key for that account only,
  names the person and key in the login line, accepts an 8 h certificate for the matching principal only, refuses an expired one, refuses a key in `RevokedKeys` (and, measured, every certificate for that key) while the others log in.
  **Not proven**: any cloud image, cloud-init ordering on a first boot, a FIDO token (no `sk` login, no `verify-required`), that each provider shows the host key in a console log, that a plan on a running cluster is empty.
  **Not done**: a host certificate signed by the CA (no first-contact step), injecting host keys (deliberately refused: they would live in the state), operating the CA (it stays offline or in OpenBao, outside this repository),
  an OIDC login, session recording, and moving `bastion_image_id` to Ubuntu 24.04 with the hybrid `sntrup761x25519` KEX (TLS-01/TLS-19: it replaces the bastion on a running cluster and OpenSSH 8.9 on 22.04 does not know that KEX).

- **Bastion Internet egress can be closed, opt-in `bastion_internet_egress` (ANSSI PA-022 R10/R19, HYG-M27, NT-006 R2; audit ADM/F06, OSN/F14, SCC/F18, NET/F04).**
  `mode = "closed"` (default `"legacy"`: nothing changes) removes 80/443 to any address from the bastion's nftables and from the security group on Scaleway, OVH and Outscale; replaces the Scaleway "ANY to 172.16.0.0/12" and
  the OVH "every protocol to 10.0.0.0/24" rules by TCP 6443 and 50000 to the subnet the network really has (Scaleway: `scw_subnet_in_use`, which follows an adopted network; OVH: the subnet resource's CIDR; Outscale: the Net);
  limits outbound ICMP to that subnet; drops 8200 from the firewall and from `PermitOpen` (grep: no script or document in this repository or in OpenAether-apps forwards 8200 through the bastion); keeps the metadata
  addresses reachable on port 80 (a security group applies to them on OpenStack); and installs neither `curl`, `netcat`, `tcpdump` nor `unattended-upgrades` and switches the apt timers off, since no mirror is reachable: **a closed
  bastion is patched by replacing it** (`docs/admin-access.md` gives the `-replace` addresses). `dns_servers` / `ntp_servers` (addresses only) pin DNS and NTP in the VM's firewall (IPv4 and IPv6) and, IPv4, in the security group;
  empty keeps them open. The OVH and Outscale rule resources gain `count` / `for_each` with `moved` blocks, so a cluster that never sets the variable plans no change (tests pin the legacy rule lists, in order for Scaleway,
  where the provider compares a list). With the baseline on, the bastion user also leaves the `sudo` group. `bastion-harden-check.sh` no longer expects port 80 blocked (the shipped rules never did): it checks an arbitrary port in
  legacy, and with `BASTION_EGRESS=closed` 80, 443, another public address and 8200 refused, no tools, timers off. Rung: **mocked and local Docker**: `tofu test` on the security-group rules of the three providers (legacy and
  closed, pinned servers), a render test of the template, and `task bastion-identity-check`, which loads the closed and the legacy ruleset in a container's network namespace and shows 80, 443 and 8200 dropped and 6443 and
  50000 kept only when closed. **Not proven**: a closed bastion on a real cloud (first boot, the Scaleway private-NIC route fix, DHCP renewals and the metadata address under the new rules, the Scaleway metadata address
  `169.254.42.42` is from memory), tunnels to control planes, workers and the VIP, a plan on a running cluster. **Not done**: an ephemeral jump host or a baked-image replacement schedule (S13.6), disk encryption of the
  bastion (it holds no secret at rest; the exception is not argued in a separate document), a provider mirror allowlist (not possible by name in nftables), and a changed default.

- **Bastion logs off the VM: upload with a watermark, a fingerprint-to-person table (ANSSI PA-012 R2/R9/R14, HYG-42 M8; audit LOG-08).**
  `bastion-logs-pull.sh` with `OA_LOGS_UPLOAD=1` stores the encrypted journal and audit archives in the artifacts bucket of both object stores under `backups/bastion-logs/` (SSE on top, the credentials of
  `etcd-snapshot.sh`), refuses to upload anything in clear, keeps a per-store marker so a failed store is retried and nothing is re-sent, and keeps the journal cursor in the bucket too (moved only when both stores hold
  everything), so a pull from another machine resumes. `docs/admin-access.md` documents reading a file back, the fingerprint table, and the cloud audit trails (Scaleway Audit Trail, OVH Activity logs, Outscale API logs,
  Proxmox syslog) as a **manual** export. Rung: **mocked** (stub `ssh` and `aws`: both stores, per-store credentials, a store down then retried, a fresh directory resuming from the bucket cursor, the clear-text refusal);
  restoring and reading goes through `systemd-journal-remote`, shown on a hand-built export in a container, not on a real `journalctl -o export`. **Not run against a real bucket.** The logs on the VM are still not
  tamper-proof between two pulls, and nothing schedules the pull.

- **Ops verification tooling: encryption at rest read back, an exposure scan, a behavioural network check, an RBAC review (ANSSI HYG M37/M38 evidence, NT-006 R14; NSA/CISA AUTH-03 and the Cilium encryption control).**
  `infra-verify.sh` now reads `STATE` and `EPHEMERAL` back from each node's Talos API and fails unless they are `ready` and `luks2`, and
  fails when the kube-apiserver has no `--encryption-provider-config` (the volume id is taken from Talos' source and has never been read on a
  node: a node that does not know it is reported as unchecked, not as red). `cluster-security-tests.sh` gains 1.8 (Cilium WireGuard enabled in
  `cilium-config` and reported by the agent), 4.6 (`openbao-recovery-dev` fails with `OA_ENVIRONMENT=prod`, is only reported otherwise) and
  4.7 (the seal-key `openaether.io/escrowed-at` annotation; **opt-in** with `OA_ESCROW_ANNOTATION_CHECK=1` until the apps escrow step that sets it
  exists, prod only). New: `task cluster-exposure` (`scripts/ops/exposure-scan.sh`: TCP probes of the bastion, API and app load balancers,
  `FROM=denied` from an address outside `admin_ip`), `task cluster-netcheck` (`cluster-netcheck.sh`: a throwaway non-root pod in a temporary
  namespace must be unable to reach a Service of each platform namespace, with an API-server reachability control; `CILIUM=1` adds
  `cilium connectivity test`, never run here), `task rbac-review` (`rbac-review.sh` + `rbac-review.jq`, a dated `.tsv` flagging named User/Group
  subjects, anonymous bindings and `cluster-admin` outside the allowlist) and a "review at staff change" paragraph in `docs/admin-access.md`.
  The regression workflow runs the exposure scan and the netcheck after `cluster-verify`. Everything is read-only except the netcheck's temporary
  namespace. Rung: mocked/static (stub `kubectl`/`talosctl`, loopback listener, failure and mutant cases; `shellcheck`), **not run on a cluster**.
  It does **not** prove that a real node answers the way the stubs do, that the netcheck image can be pulled under the cluster's policies,
  or that any of the new checks is green on a good cluster; it adds no OIDC and no named-human access (K8S/F13 steps 2-4 are not done), no etcd
  or barman restore test and no backup-policy document (DP-16's apps and policy part), and no UDP probing.

- **Supply chain: committed provider locks, a checksum lane for the Talos boot images, an SBOM, a protected environment for the cloud workflow, rulesets as code (ANSSI SSDLC CICD-AIP-01c/-03, PROV-REC03, CICD-IAM-03/-05, CIO-REC03, SCM-REC06/-07, SBOM25-1/-2/-3 in part).**
  `.terraform.lock.hcl` of `cluster/` and `talos-image/` is committed (linux and macOS, amd64 and arm64); both roots' `>=` provider
  constraints become `~>`; `task validate`/`test` and CI run `tofu init -lockfile=readonly` (shown to fail on a constraint bumped without
  a refresh); `task lock-providers` refreshes by hand and Renovate looks providers up on registry.opentofu.org. `talos-image/images.lock`
  records the sha256 of the Factory raw image per platform and arch for the pinned Talos version; `verify-image-checksum.sh` runs after
  the download in the Scaleway, OVH and Outscale modules, driven by `image_checksum_mode` (**`warn` by default**: today's behaviour plus a
  message; `enforce` stops the build; `off`), and Proxmox passes the provider's `checksum` under `enforce` only. `talos_tunnels` hands its
  values to `local-exec` as environment variables (a key path with a space or `$(...)` stays data; it stays off by default). `real-cloud-regression.yml`
  runs in an environment `sandbox`. `sbom.yml` (weekly and on release) attaches a CycloneDX 1.5 inventory (`gen-sbom.py`: tool pins, locked
  providers, bootstrap images with digests, Factory images with hashes) and Trivy-scans the bootstrap images; `.vex/` holds an empty OpenVEX file.
  `.github/rulesets/` holds the two rulesets as exported; `check-required-checks.sh` compares them with GitHub, requires a pull request,
  no force-push and no deletion on main, and **warns** (fails under `--strict-main`) on 0 approving reviews, no required signatures and the
  admin bypass on main; it also checks the `sandbox` environment. `docs/supply-chain.md` has the rotation table. Rung: mocked/static
  (`tofu test` on the image root and the Proxmox module, stub harnesses, 79 offline cases for the settings check); the settings check was
  also run once, read-only, against the live repository; the Factory was downloaded for real to write the lock. Nothing was run on a cloud or
  a Proxmox host, Trivy and the Renovate validator were not run, and the new workflow has not run. It does **not**
  prove the Factory serves stable bytes over months, that Proxmox's checksum covers the compressed file, that provider versions in the locks
  are the ones the clusters ran on, or that the `sandbox` environment exists with reviewers (create it, then move the secrets); it adds no OIDC,
  no bucket versioning, no image signature verification, and it covers none of what `OpenAether-apps` deploys.

- **Patch policy and the signals behind it (ANSSI hygiene measure 34, audit ids HYG-M34, SSDLC CICD-AIP-01a/-03, NT-35 R2 in part).**
  `docs/patching.md` states the rule (security fix merged or waived in writing within 30 days, 7 when exploited or internet-reachable)
  and what feeds it. `renovate.json5` gains `vulnerabilityAlerts` (label only: Renovate's default for that block already skips the
  schedule, the dashboard approval and `minimumReleaseAge`) and `osvVulnerabilityAlerts`. Cléa gets an optional
  `[policy] max_minors_behind` (set to 2 in `clea.toml`): its report lists every pin more than that many minor releases, or a major,
  behind upstream, held back or not; report only, 15 new assertions in `test-clea.sh`. `scripts/dev/check-image-pins.sh --enforce` runs in
  `task lint` and fails on an `image:` pinned by tag with neither `@sha256` nor an entry in `flux-image-digests.lock` (none today);
  `.github/workflows/image-digests.yml` runs `check-flux-image-digests.sh` weekly (anonymous ghcr.io, no credential, never on a PR).
  Rung: mocked/static; the digest check was also run once against ghcr.io. Renovate's validator was not run (no Node here), and
  the new Renovate keys are checked only against its published JSON schema. It does **not** upgrade Istio, cert-manager, Kyverno or
  CNPG (those pins live in `OpenAether-apps`), does not move the bastion image off Ubuntu 22.04 (a replacement of a deployed
  bastion, left to its own change), does not enable Renovate `pinDigests` (this repository has no manifest a Renovate manager would
  rewrite: the Flux and Cilium manifests are generated), and the 30 days are a commitment of one maintainer, not a control.

- **Passphrase hygiene for the state, the access artifacts and the etcd snapshots (ANSSI PG-083 weak-entropy rule, B2 one key / one use, PA-079 R4 and R14 in part).**
  `scripts/ops/gen-passphrase.sh` prints `openssl rand -base64 48`. `task cluster-up` runs an entropy heuristic on the
  passphrase after the existing placeholder check (distinct characters, repeated block, runs, common words; random base64 and hex
  pass): **warn by default**, `OA_PASSPHRASE_CHECK=enforce` refuses, `=off` silences. New optional `artifact_passphrase`
  (`TF_VAR_artifact_passphrase`, default null = unchanged behaviour and no plan diff) encrypts the gpg talosconfig/kubeconfig
  backups and the etcd snapshots; `restore-artifacts.sh` tries it first and falls back to the state passphrase, so older objects
  open. The pbkdf2 parameters of the state encryption are pinned to OpenTofu 1.12's defaults (600000 / sha512 / 32, read back
  from a state's own metadata: existing states decrypt unchanged). `task kubeconfig` writes both files 0600, the snapshot cron
  warns on a `.env.sh` readable by others, and the false "SSE-C" and "authenticated/OCB" wording is gone. Rung: mocked (`tofu
  test`, the stub harnesses with real gpg, a real go-task), plus a local-backend decrypt check of the pbkdf2 defaults; nothing
  run on a cluster or against a real store. It does **not** make gpg an AEAD (still CFB + SHA-1 MDC), does not add `enforced = true`
  (an unencrypted state would stop planning), does not move artifacts to PGP public keys, and splitting the secrets is only as
  good as the places they are kept.
- **Secrets-at-rest cipher said as it is (ANSSI PA-079 R12).** The comments in `modules/talos/main.tf` called the etcd
  encryption `AES-256-GCM`; Talos' `secretbox` is XSalsa20-Poly1305. `docs/upgrade.md` now records the deviation (not a
  listed AEAD; Talos offers no AEAD alternative) and that the key has no verified in-place rotation. Docs and comments
  only, nothing run; it does not add a rotation procedure, a KMS provider or a new cipher.
- **Review fixes for the passphrase, supply-chain and ops-check changes above (ANSSI PG-083, SSDLC CICD-AIP-03, CICD-IAM-03; found by an independent review).**
  `test-passphrase.sh` now greps that `backup.tf` hands the backup script `local.artifact_passphrase` (reverting it to the state
  passphrase left every test green before; the line was changed and the new check went red). `artifact_passphrase_set` is
  `nonsensitive()`: it derived from a sensitive variable and so hid the whole `triggers_replace` map in every plan, set or not (a
  test asserts it is readable; no value changes, so no plan diff is expected, **not run against a real state**). `etcd-snapshot.sh` warns
  when `artifact_passphrase` is in a tfvars file but not in `TF_VAR_artifact_passphrase`, the case where artifacts and snapshots would
  silently end up under different passphrases (the variable's description now says environment only). The sandbox-environment
  check fetches the deployment-branch patterns and fails on anything but `main` (a `*` policy passed before) and warns on
  "protected branches" only (82 self-test cases, 3 new). `task kubeconfig` creates its two files with `touch` and `chmod 0600`
  (BSD `install` on macOS may refuse `/dev/null`; **not run on macOS**). `test-talos-tunnels.sh` checks that `OA_TUNNEL_KEY` is
  still `pathexpand()`ed. `test-passphrase.sh` checks a fixed hex value instead of a random one (a random 32-character hex string
  has fewer than 10 distinct characters about once in 10^4 draws and was flagged, so the line flaked). Docs and variable text now say that `checksum_mode = enforce` on a Proxmox root that already holds
  the image plans its re-download (bpg 0.116 `checksum` forces replacement; the resource is deprecated there), that a Talos bump
  needs `talos-image-lock.sh` run by hand (the Renovate PR body says so), and what `osvVulnerabilityAlerts` actually reaches.
  Rung: mocked/static, nothing run on a cluster or a Proxmox host. It does **not** automate the lock update, and
  does not replace the deprecated Proxmox resource.

- **The security documentation set, each page with a French twin (ANSSI rules on key impact, crypto-period and erasure; incident handling and PG-078 R26; backup policy, restore tests and destruction; a documented recovery plan; a documented architecture, flow matrix and trust zones; a documented administration system and privileged accounts; patching, vulnerability watch and written deviations; audit ids DP-06, DP-07, DP-17, TLS-12, TLS-19, TLS-20, F-BKP-07, F-BKP-10, F-BKP-16, LOG-17, ADM/F11, ADM/F13, NET/F07, NET/F09, OSN/F13 stage 0, OSN/F18, SCC/F11).**
  New in `docs/`: `key-management` (every key K1 to K13 with purpose, algorithm, crypto-period, impact if lost and if leaked, replacement, revocation, erasure and archive; the Talos PKI, state-passphrase and etcd-key replacement procedures; the recorded deviations for
  the software seal key, the AES-GCM wrap, the three CAs and the absent post-quantum hybrid), `incident-response` (detection sources, severity, contact placeholders, evidence capture with `talosctl` before a node is replaced, backups protected first, containment, a rotation table per secret, restore-point choice,
  degraded access when Zitadel or the bastion is down, a register template), `backup-policy`, `disaster-recovery` (one ordered chain, OpenBao's snapshot before Zitadel's database because the masterkey lives in OpenBao, prerequisites, time targets, a yearly drill with a result table), `security-architecture`, `network`,
  `hardening`, `threat-model`, `component-selection` (with the VEX register) and `audit-register`; linked from `SECURITY.md` and both READMEs; "Quarterly security review" added to `release-checklist.md`.
  **Two statements the code contradicts are corrected** in `admin-access` (EN and FR): section 6 said the gateway was "nothing public" (with `deploy_app_lb` the application load balancer forwards public 80/443 to it, with no source filter) and showed bare `bao token create`
  commands that need a token this platform does not hand out (`openaether-admin` explicitly cannot mint one); the maintenance-mode apply is written up as a residual risk in `first-cluster` and in the `modules/talos` header (DP-17).
  New checks: `scripts/dev/check-doc-twins.sh` (in `task lint`: each pair opens with a link to the other, the security pairs have the same sections and code blocks on both sides, relative links resolve; its own test `test-check-doc-twins.sh`), and `scripts/dev/gen-flow-matrix.sh` with `test-flow-matrix.sh`
  (in `task test-scripts`): the node-inbound tables of `network.md` and `network.fr.md` are generated from `scw/security.tf` (the `node_inbound_ports` map), `ovh/security.tf` and `outscale/security.tf` and compared with the code, and every rule must have a justification row.
  Rung: **documents, read against the code, plus mocked tests of the two checks; nothing was run on a cluster, and no procedure in these pages was drilled.** RPO and RTO figures are proposed targets, the periods marked "proposed" are the maintainer's to confirm, and two joins of the recovery chain are named as unsettled (how the seal-key Secret is placed before OpenBao starts on a cluster built with Flux; the restic repository prefix of a rebuilt cluster).
  It does **not** add a mechanism, an object lock or versioning on the buckets (recorded as a gap), a rotate-secret task, a host firewall (stage 0 of OSN/F13 is the page), named Kubernetes identities, the Talos node baseline (sysctls, kernel arguments, Secure Boot: rows left open in `hardening`), or end-of-support dates for the infrastructure pins; the application-side inventory it points to (`OpenAether-apps/docs/key-inventory.md`) ships with the apps half of the same work.

- **Optional source filter on the application load balancer, `app_lb_allowed_cidrs` (ANSSI PA-022 R15/R16, HYG-M28, BP-028 R79; the infra half of the audit's OSN/F15 and ADM/F03).**
  New variable (list of IPv4 CIDRs, default **empty = no filter = exactly the previous behaviour**, so no deployed cluster changes). With `deploy_app_lb` and a non-empty list: Scaleway gets inline allow-then-deny ACLs
  on the `http` and `https` frontends (the pattern of the Kubernetes API frontend, an in-place update), OVH `allowed_cidrs` (sorted) on the two Octavia listeners, Outscale inbound 80/443 rules from the list in the
  cluster security group, which is the load balancer's group. Each module also admits the cluster's own egress address (Scaleway NAT gateway, OVH router address, Outscale NAT service: pods reach
  `https://zitadel.openaether.local` through the load balancer) and, on Scaleway and OVH, the private range; Proxmox and local are left out (no cloud load balancer). `["0.0.0.0/0"]` is accepted to turn the machinery on while
  staying open. A `check` warns when the list is set but nothing can apply it. `network.md`/`.fr.md` (generated flow tables, section 6 gap 5) and `admin-access.md`/`.fr.md` section 6 describe it and the staged roll-out.
  Rung: **mocked/static, not run on a cloud**: `tests/app-lb-source-filter.tftest.hcl` (ten cases: no ACL by default, allow before deny on both frontends, listener lists sorted, Outscale rule sources, input refused for a bare
  address and for IPv6, the warning), the flow-matrix generator and its test. **Not proven**: that any of the three clouds enforces it, that the update is in place (no LB replacement, hence the same public IP), that pods still
  reach Zitadel, that health checks and the client source address survive the NodePort path, and, on Outscale, whether the load balancer is filtered by its group at all (the group has had no 80/443 rule until now). It does
  **not** authenticate anyone (a listed address still reaches every route's own login), does not remove any route (the apps half is another change), does not change the default to `admin_ip`, and does not cover Proxmox.

- **Opt-in versioning, expiry and object lock on the buckets that hold copies and logs, `backup_immutability` (ANSSI RW-SAUV-2/-3, GH-BKP-1, HYG-M37; the infra half of the audit's F-BKP-01, LOG-07 and DP-05).**
  New variables `backup_immutability` (`off` default | `versioned` | `governance` | `compliance`) and `backup_retention_days` (default 60), read from the tfvars by `scripts/internal/ensure-buckets.sh`
  (no resource reads them: the buckets exist before OpenTofu runs). **`off` changes nothing**: no call is made, no bucket is created. Otherwise the script creates the application-backups bucket and its `-backup`
  twin (until now the operator's to create by hand; the seed and the apps need them) and, on all seven buckets, turns on versioning and a lifecycle rule `oa-noncurrent-expiry` (non-current versions expire after
  `backup_retention_days`); with `governance`/`compliance` the five buckets that hold copies or logs (application backups and their replica, the state and artifact replicas, Loki's logs) are CREATED with object lock
  and get a default retention of the same length (the primary state and artifact buckets are versioned, never locked: tofu writes them). Everything is read back from the store and a refusal is a loud warning naming the
  bucket and the provider's words, never a silent pass (`OA_BUCKET_PROTECTION_STRICT=1` makes it exit 1). Lifecycle rules someone else set are merged, not replaced, and nothing is written when they cannot be read.
  A check warns for `compliance` on a dev cluster with more than 7 days: such a bucket cannot be emptied or deleted before the retention ends. Rung: **mocked/static, not run on a cluster**: a fake store
  (`testdata/fake-aws-s3.sh`) that refuses object lock on a bucket not created with it, 56 assertions in `test-bucket-protection.sh`, seven `tofu test` cases. **Not proven**: that Scaleway, OVH or Outscale accept any of
  these calls (versioning, a lifecycle on non-current versions, create-with-lock, a default retention), that restic, Barman, Longhorn and Loki keep working against a versioned or locked bucket, or that the expiry fires.
  It does **not** stop a key that may call `DeleteObjectVersion` from removing an unlocked version (that is the key policy, below), does not touch an existing cluster unless its tfvars ask, and does not enable
  object lock on a bucket that already exists without it on providers that refuse it (reported, not forced).

- **Key pairs of their own for the backup stores, and a check of who can open what (ANSSI RW-SAUV-2, GH-BKP-1, PA-012 R26/R26+, HYG-M37; the infra half of the audit's F-BKP-01, F-BKP-04, LOG-07, F05 and DP-05).**
  Extends 0.2.1's Loki bucket and `OA_LOKI_S3_*`. `seed-openbao.sh` takes the same optional, both-or-neither pairs for the two backup stores: `OA_BACKUP_S3_ACCESS_KEY_ID` / `OA_BACKUP_S3_SECRET_ACCESS_KEY` for
  `backup/s3-primary` and `OA_BACKUP_REPLICA_S3_*` for `backup/s3-replica`, each meant to be limited by the operator to its bucket. **Without them nothing changes** (the cluster still gets the operator's keys, which also open the
  state, artifact and logs buckets and may delete in them) **and the script now says so, from OpenBao's answers**, for the backups as it already did for Loki; a pair set against an entry that exists is reported as not applied (the
  seed is create-only). New `scripts/ops/s3-isolation-check.sh <tfvars>` reads, with the pairs in the environment, which identity lists which bucket and whether a dedicated pair may call DeleteObjectVersion (a version that does not
  exist is named: nothing is deleted), and compares the buckets with `backup_immutability`; exit 0 held, 1 not, 2 nothing dedicated in scope. Rung: **mocked/static, not run on a cluster**: `test-seed-openbao.sh` (96 assertions) and
  `test-s3-isolation.sh` (23, on the fake store). **Not proven**: that any provider lets a key be limited to one bucket, or to everything but DeleteObjectVersion (the policy is the operator's to write and is not shipped:
  `docs/backup-policy.md` lists the actions each identity needs), or that restic prune, Barman, Longhorn and Loki run with such a key. It does **not** move `forget --prune` out of the cluster (that is apps and needs restic locking
  checked against a reduced key), does not rotate a seeded key (create-only: `bao_admin kv put`, documented), and does not touch an existing cluster's entries.
  Documented in `backup-policy.md`/`.fr.md` (section 3 the modes and their limits, new section 4 the identity-to-bucket table and the rotation order), `admin-access`, `incident-response` (step 5 no longer says "no object lock is configured" without the opt-in), `key-management`, `security-architecture`, `audit-register`, `.env.example` and the teardown message of `fleet-down.sh` (a locked bucket cannot be emptied).

- **`task cluster-security` checks that Loki writes to a bucket of its own and does not hold the backups' keys (4.8, 4.9; ANSSI PA-012 R26, RW-SAUV-3; the live-cluster half of the audit's F-BKP-04 and F05).**
  Reads `loki-s3-credentials` and `backup-restic-env`, compares the encoded values and prints none. 4.8 **fails** when Loki's bucket is the backups bucket (what a cluster seeded before 0.2.1 still has, create-only);
  4.9 is a **skip**, not a failure, when the key pair is the same (the seed's default without `OA_LOKI_S3_*`), and says what that leaves open. A cluster that lacked a dedicated pair keeps its 0.2.1 count
  of passes, with one more skip and one more pass. Rung: **mocked/static**, six cases in `test-security-tests-checks.sh` (21 in all); not run on a cluster. Already there and not repeated: the Cilium WireGuard
  check (1.8) and `check-cilium-effective-config.py`, which answer the audit's cleartext Alloy-to-Loki hop (WireGuard, no application-layer TLS); the `insecure: true` of `loki.yaml` is the apps repository's.

- **`task escrow`: the OpenBao seal key, recovery shares and restic password escrowed to at least two custodians, proved against the live key, then attested (ANSSI GH-M37-5, RW-PRA-1, B2 recovery rule, PA-022 R45 in part; the infra half of the audit's F-BKP-05, DP-02 and F15).**
  New `scripts/ops/escrow-openbao.sh` (`task escrow -- export|verify|attest`). `export` reads the three items from the cluster (the restic password through the `openaether-admin` path, the token on stdin), encrypts the seal key and the
  password to every custodian (`-r KEYID` twice or more, or `--recipients-from-tfvars`), copies the already PGP-encrypted shares and writes a receipt of hashes (no secret); it refuses fewer than two **distinct** keys (two names for one key
  count once), a directory inside a git work tree, a non-empty directory and a development bootstrap, and never puts a value on a command line or in a file unencrypted. `verify` reconstructs the key from the escrow alone (or from `--key-file`
  for a hand-made k-of-n split) and compares its sha256 with the receipt and with the live Secret, and does the same for the restic password and the share copies; `attest` runs `verify` and only then writes the ConfigMap
  `openbao-escrow-ack` and the annotation `openaether.io/escrowed-at`, exactly as the apps Day 0 step 5 does. **`cluster-security` check 4.7 now compares the attested hash with the live key**, and also fails on one holder, an attestation
  older than 400 days or undated, and an annotation without the ConfigMap: the case the apps CronJob cannot see (it never reads the key) is an escrow of a key that was rotated since. 4.7 stays opt-in (`OA_ESCROW_ANNOTATION_CHECK=1`, prod only).
  Rung: **mocked/static with real crypto**: `test-escrow-openbao.sh` (37 assertions, real gpg keys, a stub cluster, mutants run) and 29 in `test-security-tests-checks.sh`. **Not run on a cluster**: the pod exec, the apps CronJob
  accepting the ConfigMap this writes, the `ssss`/`gfsplit` split (not tried), a restore from the escrow. It does **not** split the key (several recipients means any one opens it: it survives losing a person, not one leak), prove that each custodian
  can open their copy (each runs `verify`), move the key out of the cluster, or run the disaster-recovery drill. Docs: `admin-access`, `key-management`, `disaster-recovery`, `release-checklist`, `audit-register` (EN and FR).

- **`task rotate-secret`: the replace path that `seed-openbao.sh` (create-only) does not have (ANSSI B2 renewal rule, PG-078 R7/R26; the infra half of the audit's F-BKP-10, ADM/F11 and DP-07).**
  New `scripts/ops/rotate-secret.sh <path> [--apply] [--restart ns/kind/name]`. As `openaether-admin` (token exchanged inside the pod, on stdin) it reads the entry, replaces only the fields it is given from `OA_ROTATE_*` in the environment
  (the S3 pairs of `backup/s3-primary`, `backup/s3-replica` and `observability/loki-s3` with an optional bucket or endpoint; `OA_ROTATE_VALUE` for the two Alertmanager URLs and `grafana/oidc`), writes a new version with a check-and-set on the version it read,
  nudges every ExternalSecret and, for `--restart`, waits until they have refreshed before restarting the named consumer (and restarts nothing if they did not). A dry run is the default. It **refuses, with the reason**, `backup/restic`, `zitadel/masterkey`,
  `longhorn/encryption`, `zitadel/db`, `grafana/db`, `zitadel/admin`, `grafana/admin` and `minio/root`: each has a step outside OpenBao (a repository key, a database role, an encrypted volume) that this tool cannot do. Implemented as its own script rather than a mode of
  `seed-openbao.sh`: the seed's identity may only create, and a replace mode would have widened it. Rung: **mocked/static**, `test-rotate-secret.sh` (39 assertions, stub kubectl, mutants run); not run against an OpenBao or a cluster. It does **not** rotate
  the Talos PKI, the state passphrase or the etcd and disk keys (written procedures only, `key-management.md` section 3), does not create the new key at the provider, and does not revoke the old one. `incident-response.md` section 7 and `backup-policy.md` section 4 point to it (EN and FR).

## [0.2.1] — 2026-10-15

**The infra half of the pair with OpenAether-apps 0.2.0: Day-1 seeding without a root token, a bucket of its own for Loki, a language check shared with the apps, and the Day-1 documentation corrected. A patch: no new scope.** It pins apps `refs/tags/0.2.0`. Read the entries below with their rung: real cloud means once, by hand, on the clouds named; nothing is repeated or unattended, and `cluster-up` with `deploy_flux = true` still ends 201 until the Day-1 seeding has run.

**Not fixed, and not observed:** the dedicated Loki key pair was never run on a cloud; infra #302 stays open for it. `task cluster-upgrade`'s pre-upgrade safeguards (#270) have never run on a cloud. Outscale ran the reduced apps profile only. An OVH worker can stay `ACTIVE` while dead (#49): it happened once and was hard-rebooted. No disaster-recovery restore, no rolling upgrade with Flux, no Proxmox hardware.

### Security

- **Loki writes to a bucket of its own (#302).** `seed-openbao.sh` seeded `observability/loki-s3` with the backups bucket and the
  backup keys, so a compromised Loki could erase the backups, against what the docs and the ExternalSecret said. It now seeds
  `s3-<project>-<provider>-logs-<env>` (`oa_logs_bucket`, created by `ensure-buckets.sh` beside the artifacts bucket) and, when
  `OA_LOKI_S3_ACCESS_KEY_ID` and `OA_LOKI_S3_SECRET_ACCESS_KEY` are both set, that pair (half a pair is refused before any write).
  **Without them Loki still gets the primary's keys, which are account-wide on the providers, and the script says that the
  separate bucket then protects against a mistake and not against a compromise.** Scoped keys are the operator's to create; this
  repository does not create them. A cluster seeded earlier keeps its entry (create-only). Rung: mocked (seed and name tests), and real
  cloud once by hand on Scaleway and OVH with the shared keys (Validated); the dedicated pair was never run on a cloud.
- **Day-1 seeding without a root token (#296, #297).** `scripts/ops/seed-openbao.sh` read the root token from the Secret
  `openbao-recovery` and passed it, with every value, on the `kubectl exec` command line. With OpenAether-apps 0.1.1 there is
  no such Secret (the bootstrap revokes the root token), and the script now uses the ServiceAccount `openbao-seeder`:
  Kubernetes issues a 10-minute token, OpenBao exchanges it inside the pod for a token whose policy `secret-seeder` can
  **create** five paths and read their metadata. The token and the documents travel on stdin, never on a command line; every
  secret is written with `cas=0`, so a re-run cannot overwrite one. The script no longer seeds `backup/restic`,
  `grafana/db`, `zitadel/db` or `longhorn/encryption`: `openbao-vault-bootstrap` generates them inside OpenBao, create-only,
  and prints none, which removes the race of #297 (the script could win it and the escrow print was lost). **Needs apps 0.1.1:**
  on a cluster still bootstrapped by apps 0.1.0 the script fails and says to use the infra 0.2.0 tag's script. Rung: mocked (a stub
  `kubectl`, 66 checks); the remote loop was run once against a real OpenBao 2.7.1 with the real policy (create, left alone,
  refused). The Kubernetes-auth login was exercised on real clusters running apps 0.1.1 and later (Scaleway and OVH full, Outscale reduced profile: see Validated).
- **`openbao_recovery_pgp_keys` / `openbao_recovery_threshold`: who holds the OpenBao recovery shares.** OpenBao unseals itself
  with a static key, so no human holds an unseal share; what operators hold are recovery shares, used only to generate a root
  token. Given at least three PGP public keys, the Flux bootstrap manifest also publishes the ConfigMap
  `openbao-operator-keys`, which switches the apps bootstrap to production mode: one share per key, encrypted to it. Without
  keys the bootstrap is a development one (a single plaintext share in a labelled Secret). `environment = "prod"` with
  `deploy_flux = true` refuses to plan without three keys, and a threshold above the number of keys, below 2, a duplicate key
  or a private key pasted by mistake are refused. Rung: mocked (`tofu test`, 9 runs; the template rendered by OpenTofu
  in both shapes and validated by `check-flux-schema.sh`).
- **`task cluster-up` checks the OpenBao recovery-share keys before it bills** (`scripts/internal/check-openbao-keys.sh`, tested against real
  gpg keys): `sys/init` commits the cluster before it encrypts the shares, so a key with no usable encryption subkey (a signing-only or
  expired key) ends the first run in a re-init. Each key's fingerprint is printed. Found by an independent review of the redesign.
- `cluster-security-tests.sh` 4.5 now asserts that no Shamir-share or root-token Secret exists in `foundation-vault` (it asserted
  that an unsealer was running).

### Changed

- **The `git_ref` default and the twelve `envs/*.tfvars.example` pin OpenAether-apps `refs/tags/0.2.0`** (they pinned 0.1.0). The pair
  is infra 0.2.1 with apps 0.2.0, validated end to end with the pins as shipped (see Validated). Infra 0.2.1 with apps 0.1.1 was **not run**
  (the only validated 0.1.1 pair is an infra commit on main, `f127a26`); infra 0.2.0 stays on apps 0.1.0 and cannot move. apps 0.1.1 and 0.2.0
  initialise OpenBao with a static seal: **a cluster built from infra 0.2.0 and apps 0.1.0 cannot be moved to this pair in place; build a
  new cluster, on new buckets** (a rebuild on the old backup bucket meets the old WAL archive and CloudNativePG refuses to archive into it,
  `OpenAether-apps/docs/traps.md`). A cluster on apps 0.1.1 moving to 0.2.0 must recreate its VictoriaMetrics volumes and loses their metric
  history (apps CHANGELOG, Upgrade notes). Nothing here ran an upgrade.
- **`scripts/dev/check-language.sh` is the OpenAether-apps copy again** (`check-skill-parity.sh` compares them byte for byte and
  `task apps-validate` against the apps tag was red on it). It now reads inline comments, Python strings and accents, so it
  found eight genuinely French lines here, now English: the Cilium parity message, two preflight messages, the Flux bootstrap
  template header and the Proxmox VIP comments. Its own cases come with it (`test-check-language.sh`, wired into `test-scripts`).
  The name of the dependency watcher, Cléa, is no longer read as French (taught in both repositories at once).
### Added

- **The environment-data rules of `.gitleaks-envdata.toml` judge the token, not the line, and know more names.** An independent review of the
  copy added to OpenAether-apps showed that one private range or one word like `shared` on a line excused a real address next to it, that
  `outscale_account_id` and `OSC_ACCOUNT_ID` (prefixed names) were not matched, and that the logs and artifact buckets were not covered. The same
  file is fixed here; the probe now holds 16 values it must catch and 13 it must leave alone. Known limit: a line carrying a version word is
  excused whole. Rung: the probe, run before the scan in CI.

- **`explain-failure.sh` points at the OVH router's SNAT port** when a run says `time is not in sync` and touched `module.ovh`.
  Seen once on a real account: a router whose `network:router_centralized_snat` port stayed DOWN left every node without DNS or
  NTP, and a fresh router of the same code was ACTIVE. The message gives the read-only command and says a bad router does not
  recover (tear down and run `cluster-up` again). It is a hint on the transcript, not a guard: a guard that fails a healthy
  apply on a transient DOWN has not been measured. Rung: mocked (three cases in `test-explain-failure.sh`).
- **`task cluster-upgrade` secures the way back before it moves anything (#270).** An encrypted etcd snapshot
  (`backups/etcd/pre-upgrade-etcd-<timestamp>.snap.gpg`, both artifact buckets) and a labelled copy of the state
  (`<state key>.pre-upgrade.<timestamp>` in the replica) are written first, under names no retention removes, and the run
  does not start when it cannot take them (`UPGRADE_SKIP_SNAPSHOT=1` starts without, and prints what that costs). The
  drill of #270 measured that the way back for the control planes across a minor is a restore of exactly these two;
  nothing took them. `SNAPSHOT_LABEL` (etcd-snapshot.sh) and `STATE_LABEL` (backup-state.sh, `--list` shows them) are the
  mechanism. Rung: mocked (new checks in test-state-backups.sh and test-cluster-checks.sh); not run on a cloud, and the state copy back is still the
  unmeasured part named in docs/upgrade.md. The route decisions of #270 (a supported flag to lower a pin, the Kubernetes
  rule) stay open.

### Fixed

- **`ensure-buckets.sh` refused a deploy over a bucket it had itself created.** On a real OVH run with the replica on Scaleway, the
  AWS CLI retried a create whose answer was lost, and the retry was told `BucketAlreadyOwnedByYou`; the script counted that as a
  failure of the replica store and stopped `cluster-up` before anything billed. That answer now counts as the bucket existing; any
  other refusal still stops it and is printed. Rung: mocked (two cases in `test-backup-creds.sh`); the defect was seen once, on a real cloud.

- `docs/admin-access.md` (and its French twin) read the PKI CSR from KV (`bao_admin kv get -field=csr secret/pki/intermediate-csr`),
  not from the bootstrap Job's log, which is removed an hour after the Job ends; the page and the seed script say apps 0.1.1,
  not 0.2.0, and tell a 0.1.0 cluster to be rebuilt.

- **`seed-openbao.sh` seeded the replica store with the primary provider's S3 keys (#296).** The replica's pair is now asked
  for with its own endpoint (`resolve-s3-cred.sh <provider> ak|sk backup <replica endpoint>`), as every other replica
  consumer does, and the run fails before any write when that pair is empty. A cluster seeded earlier keeps what it has
  (create-only): correct `backup/s3-replica` by hand (docs/admin-access.md, section 3). Rung: mocked (a cross-provider tfvars).
- **The red of a `deploy_flux = true` cluster pointed nowhere (#298, #300).** The `flux-system exists` line now names
  `seed-openbao.sh` and `admin-access.md` § 3, the app-load-balancer line states that its "nothing serves" holds for an
  infra-only cluster, and `README.md` / `admin-access.md` no longer say that Day-1 belongs to a later release: it applies to
  any cluster built with `deploy_flux = true`. The assertion that Flux is absent is unchanged.
- **Day-1 inputs written nowhere (#299, documented part).** `docs/admin-access.md` § 3 now names `source .env.sh`, the two
  alerting variables, the replica cloud's `<CLOUD>_BACKUP_AWS_*` keys and the two bucket names (`ensure-buckets.sh` creating
  them stays an open decision on #299).

### Validated

- **The pair as shipped, 2026-10-15 (infra `dcd1ace`, no `git_ref` in the tfvars so the default `refs/tags/0.2.0` applied; apps tag 0.2.0 at
  `22b00cc`).** Rung: real cloud, **once per cloud**, by hand. **Scaleway and OVH**, management role, 3 control planes + 2 workers,
  `deploy_flux = true`, three throwaway PGP recovery keys: Flux followed `refs/tags/0.2.0` at `22b00cc`; `cluster-up` ended 201 on
  `flux-system exists` only (13 passed, 1 failed); the seeding printed the shared-keys warning from OpenBao's answers; 35 of 35
  Kustomizations, every pod Running; the Kyverno report held 2 results (the Istio-generated proxies, apps #70); `grafana-db` and
  `zitadel-db` Ready with archiving True; Longhorn BackupTarget available; Loki's first objects in its own logs bucket after its 30-minute
  idle flush, the backups bucket holding only `cnpg/`; `cluster-security` 30 of 31; strict plan "No changes". `task apps-validate` is green
  against the tag. **Not run on the shipped pins:** Outscale (its quota only holds the reduced apps profile, which needs a branch, so the
  Outscale run below is with a branch), an upgrade, the dedicated Loki key pair, Proxmox. Both clusters torn down, `purge-orphans` and
  `verify-provider-clean` clean, lab buckets and images deleted.
- **The 0.2.1 candidate with the apps 0.2.0 candidate on three clouds, 2026-10-15** (the apps branches are not tags; see that repository's
  CHANGELOG for what ran inside). Rung: real cloud, **once per cloud**, by hand; `cluster-up` ended 201 on `flux-system exists` only
  (13 passed, 1 failed), as documented until the Day-1 seeding. **Scaleway** (infra `4ae2357`): `seed-openbao.sh` printed the shared-keys
  warning, wrote five paths; Loki wrote to the new `…-logs-<env>` bucket created by `ensure-buckets.sh` and nothing of Loki's reached the
  backups bucket; 35 of 35 Kustomizations; `cluster-security` 30 of 31; strict plan "No changes". **OVH** (infra `39df1b8`): same, and the
  run that exposed the `BucketAlreadyOwnedByYou` defect (Fixed above) first; one worker was dead after boot (issue #49), hard-rebooted and
  `up` re-run. **Outscale, reduced apps profile only** (infra `39df1b8`): up in 1020 s (13 passed, 1 failed: the same line), seeding and the OpenBao snapshot job fine; `cluster-security` 25 of 31, the four failures being the mesh checks (that profile has no Istio).
  **Changed after the last lab run (mocked only):** the seed script's closing message (now built from OpenBao's answers), the wording of
  the `ensure-buckets` retried-create message, the logs bucket in the teardown list and docs, the gitleaks rules, the release checklist and
  status text. **Not run:** the dedicated Loki key pair (the lab used the shared keys), `task cluster-upgrade` with the new safeguards, a second
  `cluster-up`, the OVH SNAT hint (its failure did not recur), Proxmox. All three labs torn down; `purge-orphans` clean on Scaleway and OVH, and on
  Outscale it lists only the standing OMI, kept on purpose (deleting it is the owner's call); lab buckets and images deleted by hand (Outscale's
  image-lane buckets kept: state of that OMI).

- **The Day-1 path of the OpenBao redesign, `deploy_flux = true`, Scaleway, 2026-10-13, on this branch (8d4a036 for the apply and the
  seeding; later commits touched the upgrade path and documentation only), with OpenAether-apps `claude/security-bootstrap`.**
  Management role, 3 control planes + 2 workers, replica store on OVH. `cluster-up` ended 201 after 570 s on
  the `flux-system exists` line (13 passed, 1 failed), which now names `seed-openbao.sh`. Three PGP public keys in `openbao_recovery_pgp_keys` produced the
  ConfigMap `openbao-operator-keys` in the Flux bootstrap manifest and OpenBao bootstrapped in production mode (three shares encrypted
  to the keys, threshold 2). `seed-openbao.sh` ran with a ServiceAccount token (no root token exists): five paths written in 2.6 s, all
  five left alone on the second run; `backup/s3-replica` carried the replica cloud's endpoint and keys, not the primary's (#296 observed
  on a real cross-provider setup). `task cluster-security` 30 of 31 passed (one skipped: no MinIO namespace), including the new 4.5. Torn
  down in the two commands (53 resources), `purge-orphans` and `verify-provider-clean` clean, the lab's seven buckets and its images
  deleted. **A second run on the hardened code (87daaf4, same day):** `task cluster-up` refused a signing-only key in
  `openbao_recovery_pgp_keys` in one second, before any resource was created, printing each key's fingerprint; with the key replaced it
  applied and bootstrapped unaided, the seeding wrote five paths, the hardened apps bootstrap passed (see that repository's CHANGELOG),
  35 of 35 Kustomizations were Ready 132 s after the seeding began, `cluster-security` 30 of 31. **Not run:** `cluster-upgrade` with its new
  pre-upgrade safeguards on a cloud, a second `cluster-up`, another cloud or role. What the runs found in OpenAether-apps is in that
  repository's CHANGELOG.

- **`deploy_flux = true`, Scaleway, 2026-10-12, on the 0.2.0 tag commit, once, stage by stage from a maintainer's lab
  script.** Management role, 3 control planes across three zones + 2 workers (`POP2-4C-16G`), `git_ref = refs/tags/0.1.0`
  (OpenAether-apps 0.1.0). `cluster-up` applied and ended 201 after 486 s on `cluster-verify`: 13 passed, 1 failed, 0
  could not be checked, the failure being `flux-system exists`. Flux followed the tag and reconciled the `management`
  profile. Counted from the first Flux object: 12 of 35 Kustomizations Ready at 2 minutes, 29 of 35 at 6.5 minutes, then
  the same six not Ready for about 17 minutes (`cnpg` waits on the ExternalSecret `cnpg-backup-s3`, which reads
  `backup/s3-primary`; its first 15-minute health check failed and it retried after 2 minutes). Counted from the start of
  `scripts/ops/seed-openbao.sh scaleway` (docs/admin-access.md, section 3; five paths written, four left alone): `cnpg`
  Ready after 11 s and the last of the six after 114 s (about 60 s of it the 1-minute retry of
  `observability-vm-customresources`, whose first dry-run found no VMAlert CRD), then every Kustomization Ready (61 of 62
  Flux objects; the 62nd is an OCI HelmRepository, which has no Ready condition) until the last sample 7.5 minutes later;
  15 HelmReleases InstallSucceeded, 127 pods Running and 6 Completed. The 17 minutes are the lab's order (seeding after
  the observation snapshots), not a product latency; the product facts are that it does not converge without the seeding
  and that it converged in 114 s with it. Figures come from the Kustomizations' lastTransitionTime and the controller
  logs. It corrects, for this lab and without moving the 0.2.0 text, the 0.2.0 statements that no cluster has followed the
  apps tag: only `refs/tags/0.1.0` was followed, `refs/heads/main` was not. Torn down in the two commands (52 resources,
  `purge-orphans` clean, `verify-provider-clean` rc 0). Not run: a second `cluster-up`, `cluster-idempotency`, an upgrade
  or a roll with Flux, the PKI signing, Grafana SSO, a backup or a restore, another cloud or role.

### Added

- **`docs/upgrade.md`, "Going back": what was measured of rolling an upgrade back (#270).** Real cloud, by hand, Scaleway,
  2026-10-12, the `0.1.0` and `0.2.0` tags (Talos 1.13.9 and Kubernetes 1.36.3 to 1.14.2 and 1.37.1, 3 control planes + 2
  workers). A worker comes back with `talosctl rollback` in 21 to 39 s, also with Kubernetes at 1.37.1. A control plane
  does not, across a minor that moves etcd's storage version: Talos 1.13.9's etcd refuses the data Talos 1.14.2's wrote
  (`version "3.7.0" is not supported`) and two rolled-back control planes cost the quorum for about 11 minutes. The way back
  for the control planes is a restore of an etcd snapshot taken before the upgrade: three members 52 s after the
  `bootstrap`, the API back 4.3 minutes after the first rollback, everything since the snapshot lost. Lowering the pins
  afterwards makes the plan replace the Talos secrets (the state has to go back too). Not measured: the state copy back,
  a restore after the Kubernetes bump, other clouds, a patch-level control plane rollback. `cluster-upgrade` still takes
  no snapshot and #270 stays open for the tooling and the decisions it lists.

### Fixed

- **`task local-up` refuses, in a second, a host whose kernel cannot build Talos 1.14's `/etc` overlay (#291).** Talos 1.14
  passes the overlay's layers as O_PATH file descriptors (`fsconfig` `FSCONFIG_SET_FD`, `lowerdir+`), which Linux accepts
  from 6.15 (6.13 added layers by descriptor, 6.15 the O_PATH ones). On 6.12.107 the call answers `EBADF`, every node died at
  boot and the bootstrap waited ten minutes. `scripts/dev/check-host-overlay-fd.sh` reads the Docker daemon's kernel; below
  6.15 and on this machine's own kernel it asks that kernel with the same call, in a user namespace, and refuses only on a
  refusal. A daemon it cannot ask (a Docker Desktop VM, a WSL2 kernel) gets a warning. Rung: mocked (a stubbed daemon, kernel
  and probe, every branch removed once to see its test go red); the real probe refused on the kernel 6.12.107 host that found
  the defect. The guard asks only for Talos 1.14 and later: Talos 1.13.9 / Kubernetes 1.36.3 booted on that host and
  `local-verify` passed (1 control plane + 1 worker, apart from the pin comparison; 3 + 3 ran the 3.8 GB host out of
  memory). Not run: the guard on a kernel 6.15 or newer, where it passes by version.

---

## [0.2.0] — 2026-10-12

**A Talos cluster that is upgraded to Talos 1.14 and Kubernetes 1.37, grown and shrunk while it runs, and rebuilt once on
a second cloud from its replica (OVH to Scaleway, one control plane and one worker), with Cilium still the only
platform above Talos.** The climb, node growth and node removal ran by hand on real accounts between 2026-10-02 and
2026-10-04, on Scaleway (two climbs), OVH and Outscale (one each); on 2026-10-05 the failover, the image lane, the
nodes' resolver and the Talos provider 0.12.0 pin ran at one control plane and one worker. The climbs of 2026-10-02 and
2026-10-03 ran under provider 0.11, which 0.2.0 no longer ships. The climbs from a 0.1.0 cluster (2026-10-06) and a
deploy from empty at the shipped pin (2026-10-10 and 2026-10-11) ran under 0.12.0 on all three clouds (Validated).
Nothing is unattended. A bullet's rung is its evidence: what does not say real cloud is mocked, emulated or local
Docker. Read Known limits and Upgrade notes before pulling this onto a cluster that matters.

### Added

- **`task teardown-all`: take a dev cluster down in one guarded command (#277).** It plans, asks the cluster's full id (or
  `CONFIRM=<id>`), destroys, then runs `purge-orphans` as a dry run and `verify-provider-clean`. It refuses anything that is
  not exactly `environment = "dev"` in the tfvars, with no flag to lift a refusal; `PROVIDER=all` guards every target before
  destroying any; `OA_NO_TEARDOWN_ALL` or a `.no-teardown-all` file locks it for a shell or a checkout. It never runs
  `purge-orphans --apply` and never deletes buckets, images or keypairs. The guard trusts the declared `environment`:
  a production cluster deployed as `dev` is not protected by it. Rung: mocked (each guard removed once to see its test
  go red); real cloud on Scaleway, from the pull request's branch before main was merged into it: a 3 control plane +
  2 worker dev cluster to a provider-side zero in under three minutes, and a `prod`-labelled tfvars refused. Not run:
  OVH, Outscale, `PROVIDER=all`, and the typed id on a real cloud. `task cluster-down` stays two commands for
  everything else.
- **The replica of the state keeps dated generations (#267).** `<key>.<UTC stamp>` objects beside the current one, the
  newest five kept, written only for a state that holds the Talos secrets; `backup-state.sh --list` lists them and
  `task restore-state` reads one for a failover (`STATE_GENERATION=`). Rung: mocked (a fake object store); real stores,
  Scaleway's and OVH's S3 as replicas, listed and copied down 2026-10-06: the current object plus five keys, the newest
  byte-identical to the current object. Not run: a restore from a generation, Outscale's store as a replica.
- **Cléa offers a bump only once it is old enough (#263).** A release younger than `min_release_age_days` (7) is "too young,
  eligible on <date>", a yanked, draft, retagged or advised-against release is held with its reason, an age that cannot be
  read is never eligible, and Renovate carries the same `minimumReleaseAge`. Rung: mocked; then seen on a hosted runner
  in the scheduled scan of 2026-10-11 (`893a395`), which resolved upstream for real (PyPI, GitHub releases and tags,
  OSV) and held every bump behind upstream back as "too young, eligible on <date>", offering none. Not seen: a bump
  offered after its cooling-off, or a hold for any other reason (yanked, draft, retagged, advised against).
- **`cluster-verify` asks where the control planes sit, and whether the workers' data volumes exist (#38, #62).** Each
  provider module outputs `control_plane_zones` (a required contract row), read from each server resource in the state.
  Three control planes in one failure domain end red and the red line names the knob; a 2+1 split (Scaleway over two
  zones) warns, since losing the zone that holds two loses etcd quorum; a missing output is UNCHECKED, fatal, never a
  pass. Each worker's own Talos API is asked, through the first control plane's tunnel, for every `worker_storage` volume
  (`ready`, `luks2`); that needs `task tunnels-up`, and without a tunnel the volume and schematic checks warn instead of
  passing. Rung: mocked; real cloud 2026-10-03: the verdict read on Outscale (red in one subregion, green across three)
  and OVH (green across three zones), matching the provider's own listing; 13/13 on all three clouds with encrypted
  worker disks, the read-back named only for Scaleway, green and red (red: a volume the workers lack). Again at 893a395
  on all three clouds, 2026-10-10 and 11: three failure domains read as HA (Scaleway's over three zones) and every
  worker's volumes read back, `cluster-verify` 14/14. Mocked only: OVH's one-zone red (read from the config; whether OVH
  reads its zone back or echoes the config is unknown) and Scaleway's 2+1 warning (not deployed when the check landed).
- **`task cluster-up` grows a live cluster (#59).** The apply that created a node also waited on its Talos port, reachable
  only through a tunnel that cannot exist before the node. `scripts/bootstrap/grow-nodes.sh` now runs first: it creates
  the machines, opens the tunnels and configures only the nodes the state has no configuration for; a no-op on a fresh
  cluster. Rung: mocked; real cloud by hand, 2026-10-03 (Validated, Growth).
- **`task cluster-up` lands the versions its tfvars declare.** A bumped `talos_version` used to reach the machine config
  and roll no node, with an empty plan and `cluster-verify` green (11 passed, 0 failed, Scaleway 2026-08-21). The
  verifier now compares running versions with the pin (12 passed, 1 failed on that state; a fleet split between two
  versions reads MIXED, a roll stopped part way); `cluster-up` prints the roll (`converge-versions.sh --check`) before
  its approval question and rolls the fleet after the bootstrap; `cluster-upgrade` climbs one minor at a time from
  `version-support.json`, which now knows Talos 1.14 (Kubernetes 1.32 to 1.37). Rung: real cloud once, Scaleway
  2026-08-21: a seven-step climb from Talos 1.12.7 / Kubernetes 1.30.0 to 1.13.9 / 1.36.3, longest outage 5 s, and a
  `cluster-up` on a matching fleet that rolled nothing. Also real cloud, Scaleway and Outscale, 2026-10-05: `cluster-up`
  read a worker left on v1.14.1 under a v1.14.2 pin (`cluster-verify` red, `MIXED`) and rolled it to v1.14.2
  (Validated). Mocked only: a `cluster-up` that carries a minor climb; the measured climbs used `cluster-upgrade`.
- **`task cluster-up` adopts a bootstrap the state forgot (#67, #40).** An apply interrupted after the node accepted the
  Bootstrap call left no bootstrap in the state, and phase 2 sent it again to a live etcd, which refuses it.
  `adopt-bootstrap.sh` asks every control plane for `etcd members` and imports the bootstrap only if one answers with a
  member row; a fresh cluster pays up to 15 s per control plane. The import lands before phase 2's approval question and
  declining does not undo it (the script prints the `tofu state rm` that does). Rung: mocked; real cloud, Scaleway only:
  2026-10-02, a state lost to PR #223's defect (three etcd members found, bootstrap imported, `cluster-verify` 12/12,
  `cluster-idempotency` passed), and 2026-10-03, a `SIGKILL` right after the Bootstrap call. Not on OVH or Outscale.
- **`task cluster-upgrade` also measures a Service (#41).** A 2-replica workload behind a Service (with a PDB when two
  nodes can take it) is polled through the apiserver proxy for the whole roll; failed samples and longest outage are
  reported beside the apiserver's, and samples taken while the apiserver is down count apart as BLIND. Reported, not
  gated. Rung: mocked; real cloud 2026-10-03 on Scaleway, OVH (the `upgrade-k8s` step in `docs/upgrade.md`, the
  Flux/CNPG roll in Validated) and Outscale.
- **`task cluster-shrink-plan` then `task cluster-shrink` remove nodes from a live cluster (#249).** Two commands, like
  destroy: `PLAN=` is required and `APPROVE=auto` does not collapse them; the scope comes from the saved plan and is
  derived again at apply. A worker run may take several nodes, highest index first; a control-plane run takes exactly
  one, never in the same run as a worker; the cluster keeps at least one of each, and below three control planes it needs
  `-- --allow-below-ha` on both commands. Per node: Longhorn eviction (workers only), drain, `talosctl shutdown`, delete the
  Node, a targeted destroy of exactly that node's resources; a control plane also takes an etcd snapshot, hands leadership
  off and runs `etcd leave`; the run ends with `_backup-state` and `cluster-verify`. Refusals, mechanism and figures:
  `docs/upgrade.md`, Removing nodes. The closing step applies every pending machine-config update, so make a config edit
  separately. A lowered count through `cluster-up` is now refused (Fixed). Rung: mocked, the only rung of every refusal
  but Longhorn's two-replica one (a real cluster refused that too); real cloud 2026-10-04 (Validated).
- **`task restore-state` rebuilds a cluster on another provider from the replica the first one left (#57).** When provider
  A is gone its tfstate survives as the `-backup` replica on B's store, the only carrier of the Talos PKI and the etcd
  secretbox key. `task restore-state PROVIDER=<b> ROLE=failover FROM=<A's env name>` (the file under `envs/` without
  `.tfvars`, e.g. `management-<a>`) copies the replica to B's state key and untracks everything but the three state-only
  Talos resources, so `task cluster-up` builds a cluster that A's saved kubeconfig and talosconfig still open. It is a
  rebuild, not a restore: etcd contents and application data are not in the replica. It refuses a target that holds
  resources or whose state cannot be read, a replica that is its own target, a plaintext replica, a state with no PKI and
  a `talos_version` below the one the PKI was made for; from the upload on, any failure removes the copy again (a `kill
  -9` leaves it, and the next run refuses, naming the object). The replica is only ever read. A's env file is gitignored
  and in no store, so after losing the workstation it is rebuilt by hand (runbook:
  `infrastructure/opentofu/cluster/README.md`, "Cross-provider failover"). Rung: mocked; real cloud once, OVH to Scaleway,
  2026-10-05 (Validated). Not run: any other provider pair, three control planes, Talos discovery with a live A.
- **`node_nameservers`: DNS-over-TLS or -HTTPS for the nodes' own resolver (#173).** Opt-in. A list of `{address,
  protocol, tls_server_name}` is rendered as one Talos `ResolverConfig` appended to every node, plus a `TimeSyncConfig`
  `bootTimeout` (`node_dns_boot_timeout`, default `90s`) when a server is encrypted; unset, every node's config is
  byte-identical. A list that mixes encrypted and plain entries is refused (a plain entry beside an encrypted one fell
  back to plaintext on a local QEMU node, not on a cloud), and a change replaces the apply resources, all in one apply.
  **A list no node can reach is found only at the next reboot, and that node then has no Talos API**: replacing it is
  the recovery, `nc -zvw5 <ip> 853` from a pod is the check beforehand, and `cluster-verify` does not read the resolver.
  Rung: mocked; real cloud once, DoT on OVH, 2026-10-05, 1 control plane + 1 worker (Validated). DoH and plain Do53:
  rendered and `talosctl validate`d only, no node run. Not recorded: Outscale, three control planes, a cold first boot
  with the list set, the apply on Scaleway (only its egress was read).
- **The Talos tunnels keep what their ssh said, and `ensure` and a short `open` quote it (#65).** Every tunnel's ssh
  output went to `/dev/null`, so a tunnel reported up with no listener left nothing to read. Each ssh now appends its
  `LogLevel=VERBOSE` output to `.talos-tunnel-<port>.log` beside the pidfile (gitignored: it names the bastion, so
  redact it before pasting it anywhere public); `open` and `open-direct` quote the log of each port that did not come
  up, and `ensure` quotes each tunnel that does not answer and says whether its ssh still runs. A log says how an ssh
  ended, not who asked it to; the cause of the 2026-08-18 deaths is still unknown (the issue is closed as not reproduced).
  Rung: mocked; seen once on a real Scaleway bastion with 2 tunnels, on the first version of this change (after a TERM,
  `ensure` quoted the client's closing lines and rebuilt 2/2). Not seen: a drop by the bastion, a KILL, `open-direct`.
- **A manual real-cloud deploy, verify and teardown workflow, dormant until its secrets exist (PR #257).**
  `.github/workflows/real-cloud-regression.yml` (`workflow_dispatch` only, one provider or all three, a "these are
  sandbox accounts" box, the teardown and an account-clean proof under `if: always()`). Its prerequisites step names
  whichever secret is missing, and none of them exists in the repository. Secrets reach a step only through `env:`,
  `kubectl` is the cluster's own pin and checksum-verified, and Outscale is judged on its VMs and public IPs because of
  #43. Rung: mocked (each shell step lifted out of the YAML and run with fake secrets); **never run against an account**.
- **`task state`, `task purge-orphans`, `task talosconfig-new`, `task local-rbac`.** `state PROVIDER=… [ADDR=…]` lists what
  a cluster's state holds and tells an absent state from an empty one, read-only; `purge-orphans PROVIDER=… [APPLY=1]`
  is the command the release checklist already named and the repository did not have. `talosconfig-new` issues a
  role-scoped talosconfig with a TTL (`os:reader`, 8 h by default) from the admin one, which the deploy hands out as
  `os:admin` valid a year; it refuses to report success if the node grants other roles. `local-rbac` asks the Docker
  cluster whether Talos enforces those roles. Rungs: `state` mocked (no real listing recorded); `purge-orphans` mocked
  and emulated; real cloud, read-only dry runs after the teardowns of 2026-10-10 and 11 on all three clouds (Scaleway
  and OVH: nothing to purge; Outscale: only the stuck Net of #43 is targeted, exit 1 as expected; Fixed, teardown);
  `talosconfig-new` Docker lane, then real cloud once, OVH 2026-10-03; `local-rbac` Docker only (2026-08-24, Talos
  v1.13.3; not run at the shipped pin, #291).
- **`task cluster-up` refuses, before it spends, a never-applied `prod` cluster whose replica is on the primary's cloud
  (#57).** Only the verifier said so, after the apply; it is now also red on a prod replica in another region of the same
  cloud. A self-hosted S3 only has to be another endpoint; a cluster name that already has a state object is only warned
  (it may be live). Rung: mocked.
- **A changed `admin_ip` can be applied.** The documented remedy stopped at the tunnel check on a bootstrapped cluster,
  because the bastion no longer let this machine in, and the escape hatch lived in a Taskfile comment. The check is
  `scripts/internal/tunnel-guard.sh`; its failure names `OA_SKIP_TUNNEL_GUARD=1`, and `docs/admin-access.md` has the
  procedure. Rung: mocked; real cloud once, Scaleway 2026-10-04 (Validated).
- **`docs/capacity.md`: what a cluster needs, per provider (#72).** The sizing floor and its evidence, what each module
  creates, the totals and `preflight-quotas` flags of every shipped example
  but the two emulated-lane ones; derived figures marked apart from measured.

### Changed

- **Talos v1.14.2 and Kubernetes v1.37.1 are the default pin (#181).** Both roots move together; 0.1.0's cluster root
  was v1.13.9 and v1.36.3, its Docker root v1.13.3 and v1.35.3. Rung: real cloud on all three clouds, 2026-10-03, under
  provider 0.11 (next bullet). The Docker lane follows the pin, and did not boot at it on the two hosts tried (kernel
  6.12, #291). It booted once, with 1 control plane + 1 worker, on a hosted runner (Cléa's weekly lane, 2026-10-11); its
  recorded 3 + 3 run (2026-08-24) is at v1.13.9 and v1.36.3.
- **The Talos provider is pinned at 0.12.0, and the module renders a 1.14 node under the v1.13 config contract (#241,
  #44).** Provider 0.12 reads `talos_version` on the machine-configuration data source as the config contract, not as
  the node's Talos, and for a 1.14 contract renders Talos's multi-document config, which the module's v1alpha1 patches
  collide with (seven errors on every config apply, measured on OVH); 0.11 could not render that contract and silently
  gave the 1.13 shape. One local, `config_contract` (v1.13, or the node's own version when older), now feeds both data
  sources, so a 1.14 node's rendered config equals 0.11's (offline, real providers, no node). The cluster root and the
  local lane pin `0.12.0` exactly (no lock file is committed, so a range could change the rendered text unseen) and the
  module's ceiling is `< 0.13.0`. `replace_triggered_by` (upstream `siderolabs/terraform-provider-talos#352`, fixed in
  0.12.0) stays: no run without it has happened (#83). **Existing checkouts must run `tofu init -backend=false -upgrade` in
  `infrastructure/opentofu/cluster`** (Upgrade notes). Rung: mocked; real cloud, Scaleway, 2026-10-05, 1 control plane +
  1 worker, then 3 control planes + 2 workers on all three clouds, `cluster-verify` 14/14, and a 0.1.0 cluster climbed
  by `cluster-upgrade` on each, 2026-10-06, the fresh builds repeated at the shipped pin on 2026-10-10 (Scaleway, OVH)
  and 2026-10-11 (Outscale) (Validated; Known limits has what was not measured).
- **The image lane keeps one state per Talos version (#69).** Each version has its own state
  (`talos-image-<provider>-<version>.tfstate`), so a build touches only its own version: building v1.14.2 no longer
  replaces v1.14.1 (0.1.0 replaced it, silently, #93). `task image-build PROVIDER=<p>` takes `LIST=1` (the versions
  held), `PRUNE=1 VERSION=<v>` (destroy one, refused while a
  tfvars pins it) and `RETAIN=1` (next bullet). Images only: there is one cluster state, and a node built from
  an older image joins the same cluster. The image state takes no lock: one operator per lane, one run at a time per
  checkout. Rules and recoveries: `infrastructure/opentofu/talos-image/README.md`; the first-build migration and its
  refusals are in Upgrade notes. Rung: mocked; real cloud, 2026-10-05, Scaleway and Outscale (Validated; Known limits
  has what was not run).
- **`RETAIN=1` keeps the cluster's Talos version and the one below it, and `task cluster-up` offers it (#69).** With N
  the newest `talos_version` a tfvars pins, it keeps N and the highest version held below it and destroys the rest,
  lowest first, so a node can still be created on the previous image while the cluster runs N: on a cluster moved from
  1.14.1 to 1.14.2 it keeps both, after the move to 1.14.3 it destroys 1.14.1. A version above N and a version a tfvars
  names (`talos_version`, or an `image_name` or `talos_image_file_id` override) are kept; an `image_id` or an unreadable
  tfvars refuses the run. "Still needed" is judged from this checkout's `envs/*-<provider>.tfvars` only: a cluster
  whose tfvars is on another workstation is not asked, and with none present `PRUNE=1` only warns. `cluster-up` runs it
  after its `cluster-verify`, asks tofu's own yes for each image it destroys and only warns if it fails; **under
  `APPROVE=auto` it never prunes** (it prints the command), and `cluster-upgrade` does not run it, so run it by hand
  once a climb is verified. Rung: mocked; real cloud, 2026-10-05, Scaleway and Outscale (Validated).
- **`task cluster-up` ends with `cluster-verify` and fails when it does (#84).** It used to print "complete" without
  asking the cluster, so a red cluster exited 0; `cluster-idempotency`, which runs `cluster-up`, now ends non-zero on a
  red verifier (`cluster-upgrade` already did in 0.1.0). Rung: mocked; seen red on a real Scaleway cluster, 2026-10-02.
- **Outscale spreads its nodes over the subregions listed in `availability_zones` (#58).** It read only the first entry,
  so three control planes shared one subregion. It now builds a private subnet per entry and places control planes and
  workers by index, a worker's data volumes in its node's subregion; the public subnet, bastion, NAT and load balancers
  stay in the first subregion (a load balancer takes one subnet, measured) and reach every node. A node's subnet is
  ignored after creation: **a cluster built before this keeps its layout and ends red, and no setting clears it**; so
  does a one-entry list. Rung: real cloud 2026-10-03 for the new layout (three control planes in three subregions,
  13/13, the load balancer UP on all three); the red was seen on the old module, 2026-10-03 (12 passed, 1 failed), the
  kept layout is the mocked plan's reading, and the new module has not been applied live over an old cluster.
- **OVH examples and defaults name availability zones OVH accepts (#72).** They said `["nova"]`, which Nova tolerates and
  Cinder rejects on EU-WEST-PAR, so the first apply died creating the workers' data volumes. Now `eu-west-par-a/b/c` in
  the examples, the cluster default and the module default. Rung: mocked for those; the three zone names deployed and
  verified 13/13 on a real OVH account, 2026-10-03, through a private tfvars, so the shipped defaults never ran.
- **Examples.** The Scaleway examples move to `POP2-4C-16G`, the sizing floor (0.1.0 shipped `POP2-2C-8G` and, for the
  workload one, `DEV1-M`, absent from `fr-par-3`), and stop pinning an image the lane no longer holds. Outscale stays at
  `tinav5.c2r4p1`, below the floor on purpose (the floor on five nodes plus the bastion is 22 vCPU against a default
  quota of 20): a bare cluster only, deployed and verified 2026-10-03 (`docs/capacity.md`). The examples that hard-pinned
  Talos v1.13.3 and Kubernetes v1.35.3, a pair no recorded cloud run used, now inherit the default pin.
- **The Docker lane is not a provider, and says so.** The cloud tasks (`cluster-*`, `infra-*`, `image-build`, `tunnels-up`
  and the rest) refuse `PROVIDER=local`: `cluster-up`, `cluster-down`, `cluster-upgrade`, `cluster-idempotency`,
  `image-build` and `teardown-all` with a message naming the family that applies, the others on the credential resolver's
  `unknown provider 'local'`; `task local-verify` exists because `cluster-verify PROVIDER=local` is refused.
  `K8S_API_PORT` moves the host port 6443 (a WSL2 reserved range made `local-up` unrunnable); `local-up` refuses in about
  a second on a host where `capsh` shows no `CAP_SYS_RESOURCE` (silent without `capsh`) instead of hanging 90 s;
  `local-down` runs on a clone with only this repository; `opentofu-local` pins what the cloud root pins; `task
  local-test` now fails when workers never become schedulable or Flux never comes up, where it printed "validated
  end-to-end" regardless (no run of either failure is recorded). Rung: local Docker 2026-08-24, default 3+3: six nodes
  Ready, Cilium 6/6, `local-verify` 6/6; the `PROVIDER=local` refusals: mocked (`task --dry`).
- **Provider contract, for module authors.** `control_plane_zones` is a required output, and a new rule 5 (scale-in)
  says how a node's resources must be indexed and named for `shrink-nodes.sh`. The contract's tables are
  executed by `check-provider-contract.sh`, by name and type (it required a `bastion_ssh_key` string no module declares;
  all four declare `bastion_ssh_keys`), and `tofu validate` now fails on a missing contract output where it answered
  `Success!` (`try()` could not tell an inactive provider from a missing attribute). Rung: mocked.
- **Decisions written down (#82, #56, #70, #80, #172), and `flux_namespace` validated.** The bastion stays, hardened in
  place; revisit with two or more operators, or a stateful service whose restore has been run. Outscale has no state lock
  by design: one operator at a time. `talosctl upgrade-k8s` measured no gentler than the config-driven Kubernetes step,
  which stays. For read-only work, mint one `os:reader` talosconfig by hand and reuse it until it expires rather than one
  per run (#80); the tasks still default to the admin one. `flux_namespace` must be `flux-system`, the only namespace the
  vendored Flux install creates. Steering traffic between two live clusters is health-checked DNS from a zone that shares
  no fate with either, not BGP or anycast across providers: none of the three documents a customer BGP peer or prefix for
  a VM (vendor pages read 2026-10-04). Not evaluated: a customer-operated router reaching each cloud over InterLink or
  DirectLink. DNS failover time (check interval times threshold, plus the TTL) is not measured.
- - **The examples and the default pin OpenAether-apps at its tag 0.1.0.** The twelve `envs/*.tfvars.example` that carry a
  `git_ref` (the two `feint-*` examples carry none) and the `git_ref` default in `variables.tf` now say `refs/tags/0.1.0`,
  so an apps commit cannot change a cluster that follows them; `refs/heads/<branch>` is how to develop against apps
  (Upgrade notes). The apps tag asserts only the static gates: its `CHANGELOG.md` says what it does not, and `task
  apps-validate` (Cilium parity between the foundation here and the CAPI children there, skill parity, the Flux DAG) is
  the check between the two. Flux is off by default and no validation leg of this release turned it on, so no cluster of
  this release has followed that tag. Rung: mocked (example values, a variable default and documentation); Cilium parity
  and the Flux DAG were run against a checkout of the tag.
- **Dependencies, final values (pins):** OpenTofu 1.13.1, Talos provider 0.12.0 (above), Cilium 1.20.2 (0.1.0 shipped
  1.20.0; the manifest is re-rendered; the cloud legs of 2026-10-10 and 2026-10-11 deployed it (`cluster-verify` counts
  Cilium running on every node), none of them isolates the bump), flux2 2.9.6 (the vendored install refreshed and its
  controller digests recorded for the first time (`task check-flux-digests`); it reaches only a `deploy_flux=true`
  cluster, which no lab sets), helm 4.3.0, flux-schema 0.15.0, go-task 3.54.0, `kubectl-cnpg` 1.30.1, gitleaks 8.30.1,
  plumber 0.5.20, commitizen 4.19.1, yamllint 1.38.0, Feint 0.13.0, and in `setup.sh` kubectl 1.37.1, aws-cli 2.37.9,
  checkov 3.3.22 and pre-commit 4.6.2; the pre-commit hooks lag (commitizen v4.9.1, yamllint v1.35.1). A workstation's
  `talosctl` is pinned, checksum-verified and taken from the cluster's own `talos_version`. Rung: mocked; the pinned
  binaries were installed and run, with no cloud, and `setup.sh` ran to the end in a bare `ubuntu:24.04` container with
  all five of its newest pins.
- **Maintainer tooling; mostly nothing an operator types.** `task evidence-check` goes red when a provider's newest
  `docs/status.md` row is not at the pin, is older than 45 days (`OA_EVIDENCE_MAX_AGE_DAYS`) or carries a ❌ or ⚠; it is in
  neither `task lint` nor `task test`, and `task preflight`, which an operator does type, runs it with `--warn` (a stale
  row warns, an unreadable table fails). Gates that were green on something they had stopped checking now fail:
  `render-check` offline (`RENDER_CHECK_ALLOW_OFFLINE=1` is the deliberate way around, and `preflight` then says
  INCOMPLETE), `tflint` skipping most directories, a typo in a Cilium `--set` flag (#112). Cléa (`docs/clea.md`) probes
  each pinned bump from cold in a bare container and never reaches a cloud; its push-token and `action-sha` fixes are not
  yet seen on a runner (#91). Cléa's lane exports `VERSION`, which made `test-talos-image.sh` fail in every probe until
  the harness defined its own environment (#286; mocked, no Cléa run has shown a verdict since, and whether the lane
  should stop exporting it is open). For contributors: rung receipts let CI check a pull request's declared rung (`task
  receipts`), the hand-kept backlog file is gone (tasks are GitHub issues, "where we stand" is `docs/status.md`) and
  `Assisted-by:` is a tool-only trailer with no model version. The rest is in `task --list-all`. Rung: mocked, each gate
  reproduced in both directions.

### Validated

Measured by hand on real accounts. Dates and figures come from `docs/status.md` and `docs/upgrade.md`, and, for the
passes of 2026-10-06 to 2026-10-11, from the maintainer's step records, kept outside the repository; control-plane
growth and the plan-only refusal from `docs/deployment-test-matrix.md` (growth also `docs/first-cluster.md`); the
changed `admin_ip` from `docs/admin-access.md`; the lock refusals from `docs/release-checklist.md`; the failover and the provider pin from
`docs/status.md`; the node resolver from the matrix and PR #268; the image lane's runs from the message of PRs #269 and
#272 only. Versions were read from the kubelets and each node's own Talos API, never from the tool that performed the
upgrade. A longest outage is the longest run of consecutive failed one-second probes.

- **The release code (`893a395`) on all three clouds, 2026-10-10 and 2026-10-11, each from an empty state under a fresh
  `bucket_suffix`, 3 control planes + 2 workers, at the shipped pin (Talos 1.14.2, Kubernetes 1.37.1, provider 0.12.0).**
  Scaleway over the example's three zones, OVH over `eu-west-par-a/b/c`, Outscale into a fresh Net over three subregions.
  On each: `cluster-up` (Scaleway 650 s, OVH 545 s on its first deploy, Outscale 1661 s, about 15 minutes of it the image
  build); `cluster-verify` 14 passed, 0 failed, 0 could not be checked, with the control planes read in three failure
  domains and every worker's encrypted data volume read back from its node; `cluster-idempotency` with the same nodes and
  no control plane rebooted; the lab's health suite (every node Ready, every pod healthy, a Service reachable from every
  node, DNS, egress, a NetworkPolicy that allows and denies, Cilium) 14 ok, 0 failed; a stand-alone `task etcd-snapshot`,
  encrypted, written to both buckets; `backup-state`, the encrypted state replicated to another cloud's store (Scaleway's
  to OVH's, OVH's and Outscale's to Scaleway's); an empty strict plan; the pinned schematic on every control plane; then
  the two commands of `task cluster-down` (52 resources in the plan on Scaleway, 62 on OVH, 64 on Outscale) and the
  provider's own answer. Scaleway: `purge-orphans` clean and `verify-provider-clean` rc 0. OVH: `purge-orphans` clean on
  its first pass; the `openstack` mode of `verify-provider-clean` was not run. Outscale never reads clean (#43):
  `verify-provider-clean` rc 0 (no VM, no unassociated public IP), the `purge-orphans` dry run exit 1 with only the stuck
  Net and what hangs on it, the run's own Net gone. Rung: real cloud, once per cloud (OVH twice), the repository's tasks
  and scripts called stage by stage by a maintainer's lab script that stops at the first red; the script and the health
  suite are outside the repository. Not run: OVH's one-zone red, read from the config only. An earlier pass on
  2026-10-06, on older commits, is superseded by this one.
- **OVH, 2026-10-10: two deploys and two teardowns in a row in one project; the second met #49 at first boot.** The first
  ran as above. The second stopped at its first `cluster-up`: phase 2 waited 900 s for control plane 2's Talos API and
  ended 201 after 1349 s, the other two answering. Nova said all three servers `ACTIVE`, power state 1, and the console
  showed no kernel message; the node stayed silent from the first seconds of its first boot for about twenty minutes. This
  is the situation of #49, again: the first OVH deploy of 2026-10-06 (`21c4a73`) ended the same way, at control plane 1. A
  Nova hard reboot of that one server, the hypervisor reset #49 prescribes, brought its Talos API up 5 s later; the same
  command resumed (326 s on the partial state) and every stage above then passed, `cluster-idempotency` with no control
  plane rebooted since the reset. No defect of the repository is shown and no cause: #49 stays open, blocked on the
  provider, with one more occurrence. Both teardowns ended `purge-orphans` clean on the first pass: the second teardown
  the release checklist asks for.
- **Outscale, 2026-10-11, into a fresh Net.** The first attempt, the evening before, stopped after 37 s at the image
  build, before an image, a snapshot or a machine existed: the account held an image of the pin's name that no state
  tracks (made 2026-10-03, untagged), and the plan would have created the same name, which Outscale refuses after the
  snapshot import. The same-name gate refused it. On the account owner's go, that one image and its one snapshot were
  deleted (checked by id, name and mapping first), the account's other images untouched; the second attempt rebuilt the
  image and ran as above in one `cluster-up`, `cluster-verify` 14 of 14 with three control planes in three subregions (a
  cluster built before #58 ends 13 of 14, by design). The pass of 2026-10-06 had needed several runs (transient API
  errors, and the same gate). Left standing, on purpose: the stuck Net of #43 and the three Talos images the lane keeps
  (v1.13.8, v1.14.1 and the rebuilt v1.14.2).
- **0.1.0 to this release, 2026-10-06, on `2f8bd02`, `task cluster-upgrade` through the same lab script, versions unset
  in the tfvars.** Each started from a cluster built by the 0.1.0 tag (3 control planes + 2 workers, under Talos
  provider 0.11); the climb ran under 0.12.0. Talos 1.13.9 to 1.14.2 and Kubernetes 1.36.3 to 1.37.1 on 5/5 nodes, read
  from the nodes. **Scaleway and OVH in one uninterrupted run** (1064 s and 962 s): `cluster-verify` 14/14, no control
  plane rebooted by the `cluster-idempotency` after it, the health suite 14/14, an empty strict plan, then teardown
  (Scaleway: `purge-orphans` clean and `verify-provider-clean` rc 0; OVH: `purge-orphans` clean). Through the load
  balancer, probed at 1 Hz: Scaleway `/readyz` 18 failed of 1056, longest run 3 s; OVH 6 of 956, longest 3 s. **Outscale
  was not one run:** the first apply modified the bastion in place and the run stopped on its dead tunnels (Upgrade
  notes); the same command resumed and converged, `cluster-verify` read 13 of 14 (the red line is the single-subregion
  verdict, Upgrade notes), the health suite 14/14, the strict plan empty, then teardown (`verify-provider-clean` rc 0; the
  `purge-orphans` dry run listing as many targets as the stuck Net of #43 holds, their ids not kept). Its interruption is
  the worst measured (Known limits). Before the four fixes under Fixed, none of these climbs completed: the first
  Scaleway attempt replaced the private network (16 to destroy, the API unreachable on every backend for 68 s), OVH's
  lost its tunnels with a replaced bastion, and a plain `cluster-up` was refused by the nodes four minutes into the
  apply. Outscale's climb on `2f8bd02` was not one clean run, and the idempotency re-run was not asserted there (its
  verify is red by design). **No climb was re-run on `893a395`.** Its apply path is `2f8bd02`'s, read in the diff and not
  re-run: no module of Scaleway, OVH, Outscale or Talos, no `.tf` of the cluster root beyond a comment and an output
  description, and the scripts that `cluster-up`, `cluster-upgrade` and `infra-apply` run changed only by a diagnostic
  paragraph added to `explain-failure.sh`, a helper added to `scripts/lib/common.sh` and a task name added to the receipt
  writer. The diff also adds `task teardown-all`, the Proxmox VM bastion's user and PyYAML in `setup.sh`.
- **Scaleway, 2026-10-02 and 2026-10-03, each from an empty project under a fresh `bucket_suffix` (#68).** The first:
  `cluster-up`, `cluster-verify` 12/12, two `cluster-idempotency` passes; the Talos step rolled six nodes with the
  apiserver failing 6 times in 474 probes, longest 1 s; the Kubernetes step stopped on a defect of ours (PR #223, Fixed),
  and `adopt-bootstrap` plus a plain `cluster-up` brought the state back, after which the fleet read 1.37.1 everywhere
  (whether that run rolled anything is not recorded). A control plane powered off for 80 s cost 3 failed
  probes in 360 and a write succeeded. Torn down and proven clean that night. The second, with encrypted worker disks, a
  Longhorn volume and a Service probe: `cluster-upgrade` 1.13.9 / 1.36.3 to 1.14.2 / 1.37.1 in place on 6/6 nodes,
  `cluster-verify` 13/13, `No changes.` after. Longest outage 2 s (6 failed in 764, Talos step; 9 in 805, Kubernetes
  step); the Service failed 0 times, a blob written before the climb read back with the same hash, the stateful pod was
  gapped 20 s and 16 s. The roll stopped once on PR #229's defect (Fixed). On the pair #181 names (Talos 1.14.1,
  Kubernetes 1.37.0) the same day, Longhorn was written, read from other workers and across a node reboot, and the worker
  volumes read back by `cluster-verify`.
- **OVH, 2026-10-03.** 3+3 across `eu-west-par-a/b/c`, encrypted worker disks, `cluster-verify` 13/13. Kubernetes 1.36.3 to
  1.37.1 through `talosctl upgrade-k8s` (#70), 10 s (11 failed in 430), then the pin; plan empty after the climb and
  after the pin. Its Talos step, 1.13.9 to 1.14.2 on 6/6 nodes, was the roll with Flux and CNPG below.
- **A roll with Flux and CNPG, OVH, 2026-10-03 (#64).** A lab, not a `deploy_flux` cluster: the vendored Flux controllers
  (v2.9.3, the vendored install until 2026-10-05), the CNPG operator 1.23.1 and local-path storage installed by hand, a
  three-instance CNPG cluster owned by a Flux Kustomization. `cluster-upgrade` took Talos 1.13.9 to 1.14.2: before every
  node the roll suspended the Kustomization and the CNPG budget, and at the end of each of its two rolls it checked both
  were restored (longest outage 1 s, 3 failed in 583; the Service 3 failed and 3 blind in 621). The surrounding
  `cluster-upgrade` exited 201, because its closing `cluster-verify` found `flux-system`; `cluster-verify` read 13/13 only
  after the lab was removed.
- **Outscale, 2026-10-03.** 3+3 `tinav5.c2r4p1`, encrypted worker disks, `cluster-verify` 13/13, 6/6 nodes to Talos 1.14.2
  and Kubernetes 1.37.1, `No changes.` three times, one after the climb. Longest outage 9 s (68 failed in 1535: 3 s on
  the Talos step, 9 s on Kubernetes); the Service probe failed 40 times with 20 blind samples in 1490, longest 3 s.
- **Growth, 2026-10-03.** Scaleway workers 3 to 6, one worker per `task cluster-up`, three runs in a row (3 to 4 to 5 to
  6), each ending `cluster-verify` 13/13. After those three the following full plan was not empty (`0 to add, N to
  change`, N one fewer than the worker count; not investigated); the 2026-10-04 grow-back ended with
  `cluster-idempotency` passed. Control planes 1 to 3: Outscale by one `cluster-up` (three control planes and two
  workers, 13/13, the load balancer UP on all three); Scaleway and OVH are recorded as 1 to 3 only. Worker growth on OVH
  and Outscale is not recorded.
- **Removing nodes, 2026-10-04**, on each cloud's 3-control-plane cluster at Talos 1.14.2, Cilium only: a worker, then a
  control plane (3 to 2). `cluster-verify` green after every run (13/13 after a worker, 12/12 after the control plane,
  which reads `~ NOT HA` at two), etcd with exactly the members left, the provider's API listing exactly the machines
  left. Each control-plane run took an etcd snapshot, encrypted and uploaded to both buckets, before the leave. During
  the control-plane removal the load balancer kept sending one request in three to the member that had left etcd, for 40
  to 76 s (12 to 13 failed `/readyz` per cloud; the figures and what they do not separate are in `docs/upgrade.md`); a
  client that retries does not see them. Worker removals: Outscale 1 failed probe of 215, OVH none (bar the probe's own
  kubeconfig read), Scaleway not probed. Scaleway was grown back to 3+2 by one `cluster-up`: 13/13,
  `cluster-idempotency` passed. On that cluster only: Longhorn 1.13.0 moved a sole replica to the worker that stays
  before the drain (the volume stayed healthy and attached, its blob's checksum held) and refused a volume wanting two
  replicas at `--plan`; CloudNativePG 1.30.1, on one control plane and two workers, moved a replica on the departing
  worker with its volume (1000 rows on both instances, the budget and the maintenance window restored) and, with the
  primary on the departing node, failed over to the replica on the other worker (of 368 inserts sent once a second
  through the read-write service 2 failed, a run of 2 s, and none acknowledged was lost). The refusal of a lowered count
  ran plan-only on two real Scaleway shrink plans, 2026-10-03: both refused.
- **An interrupted bootstrap, Scaleway only, 2026-10-03.** `cluster-up` interrupted twice on purpose in phase 2: tunnels
  killed before the bootstrap call (a plain re-run resumed), then `SIGKILL` right after it (`adopt-bootstrap` found 3 etcd
  members and imported it). The stale state lock that kill left needed `tofu force-unlock`, which `explain-failure.sh` now
  names, with the holder, and says to check that run is really gone first.
- **The reader talosconfig, OVH only, 2026-10-03.** `TALOSCONFIG=<os:reader file> task cluster-verify` passes 13/13 through
  the tunnels while `talosctl get machineconfig` is refused. Mint one and reuse it until it expires.
- **Lock behaviour.** Scaleway refused a second `plan` by name (2026-10-02, #56); OVH refused the second run (HTTP 412,
  undated); Outscale holds no lock by design and none appeared while an apply waited (re-measured 2026-10-03).
- **A changed `admin_ip`, Scaleway, 2026-10-04.** Set to an address that is not ours (SSH to the bastion timed out); the
  plain apply stopped at the tunnel check; `OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true` applied in under four
  minutes, SSH worked again, `cluster-verify` 13/13. Not run on OVH or Outscale.
- **A failover, OVH to Scaleway, 2026-10-05 (#57).** A = OVH (1 control plane + 1 worker, `environment = prod`) with its
  replica on Scaleway's store; B = Scaleway (1 + 1) with its replica on Outscale's; both under one fresh
  `bucket_suffix`. A reached `cluster-verify` 13/13 and was destroyed in the two commands. In a shell holding only B's
  and Outscale's keys, `restore-artifacts` read A's kubeconfig and talosconfig back byte-identical from the replica,
  `restore-state` put A's PKI in B's state key, and B's `cluster-up` ended on `cluster-verify` 13/13 with an empty
  strict plan. A's saved kubeconfig listed B's nodes Ready and A's talosconfig answered on B's control plane; A's stores
  were unchanged afterwards. Both purges were clean. The drill found `image-build` ignoring `ROLE=` (Fixed) and left its
  buckets on the three accounts for their owner.
- **The image lane, Scaleway and Outscale, 2026-10-05 (#69),** at 1 control plane + 1 worker, Talos 1.14.2. The legacy
  state was copied to its version's key (`No changes`, nothing rebuilt) and a second version built beside it. A worker
  created with an `image_name` override naming v1.14.1 booted that image, joined Ready on v1.14.1 and stayed on it;
  `cluster-verify` read the fleet `MIXED` (red), and with the override removed `cluster-up` rolled the node to v1.14.2
  and the verifier read green. `PRUNE=1` destroyed v1.14.1 and left the other versions untouched. Outscale's same-name
  gate refused a build of v1.13.8, an OMI of the account's that no state tracks, in 13 s with the snapshots unchanged;
  it asks the account (`ReadImages`) because the provider's `outscale_images` data source fails a whole plan on a name
  nobody holds, which the mocked provider hid.
- **Image retention, Scaleway and Outscale, 2026-10-05 (#69).** With a second tfvars pinning v1.14.0, `RETAIN=1` kept it
  and destroyed nothing; with that file gone it destroyed v1.14.0's images and snapshots, the provider's own listing
  agreed (the untracked v1.13.8 OMI on Outscale untouched), and a second `RETAIN=1` said `nothing to destroy`.
- **The Talos provider 0.12.0, Scaleway, 2026-10-05 (#241).** 1 control plane + 1 worker, Talos 1.14.2. A cluster built
  under 0.11 planned empty under the pin and `cluster-up` changed nothing (`cluster-verify` 12/12); rebuilt from an
  empty state under 0.12.0, it ended on `cluster-verify` 12/12 with `cluster-idempotency` green. Inside the 1.13
  contract 0.12.0 had already run on OVH and Outscale (a fresh deploy and a bump 1.13.9 to 1.13.11, 13/13, plan empty
  after). At the shipped pin it has since run with three control planes: the climb from a 0.1.0 cluster on all three
  clouds (2026-10-06) and a deploy from empty on all three (2026-10-10 and 2026-10-11), both above.
- **The node resolver, OVH, 2026-10-05 (#173).** 1 control plane + 1 worker, Talos 1.14.2. Unset planned empty; setting
  the list replaced both `talos_machine_configuration_apply` with no "inconsistent final plan" (upstream #352),
  `cluster-up` applied it with no reboot and the strict plan was empty after. Both nodes resolved over DoT (a capture
  during image pulls showed tcp/853 and no udp/53), pods resolved names with a DoT-only list, and a healthy worker
  reboot was Ready in 47 s. A list no node can reach: the rebooted worker never started its Talos
  API (port 853 unreachable) and was still NotReady after 10 minutes with the 90 s bound in place; only replacing it
  recovers it.

### Fixed

- **The Proxmox VM bastion's user is `bastion`, not the image's `ubuntu` (PR #285).** cloud-init ignores a second
  definition of a user the image already has, so `ubuntu` would never join `bastion-admins` and sshd would refuse the key
  (measured on OVH). One local feeds the VM and the output. Rung: mocked; never applied on a real Proxmox host.
- **A bastion change under the Talos tunnels is explained (#65).** When an apply modifies, replaces or stops the bastion and
  the config applies then fail on refused tunnel ports, `explain-failure` says the change landed and that re-running is the
  fix. The apply still kills the tunnels (Upgrade notes; #288). Rung: mocked, the pattern checked against the real Outscale
  transcript; no real run is recorded where `explain-failure` said it.
- **Upgrading a 0.1.0 cluster to this release, found by running it on real clouds (PR #280, refs #79, #81, #278, #279).**
  Four defects stood between `git pull` and a working upgrade. A Scaleway network built under 0.1.0 had its subnet
  replaced by the new pin, and every private NIC behind it. The shared bastion cloud-init had four comment lines edited,
  which replaced the bastion on OVH mid-apply and killed the Talos tunnels (the default render is 0.1.0's bytes again, and
  a test pins its hash). `task cluster-up` pushed a Kubernetes pin the running Talos refuses, four minutes into the apply
  (`converge-versions.sh` now stops before the plan and names `task cluster-upgrade`). `cluster-upgrade` left the axis
  that does not move at the shipped default, so its first step did the same (it pins that axis where it runs). **To
  upgrade: `task cluster-upgrade`.** Rung: mocked for each guard (the Scaleway one pins two lines of HCL; no mocked plan
  shows a replacement), each removed once to see its test go red; real cloud: Scaleway and OVH climbs (Validated), the
  bastion fix observed on OVH only (Upgrade notes for Outscale).
- **Two more defects the validation hit, both in our own code: a check and the image lane.**
  The replica check of `cluster-verify` read
  `aws s3 ls | grep -q` as "not found" when `grep` exited first under `pipefail` (PR #275), and the Image Factory request of
  the image lane had no retry and failed the plan on one failed request (PR #276, up to four retries now). A test that
  captured output into
  `grep -q` through a pipe failed once the same way (PR #284); the harnesses use here-strings now. Rung: mocked; PR #275's
  fix was also run six times each way on a real replica (2 of 6 failed piped, 0 of 6 once captured). Not shown: that
  PR #276's retry rescues a real failed request (the failure was not reproduced on demand).
- **Lowering `control_planes` or `workers` destroyed the highest-index machine and its data volumes, with no drain, no
  etcd leave and no Node delete, and nothing said so.** `cluster-up`, `infra-apply` and `grow-nodes.sh` now stop on a plan
  that deletes a node of a bootstrapped cluster (`grow-nodes.sh` allows creates only), and `node_distribution` is
  refused when an entry has workers and no control plane (PR #246). Removal has its own commands (Added). Rung: mocked;
  two real Scaleway plans refused, plan only.
- **The roll deadlocked on Longhorn when it had as many replicas as workers (PR #229).** It waited for Longhorn to be
  healthy before uncordoning the node it had just rebuilt, but Longhorn puts no replica on a cordoned node, so the 600 s
  gate ran out. The node is uncordoned first. Rung: mocked; real cloud once, Scaleway 2026-10-03: found there (healthy 63 s
  after a manual uncordon), then the resumed `cluster-upgrade` ran the new order on two workers, the gate passing, rc 0.
  Not measured: a volume with fewer replicas than workers, where the old order also passed.
- **A roll exits 1 and names what is left when a Flux Kustomization is still suspended or a CNPG budget is missing
  (#64).** The exit trap restored them and nothing looked afterwards. The roll now waits (about two minutes, up to 211 s
  with the apiserver down; `RESTORE_TIMEOUT`, `RESTORE_POLL`, `RESTORE_REQUEST_TIMEOUT`), and a failed owner-label read
  refuses the roll on the way in. Ctrl+C ends the wait (exit 130); a roll stopped between nodes says so instead of
  "complete". The verdict comes after the last node is replaced, so do not re-run replacement mode to clear it (it
  replaces every node again): fix what is named and run `scripts/ops/backup-state.sh`, which `task cluster-roll` then
  skips, while `cluster-upgrade` stops between its two rolls. Rung: mocked; one real roll, the OVH lab above, green path
  only. CNPG 1.23.1 creates `<name>-primary` for a one-instance cluster (local Docker, scratch script, no receipt); a real
  cloud saw only three instances. Not observed: the failure branches on a real cluster (a Kustomization that stays
  suspended, a budget the operator never re-creates), a real Ctrl+C, and the two task effects (mocked only).
- **A size change through `cluster-roll` resized every node at once (#51, PR #222).** Scaleway 2026-10-02: with
  `instance_type` raised, `-- --workers-only` replaced worker 0 and its config step resized all three control planes, the
  API down 56 s. The roll now plans both steps before the cordon and refuses a plan that changes another node; a size
  change goes one node at a time, in place, 1 s blips (`docs/upgrade.md`). Rung: mocked; the refusal was seen at worker 0
  on that cluster, from an uncommitted pre-review tree. A resize is in place on every provider: measured on OVH
  (2026-08-15) and Scaleway (2026-10-02); Outscale and Proxmox from provider source and an offline plan.
- **`infra-plan` and `infra-apply` read an unreadable state as "no bootstrap" (PR #223).** On any read failure (an S3 error,
  a bad credential) a bootstrapped cluster's node counts were zeroed and its bootstrap, machine configs and kubeconfig
  dropped from the state; a live Scaleway upgrade ended that way on 2026-10-02, and `adopt-bootstrap` plus a plain
  `cluster-up` brought it back. It now answers only when the state is read or absent. Rung: mocked; against that cluster's
  state the helper answered true, a wrong secret key made it stop quoting OpenTofu's error, an absent state read as
  absent. Why the original read failed is not known.
- **A state that lost its Talos secrets is refused, and the teardown plan replicates the state before it untracks them
  (#66).** `task infra-down-plan` takes `talos_machine_secrets` out of the state to compute a destroy plan
  (`prevent_destroy` is a plan-time check), and so does `tofu state rm` by hand. Declining the destroy left nodes that
  trust a PKI the state no longer held: the next `cluster-up` minted another and every Talos call ended in `x509:
  certificate signed by unknown authority` while Kubernetes stayed healthy. Now `bootstrap-in-state.sh` refuses, before
  any plan of `cluster-up`, `infra-plan`, `infra-apply`, `cluster-roll` and `cluster-shrink`, a state that holds the
  bootstrap, a machine config or the kubeconfig without the secrets; `backup-state.sh` refuses to replicate it, so the
  replica stays the undo; `infra-down-plan` replicates first and never blocks a teardown. The cluster README's "Lost the
  Talos secrets" gives two recoveries. Rung: mocked; real cloud, Scaleway and OVH, 1 control plane + 1 worker,
  2026-10-04 and 2026-10-05: the symptom, the refusals and the recoveries (both on Scaleway; recovery 2 on OVH, the
  provider of the original incident). At the merged head the happy path ran for real in the teardowns of 2026-10-10 and
  2026-10-11 on all three clouds (the state replicated to another cloud's store, the secrets untracked, the undo
  printed); the refusals by `backup-state.sh` and the `cluster-roll` guard are mocked only (Known limits has what was not
  seen).
- **`restore-artifacts` read the wrong replica, and `image-build` ignored `ROLE=` (#57).** A replica on another cloud
  was opened with the cluster's own key, or not at all: the replica's keys were looked up without its endpoint, the
  bucket was named from `--role` (which picks the file) instead of the file's `cluster_role`, the last quoted string of
  a tfvars line became the replica endpoint (the `"dev"` of an inline comment), and every fetch error read as "not
  found". The `image-build` task never told the script which role it served, so on a machine holding only a failover
  file the lane looked for `management-<provider>.tfvars` and fell back to the shared `openaether` bucket namespace, a
  name another customer may own; the failover cluster could not be created. Rung: mocked; the `image-build` defect was
  found by the real failover drill (Validated), which also ran the fixed `restore-artifacts` on real stores (PR #271).
- **The roll applied a plan other than the one it counted (#55), and missed a worker's data disk (PR #247).** Each per-node
  apply now plans to a file, counts deletes from it and applies it. `node_targets` matched `worker_data[<n>]` where OVH's
  attach and Outscale's link resources are keyed `"w<worker>-d<disk>"`, so a replaced worker lost its data disk until the
  next full apply (inferred from the graph, not run). Rung: mocked for both. #55's change merged 2026-09-26 and the
  receipts of the real rolls of 2026-10-03 on Scaleway and OVH are from heads that contain it, and #55 closed on a real
  Scaleway roll of 2026-10-02 (three workers replaced one at a time, each plan saved and counted before its apply, rc 0).
  PR #247's OVH and Outscale attach and link targets have never run on a real cloud (the 2026-10-03 climbs were in-place
  `--upgrade` rolls, which keep the node's disk).
- **`task cluster-upgrade` could not upgrade Talos, and could read another cluster's fleet (#181, PR #200).** It built
  the image before moving `talos_version`, and the image lane then refused to build while any tfvars pinned another
  version. It now moves the pin first (a failed build leaves it at the target and the previous image untouched, and the
  message says how to put the pin back) and fetches its own kubeconfig, not whichever cluster wrote the shared one last.
  Rung: mocked; the 2026-10-03 climbs on all three clouds ran in this order, on the single-image lane #69 replaced.
- **`cluster-roll` rolled the management state whatever `ROLE=` said (PR #37).** `cluster-upgrade ROLE=workload` applied the
  workload tfvars and then rolled the management cluster; both now follow `ROLE=`. Rung: mocked; the workload role has no
  real-cloud run.
- **`task upgrade PROVIDER=x DRY_RUN=1` started a real upgrade (PR #218), `UPGRADE_TALOS_TO` and `UPGRADE_K8S_TO` on the
  command line were ignored too; `task cluster-up` checked the passphrase after creating the buckets (PR #217) and
  advertised a `VERSION=` it ignored.** A Task variable is not an environment variable, so the script never saw them; the
  target now passes all three on; the passphrase check runs first; the tfvars pin decides the version. A dry run also
  leaves no rung receipt. Rung: mocked.
- **`etcd-snapshot.sh` retention deleted almost everything while a cluster had the fewest snapshots (PR #167).**
  The prune slice went
  negative below `KEEP` objects and jq counts a negative end from the end: at `KEEP=30`, 29 snapshots became 1, every
  run. Two siblings fell out: an optional tfvars key silently killed the scripts that read it, and `s3_cred` with kind and
  type swapped printed the secret where an access-key id belongs. Rung: mocked. The script also ran inside the three real
  control-plane removals of 2026-10-04 (snapshot, encryption, upload to both buckets, retention; each run rc 0), and
  stand-alone as `task etcd-snapshot` on each cloud (2026-10-10 on Scaleway and OVH, 2026-10-11 on Outscale, and once
  before on 2026-10-06 on an older commit; real cloud, by hand): the object encrypted and in both buckets, rc 0.
  Retention was not read, and none of those snapshots was restored.
- **Building a Talos image for one cluster could delete the image another cluster's tfvars still pinned (#93), and a
  Factory answer without a schematic id went to "image already up to date" one step from a billable publish.** The lane
  held one image per provider and nothing failed until the other cluster's next plan; with one state per version a
  build can no longer replace another version's image (Changed; retention and prune still read only this checkout's
  tfvars). `talos-image.sh` also refuses when the Factory answers without a schematic id
  (`TALOS_IMAGE_ALLOW_OFFLINE=1` is the deliberate way around). Rung: mocked for the refusal; the lane's real runs are
  in Validated.
- **`seed-openbao.sh` named a backups bucket that did not exist on any cluster deployed under a `bucket_suffix` (#166).**
  Restic and Loki were seeded with the wrong name and the seeder reported success. The name now comes from the derivation
  every other caller uses. Rung: mocked.
- **The Scaleway node security group opened every port (#79).** The provider stored an omitted port and `port = 0` as the
  same rule, so an earlier fix changed nothing. The group now lists the ports this repository's layers serve over the
  private network, from the module's own subnet, pinned to the private network's own /22; `100.64.0.0/10` keeps only the
  load balancer backend ports, and the rules sourced from the load balancers' public IPs, the dead bastion-public-IP rule
  and the `10.0.0.0/8` rule are gone. Rung: mocked, and emulated (apply, empty re-plan, destroy of the whole root); real
  cloud on Scaleway, 2026-10-02, where the load balancer read 3 backends `running` and its last health check `passed`.
  Applying it to an existing cluster is in Upgrade notes.
- **The teardown proofs read "could not ask" as "clean".** Scaleway had no check in `verify-provider-clean.py` (exit 2); it
  now lists the cluster's servers, load balancers, gateways, security groups and networks plus every detached IP and
  volume. The Scaleway purge (`task purge-orphans PROVIDER=scaleway APPLY=1`) now also lists and deletes what it never
  touched, public gateways, their IPs, load balancer IPs left without a load balancer, security groups and instance
  volumes, and it read the first 50 items of each list only; it now reads page by page. A kind no zone answered, missing
  credentials, a refused OVH login or region, and a refusing endpoint under `--apply` exit 2, not the 1 that means
  "leftovers" or a clean 0; `--apply` no longer ends on "The project is clean" and asks for a re-run; `ovh.py` counts
  refused calls (#63); `edge-down.sh` no longer sends a Scaleway or Outscale operator to the OpenStack-only deleter;
  Outscale lists leftover snapshots (#71, PR #108) and this account's images, never deleting either (#107). Rung: mocked
  and emulated; real cloud, read-only: Outscale's image read, and the Scaleway checker (rc 0) and purge dry run (nothing
  to purge) after the teardowns of 2026-10-06 and 2026-10-10. Buckets are not listed.
- **The bastion's SSH-CA hooks shipped inert (#81).** `TrustedUserCAKeys` and `AuthorizedPrincipalsFile` were hardcoded
  to an empty file; `bastion_ssh_ca_public_key` and `bastion_ssh_ca_principals` are now variables of all four provider
  modules, default `""`, identical rendered bytes when unset. **The cluster root does not forward them, so no tfvars
  can turn SSH-CA on yet:** enabling it means editing the root. `task ssh-ca-check` now refuses to start without Docker
  instead of skipping with exit 0. Rung: local Docker (`task ssh-ca-check`, a real sshd); never on a cloud bastion, and
  `bastion-harden-check.sh` has no recorded run against one.
- **`converge-versions.sh` had no downgrade guard of its own (#90).** It survived a downgrade only by accident, on two
  layers it does not own. It now refuses a pin semver-lower than what the fleet runs, naming both. Rung: mocked.
- **Statements about a deploy that were wrong.** The Taskfile said `cluster-up` asks once; it asks twice (the phase-1
  plan and `bootstrap-phase2`'s). `cluster-upgrade` said its applies ask; they run with `APPROVE=auto`. On Proxmox with
  `enable_bastion` the root now reports the VM's user, `bastion` (PRs #209 and #285; Known limits).
  0.1.0's docs said the first
  apply after a `talos_version` bump fails once on OVH and Outscale and must be re-run (upstream
  `siderolabs/terraform-provider-talos#352`); the module already carried the workaround (`replace_triggered_by`) in the
  0.1.0 tag, and the 2026-10-03 climbs applied the bump in one apply on all three clouds, through `cluster-upgrade`,
  which has no retry.
- **`setup.sh` died, or silently kept an old tool, on a bare machine.** `talosctl` is installed from a pinned,
  checksummed release; OpenTofu is pinned instead of asking the GitHub API for the newest (a 403 took the bootstrap
  down) and no longer goes through snap or brew, which cannot install a named version; the pinned ShellCheck installer
  installs `xz-utils` when missing (its absence also made Cléa blame flux2, #174); `check_cmd` compares versions, so an
  upgrade is no longer skipped; `sudo` is asked whether it can be used, not whether it exists; checkov goes in a venv so
  `task security`'s checkov step can finish on Ubuntu 24.04 (its trivy step needs a trivy `setup.sh` does not install); it
  now also installs actionlint, gitleaks, plumber and the flux-schema
  plugin; kubectl (checksum-verified), aws-cli, checkov, yamllint and pre-commit, installed at whatever upstream served
  that day, are pinned, so Cléa's probes compare a version instead of watching one move. Rung: mocked; run from cold on
  one machine the repository had never been set up on; a bare `ubuntu:24.04` is recorded for the OpenTofu 403, the
  missing `xz` and the five new pins (run to the end, all five at their pin).
- **`task preflight` died on a clean machine while `setup.sh` said the environment was ready (#289, #290).** `render-check`
  now reads Cilium's effective config with PyYAML (`import yaml`; 0.1.0's did not) and nothing installed it; CI hid it, its
  runner image ships it. `setup.sh` now installs `python3-yaml` (apt) or `pyyaml` (brew), or names the package and carries
  on. The same clean-machine clone found `test-cluster-checks.sh` printing `command not found` on every run (its stubs were
  defined after their first call). Rung: mocked; local Docker: a bare `ubuntu:24.04` clone of the fix's merge commit ran
  `setup.sh` and then `task preflight` to the end, 2026-10-10. Not run: macOS (the brew branch is stub-only), another
  distribution.
- **A real `envs/*.tfvars` turned `task lint` red and was rewritten or deleted by the tooling (#191).** `task fmt` and the
  pre-commit hook rewrote the ignored files, the hook while saying Passed, and several harnesses wrote and deleted their
  fixtures in `envs/`. Both leave the real directory alone. Rung: mocked, with synthetic tfvars planted in `envs/`.

### Security

- **`admin_ip` refuses to open the cluster to the internet.** The variable had no `validation`, so `["0.0.0.0/0"]` was
  accepted in silence, and it feeds bastion sshd and the 6443 LB ACL on all four providers at once. Behind that ACL sits a
  `system:masters` kubeconfig Kubernetes cannot revoke. Three rules now reject an empty list, an entry without a prefix
  (including the `YOUR_IP/32` of a copied example) and any `/0`, read from the prefix. Rung: mocked (`tofu test`); each
  rule was deleted in turn and the suite watched to go red before it was kept.
- **Admin access is documented as unrevocable where it is unrevocable.** [`docs/admin-access.md`](docs/admin-access.md)
  says what a leaked kubeconfig costs, instead of leaving the reader to find out.
- **The Scaleway node security group lists ports instead of opening every one (#79, Fixed).** Scaleway's security groups
  filter public traffic only and these nodes have no public IP, so on this provider the list declares the perimeter; it
  does not enforce it.
- **Credential lifetime can be narrowed:** `task talosconfig-new` (Added) issues a role-scoped talosconfig that expires;
  it is not the default, and the deploy still hands out `os:admin` valid a year.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **Proxmox has never been applied on real hardware (#48).** The module is code and mocked tests; no tunnel has gone
  through a Proxmox VM bastion. Its user is `bastion` like on the other clouds (it was the image's `ubuntu`, which
  cloud-init cannot add to `bastion-admins`), mocked only (#201).
- **The real-cloud workflow has never run.** Its secrets, a dedicated SSH key, the tfvars of sandbox accounts and a
  decision on `admin_ip` (a hosted runner has no small stable IP) are the owner's to create; the first dispatch is where
  a real account gets to disagree with it.
- **Removing a node: a half-way stop has only run against fixtures, never on a real cluster.** Longhorn's eviction and
  CNPG (a replica, and a primary) ran on Scaleway only. A node that holds a node-local volume is refused, not migrated.
  The load balancer keeps sending one request in three to the departed control plane for 40 to 76 s (measured on all
  three clouds); taking the member out first is not built, and its effect was not measured.
- **A control-plane roll with zero failed probes has not happened on any cloud (#42).** Longest outage in the runs of
  2026-10-02 and 2026-10-03, Talos step: 1-2 s on Scaleway, 1 s on OVH, 3 s on Outscale; Kubernetes step: 2 s on Scaleway,
  9 s on Outscale (OVH: 10 s through `upgrade-k8s`). **Outscale on a cluster built by 0.1.0 (2026-10-06): about 22 s with
  all three apiservers down at once and 48 consecutive failed `/livez` samples through the load balancer (25 on `/readyz`)
  in the Kubernetes step** (`cluster-upgrade`'s own probe read 8 s for the same run; the two disagree and it is not
  explained). Plan for a gap, and for a longer one on Outscale.
- **The failover ran for one provider pair, and only as a rebuild (#57).** OVH to Scaleway, 1 control plane + 1 worker
  each, 2026-10-05 (Validated). Not run: any other pair, three control planes, Talos discovery with a live A (its
  records can outlive A by up to 30 minutes: read `talosctl get members` on B). Etcd contents and application data are
  not in the two stores. A's gitignored env file is in no store, and backing it up is undecided.
- **Flux is off by default, and `cluster-verify` fails a cluster that has a `flux-system` namespace.** The one roll with
  Flux and CNPG was a hand-installed lab on OVH (Validated). Flux's own controllers no longer record
  `gotk_reconcile_condition` (by about Flux 2.5, inferred from flux2's `go.mod`, not measured), so no per-object Ready
  signal comes from them: per-object state is `gotk_resource_info` through kube-state-metrics, whose manifests live in
  `OpenAether-apps` (#46). The vendored install is flux2 2.9.6 and has run on no cluster. There is no CAPI and no
  multi-cluster; a management cluster is an optional overlay.
- **Outscale: a Net that will not delete (#43).** One Net from before the load balancer fix still refuses deletion on a
  dependency no read returns; only Outscale can clear it, `purge-orphans` there cannot read clean while it exists, and
  Outscale's instruction is to create no further load balancer in that Net and use a fresh one. After `fleet-down`
  completes, the account lists a load balancer and a Net as `deleting` for about three minutes: read it again before
  calling it dirty. There is no state lock: one operator at a time.
- **Scaleway over two zones is a 2+1 split and a warning that has only run mocked.** Over the shipped example's three
  zones `cluster-verify` read three failure domains on a real account (2026-10-10, by hand). The Outscale
  examples sit below the sizing floor on purpose (bare cluster only).
- **The Talos provider is 0.12.0, and the climbs of 2026-10-02 and 2026-10-03 ran under 0.11 (#241).** Under 0.12.0, real
  cloud by hand, `cluster-upgrade` took clusters built by 0.1.0 (3 control planes + 2 workers) from 1.13.9 to 1.14.2 on
  all three clouds on 2026-10-06 (Outscale after one resume), and a fresh 1.14.2 cluster of that shape was built and
  verified on all three (2026-10-06, then the release code on 2026-10-10 and 2026-10-11); at 1 control plane + 1 worker a
  1.14 cluster was built and verified on Scaleway (2026-10-05); inside the 1.13 contract it ran on OVH and Outscale (a
  fresh deploy and a bump 1.13.9 to 1.13.11, 13/13), with `replace_triggered_by` still in. Not measured: a run without
  `replace_triggered_by` (#83). `talos_machine` (#44) is not adopted.
- **A state that lost the Talos secrets is refused, and comes back only from a replica copy or a talosconfig the nodes
  still trust (#66).** With neither there is no way back from here. The cause of the 2026-08-15 mismatch is not
  established; the version flip is refused by `prevent_destroy` and the interrupted-apply path was not broken. Not seen
  on a real cloud: Outscale, three control planes, a replica on another provider, `cluster-verify` on a lost PKI.
- **Rolling an upgrade back is not proven (#270).** The image lane keeps the cluster's version and the one below it
  (#69), which is the medium for a node on the previous Talos, and nothing more: `converge-versions.sh` refuses a pin
  below what the fleet runs, `talosctl rollback` is wrapped by no script and described by no runbook, and no run is
  recorded that took a rolled node back. A node created on the previous image joined Ready on it and stayed there; the
  fleet read red, `MIXED`, until `cluster-up` rolled it forward.
- **The image lane's extra paths ran on Scaleway and Outscale only (#69, 2026-10-05), and its retention needs a person.**
  The extra paths are the legacy-state copy, a second version beside, `PRUNE`, `RETAIN` and a node on the previous image;
  its plain build ran inside the release deploys of 2026-10-10 and 2026-10-11 on all three clouds. Not run: those extra
  paths on OVH, Proxmox, the retention hook inside `cluster-up` under a real terminal and tofu, the destroy of a held set
  through it, a legacy state holding the oldest version on a real backend, `--import-snapshot` (stand-ins only), a node
  one minor behind, a control plane on an older image. Retention never prunes under `APPROVE=auto` and `cluster-upgrade`
  does not run it, so an unattended run keeps every image; it reads this checkout's tfvars only, so a cluster whose tfvars
  is elsewhere is not asked.
- **Buckets stand on the three accounts, and only a person empties them.** Each of the final validation runs (2026-10-10
  and 2026-10-11) left its state, its etcd snapshots and a replica of the state on another cloud. The old `-talos-staging`
  buckets were emptied and deleted by hand on 2026-10-06 (#73, closed). The image lane's `-talos-import` and
  `-talos-image` buckets stand too, those of the final runs included, on Scaleway and Outscale. No script enumerates
  buckets, and `purge-orphans` matches resources, not buckets.
- **Destroying a cluster whose pinned image is gone is unproven (#269).** On Outscale `infra-plan` fails on the missing
  image and `infra-down-plan` takes its `-refresh=false` fallback; that fallback's plan was never applied (an equal plan,
  made after the override was removed, was), and Scaleway did not reproduce the failure.
- **The Docker lane at 1.14.2 did not boot on either host tried by hand, both kernel 6.12 (#291).** On the second (Docker
  29, containerd image store) the guards passed, six containers started and every node log read ended in the same fatal
  error while the node set up its `/etc` overlay (`FSCONFIG_SET_FD`); the bootstrap then waited until interrupted, at ten
  minutes, and nothing refuses such a host. The recorded 3 control plane + 3 worker run is at v1.13.9 and v1.36.3
  (2026-08-24). At 1.14.2 and 1.37.1 the lane booted once, on a hosted runner (kernel 6.17, Cléa's weekly lane, 1 control
  plane + 1 worker, `local-verify` 8 passed, 2026-10-11). Rung: local Docker. Not run: the default 3 + 3 at this pin.
- **The purged address is still served by GitHub, by its SHA and in the original pull request's diff (#61).** Only GitHub
  can remove it; a published value is published.
- **The emulated lane is weaker than the cloud:** the lanes that destroy run the Scaleway provider below 2.83.0 while real
  clusters run newer, the fix waiting on a Feint release (#179); `module.scw` was recorded twice on a real Scaleway
  account (2026-10-05, 2026-10-08; one control plane and one worker) and replayed against the emulator, where the replay
  diverges and the first divergence of each chain is not isolated; Outscale was never recorded, and `feint shapes
  --check`, which compares a fixed read list, was dropped as the bar (#76, closed); `talos-image` is outside the lane
  (#47).
- **`task security` was not run for this release** (the validating host had no `trivy`): skipped, not passed. CI's IaC
  Security Scan was green on `main` at the release code, `893a395`.
- **Never recorded against real infrastructure:** `bastion-harden-check.sh` on a real bastion, `k8s_lb_mode = "vip"` on
  OVH, the `workload` role.
- **The tag ruleset blocks moving or deleting any tag, 0.1.0 included**, so a release tag cannot be re-cut. That the ruleset
  has no bypass actors is checked only by an admin's run of `check-required-checks.sh` (CI's token cannot read them), and
  the admin run of 2026-10-10 found none.
- **Also open:** an apply that changes the bastion kills the Talos tunnels mid-run, and nothing refuses or splits that
  plan (#288); why the tunnels died on Outscale in August (#65, closed as not reproduced on 2026-10-08; transcripts are
  now kept, one induced TERM was quoted correctly and no unprompted death is recorded), and an OVH node that can stay
  `ACTIVE` while dead (#49, blocked on the provider): seen on a real account at the first boot of a fresh deploy on
  2026-10-06 and again on 2026-10-10 (one deploy of two that day), recovered each time by a Nova hard reboot of that node
  alone and the same `cluster-up` resumed; the cause is not known and no frequency is claimed.

### Upgrade notes

For an operator on 0.1.0. Read the plan before you approve it, and the roll `cluster-up` prints.

- **A tfvars that leaves `talos_version` and `kubernetes_version` unset now inherits v1.14.2 and v1.37.1, and `cluster-up`
  is built to converge the fleet onto them.** It prints the roll before it asks, but a plain pull then `cluster-up` is a
  Talos 1.13 to 1.14 and Kubernetes 1.36 to 1.37 upgrade, and `cluster-verify` is red until it lands. A minor climb
  through `cluster-up` has only run mocked, and so has its stop before the plan; the measured climbs used
  `cluster-upgrade`. **Use `task cluster-upgrade` for a 0.1.0 fleet:** a plain `cluster-up` across a Talos minor and a
  Kubernetes minor stops before the plan (the running Talos 1.13 cannot host Kubernetes 1.37, #278), and `cluster-upgrade`
  walks the pair one minor at a time, with each axis pinned where it runs (#279). It asks nothing (its applies run with
  `APPROVE=auto`) and writes each pin it lands into the tfvars; `task cluster-upgrade PROVIDER=<p> DRY_RUN=1` works out
  the walk on a copy of them and stops. A plain `cluster-up` has rolled one worker, v1.14.1 to v1.14.2, on two clouds
  (2026-10-05). Set both explicitly to stay where you are; a downgrade is refused. A tfvars copied from an example that
  hard-pinned v1.13.3 and v1.35.3 keeps that pair, which no recorded cloud run used (Changed).
- **After pulling, run `tofu init -backend=false -upgrade` in `infrastructure/opentofu/cluster` (or `task validate`,
  which shares the lock).** The Talos provider is pinned at 0.12.0 and the lock file is local and gitignored, so every
  `infra-*` task stops at init on a stale 0.11 lock. `-upgrade` moves every provider within its constraint: read the
  next plan. To move only talos, delete its block from `.terraform.lock.hcl` and run a plain `tofu init`. A cluster
  built under 0.11 planned empty under the pin (Scaleway, 1 control plane + 1 worker; and, after the climb of
  2026-10-06, the three clusters the 0.1.0 tag built, 3 control planes + 2 workers).
- **Three control planes in one failure domain now end red:** OVH built on `nova` (read from the config, never seen on a
  live cluster; the verifier's red line names the knob that clears it for a new cluster, and what changing it does to
  nodes already built is not measured), an Outscale cluster built before the subregion spread (Changed: its layout is
  kept, no setting clears it), Proxmox on one host. `cluster-up` ends at its verify, so `cluster-up`,
  `cluster-idempotency` and `cluster-upgrade` end non-zero there. A state older than the `control_plane_zones` output
  reads UNCHECKED, which is fatal, until one apply.
- **`git_ref` now defaults to `refs/tags/0.1.0`, not `refs/heads/main`.** It only matters with `deploy_flux = true`: a
  tfvars that omits it re-points Flux's source from the branch to the tag at the next apply, and a tfvars copied from
  0.1.0's example keeps whatever it names. Say `git_ref = "refs/heads/main"` to stay on the branch. Nothing of this
  release has followed either ref on a cluster.
- **A lowered count is refused**; use `task cluster-shrink-plan` then `task cluster-shrink`. Do not route a node size
  change through `cluster-roll`: it is an in-place update of every node at once, and `docs/upgrade.md` has the one-node
  procedure. The new Scaleway examples' `instance_type` is a size change on a running cluster.
- **`admin_ip` and `flux_namespace` are validated:** an empty list, an entry with no prefix and any `/0` now fail the
  plan, and so does a `flux_namespace` other than `flux-system` (inert unless `deploy_flux`, validated all the same).
  Changing `admin_ip` on a bootstrapped cluster needs `OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true`
  (`docs/admin-access.md`).
- **OVH's default `availability_zones` moved from `nova` to the three EU-WEST-PAR zones.** A tfvars that leaves it unset
  changes zone; whether that replaces a node or a volume was not run, so pin what the cluster was built with and read the
  plan for replacements. A tfvars copied from 0.1.0's example names `["nova"]` itself: the default does not touch it, and
  the verifier is expected to end red on it (read from the config, never seen on a live OVH cluster; the failure-domain
  note above).
- **Scaleway clusters built under 0.1.0:** the private network keeps the subnet it has (`ignore_changes`), the pin only
  decides a new one, and the node security rules follow the subnet in use. Measured on a 0.1.0 cluster (2026-10-06): the
  first step plans `7 to add, 8 to change, 7 to destroy` (seven replacements: the five Talos configuration applies,
  `terraform_data.backup` and the local talosconfig; the in-place updates include the three node security groups; no
  network, subnet, private NIC or node). Without it the same climb replaced the network and every private NIC. Read the
  plan and stop at any network or node replacement all the same.
- **The bastion carries the Talos tunnels, and a change to it stops them mid-apply.** OVH: the bastion's default
  cloud-init renders 0.1.0's bytes, so it is not replaced. Outscale: the cloud-init now renders the Net CIDR (#58), so the
  first apply of the upgrade MODIFIES the bastion in place, the VM restarts (32 s), the tunnels die and the run stops with
  `connection refused` on the tunnel ports: **re-run the same command**, the tunnels are rebuilt at its start and it
  converges (one resume on Outscale, 2026-10-06). `explain-failure` now says the change landed (mocked only: that run
  predates the message). Nothing yet refuses or splits a plan that changes the bastion under live tunnels (#288).
- **An Outscale cluster built under 0.1.0 ends `cluster-verify` red, for good:** its three control planes are in one
  subregion, a node's zone is fixed when it is created, and the verdict is `13 passed, 1 failed` (the failure domain).
  `cluster-up` and `cluster-upgrade` then end non-zero although the versions converged.
- **The image lane:** the first build of the version the old `talos-image.tfstate` holds copies it to its own key and
  renames the old object, never deleted. A legacy state with a deposed or tainted object, or objects naming two
  versions, refuses the build of the version it holds (the image README names the way out). On Outscale the same-name
  gate runs on `--ensure` only: a plain `task image-build` still reaches the provider's 409 after the 8 to 14 minute
  import, and only the account's owner can delete the untracked OMI that caused it, which the script never does.
  `cluster-up` now ends by asking tofu's own yes for each image below the cluster's version and the one under it
  (skipped under `APPROVE=auto`; Changed).
- **Teardown:** the plan step of `task cluster-down` replicates the state before it untracks the Talos secrets, and a
  state without them is refused until restored (#66).
- **The Docker lane's default pin moves from v1.13.3 / v1.35.3 to v1.14.2 / v1.37.1, and `task local-up` did not start at
  it on the two kernel 6.12 hosts tried (#291, open; Known limits).** It booted at it on a hosted runner (Cléa's weekly
  lane, 1 control plane + 1 worker, 2026-10-11). Rung: local Docker; the default 3 control planes + 3 workers has no
  recorded boot at this pin.
- **Smaller:** `task cluster-up VERSION=` is not an argument; `cluster-*` tasks refuse `PROVIDER=local`; `cluster-up`
  refuses a never-applied `prod` cluster whose replica shares the primary's cloud, and fails when its verifier does.

---

## [0.1.0] — 2026-08-20

> **This tag does not point at the commit first cut as 0.1.0.** That one,
> `421c1ee`, carried a real admin IP that had been serving as a test fixture in
> `check-gitleaks-rules.sh` since 2026-08-13 — found by reading the published tag
> as a stranger, which is what §9 of the release checklist is for. History was
> rewritten and the tag re-cut, twice: once on the purged history, once more to
> take in this record of it. No release was ever published under the first tag
> and nothing depended on it. GitHub still serves the old blob by direct SHA and
> the diff of the pull request that introduced it; only GitHub Support can remove
> those, and anyone who cloned before the rewrite keeps it.

**One Talos cluster, on one supported cloud, with one fixed foundation: Cilium.**
Infrastructure only — nothing above that layer. Start at
[`docs/first-cluster.md`](docs/first-cluster.md).

### Added

- **Every task is `<noun>-<verb>`**: `cluster-up`, `infra-plan`, `infra-apply`,
  `tunnels-up`, `cluster-verify`, `cluster-upgrade`, `cluster-idempotency`,
  `cluster-roll`, `infra-down`, `cluster-down`. Upgrades:
  [`docs/upgrade.md`](docs/upgrade.md). Day-1 access:
  [`docs/admin-access.md`](docs/admin-access.md).
- **An approval you cannot lose by accident.** `APPROVE=auto|ask` names *who*
  answers the question, never whether one is asked: every apply plans to a file
  and applies that file, and `tofu apply <saved plan>` does not prompt.
  `-auto-approve` is gone from the cloud path, CI included. Destroy always takes
  two commands and no flag collapses them.
- **State and artifacts encrypted client-side in S3**, with an optional replica
  on a second cloud. S3 credentials are namespaced by the cloud that *holds the
  bucket*, not by the cluster. Proven across providers: an encrypted tfstate at
  Outscale while the cluster ran on Scaleway.

### Validated

Measured on real accounts: Scaleway and OVH on 2026-08-19, Outscale on
2026-08-20. Versions were read back from the kubelets and from each node's own
Talos API, never from the tool that performed the upgrade.

- **Scaleway, from an empty account**: deploy in 8 min 50 for 72 resources,
  `cluster-verify` 11/11, idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos
  v1.13.7 → v1.13.8 confirmed by Talos itself on 6/6 nodes (`stage=running`,
  fallback dropped).
- **OVH**: the same five pillars — deploy, verify, idempotency, and both
  upgrades — the same versions, 11/11, idempotency 3/3.
- **Outscale**: the same five pillars again, measured the same way — deploy (51
  resources, then 17), `cluster-verify` 11/11, idempotency 3/3, the same two
  upgrades on 6/6 nodes. It had to go onto a **fresh Net**: see the known limits.
- **Idempotency is a property of the command.** Run `task cluster-up` once or a
  hundred times and you land in the state you asked for; the evidence is the
  command's own plan, which prints `No changes.` on a cluster that already
  matches. `task cluster-idempotency` adds the two assertions OpenTofu cannot
  make — the *same* nodes (name and `creationTimestamp`), and a kubeconfig that
  still reaches the apiserver — because an empty plan alone would not catch a
  node replaced underneath it.
- **A second Scaleway cycle on 2026-08-20**: `cluster-up`, `cluster-up`,
  `cluster-upgrade`, `cluster-up`, all four green, both re-runs applying nothing
  on all three roots. **Idempotency after an upgrade had never been checked**; it
  holds because `cluster-upgrade` writes the new pin back into the tfvars. Talos
  v1.13.8 → v1.13.9 on 6/6 nodes, and `cluster-verify` compared the running
  *schematic*, not just the version tag.
- **An upgrade is not seamless.** Longest apiserver outage 5 s on Scaleway (16
  failed probes out of 575), 7 s on OVH (9-10 out of ~540) and 8 s on Outscale.
  All three are *worse* than the best figures this project ever recorded (3 s,
  1 s and 1 s), and why has not been established. Plan for a gap.
  A later Scaleway run measured **2 s**, with the roll taking the etcd leader
  last and handing leadership over first. **That does not establish the fix**:
  that run moved Talos alone, while the 5 s run also moved Kubernetes, which
  restarts an apiserver per control plane by itself. Two workloads, two numbers
  that do not compare — quote the 5/7/8 figures.
- **358 offline assertions across 11 harnesses**, every one mutation-tested
  (`task test-scripts`). The emulated lane runs feint 0.10.0 against Scaleway provider
  2.81.0 — the same version the clusters run.

### Fixed

- **The shared schematic shipped `siderolabs/qemu-guest-agent`, and that one
  extension cost every upgrade.** It never starts on OVH or Outscale, whose
  images carry no `hw_qemu_guest_agent` device: the boot sequence never
  completed, Stage never became Running, the META Upgrade key was never dropped,
  and the next reboot reverted the upgrade the tool had just reported as
  successful. Root cause, not a workaround.
- **A failed purge no longer exits 0 saying "purge complete".** The teardown for
  this release found six Outscale resources, was refused on all six, and the
  script still reported success — the refusals were printed but never counted, so
  the exit code every caller reads said the account was clean. All three
  `purge-orphans` scripts now count failed deletions and end on one of three
  verdicts, the third being *N of M failed, NOT clean*.

### Removed

- **The staging CI lane.** 479 lines that never deployed anything: the workflow's
  one recorded run died for want of secrets that were never set, and part of it
  verified a platform this release disables (35 Flux Kustomizations). A weekly
  red that measures nothing teaches you to ignore red. 0.1.0 ships **no CI lane
  that deploys** — the credentialed rung is run by hand, by someone watching. The
  code is on the `archive/staging-lane` branch.

### Changed

- **`talos-image`'s "staging" bucket is now the "import" bucket.** This repository
  already spends that word on environments (`environment = "dev"`), and reading
  it as one here is what it cost. The variable is `import_bucket`, the bucket is
  `…-talos-import`, and the default is no longer a literal name with the project
  and the provider baked into it — it is empty, and refused where it is named.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **No Flux and no applications.** `deploy_flux` defaults to `false`. Flux is
  disabled, not amputated — the Talos module already reads an empty manifest as
  "no Flux", so turning it on moves no resource address — and it returns as a
  user choice in a later release. Everything it reconciles lives in
  `OpenAether-apps`.
- **No CAPI and no multi-cluster.** A management cluster is an optional overlay
  on top of this, never the entry point.
- **Outscale needs a fresh Net, and leaves one behind.** A load balancer that
  never left `provisioning` was diagnosed by Outscale as an internal timeout in
  their LBU service — support request 399530, now closed, with the instruction
  not to create another load balancer in that Net. One Net created before the
  fix still refuses deletion on a dependency no read returns; only the provider
  can clear it, and a second request is open for that.
- **No state lock on Outscale.** Its object store accepts a conditional write
  (`If-None-Match`) that Scaleway's and OVH's refuse, so `use_lockfile` is
  enabled on those two and deliberately not there — a lock that announces itself
  and holds nothing is worse than none. Two concurrent runs against an Outscale
  cluster's state are not stopped by anything.
- **Scaleway, OVH and Outscale are the clouds that were measured.** Proxmox has
  never been applied on real hardware; the local Docker rung proves
  `modules/talos` without credentials and nothing about a cloud. Anything else is
  code, not a claim.
- **Two release-checklist lines were not met, and are not ticked.** The OVH
  teardown was run once where the checklist asks for twice — an Octavia load
  balancer orphaned by one teardown was once silently reused by the next deploy,
  and only a second teardown proves the check that now covers it. And the
  Outscale purge is not clean: the pre-fix Net above is still there and no
  deletion is accepted for it.
- **One image bucket is orphaned by this release's own rename.** The old
  `…-talos-staging` still holds every QCOW2 it was given, on every cloud built
  from. `purge-orphans` lists it; emptying it is by hand.
- **`ovh.py` cannot tell a refused question from an empty account.** Its two
  siblings count refused calls and exit 2 when they found nothing but asked
  nothing; it has no such counter. A total auth failure crashes it rather than
  reporting clean, so this is a gap and not the same defect — but a partial
  refusal would shrink its findings in silence.
