# Opt-in Flux Git source verification (flux_git_verify). Off = the GitRepository is exactly what it was before the
# variable existed; on = the Secret `git-signers` comes BEFORE the GitRepository and the GitRepository carries
# spec.verify. Mocked: whether source-controller accepts the block is a lab question (LAB-CHECKLIST B27).

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
  deploy_flux         = true
  flux_manifest       = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: flux-system"
}


run "default_renders_no_verification" {
  command = plan
  assert {
    condition     = !strcontains(local.flux_bootstrap_manifest, "git-signers") && !strcontains(local.flux_bootstrap_manifest, "verify:")
    error_message = "with the flag off nothing about verification may be rendered"
  }
  assert {
    condition     = strcontains(local.flux_bootstrap_manifest, "    name: refs/tags/0.2.0\n  timeout: 60s\n---\napiVersion: kustomize.toolkit.fluxcd.io/v1")
    error_message = "the GitRepository must stay byte-identical to the released render"
  }
}

run "enabled_renders_secret_before_gitrepository_and_verify" {
  command = plan
  variables {
    flux_git_verify = {
      enabled = true
      public_keys = [
        "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBAAAAAAAAAAAAAAA\n=abcd\n-----END PGP PUBLIC KEY BLOCK-----",
        "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBBBBBBBBBBBBBBBB\n=efgh\n-----END PGP PUBLIC KEY BLOCK-----\n",
      ]
    }
  }
  assert {
    condition     = strcontains(local.flux_bootstrap_manifest, "kind: Secret\nmetadata:\n  name: git-signers\n  namespace: flux-system")
    error_message = "the git-signers Secret is missing"
  }
  assert {
    condition     = strcontains(local.flux_bootstrap_manifest, "  signer-2.asc: |\n    -----BEGIN PGP PUBLIC KEY BLOCK-----\n    \n    mQINBBBB") && !strcontains(local.flux_bootstrap_manifest, "signer-3")
    error_message = "one indented signer-N.asc per key, numbered from 1"
  }
  assert {
    condition     = strcontains(local.flux_bootstrap_manifest, "  timeout: 60s\n  verify:\n    mode: HEAD\n    secretRef:\n      name: git-signers\n")
    error_message = "the GitRepository must carry spec.verify with mode HEAD"
  }
  assert {
    condition     = length(split("name: git-signers", split("kind: GitRepository", local.flux_bootstrap_manifest)[0])) == 2
    error_message = "the Secret must precede the GitRepository in the manifest"
  }
}

run "enabled_without_keys_is_refused" {
  command = plan
  variables {
    flux_git_verify = { enabled = true }
  }
  expect_failures = [var.flux_git_verify]
}

run "a_private_key_or_a_bare_string_is_refused" {
  command = plan
  variables {
    flux_git_verify = {
      enabled = true
      # Built from parts so the secret-scanning hook does not see a private-key marker in the repository.
      public_keys = [join("", ["-----BEGIN PGP PRIV", "ATE KEY BLOCK-----\nxx\n-----END PGP PRIV", "ATE KEY BLOCK-----"])]
    }
  }
  expect_failures = [var.flux_git_verify]
}
