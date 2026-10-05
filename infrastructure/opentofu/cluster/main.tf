# ==============================================================================
# Providers
# ==============================================================================

# Emulated-cloud lane (docs/emulated-cloud.md). Well-formed but meaningless
# credentials: Feint checks their shape and never their value, and pinning them
# is what stops a provider from finding real ones elsewhere.
locals {
  emulated = var.emulator_api_url != ""
  emulator_creds = {
    scw_access_key = "SCWXXXXXXXXXXXXXXXXX"
    scw_secret_key = "11111111-1111-1111-1111-111111111111"
    scw_project_id = "11111111-1111-1111-1111-111111111111"
    osc_access_key = "AAAAAAAAAAAAAAAAAAAA"
    osc_secret_key = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  }
}

provider "talos" {}

# Scaleway takes everything from the SCW_* environment for a real deploy. Under
# the emulator every field is pinned instead: an unset credential does not fail,
# it falls back to ~/.config/scw/config.yaml and drives a paying account.
provider "scaleway" {
  api_url         = local.emulated ? var.emulator_api_url : null
  access_key      = local.emulated ? local.emulator_creds.scw_access_key : null
  secret_key      = local.emulated ? local.emulator_creds.scw_secret_key : null
  project_id      = local.emulated ? local.emulator_creds.scw_project_id : null
  organization_id = local.emulated ? local.emulator_creds.scw_project_id : null
}

# Only the OVH module uses OpenStack. When OVH is not the active provider we feed
# a placeholder auth_url so a Scaleway/Outscale-only apply doesn't require OVH
# creds; for an OVH deploy auth_url=null falls back to the OS_AUTH_URL env var.
provider "openstack" {
  auth_url = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? null : "https://auth.placeholder.invalid/v3"
}

# Outscale API creds fed explicitly (Taskfile sets TF_VAR_outscale_* from the
# resolved S3/API keys) so auth doesn't depend on the exact OSC_* env var names.
# Empty/null when not deploying Outscale → no effect on Scaleway/OVH applies.
provider "outscale" {
  access_key_id = local.emulated ? local.emulator_creds.osc_access_key : (var.outscale_access_key_id != "" ? var.outscale_access_key_id : null)
  secret_key_id = local.emulated ? local.emulator_creds.osc_secret_key : (var.outscale_secret_key_id != "" ? var.outscale_secret_key_id : null)

  # region and the api{} block are mutually exclusive — only one may be set.
  # #77 asked whether to move real runs onto api{} too, which would mean
  # hardcoding Outscale's DNS ourselves. Decided: no. outscale/terraform-provider-outscale
  # reverted the top-level `region` deprecation in its own PR #817 (shipped in
  # 1.8.0, pinned here) — real commands no longer warn, so there is nothing left
  # to build the URL to avoid.
  region = local.emulated ? null : (local.active_provider == "outscale" ? local.osc_dist.region : null)

  # `endpoint` carries the whole API path, version segment included. Without it
  # the provider retries with backoff for six minutes and reports a timeout,
  # which reads like a slow server rather than a misdirected client.
  dynamic "api" {
    for_each = local.emulated ? [1] : []
    content {
      endpoint = "${var.emulator_api_url}/api/v1"
      region   = local.osc_dist.region
    }
  }
}

# Proxmox (bpg) reads creds from the environment for a real Proxmox deploy:
#   PROXMOX_VE_ENDPOINT=https://<host>:8006/
#   PROXMOX_VE_API_TOKEN=<user>@<realm>!<tokenid>=<secret>
#   PROXMOX_VE_INSECURE=true   # self-signed 8006 cert
# bpg validates the endpoint AND credentials EAGERLY at plan time, even when the
# proxmox module is inactive (count = 0) — so an empty block breaks every
# Scaleway/OVH/Outscale apply that carries no PROXMOX_* creds. When Proxmox is
# inactive we feed benign localhost placeholders that are never contacted (no
# proxmox resource → no API call); when it IS the active provider these are null,
# so bpg falls back to the PROXMOX_VE_* env vars above — same as before. (Mirrors
# the openstack/outscale blocks, which gate the same way.)
provider "proxmox" {
  endpoint  = local.active_provider == "proxmox" ? null : "https://127.0.0.1:8006/"
  api_token = local.active_provider == "proxmox" ? null : "placeholder@pam!inactive=00000000-0000-0000-0000-000000000000"
  insecure  = local.active_provider == "proxmox" ? null : true
}

