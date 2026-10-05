# node_nameservers: one ResolverConfig (plus a TimeSyncConfig when a server is encrypted)
# appended to every node's generated config; a change replaces the apply resources. Provider
# mocked: the generated text is unknown at plan, so the composition runs `apply` (nothing reaches
# a node; the port-ready guard that would run a script is off). That a node accepts the document
# and resolves through it is a node, not this file.

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

# The control plane's generated text ends with a newline, as the real one does; the worker's keeps
# the mock's, which does not. The append must come out right on both.
override_data {
  target = data.talos_machine_configuration.control_plane
  values = { machine_configuration = "version: v1alpha1\nmachine:\n  type: controlplane\n" }
}

# --- what reaches the nodes ---------------------------------------------------

run "unset_leaves_every_config_byte_identical" {
  command = apply
  assert {
    condition     = length(output.appended_documents) == 0
    error_message = "no node_nameservers must append nothing"
  }
  assert {
    condition     = talos_machine_configuration_apply.control_plane[0].machine_configuration_input == data.talos_machine_configuration.control_plane[0].machine_configuration && talos_machine_configuration_apply.worker[0].machine_configuration_input == data.talos_machine_configuration.worker[0].machine_configuration
    error_message = "an unset list must hand each node the generated config untouched: a different byte is a config apply on every existing node"
  }
}

run "an_encrypted_list_is_appended_to_both_roles" {
  command = apply
  variables {
    node_nameservers = [
      { address = "9.9.9.9", tls_server_name = "dns.quad9.net" },
      { address = "149.112.112.112", tls_server_name = "dns.quad9.net" },
    ]
  }
  assert {
    condition     = length(output.appended_documents) == 2 && yamldecode(output.appended_documents[0]).kind == "ResolverConfig" && yamldecode(output.appended_documents[1]).kind == "TimeSyncConfig"
    error_message = "an encrypted list must append a ResolverConfig and a TimeSyncConfig, in that order"
  }
  assert {
    condition     = yamldecode(output.appended_documents[0]).nameservers[0] == { address = "9.9.9.9", protocol = "DoT", tlsServerName = "dns.quad9.net" } && length(yamldecode(output.appended_documents[0]).nameservers) == 2
    error_message = "a DoT entry must carry exactly address, protocol and tlsServerName, in list order"
  }
  assert {
    condition     = !contains(keys(yamldecode(output.appended_documents[0])), "hostDNS")
    error_message = "hostDNS must stay out of the document: the generated v1alpha1 sets it and Talos refuses both"
  }
  assert {
    condition     = yamldecode(output.appended_documents[1]).bootTimeout == "90s"
    error_message = "the default boot wait is 90s"
  }
  # What the node is handed (the apply resource), and what the backup outputs hold, is the generated
  # text, then each document after a --- line.
  assert {
    condition     = talos_machine_configuration_apply.control_plane[0].machine_configuration_input == "${trimsuffix(data.talos_machine_configuration.control_plane[0].machine_configuration, "\n")}\n---\n${output.appended_documents[0]}---\n${output.appended_documents[1]}" && output.control_plane_config == talos_machine_configuration_apply.control_plane[0].machine_configuration_input && output.control_plane_machine_configs[0] == output.control_plane_config
    error_message = "the control plane config must be the generated text, then each document after a --- line"
  }
  assert {
    condition     = talos_machine_configuration_apply.worker[0].machine_configuration_input == "${trimsuffix(data.talos_machine_configuration.worker[0].machine_configuration, "\n")}\n---\n${output.appended_documents[0]}---\n${output.appended_documents[1]}" && output.worker_config == talos_machine_configuration_apply.worker[0].machine_configuration_input && output.worker_machine_configs[0] == output.worker_config
    error_message = "the worker config must carry the same documents: workers pull images too"
  }
}

run "a_plain_list_does_not_touch_the_boot_wait" {
  command = plan
  variables {
    node_nameservers = [{ address = "9.9.9.9", protocol = "Do53" }]
  }
  assert {
    condition     = length(output.appended_documents) == 1 && yamldecode(output.appended_documents[0]).nameservers[0] == { address = "9.9.9.9" }
    error_message = "a Do53 entry is a bare address, and plain DNS adds no TimeSyncConfig"
  }
}

run "an_empty_boot_timeout_keeps_the_talos_wait" {
  command = plan
  variables {
    node_dns_boot_timeout = ""
    node_nameservers      = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }
  assert {
    condition     = length(output.appended_documents) == 1
    error_message = "an empty node_dns_boot_timeout must append no TimeSyncConfig"
  }
}

