# node_monitor_grace_period_seconds, the SHIPPED default (owner decision 2026-10-26, lab 27): 30 s, because the node power-off
# write-gap target (75 s) is met only at 30 s; evidence from ONE provider (Scaleway). 0 stays the opt-out (Kubernetes' 50 s).
# These runs turn red if the default goes back to 0. What the value renders into the machine configs is proven in
# modules/talos/tests/node-failure-detection.tftest.hcl; the root only passes the variable on (main.tf, module "talos").
# Every run passes or fails at the variable, before any provider module plans, so no mock needs shaping.

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

run "the_shipped_default_is_thirty_seconds" {
  command = plan

  assert {
    condition     = var.node_monitor_grace_period_seconds == 30
    error_message = "The shipped default is 30 s (owner decision 2026-10-26); 0 is the opt-out, not the default."
  }
}

run "the_default_reaches_the_talos_module_as_a_kubelet_heartbeat" {
  command = plan

  assert {
    condition     = module.talos.node_baseline_patch.worker.kubelet.extraConfig.nodeLeaseDurationSeconds == 30 && module.talos.node_baseline_patch.worker.kubelet.extraConfig.nodeStatusUpdateFrequency == "7s"
    error_message = "With no tfvars line the workers' kubelet must get lease 30 s and status every 7 s (floor(30 / 4)): the root passes the variable on."
  }
  assert {
    condition     = module.talos.node_baseline_patch.control_plane_kubelet.extraConfig.nodeLeaseDurationSeconds == 30
    error_message = "The control planes' kubelet gets the same heartbeat."
  }
}

run "zero_is_the_opt_out" {
  command = plan
  variables {
    node_monitor_grace_period_seconds = 0
  }
  assert {
    condition     = length(module.talos.node_baseline_patch.worker) == 0 && length(module.talos.node_baseline_patch.control_plane_kubelet) == 0
    error_message = "At 0 no node's kubelet gets a heartbeat setting: the Kubernetes defaults apply."
  }

  assert {
    condition     = var.node_monitor_grace_period_seconds == 0
    error_message = "0 must stay accepted: it keeps the Kubernetes default 50 s."
  }
}

run "between_zero_and_twenty_is_refused" {
  command = plan
  variables {
    node_monitor_grace_period_seconds = 19
  }
  expect_failures = [var.node_monitor_grace_period_seconds]
}

run "above_three_hundred_is_refused" {
  command = plan
  variables {
    node_monitor_grace_period_seconds = 301
  }
  expect_failures = [var.node_monitor_grace_period_seconds]
}