# Backups go through the AWS CLI (scripts/ops/backup-artifacts.sh + backup-state.sh),
# not a Terraform provider — the artifacts/state are streamed to S3-compatible
# stores with per-call creds/endpoints (primary + cross-provider replica), which
# the aws provider can't express cleanly. So there is intentionally no aws provider.

# ==============================================================================
# Provider Distribution Locals
# Extract per-provider node counts with safe defaults.
# ==============================================================================

locals {
  scw_dist = merge({
    control_planes     = 0
    workers            = 0
    region             = null
    zone               = null
    instance_type      = null
    image_id           = null
    image_name         = null
    zones              = null
    availability_zones = null
    k8s_lb_mode        = "managed"
  }, try(var.node_distribution["scaleway"], {}))

  ovh_dist = merge({
    control_planes     = 0
    workers            = 0
    region             = "EU-WEST-PAR"
    flavor_name        = "b3-8"
    image_id           = null
    image_name         = null
    network_name       = "Ext-Net"
    availability_zones = ["eu-west-par-a", "eu-west-par-b", "eu-west-par-c"]
    bastion_image_id   = "Ubuntu 22.04"
    k8s_lb_mode        = "managed"
  }, try(var.node_distribution["ovh"], {}))

  osc_dist = merge({
    control_planes     = 0
    workers            = 0
    region             = "eu-west-2"
    instance_type      = "tinav5.c2r4p1"
    image_id           = null
    image_name         = null
    availability_zones = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    bastion_image_id   = null
    k8s_lb_mode        = "managed"
  }, try(var.node_distribution["outscale"], {}))

  # Proxmox (single host or multi-host PVE cluster). VMs round-robined across
  # node_names via element(). 1 entry = non-HA, 3 entries = true HA.
  pmx_dist = merge({
    control_planes          = 0
    workers                 = 0
    node_names              = null
    datastore_id            = "local-zfs"
    iso_datastore_id        = "local"
    talos_image_file_id     = null
    network_bridge          = "vmbr1"
    network_cidr            = "10.0.0.0/24"
    gateway_ip              = null
    apiserver_vip           = null
    apiserver_vip_interface = "eth0"
    cpu_cores               = 4
    memory_mb               = 8192
    root_disk_gb            = 20
    control_plane_ip_offset = 10
    worker_ip_offset        = 20
    nameservers             = ["1.1.1.1", "8.8.8.8"]
    enable_bastion          = false
    host_public_ip          = null
    host_ssh_user           = "root"
  }, try(var.node_distribution["proxmox"], {}))
}

# ==============================================================================
# Image lookup convention — when a provider's image_id/image_name/
# talos_image_file_id is left unset, fall back to the exact name the
# talos-image root publishes/downloads under (see talos-image/main.tf's
# local.image_name and modules/talos-image/proxmox), so the operator rarely
# needs to hand-copy an ID between the two roots. An explicit value always
# wins (coalesce picks the first non-null). Computed here rather than as a
# merge() default in *_dist above: node_distribution's map(object) type fills
# every unset field with null (not "absent"), which would silently clobber a
# literal default placed inside merge() — see the comment on pmx_dist's
# host-specific keys above.
# ==============================================================================

