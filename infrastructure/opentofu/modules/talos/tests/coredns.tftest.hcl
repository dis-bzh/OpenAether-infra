# CoreDNS (infra #388): the Talos-owned Deployment (2 replicas, both on one worker in lab 21, no budget) is disabled and
# OpenAether's own is injected, with replicas that must sit on different nodes. Mocked: this proves the rendered config and
# manifest, not that a node runs it (LAB-CHECKLIST: power off the worker holding a replica and watch a 1 Hz DNS lookup).

mock_provider "talos" {}
mock_provider "random" {}

variables {
  cluster_name            = "t"
  cluster_endpoint        = "https://10.0.0.10:6443"
  talos_version           = "v1.14.2"
  kubernetes_version      = "v1.37.1"
  control_plane_count     = 3
  worker_count            = 4
  control_plane_ips       = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]
  worker_ips              = ["10.0.0.20", "10.0.0.21", "10.0.0.22", "10.0.0.23"]
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

run "default_disables_the_talos_coredns_and_ships_three_replicas" {
  command = apply
  assert {
    condition     = yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).cluster.coreDNS.disabled == true
    error_message = "the Talos CoreDNS must be disabled, or two Deployments fight over kube-system/coredns"
  }
  assert {
    condition     = length([for m in yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).cluster.inlineManifests : m if m.name == "coredns"]) == 1
    error_message = "exactly one inline manifest named coredns"
  }
  assert {
    condition     = local.coredns_replicas == 3
    error_message = "seven nodes must give three replicas"
  }
}

run "the_manifest_spreads_over_nodes_and_keeps_a_budget" {
  command = apply
  assert {
    condition     = strcontains(local.coredns_manifests[0].contents, "replicas: 3") && strcontains(local.coredns_manifests[0].contents, "minDomains: 3")
    error_message = "three replicas and minDomains 3"
  }
  assert {
    condition     = strcontains(local.coredns_manifests[0].contents, "whenUnsatisfiable: DoNotSchedule") && strcontains(local.coredns_manifests[0].contents, "topologyKey: kubernetes.io/hostname")
    error_message = "a hard hostname spread: the replicas must not share a node"
  }
  assert {
    condition     = strcontains(local.coredns_manifests[0].contents, "kind: PodDisruptionBudget") && strcontains(local.coredns_manifests[0].contents, "maxUnavailable: 1")
    error_message = "a budget allowing one disruption"
  }
  assert {
    condition     = strcontains(local.coredns_manifests[0].contents, "tolerationSeconds: 30") && !strcontains(local.coredns_manifests[0].contents, "tolerationSeconds: 300")
    error_message = "a 30 s not-ready/unreachable toleration, not the 300 s default"
  }
  assert {
    condition     = strcontains(local.coredns_manifests[0].contents, "clusterIP: 10.96.0.10") && strcontains(local.coredns_manifests[0].contents, "k8s-app: kube-dns")
    error_message = "the Service keeps the ClusterIP kubelet hands to pods and the label the network policies select"
  }
}

run "a_small_cluster_gets_fewer_replicas_and_never_a_pending_one" {
  command = apply
  variables {
    control_plane_count = 1
    worker_count        = 1
    control_plane_ips   = ["10.0.0.10"]
    worker_ips          = ["10.0.0.20"]
  }
  assert {
    condition     = strcontains(local.coredns_manifests[0].contents, "replicas: 2") && strcontains(local.coredns_manifests[0].contents, "minDomains: 2")
    error_message = "two nodes: two replicas, or a third would wait for ever"
  }
}

run "off_keeps_the_talos_coredns_and_the_old_trigger" {
  command = apply
  variables {
    coredns_ha = false
  }
  assert {
    condition     = !can(yamldecode(data.talos_machine_configuration.control_plane[0].config_patches[0]).cluster.coreDNS) && length(local.coredns_manifests) == 0
    error_message = "coredns_ha = false must render nothing"
  }
  assert {
    condition     = terraform_data.machine_config_version[0].input == "v1.14.2/v1.37.1"
    error_message = "the replace trigger must be unchanged when off"
  }
}

run "on_changes_the_trigger_so_an_existing_cluster_gets_it" {
  command = apply
  assert {
    condition     = startswith(terraform_data.machine_config_version[0].input, "v1.14.2/v1.37.1/")
    error_message = "the manifest must be in the replace trigger"
  }
}

# Zone spread (infra #388, lab 28 I2): the hostname spread alone let all three replicas land in ONE zone at install, so a zone loss
# could take every DNS replica. With three or more zones and a zone label on EVERY node the zone term is required (DoNotSchedule,
# minDomains 3 so a replica created before the other zones registered waits for one, nodeTaintsPolicy Honor so a lost zone's nodes
# are not counted as empty domains); with fewer, or a node without the label, it stays a preference: a hard rule would leave the
# pods Pending on a node that has no label (no topology key), or on a cluster that has two zones.

run "three_zones_make_the_zone_spread_required" {
  command = apply
  variables {
    node_zones = {
      control_plane = ["z-a", "z-b", "z-c"]
      worker        = ["z-a", "z-b", "z-c", "z-a"]
    }
  }
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).whenUnsatisfiable == "DoNotSchedule"
    error_message = "three zones, every node labelled: the zone spread must be required, or all replicas can share a zone"
  }
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).minDomains == 3
    error_message = "minDomains 3 on the zone term: a replica created before the other zones registered must wait, not join the first zone"
  }
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).nodeTaintsPolicy == "Honor"
    error_message = "nodeTaintsPolicy Honor: the nodes of a lost zone are not an empty domain the replacement must wait for"
  }
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "kubernetes.io/hostname"]).whenUnsatisfiable == "DoNotSchedule"
    error_message = "the hostname spread stays required"
  }
}

run "two_zones_keep_the_zone_spread_a_preference" {
  command = apply
  variables {
    node_zones = {
      control_plane = ["z-a", "z-b", "z-a"]
      worker        = ["z-b", "z-a", "z-b", "z-a"]
    }
  }
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).whenUnsatisfiable == "ScheduleAnyway"
    error_message = "two zones: the zone spread stays a preference (a required one would leave a replica without a third zone)"
  }
  assert {
    condition = try(one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).minDomains, null) == null
    error_message = "minDomains is only valid with DoNotSchedule: the soft zone term must not carry it"
  }
}

run "a_node_without_a_zone_label_keeps_it_a_preference" {
  command = apply
  variables {
    node_zones = {
      control_plane = ["z-a", "z-b", "z-c"]
      worker        = ["z-a", "z-b", "z-c", ""]
    }
  }
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).whenUnsatisfiable == "ScheduleAnyway"
    error_message = "a node with no zone label can never take a pod under a required zone rule: the term stays a preference"
  }
}

run "no_zone_information_keeps_it_a_preference" {
  command = apply
  assert {
    condition = one([for c in yamldecode([for d in split("\n---\n", local.coredns_manifests[0].contents) : d if strcontains(d, "kind: Deployment")][0]).spec.template.spec.topologySpreadConstraints :
    c if c.topologyKey == "topology.kubernetes.io/zone"]).whenUnsatisfiable == "ScheduleAnyway"
    error_message = "no node_zones (local Docker, Proxmox): the zone term is a preference"
  }
}
