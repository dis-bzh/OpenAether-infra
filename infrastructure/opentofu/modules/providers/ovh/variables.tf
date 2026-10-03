variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "region" {
  description = "OVH/OpenStack region"
  type        = string
  default     = "EU-WEST-PAR"
}

variable "flavor_name" {
  description = "OpenStack flavor for cluster nodes"
  type        = string
  default     = "b3-8"
}

variable "image_id" {
  description = "OpenStack (Glance) image UUID for Talos Linux. Null (default) looks it up by image_name instead — the name the talos-image root publishes under."
  type        = string
  default     = null
}

variable "image_name" {
  description = "Glance image name to look up when image_id is null (most recent match)."
  type        = string
  default     = "talos"
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one Cinder block
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

variable "worker_data_volume_type" {
  description = <<-EOT
    Cinder volume type for the worker data disks. MUST NOT be a multiattach type:
    OVH's project-default type is `classic-multiattach` (extra_specs
    multiattach="<is> True"), and Nova then rejects the attachment with
    "Multiattach volumes are only supported starting with compute API version
    2.60" — the provider only negotiates that microversion when multiattach is
    explicitly requested. Observed on a real EU-WEST-PAR apply (2026-07-25).
    Available types: high-speed, high-speed-gen2, *-luks variants (Longhorn
    already does its own LUKS with an OpenBao-held key, so plain is enough).
    ⚠️ `high-speed-gen2` produced volumes stuck in `error status` on a 50 GiB
    disk in EU-WEST-PAR (2026-07-25) — it has size/region constraints;
    `high-speed` works. Check the type before changing it.
  EOT
  type        = string
  default     = "high-speed-gen2"
}

variable "network_name" {
  description = "Network name for instances (usually Ext-Net for public)"
  type        = string
  default     = "Ext-Net"
}

variable "availability_zones" {
  description = "Availability zones for node distribution; each must exist in the region (EU-WEST-PAR: eu-west-par-a/b/c, not \"nova\", which Cinder rejects)"
  type        = list(string)
  default     = ["eu-west-par-a", "eu-west-par-b", "eu-west-par-c"]
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

variable "bastion_image_id" {
  description = "Image ID or name for the bastion host"
  type        = string
  default     = "Ubuntu 22.04"
}

variable "bastion_flavor_name" {
  description = "OpenStack flavor for the bastion host (jump box; the default is the minimum recommended)."
  type        = string
  default     = "b3-8"
}

variable "k8s_lb_mode" {
  description = <<-EOT
    How the Kubernetes API is fronted:
      "managed" (default) - an Octavia LB + floating IP (public, ACL-restricted).
      "vip"     - no LB: reserves a private port on the subnet instead, and
                  relies on modules/talos's Layer2 VIP on the private network.
                  Control plane ports get an allowed_address_pairs entry for the
                  VIP so Neutron's anti-spoofing filter doesn't drop it. The API
                  is then private-only, reachable via the bastion SSH tunnel.
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
    Create the public HTTP/HTTPS Octavia LB (+ its floating IP) that fronts the
    application Gateway. FALSE by default: its members are pinned to the
    Gateway's fixed NodePorts (see app_lb_node_ports), so on an
    infrastructure-only cluster it is an Octavia LB and a floating IP that are
    created, BILLED, and forward to ports where nothing listens.

    Does NOT govern the Kubernetes API LB (k8s_lb_mode): the apiserver must stay
    reachable whether or not the cluster runs any application.
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
