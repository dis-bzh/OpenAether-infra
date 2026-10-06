# ==============================================================================
# Proxmox — Bastion VM (OPTIONAL, enable_bastion = true)
#
# Default is host-as-bastion (no VM): on a single OVH dedicated server you already
# SSH the Proxmox host to admin it, and it routes vmbr1 to the private nodes — so
# the host IS the jump box at zero extra cost. This VM only exists when you
# explicitly want an isolated jump box instead of using the host.
#
# When enabled: SSH jump to nodes on 50000 (Talos) / 6443 (K8s), hardened
# cloud-init template, reached at bastion_public_ip (host-mapped/failover IP).
# ==============================================================================

locals {
  # Never the image's default user ("ubuntu"): cloud-init ignores the second definition of a user it already has, so
  # it would never join bastion-admins (measured on OVH, see ovh/bastion.tf). One value for the VM and the output.
  bastion_vm_user = "bastion"
}

resource "proxmox_virtual_environment_vm" "bastion" {
  count     = var.enable_bastion && (var.control_plane_count + var.worker_count) > 0 ? 1 : 0
  name      = "${var.cluster_name}-bastion"
  node_name = var.node_names[0]
  tags      = ["bastion", var.cluster_name]

  cpu {
    cores = var.bastion_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.bastion_memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = var.bastion_image_file_id
    interface    = "scsi0"
    size         = 10
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = "${local.bastion_private_ip}/${local.prefix}"
        gateway = var.gateway_ip
      }
    }
    dns {
      servers = var.nameservers
    }
    user_data_file_id = proxmox_virtual_environment_file.bastion_cloud_init[0].id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }
}

# Cloud-init user-data uploaded as a snippet (shared hardened template).
resource "proxmox_virtual_environment_file" "bastion_cloud_init" {
  count        = var.enable_bastion && (var.control_plane_count + var.worker_count) > 0 ? 1 : 0
  node_name    = var.node_names[0]
  datastore_id = var.iso_datastore_id
  content_type = "snippets"

  source_raw {
    file_name = "${var.cluster_name}-bastion-cloud-init.yaml"
    data = templatefile("${path.module}/../_shared/bastion-cloud-init.yaml.tftpl", {
      bastion_user      = local.bastion_vm_user
      ssh_keys          = var.bastion_ssh_keys
      private_cidr      = var.network_cidr
      extra_packages    = []
      extra_write_files = []
      extra_runcmd      = []
      ssh_ca_public_key = var.bastion_ssh_ca_public_key
      ssh_ca_principals = var.bastion_ssh_ca_principals
    })
  }
}
