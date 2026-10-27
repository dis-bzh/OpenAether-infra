variable "backup_enabled" {
  description = "Whether to backup cluster artifacts to S3. Disable for local testing."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster"
  type        = string
  default     = "openaether"
}

variable "bucket_suffix" {
  description = <<-EOT
    Discriminator appended to the bucket namespace, so this deployment does not
    collide with anybody else's.

    S3 bucket names are NOT scoped to your account. Scaleway documents them as
    unique "in our whole platform"; OVH as "unique within OVHcloud"; Outscale as
    unique per region. Whoever creates `s3-<project>-<provider>-tfstate-<env>`
    first owns that name for every other customer, and the next person's very
    first billable command fails on it.

    Empty by default, which keeps the names already in use. Set it — six
    lowercase alphanumerics is plenty, `task bucket-suffix` prints one — and
    every bucket becomes s3-<project>-<suffix>-<provider>-…

    It cannot be random or generated here: the state bucket has to exist before
    OpenTofu runs, so its name cannot come from OpenTofu state. Pick it once,
    keep it in the tfvars, and treat it as part of the cluster's identity —
    changing it later orphans every bucket you already have.
  EOT
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[a-z0-9]{0,16}$", var.bucket_suffix))
    error_message = "bucket_suffix must be 0-16 lowercase letters or digits (it goes into an S3 bucket name)."
  }
}

variable "backup_immutability" {
  description = <<-EOT
    What scripts/internal/ensure-buckets.sh does to the buckets that hold copies and logs (state and artifact replicas,
    application backups and their replica, Loki's logs), read back from the store afterwards:

      off         (default) nothing: a deployed cluster changes in no way.
      versioned   versioning plus expiry of non-current versions after backup_retention_days; a delete leaves a version.
      governance  versioned, plus an object lock with that default retention (a key with the bypass permission can
                  still remove a version).
      compliance  as governance, but nobody can remove a locked version before the retention ends, the account owner
                  included, and a bucket cannot be emptied or deleted until then.

    Read by the script from the tfvars file, not by any resource: the buckets exist before OpenTofu runs. Object lock
    usually has to be set when a bucket is created, so on a bucket that already exists it may be refused (reported, not
    forced). Provider support is not verified here: docs/backup-policy.md, section 3.
  EOT
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "versioned", "governance", "compliance"], var.backup_immutability)
    error_message = "backup_immutability must be off, versioned, governance or compliance."
  }
}

variable "backup_retention_days" {
  description = "Days before a non-current object version expires, and the default object-lock retention, when backup_immutability is not off (read by scripts/internal/ensure-buckets.sh)."
  type        = number
  default     = 60
  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 3650 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "backup_retention_days must be a whole number of days from 1 to 3650."
  }
}

# ==============================================================================
# Audit sink (infra #318): a second copy of the audit logs OUTSIDE the cluster. docs/audit-sink.md.
# Read from the tfvars by scripts/lib/audit-sink.sh (the buckets exist before OpenTofu runs); the only things OpenTofu does
# with them are the checks and the two non-secret values it publishes in the cluster-identity ConfigMap (the egress policy
# needs the sink's host name, and a policy cannot read a Secret). Off by default: nothing changes for a deployed cluster.
# ==============================================================================

variable "audit_sink_placement" {
  description = <<-EOT
    Where the second copy of the Kubernetes audit log lives (class A, zero loss; docs/audit-sink.md):

      off                          (default) no sink; nothing in the cluster or the apps changes.
      other_provider               another cloud than the cluster's (proposed default when the sink is on): survives an
                                   account-level event on the cluster's cloud.
      same_provider_other_region   the cluster's own provider in another region: cheaper, one account, but an account-level
                                   event reaches both copies unless audit_sink_lock_mode = "compliance".
      both                         audit_sink_endpoint = another provider AND audit_sink_secondary_endpoint = the cluster's
                                   provider in another region.
  EOT
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "other_provider", "same_provider_other_region", "both"], var.audit_sink_placement)
    error_message = "audit_sink_placement must be off, other_provider, same_provider_other_region or both."
  }
  validation {
    condition     = var.audit_sink_placement == "off" || (var.audit_sink_endpoint != "" && var.audit_sink_region != "")
    error_message = "audit_sink_placement is on: audit_sink_endpoint and audit_sink_region are required."
  }
  validation {
    condition     = var.audit_sink_placement != "both" || (var.audit_sink_secondary_endpoint != "" && var.audit_sink_secondary_region != "")
    error_message = "audit_sink_placement = both: audit_sink_secondary_endpoint and audit_sink_secondary_region are required."
  }
}

variable "audit_sink_endpoint" {
  description = "S3 endpoint of the first audit sink (https://...). other_provider and both: another provider than the cluster's; same_provider_other_region: the cluster's provider. Whether it is on the right cloud is checked by scripts/lib/audit-sink.sh and a check block, not here (a plan and a destroy must keep working)."
  type        = string
  default     = ""
}

variable "audit_sink_region" {
  description = "S3 region of the first audit sink (for same_provider_other_region it must differ from s3_primary_region)."
  type        = string
  default     = ""
}

variable "audit_sink_secondary_endpoint" {
  description = "Only with audit_sink_placement = both: S3 endpoint of the SAME-provider sink in another region."
  type        = string
  default     = ""
}

variable "audit_sink_secondary_region" {
  description = "Only with audit_sink_placement = both: its region (must differ from s3_primary_region)."
  type        = string
  default     = ""
}

variable "audit_sink_prefix" {
  description = "Key prefix inside the sink bucket; the shipper writes <prefix>/<node>/<UTC day>/."
  type        = string
  default     = "audit"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9/_-]{0,62}$", var.audit_sink_prefix)) && !endswith(var.audit_sink_prefix, "/")
    error_message = "audit_sink_prefix must be lowercase letters, digits, - _ and /, not end with /, at most 63 characters."
  }
}

variable "audit_sink_lock_mode" {
  description = "Object-lock mode of the sink bucket(s): governance (default; a key with the bypass right can still remove a version) or compliance (nobody can, the account owner included, until the retention ends: needs audit_sink_compliance_ack = true)."
  type        = string
  default     = "governance"
  validation {
    condition     = contains(["governance", "compliance"], var.audit_sink_lock_mode)
    error_message = "audit_sink_lock_mode must be governance or compliance."
  }
  validation {
    condition     = var.audit_sink_lock_mode != "compliance" || var.audit_sink_compliance_ack
    error_message = "audit_sink_lock_mode = compliance cannot be undone before the retention ends, by anyone: set audit_sink_compliance_ack = true to say you mean it."
  }
}

variable "audit_sink_retention_days" {
  description = "Default object-lock retention of the sink, in days (also the expiry of non-current versions)."
  type        = number
  default     = 365
  validation {
    condition     = var.audit_sink_retention_days >= 1 && var.audit_sink_retention_days <= 3650 && floor(var.audit_sink_retention_days) == var.audit_sink_retention_days
    error_message = "audit_sink_retention_days must be a whole number of days from 1 to 3650."
  }
}

