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
# kube-apiserver health for a load balancer (anonymous /readyz, /livez, /healthz)
# ==============================================================================

variable "apiserver_health_endpoints" {
  description = <<-EOT
    Let anonymous callers read exactly /readyz, /livez and /healthz on the kube-apiserver, so a
    load balancer can run an HTTPS /readyz check. Talos starts the apiserver with
    --anonymous-auth=false, which cannot sit next to an AuthenticationConfiguration `anonymous`
    stanza, so the patch removes it (extraArgs null: Talos >= 1.13) and mounts the file.
    Needs Kubernetes >= 1.32 (the field is absent on 1.30, alpha on 1.31) and Talos >= 1.13.
    The file is written only at BOOT: on a running node Talos 1.13 reboots to apply it (measured, Docker),
    Talos 1.14 applies the flags without a reboot and the apiserver starts against a missing file
    until the next boot (Talos source, not seen). Adopt one control plane at a time, on 1.13
    (#42). The version floors are the root's guard (cluster/versions-guard.tf): a nested validation
    cannot be tested from the root.
  EOT
  type        = bool
  default     = false
}

variable "apiserver_shutdown_delay" {
  description = <<-EOT
    kube-apiserver --shutdown-delay-duration, whole seconds under 30 (e.g. "20s"), null = flag not set.
    For that long a stopping apiserver reports /readyz 500 and keeps serving, which lets a load
    balancer drop it before it disappears. Measured on Talos 1.13.9 in Docker: a static pod restart
    (config apply) honours all 20 s, a node stop (reboot, upgrade) cuts it at about 10 s (the kubelet's
    critical-pod grace); the pod spec sets none, so the kubelet's 30 s is the ceiling.
  EOT
  type        = string
  default     = null
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
