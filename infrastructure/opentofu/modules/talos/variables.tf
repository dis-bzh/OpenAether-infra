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

variable "coredns_ha" {
  description = <<-EOT
    Ship OpenAether's own CoreDNS (min(3, number of nodes) replicas on different nodes, a PodDisruptionBudget, a 30 s
    not-ready/unreachable toleration) as an inline manifest and set cluster.coreDNS.disabled = true, instead of the
    2-replica Deployment that Talos owns (infra #388: lab 21 had 4 min 46 s without DNS when both replicas shared a
    worker). False keeps the Talos one. The ClusterIP is 10.96.0.10 (Talos's default service range 10.96.0.0/12).
    Enabling it on a running cluster replaces the Deployment in place at the next apply (docs/resilience.md, Talos upgrades).
  EOT
  type        = bool
  default     = true
}

variable "coredns_image_tag" {
  description = "CoreDNS image tag of the shipped manifest (registry.k8s.io/coredns/coredns). Talos no longer upgrades it when coredns_ha is on: bump it here."
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/coredns/coredns
  default = "v1.12.4"
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
    for Do53). Listed servers replace what a DHCP-supplied resolver hands out
    (measured on a QEMU Talos 1.14.2 node, not on a cloud: what a platform's own
    layer does, e.g. Proxmox's cloud-init `nameservers`, is open), and their order
    is a priority. The list is all encrypted or all plain: a plain entry beside an
    encrypted one is a silent plaintext fallback when that one refuses or fails
    TLS, and no rescue for a black-holed one (`talosctl validate` suggests such a
    fallback; this refuses it on purpose). DoT needs egress to tcp/853, DoH to
    tcp/443 (measured open from a pod on OVH and Scaleway, 2026-10-05). A change is applied to every node in one
    apply, without a reboot. A list no node can reach shows only at the NEXT reboot: such a node never starts its
    Talos API (it cannot sign its API CSR), the `node_dns_boot_timeout` bound does not rescue it, and only replacing
    the node recovers it (OVH console log). Check `nc -zvw5 <ip> 853` from a pod before you apply the list. To check a node
    resolves through it: `talosctl get resolvers`, `get timestatus`, `logs
    dns-resolve-cache` (`get dnsupstream` reads healthy for a dead server).
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
    # cidrhost accepts an octet with a leading zero; Talos refuses it, and only at apply.
    condition     = !anytrue([for n in var.node_nameservers : can(regex("(^|\\.)0[0-9]+(\\.|$)", n.address))])
    error_message = "node_nameservers[].address: an IPv4 octet has no leading zero (9.9.9.9, not 09.9.9.9): Talos refuses it."
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
    condition     = alltrue([for n in var.node_nameservers : n.tls_server_name == "" || can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", n.tls_server_name))])
    error_message = "node_nameservers[].tls_server_name must be a bare hostname (dns.quad9.net), not a URL or host:port: a wrong name gives a resolver that never answers."
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
    then read as synced (measured on a QEMU node, black hole simulated). Empty keeps
    Talos's wait. Unused without an encrypted entry.
  EOT
  type        = string
  default     = "90s"

  validation {
    condition     = var.node_dns_boot_timeout == "" || can(regex("^[1-9][0-9]*(s|m|h)$", var.node_dns_boot_timeout))
    error_message = "node_dns_boot_timeout must be empty or a positive whole number of seconds, minutes or hours: 90s, 2m."
  }
}

variable "talos_api_access_namespaces" {
  description = <<-EOT
    Kubernetes namespaces whose pods may be granted the Talos role `os:etcd:backup` through a talos.dev ServiceAccount object
    (machine.features.kubernetesTalosAPIAccess, control planes only). The role takes an etcd snapshot and nothing else; the
    apps repository's etcd-snapshot CronJob (foundation-databases) is its only user. Empty (module default) renders nothing and
    leaves every config byte-identical; the cluster variable etcd_snapshot_api_access sets it. One apply re-applies the
    control planes' machine configuration.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.talos_api_access_namespaces : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", n))])
    error_message = "talos_api_access_namespaces must be Kubernetes namespace names."
  }
}

variable "node_log_forwarding" {
  description = <<-EOT
    Ships the nodes' Talos service logs (machine.logging, json_lines) and, unless
    `kernel = false`, the kernel log (KmsgLogConfig) to a receiver, so that node events
    outlive the node (ANSSI PA-012 R9, batch B22). Null (default) renders nothing and
    leaves every node's config byte-identical.
      endpoint        tcp://host:port. TCP only (a UDP log is lost silently). PLAINTEXT:
                      acceptable only on the private network, and the logs hold node
                      and service events, not secrets. The host network sends it, not a
                      pod: a ClusterIP does NOT work from the host under Cilium
                      (socketLB.hostNamespaceOnly), so use a receiver on every node
                      (hostNetwork, tcp://127.0.0.1:<port>) or a fixed LB address.
      kernel          Also send the kernel log (default true).
      kernel_endpoint Another receiver for the kernel log (default: endpoint).
    An unreachable receiver drops logs; whether it also delays a boot is a lab check
    (LAB-CHECKLIST B22). The setting is global (there is no per-node switch): one apply re-applies the machine configuration of EVERY node, so try it on a throwaway cluster first. The receiver is not part of this repo's
    default: a hostNetwork collector must exist before this is switched on.
  EOT
  type = object({
    endpoint        = string
    kernel          = optional(bool, true)
    kernel_endpoint = optional(string, "")
  })
  default = null

  validation {
    condition     = var.node_log_forwarding == null || can(regex("^tcp://[A-Za-z0-9.-]+:[0-9]{1,5}/?$|^tcp://\\[[0-9A-Fa-f:]+\\]:[0-9]{1,5}/?$", var.node_log_forwarding.endpoint))
    error_message = "node_log_forwarding.endpoint must be tcp://host:port (TCP only, no path, no udp://)."
  }
  validation {
    condition     = var.node_log_forwarding == null || var.node_log_forwarding.kernel_endpoint == "" || can(regex("^tcp://[A-Za-z0-9.-]+:[0-9]{1,5}/?$|^tcp://\\[[0-9A-Fa-f:]+\\]:[0-9]{1,5}/?$", var.node_log_forwarding.kernel_endpoint))
    error_message = "node_log_forwarding.kernel_endpoint must be empty or tcp://host:port."
  }
  validation {
    condition     = var.node_log_forwarding == null || var.node_log_forwarding.kernel || var.node_log_forwarding.kernel_endpoint == ""
    error_message = "node_log_forwarding.kernel_endpoint is set while kernel = false: it would be ignored."
  }
}

variable "node_time_servers" {
  description = <<-EOT
    NTP sources of the Talos nodes, rendered as `ntp.servers` of the TimeSyncConfig document
    (ANSSI PA-012 R5 / HYG-42 M36, batch B23). Empty (default) renders no source: Talos keeps its
    built-in single default server, byte for byte as before. Give several independent hosts. Plain NTP
    over udp/123 only (Talos has no NTS); names resolve through node_nameservers, so with an encrypted
    resolver list prefer address literals or check `talosctl get timestatus` after the apply. The same
    list belongs in bastion_baseline.time_servers so that nodes and bastion agree. A change is applied
    to every node without a reboot; a list no node can reach leaves the clock unsynchronised
    (`talosctl get timestatus`), so try it on a throwaway cluster first (LAB-CHECKLIST B23).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.node_time_servers : can(regex("^[A-Za-z0-9.:-]+$", t))])
    error_message = "node_time_servers: host names or addresses only (no scheme, no port, no spaces)."
  }
  validation {
    condition     = length(var.node_time_servers) == length(distinct(var.node_time_servers))
    error_message = "node_time_servers: duplicate entries."
  }
}

