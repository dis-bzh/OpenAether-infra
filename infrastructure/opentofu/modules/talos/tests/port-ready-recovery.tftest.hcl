# port_ready_recovery (lab 27 part B, D6/D11, infra #371): the guard that waits for a new node's Talos port may ask the provider for a
# hard reboot, OVH only, after 120 to 600 s, or not at all. Mocked: this proves what the variable accepts and that it changes nothing
# else; that the call frees a real node (28 to 30 s by hand, twice) is proven by the next OVH creation that hits the trap.

mock_provider "talos" {}
mock_provider "random" {}

variables {
  coredns_ha              = false
  cluster_name            = "t"
  cluster_endpoint        = "https://10.0.0.10:6443"
  talos_version           = "v1.14.2"
  kubernetes_version      = "v1.37.1"
  control_plane_count     = 1
  worker_count            = 1
  control_plane_ips       = ["10.0.0.10"]
  worker_ips              = ["10.0.0.20"]
  k8s_lb_ip               = "10.0.0.10"
  config_delivery         = "apply"
  skip_port_ready_wait    = true
  cilium_manifest         = "apiVersion: v1\nkind: ConfigMap\n"
  skip_health_check       = true
  secrets_prevent_destroy = false
}

override_data {
  target = data.talos_machine_configuration.control_plane
  values = { machine_configuration = "version: v1alpha1\nmachine:\n  type: controlplane\n" }
}

run "off_by_default" {
  command = plan
  assert {
    condition     = var.port_ready_recovery.provider == "" && var.port_ready_recovery.after_seconds == 0
    error_message = "the module must not reboot anything unless the root asks"
  }
}

run "ovh_at_300_is_accepted" {
  command = plan
  variables {
    port_ready_recovery = { provider = "ovh", after_seconds = 300 }
  }
  assert {
    condition     = var.port_ready_recovery.provider == "ovh"
    error_message = "ovh with 300 s must be accepted"
  }
}

run "another_provider_is_refused" {
  command = plan
  variables {
    port_ready_recovery = { provider = "scaleway", after_seconds = 300 }
  }
  expect_failures = [var.port_ready_recovery]
}

run "a_wait_shorter_than_a_boot_is_refused" {
  command = plan
  variables {
    port_ready_recovery = { provider = "ovh", after_seconds = 30 }
  }
  expect_failures = [var.port_ready_recovery]
}

run "a_wait_that_eats_the_whole_guard_is_refused" {
  command = plan
  variables {
    port_ready_recovery = { provider = "ovh", after_seconds = 900 }
  }
  expect_failures = [var.port_ready_recovery]
}