locals {
  scw_image_name = coalesce(local.scw_dist.image_name, "talos-scaleway-amd64-${var.talos_version}")
  ovh_image_name = coalesce(local.ovh_dist.image_name, "talos-ovh-amd64-${var.talos_version}")
  osc_image_name = coalesce(local.osc_dist.image_name, "talos-outscale-amd64-${var.talos_version}")

  pmx_talos_image_file_id = coalesce(
    local.pmx_dist.talos_image_file_id,
    "${local.pmx_dist.iso_datastore_id}:iso/talos-${trimprefix(var.talos_version, "v")}-nocloud-amd64.img"
  )
}

# ==============================================================================
# Validation — Only one provider can be active per cluster apply
# Note: local Docker testing lives in ../opentofu-local (not a cloud provider).
# ==============================================================================

locals {
  active_providers = compact([
    (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? "scaleway" : null,
    (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? "ovh" : null,
    (local.osc_dist.control_planes + local.osc_dist.workers) > 0 ? "outscale" : null,
    (local.pmx_dist.control_planes + local.pmx_dist.workers) > 0 ? "proxmox" : null,
  ])
}

check "single_provider_per_cluster" {
  assert {
    condition     = length(local.active_providers) <= 1
    error_message = "Only one provider can be active per cluster apply. Use separate env files (envs/workload-ovh.tfvars) for each cluster."
  }
}

# ==============================================================================
# Scaleway Infrastructure
# ==============================================================================

module "scw" {
  source = "../modules/providers/scw"

  count = (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.scw_dist.control_planes
  worker_count        = local.scw_dist.workers

  image_id         = local.scw_dist.image_id
  image_name       = local.scw_image_name
  zone             = local.scw_dist.zone
  region           = local.scw_dist.region
  instance_type    = local.scw_dist.instance_type
  additional_zones = local.scw_dist.zones != null ? local.scw_dist.zones : ["fr-par-1", "fr-par-2", "fr-par-3"]
  k8s_lb_mode      = local.scw_dist.k8s_lb_mode
  deploy_app_lb    = var.deploy_app_lb

  # HTTPS /readyz check on the API load balancer; needs apiserver_health_endpoints on the control planes first.
  k8s_lb_health_https = local.lb_health_https

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "scaleway", [])
}

# ==============================================================================
# OVH / OpenStack Infrastructure
# ==============================================================================

module "ovh" {
  source = "../modules/providers/ovh"

  count = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.ovh_dist.control_planes
  worker_count        = local.ovh_dist.workers

  region             = local.ovh_dist.region
  flavor_name        = local.ovh_dist.flavor_name
  image_id           = local.ovh_dist.image_id
  image_name         = local.ovh_image_name
  network_name       = local.ovh_dist.network_name
  availability_zones = local.ovh_dist.availability_zones
  bastion_image_id   = local.ovh_dist.bastion_image_id
  k8s_lb_mode        = local.ovh_dist.k8s_lb_mode
  deploy_app_lb      = var.deploy_app_lb

  # HTTPS /readyz check on the API load balancer; needs apiserver_health_endpoints on the control planes first.
  k8s_lb_health_https = local.lb_health_https

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "ovh", [])
}

# ==============================================================================
# Outscale Infrastructure
# ==============================================================================

module "outscale" {
  source = "../modules/providers/outscale"

  count = (local.osc_dist.control_planes + local.osc_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.osc_dist.control_planes
  worker_count        = local.osc_dist.workers

  instance_type      = local.osc_dist.instance_type
  image_id           = local.osc_dist.image_id
  image_name         = local.osc_image_name
  availability_zones = local.osc_dist.availability_zones
  bastion_image_id   = local.osc_dist.bastion_image_id
  k8s_lb_mode        = local.osc_dist.k8s_lb_mode
  deploy_app_lb      = var.deploy_app_lb

  # HTTPS /readyz check on the API load balancer; needs apiserver_health_endpoints on the control planes first.
  k8s_lb_health_https = local.lb_health_https

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "outscale", [])
}

# ==============================================================================
# Proxmox Infrastructure (single host or multi-host PVE cluster)
# No managed LB/NAT/SG: k8s_lb_ip = Talos VIP, host-as-bastion by default.
# ==============================================================================

module "proxmox" {
  source = "../modules/providers/proxmox"

  count = (local.pmx_dist.control_planes + local.pmx_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.pmx_dist.control_planes
  worker_count        = local.pmx_dist.workers

  node_names          = local.pmx_dist.node_names
  datastore_id        = local.pmx_dist.datastore_id
  iso_datastore_id    = local.pmx_dist.iso_datastore_id
  talos_image_file_id = local.pmx_talos_image_file_id

  network_bridge          = local.pmx_dist.network_bridge
  network_cidr            = local.pmx_dist.network_cidr
  gateway_ip              = local.pmx_dist.gateway_ip
  apiserver_vip           = local.pmx_dist.apiserver_vip
  control_plane_ip_offset = local.pmx_dist.control_plane_ip_offset
  worker_ip_offset        = local.pmx_dist.worker_ip_offset
  nameservers             = local.pmx_dist.nameservers

  cpu_cores    = local.pmx_dist.cpu_cores
  memory_mb    = local.pmx_dist.memory_mb
  root_disk_gb = local.pmx_dist.root_disk_gb

  enable_bastion = local.pmx_dist.enable_bastion
  host_public_ip = local.pmx_dist.host_public_ip
  host_ssh_user  = local.pmx_dist.host_ssh_user

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "proxmox", [])
}

# ==============================================================================
# Provider-Agnostic Junction Point
#
# CONTRACT between the cloud provider layer and the Talos layer.
# coalesce() selects the first non-null value across all providers.
# Since only one provider is active per apply, exactly one will have a value.
#
# one(), never try(): try() swallows "this output does not exist" exactly like
# "this provider is inactive". A module that stops honouring the contract then
# validates, applies, and yields null — the endpoint falls back to the literal
# below and Talos fails much later, on a cluster that costs money. one() returns
# null at count = 0 and REFUSES an attribute the module does not declare.
#
# See: modules/providers/provider-contract.md
# ==============================================================================

locals {
  k8s_lb_ip = coalesce(
    one(module.scw[*].k8s_lb_ip),
    one(module.ovh[*].k8s_lb_ip),
    one(module.outscale[*].k8s_lb_ip),
    one(module.proxmox[*].k8s_lb_ip),
    "127.0.0.1"
  )

  bastion_ip = coalesce(
    one(module.scw[*].bastion_ip),
    one(module.ovh[*].bastion_ip),
    one(module.outscale[*].bastion_ip),
    one(module.proxmox[*].bastion_ip),
    "<bastion-ip>"
  )

  # SSH user for the bastion tunnels, by provider:
  #   scaleway, ovh, outscale — a dedicated unprivileged "bastion" user via cloud-init
  #   proxmox  — the module's own answer: host_ssh_user (default root) for
  #              host-as-bastion, "ubuntu" for the VM bastion it creates. Read
  #              from the module, never re-derived here (they drifted apart).
  bastion_user = lookup({
    scaleway = "bastion"
    ovh      = "bastion" # NOT the image's default user (see ovh/bastion.tf)
    outscale = "bastion" # NOT the image's default user (see outscale/bastion.tf)
    proxmox  = one(module.proxmox[*].bastion_user)
  }, local.active_provider, "ubuntu")

  # k8s_lb_mode only applies to scaleway/ovh (outscale rejects "vip" via its
  # own variable validation; proxmox has no LB to begin with — see below).
  active_k8s_lb_mode = lookup({
    scaleway = local.scw_dist.k8s_lb_mode
    ovh      = local.ovh_dist.k8s_lb_mode
  }, local.active_provider, "managed")

  # Proxmox always wires its own VIP (its k8s_lb_ip output IS var.apiserver_vip
  # — see modules/providers/proxmox/outputs.tf). Clouds only get one in
  # k8s_lb_mode = "vip", where k8s_lb_ip already resolves to the reserved
  # private address instead of the managed LB (see each provider's outputs.tf).
  apiserver_vip = local.pmx_dist.apiserver_vip != null ? local.pmx_dist.apiserver_vip : (
    local.active_k8s_lb_mode == "vip" ? local.k8s_lb_ip : null
  )
  apiserver_vip_interface = local.active_provider == "proxmox" ? local.pmx_dist.apiserver_vip_interface : "eth0"

  control_plane_ips = coalesce(
    length(coalesce(one(module.scw[*].control_plane_private_ips), [])) > 0 ? module.scw[0].control_plane_private_ips : null,
    length(coalesce(one(module.ovh[*].control_plane_private_ips), [])) > 0 ? module.ovh[0].control_plane_private_ips : null,
    length(coalesce(one(module.outscale[*].control_plane_private_ips), [])) > 0 ? module.outscale[0].control_plane_private_ips : null,
    length(coalesce(one(module.proxmox[*].control_plane_private_ips), [])) > 0 ? module.proxmox[0].control_plane_private_ips : null,
    []
  )

  # Only the active provider's list is non-empty, so concat() picks it without
  # the length test above.
  control_plane_zones = concat(
    coalesce(one(module.scw[*].control_plane_zones), []),
    coalesce(one(module.ovh[*].control_plane_zones), []),
    coalesce(one(module.outscale[*].control_plane_zones), []),
    coalesce(one(module.proxmox[*].control_plane_zones), []),
  )

  worker_ips = coalesce(
    length(coalesce(one(module.scw[*].worker_private_ips), [])) > 0 ? module.scw[0].worker_private_ips : null,
    length(coalesce(one(module.ovh[*].worker_private_ips), [])) > 0 ? module.ovh[0].worker_private_ips : null,
    length(coalesce(one(module.outscale[*].worker_private_ips), [])) > 0 ? module.outscale[0].worker_private_ips : null,
    length(coalesce(one(module.proxmox[*].worker_private_ips), [])) > 0 ? module.proxmox[0].worker_private_ips : null,
    []
  )

  active_provider = length(local.active_providers) > 0 ? local.active_providers[0] : "none"

  # Planned node counts from node_distribution — known at PLAN time, unlike the
  # private IPs above (which are unknown until the VMs exist). Use these to gate
  # count/for_each so the plan can be computed.
  total_control_planes = local.scw_dist.control_planes + local.ovh_dist.control_planes + local.osc_dist.control_planes + local.pmx_dist.control_planes
  total_workers        = local.scw_dist.workers + local.ovh_dist.workers + local.osc_dist.workers + local.pmx_dist.workers
}

# ==============================================================================
# Bootstrap Manifests — Loaded from static files
# Generate with: ./scripts/bootstrap/render-bootstrap-manifests.sh
# ==============================================================================

locals {
  cilium_manifest = var.cilium_manifest != null ? var.cilium_manifest : file("${path.module}/bootstrap-manifests/cilium.yaml")
  # deploy_flux=false yields "", which modules/talos already reads as "no Flux"
  # (main.tf:116) — the same path infrastructure/opentofu-local drives through
  # this very module on every `task local-up`. Locals only: no resource address
  # moves, so turning it off cannot replace a node.
  flux_manifest = var.deploy_flux ? (var.flux_manifest != null ? var.flux_manifest : file("${path.module}/bootstrap-manifests/flux-install.yaml")) : ""
  # Cluster identity, published as the `cluster-identity` ConfigMap (flux-system)
  # and consumed by the bricks that must distinguish themselves from ANOTHER
  # cluster — today the restic repositories, which share cross-provider buckets.
  # The provider is part of the identity: `cluster_name`/`environment` alone
  # read "openaether-dev" on all three clouds, so they distinguish nothing.
  cluster_id = "${var.cluster_name}-${var.environment}-${local.active_provider}"

  # Emptied by the SAME switch. modules/talos:116 only tests flux_manifest, so a
  # half-empty pair would inject a manifest with no content — asymmetric and
  # untested. One variable governs both, and the template is not even rendered
  # when Flux is off.
  flux_bootstrap_manifest = !var.deploy_flux ? "" : var.flux_bootstrap_manifest != null ? var.flux_bootstrap_manifest : templatefile("${path.module}/bootstrap-manifests/flux-bootstrap.yaml.tftpl", {
    namespace    = var.flux_namespace
    git_repo_url = var.git_repo_url
    git_ref      = var.git_ref
    cluster_role = var.cluster_role
    cluster_id   = local.cluster_id
    # Destination for Longhorn volume backups. The full URL is assembled HERE:
    # on the manifest side `value:` is a plain string and Flux substitution
    # cannot concatenate conditionally (no `${x:+y}`).
    backup_target_url = "s3://${local.backup_data_bucket}@${var.s3_primary_region}/"
    # CNPG (PITR) expects the bucket and the endpoint SEPARATELY, in a different
    # format from Longhorn — hence three keys rather than one.
    backup_s3_bucket   = local.backup_data_bucket
    backup_s3_endpoint = var.s3_primary_endpoint
  })
}

# ==============================================================================
# EXPERIMENTAL — single-apply SSH tunnels (var.auto_tunnels)
#
# Opens the tunnels itself between the provider module and modules/talos, in
# the SAME apply, instead of the operator running `task bootstrap-phase2`
# separately between two `tofu apply`s. Ordering falls out of the reference
# graph: local.bastion_ip/control_plane_ips/worker_ips are unknown until the
# provider module's VMs exist, so this resource (and, via depends_on,
# module.talos after it) can't evaluate/run until they do.
#
# Default off (var.auto_tunnels = false) — the documented two-phase flow
# remains the supported path; this is not exercised against a real host yet.
# ==============================================================================

resource "terraform_data" "talos_tunnels" {
  count = var.talos_bootstrap && var.auto_tunnels && local.total_control_planes > 0 ? 1 : 0

  triggers_replace = [
    local.bastion_ip,
    local.bastion_user,
    join(",", local.control_plane_ips),
    join(",", local.worker_ips),
  ]

  provisioner "local-exec" {
    command = join(" ", concat(
      [
        "${path.module}/../../../scripts/bootstrap/talos-tunnels.sh", "open-direct",
        "--bastion", local.bastion_ip,
        "--user", local.bastion_user,
        "--cps", join(",", local.control_plane_ips),
        "--key", var.ssh_key_path,
      ],
      length(local.worker_ips) > 0 ? ["--workers", join(",", local.worker_ips)] : []
    ))
  }
}

# ==============================================================================
# Talos Cluster (secrets, config, bootstrap, kubeconfig)
# ==============================================================================

module "talos" {
  source = "../modules/talos"

  cluster_name       = "${var.cluster_name}-${var.environment}"
  cluster_endpoint   = "https://${local.k8s_lb_ip}:6443"
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  # Container mode has no installer and no extensions; everywhere else the
  # installer must carry the schematic or a reinstall silently drops them.
  installer_schematic_id = local.active_provider == "local" ? "" : var.talos_installer_schematic_id

  # Phase 2 apply sets talos_bootstrap = true. Use the planned counts (known at
  # plan) rather than length(local.*_ips) (unknown until the VMs exist), so the
  # talos module's per-node count/for_each can be computed in Phase 2.
  control_plane_count = var.talos_bootstrap ? local.total_control_planes : 0
  worker_count        = var.talos_bootstrap ? local.total_workers : 0

  k8s_lb_ip         = local.k8s_lb_ip
  control_plane_ips = local.control_plane_ips
  worker_ips        = local.worker_ips

  # k8s_api_health: anonymous /readyz, /livez, /healthz. k8s_api_shutdown_delay: the apiserver delays its stop.
  apiserver_health_endpoints = local.apiserver_health_endpoints
  apiserver_shutdown_delay   = var.k8s_api_shutdown_delay == "" ? null : var.k8s_api_shutdown_delay

  # Proxmox always wires a VIP; scw/ovh only in k8s_lb_mode = "vip"; outscale
  # and local never do (both resolve to null — see the locals above).
  apiserver_vip           = local.apiserver_vip
  apiserver_vip_interface = local.apiserver_vip_interface

  skip_port_ready_wait    = var.skip_port_ready_wait
  secrets_prevent_destroy = var.secrets_prevent_destroy

  # The health data source's Kubernetes-level checks connect to the cluster
  # endpoint directly. In managed mode that's a public LB (reachable, so keep
  # them), but in vip mode / Proxmox it's a PRIVATE Talos VIP that is only
  # reachable through the bastion SSH tunnel — which the data source's K8s client
  # can't use (unlike the Talos API, which we already tunnel via
  # control_plane_endpoints). Skip only the K8s-level checks there so
  # `talos_cluster_health` completes instead of hanging on the private endpoint;
  # the etcd/Talos checks still validate the cluster through the tunnel. Same
  # rationale as local Docker (see the module's skip_kubernetes_health_checks).
  skip_kubernetes_health_checks = local.apiserver_vip != null
  skip_health_check             = var.skip_health_check

  # Phase 2 reaches the private nodes through per-node SSH tunnels on localhost
  # (see the `instructions` output). `endpoint` is where the provider connects;
  # node identity stays the private IP. CPs: 127.0.0.1:50000+i, workers: :50100+i,
  # both shifted by talos_tunnel_port_offset when a second cluster is being
  # brought up from the same workstation.
  control_plane_endpoints = var.talos_bootstrap ? [for i in range(local.total_control_planes) : "127.0.0.1:${50000 + var.talos_tunnel_port_offset + i}"] : []
  worker_endpoints        = var.talos_bootstrap ? [for i in range(local.total_workers) : "127.0.0.1:${50100 + var.talos_tunnel_port_offset + i}"] : []

  # Bootstrap manifests — Cilium is always injected (CNI required),
  # Flux only on initial bootstrap (not on upgrades/DRP)
  bootstrap_manifests_enabled = var.talos_bootstrap
  cilium_manifest             = local.cilium_manifest
  flux_manifest               = local.flux_manifest
  flux_bootstrap_manifest     = local.flux_bootstrap_manifest

  # Dedicated worker data volumes (encrypted UserVolumeConfig). Empty on local.
  worker_storage = var.worker_storage

  node_nameservers      = var.node_nameservers
  node_dns_boot_timeout = var.node_dns_boot_timeout

  # The provider modules are DELIBERATELY not listed here. A module-level
  # depends_on makes every resource in this module depend on every resource in
  # those — which made per-node targeting impossible: `rolling-replace` could not
  # re-apply one node's machine config without dragging the whole provider module
  # into the plan, and with a Talos version bump leaving every instance ForceNew
  # that is a parallel replacement of all three control planes. Measured
  # 2026-08-12: it took a healthy cluster's etcd down.
  #
  # Ordering does not depend on it. The supported flow is two phases — `task
  # infra` builds the VMs with talos_bootstrap=false, which counts these
  # resources out entirely — and modules/talos then waits on its own
  # talos_port_ready_* guards before touching a node. terraform_data.talos_tunnels
  # stays, and only exists when auto_tunnels=true, so it orders the experimental
  # single-apply path and is a no-op otherwise.
  depends_on = [terraform_data.talos_tunnels]
}

# ==============================================================================
# Local config files (for operator convenience)
# ==============================================================================

resource "local_file" "talosconfig" {
  content         = module.talos.talosconfig
  filename        = "${path.root}/talosconfig"
  file_permission = "0600"
}

resource "local_file" "kubeconfig" {
  count           = local.total_control_planes > 0 ? 1 : 0
  content         = module.talos.kubeconfig_raw
  filename        = "${path.root}/kubeconfig"
  file_permission = "0600"
}
