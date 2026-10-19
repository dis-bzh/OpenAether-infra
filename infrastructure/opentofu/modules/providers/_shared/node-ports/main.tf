# ==============================================================================
# The ports that reach a Talos node over the private network: the ONE list that
# the Scaleway group, the OVH and Outscale member rules (restrict_inter_node) and
# the Talos ingress rules (node_firewall_mode) are all built from, so they cannot
# drift apart. cluster/tests/node-firewall.tftest.hcl pins the three against it.
# ==============================================================================

locals {
  # Each entry carries its evidence. Scaleway applies every entry to its subnet.
  inbound = {
    kube-apiserver   = { protocol = "TCP", ports = "6443" }      # kubelets, bastion tunnel, VIP, k8s LB
    talos-apid       = { protocol = "TCP", ports = "50000" }     # bastion tunnels, apid proxying between nodes
    talos-trustd     = { protocol = "TCP", ports = "50001" }     # workers fetch certificates from control planes
    etcd             = { protocol = "TCP", ports = "2379-2381" } # client, peer, metrics (modules/talos)
    kubelet          = { protocol = "TCP", ports = "10250" }     # apiserver -> kubelet
    cilium-vxlan     = { protocol = "UDP", ports = "8472" }      # routing-mode tunnel, vxlan
    cilium-wireguard = { protocol = "UDP", ports = "51871" }     # encryption.type=wireguard
    cilium-health    = { protocol = "TCP", ports = "4240" }      # enable-health-checking
    cilium-icmp      = { protocol = "ICMP", ports = null }       # cilium-health probes, path MTU discovery
    cilium-metrics   = { protocol = "TCP", ports = "9962-9964" } # agent, operator, envoy hostPorts
    node-exporter    = { protocol = "TCP", ports = "9100" }      # apps layer (hostNetwork), unverified here
    dhcp             = { protocol = "UDP", ports = "68" }        # private network IPAM leases, unverified
  }

  # Entries a stateful group or a host firewall does not need as a rule of their own: the DHCP server
  # is not a cluster member and replies to the node's own request (tracked), so only Scaleway lists it.
  not_between_members = ["dhcp"]

  # Who may open each flow, by source group (nodes, bastion, pods). Used by the Talos rules only; the
  # security groups express sources their own way. Tightening 2379-2381 / 10250 to control planes is a
  # later step, once enforcement has been validated (B24 stage 2).
  scope = {
    kube-apiserver   = ["nodes", "bastion", "pods", "lb"]
    talos-apid       = ["nodes", "bastion"]
    talos-trustd     = ["nodes"]
    etcd             = ["nodes"]
    kubelet          = ["nodes", "pods"]
    cilium-vxlan     = ["nodes"]
    cilium-wireguard = ["nodes"]
    cilium-health    = ["nodes"]
    cilium-icmp      = ["nodes", "pods"]
    cilium-metrics   = ["nodes", "pods"]
    node-exporter    = ["nodes", "pods"]
    dhcp             = ["nodes"]
  }

  # The Talos rules are per-port ALLOW-LISTS (a source outside the list is dropped), so they are cut finer
  # than the security groups: etcd's metrics port 2381 is scraped by vmagent, a pod, which on the node it
  # shares with a control plane arrives with its pod address (not masqueraded; the same-node probes of lab
  # 11 show a pod address dropped by a nodes-only rule). Splitting it keeps 2379-2380 (client, peer) nodes
  # only. The security groups keep the single 2379-2381 entry of `inbound`: they do not change.
  talos_ports = merge(
    { for k, r in local.inbound : k => r if !contains(local.not_between_members, k) && k != "etcd" },
    {
      etcd         = { protocol = "TCP", ports = "2379-2380" }
      etcd-metrics = { protocol = "TCP", ports = "2381" }
    },
  )
  talos_scope = merge(local.scope, { etcd-metrics = ["nodes", "pods"] })
}
