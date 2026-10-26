# node_monitor_grace_period_seconds (lab 26, D2/H1): the kube-controller-manager's --node-monitor-grace-period and the matching kubelet
# heartbeat. At 0 (this module's own default; the shipped default 30 is the root's, cluster/tests/node-failure-detection.tftest.hcl) it renders nothing. Mocked: this proves the rendered machine config and the replace trigger, NOT that a shorter
# grace period shortens a failover or stays free of false NotReady (docs/resilience.md: the next lab's experiment).

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

run "zero_changes_nothing" {
  command = apply
  variables {
    node_monitor_grace_period_seconds = 0
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).cluster.controllerManager)
    error_message = "at 0, the control plane config must carry no controllerManager block"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.kubelet.extraConfig) && !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet)
    error_message = "at 0, no kubelet heartbeat setting on either role"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "at 0, the replace trigger must not move"
  }
}

run "twenty_seconds_sets_the_controller_manager_and_the_kubelet_on_every_node" {
  command = apply
  variables {
    node_monitor_grace_period_seconds = 20
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).cluster.controllerManager.extraArgs["node-monitor-grace-period"] == "20s"
    error_message = "the controller manager must get --node-monitor-grace-period=20s"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.kubelet.extraConfig.nodeLeaseDurationSeconds == 20 && yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.kubelet.extraConfig.nodeStatusUpdateFrequency == "5s"
    error_message = "control-plane kubelet: lease 20 s (renewed every 5 s) and status every 5 s"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet.extraConfig.nodeLeaseDurationSeconds == 20 && yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet.extraConfig.nodeStatusUpdateFrequency == "5s"
    error_message = "worker kubelet: the same heartbeat, or the node is heard less often than the controller manager waits"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).cluster.controllerManager)
    error_message = "workers do not run a controller manager"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input != "v1.14.2/v1.37.1"
    error_message = "a changed value must re-apply the machine configs (the replace trigger moves)"
  }
}

run "thirty_one_rounds_the_status_frequency_down" {
  command = apply
  variables {
    node_monitor_grace_period_seconds = 31
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet.extraConfig.nodeStatusUpdateFrequency == "7s" && yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet.extraConfig.nodeLeaseDurationSeconds == 31
    error_message = "31 s: lease 31, status every floor(31/4) = 7 s (4 x 7 = 28 <= 31: at least 4 chances)"
  }
}

run "from_forty_seconds_the_kubelet_keeps_the_kubernetes_defaults" {
  command = apply
  variables {
    node_monitor_grace_period_seconds = 60
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).cluster.controllerManager.extraArgs["node-monitor-grace-period"] == "60s"
    error_message = "the controller manager gets 60s"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet)
    error_message = "at 60 s the default heartbeat (renewal every 10 s, status every 10 s) already gives 5 chances: the kubelet is left alone"
  }
}

run "below_twenty_is_refused" {
  command = plan
  variables {
    node_monitor_grace_period_seconds = 10
  }
  expect_failures = [var.node_monitor_grace_period_seconds]
}

run "a_fraction_is_refused" {
  command = plan
  variables {
    node_monitor_grace_period_seconds = 25.5
  }
  expect_failures = [var.node_monitor_grace_period_seconds]
}
