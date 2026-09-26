# ==============================================================================
# Proxmox — Talos VMs (control planes + workers)
#
# Multi-host: VMs are round-robined across var.node_names via element(), same
# pattern as Scaleway zones. 1-host = non-HA, 3-host = true HA (1 CP per box).
#
# No user_data with Talos config here: Talos config is applied over the API in
# maintenance mode by modules/talos/ (config_delivery = "apply"). The IP config
# below is static (Talos reads it from the nocloud ip= kernel arg / initial net).
#
# ⚠️ cpu/memory are NOT ForceNew: the provider reboots the VM to apply them, so a
# plain apply reboots EVERY node at once. Change them with `task cluster-roll`
# (one node at a time) — docs/upgrade.md § A node size change.
# ==============================================================================

resource "proxmox_virtual_environment_vm" "control_plane" {
  count     = var.control_plane_count
  name      = "${var.cluster_name}-cp-${count.index}"
  node_name = element(var.node_names, count.index)
  tags      = ["talos", "control-plane", var.cluster_name]

  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  # Clone the Talos boot image into the node's system disk.
  disk {
    datastore_id = var.datastore_id
    file_id      = var.talos_image_file_id
    interface    = "scsi0"
    size         = var.root_disk_gb
  }

  network_device {
    bridge = var.network_bridge
  }

  # Static IP so Talos node identity is deterministic (no DHCP on the bridge).
  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = "${local.control_plane_ips[count.index]}/${local.prefix}"
        gateway = var.gateway_ip
      }
    }
    dns {
      servers = var.nameservers
    }
  }

  # Talos manages the OS; keep the agent off (no qemu-guest-agent in Talos base).
  agent {
    enabled = false
  }

  operating_system {
    type = "l26"
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  count     = var.worker_count
  name      = "${var.cluster_name}-worker-${count.index}"
  node_name = element(var.node_names, count.index)
  tags      = ["talos", "worker", var.cluster_name]

  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = var.talos_image_file_id
    interface    = "scsi0"
    size         = var.root_disk_gb
  }

  # Dedicated data disks (Longhorn / local-path), materialized as Talos
  # UserVolumeConfig by modules/talos. One block per worker_storage.disks entry.
  dynamic "disk" {
    for_each = {
      for d in local.worker_data_disks : d.key => d
      if d.worker == count.index
    }
    content {
      datastore_id = var.datastore_id
      interface    = "scsi${disk.value.disk_ix + 1}" # scsi0 = system disk
      size         = disk.value.size_gb
    }
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = "${local.worker_ips[count.index]}/${local.prefix}"
        gateway = var.gateway_ip
      }
    }
    dns {
      servers = var.nameservers
    }
  }

  agent {
    enabled = false
  }

  operating_system {
    type = "l26"
  }
}
