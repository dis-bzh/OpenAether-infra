terraform {
  required_version = ">= 1.11.0"

  # No backend: this root creates nothing outside a local emulator, so its state
  # is disposable by construction (same reasoning as opentofu-local).
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      # Tracks the real lanes. No cap: Feint serves the detach a private NIC
      # destroy calls from 0.14.0 (#179).
      version = "~> 2.68"
    }
    outscale = {
      source  = "outscale/outscale"
      version = ">= 1.7.0"
    }
  }
}
