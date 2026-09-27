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
both. A bare cluster (Cilium only, the 0.1.0 scope) needs less; no run has
measured how much less.

## What each provider creates

Defaults: `k8s_lb_mode = "managed"`, `deploy_app_lb = false`. CP / W = control
planes / workers, D = entries in `worker_storage.disks`.

| | Scaleway | OVH | Outscale | Proxmox |
|---|---|---|---|---|
| Instances | CP+W + bastion `DEV1-S` (2 vCPU / 2 GB) | CP+W + bastion `b3-8` (2 vCPU / 8 GB) | CP+W + bastion `tinav5.c2r2p2` (2 vCPU / 2 GB) | CP+W; + bastion (1 vCPU / 1 GiB / 10 GiB) only with `enable_bastion` |
| Node system disk | 20 GB `sbs_volume` each | the flavour's disk | the OMI's default | `root_disk_gb` (20 GiB) each |
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
| `management-`, `failover-scaleway` | 3+2 × `POP2-2C-8G` (2 / 8 GB) | 6 | 12 | 42 GB | **No** — 2 vCPU | no Scaleway backend |
| `workload-scaleway` | 3+3 × `DEV1-M` (3 / 4 GB) | 7 | 20 | 26 GB | **No** — 4 GB | no Scaleway backend |
| `management-`, `failover-ovh` | 3+2 × `c3-8` (4 / 8 GB) | 6 | 22 | 48 GB | Type yes; headroom on 2 workers unmeasured | `--add-vms 6 --add-cores 22 --add-ram-gb 48` |
| `workload-ovh` | 3+3 × `c3-8` | 7 | 26 | 56 GB | Yes | `--add-vms 7 --add-cores 26 --add-ram-gb 56` |
| `management-`, `failover-outscale` | 3+2 × `tinav5.c2r4p1` (2 / 4 GB) | 6 | 12 | 22 GB | **No** | `--add-vms 6 --add-cores 12 --add-ram-gb 22` |
| `workload-outscale` | 3+3 × `tinav5.c2r4p1` | 7 | 14 | 26 GB | **No** | `--add-vms 7 --add-cores 14 --add-ram-gb 26` |
| `*-proxmox` | 1+1 × 4 vCPU / 8 GiB, 20 GiB disk | 2 | 8 | 16 GiB | Type yes; one worker cannot be drained without downtime | host capacity, not a quota |

Also against the examples:

- `workload-scaleway`'s `DEV1-M` is a local-SSD type, while the module always
  asks for an `sbs_volume` root, and its `zones` include `fr-par-3`, where the
  management example's comment says `DEV1-M` is not offered. No run is recorded.
- **Measured** on Outscale: 3+3 of `tinav5.c2r7p2` does not fit the test
  account's RAM quota and `preflight-quotas` refuses it; the 3+1 that fits
  deploys but has one schedulable worker
  ([`deployment-test-matrix.md`](deployment-test-matrix.md), `OSC-mgmt-ha`;
  issue #72). A path to the floor within that quota is untested, and Outscale
  changes `vm_type` with a stop/start — resize one node at a time.
- The real-cloud runs in [`status.md`](status.md) do not record the instance
  types they used, so they establish no floor.
