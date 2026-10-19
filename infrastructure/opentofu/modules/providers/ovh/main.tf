# ==============================================================================
# OVH / OpenStack — Compute Instances
# Control planes use port-based networking for fixed private IPs.
# Workers use network name (dynamic IP within private subnet).
# No user_data — Talos configuration is applied via the Talos API after provisioning.
# ==============================================================================

# Root disk of the node flavour, read only for the root's check (docs/capacity.md: the application stack needs ~11 GB per node).
data "openstack_compute_flavor_v2" "node" {
  count = var.look_up_flavor_disk ? 1 : 0
  name  = var.flavor_name
}

# Looked up by name only when image_id is left unset — mirrors the Scaleway
# module's data.scaleway_instance_image (the talos-image root publishes under
# this same name convention; see talos-image/main.tf's local.image_name).
data "openstack_images_image_v2" "talos" {
  count       = var.image_id == null ? 1 : 0
  name        = var.image_name
  most_recent = true
}

locals {
  resolved_image_id = coalesce(var.image_id, try(data.openstack_images_image_v2.talos[0].id, null))
}

resource "openstack_networking_port_v2" "control_plane" {
  count              = var.control_plane_count
  name               = "${var.cluster_name}-cp-port-${count.index}"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.this.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }

  # k8s_lb_mode = "vip": let the apiserver VIP (owned by whichever CP Talos
  # currently assigns it to) pass Neutron's anti-spoofing filter on every CP
  # port — only one port actually carries it at a time.
  dynamic "allowed_address_pairs" {
    for_each = var.k8s_lb_mode == "vip" ? [1] : []
    content {
      ip_address = try(openstack_networking_port_v2.k8s_vip[0].all_fixed_ips[0], "0.0.0.0")
    }
  }
}

resource "openstack_compute_instance_v2" "control_plane" {
  count    = var.control_plane_count
  name     = "${var.cluster_name}-cp-${count.index}"
  image_id = local.resolved_image_id

  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  lifecycle {
    ignore_changes = [image_id]
  }
  flavor_name       = var.flavor_name
  region            = var.region
  availability_zone = element(var.availability_zones, count.index)

  network {
    port = openstack_networking_port_v2.control_plane[count.index].id
  }

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags = ["talos", "control-plane", var.cluster_name]
}

resource "openstack_compute_instance_v2" "worker" {
  count    = var.worker_count
  name     = "${var.cluster_name}-worker-${count.index}"
  image_id = local.resolved_image_id

  # Boot image = initial medium only; talosctl upgrade owns the live version.
  # See provider-contract.md § "Node image drift".
  lifecycle {
    ignore_changes = [image_id]
  }
  flavor_name       = var.flavor_name
  region            = var.region
  availability_zone = element(var.availability_zones, count.index)

  network {
    uuid = openstack_networking_network_v2.private.id
  }

  security_groups = [openstack_networking_secgroup_v2.this.name]

  # ⚠️ The network reference creates NO dependency on the SUBNET, and Nova
  # refuses to boot on a network that has none: "Network <id> requires a subnet
  # in order to boot instances on" (400), which failed two of two workers on
  # 2026-08-15 while the control planes came up fine — they hang off explicit
  # ports, and a port does depend on the subnet. Same shape as the bastion port,
  # documented in bastion.tf; the workers were never given the same guard, so
  # this raced silently and won often enough to look correct.
  depends_on = [openstack_networking_subnet_v2.private]

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags = ["talos", "worker", var.cluster_name]
}

# ==============================================================================
# Dedicated data disks per worker (worker × disk matrix). Each worker_storage.disks
# entry becomes one Cinder block volume per worker, attached to the instance.
# Used for Longhorn / local-path (Talos UserVolumeConfig mounts them at /var/mnt).
# ==============================================================================

locals {
  worker_data_disks = flatten([
    for w in range(var.worker_count) : [
      for d in range(length(var.worker_storage.disks)) : {
        key     = "w${w}-d${d}"
        worker  = w
        size_gb = var.worker_storage.disks[d].size_gb
      }
    ]
  ])
}

resource "openstack_blockstorage_volume_v3" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  name = "${var.cluster_name}-worker-data-${each.value.worker}-${each.key}"
  # EXPLICIT type: the OVH project default is multiattach and breaks the attachment
  # (cf. variable worker_data_volume_type).
  volume_type = var.worker_data_volume_type
  region      = var.region
  size        = each.value.size_gb
  # ⚠️ EXPLICIT AZ, the SAME as the worker that will mount it: without this
  # field the volume lands in the pseudo-AZ "any" and OVH leaves it in
  # `error status` (observed 2026-07-25; quotas and type ruled out). A volume
  # and its instance must share the AZ to be attachable anyway.
  availability_zone = element(var.availability_zones, each.value.worker)
}

resource "openstack_compute_volume_attach_v2" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  instance_id = openstack_compute_instance_v2.worker[each.value.worker].id
  volume_id   = openstack_blockstorage_volume_v3.worker_data[each.key].id
}
