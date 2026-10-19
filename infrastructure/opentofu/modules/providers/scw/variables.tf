variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "region" {
  description = "Scaleway region (e.g. fr-par)"
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Scaleway primary zone (e.g. fr-par-1)"
  type        = string
  default     = "fr-par-1"
}

variable "additional_zones" {
  description = "Zones for multi-AZ distribution of nodes"
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "project_id" {
  description = "Scaleway Project ID (null = provider default)"
  type        = string
  default     = null
}

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

variable "instance_type" {
  description = "Instance type for cluster nodes"
  type        = string
  default     = "DEV1-S"
}

variable "root_volume_type" {
  description = "Root volume type. 'sbs_volume' for block-storage instances (PRO2/POP2, recommended); 'l_ssd' for local-SSD instances (DEV1/GP1)."
  type        = string
  default     = "sbs_volume"
}

variable "root_volume_size_gb" {
  description = <<-EOT
    Size of the system volume of every node, in GB. Talos puts its EPHEMERAL partition (kubelet, containerd images, logs)
    on it, about 4 GB less than this value. 50 by default: the images of the full application stack (~11 GB per
    worker) do not fit in the ~15.6 GB left by 20 (lab 12: DiskPressure and evictions). Raising it is an in-place resize
    of an sbs_volume; Talos grows the partition on reboot.
  EOT
  type        = number
  default     = 50
  validation {
    condition     = var.root_volume_size_gb >= 20 && var.root_volume_size_gb <= 500
    error_message = "root_volume_size_gb must be between 20 and 500."
  }
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one SBS block
    volume attached to EVERY worker (worker × disk matrix). `volumes` is consumed
    by modules/talos (UserVolumeConfig), not here. Empty = no extra disks.
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(any, [])
  })
  default = { disks = [], volumes = [] }
}

variable "image_id" {
  description = "Talos image ID (zonal, overrides image_name)"
  type        = string
  default     = null
}

variable "image_name" {
  description = "Talos image name (looked up across zones)"
  type        = string
  default     = "talos"
}

# Security
variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH, K8s API)"
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

variable "bastion_image_id" {
  description = "Image ID for the bastion host"
  type        = string
  default     = "ubuntu_jammy"
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host (jump box; the default is a minimal, low-cost type)."
  type        = string
  default     = "DEV1-S"
}

variable "k8s_lb_mode" {
  description = <<-EOT
    How the Kubernetes API is fronted:
      "managed" (default) - a Scaleway LB (public IP, ACL-restricted).
      "vip"     - EXPERIMENTAL. No LB: reserves a private IPAM address instead,
                  and relies on modules/talos's Layer2 VIP (ARP-announced by
                  whichever control plane holds it) on the private network.
                  The API is then private-only, reachable via the bastion SSH
                  tunnel — no public IP for 6443. Scaleway's private network
                  anti-spoofing behavior with a floating ARP-announced address
                  is undocumented; validate before relying on this in prod.
  EOT
  type        = string
  default     = "managed"
  validation {
    condition     = contains(["managed", "vip"], var.k8s_lb_mode)
    error_message = "k8s_lb_mode must be \"managed\" or \"vip\"."
  }
}

variable "deploy_app_lb" {
  description = <<-EOT
    Create the public HTTP/HTTPS load balancer fronting the application Gateway.
    FALSE by default: its backends are pinned to the Gateway's fixed NodePorts,
    so on an infrastructure-only cluster it is created, billed, and forwards to
    ports where nothing listens. The Kubernetes API LB is a separate resource
    (k8s_lb_mode) and is NOT governed by this.
  EOT
  type        = bool
  default     = false
}

# ==============================================================================
# Gateway NodePorts — CROSS-REPOSITORY CONTRACT
#
# The public application LB is created in PHASE 1, before the cluster exists:
# it therefore cannot discover a nodePort dynamically allocated by Kubernetes
# (random 30000-32767 range). The ports are therefore FIXED on both sides.
#
# ⚠️ These values MUST match
# OpenAether-apps/apps/base/services-gateway/service-nodeport.yaml.
# A mismatch = a public LB pointing at nothing, with no error anywhere — which
# is exactly the original outage (the LB targeted worker:80/443 while the Istio
# Gateway was not listening there).
# ==============================================================================
variable "app_lb_node_ports" {
  description = "The Gateway's fixed NodePorts, targets of the public application LB. Must match the openaether-gateway-nodeport Service on the apps side."
  type = object({
    http  = number
    https = number
  })
  default = {
    http  = 30080
    https = 30443
  }
}

variable "app_lb_allowed_cidrs" {
  description = "Source CIDRs allowed to reach the application LB (80/443). Empty = no filter (the historical behaviour). Non-empty = only these, plus the cluster's own egress address; see the root variable of the same name."
  type        = list(string)
  default     = []
}