variable "audit_sink_compliance_ack" {
  description = "Explicit opt-in for audit_sink_lock_mode = compliance: the locked objects, and the bucket, cannot be removed before audit_sink_retention_days have passed."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Deployment environment (e.g., dev, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod."
  }
}

variable "cluster_role" {
  description = "Role of this cluster in the CMP: 'management' (hub, runs OpenBao/ESO/Keycloak) or 'workload' (spoke, runs client apps)"
  type        = string
  default     = "workload"
  validation {
    condition     = contains(["management", "workload"], var.cluster_role)
    error_message = "cluster_role must be 'management' or 'workload'."
  }
}

variable "skip_health_check" {
  description = <<-EOT
    Skip the post-bootstrap `talos_cluster_health` data source.

    That data source times out on clusters that are demonstrably healthy (HA
    managements on OVH and Outscale: every node Ready, etcd HEALTH OK on all
    control planes, complete Flux DAG) and returns a bare "context deadline
    exceeded" — see the GitHub issues.

    Enabling this costs the guardrail that catches a silently failed bootstrap,
    so verify health out of band (`talosctl -n <cp> service etcd`,
    `kubectl get nodes`).
  EOT
  type        = bool
  default     = false
}

variable "talos_bootstrap" {
  description = "Whether to configure Talos via SSH tunnel (Phase 2). Default true — pass -var talos_bootstrap=false for Phase 1 (infra only)."
  type        = bool
  default     = true
}

variable "skip_port_ready_wait" {
  description = <<-EOT
    Skip modules/talos's local-exec wait for 50000/TCP before config-apply.
    That wait is a plain OS-level TCP connect (not part of the "talos"
    provider, so mock_provider doesn't fake it) — under `tofu test` with
    mocked endpoints it would retry forever. Set true only for
    tofu test/CI; keep false for real deploys, where the wait is what makes
    cloud bootstrap deterministic.
  EOT
  type        = bool
  default     = false
}

variable "port_ready_hard_reboot_after_seconds" {
  description = <<-EOT
    OVH only. A new instance that the provider calls ACTIVE but whose Talos API never answers (infra #371; 2 of 12 creations in
    lab 27 part B, +5 to +11 minutes each) is hard-rebooted through the provider API after this many seconds of waiting, at most
    twice, and only while it is less than an hour old (scripts/ops/node-provider.py hard-reboot --younger-than). 0 turns it off.
    120 to 600. A reboot of a node in maintenance mode loses nothing; the same call was the manual fix (28 to 30 s).
  EOT
  type        = number
  default     = 300
  validation {
    condition     = var.port_ready_hard_reboot_after_seconds == 0 || (var.port_ready_hard_reboot_after_seconds >= 120 && var.port_ready_hard_reboot_after_seconds <= 600)
    error_message = "port_ready_hard_reboot_after_seconds must be 0 (off) or 120 to 600."
  }
}

variable "secrets_prevent_destroy" {
  description = <<-EOT
    Protect module.talos's talos_machine_secrets (the cluster's root-of-trust
    PKI) from destruction. Keep true for real deploys. Set false only for
    tofu test, whose automatic post-run cleanup destroys everything an
    apply-mode run block created — with prevent_destroy = true that cleanup
    errors out (lifecycle arguments can't be variable-driven, so this flows
    into modules/talos as a plain bool instead).
  EOT
  type        = bool
  default     = true
}

variable "auto_tunnels" {
  description = <<-EOT
    EXPERIMENTAL — collapses the two-phase bootstrap into a single `tofu apply`.
    When true (with talos_bootstrap=true), a terraform_data resource opens the
    SSH tunnels itself (scripts/bootstrap/talos-tunnels.sh open-direct) between
    the provider module and modules/talos, using node/bastion IPs that are only
    known once the VMs exist — ordering falls out of the reference graph, no
    manual tunnel step needed. Default false: the documented two-phase flow
    (`task infra` then `task bootstrap-phase2`) remains the supported path.
    Not exercised against a real host yet; validate on a disposable env first.
  EOT
  type        = bool
  default     = false
}

