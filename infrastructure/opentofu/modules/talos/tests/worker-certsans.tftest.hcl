# A worker's apid certSANs name that worker only (infra #420): listing every worker made each grow change the config,
# so the machine_configuration_hash, of every existing worker ("0 to add, N to change"). Mocked: the rendered patch.

mock_provider "talos" {}
mock_provider "random" {}

variables {
  coredns_ha              = false
  cluster_name            = "t"
  cluster_endpoint        = "https://10.0.0.10:6443"
  talos_version           = "v1.14.2"
  kubernetes_version      = "v1.37.1"
  control_plane_count     = 1
  worker_count            = 3
  control_plane_ips       = ["10.0.0.10"]
  worker_ips              = ["10.0.0.20", "10.0.0.21", "10.0.0.22"]
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

run "each_worker_names_only_itself" {
  command = apply
  assert {
    condition = alltrue([for i, ip in var.worker_ips :
    yamldecode(data.talos_machine_configuration.worker[i].config_patches[0]).machine.certSANs == ["127.0.0.1", "localhost", ip]])
    error_message = "a worker's certSANs must be 127.0.0.1, localhost and its own address: another worker's makes every grow re-apply it"
  }
}
