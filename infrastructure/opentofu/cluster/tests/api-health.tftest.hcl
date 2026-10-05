# k8s_api_health (#42): the default changes nothing, "anonymous" is the apiserver side only,
# "readyz" flips the load balancer's check, and the guards refuse what cannot work. A mocked
# plan proves the wiring and the refusals, not that a load balancer ever marks a backend UP.

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
}

# The patch the module hands Talos, decoded: files[0], the extra args and the file's own content.
# (plan-time: control_plane_config is unknown until apply, apiserver_health_patch is not.)

run "default_changes_nothing" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
  }
  assert {
    condition     = length(module.talos.apiserver_health_patch) == 0
    error_message = "The default (tcp) must add no apiserver patch."
  }
  assert {
    condition     = module.scw[0].k8s_lb_health_check.protocol == "TCP" && module.scw[0].k8s_lb_health_check.path == null
    error_message = "The default Scaleway API load balancer check must stay TCP."
  }
}

run "tcp_still_works_on_kubernetes_1_31" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.31.0"
  }
  assert {
    condition     = length(module.talos.apiserver_health_patch) == 0
    error_message = "Kubernetes 1.31 stays on tcp: the AuthenticationConfiguration field does not exist there."
  }
}

run "anonymous_is_the_apiserver_side_only" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
    k8s_api_health     = "anonymous"
  }
  assert {
    condition     = length(module.talos.apiserver_health_patch) == 1
    error_message = "anonymous must add exactly one control-plane patch."
  }
  assert {
    condition     = yamldecode(module.talos.apiserver_health_patch[0]).machine.files[0].op == "create" && yamldecode(module.talos.apiserver_health_patch[0]).machine.files[0].path == "/var/lib/oa-authn/authentication-config.yaml"
    error_message = "The file must be written with op create under /var (Talos rewrites it on every boot; overwrite fails the first one)."
  }
  assert {
    condition     = [for c in yamldecode(yamldecode(module.talos.apiserver_health_patch[0]).machine.files[0].content).anonymous.conditions : c.path] == ["/livez", "/readyz", "/healthz"]
    error_message = "Anonymous callers may read exactly /livez, /readyz and /healthz."
  }
  assert {
    condition     = yamldecode(yamldecode(module.talos.apiserver_health_patch[0]).machine.files[0].content).apiVersion == "apiserver.config.k8s.io/v1beta1"
    error_message = "The file must be v1beta1 on 1.36 as well: a content change on a Kubernetes bump makes Talos 1.13 reboot all three control planes."
  }
  assert {
    condition = (
      yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraVolumes[0].hostPath == dirname(yamldecode(module.talos.apiserver_health_patch[0]).machine.files[0].path) &&
      "${yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraVolumes[0].mountPath}/authentication-config.yaml" == yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraArgs["authentication-config"] &&
      yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraVolumes[0].readonly == true
    )
    error_message = "The apiserver must mount the directory the file is written to, read-only, at the path --authentication-config names."
  }
  assert {
    condition     = contains(keys(yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraArgs), "anonymous-auth") && yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraArgs["anonymous-auth"] == null
    error_message = "--anonymous-auth must be removed (null), it cannot sit next to the file's anonymous stanza."
  }
  assert {
    condition     = !contains(keys(yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraArgs), "shutdown-delay-duration")
    error_message = "No shutdown delay unless k8s_api_shutdown_delay is set."
  }
  assert {
    condition     = module.scw[0].k8s_lb_health_check.protocol == "TCP"
    error_message = "anonymous is the middle step: the load balancer must still check TCP."
  }
}

run "readyz_flips_the_scaleway_check" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
    k8s_api_health     = "readyz"
  }
  assert {
    condition     = module.scw[0].k8s_lb_health_check.protocol == "HTTPS" && module.scw[0].k8s_lb_health_check.path == "/readyz"
    error_message = "readyz must make the Scaleway API load balancer check HTTPS /readyz."
  }
  assert {
    condition     = length(module.talos.apiserver_health_patch) == 1
    error_message = "readyz includes the apiserver side."
  }
}