variable "ssh_key_path" {
  description = "SSH private key path used by auto_tunnels=true's terraform_data provisioner (passed to talos-tunnels.sh open-direct --key). Unused when auto_tunnels=false."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "talos_tunnel_port_offset" {
  description = <<-EOT
    Shifts the localhost ports Phase 2 reaches the nodes on (CPs 50000+offset+i,
    workers 50100+offset+i), so more than one cluster can be bootstrapped from a
    single workstation instead of colliding on a fixed block.
    Must equal TALOS_TUNNEL_OFFSET, which is what actually opens the tunnels;
    Taskfile.yml derives this from that one variable so the two cannot drift.
  EOT
  type        = number
  default     = 0
  validation {
    condition     = var.talos_tunnel_port_offset >= 0 && var.talos_tunnel_port_offset % 200 == 0
    error_message = "talos_tunnel_port_offset must be a non-negative multiple of 200 — the CP and worker blocks are 100 apart, so anything else overlaps them."
  }
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "v1.14.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  # renovate: datasource=github-releases depName=kubernetes/kubernetes
  default = "v1.37.1"
}

variable "node_distribution" {
  description = <<-EOT
    Distribution of nodes per provider. At most one provider may have count > 0 per apply.
    Keys: "scaleway", "ovh", "outscale".

    Common fields (all providers):
      control_planes, workers, region, image_id, image_name

    Scaleway-specific:
      zone            - primary zone (e.g. "fr-par-1")
      zones           - multi-AZ list for HA (e.g. ["fr-par-1", "fr-par-2", "fr-par-3"])
      instance_type   - VM type (e.g. "DEV1-M")

    OVH-specific:
      flavor_name         - OpenStack flavor (e.g. "b3-8")
      network_name        - External network name for floating IPs (default "Ext-Net")
      availability_zones  - OpenStack AZ list (default: the three EU-WEST-PAR zones)

    Outscale-specific:
      instance_type      - VM type (e.g. "tinav5.c2r4p1")
      availability_zones - Subregion list (e.g. ["eu-west-2a", "eu-west-2b"])

    Note: local 3-CP Docker testing lives in ../opentofu-local (separate root),
    not here.
  EOT
  type = map(object({
    control_planes     = number
    workers            = number
    region             = optional(string)
    zone               = optional(string)
    zones              = optional(list(string))
    instance_type      = optional(string)
    flavor_name        = optional(string)
    image_id           = optional(string)
    image_name         = optional(string)
    availability_zones = optional(list(string))
    network_name       = optional(string, "Ext-Net")
    bastion_image_id   = optional(string)
    talos_api_port     = optional(number, 50000)
    k8s_api_port       = optional(number, 6443)

    # Cloud-only (scaleway/ovh): "managed" (default, an LB) or "vip" (no LB —
    # a Talos Layer2 VIP on the private network instead). Outscale rejects
    # "vip" (its Net is an L3 SDN, no ARP/broadcast domain). See each
    # provider's k8s_lb_mode variable for the per-cloud mechanism.
    k8s_lb_mode = optional(string, "managed")

    # Proxmox-specific (single host or multi-host cluster). All optional → no
    # impact on the cloud providers. Defaults live in the TYPE (like image_name/
    # network_name): with map(object) an unset field arrives as null and would
    # clobber a merge() default, so type-level defaults are what actually apply.
    # See modules/providers/proxmox for semantics. Host-specific keys with no
    # sane default (talos_image_file_id, gateway_ip, apiserver_vip, host_public_ip)
    # stay null → supplied per-host in the tfvars.
    node_names              = optional(list(string))
    datastore_id            = optional(string, "local-zfs")
    iso_datastore_id        = optional(string, "local")
    talos_image_file_id     = optional(string)
    network_bridge          = optional(string, "vmbr1")
    network_cidr            = optional(string, "10.0.0.0/24")
    gateway_ip              = optional(string)
    apiserver_vip           = optional(string)
    apiserver_vip_interface = optional(string, "eth0")
    cpu_cores               = optional(number, 4)
    memory_mb               = optional(number, 8192)
    root_disk_gb            = optional(number, 50)
    control_plane_ip_offset = optional(number, 10)
    worker_ip_offset        = optional(number, 20)
    nameservers             = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    enable_bastion          = optional(bool, false)
    host_public_ip          = optional(string)
    host_ssh_user           = optional(string, "root")
  }))
  default = {}

  # Workers with no control plane cannot be a cluster, and on a live one that edit deletes every control
  # plane and drops the bootstrap from the state.
  validation {
    condition     = alltrue([for d in values(var.node_distribution) : d.control_planes > 0 || d.workers == 0])
    error_message = "node_distribution: workers without control planes is not a cluster. Set control_planes to 1 or 3, or workers to 0."
  }
}

variable "scw_root_volume_size_gb" {
  description = <<-EOT
    Scaleway only: size in GB of the system volume of every node (default 50). Talos keeps its EPHEMERAL partition
    (kubelet, containerd images, logs) there, about 4 GB under this value. Lab 12 measured ~11 GB of images on a worker
    with the whole application stack and 15.6 GB usable at 20 GB: DiskPressure, 25 Zitadel pods evicted. 50 leaves ~46 GB
    usable: the images, the second set a chart upgrade pulls before the old one is garbage-collected (kubelet image GC
    starts at 85% use), logs and margin. With deploy_flux the value must be at least 40. A cluster built at 20 gets an
    in-place resize of its sbs_volumes at the next apply (no node replaced); Talos grows EPHEMERAL at the node's next
    reboot, so reboot the workers one at a time (drained) afterwards. Pin 20 in the tfvars to keep the old size.
  EOT
  type        = number
  default     = 50
  validation {
    condition     = var.scw_root_volume_size_gb >= 20 && var.scw_root_volume_size_gb <= 500
    error_message = "scw_root_volume_size_gb must be between 20 and 500."
  }
  validation {
    condition     = !var.deploy_flux || var.scw_root_volume_size_gb >= 40
    error_message = "scw_root_volume_size_gb must be at least 40 with deploy_flux = true: the application stack puts ~11 GB of images on each node and 20 GB left 15.6 GB usable (lab 12: DiskPressure, evictions, CreateContainer timeouts). Use 50 (the default)."
  }
}

variable "outscale_root_volume_size_gb" {
  description = <<-EOT
    Outscale only: size in GB of the root (BSU) volume of every NEW node. null (the default) keeps the size of the OMI, which is
    the raw Talos image rounded down to a GiB (about 11-12): Talos then has only a few GB of EPHEMERAL, which the full application
    stack (~11 GB of images per worker) does not fit. Set 50 for a cluster that carries the platform; a `check` warns when
    deploy_flux is on and this is null. Applies to nodes created after the change only (the volume of an existing VM
    is not resized in place by this provider; `ignore_changes` keeps a running node from being replaced): to grow a running
    cluster, replace its workers one at a time with `task cluster-roll`.
  EOT
  type        = number
  default     = null
  validation {
    condition     = var.outscale_root_volume_size_gb == null || (var.outscale_root_volume_size_gb >= 20 && var.outscale_root_volume_size_gb <= 14901)
    error_message = "outscale_root_volume_size_gb must be null or between 20 and 14901."
  }
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data storage for worker nodes (the active provider only — one
    provider is active per apply). Decouples the block volumes created/attached
    by the provider module (`disks`) from the encrypted Talos UserVolumeConfig
    documents (`volumes`, mounted at /var/mnt/<name>, LUKS2).

    Default (empty) = no dedicated data disks (workers use the system disk only).

    Examples:
      # Dev — one shared 50GB data disk, two volumes (local-path + Longhorn):
      worker_storage = {
        disks = [{ size_gb = 50 }]
        volumes = [
          { name = "local-path-provisioner", disk_match = "!system_disk", min_size = "20GB", max_size = "25GB" },
          { name = "longhorn",                disk_match = "!system_disk", grow = true },
        ]
      }
      # Prod — one large shared disk: disks = [{ size_gb = 500 }] (same volumes).
      # Prod — dedicated disks: disks = [{ size_gb = 100 }, { size_gb = 400 }]
      #   with disk_match discriminating by size, e.g.
      #   "disk.size < 200000000000u" vs "disk.size > 200000000000u".
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

variable "node_nameservers" {
  description = <<-EOT
    DNS-over-TLS/HTTPS (or plain) resolvers for the nodes' own DNS, instead of the
    platform's plaintext one. Empty (default) changes nothing. Entries are
    { address, protocol = "DoT" | "DoH" | "Do53", tls_server_name }; the rules and the
    trade-offs are on the variable of the same name in modules/talos/variables.tf.
  EOT
  type = list(object({
    address         = string
    protocol        = optional(string, "DoT")
    tls_server_name = optional(string, "")
  }))
  default = []
}

variable "node_dns_boot_timeout" {
  description = "How long a booting node waits for time sync when node_nameservers is encrypted (\"\" keeps Talos's endless wait). Trade-off: modules/talos/variables.tf."
  type        = string
  default     = "90s"
}

variable "node_log_forwarding" {
  description = <<-EOT
    Ships the nodes' Talos service and kernel logs over plain TCP to a receiver the host can
    reach. Null (default) changes nothing. { endpoint = "tcp://host:port", kernel = true,
    kernel_endpoint = "" }; the rules and the trade-offs (plaintext, ClusterIP unreachable from
    the host, applied to every node by one apply) are on the variable of the same name in modules/talos/variables.tf.
  EOT
  type = object({
    endpoint        = string
    kernel          = optional(bool, true)
    kernel_endpoint = optional(string, "")
  })
  default = null
}

variable "node_time_servers" {
  description = <<-EOT
    NTP sources of the Talos nodes (ANSSI PA-012 R5). Empty (default) keeps Talos's single built-in
    server. Several independent hosts or addresses; plain NTP, udp/123. Mirror it in
    bastion_baseline.time_servers. Rules and caveats: the variable of the same name in modules/talos/variables.tf.
  EOT
  type        = list(string)
  default     = []
}

variable "etcd_snapshot_api_access" {
  description = <<-EOT
    Lets the apps repository's scheduled etcd snapshot (CronJob etcd-snapshot, foundation-databases) reach the Talos API of the
    control planes with ONE role, os:etcd:backup (take a snapshot, nothing else): machine.features.kubernetesTalosAPIAccess,
    allowed for the namespace foundation-databases only. This is what removes "nothing runs the snapshot for you" without putting
    the state passphrase, the S3 keys and a Talos admin credential on the bastion. true (default) on a new cluster; on an existing
    one the next apply re-applies the control planes' machine configuration (one at a time; a reboot is not expected, but try it on
    a throwaway cluster first). false keeps the configs as they were, and the operator's `task etcd-snapshot` is then the only
    snapshot. Details: docs/backup-policy.md.
  EOT
  type        = bool
  default     = true
}

variable "coredns_ha" {
  description = "Run OpenAether's own CoreDNS (min(3, nodes) replicas on different nodes, a budget, a 30 s toleration) instead of the 2-replica Talos one (infra #388, modules/talos). False keeps the Talos Deployment; docs/resilience.md says what each does on a Talos upgrade."
  type        = bool
  default     = true
}

variable "node_monitor_grace_period_seconds" {
  description = <<-EOT
    Seconds the kube-controller-manager waits for a node's heartbeat before marking it NotReady (Kubernetes default 50).
    Default 30 (owner decision 2026-10-26): it sets the controller manager and, below 40, the kubelet heartbeat to match
    (lease duration = this value, status every this value / 4, 4 chances to be heard). 0 changes nothing: the Kubernetes
    default 50 s applies (the opt-out). 20 to 300 otherwise. Why 30: the node power-off write-gap target (75 s) is met only
    at 30 s (lab 27, Scaleway: 82-86 s at the default, 62-70 s at 30 s, 49-62 s at 20 s), with no NotReady, eviction or
    failover in a 30 minute nominal soak at 30 s. EVIDENCE FROM ONE PROVIDER: the OVH and Outscale labs are the next
    proof, and the default goes back to 0 if they flap. Not measured: a soak during a roll. On an existing cluster the
    next `cluster-up` re-applies the machine config of every node (about 7.5 min per apply in lab 27, no reboot).
    Details on the variable of the same name in modules/talos/variables.tf.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.node_monitor_grace_period_seconds == 0 || (var.node_monitor_grace_period_seconds >= 20 && var.node_monitor_grace_period_seconds <= 300 && var.node_monitor_grace_period_seconds == floor(var.node_monitor_grace_period_seconds))
    error_message = "node_monitor_grace_period_seconds must be 0 (Kubernetes default, 50 s) or a whole number of seconds between 20 and 300."
  }
}

