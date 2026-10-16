# Network — zones, CIDRs, the two enforcement layers, and the flow matrix

🇫🇷 [Version française](network.fr.md)

> Written to answer ANSSI rules on a documented network architecture, a flow matrix, trust zones and a filtering policy that is
> managed and reviewed (audit ids NET/F07, NET/F09, OSN/F13 stage 0). Everything here was read from the code of this repository; **no
> flow was probed for this document** (`task cluster-netcheck` and `task cluster-exposure` probe a live cluster). The node-inbound tables are
> **generated from the Terraform files** by `scripts/dev/gen-flow-matrix.sh` and compared with this page by `scripts/dev/test-flow-matrix.sh`, so
> they cannot drift from the code without a test going red. It claims no compliance with any ANSSI document.

## 1. Trust zones

| Zone | What is in it | Reaches | Reached from |
|---|---|---|---|
| Z0 Internet | everything else | the public load balancers, and the bastion's port 22 if its address is allowed | n/a |
| Z1 Operator workstation | `.env.sh`, tfvars, keys, `kubectl`, `talosctl`, `tofu` | the bastion (SSH) and the Kubernetes API load balancer (6443), both limited to `admin_ip`; the object stores | the operator only |
| Z2 Bastion | one VM per cluster, public address, sshd; optional baseline, named operators, closed Internet egress | the cluster subnet on 6443 and 50000 (with the closed egress), the Internet on 80/443 otherwise | Z1, from `admin_ip` on port 22 |
| Z3 Public edge | the Kubernetes API load balancer (6443) and, if `deploy_app_lb`, the application load balancer (80/443) | the nodes' private addresses | the Internet (application LB: **no source filter by default**, `app_lb_allowed_cidrs` adds one, see section 6); `admin_ip` (API LB) |
| Z4 Cluster private network | control planes and workers, no public address; one flat subnet per provider | each other, the object stores and registries (outbound) | Z2, Z3, and members of the same subnet |
| Z5 Workloads | namespaces, pods, the Istio ambient mesh for part of them, the foundation namespaces out of the mesh (OpenBao, cert-manager...) | per Cilium policy | per Cilium policy |
| Z6 Object stores | the primary and replica buckets, at the providers | n/a | Z1 (S3 keys), Z4 (backups, Loki, CNPG; per-FQDN egress policy) |

**The admin plane is logical, not physical.** One network interface per node, one subnet for control planes, workers, the bastion's private side and the
load balancers; administration is separated from workloads by who holds the credentials (mTLS on the Talos API and kube-apiserver, an SSH tunnel through
the bastion, an `admin_ip` allowlist), not by a dedicated network. This is a recorded deviation (section 7).

## 2. The two enforcement layers

