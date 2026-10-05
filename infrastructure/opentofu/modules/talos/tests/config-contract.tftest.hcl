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

run "a_node_newer_than_1_14_is_capped_too" {
  command = plan
  variables {
    talos_version = "v1.15.0"
  }
  assert {
    condition     = data.talos_machine_configuration.control_plane[0].talos_version == "v1.13" && data.talos_machine_configuration.worker[0].talos_version == "v1.13"
    error_message = "the cap is 'never newer than v1.13', not 'only 1.14': a 1.15 node must be rendered under v1.13 as well"
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

# A second older version, so the branch cannot be a literal that happens to match the run above.
run "another_older_node_keeps_its_own_contract" {
  command = plan
  variables {
    talos_version = "v1.12.0"
  }
  assert {
    condition     = data.talos_machine_configuration.control_plane[0].talos_version == "v1.12.0" && data.talos_machine_configuration.worker[0].talos_version == "v1.12.0"
    error_message = "an older node must keep exactly its own version, whatever it is"
  }
}

# The cap is for the two data sources only: the node's Talos still drives the secrets and the
# #352 replace trigger. Feeding the contract to either would plan a downward secrets change on a
# live 1.14 cluster (a replacement `prevent_destroy` refuses) or stop a 1.13 to 1.14 bump from
# replacing the applies. Apply mode and several nodes, so every index and the trigger exist.
run "the_cap_reaches_every_node_and_only_the_data_sources" {
  command = plan
  variables {
    control_plane_count  = 3
    worker_count         = 2
    control_plane_ips    = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]
    worker_ips           = ["10.0.0.20", "10.0.0.21"]
    config_delivery      = "apply"
    skip_port_ready_wait = true
  }
  assert {
    condition = alltrue(concat(
      [for d in data.talos_machine_configuration.control_plane : d.talos_version == "v1.13"],
      [for d in data.talos_machine_configuration.worker : d.talos_version == "v1.13"],
    ))
    error_message = "every control plane and every worker must be rendered under v1.13, not only the first"
  }
  assert {
    condition     = talos_machine_secrets.unprotected[0].talos_version == "v1.14.2"
    error_message = "the secrets must keep the node's Talos version, not the config contract"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "the replace trigger must follow the node's Talos version, or a 1.13 to 1.14 bump replaces nothing"
  }
}

# The production resource is the protected one; the runs above only ever instantiate the other.
run "protected_secrets_keep_the_node_version" {
  command = plan
  variables {
    secrets_prevent_destroy = true
  }
  assert {
    condition     = talos_machine_secrets.this[0].talos_version == "v1.14.2"
    error_message = "the protected secrets must keep the node's Talos version, not the config contract"
  }
}