variable "node_baseline" {
  description = <<-EOT
    Opt-in kernel/kubelet baseline of the nodes (ANSSI BP-028 R9/R12/R13). Null (default) changes nothing.
    { sysctls, sysctls_extra, panic_on_oops, worker_default_seccomp, pod_pids_limit, kubelet_server_tls },
    all off/empty/0 by default; what each does, its risk and its prerequisite are on the variable of the
    same name in modules/talos/variables.tf and in docs/hardening.md. Try it on a throwaway cluster first.
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
}

variable "cilium_hubble_drop_log" {
  description = <<-EOT
    Boots Cilium from bootstrap-manifests/cilium-hubble-drops.yaml: the Hubble SERVER only (no relay, no UI,
    no TCP listener) exporting DROPPED/ERROR flows, field-masked, to the agent's stdout so that policy denials
    reach the pod-log collector (ANSSI PA-012 R9). False (default) keeps cilium.yaml, byte for byte. It is a
    bootstrap manifest: it reaches an EXISTING cluster as a Talos inline-manifest change (agents restart
    one node at a time); read LAB-CHECKLIST B22 and try it on a throwaway cluster first. Ignored when
    cilium_manifest is set.
  EOT
  type        = bool
  default     = false
}

variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH, K8s API LB ACL)"
  type        = list(string)

  # This list is the ONLY thing between the internet and two doors: bastion
  # sshd, and the 6443 ACL in front of a `system:masters` kubeconfig that
  # Kubernetes cannot revoke. It reaches all four providers from here
  # (main.tf), so one block covers what four modules would repeat.

  validation {
    condition     = length(var.admin_ip) > 0
    error_message = "admin_ip must not be empty: with no allowed source the bastion is unreachable and the deploy is wasted."
  }

  validation {
    # Rejects a bare address, and the `YOUR_IP/32` left in a copied example.
    condition     = alltrue([for c in var.admin_ip : can(cidrhost(c, 0))])
    error_message = "Every admin_ip entry must be a CIDR with its prefix, e.g. 203.0.113.4/32 — not a bare address."
  }

  validation {
    # Prefix, not string match: catches 0.0.0.0/0, ::/0 and 198.51.100.7/0
    # alike. Guarded by can(), so a malformed entry fails the rule above
    # rather than blowing up on split()[1] here.
    condition     = alltrue([for c in var.admin_ip : can(cidrhost(c, 0)) ? tonumber(split("/", c)[1]) > 0 : true])
    error_message = "admin_ip must not contain a /0: that opens bastion SSH and the Kubernetes API ACL to the whole internet."
  }
}

variable "bastion_ssh_keys" {
  description = "SSH public keys per provider. Key = provider name (scaleway/ovh/outscale), value = list of SSH public keys. Add a key to grant multi-admin access without changing the list structure. Accepted types: ssh-ed25519, sk-ssh-ed25519@openssh.com, ecdsa-sha2-nistp256/384/521, sk-ecdsa-sha2-nistp256@openssh.com and ssh-rsa of at least bastion_ssh_rsa_min_bits; one key per list entry."
  type        = map(list(string))
  default     = {}

  # The key lines are written verbatim to authorized_keys. Checked on the type token, not on the blob
  # (the test fixtures and the examples carry truncated blobs), and an options prefix is allowed.
  validation {
    condition     = alltrue([for k in flatten(values(var.bastion_ssh_keys)) : !strcontains(k, "\n") && !strcontains(k, "\r")])
    error_message = "bastion_ssh_keys: one key per list entry, no line break inside an entry (a second line would be a second, unreviewed authorized_keys line)."
  }

  validation {
    condition = alltrue([for k in flatten(values(var.bastion_ssh_keys)) :
      can(regex("(^|\\s)(ssh-ed25519|sk-ssh-ed25519@openssh\\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\\.com|ssh-rsa)\\s+[^\\s]", k))
    ])
    error_message = "bastion_ssh_keys: only ssh-ed25519, sk-ssh-ed25519@openssh.com, ecdsa-sha2-nistp256/384/521, sk-ecdsa-sha2-nistp256@openssh.com and ssh-rsa keys are accepted (ssh-dss and anything unrecognised are refused)."
  }

  # RSA size from the base64 blob length (a 2048-bit key is about 372 characters, 3072 bits about 544): the blob
  # cannot be decoded here, so the floor sits just below the nominal length.
  validation {
    condition = alltrue([for k in flatten(values(var.bastion_ssh_keys)) :
      !can(regex("(^|\\s)ssh-rsa\\s", k)) || length(regex("(?:^|\\s)ssh-rsa\\s+([^\\s]+)", k)[0]) >= (var.bastion_ssh_rsa_min_bits >= 3072 ? 540 : 370)
    ])
    error_message = "bastion_ssh_keys: an ssh-rsa key is shorter than bastion_ssh_rsa_min_bits. Use ssh-ed25519, or a longer RSA key."
  }
}

