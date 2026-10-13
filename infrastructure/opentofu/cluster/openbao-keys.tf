# ==============================================================================
# OpenBao recovery shares (variables.tf: openbao_recovery_pgp_keys)
#
# The ConfigMap built from these is what makes the OpenBao bootstrap a PRODUCTION one (see OpenAether-apps,
# foundation/vault). Without it the bootstrap falls back to development mode, which keeps one plaintext recovery
# share in a Secret: fine for a lab, not for a cluster that holds anything. So a prod cluster that deploys Flux
# refuses to plan without the keys, instead of discovering the fallback in a Secret afterwards.
# ==============================================================================

locals {
  openbao_pgp_keys  = [for k in var.openbao_recovery_pgp_keys : trimspace(k)]
  openbao_threshold = var.openbao_recovery_threshold != null ? var.openbao_recovery_threshold : floor(length(local.openbao_pgp_keys) / 2) + 1
}

resource "terraform_data" "openbao_recovery_guard" {
  input = length(local.openbao_pgp_keys)

  lifecycle {
    precondition {
      condition     = !(var.deploy_flux && var.environment == "prod") || length(local.openbao_pgp_keys) >= 3
      error_message = "environment = \"prod\" with deploy_flux = true needs openbao_recovery_pgp_keys (at least 3 operators' PGP public keys): without them OpenBao bootstraps in DEVELOPMENT mode and keeps a plaintext recovery share in a Secret. Export each key with `gpg --export <id> | base64 -w0`."
    }
    precondition {
      condition     = length(local.openbao_pgp_keys) == 0 || local.openbao_threshold <= length(local.openbao_pgp_keys)
      error_message = "openbao_recovery_threshold (${local.openbao_threshold}) is larger than the number of openbao_recovery_pgp_keys (${length(local.openbao_pgp_keys)}): no quorum could ever form."
    }
  }
}
