mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
# The `local` provider must be mocked too. local_file writes kubeconfig and
# talosconfig into the module directory, so an unmocked test run overwrites a
# live cluster's credentials and then DELETES them on teardown.
mock_provider "local" {}


# No override_data/override_resource needed (bar the bastion VM's snippet id in
# verify_bastion_user_vm_bastion): unlike the cloud providers,
# every Proxmox provider-contract output (control_plane_private_ips,
# worker_private_ips, k8s_lb_ip, bastion_ip, bastion_user,
# worker_ingress_targets) is derived from cidrhost()/variables in
# modules/providers/proxmox — never from an actual resource attribute the
# mock provider would need to fabricate. See network.tf/outputs.tf there.

# ==============================================================================
# Shared Test Variables (Proxmox non-HA: 1 CP + 1 worker on a single host)
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

  node_distribution = {
    proxmox = {
      control_planes = 1
      workers        = 1
      node_names     = ["pve1"]
      gateway_ip     = "10.0.0.1"
      apiserver_vip  = "10.0.0.100"
      host_public_ip = "203.0.113.10"
      # talos_image_file_id deliberately omitted — exercises the by-name
      # convention fallback (local.pmx_talos_image_file_id in cluster/main.tf).
    }
  }

  git_repo_url = "https://github.com/test/repo.git"

  # Non-placeholder manifest to pass the Cilium precondition
  cilium_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"

  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

# ==============================================================================
# Test 1: Module Activation — Proxmox module activates when nodes configured
# ==============================================================================

run "verify_proxmox_module_activation" {
  command = plan

  assert {
    condition     = length(module.proxmox) == 1
    error_message = "Proxmox module should be active when nodes are configured."
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when only Proxmox is configured."
  }

  assert {
    condition     = length(module.ovh) == 0
    error_message = "OVH module should be inactive when only Proxmox is configured."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Outscale module should be inactive when only Proxmox is configured."
  }
}

# ==============================================================================
# Test 2: Provider Contract — Proxmox outputs conform to provider-contract.md
# ==============================================================================

run "verify_provider_contract" {
  command = apply

  assert {
    condition     = output.active_provider == "proxmox"
    error_message = "active_provider should be 'proxmox' when Proxmox nodes are configured."
  }

  assert {
    condition     = output.k8s_lb_ip == "10.0.0.100"
    error_message = "Provider contract: k8s_lb_ip should be the apiserver_vip (no managed LB on Proxmox)."
  }

  assert {
    condition     = length(output.control_plane_private_ips) == 1 && output.control_plane_private_ips[0] == "10.0.0.10"
    error_message = "Control plane IP should be cidrhost(network_cidr, control_plane_ip_offset)."
  }

  assert {
    condition     = output.control_plane_zones == ["pve1"]
    error_message = "control_plane_zones should be the Proxmox host running the control plane."
  }

  assert {
    condition     = length(output.worker_private_ips) == 1 && output.worker_private_ips[0] == "10.0.0.20"
    error_message = "Worker IP should be cidrhost(network_cidr, worker_ip_offset)."
  }

  assert {
    condition     = output.worker_ingress_targets != null && output.worker_ingress_targets[0] == "10.0.0.20"
    error_message = "worker_ingress_targets should surface the worker IPs (no managed app LB on Proxmox)."
  }

  assert {
    condition     = output.bastion_ip == "203.0.113.10"
    error_message = "bastion_ip should default to the Proxmox host's public IP (host-as-bastion, enable_bastion=false)."
  }

  assert {
    condition     = output.bastion_user == "root"
    error_message = "bastion_user should default to host_ssh_user ('root') for host-as-bastion."
  }

  assert {
    condition     = output.talosconfig != null
    error_message = "Talos module: talosconfig must be defined."
  }

  assert {
    condition     = output.cluster_role == "management"
    error_message = "cluster_role should be 'management' for this test."
  }
}

# ==============================================================================
# Test 2b: bastion_user — the root reports what the module reports (VM bastion
# creates "ubuntu"; host-as-bastion uses host_ssh_user), not pmx_dist's value.
# ==============================================================================

run "verify_bastion_user_vm_bastion" {
  command = plan

  variables {
    node_distribution = {
      proxmox = {
        control_planes = 1
        workers        = 1
        node_names     = ["pve1"]
        gateway_ip     = "10.0.0.1"
        apiserver_vip  = "10.0.0.100"
        host_public_ip = "203.0.113.10"
        host_ssh_user  = "pmxadmin"
        enable_bastion = true
      }
    }
  }

  # The VM resource validates user_data_file_id's shape; the mock's random id fails it.
  override_resource {
    target = module.proxmox.proxmox_virtual_environment_file.bastion_cloud_init
    values = { id = "local:snippets/test-cluster-dev-bastion-cloud-init.yaml" }
  }

  assert {
    condition     = output.bastion_user == module.proxmox[0].bastion_user
    error_message = "Root bastion_user must be the Proxmox module's output, not re-derived from host_ssh_user."
  }

  assert {
    condition     = output.bastion_user == "ubuntu"
    error_message = "With enable_bastion=true the VM bastion's user is 'ubuntu' whatever host_ssh_user says."
  }
}

