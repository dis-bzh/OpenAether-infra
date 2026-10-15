terraform {
  required_version = ">= 1.11.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.68"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    outscale = {
      source  = "outscale/outscale"
      version = "~> 1.8"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6"
    }
  }
}
