# node_zones (0.4.0 M4): the failure domain of each node becomes the label topology.kubernetes.io/zone, which the zone-loss
# alert, the kube-state-metrics allowlist and `task failure-domain-check` read. Null (and an empty entry) renders nothing and
# leaves the replace trigger as it was. Mocked: this proves the rendered patches and the trigger, not that a Talos node
# accepts the label (LAB-CHECKLIST: read `kubectl get nodes -L topology.kubernetes.io/zone`).

mock_provider "talos" {}
mock_provider "random" {}

variables {
  cluster_name            = "t"
  cluster_endpoint        = "https://10.0.0.10:6443"
  talos_version           = "v1.14.2"
  kubernetes_version      = "v1.37.1"
  control_plane_count     = 3
  worker_count            = 2
  control_plane_ips       = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]
  worker_ips              = ["10.0.0.20", "10.0.0.21"]
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

run "unset_labels_nothing_and_keeps_the_trigger" {
  command = apply
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.nodeLabels) && !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.nodeLabels)
    error_message = "node_zones = null must add no label to any node"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "the replace trigger must be unchanged when no zone is known"
  }
}

run "empty_entries_label_nothing" {
  command = apply
  variables {
    node_zones = { control_plane = ["", "", ""], worker = ["", ""] }
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1" && !can(yamldecode(data.talos_machine_configuration.worker[1].config_patches[0]).machine.nodeLabels)
    error_message = "a provider that reports nothing (empty strings) must change nothing"
  }
}

run "each_node_carries_its_own_zone" {
  command = apply
  variables {
    node_zones = { control_plane = ["z-a", "z-b", "z-c"], worker = ["z-a", "z-b"] }
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[2].config_patches[0]).machine.nodeLabels["topology.kubernetes.io/zone"] == "z-c" && yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.nodeLabels["topology.kubernetes.io/zone"] == "z-a"
    error_message = "each control plane must carry the zone at its own index"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.worker[1].config_patches[0]).machine.nodeLabels["topology.kubernetes.io/zone"] == "z-b"
    error_message = "each worker must carry the zone at its own index"
  }
  assert {
    condition     = startswith(terraform_data.machine_config_version[0].input, "v1.14.2/v1.37.1/")
    error_message = "the labels must be in the replace trigger, or an existing cluster never gets them"
  }
}

run "a_shorter_list_labels_only_the_nodes_it_names" {
  command = apply
  variables {
    node_zones = { control_plane = ["z-a"], worker = [] }
  }
  assert {
    condition     = can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.nodeLabels) && !can(yamldecode(data.talos_machine_configuration.control_plane[1].config_patches[0]).machine.nodeLabels)
    error_message = "a list shorter than the node count must label the nodes it covers and leave the others alone, not fail"
  }
}
