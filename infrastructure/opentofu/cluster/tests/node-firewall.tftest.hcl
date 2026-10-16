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

# The node port list is ONE source (modules/providers/_shared/node-ports) for three layers: the Scaleway
# group, the OVH/Outscale member rules (restrict_inter_node) and the Talos ingress rules
# (node_firewall_mode). Default: both new switches off and nothing changes. Mocked rung: this proves what
# is PLANNED and that the layers agree, not what a cloud or a node enforces (LAB-CHECKLIST B24).

variables {
  cluster_name            = "test-cluster"
  environment             = "dev"
  cluster_role            = "management"
  talos_bootstrap         = false
  skip_port_ready_wait    = true
  secrets_prevent_destroy = false
  backup_enabled          = false
  deploy_app_lb           = false
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

# Every flow a node accepts from another member; no DHCP (the server is not a member).
run "ovh_default_keeps_the_broad_rules" {
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
    condition     = module.ovh[0].inter_node_rules.all_protocol && module.ovh[0].inter_node_rules.wireguard && length(module.ovh[0].inter_node_rules.explicit) == 0
    error_message = "restrict_inter_node = false must keep the all-protocol rule and the 51820 rule, and add no explicit rule"
  }
}

run "ovh_restricted_uses_the_shared_list" {
  command = plan

  variables {
    restrict_inter_node = true
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
    condition     = !module.ovh[0].inter_node_rules.all_protocol && !module.ovh[0].inter_node_rules.wireguard
    error_message = "restrict_inter_node = true must drop the all-protocol rule and the wrong-port 51820 rule"
  }
  assert {
    condition = module.ovh[0].inter_node_rules.explicit == sort(["TCP 6443", "TCP 50000", "TCP 50001", "TCP 2379-2381", "TCP 10250", "UDP 8472", "UDP 51871",
    "TCP 4240", "ICMP -", "TCP 9962-9964", "TCP 9100"])
    error_message = "OVH members must get exactly the shared list (WireGuard on 51871), no DHCP"
  }
}

run "outscale_default_keeps_the_broad_rules" {
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
    condition     = module.outscale[0].inter_node_rules.all_protocol && module.outscale[0].inter_node_rules.wireguard && length(module.outscale[0].inter_node_rules.explicit) == 0
    error_message = "restrict_inter_node = false must keep the all-protocol rule and the 51820 rule, and add no explicit rule"
  }
}

run "outscale_restricted_uses_the_shared_list" {
  command = plan

  variables {
    restrict_inter_node = true
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
    condition     = !module.outscale[0].inter_node_rules.all_protocol && !module.outscale[0].inter_node_rules.wireguard
    error_message = "restrict_inter_node = true must drop the all-protocol rule and the wrong-port 51820 rule"
  }
  assert {
    condition = module.outscale[0].inter_node_rules.explicit == sort(["TCP 6443", "TCP 50000", "TCP 50001", "TCP 2379-2381", "TCP 10250", "UDP 8472", "UDP 51871",
    "TCP 4240", "ICMP -", "TCP 9962-9964", "TCP 9100"])
    error_message = "Outscale members must get exactly the shared list (WireGuard on 51871), no DHCP"
  }
}

# Scaleway keeps its whole list (DHCP included) and the Talos rules are made from the same entries.
run "scaleway_and_talos_follow_the_same_list" {
  command = plan

  variables {
    node_firewall_mode = "port_allowlist"
    node_firewall      = { node_cidrs = ["172.16.0.0/22"] }
  }

  assert {
    condition = alltrue([for k, rs in module.scw[0].inbound_rules : k == "bastion" || alltrue([
      for p in ["TCP 6443", "TCP 50000", "TCP 50001", "TCP 2379-2381", "TCP 10250", "UDP 8472", "UDP 51871", "TCP 4240", "ICMP -", "TCP 9962-9964", "TCP 9100", "UDP 68"] :
      contains([for r in rs : "${r.protocol} ${r.port_range != null ? r.port_range : (r.port != null ? tostring(r.port) : "-")}"], p)
    ])])
    error_message = "Scaleway must list every entry of the shared list"
  }
  assert {
    condition = sort([for d in module.talos.appended_documents : yamldecode(d).name if yamldecode(d).kind == "NetworkRuleConfig"]) == sort([
      for k in ["kube-apiserver", "talos-apid", "talos-trustd", "etcd", "etcd-metrics", "kubelet", "cilium-vxlan", "cilium-wireguard", "cilium-health", "cilium-metrics", "node-exporter"] : "openaether-${k}"
    ])
    error_message = "The Talos rules must be exactly the shared list without DHCP and without ICMP (Talos refuses a rule without ports and allows ICMP itself)"
  }
  # vmagent (a pod) scrapes etcd on :2381; a pod on a control-plane node arrives with its pod address.
  assert {
    condition     = anytrue([for d in module.talos.appended_documents : try(yamldecode(d).name, "") == "openaether-etcd-metrics" && yamldecode(d).portSelector.ports == [2381] && contains([for i in yamldecode(d).ingress : i.subnet], "10.244.0.0/16")]) && anytrue([for d in module.talos.appended_documents : try(yamldecode(d).name, "") == "openaether-etcd" && yamldecode(d).portSelector.ports == ["2379-2380"] && !contains([for i in yamldecode(d).ingress : i.subnet], "10.244.0.0/16")])
    error_message = "etcd client/peer (2379-2380) stay nodes-only; the metrics port 2381 also admits the pod range (vmagent scrapes it from a pod)"
  }
  assert {
    condition     = alltrue([for d in module.talos.appended_documents : yamldecode(d).kind == "NetworkRuleConfig" || yamldecode(d).ingress == "accept"])
    error_message = "port_allowlist must never write a blocking default action"
  }
}

run "talos_default_renders_no_firewall" {
  command = plan

  assert {
    condition     = !anytrue([for d in module.talos.appended_documents : can(regex("Network(Rule|DefaultAction)Config", d))])
    error_message = "node_firewall_mode defaults to off: no firewall document"
  }
}
