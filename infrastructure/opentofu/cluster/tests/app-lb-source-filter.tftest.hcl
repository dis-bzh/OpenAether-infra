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

# The app LB source filter (app_lb_allowed_cidrs): empty = no ACL anywhere (the historical
# behaviour), set = allow-list then deny on Scaleway, allowed_cidrs on OVH, security-group
# rules on Outscale. Mocked rung: this proves what is PLANNED, not what a cloud enforces.

variables {
  cluster_name            = "test-cluster"
  environment             = "dev"
  cluster_role            = "management"
  talos_bootstrap         = false
  skip_port_ready_wait    = true
  secrets_prevent_destroy = false
  backup_enabled          = false
  deploy_app_lb           = true
  admin_ip                = ["1.2.3.4/32"]
  bastion_ssh_keys = {
    scaleway = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y94C3NzaC1lZDI1NTE5AAAAIOMpj9y9"]
    ovh      = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y94C3NzaC1lZDI1NTE5AAAAIOMpj9y9"]
    outscale = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y94C3NzaC1lZDI1NTE5AAAAIOMpj9y9"]
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

# --- Scaleway ---

run "scw_default_has_no_acl" {
  command = plan

  assert {
    condition     = module.scw[0].app_lb_acls.http == [] && module.scw[0].app_lb_acls.https == []
    error_message = "With app_lb_allowed_cidrs empty the app LB frontends must carry no ACL: the default is the old behaviour."
  }
}

# Order matters to the LB: the allow rule must come before the final deny.
run "scw_allow_list_then_deny_on_both_frontends" {
  command = plan

  variables {
    app_lb_allowed_cidrs = ["203.0.113.0/24", "198.51.100.7/32"]
  }

  assert {
    condition = alltrue([for k in ["http", "https"] : module.scw[0].app_lb_acls[k] == [
      "allow 203.0.113.0/24,198.51.100.7/32,172.16.0.0/12,10.0.0.0/8,192.0.2.4/32",
      "deny 0.0.0.0/0",
    ]])
    error_message = "Scaleway: expected allow(caller list + VPC ranges + NAT egress) then deny 0.0.0.0/0 on both frontends."
  }
}

run "scw_acl_needs_the_app_lb" {
  command = plan

  variables {
    deploy_app_lb        = false
    app_lb_allowed_cidrs = ["203.0.113.0/24"]
  }

  expect_failures = [check.app_lb_allowed_cidrs_applies]

  assert {
    condition     = module.scw[0].app_lb_acls.http == [] && module.scw[0].app_lb_acls.https == []
    error_message = "Without deploy_app_lb there is no frontend, hence no ACL."
  }
}

# --- Input validation (root level) ---

run "open_list_is_accepted" {
  command = plan

  variables {
    app_lb_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = alltrue([for k in ["http", "https"] : module.scw[0].app_lb_acls[k][1] == "deny 0.0.0.0/0"])
    error_message = "0.0.0.0/0 is the explicit 'machinery on, still open' stage and must be accepted."
  }
}

run "a_bare_address_is_refused" {
  command = plan

  variables {
    app_lb_allowed_cidrs = ["203.0.113.4"]
  }

  expect_failures = [var.app_lb_allowed_cidrs]
}

run "an_ipv6_cidr_is_refused" {
  command = plan

  variables {
    app_lb_allowed_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.app_lb_allowed_cidrs]
}

# --- OVH ---

run "ovh_default_listeners_are_unfiltered" {
  command = plan

  variables {
    node_distribution = {
      ovh = {
        control_planes     = 3
        workers            = 1
        region             = "EU-WEST-PAR"
        flavor_name        = "b3-8"
        image_id           = "dummy-talos-ovh-image"
        network_name       = "Ext-Net"
        availability_zones = ["eu-west-par-a"]
        k8s_lb_mode        = "vip"
      }
    }
  }

  assert {
    condition     = module.ovh[0].app_lb_allowed_cidrs.http == null && module.ovh[0].app_lb_allowed_cidrs.https == null
    error_message = "OVH: no allowed_cidrs on the app listeners while app_lb_allowed_cidrs is empty."
  }
}

run "ovh_listeners_take_the_sorted_list" {
  command = plan

  variables {
    app_lb_allowed_cidrs = ["203.0.113.0/24", "198.51.100.7/32"]
    node_distribution = {
      ovh = {
        control_planes     = 3
        workers            = 1
        region             = "EU-WEST-PAR"
        flavor_name        = "b3-8"
        image_id           = "dummy-talos-ovh-image"
        network_name       = "Ext-Net"
        availability_zones = ["eu-west-par-a"]
        k8s_lb_mode        = "vip"
      }
    }
  }

  assert {
    condition     = alltrue([for k in ["http", "https"] : contains(module.ovh[0].app_lb_allowed_cidrs[k], "203.0.113.0/24") && contains(module.ovh[0].app_lb_allowed_cidrs[k], "198.51.100.7/32") && contains(module.ovh[0].app_lb_allowed_cidrs[k], "10.0.0.0/24")])
    error_message = "OVH: both listeners must carry the caller list and the node subnet."
  }

  assert {
    condition     = alltrue([for k in ["http", "https"] : module.ovh[0].app_lb_allowed_cidrs[k] == sort(module.ovh[0].app_lb_allowed_cidrs[k])])
    error_message = "OVH: allowed_cidrs must be sorted, Octavia returns it sorted and an unsorted list diffs forever."
  }
}

# --- Outscale ---

run "outscale_default_has_no_lb_rule" {
  command = plan

  variables {
    node_distribution = {
      outscale = {
        control_planes     = 3
        workers            = 1
        region             = "eu-west-2"
        instance_type      = "tinav5.c2r4p1"
        image_id           = "dummy-talos-osc-image"
        availability_zones = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
        bastion_image_id   = "ami-ubuntu-2204-mock"
      }
    }
  }

  assert {
    condition     = length(module.outscale[0].app_lb_sources.http) == 0 && length(module.outscale[0].app_lb_sources.https) == 0
    error_message = "Outscale: no 80/443 rule while app_lb_allowed_cidrs is empty."
  }
}

run "outscale_rules_admit_the_list_and_the_nat" {
  command = plan

  variables {
    app_lb_allowed_cidrs = ["203.0.113.0/24", "198.51.100.7/32"]
    node_distribution = {
      outscale = {
        control_planes     = 3
        workers            = 1
        region             = "eu-west-2"
        instance_type      = "tinav5.c2r4p1"
        image_id           = "dummy-talos-osc-image"
        availability_zones = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
        bastion_image_id   = "ami-ubuntu-2204-mock"
      }
    }
  }

  assert {
    condition     = alltrue([for k in ["http", "https"] : join(",", module.outscale[0].app_lb_sources[k]) == "198.51.100.7/32,203.0.113.0/24,cluster-egress"])
    error_message = "Outscale: ports 80 and 443 must admit the caller list and the cluster's NAT address, nothing else."
  }
}
