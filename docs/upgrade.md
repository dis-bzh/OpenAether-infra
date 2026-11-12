# Upgrading a live cluster — Kubernetes and Talos

🇫🇷 [Version française](upgrade.fr.md)

> Building a cluster and keeping one are different claims. This is the second.
> Measured by hand on **Scaleway, OVH and Outscale** — the first two on
> 2026-08-19, Outscale on 2026-08-20 — HA topologies, every node upgraded **in
> place** rather than replaced and each node's own Talos API asked what it runs.
> On 2026-10-03 all three went on to Talos 1.14.2 and Kubernetes 1.37.1 through
> `task cluster-upgrade` (`docs/status.md` has the figures). Earlier runs on Outscale
> and on OVH reverted on the next reboot, and the open issues say why.
>
> The scripted version of this same procedure is `task cluster-upgrade`
> ([`scripts/dev/cluster-upgrade.sh`](../scripts/dev/cluster-upgrade.sh)). It is
> run by hand, by someone watching: no CI lane deploys anything on its own. This page is
> what was actually run.

## The two facts everything here follows from

**A node's boot image is only the medium it was installed from.** After
`talosctl upgrade` the instance still reports the old image id, by design. Node
resources therefore carry `ignore_changes` on it — see
[`provider-contract.md` § Node image drift](../infrastructure/opentofu/modules/providers/provider-contract.md).
Without that, bumping `talos_version` would make a routine apply replace every
control plane at once and etcd would lose quorum.

**Talos supports a window of Kubernetes releases, not all of them.**
`cluster/versions-guard.tf` refuses an unsupported pair at plan time, and refuses
a Talos minor nobody has entered in its map rather than passing it silently. The
starting pair, the ending pair *and* the intermediate state all have to sit
inside the window, because the two move one at a time.

## Measure the interruption

Start this before anything, against the endpoint in the kubeconfig — never a
tunnel to one node, because that node is the one you are about to take away.

```bash
while :; do kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 \
  && echo ok || echo FAIL; sleep 1; done | tee probe.log
```

A clean run loses a few seconds while an apiserver restarts. Both upgrades end
to end: **5 s** on Scaleway (16 failed samples in 575) and **7 s** on OVH (9-10
in ~540) on 2026-08-19, then **8 s** on Outscale on 2026-08-20. All three are
worse than the best this project ever recorded (3 s, 1 s and 1 s) — quote these,
not those.

The cause of that regression is not established. The roll now takes the etcd
leader last and hands leadership over with `talosctl etcd forfeit-leadership`
rather than letting its disappearance force an election (2026-08-20).

The first run under that order, Scaleway 2026-08-20, measured **2 s** — 13 failed
samples in 577. **It does not establish the fix**: that run moved Talos only
(v1.13.8 → v1.13.9, Kubernetes unchanged at v1.36.3), while the 5 s run also
moved Kubernetes, which restarts an apiserver per control plane on its own. Two
different workloads, so the two numbers do not compare. What the timestamps do
show is a changed *shape*: of the 13 failures only two adjacent pairs were
consecutive, and the rest were isolated 5-6 s apart — a lone failure means other
backends still served, so there were two real 2 s windows rather than one long
one. The experiment that would settle it is the same Talos-only upgrade with the
leader-last order disabled: one run, one variable.

