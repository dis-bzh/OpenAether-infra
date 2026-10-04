terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Bounded ceiling: a new minor can render a new Talos contract, and its first run
      # on a real node is what shows the patches still fit (#241).
      version = ">= 0.7.0, < 0.13.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