variable "node_zones" {
  description = <<-EOT
    Failure domain of each node, as the provider placed it (the root passes control_plane_zones and worker_zones). When
    set, every node carries the label topology.kubernetes.io/zone (machine.nodeLabels), which the zone-loss alert, the
    kube-state-metrics allowlist and `task failure-domain-check` read. Null, or an entry that is empty, labels nothing.
    The lists are in the order of control_plane_ips and worker_ips.
  EOT
  type = object({
    control_plane = optional(list(string), [])
    worker        = optional(list(string), [])
  })
  default = null
}

variable "node_monitor_grace_period_seconds" {
  description = <<-EOT
    How long, in seconds, the kube-controller-manager waits without a heartbeat from a node before it marks the node NotReady
    (its --node-monitor-grace-period; Kubernetes default 50). 0 (this module's default) sets nothing: the configs stay
    byte-identical and the Kubernetes defaults apply. The SHIPPED default, 30, is the root variable's (cluster/variables.tf,
    owner decision 2026-10-26): this module is plumbing and keeps 0 so that a caller that does not pass the value gets the
    Kubernetes behaviour. This is the longest part of a node-loss failover that our configuration can shorten (lab 26, D2:
    32-35 s of a 76-79 s database write gap, and the 15-17 s HTTP failure runs when the lost node held a Gateway pod).
    Below 40 the kubelet is told too, so that the node still has 4 chances to be heard: nodeLeaseDurationSeconds = this value
    (the Lease is renewed every quarter of it) and nodeStatusUpdateFrequency = this value / 4, rounded down. Between 20 and 300.
    Kubernetes asks that the grace period be N times the kubelet's status frequency and ALSO more than the HTTP/2 ping and read-idle
    timeouts of its clients (30 s + 15 s by default, client-go), which no Talos setting changes: a shorter value can mark a node
    NotReady while only its connection to the API is dead. The root default 30 rests on ONE provider's lab (Scaleway, lab 27; OVH and Outscale
    unverified, docs/resilience.md, "Failure detection time"). Changing it re-applies every node's machine config (the kubelet restarts).
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.node_monitor_grace_period_seconds == 0 || (var.node_monitor_grace_period_seconds >= 20 && var.node_monitor_grace_period_seconds <= 300 && var.node_monitor_grace_period_seconds == floor(var.node_monitor_grace_period_seconds))
    error_message = "node_monitor_grace_period_seconds must be 0 (Kubernetes default, 50 s) or a whole number of seconds between 20 and 300: below 20 the node has fewer than 4 heartbeats of 5 s to be heard in."
  }
}

