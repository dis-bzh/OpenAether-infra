# Node counts: workers with no control plane are refused (on a live cluster that edit deletes every control
# plane and drops the bootstrap from the state). Every run fails or passes at the variable, before any provider
# module plans, so no mock needs shaping; a shape that is valid must still reach the module is proven by
# scaleway.tftest.hcl and k8s-lb-mode.tftest.hcl, which plan full roots and turn red if this rule is too strict.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
mock_provider "local" {}

variables {
  cluster_name        = "test-cluster"
  environment         = "dev"
  cluster_role        = "management"
  talos_bootstrap     = false
  backup_enabled      = false
  admin_ip            = ["203.0.113.4/32"] # RFC 5737 TEST-NET-3
  git_repo_url        = "https://github.com/test/repo.git"
  cilium_manifest     = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"
  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
  node_distribution   = {}
}

run "no_provider_is_accepted" {
  command = plan

  assert {
    condition     = length(var.node_distribution) == 0
    error_message = "An empty node_distribution (nothing deployed) must survive validation."
  }
}

run "an_inactive_provider_at_zero_is_accepted" {
  command = plan
  variables {
    node_distribution = {
      scaleway = { control_planes = 0, workers = 0 }
      ovh      = { control_planes = 0, workers = 0 }
    }
  }

  assert {
    condition     = var.node_distribution["ovh"].control_planes == 0
    error_message = "An inactive provider is control_planes = 0 with workers = 0 and must not trip the rule."
  }
}

run "workers_without_a_control_plane_are_refused" {
  command = plan
  variables {
    node_distribution = {
      scaleway = { control_planes = 0, workers = 2, region = "fr-par", zone = "fr-par-1", instance_type = "POP2-4C-16G" }
    }
  }
  expect_failures = [var.node_distribution]
}

run "one_provider_in_error_is_enough" {
  command = plan
  variables {
    node_distribution = {
      scaleway = { control_planes = 0, workers = 0 }
      ovh      = { control_planes = 0, workers = 3 }
    }
  }
  expect_failures = [var.node_distribution]
}
