provider "scaleway" {}

# Proxmox (bpg) reads creds from the environment (PROXMOX_VE_ENDPOINT/
# PROXMOX_VE_API_TOKEN/PROXMOX_VE_INSECURE) — same as cluster/main.tf. bpg
# validates the endpoint AND credentials EAGERLY at plan time, even when proxmox
# isn't the target (module.proxmox count = 0), so an empty block breaks
# scaleway/ovh/outscale image builds that carry no PROXMOX_* creds. Feed benign
# localhost placeholders (never contacted — no proxmox resource) unless proxmox
# IS the target, in which case they're null and bpg falls back to the env.
provider "proxmox" {
  endpoint  = var.target_provider == "proxmox" ? null : "https://127.0.0.1:8006/"
  api_token = var.target_provider == "proxmox" ? null : "placeholder@pam!inactive=00000000-0000-0000-0000-000000000000"
  insecure  = var.target_provider == "proxmox" ? null : true
}

# OpenStack (OVH). Placeholder auth_url unless we're building the OVH image, so a
# scaleway/outscale build doesn't require OS_* creds (auth_url=null falls back to
# the OS_AUTH_URL env var).
provider "openstack" {
  auth_url = var.target_provider == "ovh" ? null : "https://auth.placeholder.invalid/v3"
}

# Outscale API creds fed explicitly (same AK/SK as OOS) so it doesn't depend on
# the exact OSC_* env var names; null when not building Outscale → uses env.
provider "outscale" {
  access_key_id = var.outscale_access_key_id != "" ? var.outscale_access_key_id : null
  secret_key_id = var.outscale_secret_key_id != "" ? var.outscale_secret_key_id : null
  region        = var.target_provider == "outscale" ? var.region : null
}

# ==============================================================================
# Resolve the Image Factory schematic ID from schematic.yaml.
# POST is idempotent: Factory returns the existing ID for identical content.
# ==============================================================================
data "http" "schematic" {
  url    = "https://factory.talos.dev/schematics"
  method = "POST"

  request_headers = {
    "Content-Type" = "application/yaml"
  }

  request_body = file("${path.module}/schematic.yaml")

  # One failed request failed the whole plan, and with it `cluster-up`'s first step ("giving up after 1
  # attempt", seen on a release run). The POST is idempotent, so retrying is safe.
  retry {
    attempts     = 4
    min_delay_ms = 1000
    max_delay_ms = 10000
  }
}

locals {
  schematic_id = jsondecode(data.http.schematic.response_body).id

  # Must match the cluster envs/*.tfvars convention: talos-<platform>-<arch>-<version>
  image_name = "talos-${var.target_provider}-${var.arch}-${var.talos_version}"
  cache_dir  = abspath("${path.root}/.talos-image-cache")
}

# ==============================================================================
# Provider junction — only the selected provider's image module is active.
# ==============================================================================
module "scaleway" {
  source = "../modules/talos-image/scaleway"
  count  = var.target_provider == "scaleway" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  bucket_name   = var.import_bucket
  region        = var.region
  zones         = var.zones
  s3_endpoint   = var.s3_endpoint
  cache_dir     = local.cache_dir
}

# OVH: OpenStack Glance image, uploaded from the converted Factory artifact (no
# Object Storage staging needed — glance takes the local file directly).
module "ovh" {
  source = "../modules/talos-image/ovh"
  count  = var.target_provider == "ovh" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  cache_dir     = local.cache_dir
}

# Outscale: OOS upload -> snapshot import -> OMI.
module "outscale" {
  source = "../modules/talos-image/outscale"
  count  = var.target_provider == "outscale" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  bucket_name   = var.import_bucket
  region        = var.region
  s3_endpoint   = var.s3_endpoint
  cache_dir     = local.cache_dir
}

# Proxmox: server-side download straight onto each PVE host's datastore — no
# Object Storage staging, no local fetch/convert (unlike ovh/scaleway/outscale
# above). One download per node_names entry.
module "proxmox" {
  source = "../modules/talos-image/proxmox"
  count  = var.target_provider == "proxmox" ? 1 : 0

  talos_version    = var.talos_version
  arch             = var.arch
  schematic_id     = local.schematic_id
  node_names       = var.proxmox_node_names
  iso_datastore_id = var.proxmox_iso_datastore_id
}