variable "node_baseline" {
  description = <<-EOT
    Opt-in kernel and kubelet baseline of the Talos nodes (ANSSI BP-028 R9/R12/R13, batch B23). Null
    (default) renders nothing and leaves every node's config byte-identical.
      sysctls                 Set machine.sysctls on every node: kernel.sysrq=0, perf sampling limits,
                              no ICMP redirects / source routing (IPv4 and IPv6), tcp_syncookies=1,
                              tcp_rfc1337=1. rp_filter, ip_forward and the module/pid settings are NOT
                              touched (Cilium and Kubernetes need them: docs/hardening.md deviation table).
      sysctls_extra           More or overriding sysctls (strings), merged last. Operator responsibility.
      panic_on_oops           Also set kernel.panic_on_oops=1. Off even with `sysctls`: with the kernel's
                              panic timeout at 0 a panic HANGS the node instead of rebooting it. Check
                              `talosctl read /proc/sys/kernel/panic` first (LAB-CHECKLIST B23).
      worker_default_seccomp  Set kubelet defaultRuntimeSeccompProfileEnabled on the workers, as the
                              control planes already have it: pods without a seccompProfile get RuntimeDefault
                              when they next start. A workload that needs a blocked syscall breaks then.
      pod_pids_limit          kubelet podPidsLimit on every node (0 = unset, Kubernetes default: unlimited).
                              A pod over the limit cannot fork; size above your largest legitimate pod.
      kubelet_server_tls      kubelet serverTLSBootstrap: serving certificates come from the cluster CA
                              through CSRs. Needs a kubelet-serving CSR approver (OpenAether-apps does not
                              ship one yet): until the CSRs are approved the kubelet keeps a self-signed
                              certificate. Do not enable without that approver.
    Kubelet settings are written into machine.kubelet.extraConfig; the kubelet restarts on apply.
  EOT
  type = object({
    sysctls                = optional(bool, false)
    sysctls_extra          = optional(map(string), {})
    panic_on_oops          = optional(bool, false)
    worker_default_seccomp = optional(bool, false)
    pod_pids_limit         = optional(number, 0)
    kubelet_server_tls     = optional(bool, false)
  })
  default = null

  validation {
    condition     = var.node_baseline == null || (var.node_baseline.pod_pids_limit == 0 || (var.node_baseline.pod_pids_limit >= 64 && var.node_baseline.pod_pids_limit == floor(var.node_baseline.pod_pids_limit)))
    error_message = "node_baseline.pod_pids_limit must be 0 (unset) or a whole number of at least 64."
  }
  validation {
    condition     = var.node_baseline == null || alltrue([for k, v in var.node_baseline.sysctls_extra : can(regex("^[a-z0-9_]+(\\.[A-Za-z0-9_-]+)+$", k))])
    error_message = "node_baseline.sysctls_extra keys must be dotted sysctl names such as net.ipv4.tcp_syncookies."
  }
  validation {
    condition     = var.node_baseline == null || var.node_baseline.sysctls || !var.node_baseline.panic_on_oops
    error_message = "node_baseline.panic_on_oops only applies with sysctls = true; use sysctls_extra for a lone key."
  }
}

