output "inbound" {
  description = "name => { protocol (TCP|UDP|ICMP), ports (\"6443\", \"2379-2381\" or null for ICMP) }"
  value       = local.inbound
}

output "between_members" {
  description = "inbound without the entries a stateful group does not need as a rule (see not_between_members)"
  value       = { for k, r in local.inbound : k => r if !contains(local.not_between_members, k) }
}

output "scope" {
  description = "name => source groups (nodes, bastion, pods, lb) that may open the flow, for the Talos ingress rules"
  value       = local.scope
}

output "talos_ports" {
  description = "between_members with etcd split in client/peer (2379-2380) and metrics (2381), for the Talos allow-list rules"
  value       = local.talos_ports
}

output "talos_scope" {
  description = "scope plus the etcd-metrics entry, for the Talos allow-list rules"
  value       = local.talos_scope
}
