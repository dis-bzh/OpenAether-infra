variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint URL (https://<lb_ip>:6443)"
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version (e.g. v1.12.0)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (e.g. v1.34.1)"
  type        = string
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

variable "control_plane_ips" {
  description = "Node identity IPs of control plane nodes (used as the Talos `node` and in certSANs/etcd). Cloud: private IPs. Local Docker: container IPs (e.g. 10.5.0.10)."
  type        = list(string)
}

variable "worker_ips" {
  description = "Node identity IPs of worker nodes"
  type        = list(string)
}

variable "control_plane_endpoints" {
  description = <<-EOT
    Addresses (host or host:port) the Talos provider connects to for each control
    plane node. Defaults to control_plane_ips when empty (cloud: nodes reachable
    directly via VPC/tunnel). For local Docker, set to port-mapped addresses
    (e.g. ["127.0.0.1:50000", "127.0.0.1:50001"]) since container IPs aren't
    routable from the host.
  EOT
  type        = list(string)
  default     = []
}

variable "worker_endpoints" {
  description = "Addresses the Talos provider connects to for each worker. Defaults to worker_ips when empty."
  type        = list(string)
  default     = []
}

variable "health_check_timeout" {
  description = "Max time to wait for the cluster to report healthy after bootstrap (Cilium/CoreDNS image pulls on a fresh multi-CP cluster can take several minutes)."
  type        = string
  default     = "15m"
}

variable "skip_health_check" {
  description = <<-EOT
    Skip the talos_cluster_health data source entirely. The Talos provider's
    health data source has connectivity assumptions that don't hold behind
    WSL2/Docker port mappings (it can stall). For local testing set this true
    and verify health out-of-band via `talosctl health`; keep false for cloud.
  EOT
  type        = bool
  default     = false
}

variable "skip_kubernetes_health_checks" {
  description = <<-EOT
    Skip the Kubernetes-level checks in the Talos health data source (etcd/Talos
    checks still run). Set true for local Docker where the K8s API at the cluster
    endpoint isn't reachable from the host (it's verified separately via kubectl
    over the port-mapped endpoint). Keep false for cloud.
  EOT
  type        = bool
  default     = false
}

variable "skip_port_ready_wait" {
  description = <<-EOT
    Skip terraform_data.talos_port_ready_* (the local-exec that waits for
    50000/TCP before starting the config-apply retry clock). This provisioner
    is a plain OS-level TCP connect — unlike every talos_* resource/data
    source, it is NOT part of the "talos" provider, so mock_provider "talos"
    in tofu test does not fake it: it runs for real and, with mocked
    endpoints, would loop until a real host answers, i.e. never. Set true
    for `tofu test`/`command = apply` runs; keep false for real deploys
    (config_delivery = "apply"), where the wait is what makes cloud
    bootstrap deterministic (see the comment above
    talos_port_ready_cp/worker).
  EOT
  type        = bool
  default     = false
}

variable "secrets_prevent_destroy" {
  description = <<-EOT
    Protect talos_machine_secrets (the cluster's root-of-trust PKI) from
    destruction. Lifecycle arguments cannot be driven by a variable, so this
    toggles between two resource blocks (see locals.machine_secrets in
    main.tf) rather than a conditional lifecycle block. Keep true for real
    deploys. Set false only for `tofu test`, whose automatic post-run cleanup
    destroys everything an apply-mode run block created — with
    prevent_destroy = true that cleanup errors out.
  EOT
  type        = bool
  default     = true
}

variable "config_delivery" {
  description = <<-EOT
    How machine configuration reaches nodes:
      'apply'    - gRPC maintenance-mode apply via talos_machine_configuration_apply
                   (cloud VMs boot in maintenance, then config is applied).
      'userdata' - config is injected at container/VM creation (USERDATA env var).
                   Required for Docker/container platforms — maintenance-mode apply
                   reboot-loops in containers (see Talos Docker platform docs).
                   The provider module reads the *_machine_configs outputs and
                   injects them; this module skips the apply resources.
  EOT
  type        = string
  default     = "apply"
  validation {
    condition     = contains(["apply", "userdata"], var.config_delivery)
    error_message = "config_delivery must be 'apply' or 'userdata'."
  }
}

variable "k8s_lb_ip" {
  description = "IP of the Kubernetes API load balancer (for certSANs)"
  type        = string
}

# ==============================================================================
# Control Plane apiserver VIP (Talos Layer2 VIP)
# ==============================================================================

variable "apiserver_vip" {
  description = <<-EOT
    Optional Talos Layer2 VIP for the kube-apiserver, held by the control plane
    interface (moves to another CP on failure). Null (default) = no VIP — the
    provider's own LB/endpoint is the sole apiserver front door.
    When set, it is injected as machine.network.interfaces[].vip and added to
    cluster.apiServer.certSANs (alongside 127.0.0.1, for kubectl over a
    localhost SSH tunnel). Ignored in container_mode (no shared L2 to hold a
    VIP on).
  EOT
  type        = string
  default     = null
}

variable "apiserver_vip_interface" {
  description = "Network interface name the VIP binds to (ignored if apiserver_vip_device_selector is set)."
  type        = string
  default     = "eth0"
}

variable "apiserver_vip_device_selector" {
  description = "Talos deviceSelector for the VIP interface (busPath/hardwareAddr/physical), takes precedence over apiserver_vip_interface when set."
  type = object({
    busPath      = optional(string)
    hardwareAddr = optional(string)
    physical     = optional(bool)
  })
  default = null
}

# ==============================================================================
# Bootstrap Manifests (injected via Talos inlineManifests)
# ==============================================================================

variable "bootstrap_manifests_enabled" {
  description = "Whether to inject bootstrap manifests (Cilium, Flux) via inlineManifests. Set to true for initial bootstrap, false for upgrades/DRP where Flux is already running."
  type        = bool
  default     = true
}

variable "cilium_manifest" {
  description = "Cilium CNI manifest YAML content (from bootstrap-manifests/cilium.yaml). Always injected when bootstrap_manifests_enabled=true (CNI is required for networking)."
  type        = string
}

variable "flux_manifest" {
  description = "Flux install manifest YAML content (from bootstrap-manifests/flux-install.yaml)"
  type        = string
  default     = ""
}

variable "flux_bootstrap_manifest" {
  description = "Flux bootstrap manifest YAML content (GitRepository + Kustomization, rendered from template)"
  type        = string
  default     = ""
}

variable "container_mode" {
  description = <<-EOT
    Run Talos in container mode (Docker/local testing).
    When true, the machine.install block is omitted from the config patch —
    Talos skips disk installation and runs entirely in memory.
    Required for Docker-based local testing where no block device exists.
  EOT
  type        = bool
  default     = false
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data storage for worker nodes, materialized as encrypted Talos
    UserVolumeConfig documents (LUKS2, mounted at /var/mnt/<name>).
    `volumes = []` (default) → no user volumes (e.g. local Docker: container_mode
    also forces this off). The `disks` field is consumed by the provider modules
    (block volumes to create+attach); this module only reads `volumes`.
    Each `volume` targets a disk via `disk_match` (CEL diskSelector). Multiple
    volumes of volumeType=partition can coexist on a single shared data disk.
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(list(object({
      name       = string
      disk_match = string
      min_size   = optional(string)
      max_size   = optional(string)
      grow       = optional(bool, false)
    })), [])
  })
  default = { disks = [], volumes = [] }
}

