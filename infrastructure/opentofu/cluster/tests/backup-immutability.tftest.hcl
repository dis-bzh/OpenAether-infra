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

run "default_is_off_and_sixty_days" {
  command = plan

  assert {
    condition     = var.backup_immutability == "off" && var.backup_retention_days == 60
    error_message = "The defaults must keep a deployed cluster unchanged: off, 60 days."
  }
}

run "the_three_modes_are_accepted" {
  command = plan

  variables {
    backup_immutability = "governance"
  }

  assert {
    condition     = var.backup_immutability == "governance"
    error_message = "governance must be accepted."
  }
}

run "an_unknown_mode_is_refused" {
  command = plan

  variables {
    backup_immutability = "locked"
  }

  expect_failures = [var.backup_immutability]
}

run "a_retention_of_zero_is_refused" {
  command = plan

  variables {
    backup_retention_days = 0
  }

  expect_failures = [var.backup_retention_days]
}

run "a_fractional_retention_is_refused" {
  command = plan

  variables {
    backup_retention_days = 1.5
  }

  expect_failures = [var.backup_retention_days]
}

run "compliance_on_dev_for_two_months_warns" {
  command = plan

  variables {
    backup_immutability = "compliance"
  }

  expect_failures = [check.compliance_lock_on_dev]
}

run "compliance_on_dev_for_a_week_does_not" {
  command = plan

  variables {
    backup_immutability   = "compliance"
    backup_retention_days = 7
  }

  assert {
    condition     = var.backup_retention_days == 7
    error_message = "A one-week compliance lock on dev is the documented way to try it."
  }
}
