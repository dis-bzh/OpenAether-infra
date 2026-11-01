# Audit sink (infra #318): the variables, their validation and the placement check. Same fixture as backup-immutability.tftest.hcl.
mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
# The `local` provider must be mocked too. local_file writes kubeconfig and
# talosconfig into the module directory, so an unmocked test run overwrites a
# live cluster's credentials and then DELETES them on teardown.
mock_provider "local" {}


# --- Scaleway image data sources ---

override_data {
  target = module.scw.data.scaleway_instance_image.talos
  values = { id = "dummy-talos-id" }
}

override_data {
  target = module.scw.data.scaleway_instance_image.worker
  values = { id = "dummy-worker-id" }
}

# --- Scaleway resource overrides (vip mode: no k8s LB resources, as in k8s-lb-mode.tftest.hcl) ---

override_resource {
  target = module.scw.scaleway_ipam_ip.control_plane
  values = { id = "ipam-cp", address = "10.0.0.10/24" }
}

override_resource {
  target = module.scw.scaleway_ipam_ip.worker
  values = { id = "ipam-worker", address = "10.0.0.20/24" }
}

override_resource {
  target = module.scw.scaleway_ipam_ip.k8s_vip
  values = { id = "ipam-vip", address = "10.0.0.99/24" }
}

override_resource {
  target = module.scw.scaleway_lb_ip.app
  values = {
    id         = "11111111-1111-1111-1111-111111111111"
    ip_address = "192.0.2.1"
  }
}

override_resource {
  target = module.scw.scaleway_instance_ip.bastion
  values = {
    id      = "33333333-3333-3333-3333-333333333333"
    address = "192.0.2.3"
  }
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
  target = module.scw.scaleway_lb_backend.http
  values = { id = "99999999-9999-9999-9999-999999999999" }
}

override_resource {
  target = module.scw.scaleway_lb_backend.https
  values = { id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
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

# backup_immutability / backup_retention_days: read by scripts/internal/ensure-buckets.sh, not by any resource, so what
# this proves is the input rules and the warning for a lock that cannot be undone. The script is test-bucket-protection.sh.

variables {
  cluster_name            = "test-cluster"
  environment             = "dev"
  cluster_role            = "management"
  talos_bootstrap         = false
  skip_port_ready_wait    = true
  secrets_prevent_destroy = false
  backup_enabled          = false
  admin_ip                = ["1.2.3.4/32"]
  bastion_ssh_keys = {
    scaleway = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y94C3NzaC1lZDI1NTE5AAAAIOMpj9y9"]
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
      k8s_lb_mode    = "vip"
    }
  }
  git_repo_url    = "https://github.com/test/repo.git"
  cilium_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"

  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

run "default_is_off_and_changes_nothing" {
  command = plan

  assert {
    condition     = var.audit_sink_placement == "off" && var.audit_sink_lock_mode == "governance" && var.audit_sink_retention_days == 365 && var.audit_sink_prefix == "audit" && !var.audit_sink_compliance_ack
    error_message = "The defaults must be: off, governance, 365 days, prefix audit, no compliance opt-in."
  }
  assert {
    condition     = local.audit_sink_host == "" && local.audit_sink_secondary_host == ""
    error_message = "Off must publish no host name in the cluster identity."
  }
}

run "an_unknown_placement_is_refused" {
  command = plan
  variables {
    audit_sink_placement = "anywhere"
  }
  expect_failures = [var.audit_sink_placement]
}

run "a_placement_without_an_endpoint_is_refused" {
  command = plan
  variables {
    audit_sink_placement = "other_provider"
  }
  expect_failures = [var.audit_sink_placement]
}

run "both_needs_the_secondary_sink" {
  command = plan
  variables {
    audit_sink_placement = "both"
    audit_sink_endpoint  = "https://s3.gra.io.cloud.ovh.net"
    audit_sink_region    = "gra"
  }
  expect_failures = [var.audit_sink_placement]
}

run "compliance_needs_the_explicit_opt_in" {
  command = plan
  variables {
    audit_sink_lock_mode = "compliance"
  }
  expect_failures = [var.audit_sink_lock_mode]
}

run "compliance_with_the_opt_in_is_accepted" {
  command = plan
  variables {
    audit_sink_lock_mode      = "compliance"
    audit_sink_compliance_ack = true
  }
}

run "a_retention_of_zero_is_refused" {
  command = plan
  variables {
    audit_sink_retention_days = 0
  }
  expect_failures = [var.audit_sink_retention_days]
}

run "another_provider_is_accepted_and_publishes_its_host" {
  command = plan
  variables {
    audit_sink_placement = "other_provider"
    audit_sink_endpoint  = "https://s3.gra.io.cloud.ovh.net"
    audit_sink_region    = "gra"
  }
  assert {
    condition     = local.audit_sink_host == "s3.gra.io.cloud.ovh.net" && local.audit_sink_secondary_host == ""
    error_message = "The host (no scheme, no port) must reach the cluster identity."
  }
}

run "other_provider_on_the_clusters_own_provider_warns" {
  command = plan
  variables {
    audit_sink_placement = "other_provider"
    audit_sink_endpoint  = "https://s3.nl-ams.scw.cloud"
    audit_sink_region    = "nl-ams"
  }
  expect_failures = [check.audit_sink_placement_matches_providers]
}

run "same_provider_in_another_region_is_accepted" {
  command = plan
  variables {
    audit_sink_placement = "same_provider_other_region"
    audit_sink_endpoint  = "https://s3.nl-ams.scw.cloud"
    audit_sink_region    = "nl-ams"
  }
}

run "same_provider_in_the_same_region_warns" {
  command = plan
  variables {
    audit_sink_placement = "same_provider_other_region"
    audit_sink_endpoint  = "https://s3.fr-par.scw.cloud"
    audit_sink_region    = "fr-par"
  }
  expect_failures = [check.audit_sink_placement_matches_providers]
}

run "same_provider_on_another_cloud_warns" {
  command = plan
  variables {
    audit_sink_placement = "same_provider_other_region"
    audit_sink_endpoint  = "https://s3.gra.io.cloud.ovh.net"
    audit_sink_region    = "gra"
  }
  expect_failures = [check.audit_sink_placement_matches_providers]
}

run "both_is_accepted_with_one_of_each" {
  command = plan
  variables {
    audit_sink_placement          = "both"
    audit_sink_endpoint           = "https://s3.gra.io.cloud.ovh.net"
    audit_sink_region             = "gra"
    audit_sink_secondary_endpoint = "https://s3.nl-ams.scw.cloud"
    audit_sink_secondary_region   = "nl-ams"
  }
  assert {
    condition     = local.audit_sink_host == "s3.gra.io.cloud.ovh.net" && local.audit_sink_secondary_host == "s3.nl-ams.scw.cloud"
    error_message = "Both hosts must reach the cluster identity."
  }
}
