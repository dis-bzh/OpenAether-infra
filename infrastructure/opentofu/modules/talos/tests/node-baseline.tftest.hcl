# node_baseline (sysctls, kubelet) and node_time_servers: opt-in, byte-identical when unset. Mocked: this
# proves the rendered patches, the single TimeSyncConfig and the replace trigger, not that a Talos node
# accepts them or that a workload survives them (LAB-CHECKLIST B23).

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

run "unset_changes_nothing" {
  command = apply
  assert {
    condition     = length(output.node_baseline_patch.sysctls) == 0 && length(output.node_baseline_patch.worker) == 0 && length(output.node_baseline_patch.control_plane_kubelet) == 0
    error_message = "node_baseline = null must patch nothing"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.sysctls) && !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet) && !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.sysctls)
    error_message = "the worker keeps no kubelet block and neither role gets sysctls by default"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.kubelet == { defaultRuntimeSeccompProfileEnabled = true }
    error_message = "the control-plane kubelet block must stay exactly what 0.2.1 rendered"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1" && length(output.appended_documents) == 0
    error_message = "the replace trigger and the appended documents must be unchanged when nothing is set"
  }
}

run "an_all_default_object_is_still_a_noop" {
  command = apply
  variables {
    node_baseline = {}
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "node_baseline = {} sets nothing and must not replace any node"
  }
}

run "sysctls_reach_both_roles_without_touching_cilium_needs" {
  command = apply
  variables {
    node_baseline = { sysctls = true }
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.sysctls["kernel.sysrq"] == "0" && yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.sysctls["net.ipv4.tcp_rfc1337"] == "1"
    error_message = "both roles must receive the sysctls"
  }
  assert {
    condition     = !contains(keys(output.node_baseline_patch.sysctls), "net.ipv4.ip_forward") && !contains(keys(output.node_baseline_patch.sysctls), "net.ipv4.conf.all.rp_filter") && !contains(keys(output.node_baseline_patch.sysctls), "kernel.panic_on_oops") && !contains(keys(output.node_baseline_patch.sysctls), "kernel.pid_max")
    error_message = "ip_forward, rp_filter, pid_max (Cilium/Kubernetes) and panic_on_oops (own switch) must not be in the base set"
  }
  assert {
    condition     = alltrue([for k, v in output.node_baseline_patch.sysctls : can(tostring(v))]) && !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet)
    error_message = "sysctls alone must not add a kubelet block, and every value is a string"
  }
  assert {
    condition     = startswith(terraform_data.machine_config_version[0].input, "v1.14.2/v1.37.1/")
    error_message = "the baseline must be in the replace trigger, or an existing cluster never gets it"
  }
}

run "panic_on_oops_and_extras" {
  command = plan
  variables {
    node_baseline = { sysctls = true, panic_on_oops = true, sysctls_extra = { "net.ipv4.conf.all.rp_filter" = "2", "kernel.sysrq" = "16" } }
  }
  assert {
    condition     = output.node_baseline_patch.sysctls["kernel.panic_on_oops"] == "1" && output.node_baseline_patch.sysctls["net.ipv4.conf.all.rp_filter"] == "2" && output.node_baseline_patch.sysctls["kernel.sysrq"] == "16"
    error_message = "panic_on_oops is its own switch and sysctls_extra wins over the base set"
  }
}

run "kubelet_settings_go_to_extraconfig_and_the_worker_gets_seccomp" {
  command = apply
  variables {
    node_baseline = { worker_default_seccomp = true, pod_pids_limit = 4096, kubelet_server_tls = true }
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet == { defaultRuntimeSeccompProfileEnabled = true, extraConfig = { podPidsLimit = 4096, serverTLSBootstrap = true } }
    error_message = "worker kubelet: seccomp default and the extraConfig"
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).machine.kubelet == { defaultRuntimeSeccompProfileEnabled = true, extraConfig = { podPidsLimit = 4096, serverTLSBootstrap = true } }
    error_message = "control-plane kubelet keeps its seccomp default and gains the extraConfig"
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.sysctls)
    error_message = "no sysctls were asked for"
  }
}

run "the_pid_limit_alone_leaves_the_worker_seccomp_alone" {
  command = apply
  variables {
    node_baseline = { pod_pids_limit = 2048 }
  }
  assert {
    condition     = yamldecode(data.talos_machine_configuration.worker[0].config_patches[0]).machine.kubelet == { extraConfig = { podPidsLimit = 2048 } }
    error_message = "without worker_default_seccomp the worker gets only the pid limit"
  }
}

run "a_tiny_pid_limit_is_refused" {
  command = plan
  variables {
    node_baseline = { pod_pids_limit = 10 }
  }
  expect_failures = [var.node_baseline]
}

run "panic_on_oops_without_sysctls_is_refused" {
  command = plan
  variables {
    node_baseline = { panic_on_oops = true }
  }
  expect_failures = [var.node_baseline]
}

run "a_bad_extra_key_is_refused" {
  command = plan
  variables {
    node_baseline = { sysctls_extra = { "not a key" = "1" } }
  }
  expect_failures = [var.node_baseline]
}

# --- node_time_servers ----------------------------------------------------------

run "time_servers_make_one_timesyncconfig" {
  command = apply
  variables {
    node_time_servers = ["192.0.2.10", "ntp.example.org"]
  }
  assert {
    condition     = length(output.appended_documents) == 1 && yamldecode(output.appended_documents[0]).kind == "TimeSyncConfig" && yamldecode(output.appended_documents[0]).ntp.servers == ["192.0.2.10", "ntp.example.org"] && !can(yamldecode(output.appended_documents[0]).bootTimeout)
    error_message = "node_time_servers alone: one TimeSyncConfig with ntp.servers and no bootTimeout"
  }
  assert {
    condition     = startswith(terraform_data.machine_config_version[0].input, "v1.14.2/v1.37.1/")
    error_message = "the new document must be hashed into the replace trigger"
  }
}

run "time_servers_and_encrypted_dns_share_one_document" {
  command = apply
  variables {
    node_time_servers = ["192.0.2.10"]
    node_nameservers  = [{ address = "9.9.9.9", tls_server_name = "dns.quad9.net" }]
  }
  assert {
    condition     = length([for d in output.appended_documents : d if yamldecode(d).kind == "TimeSyncConfig"]) == 1
    error_message = "there must be exactly ONE TimeSyncConfig: a second one would be a duplicate document"
  }
  assert {
    condition     = yamldecode(output.appended_documents[1]).bootTimeout == "90s" && yamldecode(output.appended_documents[1]).ntp.servers == ["192.0.2.10"]
    error_message = "bootTimeout and ntp.servers must be in the same document"
  }
}

run "a_url_or_duplicate_time_server_is_refused" {
  command = plan
  variables {
    node_time_servers = ["ntp://example.org"]
  }
  expect_failures = [var.node_time_servers]
}

run "duplicate_time_servers_are_refused" {
  command = plan
  variables {
    node_time_servers = ["a.example.org", "a.example.org"]
  }
  expect_failures = [var.node_time_servers]
}
