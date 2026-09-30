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

# Read from the VM, not var.availability_zones: only [0] is used (#58), so the
# variable would claim a spread that does not exist.
output "control_plane_zones" {
  description = "Subregion of each control plane VM, in control_plane_private_ips order"
  value       = outscale_vm.control_plane[*].placement_subregion_name
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
