# ==============================================================================
# Emulated cloud (Feint) — create/read/update/delete against a local emulator.
#
# WHY A SEPARATE ROOT. The cluster root cannot apply here: it always builds a
# Scaleway public gateway and IPAM reservations, and Outscale security groups,
# public IPs, route tables and load balancers — none of which the emulator
# serves. This root carries the same SHAPES over the subset it does serve, so a
# real apply/destroy cycle runs with no account. Coverage and the exact gaps:
# docs/emulated-cloud.md.
#
# One provider per apply, like the cluster root — target_provider selects it.
# ==============================================================================

locals {
  scaleway_active = var.target_provider == "scaleway" ? 1 : 0
  outscale_active = var.target_provider == "outscale" ? 1 : 0

  # Well-formed and meaningless: the emulator checks the shape of a credential,
  # never its value. Pinned so no provider can find a real one instead.
  bastion_ssh_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIr6pEFlAFO3YU0DNW/r8SkpjdbptN9ockkO2BtIolSD feint@emulated"]

  # The production bastion cloud-init, rendered from the same shared template the
  # provider modules use — so a template variable added there and not here fails
  # this lane instead of a real deploy.
  bastion_cloud_init = templatefile("${path.module}/../opentofu/modules/providers/_shared/bastion-cloud-init.yaml.tftpl", {
    bastion_user      = "bastion"
    ssh_keys          = local.bastion_ssh_keys
    private_cidr      = var.private_cidr
    extra_packages    = []
    extra_write_files = []
    extra_runcmd      = []
    ssh_ca_public_key = ""
    ssh_ca_principals = ""
    baseline          = { enabled = false, audit_logging = true, restrict_ssh_source = false, time_servers = [], revoked_keys = [] }
    admin_ip          = []
  })
}

provider "scaleway" {
  api_url         = var.endpoint
  access_key      = "SCWXXXXXXXXXXXXXXXXX"
  secret_key      = "11111111-1111-1111-1111-111111111111"
  project_id      = "11111111-1111-1111-1111-111111111111"
  organization_id = "11111111-1111-1111-1111-111111111111"
  region          = "fr-par"
  zone            = "fr-par-1"
}

provider "outscale" {
  access_key_id = "AAAAAAAAAAAAAAAAAAAA"
  secret_key_id = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

  # The version segment belongs to the value: without it the provider retries
  # with backoff for six minutes and reports a timeout instead of a bad address.
  api {
    endpoint = "${var.endpoint}/api/v1"
    region   = "eu-west-2"
  }
}
