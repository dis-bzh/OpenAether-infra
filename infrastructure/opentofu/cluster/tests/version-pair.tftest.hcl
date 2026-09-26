# The pair guard: Talos supports Kubernetes n-5, so two individually valid pins
# can be jointly unsupported. Asserted in all three directions — a good pair, a
# bad one, and a Talos minor the map has never heard of — because a guard nobody
# has seen refuse is a guard nobody knows works.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
mock_provider "local" {}

override_data {
  target = module.scw.data.scaleway_instance_image.talos
  values = { id = "talos-image-id" }
}
override_data {
  target = module.scw.data.scaleway_instance_image.worker
  values = { id = "worker-image-id" }
}
override_resource {
  target = module.scw.scaleway_ipam_ip.control_plane
  values = { id = "10101010-1010-1010-1010-101010101010", address = "10.0.0.10/24" }
}
override_resource {
  target = module.scw.scaleway_ipam_ip.worker
  values = { id = "20202020-2020-2020-2020-202020202020", address = "10.0.0.20/24" }
}
override_resource {
  target = module.scw.scaleway_lb_ip.app
  values = { id = "11111111-1111-1111-1111-111111111111", ip_address = "192.0.2.1" }
}
override_resource {
  target = module.scw.scaleway_lb_ip.k8s
  values = { id = "22222222-2222-2222-2222-222222222222", ip_address = "192.0.2.2" }
}
override_resource {
  target = module.scw.scaleway_instance_ip.bastion
  values = { id = "33333333-3333-3333-3333-333333333333", address = "192.0.2.3" }
}
override_resource {
  target = module.scw.scaleway_vpc_public_gateway_ip.this
  values = { address = "192.0.2.4" }
}
override_resource {
  target = module.scw.scaleway_vpc_public_gateway.this
  values = { id = "44444444-4444-4444-4444-444444444444" }
}
override_resource {
  target = module.scw.scaleway_vpc_private_network.this
  values = { id = "55555555-5555-5555-5555-555555555555" }
}
override_resource {
  target = module.scw.scaleway_lb.app
  values = { id = "66666666-6666-6666-6666-666666666666" }
}
override_resource {
  target = module.scw.scaleway_lb.k8s
  values = { id = "77777777-7777-7777-7777-777777777777" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.k8s_api
  values = { id = "88888888-8888-8888-8888-888888888888" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.http
  values = { id = "99999999-9999-9999-9999-999999999999" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.https
  values = { id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.k8s_api
  values = { id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.http
  values = { id = "cccccccc-cccc-cccc-cccc-cccccccccccc" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.https
  values = { id = "dddddddd-dddd-dddd-dddd-dddddddddddd" }
}
override_resource {
  target = module.scw.scaleway_lb_private_network.app
  values = { id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" }
}
override_resource {
  target = module.scw.scaleway_lb_private_network.k8s
  values = { id = "ffffffff-ffff-ffff-ffff-ffffffffffff" }
}

variables {
  cluster_name    = "talos-test"
  environment     = "dev"
  cluster_role    = "management"
  talos_bootstrap = false
  backup_enabled  = false # backups run a local-exec (aws s3 cp); skip in tests
  admin_ip        = ["10.0.0.1/32"]
  bastion_ssh_keys = {
    scaleway = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 test@test"]
  }
  node_distribution = {
    scaleway = {
      control_planes = 3
      workers        = 1
      image_name     = "talos"
      instance_type  = "DEV1-S"
      zone           = "fr-par-1"
      region         = "fr-par"
      zones          = ["fr-par-1", "fr-par-2", "fr-par-1"]
    }
  }
  git_repo_url        = "https://github.com/test/repo.git"
  cilium_manifest     = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-config\n  namespace: kube-system"
  root_app_manifest   = "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: test-root"
  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

run "supported_pair_passes" {
  command = plan
  variables {
    talos_version      = "v1.13.8"
    kubernetes_version = "v1.36.3"
  }
}

run "unsupported_pair_is_refused" {
  command = plan
  variables {
    talos_version      = "v1.13.8"
    kubernetes_version = "v1.29.0" # below Talos 1.13's floor of 1.31
  }
  expect_failures = [terraform_data.version_pair_guard]
}

run "unknown_talos_minor_is_refused" {
  command = plan
  variables {
    talos_version      = "v1.99.0" # not in the map, and must not pass silently
    kubernetes_version = "v1.36.3"
  }
  expect_failures = [terraform_data.version_pair_guard]
}

# A valid start and a valid end can be joined by a step that is neither, since
# the two move one minor at a time. Each of these is one step of the climb
# from (v1.12.7, v1.31.0) to the final pair above (v1.13.9, v1.36.3): Talos
# first, then Kubernetes one minor at a time — every step must clear the guard
# on its own, not just the endpoints.

run "climb_step_v1_12_7_v1_31_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.12.7"
    kubernetes_version = "v1.31.0"
  }
}

run "climb_step_v1_13_9_v1_31_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.13.9" # Talos moves first, Kubernetes unchanged
    kubernetes_version = "v1.31.0"
  }
}

run "climb_step_v1_13_9_v1_32_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.32.0"
  }
}

run "climb_step_v1_13_9_v1_33_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.33.0"
  }
}

run "climb_step_v1_13_9_v1_34_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.34.0"
  }
}

run "climb_step_v1_13_9_v1_35_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.35.0"
  }
}

run "climb_trap_v1_13_9_v1_30_0_is_refused" {
  command = plan
  variables {
    # Talos moved ahead of Kubernetes catching up: a valid pair on its own
    # (1.30 is in range for Talos 1.12) but not one this climb ever visits
    # once Talos is at 1.13, whose floor is 1.31.
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.30.0"
  }
  expect_failures = [terraform_data.version_pair_guard]
}

# Talos 1.14 raises the floor to 1.32: the next climb (v1.13.9, v1.36.3) ->
# (v1.14.1, v1.37.0) moves Talos first, and 1.31 must no longer pass.

run "talos_1_14_step_v1_14_1_v1_36_3_passes" {
  command = plan
  variables {
    talos_version      = "v1.14.1"
    kubernetes_version = "v1.36.3"
  }
}

run "talos_1_14_pair_v1_14_1_v1_37_0_passes" {
  command = plan
  variables {
    talos_version      = "v1.14.1"
    kubernetes_version = "v1.37.0"
  }
}

run "talos_1_14_floor_v1_14_1_v1_31_0_is_refused" {
  command = plan
  variables {
    talos_version      = "v1.14.1"
    kubernetes_version = "v1.31.0"
  }
  expect_failures = [terraform_data.version_pair_guard]
}
