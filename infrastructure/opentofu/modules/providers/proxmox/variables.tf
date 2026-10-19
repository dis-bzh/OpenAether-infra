# ==============================================================================
# Proxmox provider module — variables
#
# Bare-metal target (single host or multi-host Proxmox cluster). Unlike the cloud
# providers there is NO managed LB / NAT / floating-IP / security-group service.
# Consequences:
#   - The Kubernetes API is fronted by a Talos VIP (shared L2 address the CP owns),
#     not a cloud LB. `k8s_lb_ip` output = that VIP.
#   - Nodes get STATIC IPs on a Proxmox bridge; egress is whatever the host routes
#     (the SYS-1 host, not a NAT gateway resource).
#   - Firewalling is host nftables (perimeter) + Cilium (intra), not a cloud SG;
#     this module ships no per-VM Proxmox firewall (would force pve-firewall on).
# The Talos module and cluster/ root stay provider-agnostic (contract unchanged).
# ==============================================================================

variable "cluster_name" {
  description = "Name of the cluster (used for resource naming)"
  type        = string
}

# --- Proxmox connection / placement ------------------------------------------

variable "node_names" {
  description = "Proxmox node(s) to distribute VMs across (round-robin via element()). Single entry = all VMs on one host; 3 entries = HA (1 CP per physical host)."
  type        = list(string)
}

variable "datastore_id" {
  description = "Proxmox datastore for VM disks (ZFS mirror on SYS-1, e.g. 'local-zfs')."
  type        = string
  default     = "local-zfs"
}

variable "iso_datastore_id" {
  description = "Datastore holding the Talos image import / cloud-init snippets (e.g. 'local')."
  type        = string
  default     = "local"
}

# --- Talos image --------------------------------------------------------------

variable "talos_image_file_id" {
  description = <<-EOT
    Proxmox file ID of the Talos disk image to clone from, as
    '<datastore>:<content-type>/<filename>' (e.g.
    'local:iso/talos-1.12.0-nocloud-amd64.img'). Build/upload via
    ../../talos-image and Proxmox's image import. Required.
  EOT
  type        = string
}

# --- Node sizing --------------------------------------------------------------

variable "control_plane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 0
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 0
}

variable "cpu_cores" {
  description = "vCPU cores per cluster node"
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "RAM (MiB) per cluster node. 8192 min for workers (see DEV1-M OOM lesson)."
  type        = number
  default     = 8192
}

variable "root_disk_gb" {
  description = "System disk size (GiB) per node. 50 by default: the full application stack puts ~11 GB of images on each node (lab 12, measured on Scaleway) and a 20 GiB disk leaves ~15 GiB to Talos."
  type        = number
  default     = 50
}

# --- Networking (static, no cloud LB/NAT) ------------------------------------

variable "network_bridge" {
  description = "Proxmox bridge the node NICs attach to (e.g. 'vmbr0' or a dedicated 'vmbr1')."
  type        = string
  default     = "vmbr1"
}

variable "network_cidr" {
  description = "Private subnet CIDR for the cluster nodes (e.g. '10.0.0.0/24')."
  type        = string
  default     = "10.0.0.0/24"
}

variable "gateway_ip" {
  description = "Default gateway for the nodes (the host-side bridge IP providing egress)."
  type        = string
}

variable "control_plane_ip_offset" {
  description = "Host offset in network_cidr for the first control plane (cp-i = base + offset + i)."
  type        = number
  default     = 10
}

variable "worker_ip_offset" {
  description = "Host offset in network_cidr for the first worker (worker-i = base + offset + i)."
  type        = number
  default     = 20
}

variable "apiserver_vip" {
  description = <<-EOT
    Kubernetes API VIP — a spare address in network_cidr the Talos control plane
    owns (Talos machine.network.interfaces[].vip). Set from a single CP so a later move to
    3 CP does not re-address the apiserver. This module only surfaces it as
    `k8s_lb_ip`; `cluster/main.tf` passes it to `modules/talos`, which injects it
    into the machineconfig.
  EOT
  type        = string
}

