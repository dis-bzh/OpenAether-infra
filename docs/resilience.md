> 🇫🇷 [Version française](resilience.fr.md)

# Losing a node, a control plane or a zone: what survives, what you run, how it is proven

Release 0.4.0, milestone M4. Rung: **mocked/static** (stub tests, rendered manifests, unit tests of alert rules), then **drilled once on a real cloud**: lab 21 (Scaleway, 3 control
planes and 4 workers over three zones, 2026-10-21) ran the drills at the end of this page. Its numbers, which pass criteria were met and which were not, are in the table "Measured in lab 21"
right after the drills; what stays UNVERIFIED is the last section. Not a compliance claim.

## What this promises, and what it does not

The management cluster is built by OpenTofu. **Nothing in the cluster replaces a dead node on its own**, and nothing scales its nodes: what Cluster API manages
stays Cluster API's (optional modules for the child clusters), what OpenTofu manages stays OpenTofu's. For the management cluster, 0.4.0 means:

1. **Survive** the loss of one worker, one control plane, and (with nodes spread over three failure domains) one zone, without a customer interruption beyond a
   blip, through replicas, spreading and disruption budgets. Targets: availability 99.9 %, an HTTP failure run of at most 10 s (re-posed 2026-10-26, below), a database write gap of at most 30 s.
2. **Say so loudly**, with an alert whose text names the command to run.
3. **Rebuild** the dead node with documented, tested operator commands.

| Target | Value | Where it comes from |
|---|---|---|
| Customer HTTP blip | longest run of consecutive failed samples at most 10 s, AND failed samples at most 10 % of the drill window (1 Hz probe) | owner decision, 2026-10-26 (was: at most 5 s in a row, 2026-10-19, and at most 5 failures in total) |
| Database write gap | at most 30 s | same; measured 24 s (primary killed), 12 s (switchover) in lab 15c |
| Database acknowledged commits lost | **zero** | owner rule, 2026-10-22: synchronous quorum replication (`dataDurability: required`) on both databases; criteria in OpenAether-apps `docs/resilience.md`, "Zero-loss proof"; NOT run on a cluster yet |
| Availability | 99.9 % | same |

**The HTTP criterion (D1), re-posed on 2026-10-26.** The target is: the longest run of consecutive failed samples is at most 10 s, and the failed samples are at most 10 % of the drill window, both measured by the 1 Hz probe. Measured so far: a longest run of at most 9 s in every drill of labs 25 to 27; failed-sample fractions of 2-3 % from a pod inside the cluster and up to 9.2 % (40 of 436 samples) from the lab host. Said plainly: the 10 % is **fitted to these measurements**, not derived from a need of a user; the old criterion (at most 5 isolated failures in total) was **never met since lab 15c**; two vantage points are used because a single lab-host log had holes (one gap of 10.9 s), which a pod inside the cluster does not share. Not measured: what a real client sees, and the fractions on OVH and Outscale. The older lab tables below keep the verdicts they were given against the criterion of their day.

The write gap is **bounded, not zero**: PostgreSQL has one writer, so writes stop while a replica is promoted (a client that retries masks it, the OpenAether-apps guide "Surviving a database failover from your own application"). What is zero is the loss of acknowledged commits. A true 0 s write path needs a distributed database and is not planned. Writes **block** (nothing is lost) when no replica is available: the alert `CnpgSyncReplicaMissing` says so.

**A planned in-place restart of a primary is not a switchover.** When the Barman plugin sidecar has to be added, the operator restarts the primary where it is (no promotion), and with a client pool connected and `smartShutdownTimeout: 5` the write gap measured **33.6 s** in lab 27 sitting 2 (2026-10-26, one run; 206 s before the bound; the figure of 12-25 s that an earlier text gave was an expectation, not a measurement). 6 s of it was a first pull of the sidecar image on that node. That is 3.6 s over the 30 s target: the 30 s class describes a switchover or a failover (12-24 s measured), not this restart, which happens once, during the 0.3.x to 0.4.0 move ([`upgrade.md`](upgrade.md), "The primary restart").

## Why a pod on a dead node is not rescheduled at once

Kubernetes evicts the pods of a node that stopped answering only after the 5 minute not-ready / unreachable toleration it adds to every pod. A workload with
two replicas on two workers keeps serving meanwhile; a workload with one replica is down for those 5 minutes plus the reschedule. So the audit of the platform
bricks (OpenAether-apps, `scripts/check-ha.py`, in CI) requires, for every Deployment and StatefulSet: two replicas, a hostname spread, exactly one
PodDisruptionBudget that allows exactly one disruption, nothing that can strand a pod on three workers; and a **reasoned list** (`scripts/ha-allowlist.yaml`) of
the ones that stay single, with what their loss means. Deleting the Node object of a machine that is gone frees its pods immediately instead of after 5 minutes:
`task cluster-replace-node` does that.

Worker-loss and zone-loss behaviour needs room: the CPU requests of the workers must fit on the workers that stay. The 3 x 4 vCPU examples were
roll-able with about 0.8 vCPU to spare (`capacity.md`, derived from lab 16); the HA work of M4 adds about 345 m of CPU requests (derived from the manifests:
Kyverno admission, CNPG operator, ESO controller and webhook, metrics-server, the Zitadel login, the second Alertmanager), leaving about 0.45 vCPU. Measured in lab 21 the platform requests about 9 vCPU (223-228% of a 4 vCPU worker), not the derived 7.85: the Scaleway and OVH examples ship 4 workers of 4 vCPU (owner
decision 2026-10-21; 3 would be refused by the gate), which pass at 74-76% of its limit; for the loss of the zone that holds two of the four workers 200% stay for 224%
(`capacity.md`: pods stay Pending until the zone returns; 5 workers would hold on the arithmetic). The gate of
`task cluster-roll` says so before it touches anything; `ClusterCannotLoseWorker` says so while the cluster runs.

## What you run

The alerts are in OpenAether-apps (`docs/runbooks.md`, "Loss of capacity"); each names the same few commands, run from this repository with the cluster's credentials.

| Alert | Fires after | You run |
|---|---|---|
| `NodeUnreachable` (kubelet silent) | 3 min (a reboot is 85-115 s) | `task cluster-node-state`, then `cluster-node-recover` or `cluster-replace-node` |
| `NodeNotReady` | 5 min | same |
| `ControlPlaneMemberMissing` | 3 min | same, and do not roll or touch another control plane |
| `FailureDomainLost` | 2 min | `task failure-domain-check`; wait for the provider if it reports the zone down |
| `WorkloadReplicasBelowDesired` | 15 min | find the Pending pod; a dead node: replace it |
| `ClusterCannotLoseWorker` | 30 min | add a worker or lower requests |
| `OpenBaoReplicasMissing`, `LonghornVolumeDegraded`, `CnpgInstanceMissing` | 5-30 min | a dead node: replace it; they resync on their own |
| `EtcdQuorumLost` (two of three control planes gone for good) | 2 min | `task dr-restore-plan`, the last resort |

### `task cluster-node-state PROVIDER=… NODE=<node>` (read-only)