variable "bastion_ssh_rsa_min_bits" {
  description = "Smallest ssh-rsa key accepted in bastion_ssh_keys: 2048 (default, so a key already deployed keeps planning) or 3072 (ANSSI-preferred). Only checks; it changes no resource."
  type        = number
  default     = 2048

  validation {
    condition     = contains([2048, 3072], var.bastion_ssh_rsa_min_bits)
    error_message = "bastion_ssh_rsa_min_bits is 2048 or 3072."
  }
}

# The bastion's OS baseline (sysctl, auditd, journald, sshd directives, mounts, in-VM nftables logging and
# source filter). OFF by default: turning `enabled` on changes the cloud-init user_data, which REPLACES the
# bastion on OVH and Outscale (new IP, new host key) and is ignored by a running instance elsewhere - apply it
# on a fresh cluster or in a planned window, never during a bootstrap (CHANGELOG).
variable "bastion_baseline" {
  description = <<-EOT
    Opt-in bastion hardening baseline (default: nothing changes).
      enabled             - master switch. false renders the cloud-init byte for byte as before.
      audit_logging       - with enabled: auditd (execve, /etc, mount, modules, ptrace), persistent size-capped journald, bastion user in adm and systemd-journal.
      restrict_ssh_source - with enabled: the in-VM firewall accepts port 22 from admin_ip only (Proxmox has no security group). admin_ip is then part of the user_data: changing it replaces the bastion, and a running bastion keeps the OLD source list - use it where a replacement is acceptable.
      time_servers        - with enabled: chrony with these NTP servers (empty: the image's time service stays).
      revoked_keys        - with enabled: public keys (authorized_keys lines) written to sshd's RevokedKeys file; changing the list replaces the bastion.
  EOT
  type = object({
    enabled             = optional(bool, false)
    audit_logging       = optional(bool, true)
    restrict_ssh_source = optional(bool, false)
    time_servers        = optional(list(string), [])
    revoked_keys        = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = alltrue([for t in var.bastion_baseline.time_servers : can(regex("^[A-Za-z0-9.:-]+$", t))])
    error_message = "bastion_baseline.time_servers: host names or addresses only."
  }

  validation {
    condition     = alltrue([for k in var.bastion_baseline.revoked_keys : !strcontains(k, "\n") && !strcontains(k, "\r") && length(trimspace(k)) > 0])
    error_message = "bastion_baseline.revoked_keys: one public key per entry, no line break, no empty entry."
  }

  validation {
    condition     = var.bastion_baseline.enabled || (length(var.bastion_baseline.revoked_keys) == 0 && length(var.bastion_baseline.time_servers) == 0 && !var.bastion_baseline.restrict_ssh_source)
    error_message = "bastion_baseline: restrict_ssh_source, time_servers and revoked_keys only apply with enabled = true; they would be silently ignored."
  }
}

# Per-person accounts (ANSSI NT-SSH R21/R30, PA-022 R30, HYG-M8), ADDITIVE: bastion_ssh_keys and the shared "bastion"
# account stay as the automation and break-glass path. Each entry here becomes its own unix account in bastion-admins with
# its own authorized_keys file, so the sshd login line (LogLevel VERBOSE with the baseline) names a person, not a pool.
# {} adds no user: the cloud-init is byte for byte the one without this variable.
variable "bastion_admins" {
  description = <<-EOT
    Named bastion operators: map of unix account name => { ssh_keys = [public key lines] }. One account each, in the
    group bastion-admins, no sudo. ssh_keys = [] makes a certificate-only account (needs bastion_ssh_ca_public_key; the
    certificate must carry the account name as principal). Default {}: only the shared bastion account (bastion_ssh_keys) exists.
    Adding, removing or changing an entry changes the cloud-init user_data, which replaces the bastion on OVH and
    Outscale and is ignored by a running instance elsewhere: offboard with the SSH CA (docs/admin-access.md), not by
    editing this map on a running bastion.
  EOT
  type        = map(object({ ssh_keys = list(string) }))
  default     = {}

  validation {
    condition = alltrue([for n in keys(var.bastion_admins) :
      can(regex("^[a-z][a-z0-9_-]{0,31}$", n)) && !contains(["root", "bastion", "ubuntu", "debian", "admin", "outscale", "sshd", "nobody", "daemon", "sys", "adm", "sudo", "bastion-admins"], n)
    ])
    error_message = "bastion_admins: an account name is lowercase letters, digits, '_' or '-', starts with a letter, at most 32 characters, and is not root, bastion, ubuntu, debian, admin, outscale, sshd, nobody, daemon, sys, adm, sudo or bastion-admins (an image's default user would never join the group)."
  }

  # A certificate-only operator (ssh_keys = []) is the point of the SSH CA: the login stops when the 8 h certificate does.
  # Without a CA such an account could never log in, so it is refused as a mistake.
  validation {
    condition     = alltrue([for a in values(var.bastion_admins) : length(a.ssh_keys) > 0 || var.bastion_ssh_ca_public_key != ""])
    error_message = "bastion_admins: an operator without a public key needs bastion_ssh_ca_public_key (a certificate-only account); with no CA it could never log in."
  }

  validation {
    condition     = alltrue([for k in flatten([for a in values(var.bastion_admins) : a.ssh_keys]) : !strcontains(k, "\n") && !strcontains(k, "\r")])
    error_message = "bastion_admins: one key per list entry, no line break inside an entry."
  }

  validation {
    condition = alltrue([for k in flatten([for a in values(var.bastion_admins) : a.ssh_keys]) :
      can(regex("(^|\\s)(ssh-ed25519|sk-ssh-ed25519@openssh\\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\\.com|ssh-rsa)\\s+[^\\s]", k))
    ])
    error_message = "bastion_admins: only ssh-ed25519, sk-ssh-ed25519@openssh.com, ecdsa-sha2-nistp256/384/521, sk-ecdsa-sha2-nistp256@openssh.com and ssh-rsa keys are accepted."
  }

  validation {
    condition = alltrue([for k in flatten([for a in values(var.bastion_admins) : a.ssh_keys]) :
      !can(regex("(^|\\s)ssh-rsa\\s", k)) || length(regex("(?:^|\\s)ssh-rsa\\s+([^\\s]+)", k)[0]) >= (var.bastion_ssh_rsa_min_bits >= 3072 ? 540 : 370)
    ])
    error_message = "bastion_admins: an ssh-rsa key is shorter than bastion_ssh_rsa_min_bits."
  }
}

# The SSH CA the bastion trusts (ANSSI NT-SSH R30: revocation by short-lived certificates). The modules always had these two
# variables; the root now hands them over. Both "" keeps the cloud-init byte for byte as before.
variable "bastion_ssh_ca_public_key" {
  description = "Public key of the SSH CA the bastion trusts for user certificates (one line, as in ca.pub). Empty (default) = no CA. Certificates for named operators must carry the account name as principal; set a short validity when signing (`ssh-keygen -s ca -n <account> -V +8h`). Changes user_data: replaces the bastion on OVH and Outscale, ignored by a running instance elsewhere."
  type        = string
  default     = ""

  validation {
    condition     = var.bastion_ssh_ca_public_key == "" || can(regex("^(ssh-ed25519|sk-ssh-ed25519@openssh\\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+( [A-Za-z0-9@._ -]*)?$", var.bastion_ssh_ca_public_key))
    error_message = "bastion_ssh_ca_public_key: one public key line (type, base64, optional plain comment) - no quote, backslash or line break, since it is written inside a double-quoted YAML string."
  }
}

variable "bastion_ssh_ca_principals" {
  description = "Principals (one per line) a certificate may carry to log in on the SHARED bastion account (AuthorizedPrincipalsFile for it). Named operators in bastion_admins always get their own account name as the only principal. Empty (default) = no certificate logs in on the shared account."
  type        = string
  default     = ""

  validation {
    condition     = alltrue([for l in split("\n", trimspace(var.bastion_ssh_ca_principals)) : l == "" || can(regex("^[A-Za-z0-9@._-]+$", l))])
    error_message = "bastion_ssh_ca_principals: one principal per line, letters, digits and @ . _ - only."
  }
}

variable "bastion_require_hardware_key" {
  description = "Plan-time check: every key in bastion_admins must be a FIDO/U2F hardware-backed key (sk-*). It does NOT cover bastion_ssh_keys, the shared automation and break-glass account (a CI or tunnel key cannot touch a token): restrict who holds that key. For a PIN on each use, the operator generates the key with `ssh-keygen -O verify-required` and puts the `verify-required` option in front of the key line. Changes no resource."
  type        = bool
  default     = false

  validation {
    condition     = !var.bastion_require_hardware_key || length(var.bastion_admins) > 0
    error_message = "bastion_require_hardware_key = true checks bastion_admins, which is empty: it would be silently ignored."
  }

  validation {
    condition = !var.bastion_require_hardware_key || alltrue([for k in flatten([for a in values(var.bastion_admins) : a.ssh_keys]) :
      can(regex("(^|\\s)(sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com)\\s+[^\\s]", k))
    ])
    error_message = "bastion_require_hardware_key is true, so every key in bastion_admins must be a FIDO key (sk-ssh-ed25519@openssh.com or sk-ecdsa-sha2-nistp256@openssh.com)."
  }
}

# Closing the bastion's Internet egress (ANSSI PA-022 R10/R19, HYG-M27, NT-006 R2): the in-VM firewall and the cloud security
# group stop allowing 80/443 to anywhere, the cluster rule narrows to TCP 6443/50000 on the real cluster subnet (8200 is
# gone from the firewall and from PermitOpen), and unattended-upgrades is switched off because it can no longer reach a
# mirror: the bastion is patched by REPLACING it (docs/admin-access.md). "legacy" is today's behaviour, byte for byte.
variable "bastion_internet_egress" {
  description = <<-EOT
    mode        - "legacy" (default, nothing changes) or "closed".
    dns_servers - with closed: DNS goes to these addresses only (the provider resolver); empty keeps DNS open to any destination.
    ntp_servers - with closed: NTP goes to these addresses only; empty keeps it open. A chrony source by NAME resolves to
                  addresses this list cannot know: pin NTP only with address-literal bastion_baseline.time_servers.
    closed changes the cloud-init user_data (replaces the bastion on OVH and Outscale; a running Scaleway or Proxmox VM
    keeps its old firewall) and edits the security group in place. Never apply it during a bootstrap or an upgrade.
  EOT
  type = object({
    mode        = optional(string, "legacy")
    dns_servers = optional(list(string), [])
    ntp_servers = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = contains(["legacy", "closed"], var.bastion_internet_egress.mode)
    error_message = "bastion_internet_egress.mode is \"legacy\" or \"closed\"."
  }

  validation {
    condition = alltrue([for a in concat(var.bastion_internet_egress.dns_servers, var.bastion_internet_egress.ntp_servers) :
      can(cidrhost(strcontains(a, "/") ? a : "${a}/${strcontains(a, ":") ? 128 : 32}", 0))
    ])
    error_message = "bastion_internet_egress.dns_servers / ntp_servers: IP addresses or CIDRs (the firewall and the security group cannot filter by name)."
  }

  # The security group is closed from the bastion's creation, so the first boot cannot reach a package mirror: auditd and chrony
  # would never be installed and the bastion would come up "hardened" without them (seen on a real OVH run: cloud-init ends in
  # error, auditd absent). Refused at plan time instead.
  validation {
    condition = var.bastion_internet_egress.mode != "closed" || !var.bastion_baseline.enabled || (
      !var.bastion_baseline.audit_logging && length(var.bastion_baseline.time_servers) == 0
    )
    error_message = "bastion_internet_egress.mode = \"closed\" with bastion_baseline: the first boot cannot install packages (auditd, chrony) once the Internet is closed. Set bastion_baseline.audit_logging = false and leave time_servers empty, or keep the egress legacy (docs/admin-access.md)."
  }

  validation {
    condition     = var.bastion_internet_egress.mode == "closed" || (length(var.bastion_internet_egress.dns_servers) == 0 && length(var.bastion_internet_egress.ntp_servers) == 0)
    error_message = "bastion_internet_egress: dns_servers and ntp_servers only apply with mode = \"closed\"; they would be silently ignored."
  }
}

# ==============================================================================
# GitOps / Bootstrap
# ==============================================================================

variable "git_repo_url" {
  description = "Git repository URL for the Flux GitRepository source (OpenAether-apps)"
  type        = string
  default     = "https://github.com/dis-bzh/OpenAether-apps.git"
}

# The default and the examples pin the OpenAether-apps tag this release was cut with
# (refs/tags/0.3.2 for infra 0.3.2), which exists before the infra tag that points at
# it: a commit on a branch would otherwise reach a running cluster within the
# reconcile interval. Moving the default is part of cutting a release, never of a
# change in between. Set refs/heads/<branch> to develop against apps; a branch also
# keeps two managements off the same apps/clusters.
variable "git_ref" {
  description = "Git ref OpenAether-apps is tracked at, fully qualified: refs/heads/<branch> to develop, refs/tags/<version> to deploy"
  type        = string
  default     = "refs/tags/0.3.2"

  validation {
    condition     = can(regex("^refs/(heads|tags)/.+$", var.git_ref))
    error_message = "git_ref must be fully qualified: refs/tags/<version> or refs/heads/<branch>."
  }
}

# Opt-in verification of the commit Flux applies (ANSSI SSDLC-CICD-AIP-03, SSDLC-CONT-REC06). Off = the bootstrap manifest
# is byte-identical to the one before this variable existed. This repository wires OpenPGP keys only; the vendored Flux would also take SSH keys (.sshpub), not wired here.
variable "flux_git_verify" {
  description = <<-EOT
    Flux Git source verification. enabled = false (default): nothing changes. enabled = true: the bootstrap manifest gets
    the Secret `git-signers` (one `signer-N.asc` per armored PUBLIC key in public_keys, which must include GitHub's
    web-flow key if squash merges are used) and `spec.verify {mode: HEAD, secretRef: git-signers}` on the GitRepository.
    A commit not signed by one of these keys is NOT applied (the GitRepository goes NotReady, the last good artifact
    stays). Enable it on the apps side too (apps/flux/components/git-verify) and read docs/signed-commits.md first.
    Fingerprints are NOT checked here: compare them to the published signer table before applying.
  EOT
  type = object({
    enabled     = optional(bool, false)
    public_keys = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = !var.flux_git_verify.enabled || length(var.flux_git_verify.public_keys) > 0
    error_message = "flux_git_verify: enabled = true needs at least one armored public key (an empty signer set would reject every commit)."
  }
  validation {
    condition = alltrue([for k in var.flux_git_verify.public_keys :
      startswith(trimspace(k), "-----BEGIN PGP PUBLIC KEY BLOCK-----") && endswith(trimspace(k), "-----END PGP PUBLIC KEY BLOCK-----")
    ])
    error_message = "flux_git_verify.public_keys: each entry is an ARMORED PGP PUBLIC key block (gpg --armor --export <id>); never a private key."
  }
  validation {
    condition     = length(distinct([for k in var.flux_git_verify.public_keys : trimspace(k)])) == length(var.flux_git_verify.public_keys)
    error_message = "flux_git_verify.public_keys: the same key twice."
  }
}

# The OpenBao recovery shares (OpenAether-apps, foundation/vault). OpenBao unseals itself with a static key, so no
# human holds an unseal share; what the operators hold are RECOVERY shares, used only to generate a root token in an
# emergency. They come out of `sys/init` encrypted to the keys below, so the cluster never stores a usable share.
variable "openbao_recovery_pgp_keys" {
  description = <<-EOT
    The operators' PGP PUBLIC keys, one per recovery-share holder, each `gpg --export <id> | base64 -w0` (the key needs
    an encryption subkey). Published as the ConfigMap `openbao-operator-keys`, which switches the OpenBao bootstrap to
    PRODUCTION mode: N shares, each encrypted to one of these keys. Empty = DEVELOPMENT mode: one plaintext share in a
    Secret labelled as such. With deploy_flux on a prod cluster, at least 3 keys are required. Public data; the private
    keys never come near this repository.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for k in var.openbao_recovery_pgp_keys : can(regex("^[A-Za-z0-9+/]{200,}={0,2}$", trimspace(k)))])
    error_message = "openbao_recovery_pgp_keys: each entry is a PGP public key exported with `gpg --export <id> | base64 -w0` (one line of base64, no armor, no private key)."
  }
  validation {
    condition     = length(var.openbao_recovery_pgp_keys) == 0 || length(var.openbao_recovery_pgp_keys) >= 3
    error_message = "openbao_recovery_pgp_keys: either empty (development) or at least 3 keys, so that a threshold of 2 still means two different people."
  }
  validation {
    condition     = length(distinct([for k in var.openbao_recovery_pgp_keys : trimspace(k)])) == length(var.openbao_recovery_pgp_keys)
    error_message = "openbao_recovery_pgp_keys: the same key twice would let one person hold two shares."
  }
}