run "readyz_flips_the_ovh_check" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
    k8s_api_health     = "readyz"
    node_distribution = {
      ovh = {
        control_planes     = 3
        workers            = 1
        region             = "EU-WEST-PAR"
        flavor_name        = "b3-8"
        image_id           = "dummy-talos-ovh-image"
        network_name       = "Ext-Net"
        availability_zones = ["eu-west-par-a"]
      }
    }
  }
  assert {
    condition     = module.ovh[0].k8s_lb_health_check.protocol == "HTTPS" && module.ovh[0].k8s_lb_health_check.path == "/readyz"
    error_message = "readyz must make the OVH API load balancer monitor HTTPS."
  }
}

run "ovh_default_is_tcp" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
    node_distribution = {
      ovh = {
        control_planes     = 3
        workers            = 1
        region             = "EU-WEST-PAR"
        flavor_name        = "b3-8"
        image_id           = "dummy-talos-ovh-image"
        network_name       = "Ext-Net"
        availability_zones = ["eu-west-par-a"]
      }
    }
  }
  assert {
    condition     = module.ovh[0].k8s_lb_health_check.protocol == "TCP"
    error_message = "The default OVH API load balancer monitor must stay TCP."
  }
}

run "readyz_flips_the_outscale_check" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
    k8s_api_health     = "readyz"
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
    condition     = module.outscale[0].k8s_lb_health_check.protocol == "HTTPS" && module.outscale[0].k8s_lb_health_check.path == "/readyz"
    error_message = "readyz must make the Outscale API load balancer check HTTPS /readyz."
  }
}

run "outscale_default_is_tcp" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
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
    condition     = module.outscale[0].k8s_lb_health_check.protocol == "TCP" && module.outscale[0].k8s_lb_health_check.path == null
    error_message = "The default Outscale API load balancer check must stay TCP."
  }
}

run "delay_reaches_the_apiserver_with_readyz" {
  command = plan
  variables {
    talos_version          = "v1.13.9"
    kubernetes_version     = "v1.36.3"
    k8s_api_health         = "readyz"
    k8s_api_shutdown_delay = "20s"
  }
  assert {
    condition     = yamldecode(module.talos.apiserver_health_patch[0]).cluster.apiServer.extraArgs["shutdown-delay-duration"] == "20s"
    error_message = "The shutdown delay must reach kube-apiserver as --shutdown-delay-duration."
  }
}

# --- what must be refused ---

run "anonymous_on_kubernetes_1_31_is_refused" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.31.0"
    k8s_api_health     = "anonymous"
  }
  expect_failures = [terraform_data.api_health_guard]
}

run "anonymous_on_talos_1_12_is_refused" {
  command = plan
  variables {
    talos_version      = "v1.12.7"
    kubernetes_version = "v1.34.0"
    k8s_api_health     = "anonymous"
  }
  expect_failures = [terraform_data.api_health_guard]
}

run "delay_without_readyz_is_refused" {
  command = plan
  variables {
    talos_version          = "v1.13.9"
    kubernetes_version     = "v1.36.3"
    k8s_api_health         = "anonymous"
    k8s_api_shutdown_delay = "20s"
  }
  expect_failures = [terraform_data.api_health_guard]
}

run "delay_of_30s_is_refused" {
  command = plan
  variables {
    talos_version          = "v1.13.9"
    kubernetes_version     = "v1.36.3"
    k8s_api_health         = "readyz"
    k8s_api_shutdown_delay = "30s"
  }
  expect_failures = [var.k8s_api_shutdown_delay]
}

run "delay_without_a_unit_is_refused" {
  command = plan
  variables {
    talos_version          = "v1.13.9"
    kubernetes_version     = "v1.36.3"
    k8s_api_health         = "readyz"
    k8s_api_shutdown_delay = "20"
  }
  expect_failures = [var.k8s_api_shutdown_delay]
}

run "unknown_mode_is_refused" {
  command = plan
  variables {
    talos_version      = "v1.13.9"
    kubernetes_version = "v1.36.3"
    k8s_api_health     = "http"
  }
  expect_failures = [var.k8s_api_health]
}
