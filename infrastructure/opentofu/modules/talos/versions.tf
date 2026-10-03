terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Bounded ceiling so a consumer with a loose root can't drift onto 0.12.x,
      # which the module's patches cannot drive on Talos 1.14 (#241). Lower bound
      # wide enough for the cluster root (~> 0.11.0) and the local stack (0.11.0).
      version = ">= 0.7.0, < 0.12.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
