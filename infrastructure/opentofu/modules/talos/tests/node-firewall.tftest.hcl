# node_firewall_mode: off renders nothing; rules_only appends NetworkDefaultActionConfig accept plus one
# NetworkRuleConfig per flow. Mocked: this proves the documents and the replace trigger, not that Talos
# accepts them or that traffic still flows (LAB-CHECKLIST B24).

mock_provider "talos" {}
mock_provider "random" {}

variables {
  cluster_name            = "t"
  cluster_endpoint        = "https://10.0.0.10:6443"
  talos_version           = "v1.14.2"
  kubernetes_version      = "v1.37.1"
  control_plane_count     = 1
  worker_count            = 1
  control_plane_ips       = ["10.0.0.10"]
  worker_ips              = ["10.0.0.20"]
  k8s_lb_ip               = "10.0.0.10"
  config_delivery         = "apply"
  skip_port_ready_wait    = true
  cilium_manifest         = "apiVersion: v1\nkind: ConfigMap\n"
  skip_health_check       = true
  secrets_prevent_destroy = false
}

override_data {
  target = data.talos_machine_configuration.control_plane
  values = { machine_configuration = "version: v1alpha1\nmachine:\n  type: controlplane\n" }
}

run "off_changes_nothing" {
  command = apply
  assert {
    condition     = length(output.appended_documents) == 0 && terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "node_firewall_mode = off must append nothing and leave the replace trigger as it was"
  }
}

run "rules_only_renders_inert_rules" {
  command = apply
  variables {
    node_firewall_mode = "rules_only"
    node_firewall = {
      node_cidrs    = ["10.0.0.0/24"]
      bastion_cidrs = ["10.0.1.0/24"]
    }
    node_firewall_ports = {
      talos-apid   = { protocol = "TCP", ports = "50000" }
      etcd         = { protocol = "TCP", ports = "2379-2381" }
      cilium-icmp  = { protocol = "ICMP", ports = null }
      cilium-vxlan = { protocol = "UDP", ports = "8472" }
    }
    node_firewall_scope = {
      talos-apid   = ["nodes", "bastion"]
      etcd         = ["nodes"]
      cilium-icmp  = ["nodes", "pods"]
      cilium-vxlan = ["nodes"]
    }
  }

  assert {
    condition     = length(output.appended_documents) == 4 && yamldecode(output.appended_documents[0]).kind == "NetworkDefaultActionConfig" && yamldecode(output.appended_documents[0]).ingress == "accept"
    error_message = "rules_only must write the default action as accept (inert) first, then one rule per TCP/UDP flow (ICMP has none)"
  }
  assert {
    condition     = alltrue([for d in slice(output.appended_documents, 1, 4) : yamldecode(d).kind == "NetworkRuleConfig" && !contains(["block"], try(yamldecode(d).ingress, ""))])
    error_message = "every other document is a NetworkRuleConfig"
  }
  assert {
    condition     = anytrue([for d in output.appended_documents : try(yamldecode(d).name, "") == "openaether-talos-apid" && yamldecode(d).portSelector.protocol == "tcp" && yamldecode(d).portSelector.ports == [50000] && yamldecode(d).ingress == [{ subnet = "10.0.0.0/24" }, { subnet = "10.0.1.0/24" }]])
    error_message = "apid: tcp 50000 from the node and bastion subnets"
  }
  assert {
    condition     = anytrue([for d in output.appended_documents : try(yamldecode(d).name, "") == "openaether-etcd" && yamldecode(d).portSelector.ports == ["2379-2381"] && yamldecode(d).ingress == [{ subnet = "10.0.0.0/24" }]])
    error_message = "etcd: the range stays a string, nodes only"
  }
  assert {
    condition     = !anytrue([for d in output.appended_documents : try(yamldecode(d).name, "") == "openaether-cilium-icmp"]) && alltrue([for d in output.appended_documents : try(yamldecode(d).kind, "") != "NetworkRuleConfig" || length(yamldecode(d).portSelector.ports) > 0])
    error_message = "no document for icmp (Talos refuses a NetworkRuleConfig without ports and allows ICMP itself), and every rule document carries ports"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input != "v1.14.2/v1.37.1"
    error_message = "the documents must change the replace trigger, or an existing cluster never receives them"
  }
}

run "rules_only_needs_node_cidrs" {
  command = plan
  variables {
    node_firewall_mode = "rules_only"
  }
  expect_failures = [var.node_firewall]
}

run "enforce_is_refused" {
  command = plan
  variables {
    node_firewall_mode = "enforce"
  }
  expect_failures = [var.node_firewall_mode]
}

run "the_whole_internet_is_refused" {
  command = plan
  variables {
    node_firewall = { node_cidrs = ["0.0.0.0/0"] }
  }
  expect_failures = [var.node_firewall]
}
