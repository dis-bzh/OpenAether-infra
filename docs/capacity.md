> 🇫🇷 [Version française](capacity.fr.md)

# Capacity per provider

What a cluster consumes, per provider, before you deploy it. The modules under
`infrastructure/opentofu/modules/providers/` are the authority; this page is
their arithmetic applied to the shipped `envs/*.tfvars.example`.

Every figure is **derived** from that code unless marked **measured**, with
where the repository records the measurement. vCPU/RAM per type come from the
provider's naming or catalogue (Outscale `tinavX.cNrM` = N vCPU, M GB), not
from a run.

## Sizing floor

| Rule | Evidence |
|---|---|
| Workers must leave one node's worth of CPU requests free, or no drain completes and `rolling-replace --upgrade` stalls. | **Measured** 2026-08-15, application platform on: 3× Scaleway `DEV1-L` (4 vCPU / 8 GB) at 72/47/27%, every drain went through; 3× OVH `b3-8` (2 vCPU / 8 GB) at 78/99/100%, none could. [`upgrade.md`](upgrade.md) |
| Workers ≥ 8 GB RAM. | Stated in `modules/providers/proxmox/variables.tf` (a `DEV1-M` OOM); the run behind it is not recorded. |
| HA = 3 control planes (etcd quorum); non-HA = 1 + 1, control plane tainted `NoSchedule`. | Code. |

So the floor for a cluster that will carry the platform is **workers of at
least 4 vCPU / 8 GB, enough of them to lose one**. Each cloud module takes one
instance type for control planes and workers alike, so the floor applies to
both. A bare cluster (Cilium only, the 0.2.0 scope) needs less: a bare 3+3 on Outscale's
`tinav5.c2r4p1` (2 vCPU / 4 GB) deployed and verified on 2026-10-03, which is the one point measured.

## What each provider creates

Defaults: `k8s_lb_mode = "managed"`, `deploy_app_lb = false`. CP / W = control
planes / workers, D = entries in `worker_storage.disks`.

| | Scaleway | OVH | Outscale | Proxmox |
|---|---|---|---|---|
| Instances | CP+W + bastion `DEV1-S` (2 vCPU / 2 GB) | CP+W + bastion `b3-8` (2 vCPU / 8 GB) | CP+W + bastion `tinav5.c2r2p2` (2 vCPU / 2 GB) | CP+W; + bastion (1 vCPU / 1 GiB / 10 GiB) only with `enable_bastion` |
| Node system disk | 50 GB `sbs_volume` each (`scw_root_volume_size_gb`; at least 40 with `deploy_flux`, enforced) | the flavour's disk (at least 50 GB; `check` warns below 40) | the OMI's (~11-12 GiB): set `outscale_root_volume_size_gb = 50` (`check` warns) | `root_disk_gb` (50 GiB) each (`check` warns below 40) |
| Data volumes | W × D | W × D | W × D | W × D, on `datastore_id` |
| Public IPs | 3: bastion, public gateway, API LB | 2 floating: bastion, API LB | 2: bastion, NAT | none — `host_public_ip` is yours |
| Load balancers | 1 | 1 (Octavia) | 1 (LBU) | none — Talos VIP |
| Security groups | 1 per entry in `zones` + 1 bastion | 2 | 2 | none |
| Network | 1 private network, 1 public gateway | 1 network, subnet, router | 1 Net, 2 subnets, internet + NAT service | your bridge; CP+W + 1 VIP static IPs in `network_cidr` |

`deploy_app_lb = true` adds one LB and one public IP on each cloud.
`k8s_lb_mode = "vip"` (OVH; experimental on Scaleway) swaps the API LB and its
IP for a private address.

## The shipped examples

Totals include the bastion. `preflight-quotas` checks instances, vCPU and RAM,
on OVH and Outscale only — the last column is what to pass it. No script checks
IPs, LBs or security groups.

