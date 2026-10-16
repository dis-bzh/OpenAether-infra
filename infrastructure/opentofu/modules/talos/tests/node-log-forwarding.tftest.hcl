# node_log_forwarding: Talos service logs (machine.logging) and the kernel log (a KmsgLogConfig) pushed over
# TCP to a receiver; null renders nothing. Mocked: this proves the rendered documents and the replace trigger,
# not that a Talos node accepts them or that a collector receives anything (LAB-CHECKLIST B22).

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

run "unset_renders_nothing_and_keeps_the_version_input" {
  command = apply
  assert {
    condition     = length(output.appended_documents) == 0 && length(output.node_log_patch) == 0
    error_message = "node_log_forwarding = null must append no document and patch no logging"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.logging) && !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.logging)
    error_message = "an unset node_log_forwarding must leave the machine patch of both roles without a logging key"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "the replace trigger input must be unchanged when nothing is forwarded: a different value replaces every node's apply on an existing cluster"
  }
}

run "set_patches_both_roles_and_appends_the_kernel_log" {
  command = apply
  variables {
    node_log_forwarding = { endpoint = "tcp://127.0.0.1:5170" }
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.logging.destinations == [{ endpoint = "tcp://127.0.0.1:5170", format = "json_lines" }]
    error_message = "the control plane must send service logs as json_lines to the endpoint"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.logging.destinations == [{ endpoint = "tcp://127.0.0.1:5170", format = "json_lines" }]
    error_message = "the workers must send their logs too: node events there matter as much"
  }
  assert {
    condition     = length(output.appended_documents) == 1 && yamldecode(output.appended_documents[0]).kind == "KmsgLogConfig" && yamldecode(output.appended_documents[0]).url == "tcp://127.0.0.1:5170"
    error_message = "the kernel log must be a KmsgLogConfig toward the same endpoint by default"
  }
  assert {
    condition     = startswith(terraform_data.machine_config_version[0].input, "v1.14.2/v1.37.1/") && length(split("/", terraform_data.machine_config_version[0].input)) == 4
    error_message = "the hashes of the new documents must be in the replace trigger, or an existing cluster never gets them"
  }
}

run "the_hash_follows_the_endpoint" {
  command = apply
  variables {
    node_log_forwarding = { endpoint = "tcp://127.0.0.1:5171" }
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input != "v1.14.2/v1.37.1" && yamldecode(output.appended_documents[0]).url == "tcp://127.0.0.1:5171"
    error_message = "another endpoint must give another trigger value"
  }
}

run "kernel_can_be_left_out_or_sent_elsewhere" {
  command = plan
  variables {
    node_log_forwarding = { endpoint = "tcp://127.0.0.1:5170", kernel = false }
  }
  assert {
    condition     = length(output.appended_documents) == 0 && length(output.node_log_patch.logging.destinations) == 1
    error_message = "kernel = false must send service logs only"
  }
}

run "a_kernel_endpoint_is_used_for_the_kernel_document" {
  command = plan
  variables {
    node_log_forwarding = { endpoint = "tcp://127.0.0.1:5170", kernel_endpoint = "tcp://127.0.0.1:5171" }
  }
  assert {
    condition     = yamldecode(output.appended_documents[0]).url == "tcp://127.0.0.1:5171" && output.node_log_patch.logging.destinations[0].endpoint == "tcp://127.0.0.1:5170"
    error_message = "kernel_endpoint must only move the kernel log"
  }
}

run "it_composes_with_node_nameservers" {
  command = plan
  variables {
    node_log_forwarding = { endpoint = "tcp://127.0.0.1:5170" }
    node_nameservers    = [{ address = "9.9.9.9", protocol = "Do53" }]
  }
  assert {
    condition     = length(output.appended_documents) == 2 && yamldecode(output.appended_documents[0]).kind == "KmsgLogConfig" && yamldecode(output.appended_documents[1]).kind == "ResolverConfig"
    error_message = "both features append their documents"
  }
}

run "udp_is_refused" {
  command = plan
  variables {
    node_log_forwarding = { endpoint = "udp://127.0.0.1:5170" }
  }
  expect_failures = [var.node_log_forwarding]
}

run "a_path_or_a_missing_port_is_refused" {
  command = plan
  variables {
    node_log_forwarding = { endpoint = "tcp://logs.internal" }
  }
  expect_failures = [var.node_log_forwarding]
}

run "a_kernel_endpoint_with_kernel_off_is_refused" {
  command = plan
  variables {
    node_log_forwarding = { endpoint = "tcp://127.0.0.1:5170", kernel = false, kernel_endpoint = "tcp://127.0.0.1:5171" }
  }
  expect_failures = [var.node_log_forwarding]
}
