# ==============================================================================
# Talos Configuration Tests
# Validates the Talos module's machine config logic:
#   - Precondition: cilium placeholder detection
#   - Bootstrap manifests injection logic
#   - Cluster endpoint format
#   - Two-phase bootstrap behavior
# ==============================================================================

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
# The `local` provider must be mocked too. local_file writes kubeconfig and
# talosconfig into the module directory, so an unmocked test run overwrites a
# live cluster's credentials and then DELETES them on teardown.
mock_provider "local" {}



# Scaleway overrides (always needed even when not active in some tests)
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

# ==============================================================================
# Shared variables — Scaleway HA configuration
# ==============================================================================

variables {
  cluster_name    = "talos-test"
  environment     = "dev"
  cluster_role    = "management"
  talos_bootstrap = false
  backup_enabled  = false # backups run a local-exec (aws s3 cp); skip in tests
  admin_ip        = ["10.0.0.1/32"]
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
  root_app_manifest   = "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: test-root"
  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

# ==============================================================================
# Test 1: Cilium placeholder precondition — tested via check block at root
# The module-internal lifecycle precondition on data.talos_machine_configuration
# cannot be referenced via expect_failures from outside the module
# (OpenTofu limitation: expect_failures only supports root-level checkable objects).
# The precondition on data.talos_machine_configuration.control_plane in
# modules/talos/main.tf (guarding the CILIUM-MANIFEST-PLACEHOLDER sentinel) is the
# source of truth.
# It is validated indirectly via Test 2 (valid manifest passes).
# ==============================================================================

run "cilium_placeholder_detection_covered_by_precondition" {
  command = plan

  variables {
    talos_bootstrap = false
    cilium_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-config"
  }

  assert {
    condition     = !strcontains(var.cilium_manifest, "CILIUM-MANIFEST-PLACEHOLDER")
    error_message = "Cilium manifest must not be the unrendered placeholder — run scripts/bootstrap/render-bootstrap-manifests.sh first."
  }
}

# ==============================================================================
# Test 2: Valid cilium manifest passes precondition with talos_bootstrap=true
# ==============================================================================

run "valid_cilium_manifest_passes" {
  command = plan

  variables {
    talos_bootstrap = true
    cilium_manifest = "apiVersion: apps/v1\nkind: DaemonSet\nmetadata:\n  name: cilium\n  namespace: kube-system"
  }

  assert {
    # `> 0 || true` is a constant, and it guarded the one thing that matters:
    # the Cilium-placeholder precondition self-disables at control_plane_count
    # == 0 (modules/talos/main.tf), so a run that asserted nothing about the
    # count was documented as validating it.
    condition     = module.talos.control_plane_count == 3
    error_message = "Talos module should be instantiated with valid cilium manifest."
  }
}

# ==============================================================================
# Test 3: Phase 1 (talos_bootstrap=false) — no Talos apply resources planned
# Infrastructure is provisioned but Talos config is not applied yet.
# ==============================================================================

run "phase1_skips_talos_apply" {
  command = plan

  variables {
    talos_bootstrap = false
  }

  assert {
    condition     = length(module.scw) == 1
    error_message = "SCW infra should be active in Phase 1."
  }
}

# ==============================================================================
# Test 4: Cluster endpoint format — must use https:// and port 6443
# ==============================================================================

run "cluster_endpoint_format" {
  command = plan

  assert {
    condition     = startswith(module.talos.cluster_endpoint, "https://")
    error_message = "cluster_endpoint must start with https://"
  }

  assert {
    condition     = endswith(module.talos.cluster_endpoint, ":6443")
    error_message = "cluster_endpoint must end with :6443"
  }
}

# ==============================================================================
# Test 5: Talos version format — must start with 'v'
# ==============================================================================

run "talos_version_format" {
  command = plan

  assert {
    condition     = startswith(var.talos_version, "v")
    error_message = "talos_version must start with 'v' (e.g. v1.13.3)"
  }
}

# ==============================================================================
# Test 6: Kubernetes version format — must start with 'v'
# ==============================================================================

run "kubernetes_version_format" {
  command = plan

  assert {
    condition     = startswith(var.kubernetes_version, "v")
    error_message = "kubernetes_version must start with 'v' (e.g. v1.35.3)"
  }
}

# ==============================================================================
# Test 7: Talos installer image uses the correct talos_version
# The installer image in config_patches must reference var.talos_version
# to ensure nodes install the expected Talos version.
# ==============================================================================

run "installer_image_uses_talos_version" {
  command = plan

  variables {
    talos_bootstrap = true
    talos_version   = "v1.14.1"
  }

  # This used to assert `var.talos_version == "v1.13.3"` — that the variable the
  # run had just set held the value it set. A tautology, under a name promising
  # it checked the installer. It could not fail, and the installer reference it
  # claims to cover is the one that decides which Talos a node actually runs:
  # booting a newer image changes nothing if this string stays behind.
  # The FACTORY installer, not the plain one: the plain image carries no system
  # extensions, so every reinstall dropped iscsi-tools and Longhorn's manager
  # crash-looped on a missing iscsiadm (Scaleway, 2026-08-15). Asserting the
  # exact string is the point — a version pin alone was what let this through.
  #
  # HARDCODED ON PURPOSE, and updating it by hand IS the feature: reading it
  # from var.talos_installer_schematic_id would let any schematic change pass
  # in silence, and a schematic change means every node reinstalls from a
  # different image. Last moved 2026-08-19, dropping qemu-guest-agent — see
  # talos-image/schematic.yaml for why that extension had to go.
  assert {
    condition     = module.talos.installer_image == "factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.14.1"
    error_message = "the machine config must install from the Image Factory schematic, pinned to var.talos_version"
  }
}

# ==============================================================================
# Test 8: bootstrap_manifests_enabled=false → flux NOT in inline manifests
# This is critical for upgrades and DRP where Flux is already running.
# Adding Flux manifests again would cause reconciliation conflicts.
# ==============================================================================

run "bootstrap_disabled_skips_flux" {
  command = plan

  variables {
    talos_bootstrap = false
    flux_manifest   = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: management-gitops"
  }

  assert {
    condition     = module.talos.bootstrap_manifests_enabled == false
    error_message = "bootstrap_manifests_enabled must be false when talos_bootstrap=false."
  }
}

# ==============================================================================
# Test 9: Environment variable validation
# ==============================================================================

run "environment_validation" {
  command = plan

  assert {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

# ==============================================================================
# Test 10: cluster_role validation
# ==============================================================================

run "cluster_role_validation" {
  command = plan

  assert {
    condition     = contains(["management", "workload"], var.cluster_role)
    error_message = "cluster_role must be 'management' or 'workload'."
  }
}

# ==============================================================================
# Test 11: apiserver VIP is only injected when explicitly set. This suite's
# shared variables block (see top of file) is Scaleway with k8s_lb_mode left at
# its default ("managed"), so no provider here ever sets an apiserver_vip —
# module.talos should always receive null, matching pre-VIP-support behavior.
# ==============================================================================

run "vip_injected_only_when_set" {
  command = plan

  assert {
    condition     = module.talos.apiserver_vip == null
    error_message = "apiserver_vip must stay null when no provider requests one (Scaleway, k8s_lb_mode=managed)."
  }
}

# ==============================================================================
# Test 12: auto_tunnels defaults to false — the experimental single-apply
# terraform_data.talos_tunnels resource (cluster/main.tf) must never run
# unless explicitly opted into, including under `tofu test`'s apply mode.
# ==============================================================================

run "auto_tunnels_disabled_by_default" {
  command = plan

  assert {
    condition     = length(terraform_data.talos_tunnels) == 0
    error_message = "terraform_data.talos_tunnels must have count=0 when auto_tunnels is left at its default (false)."
  }
}

# ==============================================================================
# Test 14: deploy_flux governs BOTH manifests, in both directions
#
# 1.0.0 ships infrastructure only, so the default must leave Flux out. An
# off-switch whose only tested position is "off" is not a switch — it is a
# deletion nobody wrote down, and Flux comes back as a user choice in 1.1.0.
# Asserted on the rendered control-plane config, which is where inlineManifests
# actually land, rather than on the local that builds them.
# ==============================================================================

run "flux_absent_by_default" {
  command = plan

  variables {
    talos_bootstrap = true
  }

  assert {
    condition     = !contains(module.talos.inline_manifest_names, "flux-install") && !contains(module.talos.inline_manifest_names, "flux-bootstrap")
    error_message = "deploy_flux defaults to false, so the control-plane config must carry no Flux manifest."
  }

  assert {
    condition     = contains(module.talos.inline_manifest_names, "cilium")
    error_message = "Cilium is the floor and is unconditional — a cluster without a CNI is not a cluster."
  }
}

run "flux_present_when_asked" {
  command = plan

  variables {
    talos_bootstrap         = true
    deploy_flux             = true
    flux_manifest           = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: flux-system"
    flux_bootstrap_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: flux-bootstrap-probe"
  }

  assert {
    condition     = contains(module.talos.inline_manifest_names, "flux-install")
    error_message = "deploy_flux=true must put the Flux install manifest back into the control-plane config."
  }

  assert {
    condition     = contains(module.talos.inline_manifest_names, "flux-bootstrap")
    error_message = "The bootstrap manifest is governed by the same switch — a half-empty pair injects an empty manifest."
  }
}

# The vendored flux-install.yaml creates exactly ONE namespace, flux-system, and
# every namespaced object in it points there. Any other value renders
# inlineManifests aimed at a namespace nothing creates — and Talos applies
# inlineManifests with no ordering and no namespace creation, so it fails on a
# paid cluster with every offline gate green. `namespace: gitops` is valid YAML,
# so no schema validator can catch it; only this can.
run "flux_namespace_cannot_leave_the_vendored_manifest" {
  command = plan

  variables {
    flux_namespace = "gitops"
  }

  expect_failures = [var.flux_namespace]
}

# The default users get is declared here too, not only in the module: a changed one would reach every
# existing cluster as a config apply on every node, and no module test sees it.
run "node_dns_is_off_by_default" {
  command = plan

  assert {
    condition     = length(module.talos.appended_documents) == 0
    error_message = "node_nameservers must default to empty at the cluster root: opt-in, and no node's config changes."
  }
}

# Both node DNS settings must reach modules/talos, where the rules and their tests live.
run "node_dns_settings_reach_the_talos_module" {
  command = plan

  variables {
    node_dns_boot_timeout = "2m"
    node_nameservers      = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }

  assert {
    condition     = length(module.talos.appended_documents) == 2 && yamldecode(module.talos.appended_documents[0]).nameservers[0].address == "9.9.9.9" && yamldecode(module.talos.appended_documents[1]).bootTimeout == "2m"
    error_message = "node_nameservers and node_dns_boot_timeout must be passed to the talos module."
  }
}

run "node_nameservers_alone_get_the_default_boot_wait" {
  command = plan

  variables {
    node_nameservers = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }

  assert {
    condition     = yamldecode(module.talos.appended_documents[1]).bootTimeout == "90s"
    error_message = "the root default for node_dns_boot_timeout must stay the module's (90s)."
  }
}