| Example | Nodes × type (vCPU / RAM) | Inst. | vCPU | RAM | Meets the floor? | `task preflight-quotas PROVIDER=… --` |
|---|---|---|---|---|---|---|
| `management-`, `failover-scaleway` | 3+4 × `POP2-4C-16G` (4 / 16 GB) | 8 | 30 | 114 GB | Yes; rollable, see the arithmetic below | no Scaleway backend |
| `workload-scaleway` | 3+4 × `POP2-4C-16G` | 8 | 30 | 114 GB | Yes | no Scaleway backend |
| `management-`, `failover-ovh` | 3+4 × `c3-8` (4 / 8 GB) | 8 | 30 | 64 GB | Yes; rollable, see the arithmetic below | `--add-vms 8 --add-cores 30 --add-ram-gb 64` |
| `workload-ovh` | 3+4 × `c3-8` | 8 | 30 | 64 GB | Yes | `--add-vms 8 --add-cores 30 --add-ram-gb 64` |
| `management-`, `failover-outscale` | 3+2 × `tinav5.c2r4p1` (2 / 4 GB) | 6 | 12 | 22 GB | **No, on purpose** — see below | `--add-vms 6 --add-cores 12 --add-ram-gb 22` |
| `workload-outscale` | 3+3 × `tinav5.c2r4p1` | 7 | 14 | 26 GB | **No, on purpose** | `--add-vms 7 --add-cores 14 --add-ram-gb 26` |
| `*-proxmox` | 1+1 × 4 vCPU / 8 GiB, 20 GiB disk | 2 | 8 | 16 GiB | Type yes; one worker cannot be drained without downtime | host capacity, not a quota |

Also against the examples:

- **Why the Outscale examples stay below the floor.** The default account quota is 20 vCPU / 40 GB.
  The module takes one type for every node, so the floor (4 vCPU / 8 GB) on 5 nodes plus the
  bastion is 22 vCPU: it does not fit. A bare cluster (Talos + Cilium) deployed and verified on
  `tinav5.c2r4p1` at 3+3 on 2026-10-03; carrying the platform there needs a higher quota first.
- Scaleway's old `workload` example used `DEV1-M`, a local-SSD type, while the module always
  asks for an `sbs_volume` root, and its `zones` include `fr-par-3`, where the
  management example's comment says `DEV1-M` is not offered. No run is recorded.
- **Measured** on Outscale: 3+3 of `tinav5.c2r7p2` does not fit the test
  account's RAM quota and `preflight-quotas` refuses it; the 3+1 that fits
  deploys but has one schedulable worker
  ([`deployment-test-matrix.md`](deployment-test-matrix.md), `OSC-mgmt-ha`;
  issue #72). A path to the floor within that quota is untested, and Outscale
  changes `vm_type` with a stop/start — resize one node at a time.
- The real-cloud runs in [`status.md`](status.md) record the instance type only for Outscale
  (`tinav5.c2r4p1`), so Scaleway's and OVH's establish no floor.

## Can the cluster lose a worker, and be rolled? (infra #378)

`cluster-roll` refuses to start when the CPU requests of all workers, each as a percentage of its own node, add up to more than
(workers - 1) x 100%: one node's worth of requests must fit on the others (`worker_cpu_requests` / `preflight_roll`,
`scripts/lib/roll-gates.sh`). **Measured** in lab 16 with the full application stack on a management cluster, requests as % of a
worker's allocatable CPU:

| Profile (as shipped before) | Workers | Requested | Limit | Verdict |
|---|---|---|---|---|
| Scaleway 3+2 `POP2-4C-16G` | 82% + 90% | 172% | 100% | refused |
| OVH 3+2 `c3-8` | 81% + 91% | 172% | 100% | refused |
| Outscale 3+3 `tinav5.c3r6p2` (3 vCPU) | 239% in all | 239% | 200% | refused |

