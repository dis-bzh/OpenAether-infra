# Proxmox provider module

Implements `../provider-contract.md` for **Proxmox VE** (single host or multi-host
PVE cluster). VMs are round-robined across `node_names` via `element()` — same
pattern as Scaleway zones. `node_names = ["pve1"]` = non-HA (all VMs on one host);
`node_names = ["pve1","pve2","pve3"]` = true HA (1 CP per physical host, etcd quorum
distributed). The `modules/talos` and `cluster/` layers stay provider-agnostic —
this module only supplies IPs + endpoints.

## What differs from the cloud providers

Bare-metal has no managed LB / NAT / floating-IP / security-group service, so:

| Concern            | Cloud (scw/ovh/outscale)        | Proxmox (here)                          |
|--------------------|---------------------------------|-----------------------------------------|
| Kubernetes API     | managed LB → `k8s_lb_ip`        | **Talos VIP** → `k8s_lb_ip` (no LB)     |
| Node IPs           | cloud IPAM                      | **static** via `cidrhost()` + offsets   |
| Egress             | NAT gateway resource            | host bridge gateway + host NAT          |
| Inbound firewall   | cloud security group            | **host nftables** (perimeter) + Cilium  |
| App LB (80/443)    | managed LB → `app_lb_ip`        | none — host DNAT → worker (see below)   |
| Admin jump         | dedicated bastion VM            | **the Proxmox host itself** (default)   |

The cloud modules ship a per-VM security group; this module does **not** program
the Proxmox per-VM firewall. On one host that would force `pve-firewall` on and
collide with the host's raw nftables (see hardening). Instead the security model
is two layers that already exist: **host nftables** as the perimeter (the
security-group equivalent — nodes sit on a private `vmbr1`, unreachable from the
WAN except the 80/443 DNAT) and **Cilium ambient** for intra-cluster policy
(shipped in `OpenAether-apps`).

### Why no LB (and no bastion VM by default)

On bare-metal there is **no managed LB/NAT/floating-IP**. So:

- **K8s API = Talos VIP.** kubectl/talosctl only need an IP/URL; there is nothing
  a LB would add. The VIP floats across CPs, so it covers multi-CP scale-up too.
  No LB resource, ever, on Proxmox.
- **Admin jump = the host.** You already SSH the Proxmox host to run Debian/
  Proxmox upgrades, and it routes `vmbr1` to the private nodes. That access *is*
  the bastion — `enable_bastion = false` (default) points the contract's
  `bastion_ip`/`bastion_user` at the host (`host_public_ip`/`host_ssh_user`), and
  `talos-tunnels.sh` tunnels through it unchanged. A bastion VM would only burn a
  VM slot + RAM on a resource-constrained box. Set `enable_bastion = true` if you
  want an isolated jump VM anyway.
- **App 80/443 = host DNAT.** No managed app LB; the host DNATs `:80/:443` to a
  worker IP (`worker_ingress_targets` output). See "Host NAT/DNAT" below.

### Break-glass

Keep the OVH **IPMI/KVM console** (out-of-band, via the OVH Manager — no host port
exposed) as your recovery path. That lets you harden host SSH aggressively without
risk of locking yourself out. Note: IPMI may be limited on the Eco/SYS line —
confirm on your model in the Manager.

## apiserver VIP (set from the first control plane)

`apiserver_vip` is a spare address in `network_cidr` the control plane owns so a
later move from 1 CP → 3 CP does **not** re-address the apiserver. This module
surfaces it as `k8s_lb_ip`; `cluster/main.tf` passes it straight through to
`modules/talos`, which injects it into the control plane machineconfig
(`machine.network.interfaces[].vip`) and adds it to `cluster.apiServer.certSANs`.

## Host prerequisites (manual, once)

1. Proxmox VE cluster with a datastore for VM disks (`datastore_id`, e.g. `local-zfs`
   on ZFS mirror) and one for snippets/images (`iso_datastore_id`, e.g. `local`).
2. A bridge for the cluster subnet (`network_bridge`, e.g. `vmbr1`) with the host(s)
   holding `gateway_ip` and routing/NAT to the internet. **Multi-host**: the bridge
   must be L2-connected across all hosts (VXLAN, WireGuard L2, or provider VLAN) so
   Talos VIP + Cilium work across hosts.