variable "installer_schematic_id" {
  description = <<-EOT
    Image Factory schematic ID, so the machine config installs from
    factory.talos.dev/installer/<id>:<version> and keeps the schematic's system
    extensions across every reinstall and `talosctl upgrade`. Empty falls back to
    the plain ghcr.io installer, which carries NO extensions — see the comment on
    local.installer_image for what that costs.
  EOT
  type        = string
  default     = ""
}

variable "node_nameservers" {
  description = <<-EOT
    Resolvers for the nodes' own DNS (image pulls, NTP), rendered as one Talos
    ResolverConfig appended to every node's config. Empty (default) keeps the
    platform's resolver and the rendered config byte-identical. Per entry:
    `address` (an IP), `protocol` (Do53, DoT or DoH; DoT/DoH need Talos 1.14)
    and `tls_server_name` (SNI and certificate name: required for DoT/DoH, empty
    for Do53). Listed servers replace what the platform's DHCP hands out, and
    their order is a priority. The list is all encrypted or all plain: a plain
    entry beside an encrypted one is a silent plaintext fallback when that one
    refuses or fails TLS. DoT needs egress to tcp/853, DoH to tcp/443.
    Schema: https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/resolverconfig
  EOT
  type = list(object({
    address         = string
    protocol        = optional(string, "DoT")
    tls_server_name = optional(string, "")
  }))
  default = []

  validation {
    # "/32" parses for an IPv6 address too: only whether it is an address matters here.
    condition     = alltrue([for n in var.node_nameservers : can(cidrhost("${n.address}/32", 0))])
    error_message = "node_nameservers[].address must be an IPv4 or IPv6 address, not a hostname: Talos dials it directly."
  }
  validation {
    condition     = alltrue([for n in var.node_nameservers : contains(["Do53", "DoT", "DoH"], n.protocol)])
    error_message = "node_nameservers[].protocol must be Do53, DoT or DoH."
  }
  validation {
    condition     = alltrue([for n in var.node_nameservers : (n.protocol == "Do53") == (n.tls_server_name == "")])
    error_message = "node_nameservers[].tls_server_name is required for DoT/DoH and must be empty for Do53."
  }
  validation {
    condition     = length(distinct([for n in var.node_nameservers : n.protocol == "Do53"])) <= 1
    error_message = "node_nameservers must be all encrypted (DoT/DoH) or all Do53: a plain entry beside an encrypted one is a silent plaintext fallback when the encrypted one refuses or fails TLS."
  }
  validation {
    condition     = alltrue([for n in var.node_nameservers : n.protocol == "Do53" || can(regex("^v(1\\.(1[4-9]|[2-9][0-9])|[2-9])\\.", var.talos_version))])
    error_message = "DoT and DoH in node_nameservers need Talos 1.14 or later: an older node refuses the document (unknown keys)."
  }
}

variable "node_dns_boot_timeout" {
  description = <<-EOT
    With an encrypted entry in node_nameservers: how long a booting node waits for
    time sync, as a TimeSyncConfig bootTimeout. NTP names resolve through those
    servers and Talos waits forever by default, so an unreachable server leaves
    etcd, kubelet and trustd waiting: loud, and one applied working config fixes
    it. The bound trades that stall for a node that starts after this delay with
    time unverified and name resolution still dead, which `get timestatus` can
    then read as synced. Empty keeps Talos's wait. Unused without an encrypted entry.
  EOT
  type        = string
  default     = "90s"

  validation {
    condition     = var.node_dns_boot_timeout == "" || can(regex("^[1-9][0-9]*(s|m|h)$", var.node_dns_boot_timeout))
    error_message = "node_dns_boot_timeout must be empty or a positive whole number of seconds, minutes or hours: 90s, 2m."
  }
}
