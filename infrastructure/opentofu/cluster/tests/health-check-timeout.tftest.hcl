# health_check_timeout bounds the cluster-health read; a malformed duration must fail at the variable.

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

run "a_short_duration_is_accepted" {
  command = plan
  variables {
    health_check_timeout = "5m"
  }
  assert {
    condition     = var.health_check_timeout == "5m"
    error_message = "5m must pass validation."
  }
}

run "a_malformed_duration_is_refused" {
  command = plan
  variables {
    health_check_timeout = "five minutes"
  }
  expect_failures = [var.health_check_timeout]
}