variable "openbao_recovery_threshold" {
  description = "How many recovery shares generate a root token. Null = a majority of the keys (floor(N/2)+1). At least 2, at most N."
  type        = number
  default     = null

  validation {
    condition     = var.openbao_recovery_threshold == null || (var.openbao_recovery_threshold >= 2 && var.openbao_recovery_threshold == floor(var.openbao_recovery_threshold))
    error_message = "openbao_recovery_threshold: an integer of at least 2 (one share would be a single point of failure and compromise)."
  }
}

variable "deploy_app_lb" {
  description = <<-EOT
    Create the public HTTP/HTTPS load balancer that fronts the application
    Gateway. FALSE by default: its backends are pinned to the Istio Gateway's
    fixed NodePorts (30080/30443), so on an infrastructure-only cluster it is a
    load balancer that is created, billed, and points at ports where nothing
    listens. Turn it on with the apps that need it.

    The Kubernetes API load balancer is a different resource and is NOT governed
    by this — a cluster needs its apiserver reachable whether or not it runs any
    application.
  EOT
  type        = bool
  default     = false
}

variable "app_lb_allowed_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the application load balancer (80/443). EMPTY
    by default = no filter, exactly the behaviour before this variable existed:
    every route on the Gateway (Zitadel, OpenBao UI, Grafana) then answers anyone
    who sets its Host header.

    When set, Scaleway gets allow-then-deny ACLs on both frontends, OVH
    `allowed_cidrs` on both Octavia listeners, Outscale security-group rules on
    the LB's group. Proxmox and local have no cloud LB and ignore it. Each module
    also admits the cluster's own egress address (pods reach
    https://zitadel.openaether.local through the LB) and, on Scaleway and OVH, the
    private range; YOUR other public clients (an office, a CI runner, a monitor)
    must be listed here or they lose access. `["0.0.0.0/0"]` is accepted: it turns
    the machinery on while staying open, to prove the in-place update first.

    Roll out empty, then open, then one provider (docs/network.md, section 6).
    Enforcement is untested on a real cloud: docs/admin-access.md, section 6.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.app_lb_allowed_cidrs : can(cidrhost(c, 0)) && !strcontains(c, ":")])
    error_message = "Every app_lb_allowed_cidrs entry must be an IPv4 CIDR with its prefix, e.g. 203.0.113.4/32 — not a bare address."
  }
}