run "verify_bastion_user_host_as_bastion" {
  command = plan

  variables {
    node_distribution = {
      proxmox = {
        control_planes = 1
        workers        = 1
        node_names     = ["pve1"]
        gateway_ip     = "10.0.0.1"
        apiserver_vip  = "10.0.0.100"
        host_public_ip = "203.0.113.10"
        host_ssh_user  = "pmxadmin"
      }
    }
  }

  assert {
    condition     = output.bastion_user == module.proxmox[0].bastion_user && output.bastion_user == "pmxadmin"
    error_message = "With enable_bastion=false the root reports host_ssh_user, as the module does."
  }
}

# ==============================================================================
# Test 3: apiserver VIP wiring — Proxmox always injects its VIP into Talos
# ==============================================================================

run "verify_apiserver_vip_wiring" {
  command = plan

  assert {
    condition     = module.talos.apiserver_vip == "10.0.0.100"
    error_message = "modules/talos should receive Proxmox's apiserver_vip."
  }

  assert {
    condition     = module.talos.cluster_endpoint == "https://10.0.0.100:6443"
    error_message = "cluster_endpoint should point at the VIP, not a raw node IP."
  }
}

# ==============================================================================
# Test 4: Phase 1 Only — talos_bootstrap=false should not create Talos resources
# ==============================================================================

run "verify_phase1_no_talos_apply" {
  command = plan

  variables {
    talos_bootstrap = false
  }

  assert {
    condition     = length(module.proxmox) == 1
    error_message = "Proxmox infra module should still be active in Phase 1."
  }

  assert {
    condition     = module.talos.control_plane_count == 0
    error_message = "modules/talos should have zero control planes in Phase 1 (talos_bootstrap=false)."
  }
}

# ==============================================================================
# Test 5: HA round-robin — 3 control planes across 3 physical hosts
# ==============================================================================

run "verify_proxmox_ha_round_robin" {
  command = plan

  variables {
    node_distribution = {
      proxmox = {
        control_planes = 3
        workers        = 1
        node_names     = ["pve1", "pve2", "pve3"]
        gateway_ip     = "10.0.0.1"
        apiserver_vip  = "10.0.0.100"
        host_public_ip = "203.0.113.10"
      }
    }
  }

  assert {
    condition     = length(module.proxmox) == 1
    error_message = "Proxmox module should be active for the HA distribution."
  }

  assert {
    condition     = var.node_distribution.proxmox.control_planes == 3
    error_message = "Control plane count should be 3 for HA."
  }

  assert {
    condition     = length(var.node_distribution.proxmox.node_names) == 3
    error_message = "HA requires 3 distinct node_names (1 CP per physical host)."
  }

  assert {
    condition     = output.control_plane_zones == ["pve1", "pve2", "pve3"]
    error_message = "control_plane_zones should list one distinct host per control plane."
  }
}

# ==============================================================================
# Test 6: Image file_id convention — falls back to the talos-image download
# path when talos_image_file_id is left unset (see cluster/main.tf's
# local.pmx_talos_image_file_id and modules/talos-image/proxmox).
# ==============================================================================

run "verify_image_file_id_convention" {
  command = plan

  assert {
    condition     = output.resolved_image_ref == "local:iso/talos-${trimprefix(var.talos_version, "v")}-nocloud-amd64.img"
    error_message = "resolved_image_ref should default to <iso_datastore_id>:iso/talos-<version>-nocloud-amd64.img when talos_image_file_id is unset."
  }
}

# ==============================================================================
# Test 7: Explicit talos_image_file_id overrides the convention
# ==============================================================================

run "verify_image_file_id_explicit_override" {
  command = plan

  variables {
    node_distribution = {
      proxmox = {
        control_planes      = 1
        workers             = 1
        node_names          = ["pve1"]
        gateway_ip          = "10.0.0.1"
        apiserver_vip       = "10.0.0.100"
        host_public_ip      = "203.0.113.10"
        talos_image_file_id = "local:iso/custom-image.img"
      }
    }
  }

  assert {
    condition     = output.resolved_image_ref == "local:iso/custom-image.img"
    error_message = "An explicit talos_image_file_id should override the convention default."
  }
}
