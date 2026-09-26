terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Ceiling below the next minor: 0.12 swapped the Talos SDK and the default
      # installer, so a new minor gets read before a loose root can select it.
      # Both roots select 0.12.x, the first stable line with the
      # siderolabs/terraform-provider-talos#352 fix.
      version = ">= 0.7.0, < 0.13.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
