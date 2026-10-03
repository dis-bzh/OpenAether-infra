terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Held on 0.11: 0.12.0 (stable since 2026-09-21) renders Talos 1.14's multi-document
      # config and the module's v1alpha1 patches collide with it (#241). Renovate is told so.
      version = "~> 0.11.0"
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
