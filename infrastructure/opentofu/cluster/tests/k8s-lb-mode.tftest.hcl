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

# --- Scaleway resource overrides — k8s_lb_mode = "vip": no k8s LB resources
# exist (count=0), so only the always-present resources + the new k8s_vip
# reservation need values (compare to scaleway.tftest.hcl's "managed"-mode set,
# which instead overrides scaleway_lb.k8s/scaleway_lb_ip.k8s/etc.). ---

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

# ==============================================================================
# Shared Test Variables — Scaleway, k8s_lb_mode = "vip"
# ==============================================================================

variables {
  cluster_name            = "test-cluster"
  environment             = "dev"
  cluster_role            = "management"
  talos_bootstrap         = true
  skip_port_ready_wait    = true  # local-exec TCP wait isn't mocked — see modules/talos/variables.tf
  secrets_prevent_destroy = false # tofu test's post-run cleanup destroys apply-mode state — see cluster/variables.tf
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

# ==============================================================================
# Test 1: Scaleway vip mode — no managed LB, VIP wired into modules/talos
# ==============================================================================

run "scw_vip_mode_contract" {
  command = apply

  assert {
    condition     = length(module.scw) == 1
    error_message = "SCW module should activate."
  }

  assert {
    condition     = output.k8s_lb_ip == "10.0.0.99"
    error_message = "k8s_lb_ip should resolve to the reserved private VIP address in vip mode, not a managed LB IP."
  }

  assert {
    condition     = module.talos.apiserver_vip == "10.0.0.99"
    error_message = "modules/talos should receive the cloud's VIP when k8s_lb_mode=vip."
  }

  assert {
    condition     = module.talos.cluster_endpoint == "https://10.0.0.99:6443"
    error_message = "cluster_endpoint should point at the VIP in vip mode."
  }

  # No k8s LB and no App LB: no LB backend port, so no carrier-range rule (#79).
  assert {
    condition = length(module.scw[0].inbound_rules) > 1 && alltrue([
      for k, rs in module.scw[0].inbound_rules : k == "bastion" || sort([
        for r in rs : "${r.protocol} ${r.port_range != null ? r.port_range : (r.port != null ? tostring(r.port) : "-")} ${r.ip_range}"
        ]) == sort([for p in ["TCP 6443", "TCP 50000", "TCP 50001", "TCP 2379-2381", "TCP 10250", "UDP 8472", "UDP 51871",
      "TCP 4240", "ICMP -", "TCP 9962-9964", "TCP 9100", "UDP 68"] : "${p} 172.16.0.0/22"])
    ])
    error_message = "In vip mode, an SCW node security group differs from the reviewed port list (#79)."
  }
}

# ==============================================================================
# Test 2: OVH vip mode — VIP wired into modules/talos (plan only; OVH's fuller
# apply-mode contract coverage is out of scope here, see scaleway.tftest.hcl
# for the pattern an ovh.tftest.hcl would follow).
# ==============================================================================

run "ovh_vip_mode_plan" {
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
    condition     = length(module.ovh) == 1
    error_message = "OVH module should activate."
  }

  assert {
    condition     = module.talos.apiserver_vip != null
    error_message = "modules/talos should receive a non-null VIP when OVH k8s_lb_mode=vip."
  }
}

# ==============================================================================
# Test 3: Outscale — k8s_lb_mode defaults to "managed" (the only mode it
# supports). Its own variable validation (modules/providers/outscale/
# variables.tf) rejects "vip", but that validation lives inside a NESTED
# module — like the Cilium placeholder precondition in modules/talos (see the
# comment in talos-config.tftest.hcl), expect_failures can only target
# root-level checkable objects, so the rejection itself can't be exercised
# from this root test suite. Confirm it manually: `tofu plan` with
# node_distribution.outscale.k8s_lb_mode = "vip" must fail validation.
# ==============================================================================

run "outscale_k8s_lb_mode_defaults_managed" {
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
    condition     = length(module.outscale) == 1
    error_message = "Outscale module should activate."
  }

  assert {
    condition     = var.node_distribution.outscale.k8s_lb_mode == "managed"
    error_message = "Outscale k8s_lb_mode should default to managed."
  }

  assert {
    condition     = module.talos.apiserver_vip == null
    error_message = "modules/talos should receive no VIP for Outscale (managed mode, no vip support)."
  }
}
