# Provider Module Contract

Every cloud provider module in `modules/providers/<name>/` **MUST** implement
this contract to be consumed by the Talos module and the root `main.tf`.

## Required Outputs

| Output | Type | Description |
|---|---|---|
| `control_plane_private_ips` | `list(string)` | Private IPs of control plane nodes (used by Talos on 50000/TCP) |
| `worker_private_ips` | `list(string)` | Private IPs of worker nodes |
| `k8s_lb_ip` | `string` | Public IP of the Kubernetes API Load Balancer (port 6443) |
| `bastion_ip` | `string` | Public IP of the bastion host (SSH jump server) |
| `control_plane_zones` | `list(string)` | Failure domain of each control plane (zone, AZ, subregion or hypervisor host), one per node, in the order of `control_plane_private_ips`. A module that cannot spread reports the one domain it uses, never a list built from an input it ignores. |

## Optional Outputs

| Output | Type | Description |
|---|---|---|
| `app_lb_ip` | `string` (nullable) | Public IP (or DNS name) of the application Load Balancer (ports 80/443). A module that gates that LB behind `deploy_app_lb` MUST return `null` when it is off, never fail — use `one(...)`. |
| `nat_gateway_ip` | `string` | Public IP of the NAT gateway (for LB ACL whitelisting) |

## Required Variables

| Variable | Type | Description |
|---|---|---|
| `cluster_name` | `string` | Name of the cluster (used for resource naming) |
| `control_plane_count` | `number` | Number of control plane nodes to provision |
| `worker_count` | `number` | Number of worker nodes to provision |
| `admin_ip` | `list(string)` | Allowed CIDRs for admin access (SSH, K8s API ACLs) |
| `bastion_ssh_keys` | `list(string)` | SSH public keys for bastion access (a list, so several admins can hold one) |

> These tables are checked, not decorative: `scripts/dev/check-provider-contract.sh`
> compares every module against them by name and by type, and `task lint` runs it.
> It was written because this row said `bastion_ssh_key` / `string` while all four
> modules had always declared `bastion_ssh_keys` / `list(string)` — a contract with
> zero implementers, pointed at by CLAUDE.md as the authority.

## Rules

1. **No Talos logic** — Provider modules MUST NOT contain `data.talos_machine_configuration`,
   `talos_machine_secrets`, or any Talos-specific resources. Talos configuration is handled
   exclusively by the centralized `modules/talos/` module.

2. **`user_data` delivery is opt-in** — the default cloud delivery mode is
   `talos_machine_configuration_apply` (gRPC maintenance-mode apply). Provider
   modules MAY expose a `user_data` variable to inject Talos config at VM creation
   when the platform supports it (`config_delivery = "userdata"` in the Talos module).
   Docker/container platforms require this mode; cloud providers may use it to skip
   the maintenance-mode phase and shorten bootstrap time.

3. **Private-first networking** — All cluster nodes (control planes + workers) SHOULD
   reside in a private network with no public IP. A bastion host provides admin access,
   and a NAT gateway provides outbound connectivity.

4. **Security groups** — Inbound default policy MUST be `drop`. Only explicitly
   required ports should be allowed (6443 from LB, 50000 from bastion, inter-node mesh).
   Check what the cloud's group actually filters: Scaleway's filters public traffic
   only (see `scw/security.tf`).

5. **Scale-in** — `scripts/ops/shrink-nodes.sh` reads a lowered count off the saved plan, so a node's
   resources MUST be count-indexed by node and carry `control_plane` or `worker` in their name (a data
   volume is keyed `"w<worker>-d<disk>"`, a load balancer member is named for its pool and goes by type),
   and its machine resource MUST be among them. A load balancer's membership MUST update in place when a
   node leaves, never be replaced: replacing it would empty the backend list.

## Node image drift

Every node resource must carry `lifecycle { ignore_changes = [<image attribute>] }`.

A Talos node's boot image is the medium it was *installed* from, nothing more.
Once the node runs, its version comes from the installer image in the machine
config, and `talosctl upgrade` changes that version without touching the cloud
resource. So after an upgrade the two disagree by design: the instance still
reports the old image id.

Left alone, that disagreement is destructive. Bumping `talos_version` makes the
image data source resolve to a new id, and the attribute is ForceNew on Scaleway
and a disk-wiping rebuild on OpenStack — so a routine `tofu apply` would replace
every node, all control planes at the same time, and etcd would lose quorum.

Ignoring the attribute keeps new nodes on the new image while existing ones are
upgraded in place. Re-imaging on purpose is still available and still the way to
do it: `scripts/ops/rolling-replace.sh` passes an explicit `-replace`, one node
at a time, with health gates between them.

## Architecture

```
Provider Module (cloud-specific)          Talos Module (cloud-agnostic)
┌─────────────────────────────┐          ┌──────────────────────────────┐
│ VMs (no public IP)          │          │ Machine secrets              │
│ Private Network / VPC       │──IPs──►  │ Machine configuration        │
│ Load Balancers (K8s + App)  │          │ Configuration apply (API)    │
│ Security Groups             │          │ Bootstrap (etcd)             │
│ Bastion Host                │          │ Kubeconfig retrieval         │
│ NAT Gateway                 │          │ Inline manifests (Cilium,    │
│                             │          │   Flux, Root App)          │
└─────────────────────────────┘          └──────────────────────────────┘
```

## Reference Implementation

See `modules/providers/scw/` for the canonical implementation of this contract.
