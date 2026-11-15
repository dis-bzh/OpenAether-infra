terraform {
  required_version = ">= 1.11.0"

  # No backend: this root creates nothing outside a local emulator, so its state
  # is disposable by construction (same reasoning as opentofu-local).
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      # Same constraints as the cluster root, and the committed lock holds the same versions
      # (check-version-drift.sh): the emulated lane exercises the binary the real one runs.
      version = "~> 2.68"
    }
    outscale = {
      source  = "outscale/outscale"
      version = "~> 1.8"
    }
  }
}