variable "deploy_flux" {
  description = <<-EOT
    Install Flux on the cluster. FALSE by default: this release is infrastructure only —
    Talos plus Cilium, which is what makes a cluster healthy, up and ready. Flux
    and everything it reconciles live in OpenAether-apps and come back as a
    user choice in a later release.

    The mechanism is not new and is not switched off code: modules/talos already
    reads an empty flux_manifest as "no Flux", and infrastructure/opentofu-local
    has driven that exact path through this same module on every `task local-up`
    since the local cluster existed. This variable only chooses which way the
    existing branch goes, in a local — no resource address moves, so flipping it
    cannot replace a node.

    When false, git_repo_url / git_ref / flux_namespace / apps_profile are inert:
    they exist to fill a template that is never rendered.
  EOT
  type        = bool
  default     = false
}

variable "flux_namespace" {
  description = "Namespace for Flux installation"
  type        = string
  default     = "flux-system"

  # The vendored flux-install.yaml creates exactly one Namespace, flux-system,
  # and every namespaced object in it points there. Another value renders
  # inlineManifests aimed at a namespace nothing creates — and Talos applies
  # inlineManifests with no ordering and no namespace creation, so it fails on a
  # paid cluster with every offline gate green. No schema validator can see it:
  # `namespace: gitops` is perfectly valid YAML.
  validation {
    condition     = var.flux_namespace == "flux-system"
    error_message = "flux_namespace must be flux-system: the vendored flux-install.yaml creates that namespace and nothing else. Re-render the manifest before changing this."
  }
}

