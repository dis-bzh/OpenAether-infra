# #346: an existing cluster built with the old 32-character LUKS passphrase must keep it when the default
# becomes 40; a regenerated passphrase would leave the sealed partitions unable to unlock after a reboot.
# Mocked rung: the state is a mock apply of the passphrase alone, not a node.

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
  config_delivery         = "userdata"
  cilium_manifest         = "apiVersion: v1\nkind: ConfigMap\n"
  skip_health_check       = true
  secrets_prevent_destroy = false
}

run "existing_cluster_built_at_32" {
  command = apply
  plan_options { target = [random_password.disk_encryption_secret] }
  variables {
    disk_encryption_passphrase_length = 32
  }
  assert {
    condition     = random_password.disk_encryption_secret.length == 32
    error_message = "setup: the existing passphrase must be 32 characters"
  }
}

run "the_new_default_does_not_regenerate_it" {
  command = plan
  plan_options { target = [random_password.disk_encryption_secret] }
  assert {
    condition     = random_password.disk_encryption_secret.length == 32
    error_message = "a length change must not reach an existing passphrase: it would be regenerated and the sealed partitions would not unlock"
  }
}
