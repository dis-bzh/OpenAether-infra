# Provider Contract Outputs — see provider-contract.md

# Node private IPs
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = outscale_vm.control_plane[*].private_ip
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = outscale_vm.worker[*].private_ip
}

# Read from the VM, not var.availability_zones: where a VM actually landed is the fact,
# and the variable is only what was asked for.
output "control_plane_zones" {
  description = "Subregion of each control plane VM, in control_plane_private_ips order"
  value       = outscale_vm.control_plane[*].placement_subregion_name
}

output "worker_zones" {
  description = "Subregion of each worker VM, in worker_private_ips order"
  value       = outscale_vm.worker[*].placement_subregion_name
}

# Load Balancer DNS names (Outscale LBs expose a DNS name, not a raw IP)
output "k8s_lb_ip" {
  description = "DNS name of the Kubernetes API LB (6443)"
  value       = outscale_load_balancer.k8s.dns_name
}

output "app_lb_ip" {
  description = "DNS name of the App LB (80/443). Null means no application load balancer on this cluster (deploy_app_lb = false)."
  value       = one(outscale_load_balancer.app[*].dns_name)
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = outscale_public_ip.bastion.public_ip
}

# Not part of the provider contract: the subnet layout of #58, readable by a test.
output "private_subnet_zones" {
  description = "Subregion of each private subnet, in node-placement order"
  value       = outscale_subnet.private[*].subregion_name
}

output "private_subnet_cidrs" {
  description = "CIDR of each private subnet"
  value       = outscale_subnet.private[*].ip_range
}

output "public_subnet_cidr" {
  description = "CIDR of the single public subnet (bastion, NAT service, load balancers)"
  value       = outscale_subnet.public.ip_range
}

output "control_plane_zone_index" {
  description = "Index into the private subnets of each control plane (its zone)"
  value       = local.cp_zone_index
}

output "worker_zone_index" {
  description = "Index into the private subnets of each worker (its zone, and its data volumes')"
  value       = local.worker_zone_index
}

# Test-only: the bastion's outbound rules as "protocol port destination", for the egress tests.
output "bastion_egress_rules" {
  description = "Every Outbound rule of the bastion security group as 'protocol from-to ip_range', for tests"
  value = concat(
    [for r in outscale_security_group_rule.bastion_egress_private : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for k, r in outscale_security_group_rule.bastion_egress_cluster : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for r in outscale_security_group_rule.bastion_egress_dns_udp : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for r in outscale_security_group_rule.bastion_egress_dns_tcp : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for k, r in outscale_security_group_rule.bastion_egress_dns_pinned : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for k, r in outscale_security_group_rule.bastion_egress_ntp_pinned : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for r in outscale_security_group_rule.bastion_egress_metadata : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for r in outscale_security_group_rule.bastion_egress_http : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
    [for r in outscale_security_group_rule.bastion_egress_https : "${r.ip_protocol} ${r.from_port_range}-${r.to_port_range} ${r.ip_range}"],
  )
}

# Test-only: a test cannot read a child module's resources. The sources admitted on the app LB ports, as "port source".
output "app_lb_sources" {
  description = "Source CIDRs of the app LB inbound rules (80, 443), for tests; empty = no rule (unfiltered or no app LB)"
  value = {
    http  = sort([for k, r in outscale_security_group_rule.app_lb_http : k])
    https = sort([for k, r in outscale_security_group_rule.app_lb_https : k])
  }
}

# Test-only: see the OVH output of the same name.
output "inter_node_rules" {
  description = "restrict_inter_node: the explicit member rules as 'PROTOCOL ports' and whether the all-protocol and 51820 rules exist, for tests"
  value = {
    all_protocol = length(outscale_security_group_rule.inter_node) > 0
    wireguard    = length(outscale_security_group_rule.wireguard) > 0
    explicit = sort([for k, r in outscale_security_group_rule.inter_node_ports :
      "${upper(r.rules[0].ip_protocol)} ${r.rules[0].from_port_range == -1 ? "-" : (r.rules[0].from_port_range == r.rules[0].to_port_range ? tostring(r.rules[0].from_port_range) : "${r.rules[0].from_port_range}-${r.rules[0].to_port_range}")}"
    ])
  }
}

# Test-only: the health check of the app LB; null = no app LB.
output "app_lb_health_check" {
  description = "Health check of the app LB, for tests (null = no app LB)"
  value = one([
    for a in outscale_load_balancer_attributes.app : {
      check_interval      = a.health_check[0].check_interval
      timeout             = a.health_check[0].timeout
      healthy_threshold   = a.health_check[0].healthy_threshold
      unhealthy_threshold = a.health_check[0].unhealthy_threshold
      port                = a.health_check[0].port
      protocol            = a.health_check[0].protocol
    }
  ])
}
