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

# --- Scaleway resource overrides (computed values) ---

override_resource {
  target = module.scw.scaleway_ipam_ip.control_plane
  values = {
    id      = "ipam-cp"
    address = "10.0.0.10/24"
  }
}

override_resource {
  target = module.scw.scaleway_ipam_ip.worker
  values = {
    id      = "ipam-worker"
    address = "10.0.0.20/24"
  }
}

override_resource {
  target = module.scw.scaleway_lb_ip.app
  values = {
    id         = "11111111-1111-1111-1111-111111111111"
    ip_address = "192.0.2.1"
  }
}

override_resource {
  target = module.scw.scaleway_lb_ip.k8s
  values = {
    id         = "22222222-2222-2222-2222-222222222222"
    ip_address = "192.0.2.2"
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

# ==============================================================================
# Shared Test Variables (Scaleway HA configuration)
# ==============================================================================

variables {
  cluster_name            = "test-cluster"
  environment             = "dev"
  cluster_role            = "management"
  talos_bootstrap         = true
  skip_port_ready_wait    = true  # local-exec TCP wait isn't mocked — see modules/talos/variables.tf
  secrets_prevent_destroy = false # tofu test's post-run cleanup destroys apply-mode state — see cluster/variables.tf
  backup_enabled          = false # backups run a local-exec (aws s3 cp); skip in tests
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
    }
  }
  git_repo_url = "https://github.com/test/repo.git"

  # Non-placeholder manifest to pass precondition
  cilium_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"

  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

# ==============================================================================
# Test 1: Module Activation — SCW module activates when nodes configured
# ==============================================================================

run "verify_scw_module_activation" {
  command = plan

  assert {
    condition     = length(module.scw) == 1
    error_message = "SCW module should be active when nodes are configured."
  }

  assert {
    condition     = length(module.ovh) == 0
    error_message = "OVH module should be inactive when not in node_distribution."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Outscale module should be inactive when not in node_distribution."
  }
}

# ==============================================================================
# Test 2: Variable Validation — HA requirements
# ==============================================================================

run "verify_variable_validation" {
  command = plan

  assert {
    condition     = var.node_distribution.scaleway.control_planes == 3
    error_message = "Control plane count should be 3 for HA."
  }

  assert {
    condition     = length(var.node_distribution.scaleway.zones) >= 2
    error_message = "Control planes should span at least 2 zones for HA."
  }
}

# ==============================================================================
# Test 3: cluster_role variable is valid
# ==============================================================================

run "verify_cluster_role" {
  command = plan

  assert {
    condition     = var.cluster_role == "management"
    error_message = "cluster_role should be management for this test."
  }
}

# ==============================================================================
# Test 4: Bastion Configuration — SSH key must be present
# ==============================================================================

run "verify_bastion_config" {
  command = plan

  assert {
    condition     = length(var.bastion_ssh_keys.scaleway) > 0
    error_message = "Bastion SSH key cannot be empty."
  }
}

# ==============================================================================
# Test 4b: Security Groups — no inbound rule opens every port (#79)
# ==============================================================================

# Judged as the provider sends a rule: a non-empty port_range wins over port,
# and port 0, "0-0" or no port at all means every port. A mock plans an omitted
# port as null, so null counts as 0 here.
run "verify_no_all_ports_inbound_rule" {
  command = plan

  variables {
    deploy_app_lb = true
  }

  # Every group, the bastion's included.
  assert {
    condition = length(flatten(values(module.scw[0].inbound_rules))) > 0 && alltrue([
      for r in flatten(values(module.scw[0].inbound_rules)) :
      r.protocol == "ICMP" || (contains(["TCP", "UDP"], r.protocol) && (
        r.port_range != null && r.port_range != "" ?
        try(tonumber(split("-", r.port_range)[0]) > 0 && (tonumber(split("-", r.port_range)[0]) > 1 || tonumber(split("-", r.port_range)[1]) < 65535), false) :
        try(r.port > 0, false)
    ))])
    error_message = "An SCW inbound_rule may open every port: ANY, no port, port 0, a range from 0 (0-0 included), or 1-65535 (#79)."
  }

  # Node groups hold exactly the reviewed list, so a port added, widened,
  # duplicated or opened to the carrier range turns this red.
  assert {
    condition = length(module.scw[0].inbound_rules) > 1 && alltrue([
      for k, rs in module.scw[0].inbound_rules : k == "bastion" || sort([
        for r in rs : "${r.protocol} ${r.port_range != null ? r.port_range : (r.port != null ? tostring(r.port) : "-")} ${r.ip_range}"
        ]) == sort(concat(
        [for p in ["TCP 6443", "TCP 50000", "TCP 50001", "TCP 2379-2381", "TCP 10250", "UDP 8472", "UDP 51871",
        "TCP 4240", "ICMP -", "TCP 9962-9964", "TCP 9100", "UDP 68", "TCP 30080", "TCP 30443"] : "${p} 172.16.0.0/22"],
        [for p in ["TCP 6443", "TCP 30080", "TCP 30443"] : "${p} 100.64.0.0/10"],
      ))
    ])
    error_message = "An SCW node security group differs from the reviewed port list: a new port needs its evidence in security.tf, then an entry in each pinned list (#79)."
  }
}

# Root defaults: no App LB, so no NodePorts, and the carrier range keeps 6443
# only. The bastion does not vary with these variables: checked above.
run "verify_node_inbound_rules_defaults" {
  command = plan

  assert {
    condition = length(module.scw[0].inbound_rules) > 1 && alltrue([
      for k, rs in module.scw[0].inbound_rules : k == "bastion" || sort([
        for r in rs : "${r.protocol} ${r.port_range != null ? r.port_range : (r.port != null ? tostring(r.port) : "-")} ${r.ip_range}"
        ]) == sort(concat(
        [for p in ["TCP 6443", "TCP 50000", "TCP 50001", "TCP 2379-2381", "TCP 10250", "UDP 8472", "UDP 51871",
        "TCP 4240", "ICMP -", "TCP 9962-9964", "TCP 9100", "UDP 68"] : "${p} 172.16.0.0/22"],
        ["TCP 6443 100.64.0.0/10"],
      ))
    ])
    error_message = "With the root defaults, an SCW node security group differs from the reviewed port list (#79)."
  }
}

# ==============================================================================
# Test 5: Provider Contract — SCW outputs conform to provider-contract.md
# ==============================================================================

run "verify_provider_contract" {
  command = apply

  assert {
    condition     = output.bastion_ip != null && output.bastion_ip != "N/A"
    error_message = "Provider contract: bastion_ip must be available."
  }

  assert {
    condition     = output.k8s_lb_ip != null && output.k8s_lb_ip != ""
    error_message = "Provider contract: k8s_lb_ip must be available."
  }

  assert {
    condition     = output.talosconfig != null
    error_message = "Talos module: talosconfig must be defined."
  }

  assert {
    condition     = length(output.control_plane_private_ips) == 3
    error_message = "Provider contract: should have 3 control plane IPs for HA."
  }

  assert {
    condition     = length(output.worker_private_ips) == 1
    error_message = "Provider contract: should have 1 worker IP."
  }

  assert {
    condition     = output.active_provider == "scaleway"
    error_message = "active_provider should be 'scaleway' when SCW nodes are configured."
  }

  assert {
    condition     = output.cluster_role == "management"
    error_message = "cluster_role should be 'management' for this test."
  }
}

# ==============================================================================
# Test 6: Phase 1 Only — talos_bootstrap=false should not create Talos resources
# ==============================================================================

run "verify_phase1_no_talos_apply" {
  command = plan

  variables {
    talos_bootstrap = false
  }

  assert {
    condition     = length(module.scw) == 1
    error_message = "SCW infra module should still be active in Phase 1."
  }
}

# ==============================================================================
# Test 7: Provider Disabled — empty node_distribution creates nothing
# ==============================================================================

run "verify_provider_disabled" {
  command = plan

  variables {
    node_distribution = {}
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when node_distribution is empty."
  }

  assert {
    condition     = length(module.ovh) == 0
    error_message = "OVH module should be inactive when node_distribution is empty."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Outscale module should be inactive when node_distribution is empty."
  }
}

# ==============================================================================
# Test 8: OVH module activates with OVH node distribution
# ==============================================================================

run "verify_ovh_module_activation" {
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
        availability_zones = ["nova"]
      }
    }
  }

  assert {
    condition     = length(module.ovh) == 1
    error_message = "OVH module should be active when OVH nodes are configured."
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when only OVH is configured."
  }
}

# ==============================================================================
# Test 9: Outscale module activates with Outscale node distribution
# ==============================================================================

run "verify_outscale_module_activation" {
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
    error_message = "Outscale module should be active when Outscale nodes are configured."
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when only Outscale is configured."
  }
}