3. The Talos nocloud image downloaded onto `iso_datastore_id` — run
   `task image-build PROVIDER=proxmox` (uses `../../talos-image/modules/talos-image/proxmox`,
   `proxmox_virtual_environment_download_file`) once per Talos version. `talos_image_file_id`
   defaults to that download's path (`<iso_datastore_id>:iso/talos-<version>-nocloud-amd64.img`)
   and rarely needs to be set explicitly.
4. An API token for the `bpg/proxmox` provider (configured in `cluster/main.tf`,
   not here — modules only declare `required_providers`).
5. **Host NAT/DNAT + SSH restriction** on the host (nftables) — see below. Not
   managed by this tofu (the host pre-exists and outlives any cluster), same
   status as "enable firewall".

## Host NAT/DNAT + perimeter firewall (manual, on the host)

One public IPv4, private nodes on `vmbr1` → the host is the perimeter. It must:
(a) MASQUERADE egress for the subnet, (b) DNAT public `:80/:443` to a worker
(**forward chain must accept it too — the #1 omission**), (c) allow SSH only from
`admin_ip`, drop the rest inbound. **Never DNAT / expose `:8006` (Proxmox UI) —
reach it via SSH tunnel or VPN.**

**Do NOT run `pve-firewall` and raw host `nftables` at once** — they both program
netfilter and collide (conntrack/INVALID handling, PVE's `PVEFW-` chains). On PVE
8.3+ forward/NAT rules only work under the new `proxmox-firewall` nftables backend
(still tech-preview, boot-load + chain-order bugs). For a single host doing one
job, the boring correct choice is **raw nftables, `pve-firewall` disabled**
(`systemctl disable --now pve-firewall`) — which is why this module ships no
per-VM firewall rules.

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf (host) — illustrative, NOT applied by tofu. Adapt IFs/IPs.
flush ruleset

define WAN_IF  = vmbr0            # OVH public bridge (verify vs the NIC)
define LAN_IF  = vmbr1            # internal VM bridge
define LAN_NET = 10.0.0.0/24
define WORKER  = 10.0.0.20        # worker_ingress_targets[0]
define ADMIN   = { 203.0.113.0/24 }   # admin_ip

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    ip protocol icmp accept
    iifname $LAN_IF accept                    # host <-> nodes
    ip saddr $ADMIN tcp dport 22 accept        # SSH admins only
    # 8006 intentionally NOT accepted — tunnel/VPN only.
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iifname $WAN_IF oifname $LAN_IF ip daddr $WORKER tcp dport { 80, 443 } accept
    iifname $LAN_IF oifname $WAN_IF accept      # VM egress
  }
}
table ip nat {
  chain prerouting  { type nat hook prerouting priority dstnat;
    iifname $WAN_IF tcp dport { 80, 443 } dnat ip to $WORKER
  }
  chain postrouting { type nat hook postrouting priority srcnat;
    oifname $WAN_IF ip saddr $LAN_NET masquerade
  }
}
```

```bash
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-forward.conf && sysctl --system
systemctl enable --now nftables   # ⚠ MANDATORY — nft does NOT autoload at boot
nft -f /etc/nftables.conf && nft list ruleset
```

⚠️ Footgun #1 on a remote box: forget `systemctl enable nftables` → rules vanish
on reboot. Keep a second SSH session + confirm OVH IPMI/rescue works before
applying anything here.

## Host hardening (Proxmox / Debian) — checklist

Applies per host. For a standalone host (single-host setup), **you CAN harden SSH
fully** — the common CIS "keep root SSH / keep forwarding" deviations are
*cluster-only* (PVE clusters need root SSH for replication); they do not bind you
on a standalone host. On multi-host PVE clusters, keep root SSH but restrict to
the inter-node network. Ordered by payoff:

1. **Break-glass first.** Confirm OVH IPMI/KVM + rescue-mode boot work *now* — the
   only recovery on a remote dedicated. Keep a 2nd SSH session open while applying.
2. **8006 off the WAN.** Highest-value control. Never DNAT it; reach via
   `ssh -L 8006:localhost:8006 root@host` or VPN.
3. **Repos + patching.** Swap enterprise → **no-subscription** repo (safe
   standalone), `apt full-upgrade`, `unattended-upgrades` (security only,
   `Automatic-Reboot false`), `intel-microcode`/`amd64-microcode`.
4. **Perimeter firewall.** Raw nftables above; `pve-firewall` disabled.
5. **SSH.** Key-only (`PasswordAuthentication no`), `PermitRootLogin
   prohibit-password` (or `no` once a personal admin `@pam` user works over SSH),
   ssh-audit-grade ciphers. Better still: SSH behind VPN so 22 isn't public at all
   (OVH admin IPs are often dynamic → allow-listing is brittle).
6. **Web UI auth.** Personal least-privilege `@pam` user (not blanket `PVEAdmin`);
   **TOTP 2FA** on every interactive user (`pveum realm modify pam --tfa
   type=oath`); leave break-glass `root` without TOTP but with a strong offline
   password.
7. **Fail2ban.** Community standard, not shipped configured: `[sshd]` + `[proxmox]`
   jail (port 8006, `backend=systemd`). Lower value once 8006 is off-WAN + SSH is
   key-only, but cheap.
8. In-cluster microseg stays with **Talos + Cilium ambient** (already in
   `OpenAether-apps`); the host firewall only guards the perimeter.

### Automation — Ansible, not tofu

**No OpenTofu provider hardens the Proxmox *host* OS.** `bpg/proxmox` manages VMs +
PVE firewall *objects* only — not apt repos, SSH, nftables, fail2ban, or
unattended-upgrades. Host hardening is **Ansible** (community standard). Named,
maintained roles:

- **`lae.proxmox`** — de-facto PVE base/repo setup.
- **`devsec.hardening`** (`os_hardening` + `ssh_hardening`) — the SSH/OS baseline.
  ⚠️ It hardens fully — fine here (standalone); would fight a PVE *cluster*.
- **`geerlingguy.security`** — lighter (fail2ban, SSH, unattended-upgrades).
- **`HomeSecExplorer/Proxmox-Hardening-Guide`** — best PVE-specific guide (CIS-Debian
  + Proxmox deltas), maps 1:1 to tasks (`pveum` 2FA, fail2ban jail, ssh-audit).

Suggested split: OpenTofu/`bpg` provisions the Talos VMs (this module); an Ansible
play (`lae.proxmox` → `devsec.hardening` → a small role templating the nftables +
fail2ban + `pveum` 2FA above) hardens the host. **No official CIS-Proxmox benchmark
exists** — only CIS *Debian* + unofficial community Proxmox benchmarks; don't claim
CIS-Proxmox compliance.

### Sources

- Proxmox firewall: https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html ·
  https://pve.proxmox.com/wiki/Firewall · OVH wiki: https://pve.proxmox.com/wiki/OVH
- OVH Proxmox NAT / networking:
  https://support.us.ovhcloud.com/hc/en-us/articles/360002394324-Connecting-a-VM-to-the-Internet-Using-Proxmox-VE
- PVE 8.3 nftables masquerade (forum):
  https://forum.proxmox.com/threads/proxmox-ve-8-3-masquerading-nat-with-nftables-not-iptables.159249/
- HomeSecExplorer PVE9 hardening guide:
  https://github.com/HomeSecExplorer/Proxmox-Hardening-Guide
- smallab k8s-pve host firewalling (nftables):
  https://github.com/ehlesp/smallab-k8s-pve-guide/blob/main/G014%20-%20Host%20hardening%2008%20~%20Firewalling.md
- Ansible: https://github.com/lae/ansible-role-proxmox ·
  https://github.com/dev-sec/ansible-collection-hardening

## Topology

Non-HA: `control_plane_count = 1`, `worker_count = 1`, `node_names = ["pve1"]` (CP
tainted `NoSchedule`; workloads land on the worker). HA: `control_plane_count = 3`,
`node_names = ["pve1","pve2","pve3"]` — VMs round-robin across hosts via
`element()`, 1 CP per physical machine = true HA (etcd quorum survives 1 host down).

## Consuming from `cluster/`

Add a `proxmox` provider block + a `module "proxmox"` in `cluster/main.tf`, a
`proxmox` key in `node_distribution`, and wire the outputs into the coalesce
junction — same pattern as `module "scw"`/`module "ovh"`. See the root
`cluster/main.tf` "Provider-Agnostic Junction Point".
