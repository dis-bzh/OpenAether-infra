# Node private IPs (via IPAM)
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = [for ip in scaleway_ipam_ip.control_plane : split("/", ip.address)[0]]
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = [for ip in scaleway_ipam_ip.worker : split("/", ip.address)[0]]
}

# Load Balancer IPs
output "k8s_lb_ip" {
  description = "Public IP of the Kubernetes API LB (6443), or the private Talos VIP when k8s_lb_mode = \"vip\""
  value       = var.k8s_lb_mode == "managed" ? scaleway_lb_ip.k8s[0].ip_address : split("/", scaleway_ipam_ip.k8s_vip[0].address)[0]
}

output "app_lb_ip" {
  description = "Public IP of the App LB (80/443). Null means no application load balancer on this cluster (deploy_app_lb = false)."
  value       = one(scaleway_lb_ip.app[*].ip_address)
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = scaleway_instance_ip.bastion.address
}

# NAT Gateway
output "nat_gateway_ip" {
  description = "Public IP of the NAT gateway (for LB ACL whitelisting)"
  value       = scaleway_vpc_public_gateway_ip.this.address
}

# Test-only: a test cannot read a child module's resources, so this is how
# scaleway.tftest.hcl checks the generated inbound rules (#79).
output "inbound_rules" {
  description = "Every inbound_rule (protocol, port, port_range, ip_range) of each zone's node group and of the bastion group, for tests"
  value = {
    for name, sg in merge(scaleway_instance_security_group.this, { bastion = scaleway_instance_security_group.bastion }) : name => [
      for r in sg.inbound_rule : { protocol = r.protocol, port = r.port, port_range = r.port_range, ip_range = r.ip_range }
    ]
  }
}
