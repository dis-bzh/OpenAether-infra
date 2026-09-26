# Node size changes (#51): the provider resizes in place, so a plain apply hits
# every node at once (docs/upgrade.md § A node size change). A mock cannot tell
# replace from update, so these pin only our half: where the size lands, and
# that no knob turns it into a replacement.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}

variables {
  cluster_name        = "size-test"
  admin_ip            = ["10.0.0.1/32"]
  control_plane_count = 3
  worker_count        = 2
}

run "scaleway_size_is_type_and_never_replaces" {
  command = plan
  module { source = "../modules/providers/scw" }
  providers = { scaleway = scaleway }
  plan_options { target = [scaleway_instance_server.control_plane, scaleway_instance_server.worker] }

  variables {
    instance_type = "DEV1-L"
    image_id      = "fr-par-1/11111111-1111-1111-1111-111111111111"
    deploy_app_lb = false
  }
  override_resource {
    target = scaleway_lb_ip.k8s
    values = { ip_address = "192.0.2.2" }
  }

  assert {
    condition = alltrue([for n in concat(scaleway_instance_server.control_plane, scaleway_instance_server.worker) :
    n.type == "DEV1-L"])
    error_message = "instance_type must reach every node's `type`."
  }
  # true makes the provider ForceNew `type`: a plain apply would then replace
  # every node at once instead of resizing it.
  assert {
    condition = alltrue([for n in concat(scaleway_instance_server.control_plane, scaleway_instance_server.worker) :
    n.replace_on_type_change != true])
    error_message = "replace_on_type_change must stay unset: see docs/upgrade.md before changing it."
  }
}

run "ovh_size_is_flavor_name" {
  command = plan
  module { source = "../modules/providers/ovh" }
  providers = { openstack = openstack }
  plan_options { target = [openstack_compute_instance_v2.control_plane, openstack_compute_instance_v2.worker] }

  variables {
    flavor_name = "b3-16"
    image_id    = "dummy-talos-ovh-image"
  }

  assert {
    condition = alltrue([for n in concat(openstack_compute_instance_v2.control_plane, openstack_compute_instance_v2.worker) :
    n.flavor_name == "b3-16"])
    error_message = "flavor_name must reach every node."
  }
}

run "outscale_size_is_vm_type" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_vm.control_plane, outscale_vm.worker] }

  variables {
    instance_type = "tinav7.c4r8p2"
    image_id      = "ami-11111111"
  }

  assert {
    condition     = alltrue([for n in concat(outscale_vm.control_plane, outscale_vm.worker) : n.vm_type == "tinav7.c4r8p2"])
    error_message = "instance_type must reach every node's `vm_type`."
  }
}

run "proxmox_size_is_cpu_and_memory" {
  command = plan
  module { source = "../modules/providers/proxmox" }
  providers = { proxmox = proxmox }
  plan_options { target = [proxmox_virtual_environment_vm.control_plane, proxmox_virtual_environment_vm.worker] }

  variables {
    node_names          = ["pve1", "pve2", "pve3"]
    gateway_ip          = "10.0.0.1"
    apiserver_vip       = "10.0.0.100"
    talos_image_file_id = "local:iso/talos.img"
    cpu_cores           = 8
    memory_mb           = 16384
  }

  assert {
    condition = alltrue([for n in concat(proxmox_virtual_environment_vm.control_plane, proxmox_virtual_environment_vm.worker) :
    n.cpu[0].cores == 8 && n.memory[0].dedicated == 16384])
    error_message = "cpu_cores/memory_mb must reach every VM's cpu.cores / memory.dedicated."
  }
  # The provider applies cpu/memory by rebooting the VM (reboot_after_update,
  # default true); false would make the update fail instead. Either way, not a replace.
  assert {
    condition = alltrue([for n in concat(proxmox_virtual_environment_vm.control_plane, proxmox_virtual_environment_vm.worker) :
    n.reboot_after_update != false])
    error_message = "reboot_after_update must stay at its default: see docs/upgrade.md before changing it."
  }
}