Asks the provider API what the machine is doing (`running`, `stopped`, `error`, `absent`, `transition`, or `unknown` when the provider does not answer), reads
the kubelet and the Talos port, and prints one `VERDICT=`: `healthy`, `recover`, `replace`, `wait` or `unknown`, with the next command. It never decides from a
provider that did not answer.

### `task cluster-node-recover PROVIDER=… NODE=<node>`

For a machine that **runs at the provider but is silent**: OVH reports the instance `ACTIVE` while it is dead (#49, #371; seen again in lab 17), and nothing in
OpenTofu or the console says a word. It refuses unless the provider says `running`, and it refuses when **no other node answers through the Talos tunnels
either** (the tunnels or the bastion are then the likely fault, and a healthy node must not be hard-rebooted for it). It sends one provider **hard reboot**
(OVH: Nova HARD; Outscale: ForceStop then Start, because a guest reboot is what is not answering; Scaleway: the `reboot` action), waits a bounded time for the
Talos port and a Ready node, and otherwise ends by naming the replacement. It destroys nothing. A hard reboot erases the serial console trace of the failure:
read the console first if you want the cause (it is the only way to learn why #371 happens).

Outscale note: a stopped VM keeps its BSU volumes, and a `vm_type` change needs the same stop/start; do not combine the two by hand while a node is dead.

### `task cluster-replace-node PROVIDER=… NODE=<node>`

For a machine that is stopped, in error or gone, or that did not come back from `recover`. It refuses a Ready node (use `task cluster-roll`) and a machine the
provider calls running (use `recover` first; `-- --even-if-running` after it failed). It runs `rolling-replace.sh --dead --node=…`: the same two saved-plan
applies and gates as `cluster-roll`, with these differences, because the node cannot be drained:

1. a **survey of the survivors**: every other node is Ready (one node at a time; several is a zone loss), and for a control plane a quorum of etcd members is
   healthy without it (otherwise it is the disaster-recovery case and the command says `task dr-restore-plan`);
2. the node is cordoned; for a control plane its **etcd member is removed first**, then the Node object is deleted (never the other way round), which frees its
   pods now; the instance and then its Talos configuration are applied;
3. then Ready, uncordon, etcd back to full membership and the kube-apiserver serving (control plane), and the Longhorn gate.

The state is backed up afterwards, as `cluster-roll` does. It then lists the volumes the old disk left behind and prints the commands that drop them (`-- --clean` runs them, for the known safe cases: section "DNS and the eviction delay after lab 21"). Wipes the node's system disk and the local-path data on it (OpenBao raft member, a CNPG instance, a
VictoriaMetrics storage replica), which the peers rebuild. What follows is what the cleanup does for you; by hand: an OpenBao member on a replaced worker does NOT rejoin on its own (lab 21: `open /bao/data/node-id: permission denied`, the retained volume's directory is re-created root-owned on the new disk): with the
other two members unsealed, delete its pod, its PVC and the retained PV, and local-path provisions a new volume; the member then rejoined and unsealed in about 2 minutes; `loki-0` and `vmselect` (class `local-path`) crash-looped the same way and came back after their pod and PVC were deleted (the script prints the hint). A CNPG instance whose volume was on the dead disk crash-loops on the empty data directory (lab 21): delete its PVC and pod and let
CNPG clone it (under a minute there; only while the cluster has a healthy primary elsewhere; the script prints the hint).

Never: `tofu destroy` or `tofu apply -replace` by hand on more than one node; deleting a control plane's Node object before its etcd member is gone;
`task cluster-roll` while a node is down (its gates refuse); deleting the PVC of a pod whose node is only unreachable.

## Control-plane roll: the API blip (#42)

Rolled with leadership handed over before the last control plane (existing) and now with an **apiserver gate**: after a control plane reboots, the roll waits for
its kube-apiserver static pod to be Ready and for `/readyz` to answer, three polls in a row, before it returns to rotation, and refuses to take a control plane
down unless every apiserver serves. etcd 3/3 and a Ready node did not say that, and the load balancer's TCP check keeps a not-ready apiserver in rotation for up
to 75 s (5 checks x 15 s). The gate is proven offline with a stub kubectl; whether it removes the 5-8 s blip needs the real-cloud roll below.

**Owner decision taken 2026-10-21: neither is enabled** (it would change what is exposed); the apiserver roll gate is what there is. The options, for the record: making the load balancers check `/readyz` over HTTPS instead of TCP 6443, and giving
kube-apiserver `--shutdown-delay-duration` so that it goes not-ready before it stops. The first requires `/readyz` to answer without credentials, that is
anonymous access to the health endpoints (`anonymous-auth` or a structured authentication configuration limited to `/livez`, `/readyz`, `/healthz`), which the
clusters do not enable today and which has to be verified on a Talos node first (#42 says so too). The second is a Talos machine-config change on every control plane.
Neither is useful without the other. The TCP checks and the gate are what there is.

## Zone loss

Spread assumptions: the control planes are spread over three failure domains (checked by `cluster-verify`, #38) and the workers too (`worker_zones`, new: where the
provider placed each worker). Every node now carries the label `topology.kubernetes.io/zone` set from that placement (Talos `machine.nodeLabels`, applied at the next
`infra-apply` without a reboot). With 3 control planes and 3 or 4 workers over 3 domains, losing one domain leaves 2 control planes (etcd quorum), 2 or 3 workers, 2 of 3
OpenBao members, an instance of each database and a replica of each volume.

`task failure-domain-check PROVIDER=…` computes that for every domain from the state and the cluster and exits 1 when some loss would stop something. A single
Gateway pod, a database whose instances share a domain, workers whose requests do not fit on the ones that stay, are named. It is also the first thing to run
when `FailureDomainLost` fires.

**OpenBao placement across zones is NOT enforced (lab 27, FJ).** The three raft members spread over hosts by a hard constraint (`DoNotSchedule`, `maxSkew` 1, `nodeTaintsPolicy: Ignore`) but over zones only by a preference (`ScheduleAnyway`), so nothing stops two members from landing in one zone. Lab 27 `failure-domain-check` found it on 5 workers: two of the three members in the same zone, so losing that zone loses the raft quorum (no secret read, no certificate issued) even though 2 of 3 control planes, the databases and the volumes would survive. The check reads the live placement and says so (`OpenBao: 2 of 3 raft members there, quorum 2 is lost`); nothing else catches it before the loss. **Why a hard zone constraint was not shipped** (decided offline, with no lab): `topologySpreadConstraints` with `DoNotSchedule` and `maxSkew` 1 would schedule 1 + 1 + 1 on three zones and 2 + 1 on two, but a node WITHOUT the `topology.kubernetes.io/zone` label (a provider or a state that records no zone, or a cluster not yet labelled) is not a candidate for it, so a labelled-nowhere cluster would leave every member Pending and the secrets store, and with it the whole platform, would not start; `minDomains` does not help (Kubernetes documents that it needs `DoNotSchedule` and that below `minDomains` eligible domains the global minimum counts as 0, which would allow one member per zone and leave the third Pending on two zones: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/); a required zone anti-affinity leaves the third member Pending on two zones. The apps repository cannot make the constraint conditional on the zone count without a Flux substitution in a bundle whose scripts contain `${...}`. Nothing risky was shipped. What to do today: after a bring-up and after every worker replacement run `kubectl -n foundation-vault get pods -l app=openbao -o wide` next to `kubectl get nodes -L topology.kubernetes.io/zone`, or `task failure-domain-check`, and fix a double placement before relying on a zone-loss survival. **Experiment for the next lab:** on 5 workers over 3 zones, with `topology.kubernetes.io/zone` on every node, apply a patch to the StatefulSet that turns the zone constraint into `DoNotSchedule` (maxSkew 1, same selector and policies), delete the three pods and their PVCs one at a time after removing each raft peer, and record: the zones of the three new members (expected 1 + 1 + 1), that no pod stays Pending, then repeat on a cluster whose workers are in two zones only (expected 2 + 1, none Pending) and on one node with the zone label removed (expected: that node is not used). Only if all three hold, ship it, with the soft form kept as the default of a cluster with fewer than three labelled zones.

## The app load balancer's health check (lab 27 sitting 3, G5)

**What was measured.** With a Gateway pod on the node that a real network partition cut off (Scaleway, 3 CP + 5 W, 240 s, probes at 1 Hz from the lab host through the app load balancer), 41 of 327 samples failed (12.5 %), the longest run 14 s: both halves of the re-posed HTTP criterion (longest run at most 10 s, failed samples at most 10 % of the window) were broken at that vantage point. From a pod inside the cluster the same drill gave 14 of 315 (4.4 %, longest 3 s). The graceful stop of the same node gave 25 of 350 (7.1 %, 6 s). The backends `http-backend` and `https-backend` carried the provider defaults of `scaleway_lb_backend` (check every 60 s, timeout 30 s, 2 retries), so a black-holed worker stayed in rotation for a minute and more.

**What changed (0.4.0).** The app LB of each provider now carries an explicit, short TCP health check on the Gateway's NodePorts. The values are written in the provider modules (`modules/providers/<provider>/lb.tf`), not exposed as variables: the k8s API LB check next to them is hard-coded in the same way, and a check that is too slow is a defect, not a preference.

| Provider | Object | Check | Valid range in the provider documentation |
|---|---|---|---|
| Scaleway | `scaleway_lb_backend.http` and `.https`: `health_check_delay`, `health_check_timeout`, `health_check_max_retries`, `health_check_port`, `health_check_tcp {}` | every 5 s, timeout 3 s, 2 failed checks, on the backend's own NodePort | the documentation (https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/lb_backend) names the arguments and their defaults (60 s, 30 s, 2) and gives **no range**: 5 s / 3 s / 2 are ordinary durations and integers, but "accepted by the API" is UNVERIFIED until a real apply |
| OVH (Octavia) | `openstack_lb_monitor_v2.http` and `.https` (existing since infra #375, unchanged) | TCP, `delay` 5, `timeout` 3, `max_retries` 2 | `timeout` must be less than `delay`; `max_retries` 1 to 10 (https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/resources/lb_monitor_v2). The same page has `max_retries_down` (failures before ERROR), default 3, which this repository does not set: Octavia may therefore need 3 failed checks, not 2, before it stops sending to a dead member (UNVERIFIED, about 5 s more in the worst case) |
| Outscale | `outscale_load_balancer_attributes.app` (new; before, the app LB kept the platform default of 30 s and 10 successes to come back) | TCP, `check_interval` 5, `timeout` 3, `unhealthy_threshold` 2, `healthy_threshold` 2, on the http NodePort | `check_interval` 5 to 600, `timeout` 2 to 60, thresholds 2 to 10 (https://registry.terraform.io/providers/outscale/outscale/latest/docs/resources/load_balancer_attributes). **One check per load balancer, not per listener:** it probes the http NodePort; the https NodePort belongs to the same Gateway Service and answers on every node that is up |

**Detection time, worst case, computed and not measured:** a check starts at most 5 s after the cut and each failed check lasts up to 3 s, so two failed checks take a dead member out after about 13 s (Octavia: about 18 s if it waits for 3 failures, see above). Before, a Scaleway backend needed over 60 s.

**What this does not fix, and the API load balancer.** The check removes a dead worker from the load balancer. It does not remove a dead Gateway pod from the Service's endpoints, which stays until the node is NotReady (about 35 s at the 30 s grace), and a node that still answers its NodePort while its Gateway pod is being evicted passes a TCP check. So the HTTP criterion may still be broken at the lab-host vantage point after this change: it is **UNVERIFIED** until the lab measures it. The API load balancer's check (TCP every 15 s, 5 retries, up to 75 s; `scaleway_lb_backend.k8s_api`, the OVH monitor `k8s_api`, the Outscale `k8s` attributes) is another object and was **not changed**: lab 27 sitting 3 read the kubelet's own logs and found that the kubelets reach the API through the local Talos proxy `127.0.0.1:7445`, not through the load balancer, so shortening the API check cannot cure a control-plane flap, and it would only make the backend flap faster (the API check is also what `wait_apiserver_ready` assumes).

**What the next lab must prove (UNVERIFIED until then).** On each provider in turn (Scaleway, OVH, Outscale): (1) the apply is accepted with these values and the rendered load balancer carries the check (`scw lb backend get`, `openstack loadbalancer healthmonitor show`, the Outscale `ReadLoadBalancers` health check); (2) the partition of a worker that holds a Gateway pod, 240 s, probes at 1 Hz from the lab host AND from a pod: longest run at most 10 s and failed samples at most 10 % of the window at both vantage points; (3) the seconds from the cut until the load balancer marks the member down (backend health from the provider API every 2 s), to compare with the 13 s computed here; (4) no member flaps down on a nominal worker roll or drain (a check this short has a price: count the down transitions of a 30 minute nominal run). Not a compliance claim.

## DNS and the eviction delay after lab 21 (infra #388, apps #154)

Rung: **mocked/static** (`tofu test`, the rendered manifest, a fake `kubectl`). Nothing below has been drilled. Not a compliance claim.

**CoreDNS (#388).** Lab 21: both Talos replicas sat on one worker, so its loss was 4 min 46 s without DNS; with the replicas on two control planes one lost control plane still cost
a 46 s write gap. The lever: Talos' `cluster.coreDNS` has two keys, `disabled` and `image`, no replicas, no scheduling, no budget, and a patch from outside (Flux, Kyverno, a
post-renderer) on an object Talos also applies would fight Talos's own sync (which side wins is UNVERIFIED). Chosen, `coredns_ha` (default true, module `talos`):
`cluster.coreDNS.disabled = true` plus an inline manifest `coredns` (`modules/talos/coredns.yaml.tftpl`) with the same names, labels and ClusterIP (`10.96.0.10`, the default service range
`10.96.0.0/12`), `min(3, nodes)` replicas, a **hard hostname spread with `minDomains` = replicas** (a replica created before the other nodes registered waits for a different node
instead of sharing one, which is what happened), a zone preference, a budget allowing one disruption, 30 s not-ready/unreachable tolerations, requests 50m/70Mi (three replicas 150 m, was 2 x 100 m).
It is an inline manifest and not a Flux object because Flux itself needs DNS to fetch anything. You now own the image: `coredns_image_tag`, tracked by Renovate.
Not chosen: a Flux or Kyverno patch of the Talos object (above); NodeLocal DNS cache (a DaemonSet per node, about 0.1 vCPU each against a margin of 0.15 vCPU in the two-worker zone, and it
answers stale only for names already asked: it hides an outage, it does not remove one); changing the apiserver default tolerations (every pod). Still true afterwards: until the Service stops
using the replica of a lost node (about 40 s after the node turns NotReady, 80 s seen in lab 21) one lookup in three goes to it; resolvers retry after 5 s, a 1 Hz writer with a short connect
timeout can still fail for that time.

**Talos upgrades.** With `coreDNS.disabled` Talos neither creates nor upgrades `kube-system/coredns`: Talos and Kubernetes upgrades leave it alone, a CoreDNS version change is a
`coredns_image_tag` change and a `tofu apply` (the config is re-sent to the control planes, which re-apply their inline manifests; no reboot). **Turning it on for a running cluster does NOT
reach it** (lab 26, K2, PROVEN on a 0.3.2 cluster moved to 0.4.0): Talos applies an inline manifest's objects only when they are absent, so the Talos-created `kube-system/coredns` Deployment stays exactly as it was
(same uid, 2 replicas, no spread) and only the new budget appears. `cluster-verify` now says so ("CoreDNS runs the declared replica count and spread", BAD in both directions, with the command). The one-time step
for a cluster built by an older release is a patch of that Deployment: `kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json`
(replicas 3, the hard hostname spread with `minDomains` 3, the zone preference, the 30 s tolerations: a test keeps the file equal to the manifest; for a cluster of fewer than 3 nodes edit `replicas` and `minDomains`).
It rolls the CoreDNS pods one at a time. It does NOT bring the rest of the manifest: the Corefile, the image tag, the requests/limits, the update strategy and the priority class of an upgraded cluster stay Talos's,
and a later `coredns_image_tag` change does not reach it either (`kubectl set image`, below). Rebuilding the Deployment from the manifest instead (delete it, let Talos re-apply the inline manifest) is not documented
because whether and when Talos re-applies an absent object after a config change was not observed. Turning it off again leaves OpenAether's in place until Talos re-applies its own, so delete
`kube-system/coredns` first. UNVERIFIED: the patch on a live cluster (the seconds of DNS during the rollout), that the inline-manifest sync updates a Deployment in place when only the tag changes (observed: it does
not, below), and what `talosctl upgrade-k8s` says about CoreDNS when it is disabled.

**Database failover (#154, OpenAether-apps `docs/resilience.md`).** The CNPG primary of a lost node is failed over when its pod is evicted; the Clusters now tolerate `unreachable` and `not-ready`
for 30 s instead of 300 s. Expected write gap of a node power loss: about 60 s (two measurements of 328 and 333 s minus the 300 s), not 30 s: detection and promotion alone are 28-33 s. A
primary kill (24 s) and a switchover (12-14 s) meet 30 s. The owner decides whether 30 s applies to a power loss.

**After a replacement (#4 of the lab 21 follow-up).** `cluster-replace-node` now ends with `scripts/ops/replaced-node-cleanup.py`: it takes the PVs pinned to the replaced node by hostname and
created BEFORE its new Node object (the data lived on the old disk), finds the pods stuck on them, and prints the exact `kubectl` commands. Default: nothing is deleted. `-- --clean` runs them,
only for: a CNPG replica whose Cluster has a Ready primary elsewhere (never the primary of record), an OpenBao member while a raft majority of the others is Ready (Ready means unsealed), Loki,
vmstorage and vmselect while another replica is Ready; the retained PV is deleted with the claim. One member per workload per run, a Ready pod is left alone, anything else is refused and
the command exits 1. Longhorn replicas are reported (a faulted volume is named), never deleted: Longhorn rebuilds them. `task cluster-replaced-node-cleanup NODE=<node> [-- --clean]` runs it alone
(for a deferred member, or later). The matching of a PV to the new Node by creation time was met on a live cluster in lab 25 (dead node: 7 volumes cleaned in 6 s). UNVERIFIED: CNPG re-cloning in every case the script lets through.

**A drained replace keeps the Node object (lab 26, C1).** `task cluster-roll -- --node=<node>` drains, then replaces the VM and its disk, but the Node object stays: no volume is "older than the Node", so the tool above
used to answer "nothing to clean" while a CNPG replica, Loki and vmselect crash-looped (`mkdir ... permission denied` on the empty, root-owned retained directory). The tool cannot see the disk. It now lists the not-Ready pods
that sit on volumes pinned to the node that the default rule skipped, refuses to say "nothing to clean", exits 1 and prints `task cluster-replaced-node-cleanup NODE=<node> -- --disk-replaced` (add `--clean` to run it). `--disk-replaced` is
the person saying the disk was replaced: every volume pinned to the node counts as the old disk's, a Ready pod is still left alone and every rule above still applies. `cluster-roll` prints that command after a worker replace. If the disk
was NOT replaced, those pods have another cause: do not delete their volumes. Stub tests only; the recipe it prints is the one used by hand in lab 26 (all healthy about a minute later).

**Lab pass criteria for these changes.**

| Drill | Pass |
|---|---|
| Fresh install, `coredns_ha` on | three `k8s-app=kube-dns` pods on three different nodes (`-o wide`), none Pending for good; `kubectl get pdb -n kube-system coredns` allows 1; `cluster-verify` green |
| Cluster upgraded from 0.3.x, before the one-time patch | `cluster-verify` BAD "CoreDNS has 2 replica(s) ... declares 3"; after the patch three pods on three nodes, the line green, 1 Hz lookups from a third node during the rollout: none fails for more than 5 s |
| Worker (or control plane) holding a CoreDNS replica powered off 5 min, 1 Hz lookup of a Service name from a pod on a third node plus the database writer | no lookup fails for good, and the longest database write gap that is not a failover is at most 30 s (was 287 s / 46 s); replicas back to three within 15 minutes of the power-on |
| Worker holding the zitadel-db primary powered off and left off | the longest write gap is at most 75 s (expected about 60 s), a replica is promoted within 45 s of the node turning Unknown, data identical; 30 s is not claimed |
| Zero-loss writer (OpenAether-apps `docs/resilience.md`, "Zero-loss proof"): 100 commits per second, fresh connection each, client-side log of acknowledged ids; primary pod killed, its worker powered off, its worker force-rebooted (`talosctl reboot --mode force`), its zone powered off; then once with synchronous replication suspended as a control | after each run with synchronous replication, **zero acknowledged ids missing** from the surviving rows; the write gap is recorded; the control shows what asynchronous replication loses (or that it did not reproduce a loss) |
| `cluster-replace-node` of a dead worker holding a CNPG instance, an OpenBao member, loki and vmselect | the cleanup lists exactly the volumes of that node created before the new one; without `--clean` nothing is deleted; with `--clean` every replica is full within 15 minutes of the command with no manual `kubectl`; the primary of record and every other node's volume are untouched (`kubectl get pv` before and after) |

## Failure detection time (lab 26, D2 and H1): the lever, and the experiment the next lab must run

Rung: **mocked** (`tofu test`: the rendered machine config and the replace trigger). The shipped default is **30 s** (owner decision 2026-10-26) on the evidence of **ONE provider** (Scaleway, lab 27): see "Why the default is 30 s" below. **UNVERIFIED: the second and third provider (OVH, Outscale) and a soak during a roll.** Not a compliance claim.

**What lab 26 measured.** A provider power-off of the node holding a database primary gave a write gap of 76-79 s (forced reboot: 62 s). It decomposes into: about 33 s while PostgreSQL is already stopped but Kubernetes still calls the pod Ready (the provider's graceful shutdown; nothing of ours); 32-35 s from the instance stopping to NodeNotReady (the kube-controller-manager's `--node-monitor-grace-period`, left at its default); 1-3 s to start the failover; 24-30 s to the first commit, of which 16 s is the new primary waiting for the CNPG primary lease. The same wait explains the HTTP failures when the lost node holds one of the two Gateway pods (runs of 15-17 s between +35 s and +90 s): the Service keeps the dead pod as an endpoint until the node is NotReady.

**Lever 1, in this repository: `node_monitor_grace_period_seconds`** (tfvars, module `talos`; **default 30 since 0.4.0**, set by the root variable; `0` = unset = Kubernetes default 50 s, the opt-out; otherwise a whole number from 20 to 300). It writes `cluster.controllerManager.extraArgs."node-monitor-grace-period"` on the control planes and, below 40, the kubelet's `nodeLeaseDurationSeconds` and `nodeStatusUpdateFrequency` on every node (`machine.kubelet.extraConfig`). The numbers, from the Kubernetes source (read 2026-10-24): the controller manager's help says the grace period "must be N times more than kubelet's nodeStatusUpdateFrequency, where N means number of retries allowed for kubelet to post node status" and "should also be greater than the sum of HTTP2_PING_TIMEOUT_SECONDS and HTTP2_READ_IDLE_TIMEOUT_SECONDS"; the defaults are grace 50 s, node-monitor-period 5 s, kubelet status frequency 10 s, `nodeLeaseDurationSeconds` 40 with the Lease renewed every quarter of it (10 s), and a status report only every 5 minutes unless it changes or `nodeStatusUpdateFrequency` is set (then it is posted at that frequency). So the default leaves 5 heartbeats; the rule used here keeps at least 4: with grace G below 40, lease duration = G (renewed every G/4) and status every floor(G/4) s. G = 20 gives a Lease renewed every 5 s and a status every 5 s, and should detect a lost node about 30 s sooner (expected NodeNotReady about 20 s after the last heartbeat instead of 50 s; node-loss write gap about 45-50 s instead of 76-79 s). Costs: more writes to the API server (a Lease and a status every 5 s per node instead of 10 s: 2 to 3 per second for 8 nodes, immaterial; check at 100 nodes), and false NotReady on a flaky link. The risk Kubernetes names is the second sentence: client-go keeps a dead HTTP/2 connection for up to 30 s (read idle) plus 15 s (ping timeout) before it reconnects, and no Talos setting changes those two environment variables of the kubelet, so a kubelet whose API connection silently died can miss a 20 s grace period while its node is fine; it comes back Ready when it reconnects. The database and CoreDNS pods tolerate NotReady for 30 s before eviction, so a flap shorter than that evicts nothing, but a Service stops sending to the node's pods while it is NotReady. Changing it re-applies every machine config (the control planes' controller manager restarts one pod at a time; the kubelets restart); the shipped default is 30 (see "Why the default is 30 s" below).

**Lever 2, in the apps repository (not changed): the CNPG primary lease.** The 16 s wait is real and configurable: `.spec.primaryLease` of the Cluster (CloudNativePG 1.30, the "Failover" page of its documentation: `leaseDurationSeconds` 15, `renewDeadlineSeconds` 10, `retryPeriodSeconds` 2, `releasedLeaseDurationSeconds` 1). After an abrupt loss a candidate must see the lease unchanged for a full `leaseDurationSeconds` before it promotes. The webhook demands lease > renewDeadline > 1.2 x retryPeriod. Upstream's own caution: lower values slow down tolerance of a slow API server (the primary stops when it cannot renew within `renewDeadlineSeconds`) and a shorter lease shortens the window in which a former primary that is still alive but cut off from the API could still accept writes. `.spec.failoverDelay` (seconds the operator waits after an unhealthy primary before starting the failover; default 0) is not a lever downwards. Not changed: a primary that stops on a 5 s renew deadline during a control-plane roll (isolated 1 s API failures were seen in every roll) would be a self-inflicted failover.

**The experiment for the next lab (3 CP + 5 W, the shipped content, NOMINAL otherwise).** Same method as lab 26, D2: a provider power-off of the node holding the `ha` primary, the acknowledged-id writer, the Node object events and the operator events timestamped. Runs: (a) baseline, no change, to get today's figures on that cluster; (b) `node_monitor_grace_period_seconds = 30`; (c) `= 20`; (d) 20 together with `primaryLease` `{leaseDurationSeconds: 8, renewDeadlineSeconds: 5, retryPeriodSeconds: 2}` on the `ha` and `standard` test Clusters only. Measure per run: seconds from the instance stopping to NodeNotReady; the write gap (target 75 s for a node loss); the `Acquiring primary lease` to `Acquired primary lease` wait; HTTP failure runs while a Gateway pod is on the lost node (target: longest run 5 s); and, to price the risk, 30 minutes of NOMINAL operation at each setting during a control-plane roll and a worker drain, counting Node NotReady events, evictions, CNPG failovers and Role/Endpoints flapping (target: none). Also read in a run with the setting on that the kubelet really got `nodeLeaseDurationSeconds` (`kubectl get lease -n kube-node-lease <node> -o yaml`: `leaseDurationSeconds`; `talosctl read /var/lib/kubelet/config.yaml`) and that `kube-controller-manager`'s command line carries the flag. Adopt a value as a default only if the node-loss gap meets 75 s with zero false NotReady in the NOMINAL runs; otherwise leave 0. (Lab 27 ran part of this on Scaleway: next paragraph.)

**Why the default is 30 s (owner decision 2026-10-26), and what is not proven.** Measured on ONE provider, Scaleway, lab 27, provider power-off of the node holding a database primary: write gap 82-86 s at the default (50 s), 62-70 s at 30 s, 49-62 s at 20 s. The target for a lost node is 75 s: met at 30 s and at 20 s, not at the default. 30 was kept over 20 for margin against a false NotReady. A 30 minute NOMINAL soak at 30 s on that provider saw 0 NotReady, 0 eviction and 0 failover. The flaps seen while a control plane is replaced (F-CPFLAP, below) occur at the default too and are independent of the grace period. **Shipped:** `node_monitor_grace_period_seconds = 30` in the root (`cluster/variables.tf`); `modules/talos` keeps 0 as its own default; 0 stays accepted (the opt-out) and so does 20 to 300. **UNVERIFIED:** (1) OVH and Outscale: the next labs are the proof, **and the default goes back to 0 if the other providers flap**; (2) a soak at 30 s during a roll or a drain (the flaps of a control-plane replacement at 30 s were 4 episodes of 13-17 s in 2 replacements, no failover, no eviction, and the grace period was not isolated as their cause or cure); (3) the heartbeat rate at 100 nodes. What an existing cluster goes through: `docs/upgrade.md`, "From 0.3.x to 0.4.0".

**Healthy workers go NotReady for 11-30 s while a control plane is replaced (lab 27 sitting 2, F-CPFLAP): the mechanism, UNVERIFIED, and the experiment.** Observed (Scaleway, 3 CP + 5 W, `task cluster-roll -- --node=<cp>`): at the default grace 6 episodes in 3 control-plane replacements (11-30 s Unknown, 1 unplanned failover of a 2-instance local-path Cluster, a 70 s write gap on a platform database), at `node_monitor_grace_period_seconds = 30` 4 episodes of 13-17 s in 2 replacements (no failover, no eviction). The grace period is not the cause: the episodes start in the same place at both settings.

*What the timestamps say* (events and `nodewatch.log` of the first replacement, cp-0, default grace; UTC): `NodeNotReady` for worker-3 at 10:11:23 and for worker-0 and worker-2 at 10:11:33; Ready again at 10:11:52 (worker-2), 10:11:59 (worker-3), 10:12:10 (worker-0); the replaced cp-0 itself `NodeNotReady` at 10:12:06. The controller marks a node 50 s after the last heartbeat it saw, so those three kubelets last got through at about 10:10:30 and were out for 79-97 s; cp-0's own kubelet kept reporting until about 10:11:15. At 30 s the same episodes lasted 13-17 s after the mark, so about 43-47 s without a heartbeat, which is the 30 s read-idle plus 15 s ping timeout of client-go that this document already names. Three facts fit one reading: (1) only some workers flap, 3 of 5, then 2, then 1 at the default and 2 + 2 at 30 s: 2.0 per replacement against the 5/3 = 1.7 expected if each kubelet holds one HTTP/2 connection to the API through the load balancer, pinned to one of the 3 backends; (2) the repository's own load balancer keeps a backend in rotation for up to 75 s after it stops answering (`scaleway_lb_backend.k8s_api`: TCP check every 15 s, 5 retries; `roll-gates.sh` already says so for the opposite direction), and a new connection has a 1 in 3 chance to be sent to it, so a kubelet that re-dials can land on the dead backend again; (3) the roll removes the etcd member of the control plane, and then destroys its VM, while that control plane is still in the load balancer (the TCP check passes as long as the port is open), so for a while a connection pinned to it reaches an apiserver that cannot serve or a machine that does not answer. The kubelet's request to renew its Lease times out, its connection is only closed after repeated failures (the kubelet closes its connections on repeated heartbeat failure, `OnHeartbeatFailure`; read in the kubelet source, not re-run) and the new one may hit the same backend. The Kubernetes documentation (Nodes, "Heartbeats") says a node is marked Unknown when its Lease is not renewed within `node-monitor-grace-period`. What this does NOT show: which of (2) and (3) dominates, how long the cp-0 apiserver kept accepting connections after the member was removed, whether the kubelet's API endpoint on Talos is the load balancer (it should be read, see below), and the kube-controller-manager leader: a new leader starts its node-health bookkeeping from "now" and cannot by itself mark a node Unknown, so a leader change is not the cause of an episode, but it is not excluded as a delay (lab 26, below: 37 s to start the controllers).

*Smallest candidate fixes, none applied* (the roll order and the load balancer are what the release gate proved; both change a proven path): (a) take the control plane out of the load balancer rotation BEFORE its etcd member is removed and put it back after it serves (provider specific: Scaleway backend `server_ips`, OVH and Outscale load balancer members; Proxmox has none); (b) or stop the control plane gracefully first (a drained node, then `talosctl shutdown`), so its apiserver closes its connections with a GOAWAY and its port refuses at once instead of black-holing, and remove the etcd member after; (c) or shorten the load balancer check (a delay of 5 s and 3 retries is 15 s instead of 75 s) at the price of a faster flap of the backend and a change of the 75 s that `wait_apiserver_ready` assumes. (a) and (b) address both (2) and (3); (c) only the length of (2). `node_monitor_grace_period_seconds` stays as it is.

*The experiment that proves or kills it* (one lab, 3 CP + 5 W, grace 30 s, three control-plane replacements per arm, same method as the flap count above). Log at 1 s, with timestamps: every worker's Lease `renewTime` (`kubectl get lease -n kube-node-lease -w`); each worker kubelet's log (`talosctl logs kubelet`: "Failed to update lease", "Error updating node status", "transport is closing") and `talosctl read /etc/kubernetes/kubeconfig-kubelet` once (is the `server:` the load balancer or `127.0.0.1:7445`); the load balancer backend server health from the provider API every 2 s; `talosctl etcd members` every 2 s and the instant of the member removal and of the VM destruction (the roll log has them without a clock: add `date` to the lab wrapper); which workers flap. Vary: (A) as shipped; (B) the control plane taken out of the load balancer by hand (provider API) 60 s before the roll starts on it and put back after it serves; (C) a graceful `talosctl shutdown` of the control plane before the roll removes its member. Prediction if the reading is right: A flaps about 5/3 workers per replacement; B and C none; the flap starts at the member removal or at the VM's disappearance, not at the cordon; the end of each flap is a kubelet re-dial. If B still flaps, the cause is not the load balancer and the next candidates are the kubelet endpoint and the controller manager leader. Not a compliance claim; nothing here was run after the lab.

## The drills that prove it (cloud, 1 Hz probes)

Probes, as in lab 15c: an HTTP request every second from outside through the public load balancer, the Gateway and a route served by 3 pods; a database writer
inserting and reading back every second through a fresh connection with a unique run id per start (a reused key made lab 15c's first run invalid); an RWX writer;
`/readyz` of the API every second through the load balancer. Record the longest run of consecutive failed samples as well as the total. Throwaway objects in their
own namespace. Cluster shape recorded with every timing.

| Drill | Do | Pass |
|---|---|---|
| Worker loss | Provider power-off of one worker for 5 minutes, then power on | longest HTTP failure run at most 10 s and failed samples at most 10 % of the drill window (criterion of 2026-10-26; it was at most 5 s and at most 5 in total, never met since lab 15c, which measured 22 for a node loss and 9 for an undrained reboot; if this fails, the load balancer is the next suspect, #375), DB write gap at most 30 s, RWX writer back within 120 s, no data difference (checksums, row counts), `NodeUnreachable` fires with the command named, every replica count full within 15 minutes of the power-on |
| Control-plane loss | Provider power-off of one control plane for 5 minutes | HTTP failures 0, `/readyz` unavailable at most 10 s in total, `ControlPlaneMemberMissing` fires, etcd 3/3 and 3 apiservers after the power-on |
| Zone loss | Provider power-off of every node of ONE failure domain (the API of the provider, all together) for 10 minutes, then power on | `task failure-domain-check` was green beforehand; `FailureDomainLost` fires within 3 minutes; HTTP longest failure run at most 10 s and failed samples at most 10 % of the window; `/readyz` at most 10 s in total; DB gap at most 30 s; OpenBao 2 of 3 unsealed throughout and 3 of 3 after; no data difference; full replica counts within 15 minutes of the power-on |
| Replace a dead worker | Provider stop of a worker, leave it; `cluster-node-state` says `replace`; `cluster-replace-node` | Ready node within 15 minutes of the command, its pods rescheduled, the Node object deleted before the apply (pods freed at once), CNPG and OpenBao back to full, no customer probe worse than the worker-loss drill |
| Replace a dead control plane | The same on one control plane | the survey passes with a quorum, the etcd member removed before the Node object, etcd 3/3 and 3 apiservers, `/readyz` unavailable at most 10 s in total |
| Recover | `cluster-node-recover` on a worker after `talosctl` made it silent, or on the next real #371 | one hard reboot, Ready within the bounded wait; with the tunnels closed on purpose, nothing is rebooted |
| Roll gate | `task cluster-roll … -- --cp-only` with the `/readyz` probe | the log shows the apiserver gate between every control-plane reboot; longest `/readyz` failure run at most 5 s (#42 measured 5-8 s before) |
| Alerts | during the drills above | each alert fired within its `for` window, its text names the command, `AlertmanagerClusterDegraded` fires during the loss of the node holding one Alertmanager (`alertmanager_cluster_members` does NOT drop: it stayed at 2 on the survivor in lab 21) |

## Measured in lab 21 (Scaleway, 3 control planes + 4 workers POP2-4C-16G, 2026-10-21, probes at 1 Hz)

Longest run of consecutive failed samples, and the total, per drill. Targets of that day: HTTP blip at most 5 s and at most 5 failures in total (re-posed on 2026-10-26: run at most 10 s, at most 10 % of the window), database write gap at most 30 s, 99.9% (not computed over a lab of a few hours).

| Drill | HTTP (longest run / failed) | `/readyz` failed | DB gap | Verdict against the pass criteria |
|---|---|---|---|---|
| Worker power-off 5 min (3 runs, three different workers) | 1 s / 8-16 isolated | 0 | 0 s, 287 s when both coredns replicas sat on the worker, 328-333 s when it held the database primary | run <= 5 s met; total <= 5 NOT met (8-16); DB gap NOT met when the primary or the DNS is lost; replicas full 113-122 s after power-on; no data difference |
| Worker undrained reboot | 1 s / 8 | 0 | 59 s (primary on that worker) | as above |
| Control-plane power-off 5 min / undrained reboot | 0 / 0 | 2 / 3 isolated | 46 s (a coredns replica on it) / 0 | HTTP 0 and `/readyz` <= 10 s met; DB gap NOT met when DNS lost half its replicas |
| `cluster-roll -- --cp-only` (17 min 34 s) | 0 / 0 | 66 isolated, longest 1 s | 0 | apiserver gate in the log between the three control planes; longest `/readyz` run 1 s (met; #42 measured 5-8 s); the 75 s TCP health check of the load balancer still costs about 22 isolated failures per control plane |
| Zone power-off 10 min, fr-par-3 | 1 s / 4 | 3 | 0 | all met except `FailureDomainLost` 3 min 11 s (`for: 1m`; fixed to 1 min 51 s) |
| Zone power-off 10 min, fr-par-1 (two workers, a control plane, grafana-db entirely inside) | 3 s / 15 | 2 | 36 s | `FailureDomainLost` 2 min 2 s; OpenBao 2 of 3 then 3 of 3; DB gap NOT met (DNS); pods Pending (CPU of the two-worker zone) |
| Same zone after the zone spread of the CNPG clusters and operator | 2 s / 31 | 4 | 0 | all met; grafana-db failed over to fr-par-2 |
| Replace a dead worker (`cluster-replace-node`, 260-287 s, twice) | 1 s / 12 | 0 | 328 s (primary on it) | Node object deleted before the apply, Ready in 4 min 20 s; the pods whose local-path volume sat on the replaced disk crash-looped (two CNPG instances on an empty data directory, then on the second worker an OpenBao member, loki-0 and vmselect with `permission denied`) until their PVC (and the retained PV) was deleted by hand: NOT back to full by itself, about 2 minutes each once done |
| Replace a dead control plane (335 s) | 0 / 0 | 1 | 0 | survey with quorum, etcd member removed BEFORE the Node object, etcd 3/3, 3 apiservers: all met |
| `cluster-node-recover` | 1 s / 2 | 0 | 0 | one hard reboot, Ready after 104 s; with the tunnels closed on purpose nothing is rebooted (kubelet silence simulated: no Talos API stops it) |

What the drills changed in this release: `NodeScrapeDown` and `FailureDomainLost` read the kubelet scrape (kube-state-metrics was one pod then and was blind when it sat on the lost node, and
the Ready condition arrives 80 s after the loss; it has two replicas now, OpenAether-apps #156), `AlertmanagerClusterDegraded` counts answering pods, a preferred zone spread on the CNPG clusters and operator. What they did not change:
CoreDNS (Talos-owned, both replicas on one worker after the install), the 5 minute wait before a database primary on a lost node is failed over, the capacity of the two-worker zone
(`capacity.md`). Each has an issue; the first two have offline changes, see the section "DNS and the eviction delay after lab 21" (not drilled).

## Measured in lab 22 (Scaleway, 3 control planes + 5 workers POP2-4C-16G, zones 2 + 2 + 1, 2026-10-22, probes at 1 Hz)

Heads: infra 4e84806 plus the fixes listed below, apps 71f2496 plus its fixes. Rung: **observed on a cluster**, Scaleway only. Not a compliance claim.

| Drill | Result | Against the pass criterion |
|---|---|---|
| Fresh install, 5 workers | `cluster-verify` 15/15, Flux Ready, CoreDNS 3 pods on 3 nodes with a budget of 1, kube-state-metrics 2 pods, `count(kube_node_info)` = 8, zone label on all nodes; `failure-domain-check` exit 0: `3 of 5 stay, requests 246% fit in 300%` (fr-par-1, fr-par-2), `4 of 5 stay, 246% in 400%` (fr-par-3) | met |
| Worker holding the zitadel-db primary powered off 5 min (twice) | write gap 43.6 s (switchover, 41 s after the call) and 64 s (failover, `Failing over` 35 s after the node turned NotReady); promotion 34 s and 15 s BEFORE the node turned Unknown (the kubelet posts NotReady at +1 s: the provider power-off is a clean OS shutdown); data identical | met (<= 75 s, expected about 60 s) |
| Same, undrained reboot | gap 57 s, HTTP 8 failed samples in isolated 1 s runs (total above 5, as in lab 15c / 21) | gap met, HTTP total NOT met |
| Worker holding a CoreDNS replica powered off 5 min, DB primary elsewhere | longest write gap 6 s (was 287 s); 1 Hz lookup from a third node: 4 failed samples, longest 6 s; a replacement replica Ready 36 s after the call, three replicas throughout | met |
| kube-state-metrics pod killed, then the worker with the other one powered off | `NodeUnreachable` fires (+300 s); `NodeScrapeDown` +240 s; `NodeNotReady` (`for: 5m`) only pending, the node was back | met |
| Zone with two workers (fr-par-1, then fr-par-2) powered off 10 min | no pod pending for lack of CPU (0 `Insufficient` events; the pending pods were DaemonSet pods of the lost nodes and pods whose local-path volume lives there); HTTP longest 2 s / 1 s, `/readyz` 1-2 s, OpenBao 2 of 3 then 3 of 3, data identical, every replica full 177 s after the power-on; DB write gap **11 s when the primary was outside the zone, 122 s when it was inside** | HTTP, `/readyz`, OpenBao, CPU met; DB gap 30 s NOT met with the primary inside the zone |
| Replace a dead worker holding a CNPG replica, OpenBao, loki and vmselect | `cluster-replace-node` 460 s; the listing named exactly the four volumes of the old disk, deleted nothing without `--clean`; **`--clean` did nothing on its first run (defect, fixed below)**; with the fix every replica full 61 s after the command, only the four volumes changed | met after the fix |
| Alert latencies after the power-off (1 min evaluation grain) | `FailureDomainLost` 64 s, `NodeScrapeDown` 244 s, `ControlPlaneMemberMissing` 244 s, `NodeUnreachable` 304 s, `NodeNotReady` / `EtcdMemberDown` 364 s | |

Why the zone loss with the primary inside takes 122 s: the kube-controller-manager leader sat on the lost control plane. The new leader started its node lifecycle and taint-eviction controllers 37 s after the loss (lease 15 s), the 30 s toleration ran after that, CNPG failed over at +89 s and promoted at +120 s. With the leader alive the same eviction came at +30 s. Levers (not applied, an issue holds them): shorter `leader-elect-*` timings of the controller manager through Talos (risk: leader flapping under API latency), or nothing and a stated limit of about 2 minutes for a database primary in a lost zone.

Defects found and fixed on the branch: `scripts/ops/replaced-node-cleanup.py` printed and ran `kubectl delete pod NAME pvc CLAIM` (three pod names: nothing deleted; fixed to `pod/NAME pvc/CLAIM`) and `kubectl delete pv` blocked on a still-bound volume (now `--wait=false`); `oa_protect_bucket` reported a fully locked Outscale bucket as "NOT fully protected" because the provider refuses to re-enable versioning on a bucket created with object lock.

CoreDNS and Talos (observed): a changed `coredns_image_tag` is sent to the nodes by `tofu apply` (8 nodes, no reboot, the probes saw nothing) but the running Deployment is **not** updated by it (6 minutes after: still the old tag). `talosctl upgrade-k8s --dry-run` with `coreDNS.disabled = true` lists Service, PDB, ConfigMap and RBAC `unchanged` and the Deployment `configured` with a one-line diff (the image): the new tag is rolled out by the next `upgrade-k8s`, which neither recreates a Talos CoreDNS nor ignores ours. By hand before that: `kubectl -n kube-system set image deployment/coredns coredns=registry.k8s.io/coredns/coredns:<tag>`. `tofu plan` after all drills: no changes.

## Measured in lab 23 (Scaleway, 3 control planes + 5 workers POP2-4C-16G, 2026-10-22): synchronous replication, zero-loss proof

Heads: infra 100c862 plus the fixes of the lab, apps 11c1096 plus its fixes. Rung: **observed on a cluster**, Scaleway (cluster) and OVH (replica store and audit sink, buckets only). Not a compliance claim. The full table and the method are in OpenAether-apps `docs/resilience.md` ("Zero-loss proof").

| Fault (two writers on `zitadel-db` and an `ha` profile Cluster, plus one through the pooler; ids acknowledged after the COMMIT) | acknowledged ids missing | longest write gap |
|---|---|---|
| force delete of both primary pods | **0** of 9519 / 7679 / 7624 | 32-36 s |
| provider power-off of the primaries' worker, 300 s | **0** of 19048 / 15936 / 16482 | 40-60 s |
| `talosctl reboot --mode force` of that worker | **0** of 13724 / 10912 / 10851 | 61-63 s |
| power-off of the zone holding both primaries, 300 s (twice) | **0** (19698 / 15087 / 9825, then 21773 / 15262 / 15388) | 112-120 s then 50-80 s direct; **314.5 s once through the PgBouncer pooler** |
| both replicas down 122 s, 330 s, 480 s | **0** | writers blocked for the whole outage (no acknowledgement); `CnpgSyncReplicaMissing` firing at +274 s of 480 s |
| a primary and one replica lost together, 300 s | **0** of 18675 / 14126 / 14600 | no promotion (FailoverQuorum): 353-375 s, until the nodes returned |

Control, asynchronous replication: 0 missing after a pod kill (also under a 32-client pgbench) and after a forced reboot; **817 of 15916 and 1409 of 16432 acknowledged ids LOST** when both replicas were down and the primary's node was then powered off, which is the double fault the synchronous setting blocks. Synchronous replication cost about 25% of the write throughput and 2.2 ms per commit across zones (the OpenAether-apps guide "Database profiles").

What it means for this repository: the 75 s node-loss bar was met (40-63 s), the zone-loss bar of 30 s was not (50-120 s, infra #390 stays), and a zone power-off with the pooler path once took 314.5 s (not explained: OpenAether-apps #158). The sink (infra #318) results of the same lab are in `docs/audit-sink.md`, section 10.

## UNVERIFIED

Verified in lab 21 (Scaleway): two CNPG operators with one holding the lease, the ESO controller leader election, two Kyverno admission controllers, `kube_node_role`, the zone label of
`kube_node_labels` and `alertmanager_cluster_members` as series, the Alertmanager gossip through the network policy (2 members), `machine.nodeLabels` applied to a running node without a
reboot (the zone label is on every node from the first boot), the Scaleway `state` and `hard-reboot` calls of `node-provider.py`, and what a CNPG instance and an OpenBao member on a replaced disk need
(a CNPG instance: its PVC and pod deleted, then a clone in under a minute; an OpenBao member: its pod, PVC and retained PV deleted, back in about 2 minutes).

Still UNVERIFIED:

- The OVH and Outscale calls of `node-provider.py` (OVH follows the existing purge script), and that the Outscale placement is known at plan time.
- A real "running but silent" machine (OVH #371): simulated here by forcing the Ready condition.
- The Longhorn behaviour with the default replica replenishment wait (10 minutes) after a node loss; the alert for "fewer than two healthy replicas" is
  `LonghornVolumeDegraded` (Longhorn exports no replica count).
- Lowering the 5 minute toleration for every pod (kube-apiserver `--default-not-ready-toleration-seconds` and `--default-unreachable-toleration-seconds`): not done, it affects eviction for every pod.
  Only the two CNPG Clusters and CoreDNS carry a 30 s toleration (see the section on DNS above); `kube-controller-manager`'s `node-monitor-grace-period` is the separate lever above (30 s by default since 0.4.0, 0 to keep Kubernetes' 50 s).
- The offline changes after lab 21 ran on a cluster in lab 22 (section above), except: a crash with no NotReady signal from the kubelet (both provider actions shut the OS down cleanly, so the Unknown-driven path, about +76 s plus 30 s, was not observed); the database gap of a zone loss with the primary inside (122 s, above the 30 s target); OVH and Outscale.
- Everything on OVH and Outscale: nothing here ran there.
