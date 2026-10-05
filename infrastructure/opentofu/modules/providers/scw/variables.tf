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

variable "k8s_lb_health_https" {
  description = <<-EOT
    Health-check the Kubernetes API load balancer with HTTPS GET /readyz instead of a
    TCP connect. Requires the apiserver to answer /readyz anonymously
    (modules/talos apiserver_health_endpoints) on EVERY control plane first: with
    anything else the check reads 401 and the load balancer marks every backend down.
  EOT
  type        = bool
  default     = false
}
