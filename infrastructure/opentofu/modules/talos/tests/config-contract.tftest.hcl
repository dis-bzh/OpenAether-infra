# The config contract the machine configuration is rendered under (#241). Provider mocked: the
# rendered text is unknown at plan, so this reads the value both data sources are handed. That
# Talos accepts the text is `talosctl validate -m metal` on a real render, then a node.

mock_provider "talos" {}
mock_provider "random" {}

variables {
  cluster_name            = "t"
  cluster_endpoint        = "https://10.0.0.10:6443"
  talos_version           = "v1.14.2"
  kubernetes_version      = "v1.37.1"
  control_plane_count     = 1
  worker_count            = 1
  control_plane_ips       = ["10.0.0.10"]
  worker_ips              = ["10.0.0.20"]
  k8s_lb_ip               = "10.0.0.10"
  config_delivery         = "userdata"
  cilium_manifest         = "apiVersion: v1\nkind: ConfigMap\n"
  skip_health_check       = true
  secrets_prevent_destroy = false
}

run "a_1_14_node_is_rendered_under_the_1_13_contract" {
  command = plan
  assert {
    condition     = data.talos_machine_configuration.control_plane[0].talos_version == "v1.13" && data.talos_machine_configuration.worker[0].talos_version == "v1.13"
    error_message = "both machine configuration data sources must get v1.13 on a 1.14 node: a 1.14 contract collides with the v1alpha1 patches"
  }
}

run "a_1_12_node_keeps_its_own_contract" {
  command = plan
  variables {
    talos_version = "v1.12.6"
  }
  assert {
    condition     = data.talos_machine_configuration.control_plane[0].talos_version == "v1.12.6" && data.talos_machine_configuration.worker[0].talos_version == "v1.12.6"
    error_message = "a 1.12 node cannot read a 1.13 configuration: both data sources must keep its own version"
  }
}