**Those numbers are the control plane, not a service.** `task cluster-upgrade`
also runs a second probe for the whole roll: a 2-replica workload behind a
Service (with a PDB when two nodes can take it), polled through the apiserver
proxy, reported as FAIL count and longest outage, then deleted. Samples taken
while the apiserver is down are counted apart as BLIND. It is reported, not
gated. Real numbers, 2026-10-03: 0 failed on Scaleway, 40 failed and 20 blind of
1490 on Outscale (`docs/status.md`). How it works:
[`cluster-upgrade.sh` § The service probe](../scripts/dev/cluster-upgrade.sh).
Under the platform's default-deny ingress the proxy cannot reach the probe's pod
unless a policy lets it in (lab 25 printed "394 FAIL, 2 BLIND in 396 samples": a
policy, not an outage; infra #403). The probe's namespace therefore gets a
`CiliumNetworkPolicy` for the control plane (the entities `host`, `remote-node` and
`kube-apiserver`, port 8080 only: which one the proxy's traffic is classified as is
not established, so all three), and before the upgrade starts the proxy is asked for
the pod (up to 15 tries, 2 s apart). If it never answers while the apiserver does,
the run prints `NOT MEASURING` and makes no claim about the service, and the upgrade
goes on (still reported, not gated). A cluster without Cilium's CRD gets no policy.
Rung: mocked (`test-cluster-checks.sh`); the policy on a real Cilium, and whether the
three entities are enough, is UNVERIFIED on a cluster.

## From 0.2.x to 0.3.0 (the platform, not Talos or Kubernetes)

0.3.0 moves neither Talos (1.14.2) nor Kubernetes (1.37.1). What it changes on a running cluster, in this order:

1. **Read the plan** (`task cluster-up` stops at it). With unchanged tfvars the one change you should see is the Scaleway system volumes going from 20 to 50 GB
   **in place** (`scw_root_volume_size_gb`, default 50; no node is replaced) and a Talos machine config change. Pin `scw_root_volume_size_gb = 20` only to keep the old size,
   which does not hold the application stack. On Outscale the root of a running VM is not resized in place: set `outscale_root_volume_size_gb` (and raise the root IOPS,
   infra #376) and replace the workers one at a time with `task cluster-roll`. OVH and Proxmox: the flavour's disk and `root_disk_gb` (50).
2. **Reboot the Scaleway workers one at a time, drained**, so Talos grows EPHEMERAL. Use `task cluster-roll`; a hand-typed `talosctl reboot` does not drain, and
   a worker carrying a CNPG instance must never be rebooted undrained (see below).
3. **Grow the disks before the application hops.** The 0.3.0 images are larger, and a 20 GB node reached DiskPressure after hours of hops (lab 15c).
4. **Then move the apps side** one minor at a time where it says so: Longhorn 1.9 -> 1.10 -> 1.11 -> 1.12 (with the CRD conversion pre-step), cert-manager, the CNPG operator,
   Kyverno, and the Loki chart procedure are in OpenAether-apps `docs/patching.md`. Take a CNPG Backup and a Longhorn backup first; Zitadel and Grafana migrations are forward-only.
5. **Hardening options are off by default.** Turn them on one at a time (`docs/hardening.md`, `docs/security-architecture.md`); each plan is read before it is applied.
   Options that change the Talos machine config (node filtering, baseline, log forwarding) are applied by the plan; if a change needs a reboot, do it with `task cluster-roll`.

Not rehearsed in place: the Loki 6.55 -> 18 step, Grafana, Alloy, the Gateway API CRDs. A fresh install of every version ran on the three clouds. (Flux on the children was rehearsed in place once afterwards, for 2.9.6 to 2.10.0: "From 0.4.4 to 0.4.5".)

## From 0.3.x to 0.4.0 (an existing cluster)

Written from the branch before the 0.4.0 tag, from lab 25 (a cluster built by infra 0.3.2 and apps 0.3.2, moved to the 0.4.0 branches) and from the code; the 0.3.2 to 0.4.0 move was then replayed on Scaleway in lab 28B (one `task cluster-up`, 39 min 13 s, see "Move and node operations" in `docs/resilience.md`). **Rung: the
commands below are mocked offline; what the labs did is said as such. Every step marked UNVERIFIED was not run on a cluster by those labs (the 0.4.0 release did not replay the move on OVH or Outscale).** Not a compliance claim.

**Supported upgrade path (owner decision, 2026-10-24).** Before 1.0.0 the supported upgrade is from the PREVIOUS minor to the current one only: n-1.x.x to n.x.x, here 0.3.x to 0.4.0.
No path from an older version is built or documented; from 0.2.x or earlier, go through 0.3.x first or rebuild.

**Why a plain `task cluster-up` is not enough (established from the code, one point from upstream).** The `cluster-identity` ConfigMap, the GitRepository `openaether` and the
Kustomization `openaether-platform` (with its `GIT_REF`) are all objects of the Talos inline manifest `flux-bootstrap` (`bootstrap-manifests/flux-bootstrap.yaml.tftpl`,
`modules/talos`). A change to that manifest changes the machine config of the control planes: that is the "3 to change" of the plan, and `tofu apply` sends the new config. What the
node then does with the manifest is Talos's manifest-apply controller. Its source (Talos `release-1.14`, `manifest_apply.go`, read on 2026-10-23 through a summarising fetch, not
cloned) checks each object with a `Get` and applies it **only when it is not found**; an object that exists is recorded and skipped, never updated, patched or merged. The same
behaviour was seen in lab 22 for the CoreDNS Deployment (`docs/resilience.md`) and matches lab 25: the ConfigMap kept its four keys. **So an inline-manifest object that exists on the
cluster is never rewritten by a later `cluster-up`.** What was NOT shown: a `talosctl get manifests` read on a node, and the same test on the GitRepository and the Kustomization
(by the rule above `git_ref` does not move a running cluster either; lab 25 patched the Kustomization's `GIT_REF` by hand). Also: the line "flux-system exists and every Flux controller is
Available" that lab 25 read is the VERIFIER's check (`cluster-verify`), not a decision to skip the bootstrap. In lab 25 `cluster-verify` looked at neither the ConfigMap nor the Kustomizations,
which is why `cluster-up` ended 0 with `cnpg` NotReady. Since 0.4.1 it reads the ConfigMap (the table below); it still does not read the Kustomizations.

The design does not depend on that point: the sync below reads the cluster and the rendered values, and writes whatever differs, whatever Talos does.

Steps, in order (take a CNPG Backup, a Longhorn backup and `task etcd-snapshot` first; a person runs this, with the plan read):

1. **Decide the path.** The 0.4.0 apps content moves the Gateway API CRDs from 1.2.1 to **1.6.0** and Istio from 1.24.2 to **1.31.3**, the chart repository of Istio, the waypoint class, and
   moves the CNPG archives to the Barman Cloud plugin. On an EXISTING cluster a **rebuild aside** stays an option: a new cluster on new buckets from the 0.4.0 tag, then the data moved
   (`docs/disaster-recovery.md`; a rebuild on the old backup bucket meets the old WAL archive and CNPG refuses to archive into it). The in-place move from the 0.3.x content was observed
   once, in lab 25 (Istio in 5 minutes, no client traffic judged, see below); the supported, tested path is the one the 0.4.0 release notes name. **Lab 25 observed:** after the Kustomization ref was patched by hand, Istio 1.24.2 to 1.31.3 in place in 5 minutes (istio-base, istiod, istio-cni, ztunnel Ready in that
   order; cni and ztunnel Unknown/False while the old pods rolled), the CRDs at v1.6.0, the GatewayClasses `istio`, `istio-remote`, `istio-waypoint` Accepted, the Gateway and the waypoint Programmed,
   and a test route through the load balancer and the Gateway answering 200; a Talos 1.14.2 to 1.14.4 roll before it (API: 8 failed probes in 2311, isolated 1 s). **Lab 25 did not observe:**
   convergence of the whole apps layer (the hop ended with 9 Kustomizations NotReady, finding D9, fixed below, not re-run), the rebuild-aside path, the Loki 6.55 to 18 hop (0.3.2 already carries
   Loki 18), traffic of real clients through the Istio hop beyond the 1 Hz probes, and any rollback of the CRDs (they are not rolled back; the `safe-upgrades` admission policy of the 1.6 CRDs refuses a downgrade below 1.5).
2. **Talos first** (patch inside the 1.14 minor: 1.14.2 to 1.14.4): edit `talos_version` in the tfvars, `task cluster-upgrade` or `task cluster-roll` as in the sections below. Lab 25 did this first.
3. **Move the tools and the config.** Check out the 0.4.0 tag of this repository, then `task cluster-up PROVIDER=… ROLE=…` with the plan read. Expect the control-plane machine configs "to change"
   (the manifest text and the 1.14.4 pin) and the new variables at their defaults (`CHANGELOG.md`, `variables.tf`). `cluster-up` now looks at the CNPG Clusters (step 4), the apps ref (step 5), the identity ConfigMap (step 6) and CoreDNS (below) itself, in the order: roll, CNPG presync + apps ref (one step when the presync has work), identity, CoreDNS, verify.
   **CoreDNS (lab 26, K2).** The 0.4.0 CoreDNS HA is an inline manifest and does NOT reach a cluster built by an older release: Talos leaves the existing `kube-system/coredns` Deployment (2 replicas, no spread) alone;
   only the new budget and the zone node labels appear. `cluster-verify` reports it ("CoreDNS runs the declared replica count and spread", BAD), and in lab 27 it made `cluster-up` end rc 201 because the one-time patch was documented AFTER `cluster-up` (FB). The patch is now a converge step INSIDE `cluster-up`, before its verify: `task cluster-coredns-ha PROVIDER=… ROLE=…` is a dry run (reads the Deployment and the node count, writes nothing, exit 3 on a difference), `… APPLY=1` merge-patches `scripts/ops/coredns-ha-patch.json` (replicas `min(3, nodes)` and the same `minDomains`, hard spread over nodes, spread over zones (required with three or more zones when every node has its zone label, else a preference; lab 28, I2), 30 s tolerations; a rolling restart of the DNS pods), waits for the rollout and reads it back. It is idempotent (in the declared shape it writes nothing and asks nothing), `cluster-up` applies it at `APPROVE=auto` or a typed "yes" and otherwise FAILS naming the command, and `coredns_ha = false` skips it. The same patch by hand: `kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json` (3-node shape; for fewer than 3 nodes edit `replicas` and `minDomains` first). Lab 27 ran that patch by hand (6 s rollout, 3 replicas on 3 workers, 31 lookups at 1 Hz, 0 failed); the step inside `cluster-up` is tested offline only (`test-cluster-up.sh`, `test-cluster-coredns-ha.sh`) and UNVERIFIED on a cluster. The Corefile, the image tag and the requests of that Deployment stay Talos's (`docs/resilience.md`).
   Everything else the 0.4.0 inline manifests newly define is created or covered: the CoreDNS budget and the `topology.kubernetes.io/zone` node labels (both appeared, lab 26), the Talos ServiceAccount CRD
   (Talos-built-in, appeared), the new `cluster-identity` keys (step 6) and the apps ref (step 5). The Flux manifest did not change between 0.3.2 and 0.4.0; the Cilium one changed in ONE place, the operator (**2 replicas, a budget of one disruption and a zone preference; it ran 1**, critical-path audit of 2026-10-28). The Cilium image is the same, and the manifest follows the CoreDNS rule: Talos creates the new budget but never rewrites the existing `kube-system/cilium-operator` Deployment, so `cluster-verify` says BAD ("the Cilium operator has 1 replica(s), the manifest declares 2") until it is patched. The patch is the same converge step as CoreDNS, inside `cluster-up` before its verify: `task cluster-coredns-ha PROVIDER=… ROLE=…` (dry run) / `… APPLY=1` also sets the operator to min(2, nodes) replicas with `scripts/ops/cilium-operator-ha-patch.json` (the operator pods restart one at a time; the datapath does not depend on them). The agents are not touched, no node reboots. UNVERIFIED on a cluster: the rollout of the second operator pod and the PDB appearing.
   **A new default in this move: `node_monitor_grace_period_seconds` is 30 (it was 0, Kubernetes' 50 s).** An existing cluster meets it at its next `cluster-up`, in the same run, as part of the move and not as a separate step: the plan shows the machine configs of the control planes AND of the workers "to change" (the controller manager's `--node-monitor-grace-period=30s` on the control planes; on every node the kubelet's `nodeLeaseDurationSeconds: 30` and `nodeStatusUpdateFrequency: 7s`). It is a machine-config apply, with no reboot; lab 27 observed about 7.5 minutes per apply (kubelets restart, the control planes' controller manager restarts one pod at a time). To keep Kubernetes' 50 s, set `node_monitor_grace_period_seconds = 0` in the tfvars BEFORE that `cluster-up`. Why 30, and the evidence (ONE provider, Scaleway, lab 27): `docs/resilience.md`, "Why the default is 30 s". **UNVERIFIED:** the same apply on OVH and Outscale, and a soak at 30 s during a roll.
4. **Enable synchronous replication on the live CNPG Clusters, BEFORE the apps ref moves** (study LAB-B2, 2026-10-24). The 0.4.0 apps content changes the pod spec of a Cluster (Barman Cloud plugin sidecar, ObjectStore archive) AND its PostgreSQL
   configuration (`synchronous`) in ONE Flux apply. On the reduced lab below that combination left a Cluster stuck for good in some runs: CloudNativePG waits, with no timeout, for every pod to report the same configuration hash, and a lost
   configuration reload (cloudnative-pg#11627, https://github.com/cloudnative-pg/cloudnative-pg/issues/11627) keeps one pod from ever doing so; the Cluster then has no synchronous replication and its archive fails. Enabling `synchronous` FIRST, as a
   step of its own that only needs a reload, did not. `task cnpg-presync PROVIDER=… ROLE=…` is a dry run: it lists every `postgresql.cnpg.io` Cluster that carries the label `openaether.io/managed` in the platform namespaces
   (`foundation-databases`, or `OA_CNPG_NAMESPACES`; the Clusters of a database profile and the `rt-*` restore-test copies are left out; no Cluster is named in the script) and whose `spec.postgresql.synchronous` is not the 0.4.0 block, and exits 3 on a
   difference; with no CNPG Cluster (a new cluster) it exits 0 and prints nothing. `… APPLY=1` patches ONLY `spec.postgresql.synchronous` (method `any`, number 1, dataDurability `required`, failoverQuorum `true`) and `spec.smartShutdownTimeout` (5, see "The primary restart" below), then waits for each Cluster:
   phase healthy, `readyInstances` equal to `spec.instances`, `show synchronous_standby_names` not empty on the primary, every replica `quorum` or `sync` in `pg_stat_replication`. Not converged after 120 s: it runs `select pg_reload_conf()` on every instance
   (break-glass R1, step 7) and waits again; not converged at 300 s: it fails and PRINTS the break-glass steps (R2). It never deletes a pod and never forces anything; no secret is read or printed. **It refuses (exit 2), writing nothing,** when a Cluster is not
   healthy, when no completed Backup of a Cluster to change is younger than 24 h (take one: `kubectl cnpg backup <name> -n <ns> --method barmanObjectStore`, then `task backup-verify`), when a Talos or Kubernetes roll is pending or under way (the gate of
   `cluster-bootstrap-sync`), when a pod predates the plugin sidecar while a plugin is enabled in the Cluster spec, and when a Cluster has fewer than 3 instances. **Decision on instances:** with `dataDurability: required` and ANY 1, losing the only replica of a
   2-instance Cluster would block every write, and the 0.4.0 content declares 3 (grafana-db is 2 on 0.3.x). Run by hand, the script does not scale on a guess: it stops and names `task cnpg-presync PROVIDER=… ROLE=… APPLY=1 SCALE=1`, which puts `instances: 3` in the SAME
   patch. **What was measured:** the study and lab 27 both ran "scale and `synchronous` in one patch" (lab 27: grafana-db scaled to 3 and healthy with the sync names set after 36 s, the whole step 2 min 22 s, zero loss); the order "scale, wait, then synchronous" was never run. **Decision (0.4.0):** under `APPROVE=auto`, and after the typed "yes", `cluster-up` passes `SCALE=1` itself: the head declares 3 instances, and lab 26 and lab 27 showed that stopping is worse than scaling (the stop let Flux undo the presync, below). `SCALE=1` only touches a Cluster below 3; every other refusal (unhealthy Cluster, no Backup younger than 24 h, a roll under way, a pod without the plugin sidecar) still fails the run and is never worked around. **The presync and the apps ref move are ONE step of `cluster-up`** (lab 27, FA and FB): the presync only lives on the cluster once the apps ref has moved, because Flux, still on the OLD ref, re-applies the 0.3.x `cnpg` content at its 10 minute reconcile and reverted it (grafana-db back to 2 instances, `synchronous` gone on both Clusters), so the documented stop-and-rerun refused again. `cluster-up` therefore runs the presync apply, reads the presync again, and moves the apps ref at once (`task cluster-apps-ref … APPLY=1`), with the identity and CoreDNS steps after it; if Flux undid the presync in between, it is applied again (twice at most) before the ref moves, and if it does not hold the run fails with the ref untouched. Suspending the Flux Kustomization was considered and not done: Flux re-resumed a suspended `cnpg` Kustomization within about a minute in lab 27 (its parent applies it), and suspending the root would freeze the reconcile the ref move needs and add a resume to guarantee on every exit. `cluster-up` asks ONE question for the combined step, "yes" typed, and otherwise FAILS naming the two commands to run back to back (`task cnpg-presync … APPLY=1 SCALE=1` then `task cluster-apps-ref … APPLY=1`). A refusal fails the run as well. Tested offline (`test-cluster-up.sh`); the new order has not run on a cluster (UNVERIFIED until the next lab). `cluster-verify` checks every such Cluster afterwards (block on the spec, ContinuousArchiving True, `synchronous_standby_names` set, replicas in the quorum, FailoverQuorum object).
   **Measured on the platform (lab 27, Scaleway, 3 CP + 5 W, 0.3.2 to the 0.4.0 head, 2026-10-25), with the presync run as `task cnpg-presync … APPLY=1 SCALE=1`:** 2 min 22 s, rc 0; zitadel-db did not converge after 120 s (`synchronous_standby_names` empty on the primary) and the script's own R1 reload on every instance converged it at 128 s (cloudnative-pg#11627 reproduced on the real platform, 1 of 2 Clusters); zero acknowledged commit lost (a2a 71904 and a2b 98047 acknowledged ids, 54 of 54 writer runs over the whole sitting), WAL archive contiguous (MISSING 0 in the primary and the replica store), `synchronous_standby_names` ANY 1 with both replicas in the quorum. The apps hop after the ref move converged in 13 min 25 s with nothing by hand. The primary of zitadel-db was then restarted in place for the plugin sidecar: see "The primary restart" below for the 206 s. **Measured earlier on a REDUCED lab** (Scaleway, 2026-10-24: ONE k3s node per VM, so the three instances share a node; no Flux, no Talos, no Cilium, no zones; the real 0.3.2 and 0.4.0 Cluster specs, CNPG 1.30.1, plugin 0.15.1; 20-35 acknowledged commits/s per
   database, not 100; the recipe was run TWICE from a clean start): this step took 54-57 s with no write gap; then the single apply of the 0.4.0 content: both Clusters healthy 95-100 s later, the primary restarted in place (no switchover), a write gap of
   17-22 s per database (17.7-21.8 s), **zero acknowledged commits lost** (6899-7290 and 5322-5573 acknowledged ids per run), WAL archive contiguous (**MISSING 0** on every timeline), `synchronous_standby_names` set with both replicas in the `quorum`.
   The same 0.4.0 content applied in one go stuck zitadel-db in 2 of 2 runs and grafana-db in 1 of 2: a race, not a certainty. **Still UNVERIFIED:** Outscale and OVH, other PostgreSQL major versions, production-size data, and the single-step order of `cluster-up` above.

   **The primary restart (lab 27, FI): 206 s, not 17-22 s.** The reduced lab had no client pool. On the platform, with the Zitadel pool connected, the operator restarted the zitadel-db primary in place for the plugin sidecar ("Primary is missing the WAL-archiver sidecar; recreating it in place instead of switching over"; `primaryUpdateMethod: switchover` does not apply to that restart), the instance manager requested a smart shutdown with `smartShutdownTimeout` 180 and PostgreSQL stayed in smart shutdown for the whole 180 s because client sessions were open, then fast shutdown: writes were unavailable for **206.4 s** (14:36:58 to 14:40:24; replicas restarted in 26 s each; lab 26's forced restart: 199 s). CloudNativePG semantics (https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/docs/src/instance_manager.md): the instance manager issues a CHECKPOINT and a smart shutdown "for up to `.spec.smartShutdownTimeout` seconds" (default 180), then a fast shutdown that disconnects the clients, within `.spec.stopDelay` (default 1800); `smartShutdownTimeout: 0` skips straight to fast. The value is read by the instance manager from its cached Cluster object at shutdown (upstream `pkg/management/postgres/instance.go`, `TryShuttingDownSmartFast`), not from the pod spec, so changing it needs no restart. **Change:** every platform Cluster (zitadel-db, grafana-db, forgejo-db and the database profiles) declares `smartShutdownTimeout: 5` from one shared Kustomize component in the apps repository, and `cnpg-presync` patches the same value BEFORE the move, so the in-place restart that the move forces is already short. **Measured (lab 27, sitting 2, 2026-10-26, Scaleway, the Zitadel pool connected: 2 zitadel and 2 login pods): 33.6 s, not 12-25 s** (last acknowledged write 09:42:48, next 09:43:22; the first measurement of the bounded restart, one run). Decomposition from the events: the pod is killed at 09:42:47 and the new one is scheduled 12 s later (the smart shutdown capped at 5 s plus the checkpoint), the Barman plugin sidecar image is pulled cold on that node in 6 s (once per node, so a later restart on the same node does not pay it), PostgreSQL starts at 09:43:09 and the first commit lands at 09:43:22. Write about **35 s with a connected pool, 6 s of it a first image pull**: this is a planned in-place restart of the primary, not a switchover, and it is 3.6 s over the 30 s class of a planned switchover (17-22 s in the client-less lab, 20-22 s for the planned switchovers of a worker drain in the same sitting); do not quote 12-25 s. **Sitting 3 (2026-10-26, same Cluster and pool, one run, inside the single `cluster-up` of the move): 26.3 s** (sitting 1: 206.4 s, sitting 2: 33.6 s); **lab 28B (2026-10-30, Scaleway, one run, inside the move): 31.4 s.** **The target for this restart is 35 s** (owner decision, 2026-10-31; it was 30 s), the figures above being 26.3, 31.4 and 33.6 s with `smartShutdownTimeout` already at 5 s; 30 s stays the design aim. Pre-pulling the sidecar image on every worker would save the 6 s (not done, not measured). Cost: a planned primary restart or shutdown disconnects clients after 5 s instead of waiting up to 180 s for them to leave, so a transaction in flight at that moment is aborted (committed work is not lost).
5. **Point Flux at the new apps ref, on the cluster.** Changing `git_ref` in the tfvars sets the new inline manifest, which Talos does not apply over the existing objects (above), so the
   live objects need the ref. `task cluster-apps-ref PROVIDER=… ROLE=…` (dry run) shows the tfvars value, the ref the GitRepository `openaether` follows and the `GIT_REF` of the Kustomization
   `openaether-platform`, and exits 3 on a difference. `task cluster-apps-ref PROVIDER=… ROLE=… REF=refs/tags/<apps tag> APPLY=1` rewrites `git_ref` in the tfvars (the diff is shown, the
   old file is kept as `<tfvars>.apps-ref-bak`), patches `spec.ref.name` of the GitRepository and `GIT_REF` of the Kustomization (those two fields only; `spec.verify` and every other field are
   never written), asks Flux to reconcile both and waits (300 s by default) for the GitRepository to report the revision of that ref. The ref must be `refs/tags/…` or `refs/heads/…` like
   `variables.tf`; a branch is a moving ref, warned about loudly and refused as `REF=` unless `ALLOW_BRANCH=1`. When the CNPG presync has work (step 4) `cluster-up` moves the ref right after it, in the same step, so Flux never sits on the old ref over presynced Clusters; otherwise it runs the dry run after the node roll and the presync and moves the ref
   (`APPROVE=auto`, or a typed "yes") or fails naming the command; `cluster-verify` fails on any difference, in both directions. Lab 26 (Scaleway) ran the dry run (a bare `task` shows exit 201 for the
   script's 3, see step 6), `APPLY=1` (19 s: both objects patched and read back; Flux reports the revision as `<ref>@sha1:<commit>`, which the wait accepts) and the second run ("in sync"); the Talos
   rule was read with `talosctl get manifests` (the manifest set is updated, the existing objects are not). Not run: `REF=refs/tags/… ` with the tfvars rewrite.
6. **Write the identity values.** `task cluster-identity-sync PROVIDER=… ROLE=…` is a dry run: it reads `tofu output cluster_identity` (the map the bootstrap template itself renders: bucket
   names, endpoints, URL and the audit sink host names, no secret) and the live ConfigMap `flux-system/cluster-identity`, and prints each key to add (`+`) or change (`~`); exit 3 means a difference.
   `… APPLY=1` merges ONLY the rendered keys into `data` (nothing else of the ConfigMap, no other object), reads them back, and asks Flux to reconcile its Kustomizations; a second run changes
   nothing. A key the live ConfigMap has and the map does not is reported and kept. `cluster-up` runs the dry run after the node roll and writes with `APPROVE=auto` or at a "yes" typed
   in a terminal; otherwise it **fails** and prints the command. Run on a cluster in lab 26 (Scaleway): the dry run listed the two missing keys, `APPLY=1` wrote them in 18 s, the second run said "in sync".
   **`cluster-up` calls the tasks, not the scripts** (lab 26 F1: called directly, the identity step ran `tofu output` outside the task environment and stopped with "Backend initialization required",
   twice, after a 41-minute roll; fixed, test `test-cluster-up.sh` runs the step with no `TF_DATA_DIR` and no S3 variable). **Exit codes you will see:** the scripts exit 3 on a difference and 4 when the object
   is not there yet, but a bare `task cluster-identity-sync` / `task cluster-apps-ref` / `task cluster-bootstrap-sync` reports **201** (`task: Failed to run task ... exit status 3`); `task -x …` (`--exit-code`)
   returns the script's own code. Inside `cluster-up` the same is handled for you, and each failure names the exact command with `PROVIDER` and `ROLE` filled in.
   Safety net on the apps side: the replica bucket and endpoint now default to `replica-not-set` and `https://replica-not-set.invalid` when the key is missing or empty, so a cluster that is
   late on this step has idle replica ObjectStores and not a NotReady database layer. The cause of the lab's `endpointURL ... "null"`: kustomize prints the field without quotes and Flux turns
   an empty substitution into YAML null (reproduced with `flux build` 2.9.3).
7. **Let the apps layer converge**, watching `kubectl get kustomizations,helmreleases -A`. Order the lab saw for the mesh: base, istiod, cni, ztunnel. The Barman Cloud plugin comes with the CNPG layer
   (two replicas in 0.4.0, CNPG 1.30.x): the Clusters leave `barmanObjectStore` for the plugin ObjectStore. **Measured on the reduced lab (step 4), after the presync:** the archive switched in place with the WAL archive contiguous (MISSING 0), CloudNativePG recreated
   the primary in place (upstream fix for the switchover dead-lock, cloudnative-pg#10981 and plugin-barman-cloud#901, in 1.30.1) and all pods carried the plugin sidecar 95-100 s after the apply. **Platform (lab 27):** the Clusters archived into the plugin store in place, both plugin pods 1/1, `cnpg` Ready, the WAL archive contiguous (MISSING 0) and zero commit lost; the primary restart took 206 s with the pool connected (step 4); take the CNPG
   Backup of the preamble and run `task cluster-verify` and `task backup-verify` afterwards. **Never promote and never switch over (`kubectl cnpg promote`, a switchover, `primaryUpdateStrategy: supervised`) while ANY pod of a Cluster predates the plugin
   sidecar.** Once a plugin entry is in the spec, the instance manager of every pod loads it first and returns on `Unknown plugin: barman-cloud.cloudnative-pg.io` when the sidecar is missing: that pod can no longer refresh its configuration, reload, demote or act on a
   switchover. On the reduced lab every switchover-based move dead-locked and one took the database down for more than 9 minutes (the Service lost its endpoint). **Break-glass for a Cluster stuck for more than 5 minutes** (the operator, started with
   `--log-level=debug`, logs `Waiting for all Pods to have the same PostgreSQL configuration`; `show cnpg.config_sha256` differs between instances): **R1**, the file is new and the running hash old: `kubectl -n <ns> exec <pod> -c postgres -- psql -U postgres -Atc "select pg_reload_conf()"`
   on EVERY instance of the Cluster (it recovered the stuck Clusters of the study, hashes equal in under 10 s, healthy within 70 s). **R2**, R1 is not enough (an old pod whose files went stale and that cannot refresh them without the sidecar): delete the OLD replica pods ONE AT A TIME (the operator recreates each
   from the new spec, about 50 s), then delete the old primary pod gracefully, once (it came back as primary after 21 s; a graceful delete may hang when the archiver is blocked, 199 s in lab 26). Never `--force` a primary of a Cluster that is not yet synchronous: that is a failover with possible loss.
   Nothing automates R2 or a force. Then open an upstream issue with `kubectl cnpg status`, that log line and the `show cnpg.config_sha256` of each instance.
   After the manual keys of lab 25 the `cnpg` Kustomization was still "Reconciliation in progress" 10 minutes later: the study reproduced a mechanism that explains such a state (the stuck configuration-uniformity gate above), but it was not shown to be the cause in lab 25 (UNVERIFIED). If it happens again, read `kubectl -n flux-system describe kustomization cnpg` and the plugin and operator pods before waiting.
8. **Check.** `task cluster-verify`, then the per-section checks below. `cluster-verify` does not read the Kustomizations: also run `kubectl get kustomizations,helmreleases -A` and expect all Ready.
   The synchronous replication, the Grafana egress rule and the other 0.4.0 changes are in `CHANGELOG.md`; the synchronous replication was replayed on a reduced lab only (step 4), none of the others on an old cluster.

**Measured, lab 27 sitting 3 (2026-10-26, Scaleway only, 3 CP + 5 W, Talos v1.14.2 to v1.14.4, infra and apps heads of the 0.4.0 branches; one run, UNVERIFIED on OVH and Outscale).** The move from the 0.3.2 tags ran in **ONE invocation**, `task cluster-up PROVIDER=scaleway ROLE=management APPROVE=auto`, with only `talos_version` and `git_ref` changed in the tfvars: **rc 0 in 39 min 13 s, nothing by hand, no second invocation** (sitting 2 needed two, 31 min + 17 min; sitting 1 ended rc 201). The roll of the 8 nodes was about 35 minutes; the presync was applied and the apps ref patched **71 s later** (sitting 2: 80 s), Flux did not revert (read every 3 s), the identity keys were written, "CoreDNS converged: 3 replica(s), hard spread" ran inside the command, and its `cluster-verify` passed (a separate run afterwards: 26 passed, 0 failed, 0 could not be checked). All 40 Kustomizations were Ready **6 min 43 s** after the ref move (sitting 2: 11 min 7 s; sitting 1: 13 min 25 s). The grace default 30 s was carried (flag on 3 of 3 controller managers, Node Leases at 30 s, kubelet status frequency 7 s). **Zero acknowledged commit lost: 113,975 acknowledged by the zitadel-db writer over the roll, 0 missing**, the WAL archive contiguous in both stores (MISSING 0). The primary restart for the sidecar, with the Zitadel pool connected, gave a write gap of **26.3 s** (sitting 2: 33.6 s; sitting 1: 206.4 s before the bound). During the 35 min roll window, probes from the lab host: HTTP 23 failed of 2102 (longest run 1 s), API 12 failed (longest 3 s). On a fresh install the first `cluster-up` ended rc 201 on the known Scaleway load-balancer ACL provider error ("inconsistent final plan", explained by the script) and the same command, run again, ended rc 0. Node operations of the same sitting are in [`resilience.md`](resilience.md): grow 4 to 5 in 10 min 51 s and 10 min 16 s, shrink 5 to 4 in 6 min 56 s to 8 min 15 s (the guard refused until the node-local volumes were evacuated, see "Removing nodes"), dead-worker replacement 378 s; `--even-if-running` needs `--ip=` for a worker too.

**If `cluster-up` stops at the Talos tunnels with "Address already in use", the infra apply is already done: run the SAME command again (lab 28B, 2026-10-30, Scaleway, 3 CP + 5 W; ONE occurrence, so the move from 0.3.2 took TWO invocations).** *What you see:* a few minutes in, after the infra apply, the log says `7/8 tunnels up` and `bind [127.0.0.1]:52100: Address already in use` (the port differs with `TALOS_TUNNEL_OFFSET`), and the run ends rc 201. *What has already happened:* the infra apply COMPLETED ("Apply complete! 10 added, 5 changed, 10 destroyed": the machine configs applied in place, the zone labels on the nodes); no node was rolled, the CNPG presync did not run, the apps ref did not move. *What to do:* run the same `task cluster-up` command again, unchanged. Running it again is safe and it resumes: the converge step skips the nodes already on the target version ("nodes already on the target version are skipped") and the run goes on with the roll, the presync, the ref move, the identity keys, the CoreDNS converge and its own `cluster-verify`. *Measured (3 CP + 5 W):* the first invocation ended rc 201 after **3 min 13 s**; the same command again ended **rc 0 in 37 min 41 s** (41 min 56 s from the first launch), nothing by hand, with `cluster-verify` inside at 27 passed, 0 failed, 0 could not be checked, and 97,072 acknowledged zitadel-db commits, 0 missing. The lab labelled the whole move INCIDENT for the tunnel collision and the rest NOMINAL. *Cause:* the local ports of the Talos tunnels (a block from 50000, shifted by `TALOS_TUNNEL_OFFSET`) lie inside the range Linux gives to outgoing connections (32768 to 60999 by default), so a busy workstation can hold one of them at the moment the tunnel opens; in the lab it was the source port of the lab host's own probes at 1 Hz, nothing listened on it, and the cluster was not at fault. **Fixed in 0.4.1 (infra #422), UNVERIFIED on a cluster:** `talos-tunnels.sh` now respawns, alone, a tunnel whose ssh died on exactly "Address already in use" with nothing listening (up to 3 times, 4 s apart: `OA_TUNNEL_BIND_RETRIES`, `OA_TUNNEL_BIND_PAUSE`), so the move should end rc 0 in one invocation; any other failure is reported at once, as before. Proven mocked only, with a process holding the port as the source port of its own connection (`test-talos-tunnels.sh`); not yet against the real probes of a busy host. If the port stays busy after the retries the script says so and names the way out: reserve the tunnel block (read `/proc/sys/net/ipv4/ip_local_reserved_ports` first and put the block after what is listed there, because `sudo sysctl -w net.ipv4.ip_local_reserved_ports=...` REPLACES the whole list; the script prints the command with the current list in front, or, if it cannot read that list, says so and prints only the read-then-append steps, never a command that would replace the list with the block alone; the setting is lost at a reboot, so to keep it write the same value in `/etc/sysctl.d/`, in the file that already sets `ip_local_reserved_ports` if there is one (`grep -rs ip_local_reserved_ports /etc/sysctl.conf /etc/sysctl.d`), because when two files set it the one read last wins at boot and drops the block), or use another `TALOS_TUNNEL_OFFSET`. On a 0.4.0 checkout the note above applies unchanged. Owner decision of 2026-10-31 (option A): the 0.3.2-to-head move proved in TWO invocations is accepted for 0.4.0; the proof in ONE invocation stays the one of lab 27 sitting 3 above. This note covers the tunnel collision only: for any other stop of `cluster-up`, read its message before running it again. Not a compliance claim.

## From 0.4.0 to 0.4.1 (an existing cluster)

Rung: **TWO moves on Scaleway** (proof labs, 3 control planes + 6 workers, NOMINAL apart from a tunnel port held on purpose), each from the 0.4.0 tags in ONE `task cluster-up`: the first to infra 255e08f and apps 75b546d, the second, **at the heads of the third proof lab, infra 67be1e8 and apps d028aed** (the release is these heads plus documentation-only commits, with the exceptions listed in the line "The proof covers" of `CHANGELOG.md`). In both, Flux followed the apps BRANCH, not the 0.4.1 tag: **the move from `refs/tags/0.4.1`, the one you will run, was not shown** (the tag does not exist until the release; infra pins it then). The second move applied what the first could not show: the Istio DENY policy on the shared Gateway for `/metrics` and `/debug/metrics` and the changed dump-load restore test were both read on the upgraded cluster (below). Still unseen on an upgraded cluster: the new alert `CnpgWalNeverArchived` (nothing provoked it) and the new message of `backup-verify` (it prints only when a check fails, and none did). Not run on OVH or Outscale. Not a compliance claim.

**Supported path (owner decision, 2026-10-24): the previous minor only.** 0.4.0 to 0.4.1; from 0.3.x go through 0.4.0 first ("From 0.3.x to 0.4.0", above).

1. Check out the 0.4.1 tag of this repository. In the tfvars set `git_ref = "refs/tags/0.4.1"` (the examples carry it; a tfvars that leaves `git_ref` unset inherits the new default). OpenAether-apps `refs/tags/0.4.1` must exist. Leave the Talos and Kubernetes pins alone: their defaults are the same in 0.4.0 and 0.4.1 (v1.14.4 and v1.37.1), so the move rolls no node.
2. `task cluster-up PROVIDER=… ROLE=…`, plan read. Expect `0 to add, 3 to change, 0 to destroy`: the machine configs of the three control planes, in place, because the `flux-bootstrap` manifest carries `git_ref`. The run moves the apps ref itself (the GitRepository and the Kustomization are read back, as in "From 0.3.x to 0.4.0", step 5) and ends with its own `cluster-verify`. If it stops at the Talos tunnels on a busy port it now retries that port three times, 4 s apart (`OA_TUNNEL_BIND_RETRIES`, `OA_TUNNEL_BIND_PAUSE`); if it still stops, run the same command again.
3. `task cluster-verify` again once Flux has converged: it has more lines than at 0.4.0 (a profile CNPG Cluster whose `ContinuousArchiving` is not True is red from 300 s of age; the `cluster-identity` ConfigMap is compared with the rendered map), and `kubectl get kustomizations -A` should show all Ready.

**Measured at the lab-proven heads (a third proof lab: infra 67be1e8, apps d028aed, Scaleway, 3 control planes + 6 workers, one run; NOMINAL except that the local port of the first Talos tunnel was held by another process for 7.2 s on purpose).** A `PLAN_ONLY=1` run came first: rc 0 in 1 min 41 s, `0 to add, 3 to change, 0 to destroy`, the 10 servers, 9 images, 12 snapshots and the state buckets identical before and after, but for 3 Loki objects the running cluster wrote itself. Then `cluster-up` ended rc 0 in 6 min 41 s in ONE invocation: `:52000 could not be bound … retry 1/3 in 4s`, then 9 of 9 tunnels up (the same clash at 0.4.0 ended rc 201 and needed a second run). It applied `0 to add, 3 to change, 0 to destroy` (the machine configurations of the three control planes, in place). No node rolled (the boot ids of the 9 nodes and the restart total, 10, are identical before and after). 41 of 41 Kustomizations were Ready on the new revision 4 min 10 s after the ref move, 2 min 43 s after rc 0. Probes at 1 Hz from four vantages over the move: HTTP and API from the lab host 0 failed of 560 each, in the cluster 0 of 1,102 each. Four writers (the platform database, an `ha` database directly and through its pooler, a `light` database): 109,173 acknowledged commits, their ids recorded outside the cluster, 0 missing. `cluster-verify`, inside the run and again afterwards: 31 passed, 0 failed.

**The first move, for comparison (infra 255e08f and apps 75b546d, same shape, NOMINAL).** 7 min 6 s; 41 of 41 Ready 3 min 49 s after the ref move and 2 min 17 s after rc 0; probes 0 failed of 559, 559, 1,092 and 1,093; 37,177 acknowledged commits, 0 missing; `cluster-verify` 31 passed, 0 failed. **By the rule of `CHANGELOG.md` (WORSE: at least 10 s and at least 10 % slower; a figure within about 6 s of a line is "at the edge"; one sample each):** the move, 6 min 41 s against 7 min 6 s, is SAME (−25 s, −6 %); 41 of 41 Ready after the ref move, 4 min 10 s against 3 min 49 s (+21 s, +9 %), is at the edge, resolution about 6 s (2 s under the WORSE line), with no firm label; **41 of 41 Ready after rc 0, 2 min 43 s against 2 min 17 s, is WORSE (+26 s, +19 %)**, the cause not isolated: this move carries more change (apps 42 commits and 35 files against 7 and 11, infra 74 commits and 78 files against 51 and 52) and which Kustomizations took the extra time was not measured; **`PLAN_ONLY=1`, 1 min 41 s against 1 min 31 s (+10 s, +11 %), is at the edge, resolution about 6 s**, with no firm label (WORSE if the figures are taken as measured), and the earlier plan was not alike (its grow step would have created machines). Probes (0 failed in both) and writers (0 missing in both) are SAME.

**What the upgraded cluster showed (same run and shape, durations NOMINAL).**

- The shared Gateway refuses `/metrics` and `/debug/metrics`: 216 probes (27 spellings, 4 hosts, HTTPS and port 80) gave 112 × 403 and 0 Prometheus bodies, against 10 bodies on the 0.4.0 cluster (Grafana's `/metrics` 7, Zitadel's `/debug/metrics` 3, no login), all read from the lab host through an app load balancer whose ACL allowed that host only. The bodies lasted until Flux applied the policy: 2 min 38 s after the ref move, 71 s after `cluster-up` ended. The normal paths answered the same codes, and vmagent still scraped Grafana and Zitadel (`up` was 1 on 4 series, read before, just after the move and at the end).
- The policy applied without an error and with one Istio admission warning: `will deny all traffic to TCP ports under its scope due to the use of only HTTP attributes in a DENY rule`. Harmless today: the Gateway of the apps repository declares only the HTTP 80 and HTTPS 443 listeners (read in the file; the live listeners were not archived). The DENY names no port, so a TCP or TLS listener added to that Gateway later would be denied without a message.
- The dump-load restore test FAILED four times on the 0.4.0 cluster before its first dump (`repository does not exist`), and `RestoreTestFailed` went pending on four series (not firing yet: it fires after its `for: 10m`, and was first seen firing 17 s after rc 0 of the move, an upper bound since the alert was polled, not watched). After the move it SKIPPED four times (18 s) before the first dump, and `RestoreTestFailed` cleared 5 min 20 s to 5 min 35 s after that first run (vmalert evaluates every 5 minutes). After a `cnpg-dump` (18 s) the test PASSED four times (19 s) and `backup-verify` passed twice. In the lab the test Job was started by hand from its CronJob; an upgraded cluster that carried the failure should keep the alert until the next run of the test (not run that way).
- `cluster-security`: 31 of 36 with test 1.6 failed on the first run, 32 of 36 on the second (as in the earlier labs). The failure was the flaky test fixed in this release, not the cluster (`CHANGELOG.md`, Fixed).
- The ExternalSecret `grafana-oidc` stayed in `SecretSyncedError` for the whole lab, before and after the move (the known one: it reads `grafana/oidc`, which only a console step puts into OpenBao), and Grafana's login redirect carried an empty `client_id`. The end-to-end sign-in was not run.

**Not shown:** the move from the tag; a failover or zone drill during a move (so "no split brain" is true there, since no failover happened, and untested); the Grafana to Zitadel sign-in; the `/metrics` rule on the forge (not deployed); OVH and Outscale; a NOMINAL fresh-install wall time at 0.4.0 in the third lab. One run per figure, a development OpenBao bootstrap, one provider, one shape.

**What an operator meets that is new in 0.4.1** (each entry of `CHANGELOG.md` `[0.4.1]` has its rung): `cluster-roll` and `cluster-replace-node` refuse to replace the only copy of a single-instance database unless `--accept-sole-copy=<namespace>/<name>` is given, and an unattended run stops until it is; a bare pod is refused before the drain; the drain of `cluster-roll`, `cluster-upgrade` and `cluster-shrink` is watched and refused after 120 s of no progress behind a budget that allows nothing (`DRAIN_STALL_AFTER`, `DRAIN_STALL_POLL`; 0 restores the plain drain); `cluster-replace-node` reads each surviving etcd member up to three times (`ETCD_READ_TRIES`, `ETCD_READ_PAUSE`); `task cluster-up … PLAN_ONLY=1` reads the plan with nothing created; and the disaster-recovery chain has new knobs: `OA_DR_STABLE_ROUNDS` (5), `OA_DR_STABLE_TRIES` (60), `OA_DR_STANDBY_TRIES` (18) and `OA_DR_ES_OPTIONAL` (see "Where the DR chain may stop" in `disaster-recovery.md`); its `openbao` step now lasts about five minutes, not twenty seconds. **From OpenAether-apps 0.4.1 (applied by the move above, at the ref move):** a route of your own that serves `/metrics` or `/debug/metrics` now gets a 403 from the shared Gateway and no ALLOW policy overrides it; serve it under another path, or remove the policy with a Flux patch. The apps CHANGELOG (`[0.4.1]`, Security) and `OpenAether-apps/docs/public-exposure.md` carry the note, the opt-out and its limits.

## From 0.4.1 to 0.4.2 (an existing cluster)

Rung: **by reading, plus the cloud retest written in `CHANGELOG.md` `[0.4.2]`**, the one place for its figures and their NOMINAL or INCIDENT labels (this section carries none: read it there before relying on this one). 0.4.2 is 0.4.1 plus a CI fix, and OpenAether-apps 0.4.2 differs from apps 0.4.1 by CI, documentation and one VEX data file (`.vex/openaether-apps.openvex.json`, which Trivy and the CI check read and no cluster does). **The move from `refs/tags/0.4.2` itself, the one you will run, is not shown**: the tag does not exist until the release (infra pins it then), and the retest planned in `CHANGELOG.md` moves a 0.4.1 cluster to the 0.4.2 heads, so it follows the branches, as the 0.4.1 retest did, not the tag. Not a compliance claim.

**Supported path (owner decision, 2026-10-24): the previous release only.** 0.4.1 to 0.4.2; from 0.4.0, go through 0.4.1 first ("From 0.4.0 to 0.4.1", above).

**Only the apps ref moves, and nothing is run by hand beyond `task cluster-up`, which moves the apps ref itself (the step that `task cluster-apps-ref` runs alone)**: "From 0.4.0 to 0.4.1" has the mechanics (its steps 1 to 3: the plan to read, the tunnel retry, the checks), with the numbers moved by one. In short: check out the 0.4.2 tag; set `git_ref = "refs/tags/0.4.2"` in the tfvars (the examples carry it; a tfvars that leaves `git_ref` unset inherits the new default, the one behaviour that changed) with OpenAether-apps `refs/tags/0.4.2` existing; `task cluster-up PROVIDER=… ROLE=…` with the plan read, then `task cluster-verify`. The Talos and Kubernetes pins are the same in 0.4.1 and 0.4.2, so no node rolls; the plan should show the same kind of change as at 0.4.1 (the machine configs of the control planes in place, because the `flux-bootstrap` manifest carries `git_ref`, and nothing to add or destroy), by reading, not measured for this move.

## From 0.4.2 to 0.4.3 (an existing cluster)

Rung: **by the cloud lab written in `CHANGELOG.md` `[0.4.3]`** (Scaleway, 3 CP + 6 W, one run, with Flux following the apps BRANCH `refs/heads/claude/0.4.3-rc1`, not the tag), the one place for its figures and their NOMINAL or INCIDENT labels (this section quotes few of them: read them there before relying on it); what a line below says it read and did not run stays at that rung. **This move is two commands, not one**: 0.4.3 is the first release since `cluster-bootstrap-sync` exists (0.4.0) whose Flux controllers differ from the previous one's (0.2.0 through 0.4.2 all pin Flux 2.9.6; 0.4.3 pins 2.10.0, because the `kustomize-controller` image of 2.9.6 carries `brotli-libs` 1.2.0, Critical CVE-2026-111497, and the fix exists in 2.10 only, not in a 2.9 patch), and `cluster-up` never touches the Flux controllers of a running cluster ("Cilium and Flux on a running cluster", below). **This was the first live move of all seven controllers by `cluster-bootstrap-sync`: the command had run before, on one controller (5 s, the first proof lab of 0.4.1); the dry run and `APPLY=1` each ran once here and ended without a refusal.** The move from `refs/tags/0.4.3` itself is not shown: the tag does not exist until the release, and the lab followed the branch. Not a compliance claim.

**Supported path: the previous release only.** 0.4.2 to 0.4.3; from 0.4.1, go through 0.4.2 first.

1. Check out the 0.4.3 tag of this repository. Set `git_ref = "refs/tags/0.4.3"` in the tfvars (as in "From 0.4.0 to 0.4.1", step 1; OpenAether-apps `refs/tags/0.4.3` must exist). The Talos and Kubernetes pins are the same as in 0.4.2 (v1.14.4, v1.37.1): no node rolls.
2. **Flux first, alone:** `task cluster-bootstrap-sync PROVIDER=… ROLE=…` (dry run, exit 3: seven controllers one minor behind, each line "pinned … running …"), then the same with `APPLY=1`. 2.9 to 2.10 is one minor, which the script allows; it refuses while a node is not Ready. It waits for the seven rollouts and reads the tags back. Then `task cluster-verify` must show "Flux controllers run the pinned version". Doing this before `cluster-up` keeps each change readable alone, and `cluster-up` ends with its own `cluster-verify`, which is red on that line while the controllers still run 2.9.6. If the apply exits 1, read "If `task cluster-bootstrap-sync … APPLY=1` stops part way", below, before you run it again.
3. `task cluster-up PROVIDER=… ROLE=…`, plan read, as at 0.4.2 (the machine configs of the control planes in place, `0 to add, 3 to change, 0 to destroy`; the configs now also carry the new `flux-install.yaml` inline manifest; Talos does not update an object that exists, so it is expected to change no Flux object and roll no node, by reading; the lab's figures for the plan and the nodes are below), then `task cluster-verify` once Flux has converged.

**What the lab printed and how long it took (cluster A, 3 CP + 6 W, NOMINAL, the apps branch ref, one run).** The dry run took 20 s. The script exits 3 (`task` itself ends rc 201 and says `exit status 3`) and writes nothing; the versions are those of the 0.4.2 to 0.4.3 move:

```
Flux controllers (pinned in the artifact / running):
  ~ helm-controller              pinned v1.7.1     running v1.6.5
  ~ image-automation-controller  pinned v1.3.0     running v1.2.5
  ~ image-reflector-controller   pinned v1.3.0     running v1.2.5
  ~ kustomize-controller         pinned v1.10.1    running v1.9.6
  ~ notification-controller      pinned v1.10.0    running v1.9.4
  ~ source-controller            pinned v1.10.1    running v1.9.6
  ~ source-watcher               pinned v2.3.1     running v2.2.4
Flux differs from the pin.
  server-side dry run: the API server accepts 43 object(s) of flux-install.yaml.
✗ NOTHING was written (dry run).
```

(The Cilium lines, `= cilium … pinned v1.20.2 running v1.20.2`, sit between the Flux list and "Flux differs from the pin.") `APPLY=1` took 27 s wall, 9 s of it from the apply to the end of the seven rollouts, and ended rc 0:

```
▶ server-side apply of flux-install.yaml (field manager openaether-bootstrap)
✓ the Flux controllers run the pinned versions and every Deployment rolled out.
```

Read back: the spec image AND the pod imageID of the seven controllers equal `infrastructure/opentofu/cluster/bootstrap-manifests/flux-image-digests.lock`, the 15 Flux CRDs are established (`alerts` and `providers` then serve `v1` and `v1beta3`, storedVersions `v1beta3,v1`), and the history of every HelmRelease is identical before and after. `task cluster-verify` then printed `✓ Flux controllers run the pinned version (v1.10.0,v1.10.1,v1.3.0,v1.7.1,v2.3.1)` and two red lines, as expected until `cluster-up` has moved the apps ref, because the tfvars already declare the new one: `✗ the GitRepository openaether follows refs/tags/0.4.2, git_ref declares …` and `✗ GIT_REF of the Kustomization openaether-platform is 'refs/tags/0.4.2', git_ref declares …` (33 passed, 2 failed in the lab, where the declared ref was the branch).

**Expect a transient of about 2 minutes after the sync, and do not read it as a failure.** In the lab, 7 HelmReleases went `SourceNotReady` for 29 to 31 s right after the sync and `ztunnel` went `DependencyNotReady` (on `istio-cni`) for 60 s, and 10 Kustomizations were not Ready, the last of them Ready again about 2 minutes after the sync; **no probe failed**, and the HelmRelease histories show no upgrade or reinstall. The cause of the transient is not established. Two readings exist and neither was tested: the new `source-controller` fetches the artifacts again, or a node-local Flux restart makes every HelmRelease resolve its source again. The lab started `cluster-up` 3 minutes after the sync, once the transient was over; starting it inside the window was not tried. Then step 3: in the lab the plan was `0 to add, 3 to change, 0 to destroy`, the apply `0 added, 3 changed, 0 destroyed`, no node rolled, and the `cluster-verify` that `cluster-up` ends with passed (rc 0 in 13 min 05 s NOMINAL, which is WORSE than the 10 min 30 s of the 0.4.2 retest, cause not established: `CHANGELOG.md` `[0.4.3]` has the comparison).

**If `task cluster-bootstrap-sync … APPLY=1` stops part way** (read from `scripts/ops/cluster-bootstrap-sync.sh` and from `apply.go` of kubectl v1.37.1, not run: the apply of the lab ended rc 0 and none of these paths was seen). Exit 2 is a refusal before any write: nothing changed, and the line names the reason (a node not Ready, a downgrade, more than one minor). Exit 1 naming a Deployment means `kubectl apply` went through (it exits 0 only when every object was accepted) and that Deployment did not finish rolling out within `OA_ROLLOUT_TIMEOUT` (300 s). **Exit 1 with "apply refused" does not mean the apply stopped at the object that failed.** `kubectl apply` tries every object of the file, keeps the errors and exits non-zero at the end. `flux-install.yaml` holds 43 objects, the 15 CRDs before the 7 Deployments, so one refused object (a CRD, say) leaves the others applied, **the Deployments with the 2.10 tags included**: 2.10 controllers then start against a CRD that may still be the 2.9 one (CRDs once replaced are not rolled back: "Cilium and Flux on a running cluster", below). The script exits at once and waits for no rollout; since 0.4.4 it prints the whole error and says that other objects may have been applied (mocked, not run on a cluster).

**Run the script again once the cause is fixed.** Before 0.4.4 it compared only the image tags of the Deployment specs, so after a refused CRD with the Deployments applied, or after a rollout timeout, it printed "run exactly the pinned versions" and exited 0, and `task cluster-verify` was green too. Since 0.4.4 the tags are no longer the proof (mocked; the dry run was also read twice on clusters of lab 35, exit 0 in 15 s and 13 s, no false positive; no refusal path was seen on a cluster): it also requires, for each of the seven Deployments, `observedGeneration` equal to `generation` and `readyReplicas` equal to `replicas`, and each of the 15 CRDs of the artifact to exist and be Established. A refused new CRD or an unfinished rollout ends the dry run with exit 3 and names it, `APPLY=1` applies again, and `task cluster-verify` fails the line "Flux controllers run the pinned version" with the same gap. A refused update of a CRD that already exists leaves nothing to see in the cluster (the old one stays Established), so the script writes a marker file before each apply (`.flux-apply-unfinished-<role>-<provider>` in `infrastructure/opentofu/cluster/`, gitignored) and deletes it after the first apply that is accepted whole: while it exists the dry run ends with exit 3, `APPLY=1` applies again and `task cluster-verify` fails the same line (mocked, not run on a cluster). **Not seen:** the marker belongs to this checkout, so an apply run by hand or from another checkout leaves none, and then the error of that apply is the only trace: read it. To list every refused object by yourself, run by hand, with the cluster's kubeconfig, the command the script runs, `kubectl apply --server-side --force-conflicts --field-manager=openaether-bootstrap -f infrastructure/opentofu/cluster/bootstrap-manifests/flux-install.yaml`: its output lists every refused object with its error, and applying again is safe (server-side apply is idempotent). Fix the cause and apply until it exits 0. Then read `kubectl -n flux-system rollout status deployment/<name>` for each of the seven Deployments (for one that does not roll out: `kubectl -n flux-system get deployments,pods`, `kubectl -n flux-system describe deployment <name>` with the events of its pod, and the controller log), then run `task cluster-verify`. There is no in-place rollback: the script refuses a downgrade and nothing here reverts the CRDs. The way out this repository documents for a state you cannot repair is the rebuild aside ("Cilium and Flux on a running cluster", below); a Flux rollback has no test. Controllers that are down stop reconciliation, not the workloads they already applied (by reading, not exercised).

**Flux 2.10 against this platform (the release notes and the controllers' changelogs, read; both repositories grepped for each point, not run):**

- *Object identity is always on, and the default RBAC no longer grants `create` on `serviceaccounts/token`.* Nothing here uses it: no Flux object of OpenAether-infra or OpenAether-apps 0.4.2 sets `spec.serviceAccountName` or `kubeConfig.configMapRef` (the `edge-*` objects use `kubeConfig.secretRef`, a static kubeconfig, which this does not touch), and no `ObjectLevelWorkloadIdentity` gate is set. **If your own overlay authenticates a Flux object with a ServiceAccount token, bind the ClusterRole of https://github.com/fluxcd/flux2/pull/6139 to the controller before the sync.**
- *`Alert` and `Provider` are `v1` (the storage version); `v1beta3` is still served and deprecated.* The platform's `Provider` `alertmanager` and `Alert` `flux-errors` (apps `base/flux/notification-alertmanager.yaml`) are `v1beta3`, use none of the fields `v1` drops, and validate against the 2.10 schema in both versions; expect a deprecation warning, not an error. An `Alert` of your own with `spec.summary`, or a `Provider` with `spec.interval`, an Azure Event Hub static token or TLS or proxy settings in `spec.secretRef`, loses them on conversion (use `eventMetadata.summary`, `proxySecretRef`, `certSecretRef`). The platform's two objects stay on the deprecated `v1beta3` in 0.4.3: moving them to `v1` is an OpenAether-apps change for a later release, because OpenAether-apps 0.4.3 must still apply on a 2.9.6 cluster until the sync, and `v1` does not exist there.
- *`ImageRepository` tags move to the Flux storage backend.* No `ImageRepository`, `ImagePolicy` or `ImageUpdateAutomation` exists on this platform (the two image controllers run with nothing to do), so the rescan the notes mention has nothing to rescan.
- *Kubernetes:* 2.10 needs 1.37.0 or later on the 1.37 line; the pin is v1.37.1.
- *The other changes of `install.yaml`*, read in the diff against 2.9.6 (the same 43 objects in the same order, none added or removed; 11 of the 15 CRDs differ): the seven images, the readiness probe of `source-controller` and `source-watcher` (`/readyz` on the existing `healthz` port), an `https` port 443 on four Services (no new container port, so no policy changes), the SubjectAccessReview permission in place of the token one, and the CRD schemas of the next point. The file sets nothing for SPIFFE mTLS between the controllers, which the controllers' changelogs say is enabled by configuring the SPIFFE socket and identities: it is off here.
- *The CRD schemas, read in the diff, not run.* `HelmRelease`: `spec.chart.spec` loses the defaults of `reconcileStrategy` (`ChartVersion`) and `version` (`*`) and its `required: chart, sourceRef`; CEL rules on `spec.chart` require `chart` and `sourceRef` again, except when the new `spec.chart.kind` is `OCIRepository` (OCI fields are added under `spec.chart.spec`). `OCIRepository`: `spec` loses the defaults of `provider` (`generic`) and `timeout` (`60s`) and its `required: interval, url`, replaced by CEL rules that require `spec.url` and `spec.interval`. `spec.kubeConfig` of `HelmRelease` and `Kustomization`: the two CEL rules "one of `configMapRef`, `secretRef`" become one, `has(configMapRef) != has(secretRef)`. `GitRepository` and `OCIRepository` gain `status.sourceVerificationFingerprint`. The `v1` of `Alert` has no `spec.summary`, the `v1` of `Provider` has neither `spec.interval` nor `spec.proxy`. The other differences are new optional fields (`ArtifactGenerator`, `status.exportedInputs` of `ExternalArtifact`, `spec.policyChangeDelay` of `ImageUpdateAutomation`, new `Provider` types), the `name` limits of an `ArtifactGenerator` artifact (no `minLength`, `maxLength` 1024) and edited descriptions. No change of behaviour is expected on this platform: no HelmRelease of OpenAether-apps sets `reconcileStrategy`, `helm-controller` 1.7.1 fills in `reconcileStrategy` (`ChartVersion`) and `version` (`*`) itself when it builds the `HelmChart` (`GetReconcileStrategy`, `GetVersion`; the `HelmChart` CRD keeps both defaults), and neither `OCIRepository` nor `ArtifactGenerator` exists on the platform. To see it: a HelmRelease created after the sync should get a `HelmChart` with `spec.reconcileStrategy: ChartVersion`.
- *Read and not proven, 1: Git signature verification.* `source-controller` 1.10.0 re-runs the signature check of a `GitRepository` when the trusted keys change (its changelog), and the CRD gains `status.sourceVerificationFingerprint`, the fingerprint of the keys that verified the current artifact. This touches the opt-in `flux_git_verify` (`spec.verify` with `mode: HEAD` on the `openaether` GitRepository, `docs/signed-commits.md`), which is off by default and off in the labs: nothing here ran it. If you run with it on, expect the current HEAD to be verified again at the first reconcile after the new controller starts (inferred from the description of the field), and read `SourceVerified` on the GitRepository after the sync.
- *Read and not proven, 2: HelmRelease.* `helm-controller` 1.7.0 moves the Helm library from 4.2.4 to 4.3.1, and 1.7.1 changes how a change of `.spec.postRenderers` is compared: the digests are compared on every reconcile and the upgrade is retried, where a failed one used to be reported Ready. The MinIO, Zitadel and Forgejo HelmReleases of OpenAether-apps use `postRenderers`. A release that upgrades at the first start of the new controller with no change of its own would restart its pods: not expected; not seen in the lab (cluster A, one run: the history length, `lastDeployed` and `lastReleaseRevision` of every HelmRelease were identical before and after the sync). To see it, read `status.history` and `status.lastReleaseRevision` of every HelmRelease before and after the sync.
- *Open exposure, not covered: the Flux copy for CAPI children.* The Flux controllers that OpenAether-apps pushes to CAPI children (`cluster-api-clusters/flux-gotk`) are a separate vendored install, still Flux 2.9.6 when this was written (OpenAether-apps 0.4.2 and the 0.4.3 heads) with the same `kustomize-controller` v1.9.6 image, so the same `brotli-libs` finding. This move does not touch it: a child that carries that copy keeps the finding until the copy moves to 2.10. OpenAether-apps #103 does not cover it: it names the earlier move of that copy from 2.8.8 to 2.9.6 and says nothing of 2.10 or of `brotli-libs`. It needs its own issue in OpenAether-apps, not opened when this was written. Since 0.4.5 the copy is Flux 2.10.0 (dis-bzh/OpenAether-apps#215; "From 0.4.4 to 0.4.5").

## From 0.4.3 to 0.4.4 (an existing cluster)

**Run `task cluster-up` (or `task infra-apply`) of 0.4.4 once before a standalone `task cluster-verify`; until then the verifier reports the applied switches as UNKNOWN and exits 1.** Since 0.4.4 it judges Flux and the application load balancer on what the last apply set (the root output `applied_switches`, infra #354), not on the env file read at that moment. A state written by 0.4.3 has no such output until its next apply, so the line "could not read the applied deploy_flux and deploy_app_lb" counts as UNKNOWN, never as a pass. `cluster-up` applies before it verifies, so it writes the output first (read from the Taskfile order and tested with a stub `tofu`, not run on a cluster). A refused or interrupted `task cluster-bootstrap-sync … APPLY=1` is covered in "From 0.4.2 to 0.4.3" above.

**The first Flux sync after the ref move rolls every PostgreSQL Cluster, and `cluster-up` does not wait for it.** OpenAether-apps 0.4.4 changes the PostgreSQL image (dis-bzh/OpenAether-apps#162, dis-bzh/OpenAether-apps#163), so the move restarts every database instance, the replicas first, then a switchover of each Cluster. In the labs `cluster-up` returned rc 0 with its closing verify taken before the roll, and Flux was no reliable signal either (the roll order is not fixed): read the Clusters (`kubectl get cluster`, "Cluster in healthy state"), not Flux, before you call the move done. The steps of the move and what the labs read are in `CHANGELOG.md`, `[0.4.4]`, "Upgrade from 0.4.3"; this section holds only these two points.

## From 0.4.4 to 0.4.5 (an existing cluster)

Rung: **by the cloud runs written in `CHANGELOG.md` `[0.4.5]`** (Scaleway, 3 CP + 6 W, forge OFF, one run per figure, with Flux following the apps BRANCH `refs/heads/lab/0.4.5-rc1`, not the tag), the one place for their figures and their NOMINAL or INCIDENT labels (this section quotes few of them: read them there before relying on it); what a line below says it read and did not run stays at that rung. **The move from `refs/tags/0.4.5` itself, the one you will run, is not shown**: no run followed the tag. This repository has no code change in 0.4.5 (the apps pin moves and documentation is added); its code ran at the 0.4.4 tag in every run. Not a compliance claim.

**Supported path: the previous release only.** 0.4.4 to 0.4.5; from 0.4.3, go through 0.4.4 first ("From 0.4.3 to 0.4.4", above).

1. Check out the 0.4.5 tag of this repository. Set `git_ref = "refs/tags/0.4.5"` in the tfvars (as in "From 0.4.0 to 0.4.1", step 1; OpenAether-apps `refs/tags/0.4.5` must exist). The Talos and Kubernetes pins are those of 0.4.4 (v1.14.4, v1.37.1) and the Flux pin is unchanged: **no `task cluster-bootstrap-sync` is needed and no node rolls**.
2. `task cluster-up PROVIDER=… ROLE=…`, plan read. Both runs read `0 to add, 3 to change, 0 to destroy` (the three control planes' machine configs in place, because the Talos inline manifest carries `git_ref`) and 9 of 9 boot IDs were identical afterwards: expect the number of control planes in "to change", no add and no destroy.
3. **Do not call the move done when `cluster-up` returns: read the Clusters** (next paragraphs), then `task cluster-verify`.

**Every PostgreSQL pod restarts once, both platform Clusters together, and `cluster-up` returns before they are whole.** OpenAether-apps 0.4.5 moves the Barman Cloud plugin from v0.15.1 to v0.16.0. Its sidecar is an init container of every instance pod, so the CloudNativePG operator updates every Cluster that archives through the plugin (`zitadel-db` and `grafana-db`; `forgejo-db` too with the forge brick, which was not run): the replicas first, then ONE planned switchover per Cluster, the old primary last. The operator has one rollout slot per process and no delay between Clusters, so **both Clusters roll at the same time**. It starts on the first Flux sync after the ref move. What the runs read (CLOUD, n=1, forge OFF, so two Clusters):

- **Per Cluster, about 15 s of write interruption in a quiet restart (14.73 s and 14.42 s), and up to about 30 s measured during the move, while the Longhorn upgrade replaced its images on the same nodes (28.15 s plus a second gap of 3.09 s, a combined span of 32.29 s, and 22.06 s), against the owner's target of 35 s.** Do not read "about 30 s" as a bound: the combined span was 2.71 s under the target. The cause of the move's excess over the quiet restart is not established. The Grafana health probe saw 17 s of HTTP 503 at the `grafana-db` switchover in the move (9 s quiet); Zitadel was not probed. On the final head of the apps candidate the write interruption was not measured (no writer ran).
- **How long.** From the first "Recreating instance pod" to "Cluster in healthy state": 59 to 63 s per Cluster in a quiet restart, 204 to 210 s in the move and 178 to 185 s on the final head. The longer figures most likely come from the sidecar image (about 107 MB) waiting in the kubelet's pull queue behind the Longhorn images: its pull events on the nodes of the old primaries read 1:54 to 2:03 "including waiting", against 6 to 9 s for the replicas in the same move, and the Longhorn pull durations are not archived (cause not established). In the move both Clusters ran 2 of 3 instances for 2:30 to 2:37.
- **No acknowledged id missing** (127,604 acknowledged ids checked over three stages, 0 missing; in the move stage the last about 2 s of the direct writers' acknowledgements were not closed, in the two others they were), **no second writer seen** (0 s with two primaries at 1 s sampling), and the pinned writers had 0 acknowledgements after a promotion. ContinuousArchiving reads False for about 1.3 s at each promotion (the operator refuses the history-file archive during the switchover; no WAL segment was missing); the same sampling was not run on 0.4.4.
- **On the clock** (one `cluster-up`): the ref is read back 9:44 after launch; Flux then applies everything at once (Longhorn 1:18, the plugin 15 s, `cnpg`, `flux-egress`); the PostgreSQL roll starts within seconds of `cluster-up` returning (16 s before it in the move, 3 s after it on the final head) and ends about 3:08 to 3:14 after rc 0 in the move (3:02 to 3:08 on the final head). The closing `cluster-verify` (30 passed, 0 failed, 0 unchecked) ended with `cluster-up`, before the Clusters were whole: in the move only its last 16 s overlapped the first replica recreations, and 42 of 45 Kustomizations were on target 1:30 after rc 0; on the final head it ended 4 s before the roll began, and `cnpg` and every Kustomization (45 of 45) were Ready 1:15 before the roll ended.
- **Read the Clusters, not Flux and not `cluster-up`:** `kubectl get clusters.postgresql.cnpg.io -A`, the phase "Cluster in healthy state" on every Cluster (the long name, because `kubectl get cluster` can map to Cluster API's `Cluster` when the CAPI module is installed). A `cluster-verify` DURING the roll was not run.

**Longhorn 1.12.1 to 1.12.2 (a patch hop, same minor).** With the forge OFF the platform has no Longhorn volume (all 16 PVCs of the runs were `local-path` or `local-path-retain`): the hop matters with the forge or an opt-in component, and it was read on two lab volumes. CLOUD, n=1: the HelmRelease took 1:18; the manager DaemonSet is replaced on all nodes together (`maxUnavailable` 100 %), all six CSI sidecars change image and the instance managers are replaced. **The nodes that carried no volume had NO instance manager for 1:25 to 2:10** while the new ones started: do not restart a Longhorn workload or drain a node in the first minutes, an attach there is impossible. An attached volume kept serving (both replicas running, max write gap 0.27 s, no rebuild, the acknowledged-write ledger complete).

- **The engine fix needs one step per volume.** 1.12.2 fixes acknowledged writes lost during a replica rebuild under concurrent unaligned writes (under 4 KiB, to one sector; upstream Longhorn #14451 and #14447). **The fix lives in the engine image, so a volume has it only after ITS engine image is upgraded**, and the automatic engine upgrade is OFF here. The step is in OpenAether-apps `docs/patching.md` (step 6): set `spec.image` of the `volumes.longhorn.io` object to the engine image the cluster now runs (`ei-5830480e`, v1.12.2, in the runs). It took 9.3 s on an attached healthy volume (healthy on every poll, no rebuild) and 2.4 s on a detached one (n=1). A deliberate replica rebuild under writers on the new engine took 35.1 s with nothing lost: **one rebuild, not a test of the upstream race**.
- **An old instance-manager pod stays while an attached volume's engine process still runs in it.** After the live upgrade the sixth old pod stayed 68 minutes (the other five went); detaching the volume would free it (not run), and whether the fix needs the engine process in the new instance manager was not tested. The old engine image went by itself 1 h 00 min after its last reference.

**Children (the optional CAPI module).** The Flux copy that OpenAether-apps pushes to CAPI children moves from 2.9.6 to 2.10.0 **in place**: on one 2-node child (1 control plane + 1 worker), 7 of 7 controllers ran the 2.10.0 set 23 s after the management ref was read back, spec image and image ID equal to `flux-image-digests.lock`, 0 restarts, no CRD update refused (15 Established), the profile Kustomizations stayed Ready and the child's GitRepository was Unknown for 6 s (CLOUD, n=1; the first in-place move of an existing child, no comparator). A child built fresh from the candidate was Ready 9:04 after its Secrets with the same seven controllers (CLOUD, n=1, one Scaleway template, Talos v1.13.9 and Kubernetes v1.35.3).

- **`alerts` and `providers` keep `storedVersions [v1beta3, v1]` on a moved child** (a fresh child has `[v1]`). The API server will refuse a later Flux release that stops serving `v1beta3` until the stored objects are migrated (re-apply them or run a storage-version migration, then patch `storedVersions`). **Migrate them before such a release; the migration was NOT run.**
- **The child's own Flux keeps following its `CHILD_REF`**, and its `flux-egress` declares `v1beta3` until you bump that ref (INFO deprecation logs in the meantime). Bumping it is your next step and was NOT run: the declaration of `v1` through a child's own Flux is unproven.
- **The children's Cilium restarts one agent at a time.** The `<child>-cilium` values of the checked-in child files set `updateStrategy.rollingUpdate.maxUnavailable: 1` on the agent DaemonSet and under `envoy.updateStrategy` (the chart default is 2). **A child file of your own in OpenAether-apps must carry both keys too, or its `check-child-clusters.py` (in its `scripts/` directory; the "Child clusters" step of its `ci.yml`) fails; adding them is the strategy-only Helm change that ran on the live child.** The Helm upgrade that carries it restarted NO pod on the live child (the same four pods, 0 restarts, the child API answered 839 of 839 samples), and a later agent rollout goes one agent at a time: agents unavailable together 2 to 1, and **the rollout takes about twice as long (11.3 s to 22.4 s for the agents, 9.1 s to 17.9 s for envoy)**, with 0 failures on three probes. **Tested only for a strategy-only values change on one 2-node child**: a change that alters the pod template or the ConfigMap is untested ("Never change the Cilium values of a live child", `docs/admin-access.md`).
- A child's Talos and Kubernetes versions are not changed by this release; their life cycle beyond create, delete and this in-place Flux move was not run (dis-bzh/OpenAether-apps#222).

**`Alert` and `Provider` are declared at `notification.toolkit.fluxcd.io/v1`.** It needs Flux 2.10 on the management cluster (infra 0.4.3 or later; a cluster still on Flux 2.9.6 cannot apply `v1`: expected, not run). A fresh 0.4.4 install already stores `v1` (`storedVersions ["v1"]` before and after the move); a management cluster moved in place to Flux 2.10 ("From 0.4.2 to 0.4.3", above) and not reinstalled since stores `[v1beta3, v1]`, and the same migration applies before a Flux release that stops serving `v1beta3`. **Neither kind has a status or a Ready condition: read the Kustomization `flux-egress`** (Ready, inventory `v1`). One real error event reached Alertmanager in 5 s (n=1; not a gain: delivery is 0 to 1 s either way).

**What to read after the move, in this order:**

1. The Clusters: `kubectl get clusters.postgresql.cnpg.io -A`, "Cluster in healthy state" on each, before you call the move done.
2. **The first cron-fired Backup on the new sidecar, the next morning**: `kubectl get backups.postgresql.cnpg.io -A` (the schedules are daily, 03:10 and 03:25 UTC). Backups, restores and point-in-time recovery passed on the new sidecar, but on a cluster that moved from v0.15.1 only manual Backups ran (the two Backups that the schedules create at install completed on a fresh install of the candidate; their plugin version and duration were not read): **the first cron-fired one has not run on such a cluster**.
3. The next weekly scan of OpenAether-apps (Tuesday 05:41 UTC): 59 images instead of 51; the restic VEX statement runs to 2027-01-09 (renewed, not fixed; `check-vex.py` goes red from 2027-01-10 on every pull request).
4. Each Longhorn volume's engine image, if you have Longhorn volumes (above).
5. `storedVersions` of `alerts` and `providers` on each child, before a later Flux release (above).

`kubectl cnpg restart` leaves a `restartedAt` annotation that Flux removes within minutes, without a second roll. **Not shown:** the move from `refs/tags/0.4.4` to `refs/tags/0.4.5` itself (the runs followed moving branch refs, and `cluster-verify` warned "moving ref"), OVH and Outscale, the forge-ON shape, a larger child or another template, and any upgrade from before 0.4.4.

## Which version lives where, and how it reaches a running cluster

The model (infra #408, adopted 2026-10-24): for every pinned thing, **a declared pin, a command that converges a running cluster to it, and a verify check that fails on any difference, in both
directions** (behind and ahead are both a difference; a value that cannot be read is UNKNOWN, never a pass). Rung of everything marked UNVERIFIED: mocked, offline, not run on a cluster.

| Thing | Declared in | Converged by | Checked by (`task cluster-verify`) | Status |
|---|---|---|---|---|
| Talos | `talos_version` (tfvars, else `variables.tf`) | `task cluster-up` (`converge-versions.sh`: one node at a time, refuses a downgrade), `task cluster-upgrade` | "every node runs the pinned Talos" (MIXED fleet named apart) | PROVEN on clouds for earlier releases (1.14.2 to 1.14.4 in lab 25); the 0.4.0 pin UNVERIFIED |
| Kubernetes | `kubernetes_version` | same, through the machine config (no roll) | "every node runs the pinned Kubernetes" | PROVEN on clouds (2026-10-03 climbs) |
| Database spec (CNPG `synchronous`) | `spec.postgresql.synchronous` of the 0.4.0 apps content (`any` / 1 / `required` / `failoverQuorum`), read live from every platform Cluster | `task cnpg-presync` (`APPLY=1`, BEFORE the apps ref; `SCALE=1` for fewer than 3 instances; also sets `smartShutdownTimeout` 5); `cluster-up` runs it and moves the apps ref in the same step, `SCALE=1` under `APPROVE=auto` | per Cluster: the block, ContinuousArchiving, `synchronous_standby_names`, replicas `quorum`/`sync`, FailoverQuorum object | PROVEN on Scaleway (lab 27, run by hand: 2 min 22 s, zero loss, MISSING 0); the single-step order inside `cluster-up` and `smartShutdownTimeout` UNVERIFIED |
| WAL archive of the database-profile Clusters (OpenAether-apps profiles) | a profile with a WAL archiver (barman-cloud plugin, `isWALArchiver`); the label `openaether.io/db-profile` | no command converges it: a Cluster created on an archive path that still holds another Cluster's WAL stays False until the path is cleaned or the Cluster gets a new `serverName` (`OpenAether-apps/docs/traps.md`) | "The profile CNPG Clusters: WAL archiving" (infra #430): every such Cluster in ALL namespaces (not only `OA_CNPG_NAMESPACES`; `rt-*` copies left out) whose `ContinuousArchiving` is not True is BAD once it is 5 minutes old, with its age and the condition message; under 5 minutes it is a warning with the same message, because a new Cluster is not archiving at second 0. **So a polluted profile Cluster younger than 5 minutes is YELLOW (the run exits 0), and only a verify run from 5 minutes of age on turns it red: a verify run right after the Cluster is created cannot fail on it, run it again.** A creation time that cannot be read, or that is more than 60 s ahead of the clock of the machine running the verify (the clock is unknown, and the line says so), gets no grace; up to 60 s ahead is ordinary skew, counts as age 0 and is said on the line. Absent on a Cluster that declares an archiver is a warning under 5 minutes of age and UNKNOWN after; a `light` Cluster (no archiver) has no line. The alert `CnpgWalArchiveFailing` stays at 25 minutes by design. This check reads no alert and needs none; where the OpenAether-apps release you run carries the alert `CnpgWalNeverArchived` (`for: 5m`, it reads the archiver counters, not the condition), it can fire sooner | UNVERIFIED (mocked; the alert rule, where present, also offline); the lab 28C state (a Cluster on a polluted path) has not been re-read with this check, and whether a healthy new Cluster ever shows False before True is not known |
| Apps ref | `git_ref` | `task cluster-apps-ref` (`REF=… APPLY=1`); `cluster-up` runs it (right after the presync when that had work) | "the GitRepository and GIT_REF both follow the declared git_ref" (only with `deploy_flux = true`) | PROVEN on Scaleway (lab 27: 23 s, red and green by mutation) |
| CoreDNS shape | `coredns_ha`, the node count (replicas `min(3, nodes)`, hard spread over nodes) and the zone labels (spread over zones, required with 3 or more) | `task cluster-coredns-ha` (`APPLY=1`); `cluster-up` runs it before its verify; standalone, a patch ends by naming `task cluster-rebalance … APPLY=1` (the zones ended 2, 3, 2 in lab 28B, and the rebalance healed it in 20 s) | "CoreDNS runs the declared replica count and spread" | patch PROVEN by hand on Scaleway (lab 27); the step inside `cluster-up` UNVERIFIED |
| Forgejo brick (the ROLE path of the root Kustomization) | `path: ./apps/flux/${cluster_role}` of the Talos inline manifest `flux-bootstrap`; the forge overlay is `./apps/flux/management-forge` | NOT converged: a live `kubectl patch` only (below); `cluster-up` neither sets nor reverts it | NOT checked | GAP, not built (no tfvar, by decision of this release; issue FF of lab 27) |
| `cluster-identity` keys | rendered map (`local.cluster_identity`, output `cluster_identity`) | `task cluster-identity-sync`; `cluster-up` runs its dry run | "The cluster-identity ConfigMap holds the values the config renders" (only with `deploy_flux = true`; infra #409): a rendered key that is missing or has another value is BAD, with the key names (never the values) and the sync command; a key the config does not render is not judged, because the sync leaves it alone | UNVERIFIED (mocked) |
| Cilium | `CILIUM_VERSION` in `render-bootstrap-manifests.sh`, rendered to `cilium.yaml`, hash in `upstream-artifacts.lock` | no in-place command: **rebuild aside** (below) | "Cilium run the pinned version" (agent and operator image tags) | the BEHIND red case PROVEN once on Scaleway by mutation (lab 27: the `cilium-operator` image set one patch below the pin turned the line red, "BEHIND the pin ... rebuild aside", and green once restored); the AHEAD case and the agent image UNVERIFIED (mocked); no live upgrade exists |
| Flux controllers | `FLUX_VERSION`, vendored `flux-install.yaml`, same lock | `task cluster-bootstrap-sync` (`APPLY=1`); the 0.4.2 to 0.4.3 move (2.9.6 to 2.10.0) ran it once for the seven controllers, and it had run once for one controller (the first proof lab of 0.4.1) | "Flux controllers run the pinned version" (the seven Deployments; only with `deploy_flux = true`) | PROVEN once on Scaleway (3 CP + 6 W, the apps branch ref: dry run 20 s, `APPLY=1` 27 s, the seven controllers on the digests of the lock; `CHANGELOG.md` `[0.4.3]`); the BEHIND red case of the check was seen once by mutation (lab 27, Scaleway: `source-controller` set to v1.9.5 against the pin v1.9.6 turned the line red naming `task cluster-bootstrap-sync`, green once the image was restored); the AHEAD case, the refusal paths and the rollback UNVERIFIED (mocked) |
| CAPI child clusters | `K8S_VERSION`, `TALOS_VERSION` in `apps/clusters/*.yaml` (OpenAether-apps) | Flux applies the file; Cluster API rolls the machines | none: `check-child-clusters.py` is static; nothing compares a child's running versions | GAP, not built |

`git_ref` is converged by `task cluster-apps-ref`, which `cluster-up` runs as one of its steps (with `deploy_flux = true`: a dry run, then the move once it is approved, `APPROVE=auto` or a typed "yes"; without either it stops and names the command). One `cluster-up` moved the ref in the 0.4.3 lab (3 CP + 6 W, the apps branch ref; `CHANGELOG.md` `[0.4.3]`). What does not move a running cluster is editing `git_ref` alone: that sets the new inline manifest, which Talos does not apply over the existing objects (step 5 of "From 0.4.0 to 0.4.1"). A release channel (a semver range over signed tags that Flux follows) is
a 1.0 option, not built; today the apps version is an exact ref converged by the tooling.

`cluster-up` ends by saying what it did NOT change: the Cilium and Flux controllers of a running cluster (the Cilium operator's replica count is the one exception, above), the apps content beyond the ref, the CAPI children, and any other object Talos created
earlier from an inline manifest.

## Enabling the opt-in Forgejo brick on a running cluster (lab 27, FF)

The forge is OFF in the default profiles (docs/forgejo in the OpenAether-apps repository). The path the root Flux Kustomization follows comes from the Talos inline manifest (`path: ./apps/flux/${cluster_role}`), an object `cluster-up` never rewrites (above), and there is **no tfvar** for it. The supported way on a running cluster is one live patch, with the brick's overlay:

```
kubectl -n flux-system patch kustomizations.kustomize.toolkit.fluxcd.io openaether-platform --type merge \
  -p '{"spec":{"path":"./apps/flux/management-forge"}}'
```

Back: the same patch with `./apps/flux/management` (Flux prunes the two Kustomizations and what they applied; what survives the prune, the volumes, has not been exercised). Lab 27 ran the patch: `forgejo-db` and `forgejo` Ready 2 min 30 s later. **`cluster-up` neither sets nor reverts it, `cluster-verify` does not look at it**: after the patch a later `cluster-up` leaves the path alone, and nothing tells you if someone changes it back. A cluster rebuilt from the tfvars starts on `apps/flux/${cluster_role}` again and needs the patch again. This is a gap, not a design: the row "Forgejo brick" of the table above says "not converged, not checked", and the issue stays open. Check by hand: `kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io openaether-platform -o jsonpath='{.spec.path}'`.

## Cilium and Flux on a running cluster

`cilium.yaml` and `flux-install.yaml` are Talos inline manifests, so the rule above applies: a bumped pin reaches a NEW cluster only. `cluster-verify` now fails when the running version differs from the
pin; this is how each one is closed. Written offline; of it only the Flux sync was run on a cluster, three times (nothing to apply at the 0.4.0 retest, one controller in the first proof lab of 0.4.1, and the 0.4.2 to 0.4.3 move, `CHANGELOG.md` `[0.4.3]`); the Cilium path and the rebuild aside were not.

**Flux controllers: `task cluster-bootstrap-sync PROVIDER=… ROLE=…`** (dry run, exit 3 on a difference; `APPLY=1` writes). It checks the committed `flux-install.yaml` against `upstream-artifacts.lock`,
reads the image tag of the seven controller Deployments, and with `APPLY=1` runs `kubectl apply --server-side --force-conflicts --field-manager=openaether-bootstrap` of that file, waits for every rollout
(`OA_ROLLOUT_TIMEOUT`, 300 s) and reads the versions back. It refuses, before any write: a downgrade of any controller; a controller more than one minor ahead of the running one (stricter than upstream,
which says any v2.x can move to any other v2.x: step through the releases); a running controller the artifact no longer has (server-side apply does not prune); and any moment a Talos or Kubernetes roll may be
under way (a node not Ready or cordoned, versions that differ between nodes or from the pin). Relied on: the Flux upgrade guide gives `kubectl apply --server-side -f install.yaml` for a cluster installed with
kubectl (https://fluxcd.io/flux/installation/upgrade/). Take the Flux CRDs into account: they are replaced by the same apply and are not rolled back.

**Cilium: check plus rebuild aside, no in-place command.** The check ("Cilium run the pinned version") and the dry run of `cluster-bootstrap-sync` report the difference; `APPLY=1` on Cilium is refused (exit 5, or 2
with `COMPONENT=cilium`). Why no server-side apply of `cilium.yaml`, although the Cilium guide describes `helm template` plus `kubectl apply` (https://docs.cilium.io/en/stable/operations/upgrade/):
(1) the DaemonSets of `cilium.yaml` roll with `maxUnavailable: 2`, so two nodes lose their CNI agent at once, and `docs/admin-access.md` records a 2-node child that came out degraded from a Cilium change (the page
concerns CAPI children, but the same rolling update is what this would trigger); (2) the guide requires its pre-flight (image pre-pull, policy validation) and says the only tested path is between consecutive
minor releases; nothing here runs the pre-flight; (3) apply does not prune objects a newer render drops; (4) the ConfigMap is overwritten as a whole, and the agent and operator are not ordered. A person who
accepts those risks follows the upstream guide with the same pinned values; this repository neither builds nor tests that path. **Rebuild aside** is the documented way: a new cluster from the new tag, the
data moved (`docs/disaster-recovery.md`), the old one retired.

## Kubernetes first

It reboots nothing, so it isolates the control-plane roll from the node roll.

```bash
# edit kubernetes_version in envs/<role>-<provider>.tfvars, then
task infra-plan  ROLE=management PROVIDER=<p> OUT=tfplan
task infra-apply ROLE=management PROVIDER=<p> PLAN=tfplan
```

Talos reconciles the static pods and the kubelets; wait for every node to report
the new version before moving on. This bypasses `talosctl upgrade-k8s` on purpose.
Measured on a real OVH cluster (2026-10-03, 1.36.3 to 1.37.1), `upgrade-k8s` left the
apiserver unreachable for up to 10 s and the probe service for 6 s; this step measured
2 s on Scaleway and 9 s on Outscale on the same move. It is no gentler, it needs a
`talosctl` that matches the fleet (a 1.13 client refuses 1.36 to 1.37), and the pin
still has to be bumped and applied afterwards.

## Then Talos, in place

Bump `talos_version`, build the image for the new version (the node resources
ignore the image, but the *data source* still has to resolve), apply, then roll.

```bash
# edit talos_version in the tfvars FIRST, then
task image-build PROVIDER=<p> VERSION=<new> ENSURE=1
task infra-plan  ROLE=management PROVIDER=<p> OUT=tfplan
task infra-apply ROLE=management PROVIDER=<p> PLAN=tfplan
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<key> -- --cp-only --upgrade
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<key> -- --workers-only --upgrade
```

The pin moves before the build (`talos-image.sh` compares a pinned `image_id` only
with the image of the version it builds). Each version has its own image state, so a
build never replaces another image; if it fails, re-run, or set `talos_version` back to
the old version to plan the cluster again. Once the climb is verified, `RETAIN=1` keeps the cluster's
version and the one below it and destroys the other images (`cluster-up` runs it, `cluster-upgrade` does not);
its rules, `LIST=1` and `PRUNE=1` are in
[`talos-image/README.md`](../infrastructure/opentofu/talos-image/README.md). The
2026-10-03 climbs ran in that order on all three clouds, on the single-image lane
this replaces.

**Changing `bucket_suffix` starts an empty image state (infra #451).** The state is kept in the bucket
`s3-<project>-<provider>-talos-image`, and `<project>` is the first segment of `cluster_name` plus the suffix
(`oa_project` in `scripts/lib/common.sh`). Under a new suffix there is no state, so the next `cluster-up` builds the
image again (44 s on Scaleway, one run of the 0.4.3 proof), even though the old images are still in the project. On Scaleway
a plan-only check (`task talos-image PROVIDER=scaleway ENSURE=1 PLAN_ONLY=1`) read "7 to add": three block snapshots,
three instance images and the build step, that is a second image of the same name `talos-scaleway-amd64-<version>` in each
zone. The cluster looks the image up by name, and what that lookup returns with two matches, and which image a server
boots from, was NOT tested (left untested on purpose). If the old state object was copied to the new bucket by hand, the plan
reads "7 to add, 0 to change, 7 to destroy", because the snapshot's import bucket name forces a replacement: the install then rebuilt
the image and replaced the three images instead of reusing them, which a cluster still using them can feel (a replaced image
broke the next plan of another cluster in infra #93, closed). Keep one suffix per project, or delete the old images first. Rung: one plan-only
check and one install on Scaleway (3 control planes + 6 workers), n=1; the install was INCIDENT overall (a provider stock-out and the LB-ACL trap, #361).

`talos_version` is the node's Talos, not the machine-config contract: the module renders under a
capped one (`config_contract` in `modules/talos/main.tf`, which says why). A bump to 1.14 changes
the installer image in the config; offline renders under provider 0.12.0 show nothing else, but
no `cluster-upgrade` has run under it yet.

**After pulling a provider pin**, the committed `.terraform.lock.hcl` of `cluster/` and `talos-image/` already
names the version (docs/supply-chain.md): a plain `tofu init` in `infrastructure/opentofu/cluster` is enough, and
an init that says the lock does not match the constraint means the PR forgot `task lock-providers`. That task
moves every provider within its constraint: read the next plan. A clone that still has an older local lock
(from before it was committed) is fixed by deleting that file and running `tofu init`.

**On Outscale the image build dominates the whole upgrade.** The image is
registered from a snapshot imported through a provider-side queue: 8 min on
2026-08-18, over 60 min on 2026-07-25. It blocks before a single node is touched,
and no node ever boots from it — the roll installs from the Image Factory
(`installer_image`). It is required only because `image_id` is unpinned, so the
data source resolves the OMI by a name carrying the version. `ReadSnapshots`
tells you where the import really is; the apply's "Still creating..." does not.


`--upgrade` calls `talosctl upgrade`, which keeps the node's disk, identity and
etcd membership, drains it itself, and refuses a control-plane upgrade that would
cost etcd its quorum. One node at a time, health-gated between each, and
re-runnable: a node already on the target version is skipped. Control planes
first — a worker needs a healthy control plane to drain against.

### The cluster has to be able to lose a node

Check this before rolling, not after a drain has waited out its timeout:

```bash
kubectl describe nodes -l '!node-role.kubernetes.io/control-plane' | grep -E '^Name:|^  cpu '
```

Requests must leave one node's worth of room. Measured 2026-08-15: Scaleway's
three `DEV1-L` workers sat at 72/47/27% and every drain went through; OVH's
three `b3-8` at 78/99/100% and the first drain waited out its full 900s with no
eviction error to show for it — the evicted pods simply had nowhere to go, so
the budgets they belong to never recovered. Add a worker or a bigger flavour
before rolling; that is a prerequisite, not a symptom.

### What actually blocks a drain, and the two gates that clear it

**A CNPG primary is unevictable while it is primary.** The operator publishes a
`<cluster>-primary` budget at `disruptionsAllowed=0 / currentHealthy=1 /
expectedPods=1`, and `nodeMaintenanceWindow` does not relax it — measured on
Scaleway 2026-08-15: with the window on, CNPG deletes the *replica* budget and
keeps the primary one. That is the whole 900s drain.

So the roll sets **`spec.enablePDB: false`** on every CNPG cluster while it
rolls, and back to `true` on exit. That removes both budgets, primary included;
the operator's own webhook recommends it over the maintenance window. The
primary is then evicted like any other pod and CNPG fails over to a replica —
an unplanned failover, which is what the node reboot was going to cause seconds
later anyway. The maintenance window stays set alongside it, because that is
what tells the operator to reuse the PVC instead of reprovisioning an instance
that node-local storage could not move. On exit the roll checks the restore: it
waits about two minutes (3.5 measured with the apiserver down) for each cluster's
`<cluster>-primary` budget and every owning Kustomization, then exits non-zero
naming what is left. Ctrl+C ends that wait ("restore NOT verified", exit 130); a
roll stopped between nodes says so instead of "complete". The verdict comes after
the last node is replaced, so do not re-run replacement mode to clear it: it
replaces every node again. Fix what is named by hand and run
`scripts/ops/backup-state.sh`, which `task cluster-roll` skips after a non-zero
exit. `task cluster-upgrade` stops at the first roll that
ends this way: if it is the control-plane roll, the workers are not rolled.

**Everything else quorum-shaped blocks it too.** Three runs on 2026-08-14 stopped
on three different pods — CNPG replicas, `kube-state-metrics`, then `openbao-1`
on a raft budget wanting 2 of 3 — with no CNPG primary involved in the last one.
The shape was always the same: the roll arrived at the next node while the
previous one's workloads were still rejoining. So before cordoning, it waits
until **every budget covering a pod on that node reports
`disruptionsAllowed >= 1`**.

It waits only on budgets that can still recover (`currentHealthy < expectedPods`).
Some are zero by construction — `<cluster>-primary`, Longhorn's
`instance-manager-*`, a single-replica `kube-state-metrics` — and waiting on
those is waiting forever.

If a drain still times out, the roll **refuses** and names the pods rather than
rebooting the node under them. Do not force past it: the version this replaced
warned and rebooted anyway, which left `zitadel-db` stuck mid-switchover and
`grafana-db` with no active instance. Re-run the same command once the pod is
healthy — nodes already on the target version are skipped.

```bash
# what is refusing, on the node the roll named
kubectl get pdb -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
ALLOWED:.status.disruptionsAllowed,HEALTHY:.status.currentHealthy,EXPECTED:.status.expectedPods

# CNPG state — the qualified name is required: on a cluster carrying CAPI,
# `kubectl get cluster` means clusters.cluster.x-k8s.io, not this one.
kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,\
NAME:.metadata.name,PRIMARY:.status.currentPrimary,READY:.status.readyInstances

# and, for one database in detail (plugin installed by `task setup`)
kubectl cnpg status <cluster> -n <ns>
```

### Never reboot a node that still hosts a Longhorn RWX volume

A worker that hosts both the share-manager pod of an RWX volume and a pod mounting it did not finish a graceful `talosctl reboot` in lab 12
(Scaleway, Longhorn 1.12.1, Talos 1.14, apps #124): Talos stayed in `unmountPodMounts` (`nfs: server ... not responding`) for more than
12 minutes, twice, and only a provider hard reset ended it. So **never reboot, shut down or `talosctl upgrade` such a node undrained**.
`cordon_drain` (used by `cluster-roll`, `cluster-upgrade`, `cluster-shrink`) now waits, after the drain, until no share-manager pod and
no pod mounting a Longhorn RWX claim is left on the node (`RWX_CLEAR_TIMEOUT`, 300 s by default); when something stays it uncordons the
node, lists the pods and refuses to go on. By hand: drain, then
`kubectl -n longhorn-system get pods -o wide | grep share-manager` must show another node. Offline test: `scripts/dev/test-rwx-drain-gate.sh`.
Not yet proven on a cluster: that a drained node then reboots in about 1.5 minutes (the apps repo also shortens the RWX NFS timeouts).

### A worker that holds an attached RWX share-manager does not drain (lab 28, I3)

Rung: observed on ONE cluster (OVH, lab 28, 3 control planes + 6 workers, 2026-10-29: three attempts on the same worker, one with the product path); the cause is read from that lab, the procedure below was NOT run on a cluster. The 0.4.1 code (the stall watch described at the end of this section) is mocked offline and was run once on Scaleway with a stand-in stall: the original stall was NOT reproduced. Not a compliance claim.

**Symptom.** `task cluster-roll PROVIDER=… -- --node=<worker>` (and a plain `kubectl drain`) on a worker that carries the Longhorn share-manager of an attached RWX volume (in the lab that worker also held the only instance of a single-instance CNPG cluster, the `light` profile; in 0.4.0 the roll did not stop for such an instance; since 0.4.1 it asks first, see "A node replace destroys the data of a single-instance database" below): the survey is clean, then "Cordon + drain" waits its 900 s (`error when evicting pods/instance-manager-... in longhorn-system ... global timeout reached`) and the roll REFUSES ("could not be drained (timeout 900s) - refusing to reboot it under workloads that would not move"), **rc 201 after 1,026 s (17 minutes, INCIDENT)**. No damage: the budgets and the Flux Kustomizations are restored, the node is uncordoned and not rebooted, no other node left Ready, 0 of 6 database writers lost an acknowledged commit, HTTP 0 failed samples of 1,065. The same roll on a worker WITHOUT them: rc 0 in 789 s (13 min 09 s, NOMINAL). `cluster-upgrade` and `cluster-shrink` use the same drain; they were not tried on such a worker.

**Cause (as read in the lab).** Two budgets that allow no disruption. (1) Longhorn's `instance-manager-*` budget of the node, kept while the node holds an attached volume (node-drain-policy `block-if-contains-last-replica`; listed above as zero by construction): an RWX volume's share-manager keeps one attached, and the roll cannot evict the instance manager. (2) A single-instance database has a primary budget of `minAvailable: 1` with 0 disruptions allowed, and no replica to switch to: a plain `kubectl drain` waits on it for ever. The roll turns the budgets of the CNPG Clusters it knows off, so in the lab it was Longhorn's budget that held the roll, but the single instance has nowhere to go either way (its volume is node-local): its database is down for as long as the node is out (913 s in the lab). The RWX check of `cordon_drain` ("holds no Longhorn RWX share-manager or client") runs AFTER the drain returns, so until 0.4.0 a drain that never returned never reached it; since 0.4.1 the drain is watched (end of this section).

**Before you roll such a worker** (not run on a cluster; steps 1, 2 and 4 are plain reads and the proven roll):

1. See what the node holds:
   ```bash
   NODE=<worker>
   kubectl -n longhorn-system get pods -o wide | grep -E "share-manager|instance-manager" | grep "$NODE"
   kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,INSTANCES:.spec.instances,PRIMARY:.status.currentPrimary
   kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,NODE:.status.currentNodeID
   ```
2. Roll the workers that hold none first: 789 s each in the lab, no acknowledged commit lost.
3. For the worker that holds one: with an RWX volume, stop the workloads that mount the claim (scale them to 0), wait until the volume shows `detached` and no `share-manager` pod is on the node, roll, then scale them back: their writers are down for that time (the accepted RWX gap is about 100 s on a failure, this is a planned stop). With a single-instance database, announce its downtime for the roll (913 s measured) or give it a second instance first (the `standard` profile).
4. Do not force: do not delete a budget or the pod by hand to get past the wait (the lab did once, in a drill, and it cut the single instance). A refused roll has restored everything: fix the cause and run the same command again, nodes already done are skipped.

**Since 0.4.1 (infra #417; mocked offline, then run on Scaleway with a stand-in stall, see the end of this paragraph).** Nothing predicts which node will not drain: the RWX check exists because the drain is the cure on a node that holds a share-manager and works, so a "node holds a share-manager" refusal would stop rolls that go through today. The drain is WATCHED instead. `cordon_drain` (so `cluster-roll`, `cluster-upgrade` and `cluster-shrink`) runs `kubectl drain` in the background and reads the pods of the node every 10 s (`DRAIN_STALL_POLL`); it stops the drain, lets the usual refusal path run (node uncordoned, budgets and Flux restored, `rc 201` as a bare `task` shows it) and names what it saw when, for 120 s (`DRAIN_STALL_AFTER`), **the same pods remain on the node, none of them is terminating, and a PodDisruptionBudget that allows 0 disruptions (and is not short of a pod) covers one of them**. The message lists those pods and budgets, and the Longhorn share-managers and RWX clients still on the node (the volumes), so the refusal is designed to come after about 2 to 3 minutes (the 120 s window plus the start of the drain: a design figure, not a measurement) instead of 900 s (1,026 s in the lab: INCIDENT, OVH, 3 control planes + 6 workers). A drain that evicts pods, whose pods are winding down (a long grace period), or that waits on nothing a budget forbids, is left to `kubectl` and its own timeout as before; on a node that drains, nothing changes except that the end of the drain is noticed within 0.2 s. A signal (Ctrl+C, SIGTERM, SIGHUP) that arrives while the drain runs kills it, whichever script runs it (a background `kubectl` would ignore Ctrl+C and outlive the script; a signal the caller ignores, SIGHUP under `nohup`, stays ignored, as for a foreground drain), and takes the same refusal path: the node is uncordoned and, unattended, the run dies with the budgets and Flux restored; a SIGTERM sent to `cluster-roll` alone used to let the drain finish and now ends it. A stop asked before the drain started does not end it. **Run on Scaleway (a proof lab, 3 control planes + 6 workers, writers and probes running).** A worker holding one pod behind a budget that allows 0 disruptions (a stand-in: one replica, `minAvailable: 1`, no volume) was refused 2 min 24 s after the drain began, rc 201, the message naming the pod and the budget; the node was uncordoned at the refusal and the budgets and Flux restored 8 s later, the whole command took 4 min 34 s (a refusal is the designed outcome). Ctrl+C and a SIGTERM sent to the script alone, 20 s into a drain: the node was given back, no `kubectl drain` was left running, 11 s from the signal to everything restored, rc 201, the node never rebooted. A clean worker roll under writers took 452 s, NOMINAL (790 s in lab 28B, 789 s on OVH; that difference is not explained by a 0.4.1 change: the cluster had fewer, smaller volumes), with HTTP 2 failed samples of 449 (two of 1 s), 0 for the API, and no acknowledged commit lost. **What is NOT shown:** the stall of lab 28 as such: with three Longhorn replicas on six workers the share-manager and the instance manager were evicted within 10 s, the drain took 18 s and the node was replaced (7 min 17 s, NOMINAL), so the watch was not triggered by its original cause; the lists of RWX clients and volumes in the message (none stayed behind); SIGHUP on a real apiserver (mocked only); and that no drain which would have gone through after more than 120 s of standing still behind such a budget exists. If a lab meets one, raise `DRAIN_STALL_AFTER`; `DRAIN_STALL_AFTER=0` restores the plain foreground drain. A plain `kubectl drain` of the node of a `light` database stays blocked by its budget (above), but `cluster-roll` turns that budget off and does not stop on it: when the roll goes through, a `light` database is lost, not blocked, and since 0.4.1 the roll asks first (see "A node replace destroys the data of a single-instance database" below).

### A pod without a controller is refused in seconds, not after the drain timeout (lab 25, D6)

Rung: observed on ONE cluster (Scaleway, lab 25, 3 control planes + 5 workers, on a `--cp-only` roll); the 0.4.1 code is mocked offline and was run once on Scaleway (3 control planes + 6 workers). Not a compliance claim.

Bare writer pods (no controller) sat on a control plane of lab 25: `kubectl drain` printed "cannot delete Pods that declare no controller" at once, yet the roll stalled 900 s (INCIDENT, 3 control planes + 5 workers) and then ended in "could not be drained". Why the roll waited is NOT established (the refusal of `kubectl` is immediate; the waits that come before the drain, on the CNPG clusters and on the budgets, are the candidates, and the message prints the drain timeout whatever really ran out). So the answer no longer depends on it: since 0.4.1 `cordon_drain` reads the pods of the node FIRST, before the CNPG waits, the budgets wait, the cordon and the drain, lists those that `kubectl drain` would refuse (kubectl's own rule: no owner reference with `controller: true`; DaemonSet pods, static pods and finished pods are not counted) and **refuses at once, naming them, with the node untouched** when the roll is unattended (`--yes`, `APPROVE=auto`); attended, it asks "Drain … anyway?" and, on yes, goes on as before (the drain then refuses them, and the old question follows). A pod list that cannot be read only warns: `kubectl drain` stays the judge. Delete the pods (or put them under a Deployment) and run the same command again.

**Run on Scaleway (a proof lab, 3 control planes + 6 workers):** a roll of a worker carrying a bare pod and a stray client pod was refused naming both ("Nothing was changed"), budgets and Flux restored, rc 201. **The refusal comes after two per-node plans, so it is not "in seconds" from the command.** The `cluster-roll` of a node runs two `tofu plan` checks (41 s and 55 s there) BEFORE `cordon_drain`, whose pod read answers in under a second: the refusal came 96 s after the node was named and 2 min 41 s after the command started (147 s the first time). "Refused in seconds" holds from the start of the drain stage; counted from the command, a refusal under 60 s was NOT met. Making the same refusal from the survey before the first node, as the sole-copy question below does (33 s there), would answer in about 25 s by the same figures (an estimate, not done).

### A node replace destroys the data of a single-instance database (`light` profile; lab 28B, I17)

Rung: observed on ONE cluster (Scaleway, lab 28B, 3 control planes + 6 workers, 2026-10-30); the question in the roll is coded in 0.4.1: mocked offline, then run once on Scaleway (3 control planes + 6 workers). Not a compliance claim.

A `light` database (OpenAether-apps profile: 1 instance, node-local `local-path-retain` volume, no backup) has its only copy on the disk of its node. `task cluster-roll -- --node=<worker>` and `task cluster-replace-node` destroy the old machine and create a new one with a new disk, so **the data of a `light` cluster on that node is destroyed**. Lab 28B: the roll of a worker that held `lab27-light` finished (rc 0 in 790 s, NOMINAL, drain completed), 42,583 acknowledged commits of the test writer were gone, and the cleanup after the replace REFUSED the volume ("primary of record: its data was on the replaced disk"), too late to change anything; lab 27B met the same refusal. The single instance did not hold the roll there (no RWX share-manager on that node, unlike the case above), and 0.4.0 did not stop for a `light` database; since 0.4.1 it asks first (end of this section).

This is outside the zero-acknowledged-loss rule, by the owner's decision of 2026-10-30: `light` is documented as "node-local storage ... lost with its disk, no backup, data you can lose" (the database profiles page of OpenAether-apps), and the rule covers `ha`, `standard`, the platform's databases and the forge.

**Before you roll or replace a node** (plain reads):

```bash
NODE=<worker>
kubectl get pods -A -l cnpg.io/cluster --field-selector spec.nodeName="$NODE" -o wide
kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,INSTANCES:.spec.instances
```

A pod of a Cluster with `INSTANCES` 1 on that node is a `light` database whose data goes with the node. Move its application to `standard` or `ha` first (another copy then exists), or accept the loss.

**Since 0.4.1 (infra #425; mocked offline, then run on Scaleway: see the end of this paragraph).** Before the first node is touched, the survey of `cluster-roll` and of `cluster-replace-node` names every CNPG Cluster that declares ONE instance and whose volume is pinned by its own node affinity to a node this run replaces (a replicated volume, such as Longhorn, is not pinned, and its data survives the node, so such a Cluster is not named), and asks `Replace anyway and DESTROY the data listed above? [y/N]`. **`--yes` / `APPROVE=auto` does not answer it**: unattended the roll refuses, changes nothing, and prints the exact flag for each Cluster; the loss is accepted by name, `--accept-sole-copy=<namespace>/<name>` (repeatable), after the `--` of the task: `task cluster-roll PROVIDER=… -- --accept-sole-copy=<namespace>/<name>`, and the same for `task cluster-replace-node`. A read that fails refuses (an unanswered question is not "no database"), and so does a node of the run whose Kubernetes name cannot be read from its address: the run names the address and changes nothing, it does not ask about fewer nodes than it replaces. `--dry-run` does not read the databases: the plan it prints does not mention this loss. It is not asked for `--upgrade` (the disk is kept) nor for `cluster-shrink` (which already refuses any node-local volume). **What to expect:** an unattended roll of a cluster that carries a `light` database now stops until that flag is given; this is the point. It warns and asks; it does not move or protect the data (a second instance does). **Run on Scaleway (a proof lab):** the unattended roll of the worker that held a `light` instance was refused 33 s after the command started, rc 201, naming the Cluster, its pinned node and the exact flag, with no `Destroying` or apply line in the log; attended, answering yes to the roll and no to the question ended "aborted by operator" with the node unchanged; with `--accept-sole-copy=<namespace>/<name>` the roll went through (7 min 17 s, NOMINAL) and the instance was destroyed as accepted, with the 9,078 acknowledged commits of its writer: asked for by name, outside the zero-loss rule by the owner's decision above.

### Never reboot a worker undrained when it carries a CNPG instance

A node reboot WITHOUT a drain leaves the CNPG instance pods of that node in phase `Succeeded` (the kubelet's graceful shutdown stops postgres with exit 0) and
CNPG 1.23.1 never restarts them: both databases down, Zitadel and the Gateway answer 503 (lab 11, 30+ minutes; the traps page of the OpenAether-apps repository). `cluster-roll`,
`cluster-upgrade` and `cluster-shrink` drain first, so they are safe; a hand-typed `talosctl reboot` or `shutdown` is not. After an undrained reboot:
`kubectl get pods -A --field-selector=status.phase==Succeeded`, then delete the CNPG pods listed (never their PVC). Newer CNPG operators (the apps pin moved past 1.23) are
not known to share the defect; the habit costs nothing. The roll tooling does not guard a reboot it does not run (infra #358): this page is the guard.

### A database left "Failing over" after the roll

The roll finishes, the API never blinked, and minutes later a CNPG cluster sits
at `Failing over` or `Switchover in progress` and does not move. Seen twice on
2026-08-15, both times the same shape: the demoted primary waits for the
switchover to finish while the *target* replica waits for WAL that only a
running primary would produce. A third instance can be perfectly healthy
throughout.

Restarting the operator does nothing. Deleting the **target's** pod resolves it
in about a minute — it restarts, finishes its recovery, and the cluster elects:

```bash
kubectl get clusters.postgresql.cnpg.io -n <ns> <cluster> \
  -o jsonpath='{.status.currentPrimary} -> {.status.targetPrimary}{"\n"}'
kubectl delete pod <targetPrimary> -n <ns>
```

`kubectl cnpg promote` is not the answer here, as far as it was seen: once (n=1),
with plugin 1.23.6 against a 1.23.1 operator, it exited 0, printed "will be
promoted" and left `targetPrimary` untouched, and the cause was never separated.
The plugin and the operator are both 1.30.1 now and `promote` has not been run
again since (OpenAether-apps #36, open).

The first apply after a `talos_version` bump used to fail once on OVH and
Outscale with "Provider produced inconsistent final plan" (upstream
`siderolabs/terraform-provider-talos` #352, fixed in 0.12.0, which is pinned).
The module replaces each machine-config apply on a version change
(`replace_triggered_by`), so the bump goes through in one apply: the 2026-10-03
climbs ran through `cluster-upgrade`, which has no retry, on all three clouds. The
workaround stays until a run without it passes (#83).

## What to check, beyond "it came back"

After each node, and again at the end:

- **its name is unchanged** — a `talos-xxxxx` entry means the hostname did not
  hold, and the next reboot will orphan another node object
- the node count has not grown, and etcd still reports every member
- the probe's FAIL count has barely moved
- **`tofu plan` is empty.** If it wants to replace nodes, the boot image and the
  running version have disagreed — that plan would take the cluster down. Stop
  and read § Node image drift before running anything else.

```bash
task infra-plan ROLE=management PROVIDER=<p> STRICT=1   # exit 2 = not converged
```

## Iterating on the roll itself, without rebuilding the cluster

Fixing this script used to mean redeploying an 85-minute cluster in order to
exercise its last twenty minutes. It does not have to: both moves below were
used on a live cluster on 2026-08-15, and
[`scripts/dev/roll-lab.sh`](../scripts/dev/roll-lab.sh) is them, made repeatable.
It refuses to run unless the tfvars name a disposable environment **and** the
kubeconfig reaches the cluster that state describes, and it prints what it is
about to change before changing it.

```bash
scripts/dev/roll-lab.sh status <provider> --offset <n>   # what a resume would skip
scripts/dev/roll-lab.sh resume <provider> --offset <n>   # re-run the roll, minutes not hours
scripts/dev/roll-lab.sh inject-cnpg-deadlock <provider> --offset <n>
scripts/dev/roll-lab.sh cleanup <provider> --offset <n>  # uncordon what was left behind
```

**Resume.** A node already on the target version is skipped, so a fixed roll can
be retried in place: `resume` runs `rolling-replace.sh <p> --upgrade
--workers-only --yes` after checking the preconditions the roll itself discovers
too late — a live cluster, and one Talos tunnel per node.

**Inject.** The deadlock in § A database left "Failing over" cost four cloud
rolls to characterise and reproduces in about two minutes: cordon the node
holding a cluster's primary and delete that pod. Its `local-path-retain` PVC
pins it to the cordoned node, so it cannot come back, and CNPG stalls. The
command asserts with the roll's **own** detector and exits non-zero if the
deadlock did not appear — it cannot quietly report a success. `cleanup` undoes
it; CNPG heals once the pod can be scheduled again.

Cheaper still, and where a gate fix belongs first:
[`scripts/dev/test-rolling-replace.sh`](../scripts/dev/test-rolling-replace.sh)
exercises the same logic against a stub kubectl in seconds, with no cluster.

## Going back

An upgrade is not undone by running the upgrade backwards: `converge-versions.sh`
refuses a pin below what the fleet runs ("that is a DOWNGRADE"), and so does
`cluster-upgrade`. What exists is Talos's own A/B switch, and an etcd restore.
Both were run on Scaleway on 2026-10-12 with the `0.1.0` and `0.2.0` tags (Talos
1.13.9 and Kubernetes 1.36.3 to 1.14.2 and 1.37.1, 3 control planes + 2 workers,
the 1 Hz probe of the section above running). One provider, by hand: the timings
are Scaleway's, the mechanism is Talos's. The rest is what was **not** measured.

### A worker: `talosctl rollback`

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
talosctl -n <node-ip> rollback          # boots the previous partition
kubectl uncordon <node>                 # when the node is Ready again
```

Back on 1.13.9 and Ready in 21 s and 39 s. It also worked with Kubernetes already at
1.37.1: the worker came up with kubelet v1.37.1 and ran Cilium and the prober.
`cluster-verify` stays red, `the fleet is MIXED on Talos`, until the node is rolled
forward again; a second `rollback` on the same node switches back to the newer
partition, and `task cluster-upgrade` rolls it forward the usual way. It is valid only
while the node's previous partition still holds the version you want: a further
upgrade overwrites it.

### A control plane: not across a minor that bumps etcd

⚠️ **`talosctl rollback` on a control plane from Talos 1.14 to 1.13 breaks etcd.**
The node boots, joins as Ready, and its etcd crash-loops:

```
discovery failed ... error: version "3.7.0" is not supported
```

Talos 1.14.2 ships etcd 3.7 and the upgrade writes its storage version (3.7.0); Talos
1.13.9 ships etcd 3.6.12, which refuses that data. `etcd members` still lists the
member (membership is not health), so read `talosctl service etcd` on the node. With
two of three control planes rolled back the quorum was lost and the API was down for
about 11 minutes, until a second `rollback` on those two brought them forward again.
Do not roll back a second control plane to see whether the first one is fine.

### A control plane: restore a snapshot taken before the upgrade

The way back for the control planes is a restore, and it needs a snapshot that
**predates the first control plane of the upgrade**. `task cluster-upgrade` takes it for
you before its first step (`backups/etcd/pre-upgrade-etcd-<timestamp>.snap.gpg` in both
artifact buckets, encrypted, `gpg -d` it first; no retention removes it) and refuses to
start when it cannot, unless `UPGRADE_SKIP_SNAPSHOT=1`. By hand: `task etcd-snapshot`
or `talosctl etcd snapshot`, taken on the version you will return to.

```bash
talosctl -n <node-ip> rollback                      # every node, workers included
talosctl -n <cp-ip> reset --graceful=false --reboot \
  --system-labels-to-wipe EPHEMERAL                 # each control plane: wipes etcd
talosctl -n <one-cp-ip> bootstrap --recover-from=etcd.snapshot
```

Measured: three etcd members 52 s after the `bootstrap`, five nodes Ready, the API
answering again 4.3 minutes after the first `rollback` (236 consecutive failed probe
seconds), etcd 3.6.12 again, `cluster-verify` 14/14 once the pins were lowered. **Every
change since the snapshot is gone**: a ConfigMap written after it was missing
afterwards, one written before it was there.

### What does not go back

- **Kubernetes.** `talosctl upgrade-k8s --to 1.36.3` on a 1.37.1 cluster answers
  `unsupported upgrade path 1.37->1.36`. A restore after the Kubernetes bump was not
  tried (the drill held Kubernetes at 1.36.3): start the way back from a snapshot
  taken before the Talos step, and bump Kubernetes only once the Talos step has soaked.
- **The Terraform state and the pins.** After the restore, lowering `talos_version` in
  the tfvars makes `infra-plan` plan `talos_machine_secrets.this[0] must be replaced`
  (the provider replaces the secrets when the version goes down; `prevent_destroy`
  stops an apply, and a regenerated PKI would be worse than the problem). The state has
  to go back too, to a copy taken before the climb: `task cluster-upgrade` writes one
  (`<state key>.pre-upgrade.<timestamp>` in the replica, listed by `task backup-state -- --list`,
  never pruned), because the replica's "newest five" generations are all written during the
  climb. Until then leave the pins where they are: the
  cluster runs the old version and `cluster-verify` reads `MIXED`. Not measured: copying
  a pre-climb state back.
- Not measured either: other clouds, Proxmox, a Longhorn or CNPG workload across the
  restore, and a control plane rollback inside a Talos minor (a patch), where etcd's
  storage version does not move and it may well work.

## Replacing a node rather than upgrading it

`--upgrade` cannot carry a disk or zone change — those need a new VM. Same
script, without `--upgrade`: it drains, applies a targeted `-replace`, and waits,
one node at a time. That path *does* need the new cloud image to exist.

A new **schematic** is a different matter and `--upgrade` does carry it, since
2026-08-19. It did not before: every gate compared the Talos version tag, so a
node on the old schematic at the target version was greeted with "already runs
v1.13.8 — skipping" and a change to the system extensions could be delivered by
no supported path. The roll now reads the schematic off the node
(`talosctl get extensions` publishes it) and rolls a node whose version matches
but whose image does not.

### A live control plane is stopped gracefully first (0.4.0)

When the replacement path (no `--upgrade`) replaces a control plane that is alive, the roll drains it, then stops it with `talosctl shutdown` and waits (up to 300 s) until it stops answering, and only then removes its etcd member and destroys the VM. Why: at every control-plane replacement of the earlier path, 4 or 5 of the 5 workers stopped renewing their Lease for 46-97 s and healthy workers went NotReady; with the graceful stop first the stalls were 8-9 s and no healthy worker flapped, in 2 replacements of ONE lab on ONE provider (the figures, the arms and what is not proven: [`resilience.md`](resilience.md), "Healthy workers go NotReady ... F-CPFLAP"). **Cost: about 4 minutes more per control plane** (the whole roll of 3 control planes: about 12 minutes more). `--dry-run` prints the step. It is skipped, with a warning and no other change, when the cluster has fewer than 3 control planes or any control plane does not report a healthy etcd; a refused shutdown or a node that does not stop in time does not end the run either (the node was cordoned by the drain and stays so until the roll's uncordon, as in a replacement without the stop). Not concerned: `cluster-replace-node` (a dead node cannot answer; its path is unchanged) and the in-place `--upgrade`. The shipped step has not been run on a cloud yet.

### A node size change is an in-place update, on every provider

⚠️ `instance_type` (Scaleway, Outscale), `flavor_name` (OVH) and
`cpu_cores`/`memory_mb` (Proxmox) are not replacements: the provider stops,
resizes or reboots the instance and keeps its disk. So `task infra-apply` plans
N updates and 0 destroys, and applies them to **every node at once**. Measured
on OVH only, on 2026-08-15: six nodes went into `VERIFY_RESIZE` together and the
apiserver was unreachable for several minutes. For the other three, the verdict
comes from the provider source at the versions resolved on 2026-09-26 and from
an offline plan with the real provider binaries, not from a live bump (#51). `rolling-replace`'s "one node at a time"
guard did not catch it: it counted what a plan would DESTROY, and a resize
destroys nothing. It now also refuses a plan that changes another node (below).

**Do not route it through the roll.** Measured on Scaleway, 2026-10-02: with
`instance_type` raised, `task cluster-roll -- --workers-only` replaced worker 0
and then, in its config step, resized all three control planes in place within
25 s; the apiserver behind the load balancer was unreachable for 56 s. `-target`
pulls in dependencies, and the destroy count cannot see a resize. The roll now
plans both steps before it cordons anything and refuses a plan that changes
another node (`foreign_changes`): against that cluster, with a size change
pending on all six nodes, it stopped at worker 0 before the cordon, naming the
three control planes and the other two workers.
Whether OVH's, Outscale's and Proxmox's targeted config step drags other nodes
along has not been measured; the same refusal covers them if it does.

**Go one node at a time, in place.** `kubectl drain` the node, `tofu plan
-target=<that server>` and check it is exactly one update, apply that file, wait
for Ready, `kubectl uncordon`, next node. Measured on Scaleway the same day,
three control planes then workers: etcd 3/3 after each, 5 failed one-second
probes in 241 and none longer than 1 s, about a minute per node. It has no
budget or etcd gate beyond what you check by hand.

Two cases would turn a size change into a replacement: Scaleway's
`replace_on_type_change`, and on OpenStack a node whose recorded flavour is
empty (for example because the flavour was deleted). A replacement would be
worse, since every node would be destroyed at once.
[`tests/node-size-change.tftest.hcl`](../infrastructure/opentofu/cluster/tests/node-size-change.tftest.hcl)
checks that Scaleway's flag stays unset.

## A replacement that stops after the old VM was destroyed (provider out of stock)

`task cluster-roll -- --node=<n>` and `task cluster-replace-node` destroy the old VM and then create the new one. If the create fails, the cluster is left one node short. Observed in lab 27 (Scaleway, 2026-10-26, three times in one day, each 5-10 minutes): `resource POP2-4C-16G is out of stock` for the control-plane instance type in one zone, after the destroy. State it left: 2 of 3 control planes (etcd quorum 2), the node cordoned, its Node object and etcd member gone, the server in the OpenTofu state **tainted**, and, because the restore could not reach the API in time, the Flux Kustomizations `cnpg`, `forgejo-db` and `openaether-platform` still suspended and every CNPG PodDisruptionBudget removed. The recovery took 71 minutes, most of it detours.

**What changed after the lab (UNVERIFIED on a cloud, covered by offline tests only):** the exit restore of the roll is now repeated (`RESTORE_TRIES`, default 6, every `RESTORE_RETRY_WAIT`, default 15 s) until the API reads it back, so a roll that dies on a briefly unreachable API no longer leaves Flux suspended and the budgets gone; and a re-run is no longer refused because of the tainted server. Read the end of the roll's output anyway: it names what is still suspended or missing.

**The sequence that worked in the lab** (observed; the order matters):

1. Check the damage, read-only: `kubectl get nodes` (the control plane is absent), `kubectl get kustomizations -A` (suspended ones), `kubectl get pdb -A -l cnpg.io/cluster` (none), etcd on a surviving control plane (`talosctl etcd members`: 2 members, healthy).
2. Wait for the provider to have stock again. Retrying is cheap: the next step does it. In the lab the provider answered again after about 10 minutes the first time, after about 70 the last time. Nothing in the cluster gets worse while two control planes and every worker run, but do not start another node operation until the node is back.
3. Run **`task cluster-replace-node PROVIDER=<p> NODE=<node name> APPROVE=auto -- --even-if-running --ip=<private address of that node>`**. `--ip` is needed because the Node object is gone, **for a worker as well as for a control plane** (`tofu output control_plane_private_ips` and `worker_private_ips` list the addresses; without it the run stops with the exact command, lab 27 sitting 3); `--even-if-running` because the provider may still list the half-created server as running or stopped. It destroys the tainted server and creates a new one. If the provider is still out of stock it fails the same way and restores Flux and the budgets again on exit; wait and run it again. In the lab the same command restored the budgets and the suspends every time it ran. At the lab heads (before the change above) it first needed `tofu untaint '<server address>'` (the plan destroyed 2 resources, at most 1 expected); that is no longer asked for, and if you still meet that refusal, `tofu untaint` of the named server is the manual way out.
4. Expect the node Ready and etcd 3/3 within minutes of the create (11:37:33 in the lab, one create after the last stock-out). Then check `kubectl get kustomizations -A` and the CNPG budgets are back (`task cluster-verify PROVIDER=<p>`).

**What did not work in the lab, so do not start there:**

- `task cluster-node-state` says `recover`, and `task cluster-node-recover` is a hard reboot that refuses without a typed yes and does nothing for a VM that was never configured.
- A plain `task cluster-up`: its plan waits 15 minutes on the `talos_cluster_health` data source for a node that has no Talos configuration yet, then fails.
- Powering the VM on by hand: a VM whose private NIC was not yet attached never became reachable. Let the replace recreate it.
- A targeted `tofu apply` of the machine configuration: it waited 15 minutes on the port guard; killing it left a state lock (`tofu force-unlock <id>`, only after checking that no `tofu` process of yours still runs).

**Why the replacement cannot create first (design, not implemented).** The new node must carry the old name, private address (IPAM) and, for a control plane, a fresh etcd member after the old one is removed, so the two VMs cannot coexist without a different identity; create-before-destroy would be a new node (new name and address) and a removal, which is the grow-then-shrink path, not this one. A pre-check is possible where the provider exposes availability: the Scaleway Instance API lists, per zone, the stock state of each commercial type (available, scarce, shortage) under its products/servers/availability endpoint; a check before the destroy would refuse to start when the type is in shortage in the zone. It is provider specific (OVH, Outscale and Proxmox have no equivalent listed here), racy (stock can go between the check and the create) and has not been verified against the live API, so it is left as an issue, not code.

**The same provider answer at an install (`task cluster-up`; a third proof lab, Scaleway, 3 control planes + 6 workers, ONE occurrence, INCIDENT).** `cluster-up` creates machines too (an install, a grow), and a create can be refused the same way; only the install was seen. At a fresh install at the 0.4.0 tags the first run ended rc 201 after 5 min 33 s on two errors: the known load-balancer ACL error, and a worker that the provider created `stopped` (`expected state running but found stopped`, in fr-par-3). The same command, run again, ended rc 201 three times in a row (after 1 min 26 s, 1 min 29 s and 1 min 28 s) on `resource POP2-4C-16G is out of stock` for that worker, and the fifth run created it and ended rc 0. From the start of the install to rc 0: 20 min 25 s (the two earlier installs took 10 min 13 s and 10 min 54 s, also INCIDENT: the ACL error, and in the second an image build as well; this install's first run built the image too). Nothing in the cluster was damaged: nothing was configured yet, the servers already created kept running (and billing) while the command waited, and the stopped server was tainted, destroyed and created again by the next run. **What to do:** run the same command again, unchanged, until the create succeeds; do not change the shape (a zone, a node count) to get around it unless you mean to. The provider's availability API was no guide in this occurrence: it read `shortage` for that zone and `scarce` for the other two, and still read `shortage` after a create had succeeded. `cluster-up` has no automatic retry. Whether another provider, zone or type answers like this was not studied.

## A node that is already dead

`task cluster-roll` needs every node Ready and drains each one before it is touched; a dead node can do neither. Use `task cluster-node-state PROVIDER=… NODE=…`
(read-only, names the next command), then `task cluster-node-recover` when the provider says the machine runs, or `task cluster-replace-node` when it is stopped, in
error or gone. The second one runs the same replacement as the roll for that one node (`rolling-replace.sh --dead --node=…`), after a survey of the survivors (each surviving control plane's etcd is read up to three times, `ETCD_READ_TRIES`, so one failed read no longer refuses the replacement: infra #401, mocked offline; a member silent on every try is still refused and named) and
with the etcd member removed before the Node object. The dead node's disk is wiped like any other's, so the survey also asks about a single-instance database whose only copy sits on it (section "A node replace destroys the data of a single-instance database"). The roll itself now also waits for each rebooted control plane's kube-apiserver to serve before it goes on
(#42). The procedure, the drills and what is UNVERIFIED are in [`resilience.md`](resilience.md).

## Adding nodes: `cluster-up` creates the machine BEFORE it asks (a 0.3.x design, unchanged)

Raising `workers` or `control_planes` in the tfvars and running `task cluster-up` **without `APPROVE=auto` already creates and configures the new machine before the first question is asked.** This was established in lab 27 (sitting 3, a grow 4 to 5 started as a plain `task cluster-up`: "machines created" and "configured worker:4" were printed before the plan, which then said 0 to add) and from the code: it is not a regression of 0.4.0. `_grow-nodes` was already ahead of the plan in `cluster-up` at tag 0.3.2, by design (infra #59): a node added to a cluster that is already bootstrapped cannot be built and configured by the apply of the plan, because its Talos port is reachable only through a tunnel that opens after the machine exists, so `scripts/bootstrap/grow-nodes.sh` creates the machines (a plan of the provider module alone, refused if it deletes or resizes anything), opens the tunnels and configures only the new nodes, and the usual plan then finds nothing left to add. **What runs before the first question of `cluster-up`, in this order:** the checks of the key, the env file, the S3 credentials, the passphrase and the buckets (`ensure-buckets.sh --preflight`); the image build (`image-build ENSURE=1`: it plans, and applies only when the Talos image must be built or imported, which creates the image bucket's objects and the image at the provider without asking); the rendering of the bootstrap manifests; `converge-versions --check` (reads, writes nothing); then `grow-nodes.sh` (creates and configures the machines the state does not hold; a no-op on a fresh cluster and when no count rose); only then the phase-1 plan, the node-delete guard and the question. So **a run of `cluster-up` that you meant as a plan is not free when a count rose, nor when the image is missing**: it spends money. The question protects the apply of the plan (and the roll that follows), not the growth. **To only read the plan, add `PLAN_ONLY=1`** (`task cluster-up PROVIDER=… ROLE=… PLAN_ONLY=1`, infra #412; off by default, so `APPROVE=auto` and every other run are unchanged): the checks and the buckets run as always, the image build is planned and, if it would be built, reported ("it WOULD be built") and not built, the manifests are rendered, `converge-versions --check` runs, `grow-nodes.sh --plan-only` lists the machines it would create and the nodes it would configure without creating, applying, refreshing or opening anything, then the phase-1 plan is made and shown with the node-delete guard on it, and the run ends rc 0 with "plan only: nothing was created". When the grow step would act, the phase-1 plan is not taken (it can wait up to 15 minutes on the health of nodes that have no configuration yet) and the run says so. It still ensures the state buckets (the backend needs them), renders the manifests locally, runs `tofu init` and, on a bootstrapped cluster, opens the local Talos tunnels as `task plan` does, and it records no rung receipt. The one-time copy of a pre-#69 single image state to its own key (a push and a rename in the state bucket) is a write, so a plan-only run leaves it for a real run and plans against that state as it stands. Rung: mocked (`test-cluster-up.sh`, `test-grow-nodes.sh`, `test-talos-image.sh`), then run twice on Scaleway (3 control planes + 6 workers). (1) The drill, on a bootstrapped cluster with `workers` raised by one in the tfvars (NOMINAL): rc 0 in 1 min 31 s; the servers (10), the instance images (9), the block snapshots (12) and the object listings of the state buckets were identical before and after, and the four machine resources of the new worker were listed as "WOULD be created". The phase-1 plan itself was not reached there (the grow step would act), so that a plan on a bootstrapped cluster opens the local Talos tunnels stays UNVERIFIED on a cluster. (2) **With the Talos image missing (a fresh account) the run cannot stop at a plan it can read:** it said the image "WOULD be built (and was NOT)", then the phase-1 plan failed with `no image found` nine times (3 control planes + 6 workers) and the run ended rc 201, nothing created. Scaleway, OVH and Outscale read the image by its name in that plan, so a plan-only run needs the image to exist; only Scaleway was seen, OVH and Outscale are read from the modules. The banner and the task description say so since 0.4.1. The default order is not changed: moving the growth behind the question means a second question and a new order in a path proven on three clouds, an owner decision.

**The plan after a grow can show the existing workers as changed (infra #420).** Lab 28 (OVH, a grow, NOMINAL): once the grow step had created the machine, the plan said "0 to add, 5 to change": `talos_machine_configuration_apply.worker[0..4]` with a new `machine_configuration_hash`, applied in place, and no reboot was seen. So the machine configuration of every existing worker is re-applied when one is added; a replacement would show as a replace, this does not. Why the hash changes is not established (a reading of the code only); seen on OVH (this lab) and again on Scaleway (a proof lab, 3 control planes + 6 workers, a grow from 6 to 7, NOMINAL: "0 to add, 6 to change", applied in place, no reboot), UNVERIFIED on Outscale; whether it can be avoided is left to 0.5.0.

## Removing nodes

Lowering `control_planes` or `workers` in the tfvars used to make OpenTofu destroy the
highest-index machine and its data volumes with no drain, no etcd leave and no Node delete. `cluster-up`,
`infra-apply` and `grow-nodes.sh` now refuse such a plan, and removal has two commands of its own, like destroy:

```bash
# lower the count in envs/<role>-<provider>.tfvars, then
task cluster-shrink-plan PROVIDER=scaleway     # read-only: what goes, and can the cluster lose it
task cluster-shrink PROVIDER=scaleway PLAN=shrink-management-scaleway.json
```

The scope comes from the plan OpenTofu itself makes, never from the tfvars; `cluster-shrink` derives it
again and refuses if it moved. Only the highest indexes can go, a worker run may take several (one at a
time, highest first), a control-plane run takes one, and below three control planes it wants
`-- --allow-below-ha` on both commands. One worker and one control plane stay at least.

| | worker | control plane |
|---|---|---|
| reversible | Longhorn eviction, drain | etcd snapshot, etcd leadership handed off, drain |
| the member's point of no return | | `etcd leave` |
| the machine | `talosctl shutdown`, then delete the Node | the same |
| irreversible | targeted destroy of exactly that node's resources, data volumes included | the same, and its load-balancer membership |
| after | refresh the outputs and tunnels, apply the remaining nodes' config one at a time, empty plan, `cluster-verify` | the same |

It refuses before touching anything when: the plan changes more than the removal (another edit pending, a
disk count edited with its machine staying, a node delete tofu does not attribute to a lowered count); a
volume is pinned to the node (CNPG or local-path data: move it first); Longhorn would have fewer nodes than a
volume has replicas; the workers that stay cannot carry the CPU requests; a node is not Ready; etcd has not
the members it should. "Down" is never taken from the node's own tunnel: Talos must accept the shutdown, a
control plane that is not the one going must stop reaching the machine twice, and its Node must read NotReady.
A run that stopped half-way is finished by running `cluster-shrink-plan` and `cluster-shrink` again; a node
already out of Kubernetes and down, an etcd member already gone, are skipped.

**Evacuating a node before a shrink (the guard refuses until node-local volumes are gone; it is not weakened).** `cluster-shrink-plan` refuses with the volumes named, and since this pass it prints the commands below for them. **Observed, not scripted** (lab 27 sitting 3, Scaleway, the worker holding forgejo-db-1, openbao-1, grafana-db-2, loki-1 and a vmselect cache volume; about 3 minutes by hand; the commands are the generic form, the lab did not record its exact lines): (1) `kubectl cordon <node>`. (2) For a CNPG primary on the node, switch over first (`kubectl cnpg promote <cluster> <replica instance> -n <namespace>`; the lab's controlled switchover of forgejo-db had a 35.5 s write gap). (3) For every CNPG instance and StatefulSet pod on the node: delete its PVC, then its pod, so that CNPG or the StatefulSet recreates it on another node (`kubectl -n <namespace> delete pvc <claim>`; `kubectl -n <namespace> delete pod <pod>`). An OpenBao member leaves the raft first (`bao operator raft remove-peer <id>`) and re-joins when its pod is back (the lab's member was back in 29 s). (4) **Delete the retained PersistentVolumes too** (`kubectl delete pv <name>`): a `Retain` volume stays as `Released`, still pinned to the node by its node affinity, and the plan keeps refusing until it is gone. (5) `task cluster-shrink-plan PROVIDER=…` again: it must now plan the removal alone; then `task cluster-shrink PROVIDER=… PLAN=<file>` (7 min 10 s in the lab for one worker, 6 min 56 s and 8 min 15 s on a fresh cluster). Deleting a PVC deletes that instance's data: take the Backup of the preamble first, and only evacuate an instance whose Cluster has another healthy one. The guard itself (`pinned_pvs`) is unchanged.

**Measured on a real cloud, 2026-10-04**, on a 3 control plane cluster at Talos 1.14.2 with Cilium and no Longhorn or
CNPG on it: a worker, then one control plane (3 to 2), on each of Scaleway, OVH and Outscale. Every run ended with
`cluster-verify` green (13/13 after a worker, 12/12 after the control plane, which reads `~ NOT HA` at two), etcd with
exactly the members left, and the provider's API listing exactly the machines left (no volume, port, address or
NIC of the removed node). The targeted destroy was exactly the bundle read: a worker is 5 or 6 resources, a control
plane 3 (Outscale) to 5, plus the load balancer's membership updated in the same apply. An authenticated
`/readyz` through the load balancer each second, during the control-plane removal: Scaleway 12 failed of 350
(eight isolated timeouts over 40 s, then four instant failures in a row about 20 s before the end of the run:
attributed, not isolated, to the probe reading the kubeconfig while `task kubeconfig` rewrote it, as for OVH's
worker below), OVH 13 of 374 (isolated, over 76 s), Outscale 13 of 220 (longest run 3 probes, over 57 s). The
isolated failures are the load balancer still sending one request in three to a control plane that has left etcd;
a client that retries does not see them. OVH's span matches its health check (5 × 15 s); Scaleway's is shorter
(40 s against 75 s) and the membership update in the same apply was not timestamped, so what ended the failures
there was not separated. Taking the member out of the load balancer first is not built; its effect was not
measured. Worker removals: Outscale 1 failed probe of 215, OVH none (apart from the moment `cluster-verify`
rewrote the kubeconfig the probe was reading); Scaleway's was not probed. The probe read the live kubeconfig until
the OVH worker run and a private copy after.

On Scaleway the cluster was then grown back to 3 + 2 with one `cluster-up`: `cluster-verify` 13/13, and
`cluster-idempotency` passed (empty plan, the five nodes unchanged).

One limit: the closing step applies every pending machine-config update, one node at a time, not only the one the
counts cause, so a machine-config edit made in the same tfvars rides in with the removal. Make it separately.

**Longhorn, Scaleway, 2026-10-04** (Longhorn 1.13.0 on the encrypted user volumes): a volume whose only replica
sat on the worker going away, holding a checksummed blob written from a pod on the other worker. A second volume
wanting two replicas was refused (`wants 2 replicas, 1 node(s) would remain`). Without it, the removal asked
Longhorn to evict the node, the replica moved to the worker that stays before the drain began, the volume stayed
healthy and attached, the blob's checksum held, and the Longhorn node entry went with the node. Longhorn's webhook
refuses a node edit while it is syncing that node's disks ("please retry later"), so the eviction request is
retried.

**CNPG, Scaleway, 2026-10-04** (CloudNativePG 1.30.1 on a cluster of one control plane and two workers, two instances
on a one-replica Longhorn class, 1000 rows written): the replica sat on the worker going away. The removal opened
CNPG's maintenance window and dropped its budgets before the drain, the instance came back on the worker that
stays with its volume, both instances held the 1000 rows, the cluster read healthy with two instances, and the
budget and the window were put back at the end. That cluster is also the non-HA shape (one control plane), and the
removal ran on it unchanged.

A second run put the **primary** on the worker going away (the same cluster shape, a writer pod on the worker that
stays inserting one row a second through the read-write service). The drain evicted it, CNPG failed over to the
replica on the other worker and recreated the old primary there as a replica with its volume; the cluster read
healthy with two instances, both held the 1000 rows, and of 368 inserts 2 failed (a failing run of 2 s) and every
acknowledged one was on the new primary. The budget and the window were put back at the end.

Not measured: Proxmox, and a removal that stops half-way on a real cloud.

## The Secrets encryption key (etcd) — not rotatable in place

Kubernetes Secrets are encrypted in etcd with the `secretbox` provider (XSalsa20-Poly1305), set through
`cluster.secretboxEncryptionSecret`. It is Kubernetes' recommended local provider, but XSalsa20-Poly1305 is not among
the AEAD modes ANSSI PA-079 R12 lists (GCM, CCM, EAX, ChaCha20-Poly1305). **Documented deviation:** Talos offers only
`secretbox` and `aescbc` here, and `aescbc` is not an AEAD at all. A KMS v2 provider would replace it, but only with a
KMS outside the cluster; OpenBao inside it would be circular.

The key is one `random_bytes` (32 bytes) in the tfstate, which is encrypted client-side, and in every control-plane
machine config. Losing it makes every Secret in an etcd snapshot unreadable.

**There is no rotation procedure here, on purpose.** The machine config takes a single key, so replacing the value
(or tainting `random_bytes.etcd_encryption_secret`) leaves the existing Secrets encrypted under a key the
apiserver no longer holds. A two-key rotation (add the new key, re-write every Secret with
`kubectl get secrets -A -o json | kubectl replace -f -`, drop the old one) is the usual Kubernetes sequence, but whether
Talos can be given the second key has not been verified or run. Until it has, the only path known to be safe after a
suspected key leak is a new cluster, re-seeded from OpenBao. Do not rehearse the sequence above on a cluster you need.