Arithmetic (derived from those numbers, taking a worker's allocatable as about its vCPU count): on 4 vCPU the 172% is about 6.9 vCPU in
total, on 3 vCPU the 239% is about 7.2 vCPU, so requests are roughly 6.3 vCPU of fixed deployments plus 0.3 vCPU of DaemonSets per
worker (an estimate from two points, not a measurement of each). With n workers of 4 vCPU the gate needs 6.3 + 0.3n <= 4(n - 1):
n = 3 gives 7.2 against 8 (about 90% of the limit, 180% against 200%); n = 4 gives 7.5 against 12. The examples for Scaleway and OVH
therefore shipped 3 workers until 0.4.0 (they ship **4** now, see below: the measured load of the full platform needs it). The margin at 3 is thin: a heavier app set can break it, and the gate says so before anything is touched.
This is the CPU gate only: replicas with a required spread (three OpenBao pods, for instance) stay short while a worker is out, and
the cluster-wide behaviour of losing a node under load belongs to 0.4.0 (resilience), not to this table.

**0.4.0 (M4): derived first, then measured (lab 21).** The high-availability work adds about 345 m of CPU requests to the platform (a second Kyverno admission controller, CNPG
operator, ESO controller and webhook, metrics-server and Zitadel login, and a second Alertmanager). The derivation (6.3 vCPU fixed + 0.345 + 0.3 per worker) gave 7.55 vCPU on 3 workers
(margin 0.45 of 8) and 7.85 on 4. **Lab 21 measured** (Scaleway, 4 x `POP2-4C-16G`, the full platform and three small probes): 9095 m = 228% of one worker right after Flux converged,
223-224% later (53/43/70/57% per worker), and `cluster-roll`'s own survey printed `223% requested, 300% available without one worker`. The derivation under-counted by about 1.2 vCPU.
Consequences: on 3 workers the measured load (about 9 vCPU) is above the 8 vCPU the gate leaves, so **3 workers would be refused**; the owner's decision of 2026-10-21 to ship
**4 workers of 4 vCPU** on Scaleway and OVH is the minimum for the full platform, not a margin. 4 workers pass at 74-76% of the gate's limit (about 2.9 vCPU to spare). The Deployments
and StatefulSets that the application repository renders request 3005 m (`python3 scripts/check-ha.py`, budget 3300 m); the rest is DaemonSets, operators and Jobs, which no render shows.
`task failure-domain-check` applies the same arithmetic to the loss of a whole zone, and there four workers do not help the worst case: they spread 2 + 1 + 1 over three zones, so
losing the zone with two of them leaves two workers (200%) for 224% of requests, about 1 vCPU short; the check says so, and lab 21 lost that zone for 10 minutes (twice): nothing
stopped, but pods stayed Pending until the zone returned. Five workers (2 + 2 + 1: losing two leaves 300%) or six would hold on the arithmetic (see the lab 21 results for what a fifth
worker did), as would about 12% fewer requests. Which of these the examples should ship was decided on 2026-10-21 (below).

### What the shipped 4 workers survive, and what they do not (decision of 2026-10-21, infra #389)

The Scaleway and OVH examples ship **4 workers**, placed round-robin over three zones, so 2 + 1 + 1. Said plainly:

| Loss | Survives? | Why (measured load: 223-228% of a worker, about 9 vCPU, lab 21) |
|---|---|---|
| One worker (a drain, a reboot, a crash) | **Yes** | 3 workers = 300% for 224% requested; `cluster-roll` passes at 74-76% of its limit |
| A zone holding one worker (either of the two) | **Yes** | 3 workers stay, 300% for 224% |
| **The zone holding two workers** | **No** | 2 workers stay = 200% for 224%: about 1 vCPU of requests cannot be placed and pods stay Pending until the zone returns (lab 21 lost that zone for 10 minutes, twice: nothing stopped, pods stayed Pending until the zone returned). `task failure-domain-check` reports it as a refused loss |

Control planes are not affected: three of them in three zones keep an etcd quorum through any one zone.

### Profile "5 workers zone-HA" (2 + 2 + 1)

Set `workers = 5` in the management example of Scaleway or OVH (a commented block in each `envs/management-*.tfvars.example` says so); nothing else changes.
The modules place workers round-robin over the zone list (`element(zones, index)`), so five land 2 + 2 + 1 and **any one zone** can be lost: the least
favourable loss removes two workers and leaves three (300%). The load grows by about one DaemonSet's worth per added worker (about 0.3 vCPU), so
five workers request about 230% of a worker (derived: 224% plus one DaemonSet's share; no zone loss on five workers is recorded in this repository), well inside 300%.

`task failure-domain-check PROVIDER=<scaleway|ovh>` (read-only, needs the deployed state) is the expected verdict:

| Workers | Zones | `If <zone> is lost` | Verdict |
|---|---|---|---|
| 4 (shipped) | 2 + 1 + 1 | the zone with two: `workers: 2 stay, but the workers request 224% of a node and 2 hold 200%` | exit 1 for that zone; the other two zones pass |
| 5 | 2 + 2 + 1 | `workers: 3 of 5 stay, requests 230% fit in 300%` for the two-worker zones; 4 of 5 for the other | exit 0, every loss survivable |

The script test `scripts/dev/test-failure-domain-check.sh` runs both shapes against stub `tofu` and `kubectl`. That proves the arithmetic of the check, not a
cluster: no zone loss on the 5-worker shape is recorded here. Cost: one more instance and 4 vCPU (and the matching quota) per cloud. Outscale is
not covered (its examples are below the floor, see above).

Outscale (the examples are unchanged and stay within the 20 vCPU quota): no shape fits the default 20 vCPU quota and passes the gate. 3 workers of 3 vCPU fail (above), and 4 workers of 3 vCPU need
3 + 4 nodes x 3 + 2 (bastion) = 23 vCPU. The smallest passing shape on the arithmetic is 3+3 `tinav5.c4r8p2` (4 vCPU / 8 GB): 26 vCPU with
the bastion (thin, see the 0.4.0 paragraph above), and the 3 + 4 shape of the other clouds is 30 vCPU, so a quota raise comes first. Neither has been run on Outscale. The 6 GB nodes of lab 16 also fell into an IO and memory
cascade after one backup and restore and one drained reboot (#376); the root volume is gp2 (type not configurable here), and an `io1 3000`
change made by hand did not stop it. The example now sets `outscale_root_volume_size_gb = 50` rather than leaving it commented.

## System disk and the full application stack (all providers)

Talos keeps its EPHEMERAL partition (kubelet, containerd images, logs) on the system volume, about 4 GB under the volume size. With the
whole application stack at its current chart versions a worker held about 11 GB of images (lab 12, Scaleway), against about 15.6 GB of
ephemeral space on a 20 GB volume: the kubelet reported DiskPressure, evicted pods (25 Zitadel pods in the first minutes) and container
creation timed out.

**Minimum: 40 GB per node with the application stack; the default is 50 GB** (about 46 GB usable): the ~11 GB of images, the second set a
chart upgrade pulls before the old one is garbage-collected (the kubelet starts image GC at 85% use), logs, and margin. Per provider:

| Provider | Where it is set | Default | Guard |
|---|---|---|---|
| Scaleway | `scw_root_volume_size_gb` | 50 | a validation refuses less than 40 with `deploy_flux = true` (20 stays valid without it) |
| OVH | the flavour (`flavor_name`) | `b3-8` / `c3-8`: 50 GB | a `check` warns when the flavour's disk, read from the account, is below 40 GB |
| Outscale | `outscale_root_volume_size_gb` (BSU root of the VM) | null = the OMI's own size, the raw Talos image (~11-12 GiB), **not enough** | a `check` warns with `deploy_flux` until it is 40 or more; applies to nodes created afterwards |
| Proxmox | `root_disk_gb` in `node_distribution` | 50 GiB | a `check` warns below 40 |

Raising Scaleway's value on a running cluster is an in-place resize of the `sbs_volume` (lab 12: `cluster-up` plan "10 to change", no node
replaced); Talos grows the EPHEMERAL partition at the node's next reboot, so drain and reboot the workers one at a time afterwards (lab 12:
15.6 GB to 35.6 GB; see the RWX warning in [`upgrade.md`](upgrade.md)). A cluster built at 20 and not pinning it in its tfvars shows that resize at its
next plan; pin `scw_root_volume_size_gb = 20` to keep the old size (a full stack will not fit). On Outscale and Proxmox the OMI root volume is not resized
in place by this code: replace the nodes one at a time (`task cluster-roll`). Not measured: Outscale's usable space and OVH's, with the full stack
(lab 12 ran the full stack on Scaleway only; the Outscale run was the reduced profile).
