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
