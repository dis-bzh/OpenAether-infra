# control_plane_zones (#38): each provider module reports where it PLACED its
# control planes, read back from the control-plane resources. A mock cannot say
# what a real cloud returns, so these pin our half: which attribute is read, and
# that an input the module ignores is never echoed as if it were a placement.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}

variables {
  cluster_name        = "zones-test"
  admin_ip            = ["10.0.0.1/32"]
  control_plane_count = 3
  worker_count        = 1
}

run "scaleway_spread_reports_each_zone" {
  command = plan
  module { source = "../modules/providers/scw" }
  providers = { scaleway = scaleway }
  plan_options { target = [scaleway_instance_server.control_plane] }

  variables {
    additional_zones = ["fr-par-1", "fr-par-2", "fr-par-3"]
    image_id         = "fr-par-1/11111111-1111-1111-1111-111111111111"
    deploy_app_lb    = false
  }

  assert {
    condition     = output.control_plane_zones == ["fr-par-1", "fr-par-2", "fr-par-3"]
    error_message = "scw must report the zone of each control plane, in node order."
  }
}

# One entry per node even when they all share a zone: the verifier counts
# entries per domain, so a collapsed list would read as a single control plane.
run "scaleway_one_zone_reports_three_entries" {
  command = plan
  module { source = "../modules/providers/scw" }
  providers = { scaleway = scaleway }
  plan_options { target = [scaleway_instance_server.control_plane] }

  variables {
    additional_zones = ["fr-par-1"]
    image_id         = "fr-par-1/11111111-1111-1111-1111-111111111111"
    deploy_app_lb    = false
  }

  assert {
    condition     = length(output.control_plane_zones) == 3 && length(distinct(output.control_plane_zones)) == 1
    error_message = "Three control planes in one zone must give three entries naming that one zone."
  }
}

run "ovh_reports_the_availability_zone" {
  command = plan
  module { source = "../modules/providers/ovh" }
  providers = { openstack = openstack }
  plan_options { target = [openstack_compute_instance_v2.control_plane] }

  variables {
    availability_zones = ["zone-a", "zone-b", "zone-c"]
    image_id           = "dummy-talos-ovh-image"
  }

  assert {
    condition     = output.control_plane_zones == ["zone-a", "zone-b", "zone-c"]
    error_message = "ovh must report the availability zone of each control plane, in node order."
  }
}

# Outscale places a node by its subnet, and the module builds one subnet in
# availability_zones[0] (#58). The override stands for what the API reads back:
# an output built from the variable would say a/b/c and fail the equality.
run "outscale_reports_the_vm_placement_not_the_variable" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_vm.control_plane] }

  variables {
    availability_zones = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    image_id           = "ami-11111111"
  }
  override_resource {
    target = outscale_vm.control_plane
    values = { placement_subregion_name = "eu-west-2a" }
  }

  assert {
    condition     = output.control_plane_zones == ["eu-west-2a", "eu-west-2a", "eu-west-2a"]
    error_message = "outscale must report the subregion the VMs were placed in, not var.availability_zones (only [0] is used, #58)."
  }
}

run "proxmox_reports_the_host" {
  command = plan
  module { source = "../modules/providers/proxmox" }
  providers = { proxmox = proxmox }
  plan_options { target = [proxmox_virtual_environment_vm.control_plane] }

  variables {
    node_names          = ["pve1", "pve2", "pve3"]
    gateway_ip          = "10.0.0.1"
    apiserver_vip       = "10.0.0.100"
    talos_image_file_id = "local:iso/talos.img"
  }

  assert {
    condition     = output.control_plane_zones == ["pve1", "pve2", "pve3"]
    error_message = "proxmox must report the hypervisor host of each control plane, in node order."
  }
}