# ==============================================================================
# Node ingress firewall (batch B24, stage 2). Off: nothing is rendered.
# ==============================================================================

variable "node_firewall_mode" {
  description = <<-EOT
    "off" (default): no firewall document, every node config byte-identical. "port_allowlist": one
    NetworkRuleConfig per flow of node_firewall_ports plus NetworkDefaultActionConfig ingress: accept.
    A NetworkRuleConfig is an allow-list for its port even with that default action: each listed port
    ACCEPTS ONLY THE LISTED SOURCES and DROPS the others (live nft chain, lab 11); ports that are not
    listed stay open. A source that is missing from node_firewall (a new subnet, a load balancer or
    health-check range, a wrong pod range) is cut off: the cluster breaks. Not inert, not a monitor.
    No mode with a blocking default action exists. LAB-CHECKLIST B24. A change is applied without a reboot.
  EOT
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "port_allowlist"], var.node_firewall_mode)
    error_message = "node_firewall_mode must be \"off\" or \"port_allowlist\" (no mode with a blocking default action exists)."
  }
}

variable "node_firewall" {
  description = "Source ranges of the rules (node_cidrs required when the mode is not off; bastion_cidrs, pod_cidrs, lb_cidrs). Subnets only, never node addresses."
  type = object({
    node_cidrs    = optional(list(string), [])
    bastion_cidrs = optional(list(string), [])
    pod_cidrs     = optional(list(string), ["10.244.0.0/16"])
    lb_cidrs      = optional(list(string), ["100.64.0.0/10"])
  })
  default = {}

  validation {
    condition = alltrue([for c in concat(var.node_firewall.node_cidrs, var.node_firewall.bastion_cidrs, var.node_firewall.pod_cidrs, var.node_firewall.lb_cidrs) :
    can(cidrhost(c, 0)) && !contains(["0.0.0.0/0", "::/0"], c)])
    error_message = "node_firewall: every entry must be a CIDR and none may be the whole Internet (0.0.0.0/0)."
  }
  validation {
    condition     = var.node_firewall_mode == "off" || length(var.node_firewall.node_cidrs) > 0
    error_message = "node_firewall.node_cidrs is required when node_firewall_mode is not \"off\"."
  }
}

variable "node_firewall_ports" {
  description = "name => { protocol (TCP|UDP|ICMP), ports (\"6443\", \"2379-2381\", null for ICMP) }: the shared list of modules/providers/_shared/node-ports (between_members)."
  type        = map(object({ protocol = string, ports = optional(string) }))
  default     = {}
}

variable "node_firewall_scope" {
  description = "name => source groups (nodes, bastion, pods, lb) allowed for each entry of node_firewall_ports (output scope of the shared list)."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.node_firewall_scope : alltrue([for g in v : contains(["nodes", "bastion", "pods", "lb"], g)])])
    error_message = "node_firewall_scope: groups are nodes, bastion, pods, lb."
  }
  # An empty source list on a rule would drop every source of that port: a broken cluster, caught at plan.
  validation {
    condition = var.node_firewall_mode == "off" || alltrue([for k, v in var.node_firewall_scope :
      length(distinct(flatten([for g in v : lookup({
        nodes   = var.node_firewall.node_cidrs
        bastion = var.node_firewall.bastion_cidrs
        pods    = var.node_firewall.pod_cidrs
        lb      = var.node_firewall.lb_cidrs
      }, g, [])]))) > 0
    ])
    error_message = "node_firewall_scope: a rule would have no source at all (its groups are all empty in node_firewall); that rule would cut every source off its port."
  }
}

variable "disk_encryption_passphrase_length" {
  description = <<-EOT
    Length of the generated LUKS2 passphrase (disk encryption at rest). Default 32 keeps the released
    value (62^32, about 190 bits). 33 or more gives at least 192 bits (62^33 is about 196 bits) of entropy (ANSSI PG-083 symmetric key size).
    FOR A NEW CLUSTER ONLY: changing it on a live cluster replaces the passphrase in the state, and the
    nodes' STATE/EPHEMERAL partitions are sealed with the old one; Talos has no re-keying step here, so a reboot
    would not unlock them. Raise it before the first apply, or not at all.
  EOT
  type        = number
  default     = 32

  validation {
    condition     = var.disk_encryption_passphrase_length >= 32 && var.disk_encryption_passphrase_length <= 128 && var.disk_encryption_passphrase_length == floor(var.disk_encryption_passphrase_length)
    error_message = "disk_encryption_passphrase_length: a whole number from 32 (the released value) to 128."
  }
}
