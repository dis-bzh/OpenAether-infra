# talos_api_access_namespaces: machine.features.kubernetesTalosAPIAccess on the CONTROL PLANES, role os:etcd:backup only, for
# the namespaces given; empty renders nothing. Mocked: this proves the rendered patch and the replace trigger, not that a
# Talos node accepts it or that the controller creates the Secret (lab).

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

run "empty_renders_nothing_and_keeps_the_version_input" {
  command = apply
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.features.kubernetesTalosAPIAccess)
    error_message = "no namespace given must leave the control plane patch without kubernetesTalosAPIAccess"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "the replace trigger input must be unchanged when the access is off: a different value re-applies every node on an existing cluster"
  }
}

run "set_grants_only_the_etcd_backup_role_on_the_control_planes" {
  command = apply
  variables {
    talos_api_access_namespaces = ["foundation-databases"]
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.features.kubernetesTalosAPIAccess == { enabled = true, allowedRoles = ["os:etcd:backup"], allowedKubernetesNamespaces = ["foundation-databases"] }
    error_message = "the control plane must allow exactly the role os:etcd:backup, for exactly the namespaces given"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.features.kubernetesTalosAPIAccess)
    error_message = "the workers must not carry the grant: the controller runs on the control planes"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.features.kubePrism.enabled == true
    error_message = "the other control plane features must be kept"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input != "v1.14.2/v1.37.1"
    error_message = "turning the access on must change the replace trigger input, or an existing cluster would never get the config"
  }
}

run "a_bad_namespace_is_refused" {
  command = plan
  variables {
    talos_api_access_namespaces = ["Foundation_Databases"]
  }
  expect_failures = [var.talos_api_access_namespaces]
}
