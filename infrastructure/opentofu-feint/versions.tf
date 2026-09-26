terraform {
  required_version = ">= 1.11.0"

  # No backend: this root creates nothing outside a local emulator, so its state
  # is disposable by construction (same reasoning as opentofu-local).
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      # Tracks the real lanes (~> 2.68), capped below 2.83.0: from that release
      # destroying a private NIC calls instance/v2alpha1 detach-private-network-interface,
      # which Feint answers 501, 0.13.0 included (#179). Drop the cap once it is served.
      version = "~> 2.68, < 2.83.0"
    }
    outscale = {
      source  = "outscale/outscale"
      version = ">= 1.7.0"
    }
  }
}
