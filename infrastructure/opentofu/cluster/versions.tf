terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # 0.12.0 is the first stable release carrying the fix for
      # siderolabs/terraform-provider-talos#352, the first-apply
      # "inconsistent final plan".
      version = "~> 0.12.0"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.68"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.53.0"
    }
    outscale = {
      source = "outscale/outscale"
      # 1.x for the api{} block (endpoint + region), which replaces the
      # deprecated top-level arguments and is what the emulator lane redirects.
      version = ">= 1.7.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
