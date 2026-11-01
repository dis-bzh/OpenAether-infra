# Outscale root volume type and IOPS (lab 27 part C, E3): the root volume was hard-coded gp2, 50 GB = 150 IOPS, and containerd
# and the kubelet starved (CRI DeadlineExceeded, a worker NotReady twice, 924 s to a whole cluster after one node loss). The
# type is a variable now, io1 with 1500 IOPS by default. Mocked rung: this proves what is PLANNED, not what the API accepts
# (UNPROVEN until an Outscale lab: io1 root with a Talos OMI).

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}

variables {
  cluster_name        = "root-vol-test"
  admin_ip            = ["10.0.0.1/32"]
  control_plane_count = 3
  worker_count        = 3
  image_id            = "ami-11111111"
}

run "default_is_io1_1500_iops_on_every_node" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_vm.control_plane, outscale_vm.worker] }

  variables {
    root_volume_size_gb = 50
  }

  assert {
    condition = alltrue([for n in concat(outscale_vm.control_plane, outscale_vm.worker) :
    n.block_device_mappings[0].bsu[0].volume_type == "io1" && n.block_device_mappings[0].bsu[0].iops == 1500 && n.block_device_mappings[0].bsu[0].volume_size == 50])
    error_message = "Every node must get an io1 root of the requested size with 1500 IOPS by default."
  }
}

run "gp2_keeps_the_old_behaviour_and_sends_no_iops" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_vm.control_plane, outscale_vm.worker] }

  variables {
    root_volume_size_gb = 50
    root_volume_type    = "gp2"
  }

  assert {
    condition = alltrue([for n in concat(outscale_vm.control_plane, outscale_vm.worker) :
    n.block_device_mappings[0].bsu[0].volume_type == "gp2" && n.block_device_mappings[0].bsu[0].iops == null])
    error_message = "gp2 must be sent as gp2 with no IOPS (the API refuses IOPS on gp2)."
  }
}

run "gp2_without_a_size_sends_no_mapping" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_vm.worker] }

  variables {
    root_volume_type = "gp2"
  }

  assert {
    condition     = alltrue([for n in outscale_vm.worker : length(n.block_device_mappings) == 0])
    error_message = "gp2 and no size is the OMI's own root: no block device mapping, exactly as before this variable."
  }
}
