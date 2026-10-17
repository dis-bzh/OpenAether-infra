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
| `management-`, `failover-scaleway` | 3+2 × `POP2-4C-16G` (4 / 16 GB) | 6 | 22 | 82 GB | Type yes; headroom on 2 workers unmeasured | no Scaleway backend |
| `workload-scaleway` | 3+3 × `POP2-4C-16G` | 7 | 26 | 98 GB | Yes | no Scaleway backend |
| `management-`, `failover-ovh` | 3+2 × `c3-8` (4 / 8 GB) | 6 | 22 | 48 GB | Type yes; headroom on 2 workers unmeasured | `--add-vms 6 --add-cores 22 --add-ram-gb 48` |
| `workload-ovh` | 3+3 × `c3-8` | 7 | 26 | 56 GB | Yes | `--add-vms 7 --add-cores 26 --add-ram-gb 56` |
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
