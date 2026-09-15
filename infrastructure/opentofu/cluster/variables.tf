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
  default = "v1.13.9"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  # renovate: datasource=github-releases depName=kubernetes/kubernetes
  default = "v1.37.0"
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
      availability_zones  - OpenStack AZ list (default ["nova"])

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
    root_disk_gb            = optional(number, 20)
    control_plane_ip_offset = optional(number, 10)
    worker_ip_offset        = optional(number, 20)
    nameservers             = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    enable_bastion          = optional(bool, false)
    host_public_ip          = optional(string)
    host_ssh_user           = optional(string, "root")
  }))
  default = {}
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
  description = "SSH public keys per provider. Key = provider name (scaleway/ovh/outscale), value = list of SSH public keys. Add a key to grant multi-admin access without changing the list structure."
  type        = map(list(string))
  default     = {}
}

# ==============================================================================
# GitOps / Bootstrap
# ==============================================================================

variable "git_repo_url" {
  description = "Git repository URL for the Flux GitRepository source (OpenAether-apps)"
  type        = string
  default     = "https://github.com/dis-bzh/OpenAether-apps.git"
}

# A release of this repo has to identify a release of the platform it deploys.
# This was hardcoded to the `main` branch: a commit in OpenAether-apps could then
# change a running cluster within the reconcile interval, and no version of this
# repo named a deployable system. `refs/tags/…` by default, and a branch stays
# available for testing — which is also how two managements avoid sharing
# apps/clusters (see OpenAether-apps/README.md).
# The DEFAULT tracks a branch and the EXAMPLES pin a tag, deliberately in that
# order. A tag default makes the repository undeployable between releases —
# you cannot test the ref mechanism until the tag exists, and after it exists
# main still deploys the previous platform. Development tracks main; a user
# copies an example and gets a pinned pair.
variable "git_ref" {
  description = "Git ref OpenAether-apps is tracked at, fully qualified: refs/heads/<branch> to develop, refs/tags/<version> to deploy"
  type        = string
  default     = "refs/heads/main"

  validation {
    condition     = can(regex("^refs/(heads|tags)/.+$", var.git_ref))
    error_message = "git_ref must be fully qualified: refs/tags/<version> or refs/heads/<branch>."
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

variable "deploy_flux" {
  description = <<-EOT
    Install Flux on the cluster. FALSE by default: 0.1.0 is infrastructure only —
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
  description = "S3 endpoint of the REPLICA/backup store. Prod: a different provider (e.g. OVH https://s3.gra.io.cloud.ovh.net); dev: reuse the primary endpoint."
  type        = string
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
