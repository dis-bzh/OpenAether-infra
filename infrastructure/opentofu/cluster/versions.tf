terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Exact: a provider release can change the rendered text, and the module's patches were
      # checked against 0.12.0's alone (#241). Renovate's PR for a release is labelled needs-real-run.
      version = "0.12.0"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.68"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    outscale = {
      source = "outscale/outscale"
      # 1.x for the api{} block (endpoint + region), which replaces the
      # deprecated top-level arguments and is what the emulator lane redirects.
      version = "~> 1.8"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