run "dot_and_doh_over_ipv6_are_all_encrypted" {
  command = plan
  variables {
    node_dns_boot_timeout = "2m"
    node_nameservers = [
      { address = "2606:4700:4700::1111", protocol = "DoH", tls_server_name = "cloudflare-dns.com" },
      { address = "9.9.9.9", protocol = "DoT", tls_server_name = "dns.quad9.net" },
    ]
  }
  assert {
    condition     = length(output.appended_documents) == 2 && yamldecode(output.appended_documents[1]).bootTimeout == "2m" && yamldecode(output.appended_documents[0]).nameservers[0].protocol == "DoH"
    error_message = "DoH and DoT may be mixed (both encrypted), IPv6 is an address, and the timeout is the operator's"
  }
}

run "do53_is_fine_on_an_older_talos" {
  command = plan
  variables {
    talos_version    = "v1.13.9"
    node_nameservers = [{ address = "9.9.9.9", protocol = "Do53" }]
  }
  assert {
    condition     = length(output.appended_documents) == 1
    error_message = "a plain list carries no 1.14-only key"
  }
}

# --- a change must replace the apply resources (upstream #352) ----------------
# An in-place update of talos_machine_configuration_apply trips #352 on OVH and Outscale when the
# config is unknown at plan; main.tf replaces on a change of this input instead.

run "unset_keeps_the_replace_trigger_input_unchanged" {
  command = plan
  assert {
    condition     = terraform_data.machine_config_version[0].input == "${var.talos_version}/${var.kubernetes_version}"
    error_message = "an unset list must leave the input as it was, or every existing cluster plans a replacement"
  }
}

run "list_a" {
  command = plan
  variables {
    node_nameservers = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }
  # The two runs below compare against this value, so a stale one must fail here rather than let
  # them pass for nothing. It is sha256 of both appended documents: it moves with their text.
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1/a80d7b18be530e760a8a02821fff36254c5ffd1699e7c82faf6a30434e589813"
    error_message = "the input must carry a hash of everything appended, TimeSyncConfig included; if the documents' text legitimately changed, update this value"
  }
}

run "a_changed_list_changes_the_replace_trigger_input" {
  command = plan
  variables {
    node_nameservers = [{ address = "149.112.112.112", tls_server_name = "dns.quad9.net" }]
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input != "v1.14.2/v1.37.1/a80d7b18be530e760a8a02821fff36254c5ffd1699e7c82faf6a30434e589813"
    error_message = "another nameserver must change the input, or the apply resources update in place and trip #352"
  }
}

run "a_changed_boot_timeout_changes_the_replace_trigger_input" {
  command = plan
  variables {
    node_dns_boot_timeout = "5m"
    node_nameservers      = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input != "v1.14.2/v1.37.1/a80d7b18be530e760a8a02821fff36254c5ffd1699e7c82faf6a30434e589813"
    error_message = "the boot timeout is part of what is applied: changing it must change the input too"
  }
}

# --- what validation refuses --------------------------------------------------

run "a_hostname_is_not_an_address" {
  command = plan
  variables {
    node_nameservers = [{ address = "dns.quad9.net", tls_server_name = "dns.quad9.net" }]
  }
  expect_failures = [var.node_nameservers]
}

run "an_unknown_protocol_is_refused" {
  command = plan
  variables {
    node_nameservers = [{ address = "9.9.9.9", protocol = "TLS", tls_server_name = "dns.quad9.net" }]
  }
  expect_failures = [var.node_nameservers]
}

run "dot_needs_a_tls_server_name" {
  command = plan
  variables {
    node_nameservers = [{ address = "9.9.9.9" }]
  }
  expect_failures = [var.node_nameservers]
}

run "do53_takes_no_tls_server_name" {
  command = plan
  variables {
    node_nameservers = [{ address = "9.9.9.9", protocol = "Do53", tls_server_name = "dns.quad9.net" }]
  }
  expect_failures = [var.node_nameservers]
}

run "a_plain_entry_after_an_encrypted_one_is_refused" {
  command = plan
  variables {
    node_nameservers = [
      { address = "9.9.9.9", tls_server_name = "dns.quad9.net" },
      { address = "8.8.8.8", protocol = "Do53" },
    ]
  }
  expect_failures = [var.node_nameservers]
}

run "a_plain_entry_before_an_encrypted_one_is_refused" {
  command = plan
  variables {
    node_nameservers = [
      { address = "8.8.8.8", protocol = "Do53" },
      { address = "9.9.9.9", tls_server_name = "dns.quad9.net" },
    ]
  }
  expect_failures = [var.node_nameservers]
}

run "dot_is_refused_below_talos_1_14" {
  command = plan
  variables {
    talos_version    = "v1.13.9"
    node_nameservers = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }
  expect_failures = [var.node_nameservers]
}

run "a_boot_timeout_must_be_a_duration" {
  command = plan
  variables {
    node_dns_boot_timeout = "soon"
  }
  expect_failures = [var.node_dns_boot_timeout]
}

run "a_zero_boot_timeout_is_refused" {
  command = plan
  variables {
    node_dns_boot_timeout = "0s"
  }
  expect_failures = [var.node_dns_boot_timeout]
}
