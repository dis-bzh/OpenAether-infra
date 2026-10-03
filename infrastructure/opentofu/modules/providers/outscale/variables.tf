variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "instance_type" {
  description = "VM type for cluster nodes"
  type        = string
  default     = "tinav5.c2r4p1"
}

variable "image_id" {
  description = "OMI ID for Talos Linux. Null (default) looks it up by image_name instead — the name the talos-image root publishes under."
  type        = string
  default     = null
}

variable "image_name" {
  description = "OMI name to look up when image_id is null."
  type        = string
  default     = "talos"
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one BSU volume
    attached to EVERY worker (worker × disk matrix). `volumes` is consumed by
    modules/talos (UserVolumeConfig), not here. Empty = no extra disks.
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(any, [])
  })
  default = { disks = [], volumes = [] }
}

variable "availability_zones" {
  # One private and one public subnet per entry (#58): control planes and workers are spread over
  # the private ones by index (node i goes to zone i modulo the list), a worker's data volumes
  # live in its zone, and the load balancers span every public subnet. The bastion and the NAT
  # service stay in the first zone: losing it costs admin access and node egress, not the API.
  # A node's zone is fixed when it is created (lifecycle ignore_changes), so a cluster built
  # before this layout keeps where its nodes are.
  description = "Subregions, one subnet pair per entry; nodes are spread over them by index"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]

  validation {
    condition     = length(var.availability_zones) >= 1 && length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must list at least one subregion, each once."
  }
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

# Only referenced by its own validation block (rejects "vip"). Exists so
# cluster/main.tf can pass k8s_lb_mode uniformly to all three cloud provider
# modules; Outscale simply never acts on it beyond validating it.
variable "k8s_lb_mode" { # tflint-ignore: terraform_unused_declarations
  description = "How the Kubernetes API is fronted. Outscale only supports \"managed\" (a load balancer) — see validation."
  type        = string
  default     = "managed"
  validation {
    # Outscale Net is an L3 SDN (like AWS VPC): no ARP/broadcast domain and NIC
    # anti-spoofing on by default, so a Talos Layer2 VIP has nothing to float
    # on. The k8s LB also sits on the public subnet and returns a DNS name, not
    # an IP, which a Talos VIP can't be either. Unlike Scaleway/OVH (both L2
    # private networks), there's no vip mode here — managed LB only.
    condition     = var.k8s_lb_mode == "managed"
    error_message = "Outscale only supports k8s_lb_mode = \"managed\" — its Net is an L3 SDN with no ARP/broadcast domain for a Talos Layer2 VIP to float on, and the k8s LB is DNS-based on the public subnet, not a floatable IP."
  }
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
  default     = null
}

variable "bastion_vm_type" {
  description = "VM type for the bastion host (jump box; the default is the minimum recommended)."
  type        = string
  default     = "tinav5.c2r2p2"
}

# The Kubernetes API LB is deliberately NOT governed by this toggle: an
# apiserver has to stay reachable whether or not the cluster serves an app.
variable "deploy_app_lb" {
  description = "Create the public HTTP/HTTPS LB fronting the application Gateway. False on an infrastructure-only cluster: its backends are pinned to the Gateway's fixed NodePorts, so it would be created and billed while pointing at ports where nothing listens."
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