| Layer | What it is | What it does | What it does not |
|---|---|---|---|
| 1. Provider | Security groups (OVH, Outscale; Scaleway's group filters **public** traffic only and the nodes have no public address), load balancer ACLs and listener allowlists, the bastion's own security group and nftables | Default drop inbound on OVH and Outscale; the Kubernetes API only from `admin_ip` and the LB; the Talos API only from the bastion (OVH, Outscale) | Scaleway: inside the private network it declares the perimeter without enforcing it (`scw/security.tf` header). OVH and Outscale: any traffic between members of the cluster group is admitted (`inter_node`). Outbound from the nodes is open |
| 2. Cluster | Cilium network policies applied by the apps layer (cluster-wide default deny on **ingress**, DNS and kube-API egress allows, a policy per component), Istio ambient mTLS `STRICT` and default-deny authorization per ambient namespace, Cilium WireGuard between nodes | Pod-to-pod filtering, workload identity, node-to-node encryption of pod traffic | **No cluster-wide egress deny** (a cluster-wide one would break DNS under Cilium's policy intersection; the apps file says so). **No host firewall**: `enable-host-firewall` is false and Talos' network rules are not used, so the ports of the nodes themselves (50000, 50001, 2379-2381, 10250) are filtered by layer 1 only, and by each service's own mTLS or authentication |

Both layers are read back from a live cluster by `task cluster-security` (policies, mTLS, WireGuard) and `task cluster-netcheck` (flows the policies must drop).
Per-component egress rules, including the per-provider S3 FQDN lists, are in `OpenAether-apps` (`apps/base/*/networkpolicy.yaml`, checked by `OpenAether-apps/scripts/dev/test-s3-egress-fqdns.py`).

## 3. CIDR plan

| Provider | Node network | Other | Source |
|---|---|---|---|
| Scaleway | `172.16.0.0/22`, pinned on a new private network; a network created before the pin keeps the subnet it got (`scw_subnet_in_use` follows it) | the apiserver VIP (`k8s_vip`, an IPAM reservation) is an address of this subnet | `scw/network.tf` |
| OVH | `10.0.0.0/24`, one subnet for every role | router to Ext-Net for outbound SNAT; the Kubernetes API LB takes a floating address | `ovh/network.tf` |
| Outscale | Net `10.0.0.0/16`; one private subnet per availability zone (`10.0.0.0/24`, then `10.0.2.0/24`, `10.0.3.0/24`...) | public subnet `10.0.1.0/24` (bastion, NAT service, load balancers) | `outscale/network.tf` |
| Proxmox | `network_cidr` (default `10.0.0.0/24`), static addresses by offset | no security group: the in-VM rules and the Proxmox host firewall are the operator's | `proxmox/network.tf` |

Pod and service CIDRs are not set by this repository: Talos' defaults apply (not read from a live cluster for this page). The CIDRs above are the ones in the code; a cluster
that adopted an existing network may differ, which is why the rules follow `scw_subnet_in_use` and not the constant.

## 4. Per-provider diagram

```text
                 Internet
                    |
     (admin_ip only)|                       (no filter unless app_lb_allowed_cidrs)
        +-----------+------------+                     |
        |                        |                     |
   [bastion :22]        [k8s API LB :6443]       [app LB :80/:443]
        |  SSH tunnels            |                     |
        |  to 6443 / 50000        |                     |
 ------ + ---------- node subnet (flat, one NIC per node, no public address) ------
        |                         |                     |
   control planes  <----> workers   (etcd 2379-2381, kubelet 10250, Cilium 8472/51871/4240)
        |                  |
        +-- outbound: image registries, Image Factory, object stores (S3 FQDNs), NTP, DNS
```

The same shape on all four providers; what differs is which layer enforces it. Scaleway: one `/22` private network, a group that does not filter it. OVH: one `/24`,
a group with default drop and an all-protocol rule between members. Outscale: a private subnet per zone behind a NAT service, the LBs on the public subnet and carrying the cluster group.
Proxmox: a bridge, no group; the host-as-bastion default has no separate bastion VM.

## 5. Flow matrix

### 5.1 Administration and management flows (written by hand)

| From | To | Port | Why | Control |
|---|---|---|---|---|
| Operator workstation | Bastion | TCP 22 | the only way to reach the nodes' APIs | `admin_ip` in the bastion group (and optionally in the VM's nftables, `restrict_ssh_source`); keys or short-lived certificates |
| Operator, through the bastion tunnel | Control planes and VIP | TCP 6443 | `kubectl`, Flux status | tunnel `PermitOpen`; kube-apiserver client certificates |
| Operator, through the bastion tunnel | Every node | TCP 50000 | `talosctl`, the Talos provider's apply | OVH, Outscale: the node group admits 50000 from the bastion group only; Scaleway: from the whole node subnet; Talos client certificates (mTLS) |
| Operator workstation | Kubernetes API LB | TCP 6443 | direct API access | `admin_ip` (Scaleway LB ACL, OVH listener `allowed_cidrs`, Outscale group rule) |
| Operator workstation | Object stores | TCP 443 | state, artifacts, snapshots, bastion logs | S3 keys K7; client-side encryption (`key-management.md`) |
| Nodes | Image Factory, registries | TCP 443 | boot images, container images | outbound open; the per-FQDN lists are cluster-side |
| Cluster workloads | Object stores | TCP 443 | restic, CNPG WAL, Loki, Longhorn | Cilium per-FQDN egress (apps) |
| Cluster to the Internet, other | | | | not filtered at layer 1; layer 2 per component, with **no cluster-wide egress deny** |

### 5.2 Node inbound, generated from the code

Each block is the output of `scripts/dev/gen-flow-matrix.sh <provider>`: edit the Terraform, run the script, paste the output between the markers; `scripts/dev/test-flow-matrix.sh` (in `task test-scripts`) fails on any difference.
"Source" is as written in the code: `scw_subnet_in_use` is the node subnet in use, "cluster SG members" every node of the group, "bastion SG" the bastion's group.

**Scaleway**

<!-- flow-matrix:scw:begin -->
| Rule | Protocol | Ports | Source | Present when |
|---|---|---|---|---|
| `kube-apiserver` | TCP | 6443 | node subnet (`scw_subnet_in_use`) | always |
| `talos-apid` | TCP | 50000 | node subnet (`scw_subnet_in_use`) | always |
| `talos-trustd` | TCP | 50001 | node subnet (`scw_subnet_in_use`) | always |
| `etcd` | TCP | 2379-2381 | node subnet (`scw_subnet_in_use`) | always |
| `kubelet` | TCP | 10250 | node subnet (`scw_subnet_in_use`) | always |
| `cilium-vxlan` | UDP | 8472 | node subnet (`scw_subnet_in_use`) | always |
| `cilium-wireguard` | UDP | 51871 | node subnet (`scw_subnet_in_use`) | always |
| `cilium-health` | TCP | 4240 | node subnet (`scw_subnet_in_use`) | always |
| `cilium-icmp` | ICMP | - | node subnet (`scw_subnet_in_use`) | always |
| `cilium-metrics` | TCP | 9962-9964 | node subnet (`scw_subnet_in_use`) | always |
| `node-exporter` | TCP | 9100 | node subnet (`scw_subnet_in_use`) | always |
| `dhcp` | UDP | 68 | node subnet (`scw_subnet_in_use`) | always |
| `gateway-<name>` | TCP | `var.app_lb_node_ports` | node subnet (`scw_subnet_in_use`) | `deploy_app_lb` |
| `carrier-<name>` | TCP | the k8s API port when `k8s_lb_mode = "managed"`, and the gateway ports | `100.64.0.0/10` | the matching load balancer exists |
<!-- flow-matrix:scw:end -->

**OVH**

<!-- flow-matrix:ovh:begin -->
| Rule | Protocol | Ports | Source | Present when |
|---|---|---|---|---|
| `k8s_api` | tcp | 6443 | `10.0.0.0/24` | always |
| `talos_api` | tcp | 50000 | bastion SG | always |
| `http` | tcp | `var.app_lb_node_ports.http` | `10.0.0.0/24` | `deploy_app_lb` |
| `https` | tcp | `var.app_lb_node_ports.https` | `10.0.0.0/24` | `deploy_app_lb` |
| `wireguard` | udp | 51820 | cluster SG members | not `restrict_inter_node` |
| `inter_node` | all | all | cluster SG members | not `restrict_inter_node` |
| `inter_node_ports` | each of the list | the shared list (`_shared/node-ports`) | cluster SG members | `restrict_inter_node` |
<!-- flow-matrix:ovh:end -->

**Outscale**

<!-- flow-matrix:outscale:begin -->
| Rule | Protocol | Ports | Source | Present when |
|---|---|---|---|---|
| `k8s_api_private` | tcp | 6443 | public subnet (LB) | always |
| `k8s_api_admin` | tcp | 6443 | `admin_ip` | always |
| `talos_api` | tcp | 50000 | bastion SG | always |
| `http` | tcp | `var.app_lb_node_ports.http` | public subnet (LB) | `deploy_app_lb` |
| `https` | tcp | `var.app_lb_node_ports.https` | public subnet (LB) | `deploy_app_lb` |
| `app_lb_http` | tcp | 80 | `app_lb_allowed_cidrs`, cluster egress | `deploy_app_lb` and `app_lb_allowed_cidrs` |
| `app_lb_https` | tcp | 443 | `app_lb_allowed_cidrs`, cluster egress | `deploy_app_lb` and `app_lb_allowed_cidrs` |
| `wireguard` | udp | 51820 | cluster SG members | not `restrict_inter_node` |
| `inter_node` | all | all | cluster SG members | not `restrict_inter_node` |
| `inter_node_ports` | each of the list | the shared list (`_shared/node-ports`) | cluster SG members | `restrict_inter_node` |
<!-- flow-matrix:outscale:end -->

Proxmox has no security group; its ports are the same services, filtered by whatever the operator runs on the host or bridge.

### 5.3 Why each rule exists, and what it compensates

The test requires every rule name above to have a row here, in both languages.

| Rule | Justification | Compensating measure |
|---|---|---|
| `kube-apiserver`, `k8s_api`, `k8s_api_private`, `k8s_api_admin` | kubelets, the bastion tunnel, the VIP and the API load balancer reach the apiserver | client-certificate authentication; the API LB limited to `admin_ip` |
| `talos-apid`, `talos_api` | the Talos provider's apply, `talosctl`, apid proxying between nodes | Talos mTLS; OVH, Outscale: bastion group only. **Scaleway admits the whole subnet** (the group is not enforced there anyway) |
| `talos-trustd` | workers fetch their certificates from the control planes | mTLS |
| `etcd` | client, peer and metrics ports between control planes | etcd CA mTLS |
| `kubelet` | apiserver to kubelet | kubelet authentication and authorization |
| `cilium-vxlan`, `cilium-wireguard`, `cilium-health`, `cilium-icmp`, `cilium-metrics`, `wireguard` | pod networking, its encryption, health probes and path MTU discovery, agent metrics. On OVH and Outscale the `wireguard` rule names 51820 while Cilium's WireGuard listens on 51871: harmless today only because `inter_node` admits everything between members | WireGuard encrypts pod traffic between nodes |
| `node-exporter` | metrics scrape, apps layer, hostNetwork (unverified here) | none beyond the subnet |
| `dhcp` | private-network address leases (unverified) | none |
| `gateway-<name>`, `http`, `https` | the application load balancer's backends on the Gateway's fixed NodePorts | only exists with `deploy_app_lb`; the Gateway's own routes authenticate (`OpenAether-apps/docs/public-exposure.md`) |
| `app_lb_http`, `app_lb_https` | Outscale only: the load balancer's group is the cluster group, so the allowed public clients of 80/443 are rules in it | only with `app_lb_allowed_cidrs`; not run on a cloud, whether the group filters the load balancer at all is the first lab check |
| `carrier-<name>` | load-balancer backend traffic that arrives from the carrier range; the origin is unconfirmed | kept until a real deploy shows it unused |
| `inter_node` | all traffic between nodes (etcd, kubelet, Cilium) | **any port and any protocol between members**: broader than the matrix needs. Default; `restrict_inter_node = true` replaces it (and `wireguard`) by `inter_node_ports` |
| `inter_node_ports` | the same flows as the Scaleway list (without DHCP), one rule each, members only; WireGuard on 51871 | only with `restrict_inter_node`; the list is one file (`modules/providers/_shared/node-ports`) shared with Scaleway and the Talos rules; plan-checked, not run on a cloud (LAB-CHECKLIST B24) |

### 5.4 Bastion

Inbound: TCP 22 from `admin_ip`. Outbound (default `legacy`): the cluster subnet, DNS, NTP, and 80/443 to anywhere for updates. With `bastion_internet_egress = { mode = "closed" }`:
only TCP 6443 and 50000 to the cluster subnet, ICMP in the subnet, the metadata addresses on 80, and DNS/NTP to the pinned servers (`admin-access.md`).

## 6. Known gaps in the filtering

Listed so that a reader does not take the matrix for more than it is. None is changed by this page.

1. **Scaleway's group does not filter the private network.** The rules are exact so that a host firewall can enforce them later.
2. **No host firewall by default.** Nodes admit 50000, 50001, 2379-2381 and 10250 from the whole subnet (Scaleway) or the group (OVH, Outscale), including from a compromised node or a hostNetwork pod. Each service's own mTLS or authentication is the only barrier.
   Staged plan: stage 0 is this page; stage 1 is `restrict_inter_node` (below); stage 2 is `node_firewall_mode = "rules_only"`, which writes one Talos `NetworkRuleConfig` per TCP/UDP flow of the shared list (none for ICMP: Talos refuses a rule without ports, and its own firewall already allows ICMP, rate limited, once the default action blocks; found on a real node, lab 11) with a default ingress action of accept: the rules exist on the node and nothing is blocked. **Enforcement (`block`) is not implemented**; it waits for a soaked rules_only and a rehearsed exit path. Both switches are off by default and neither was run on a cluster.
3. **OVH and Outscale `inter_node` admits every protocol and port between members** unless `restrict_inter_node = true` (default false: nothing changes until it is set). Replacing the rules is not atomic: a few seconds may lack the new ones while the old are gone.
4. **Node egress is open** (Scaleway `outbound_default_policy = accept`, OVH explicit all-egress rules, Outscale declares none). A compromised node can reach anything; an egress allowlist risks image pulls, S3 backups and first boot and needs a design.
5. **The application load balancer has no source filter by default** when `deploy_app_lb` is true: every route on the Gateway answers anyone who sets its Host header, and a route's own login is its only protection
   (`OpenAether-apps/docs/public-exposure.md`, which lists the routes and how each authenticates). `admin_ip` guards the Kubernetes API frontend and the bastion only. `admin-access.md` said the gateway was "nothing public": corrected.
   **`app_lb_allowed_cidrs` (empty by default, so nothing changes until it is set) adds the filter at the provider**: Scaleway allow-then-deny ACLs on both frontends, OVH `allowed_cidrs` on both listeners, Outscale
   security-group rules; Proxmox and local have no cloud load balancer. The list must hold every public client, the cluster's own egress address is added automatically. It was checked by plan assertions only (mocked): that a cloud
   enforces it, that pods still reach Zitadel through the load balancer and that the update is in place are lab checks (`admin-access.md`, section 6). It does not authenticate anything: a listed address still reaches every route's login.
6. **No cluster-wide egress deny** (section 2).

## 7. Recorded deviations

| Deviation | Rule's intent | What is here instead | Revisit |
|---|---|---|---|
| Flat network, no dedicated administration network (PA-022 R15) | The administration plane separated from the workloads | One subnet per provider; administration over an SSH bastion plus mTLS, with an `admin_ip` allowlist in front of both the bastion and 6443 | A public cloud offers no dedicated physical administration network; revisit when a provider offers a private admin VLAN, or for Proxmox where the operator controls the bridges |
| SSH bastion plus mTLS instead of an IPsec or WireGuard control plane (decision #82, `admin-access.md`) | Administration flows protected by an encrypted tunnel | The bastion stays, hardened in place; the tunnel is SSH, the inner protocols (Talos API, kube-apiserver) are mTLS | Two or more operators, or a stateful service whose restore has been run: an OIDC issuer, an SSH CA or a WireGuard control plane each need an always-on host |
| One subnet for control planes, workers and the bastion | Zoning between roles | Not split; Outscale splits public from private for egress reasons, not for administration | Optional per-role subnets on Scaleway and OVH |
| Pod-to-pod traffic encrypted by Cilium WireGuard, not IPsec | Encrypted node-to-node links | WireGuard, observed enabled by `task cluster-security` | n/a |

## 8. Review cadence

Re-read this page, regenerate the tables (`scripts/dev/gen-flow-matrix.sh`), and run the checks of `release-checklist.md` ("Quarterly security review"):

- at least every quarter, and at every release;
- whenever `security.tf`, a `lb.tf`, a bastion rule, `admin_ip` or a Cilium policy of the apps layer changes: a change to a security-group file also changes the generated tables, and the test says so;
- after every incident that touched the network (`incident-response.md`).

The review asks: is every open port in the matrix still used; is any rule broader than its row says; did a provider change what its group enforces; is a gap of section 6 closed or worse?