variable "cilium_manifest" {
  description = "Optional override for Cilium manifest (rendered from file by default)"
  type        = string
  default     = null
}

variable "flux_manifest" {
  description = "Optional override for Flux install manifest (rendered from file by default)"
  type        = string
  default     = null
}

variable "flux_bootstrap_manifest" {
  description = "Optional override for Flux bootstrap manifest (rendered from template by default)"
  type        = string
  default     = null
}

# ==============================================================================
# S3 Backup / Disaster Recovery
#
# Every DR artifact lives in TWO object stores: a PRIMARY (the cluster's own
# provider, reached with the apply's AWS_* creds) and a REPLICA (the "-backup"
# bucket — in prod a *different* provider, reached with BACKUP_AWS_* creds, which
# default to the primary creds when unset, e.g. for dev).
#
#   tfstate              -> s3-<cluster>-tfstate-<env>      (+ -backup)
#   kubeconfig/talosconfig -> s3-<cluster>-<role>-<env>     (+ -backup)
#
# Bucket names are DERIVED from this convention (see locals in backup.tf), so you
# only provide the endpoints/regions of the two stores here. tfstate client-side
# encryption is the backend's encryption{} block (AES-GCM); the artifacts are
# client-side encrypted with gpg (AES-256) by scripts/ops/backup-artifacts.sh.
# ==============================================================================

variable "s3_primary_endpoint" {
  description = "S3 endpoint of the PRIMARY store (the cluster's own provider, e.g. https://s3.fr-par.scw.cloud)"
  type        = string
}

variable "s3_primary_region" {
  description = "S3 region of the primary store (e.g. fr-par)"
  type        = string
}

variable "s3_replica_endpoint" {
  description = "S3 endpoint of the REPLICA/backup store. Prod: a different provider (e.g. OVH https://s3.gra.io.cloud.ovh.net); task cluster-up refuses before spending when a prod cluster with no state object yet has its replica on the primary's endpoint or cloud (scripts/internal/ensure-buckets.sh --preflight). Dev: may reuse the primary endpoint."
  type        = string
  # No validation block on purpose: it also runs on every plan and destroy, so
  # a deployed cluster that breaks the rule could no longer be torn down.
}

variable "s3_replica_region" {
  description = "S3 region of the replica/backup store (prod: e.g. gra)"
  type        = string
}

# ==============================================================================
# Outscale API creds (fed by the Taskfile from the resolved S3/API keys; for
# Outscale the API key == the OOS key). Empty when not deploying Outscale.
# ==============================================================================

variable "outscale_access_key_id" {
  description = "Outscale API access key (Taskfile sets TF_VAR_outscale_access_key_id). Empty = use OSC_* env."
  type        = string
  default     = ""
  sensitive   = true
}

variable "outscale_secret_key_id" {
  description = "Outscale API secret key."
  type        = string
  default     = ""
  sensitive   = true
}

# ==============================================================================
# Emulated cloud (Feint) — see docs/emulated-cloud.md
# ==============================================================================

variable "emulator_api_url" {
  description = "Base URL of a local Feint emulator to point the Scaleway and Outscale APIs at (e.g. http://127.0.0.1:4599). Empty = the real cloud."
  type        = string
  default     = ""

  # Loopback or nothing. A remote value here would not be a misconfiguration but
  # an apply against somebody's account, which is the one failure this switch
  # must make impossible.
  validation {
    condition     = var.emulator_api_url == "" || can(regex("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]+$", var.emulator_api_url))
    error_message = "emulator_api_url must be empty or a loopback URL (http://127.0.0.1:<port>): it exists to reach a local emulator, never a remote endpoint."
  }
}

variable "talos_installer_schematic_id" {
  description = <<-EOT
    Image Factory schematic ID for the installer the machine config names, so a
    node keeps its system extensions (iscsi-tools, util-linux-tools) across
    `talosctl upgrade`. qemu-guest-agent was REMOVED on 2026-08-19: it never
    started on OVH or Outscale, and an extension that never starts blocks the boot
    sequence, so Talos never confirms the upgrade and the next reboot reverts the
    node — see talos-image/schematic.yaml. MUST match what
    `talos-image/schematic.yaml` resolves to — `talos-image.sh` refuses to build
    when the two disagree, which is the only place that can catch drift without
    a network call on every plan.

    Recompute after editing that file:
      curl -sf -X POST -H 'Content-Type: application/yaml' \
        --data-binary @infrastructure/opentofu/talos-image/schematic.yaml \
        https://factory.talos.dev/schematics
  EOT
  type        = string
  default     = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"
}

variable "restrict_inter_node" {
  description = <<-EOT
    OVH and Outscale only (Scaleway already lists its ports; Proxmox and local have no security group).
    false (default): the cluster group keeps its all-protocol rule between members. true: replaced by the
    explicit port list shared with Scaleway and the Talos rules (ANSSI PA-022 R17/R20, batch B24 stage 1).
    Rules and caveats: the variable of the same name in modules/providers/ovh/variables.tf.
  EOT
  type        = bool
  default     = false
}

variable "node_firewall_mode" {
  description = <<-EOT
    Talos ingress firewall of the nodes (ANSSI PA-022 R17/R20, batch B24 stage 2). "off" (default)
    renders nothing: the generated configs are byte-identical. "port_allowlist" appends one NetworkRuleConfig
    per flow of the shared port list plus NetworkDefaultActionConfig ingress: accept. A rule is a per-port
    allow-list even with that default: each listed port ACCEPTS ONLY THE LISTED SOURCES (node_firewall) and
    drops the rest, ports that are not listed stay open, and a source missing from node_firewall is cut off
    (a broken cluster: not inert, measured on live nodes, lab 11). No mode with a blocking default action
    exists. Rehearse on a throwaway cluster (docs/network.md section 6, LAB-CHECKLIST B24). Needs
    node_firewall.node_cidrs.
  EOT
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "port_allowlist"], var.node_firewall_mode)
    error_message = "node_firewall_mode must be \"off\" or \"port_allowlist\" (no mode with a blocking default action exists)."
  }
}

variable "node_firewall" {
  description = <<-EOT
    Source ranges of the Talos ingress rules, used only when node_firewall_mode is not "off".
      node_cidrs     the node subnet(s) (required): see docs/network.md for each provider's value
      bastion_cidrs  the bastion subnet (default: none; the bastion then reaches apid only if it is in node_cidrs)
      pod_cidrs      the pod network (default 10.244.0.0/16, Talos's default)
      lb_cidrs       load balancer carrier/backend sources (default 100.64.0.0/10)
    Subnets, never node addresses, so a replaced node needs no change.
  EOT
  type = object({
    node_cidrs    = optional(list(string), [])
    bastion_cidrs = optional(list(string), [])
    pod_cidrs     = optional(list(string), ["10.244.0.0/16"])
    lb_cidrs      = optional(list(string), ["100.64.0.0/10"])
  })
  default = {}
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