variable "nameservers" {
  description = "DNS resolvers for the nodes"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

# --- Admin access (host-as-bastion by default) --------------------------------

variable "enable_bastion" {
  description = <<-EOT
    Provision a dedicated bastion VM. Default false: on a single OVH dedicated
    server the Proxmox HOST is already the jump box (you SSH it to admin Proxmox
    and it routes vmbr1 to the private nodes), so a bastion VM just burns a VM
    slot + ~1 GiB RAM. Set true only if you want an isolated jump VM instead of
    using the host. When false, supply host_public_ip / host_ssh_user so the
    contract's bastion_ip/bastion_user point at the host.
  EOT
  type        = bool
  default     = false
}

variable "host_public_ip" {
  description = <<-EOT
    Public IPv4 of the Proxmox host, used as the SSH jump target when
    enable_bastion = false (contract's bastion_ip). This is the same access you
    keep for Debian/Proxmox upgrades; SSH must be restricted to admin_ip on the
    host (see README). Ignored when enable_bastion = true.
  EOT
  type        = string
  default     = ""
}

variable "host_ssh_user" {
  description = "SSH user on the Proxmox host for the jump (contract's bastion_user). Ignored when enable_bastion = true."
  type        = string
  default     = "root"
}

variable "bastion_ip_offset" {
  description = "Host offset in network_cidr for the bastion VM (only when enable_bastion = true)."
  type        = number
  default     = 5
}

variable "bastion_public_ip" {
  description = <<-EOT
    Public IP reachable for SSH to the bastion VM (enable_bastion = true). On a
    single Proxmox host this is a host-mapped/failover IP, not a cloud floating
    IP. Empty = fall back to the bastion's private IP.
  EOT
  type        = string
  default     = ""
}

variable "bastion_image_file_id" {
  description = "Proxmox file ID of the bastion cloud image (Ubuntu cloud-init img)."
  type        = string
  default     = "local:iso/jammy-server-cloudimg-amd64.img"
}

variable "bastion_cpu_cores" {
  description = "vCPU cores for the bastion (minimal jump box)."
  type        = number
  default     = 1
}

variable "bastion_memory_mb" {
  description = "RAM (MiB) for the bastion."
  type        = number
  default     = 1024
}

# --- Security -----------------------------------------------------------------

variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH to bastion, K8s API)"
  type        = list(string)
}

variable "bastion_ssh_keys" {
  description = "SSH public keys for bastion access (list for multi-admin)"
  type        = list(string)
  default     = []
}

# SSH-CA — both "" (default) keeps the bastion on static-key auth only, byte
# for byte the same cloud-init as before these variables existed.
variable "bastion_ssh_ca_public_key" {
  description = "SSH CA public key trusted for certificate auth on the bastion (empty = SSH-CA off)"
  type        = string
  default     = ""
}

variable "bastion_ssh_ca_principals" {
  description = "Principals (one per line) authorized via AuthorizedPrincipalsFile for bastion_user (empty = SSH-CA off)"
  type        = string
  default     = ""
}

# Opt-in OS baseline of the bastion (see cluster/variables.tf). {} keeps the cloud-init byte for byte as before.
variable "bastion_baseline" {
  description = "Bastion hardening baseline: enabled, audit_logging, restrict_ssh_source, time_servers, revoked_keys. Default = nothing changes; enabled changes user_data (replaces the bastion on OVH and Outscale)."
  type = object({
    enabled             = optional(bool, false)
    audit_logging       = optional(bool, true)
    restrict_ssh_source = optional(bool, false)
    time_servers        = optional(list(string), [])
    revoked_keys        = optional(list(string), [])
  })
  default = {}
}

# Per-person bastion accounts (see cluster/variables.tf). {} adds no user: the cloud-init stays byte for byte as before.
variable "bastion_admins" {
  description = "Named operators, one unix account each in bastion-admins with its own authorized_keys file. Default {} = only the shared bastion account."
  type        = map(object({ ssh_keys = list(string) }))
  default     = {}
}

# Internet egress of the bastion (see cluster/variables.tf). "legacy" keeps the 80/443 rules and the wide private rule.
variable "bastion_internet_egress" {
  description = "mode legacy (default: nothing changes) or closed (no 80/443, TCP 6443/50000 to the cluster subnet only, no 8200); dns_servers and ntp_servers pin DNS and NTP to those addresses when closed."
  type = object({
    mode        = optional(string, "legacy")
    dns_servers = optional(list(string), [])
    ntp_servers = optional(list(string), [])
  })
  default = {}
}

# --- Worker storage (contract parity; consumed here to create data disks) -----

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one extra disk on
    EVERY worker (worker × disk matrix). `volumes` is consumed by modules/talos
    (UserVolumeConfig), not here. Empty = no extra disks.
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(any, [])
  })
  default = { disks = [], volumes = [] }
}
