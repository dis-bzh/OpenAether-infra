# ==============================================================================
# Outscale — Compute Instances (VMs)
# Control planes and workers both attach to the private subnet directly and get
# an auto-assigned private IP. (A dedicated outscale_nic can't be combined with
# the VM's security_group_ids — Outscale's CreateVm rejects Nics + SG together —
# and Talos reads the actual VM IPs from the outputs, so fixed IPs aren't needed.)
# No user_data — Talos configuration is applied via the Talos API after provisioning.
# ==============================================================================

# Looked up by name only when image_id is left unset — mirrors the Scaleway
# module's data.scaleway_instance_image (the talos-image root publishes under
# this same name convention; see talos-image/main.tf's local.image_name).
# The `images[0].image_id` dereference is exercised by the emulated lane
# (`task feint-plan PROVIDER=outscale`). Its ORDERING is not: the emulator
# returns a fixed catalogue in declaration order, so "most recent first" remains
# an assumption a real account has to confirm.
data "outscale_images" "talos" {
  count = var.image_id == null ? 1 : 0
  filter {
    name   = "image_names"
    values = [var.image_name]
  }
}

locals {
  # The placement rule: node i of a kind goes to zone i modulo the number of zones (#58).
  cp_zone_index     = [for i in range(var.control_plane_count) : i % length(var.availability_zones)]
  worker_zone_index = [for i in range(var.worker_count) : i % length(var.availability_zones)]

  resolved_image_id = coalesce(var.image_id, try(data.outscale_images.talos[0].images[0].image_id, null))
}

resource "outscale_vm" "control_plane" {
  count    = var.control_plane_count
  image_id = local.resolved_image_id

  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  # subnet_id too: a node's placement is decided when it is created. Moving it is a rebuild, and
  # a cluster built when every node shared one subnet must not have two of its three control planes
  # replaced because availability_zones now spreads them (#58); new nodes follow the new layout.
  lifecycle {
    ignore_changes = [image_id, subnet_id]
  }
  vm_type = var.instance_type

  subnet_id = outscale_subnet.private[local.cp_zone_index[count.index]].subnet_id

  security_group_ids = [outscale_security_group.this.security_group_id]

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags {
    key   = "Name"
    value = "${var.cluster_name}-cp-${count.index}"
  }
  tags {
    key   = "talos"
    value = "control-plane"
  }
  tags {
    key   = "cluster"
    value = var.cluster_name
  }
}

resource "outscale_vm" "worker" {
  count    = var.worker_count
  image_id = local.resolved_image_id

  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  # subnet_id too: a node's placement is decided when it is created. Moving it is a rebuild, and
  # a cluster built when every node shared one subnet must not have two of its three control planes
  # replaced because availability_zones now spreads them (#58); new nodes follow the new layout.
  lifecycle {
    ignore_changes = [image_id, subnet_id]
  }
  vm_type = var.instance_type

  subnet_id = outscale_subnet.private[local.worker_zone_index[count.index]].subnet_id

  security_group_ids = [outscale_security_group.this.security_group_id]

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-${count.index}"
  }
  tags {
    key   = "talos"
    value = "worker"
  }
  tags {
    key   = "cluster"
    value = var.cluster_name
  }
}

# ==============================================================================
# Dedicated data disks per worker (worker × disk matrix). Each worker_storage.disks
# entry becomes one BSU volume per worker, linked to the VM. device_name follows
# the disk index (/dev/sdb, /dev/sdc, …). Volumes live in their worker's subregion. Used for Longhorn / local-path (Talos mounts under
# /var/mnt via UserVolumeConfig).
# ==============================================================================

locals {
  worker_data_disks = flatten([
    for w in range(var.worker_count) : [
      for d in range(length(var.worker_storage.disks)) : {
        key         = "w${w}-d${d}"
        worker      = w
        disk_index  = d
        size_gb     = var.worker_storage.disks[d].size_gb
        device_name = "/dev/sd${substr("bcdefghijklmnop", d, 1)}"
      }
    ]
  ])
}

resource "outscale_volume" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  # The subregion of the subnet its worker is built in (same index rule as the VM). Fixed at
  # creation, like the VM's subnet: a different subregion would replace the volume and its data.
  subregion_name = outscale_subnet.private[local.worker_zone_index[each.value.worker]].subregion_name
  size           = each.value.size_gb

  lifecycle {
    ignore_changes = [subregion_name]
  }

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-data-${each.value.worker}-${each.key}"
  }
  tags {
    key   = "cluster"
    value = var.cluster_name
  }
}

resource "outscale_volume_link" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  device_name = each.value.device_name
  volume_id   = outscale_volume.worker_data[each.key].volume_id
  vm_id       = outscale_vm.worker[each.value.worker].vm_id
}
