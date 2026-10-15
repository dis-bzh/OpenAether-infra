# Optional artifact_passphrase (the gpg-encrypted access artifacts and etcd snapshots): unset keeps the state passphrase and
# adds nothing to the backup triggers, so a deployed cluster sees no diff; set, it is the secret the backup script receives.
# The local-exec itself (gpg, aws) is not run here, and a mock plan does not expose its environment: scripts/dev/test-restore.sh and
# test-state-backups.sh own the script, test-passphrase.sh greps that backup.tf passes it local.artifact_passphrase.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
mock_provider "local" {}

override_data {
  target = module.scw.data.scaleway_instance_image.talos
  values = { id = "talos-image-id" }
}
override_data {
  target = module.scw.data.scaleway_instance_image.worker
  values = { id = "worker-image-id" }
}
override_resource {
  target = module.scw.scaleway_ipam_ip.control_plane
  values = { id = "10101010-1010-1010-1010-101010101010", address = "10.0.0.10/24" }
}
override_resource {
  target = module.scw.scaleway_ipam_ip.worker
  values = { id = "20202020-2020-2020-2020-202020202020", address = "10.0.0.20/24" }
}
override_resource {
  target = module.scw.scaleway_lb_ip.app
  values = { id = "11111111-1111-1111-1111-111111111111", ip_address = "192.0.2.1" }
}
override_resource {
  target = module.scw.scaleway_lb_ip.k8s
  values = { id = "22222222-2222-2222-2222-222222222222", ip_address = "192.0.2.2" }
}
override_resource {
  target = module.scw.scaleway_instance_ip.bastion
  values = { id = "33333333-3333-3333-3333-333333333333", address = "192.0.2.3" }
}
override_resource {
  target = module.scw.scaleway_vpc_public_gateway_ip.this
  values = { address = "192.0.2.4" }
}
override_resource {
  target = module.scw.scaleway_vpc_public_gateway.this
  values = { id = "44444444-4444-4444-4444-444444444444" }
}
override_resource {
  target = module.scw.scaleway_vpc_private_network.this
  values = { id = "55555555-5555-5555-5555-555555555555" }
}
override_resource {
  target = module.scw.scaleway_lb.app
  values = { id = "66666666-6666-6666-6666-666666666666" }
}
override_resource {
  target = module.scw.scaleway_lb.k8s
  values = { id = "77777777-7777-7777-7777-777777777777" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.k8s_api
  values = { id = "88888888-8888-8888-8888-888888888888" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.http
  values = { id = "99999999-9999-9999-9999-999999999999" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.https
  values = { id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.k8s_api
  values = { id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.http
  values = { id = "cccccccc-cccc-cccc-cccc-cccccccccccc" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.https
  values = { id = "dddddddd-dddd-dddd-dddd-dddddddddddd" }
}
override_resource {
  target = module.scw.scaleway_lb_private_network.app
  values = { id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" }
}
override_resource {
  target = module.scw.scaleway_lb_private_network.k8s
  values = { id = "ffffffff-ffff-ffff-ffff-ffffffffffff" }
}

variables {
  cluster_name            = "talos-test"
  environment             = "dev"
  cluster_role            = "management"
  talos_bootstrap         = true
  skip_port_ready_wait    = true
  secrets_prevent_destroy = false
  backup_enabled          = true
  encryption_passphrase   = "state-passphrase-0123456789abcdefghijklmnop"
  admin_ip                = ["10.0.0.1/32"]
  bastion_ssh_keys = {
    scaleway = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 test@test"]
  }
  node_distribution = {
    scaleway = {
      control_planes = 3
      workers        = 1
      image_name     = "talos"
      instance_type  = "DEV1-S"
      zone           = "fr-par-1"
      region         = "fr-par"
      zones          = ["fr-par-1", "fr-par-2", "fr-par-1"]
    }
  }
  git_repo_url        = "https://github.com/test/repo.git"
  cilium_manifest     = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-config\n  namespace: kube-system"
  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

run "unset_keeps_the_state_passphrase_and_the_old_triggers" {
  command = plan
  assert {
    condition     = local.artifact_passphrase == var.encryption_passphrase
    error_message = "without artifact_passphrase the backups use the state passphrase, as before"
  }
  assert {
    condition     = !contains(keys(terraform_data.backup[0].triggers_replace), "artifact_passphrase")
    error_message = "an unset artifact_passphrase must not change the backup triggers (it would re-upload on every deployed cluster)"
  }
}

run "unset_does_not_make_the_triggers_sensitive" {
  command = plan
  # Whether a second passphrase is set is not a secret; marking it so hides the talosconfig/kubeconfig hash diffs from every plan.
  assert {
    condition     = !issensitive(terraform_data.backup[0].triggers_replace)
    error_message = "an unset artifact_passphrase must leave the backup triggers readable in the plan"
  }
  assert {
    condition     = !issensitive(local.artifact_passphrase_set)
    error_message = "'is a separate artifact passphrase set' is a fact, not a secret"
  }
}

run "empty_counts_as_unset" {
  command = plan
  variables {
    artifact_passphrase = ""
  }
  assert {
    condition     = local.artifact_passphrase == var.encryption_passphrase && !local.artifact_passphrase_set
    error_message = "an empty artifact_passphrase (an exported but blank TF_VAR) means unset"
  }
}

run "set_replaces_the_state_passphrase_and_joins_the_triggers" {
  command = plan
  variables {
    artifact_passphrase = "artifact-passphrase-0123456789abcdefghijklmn"
  }
  assert {
    condition     = local.artifact_passphrase == "artifact-passphrase-0123456789abcdefghijklmn"
    error_message = "the artifact passphrase replaces the state one for the artifacts"
  }
  assert {
    condition     = contains(keys(terraform_data.backup[0].triggers_replace), "artifact_passphrase")
    error_message = "setting it must re-upload the artifacts under the new secret"
  }
}

run "a_short_one_is_refused" {
  command = plan
  variables {
    artifact_passphrase = "too-short"
  }
  expect_failures = [var.artifact_passphrase]
}
