# Provider Contract Outputs — see provider-contract.md

# Node private IPs
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = [for p in openstack_networking_port_v2.control_plane : try(p.all_fixed_ips[0], "")]
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = openstack_compute_instance_v2.worker[*].access_ip_v4
}

output "control_plane_zones" {
  description = "Availability zone of each control plane, in control_plane_private_ips order"
  value       = openstack_compute_instance_v2.control_plane[*].availability_zone
}

# Load Balancer IPs (floating IPs)
output "k8s_lb_ip" {
  description = "Public IP of the Kubernetes API LB (6443), or the private Talos VIP when k8s_lb_mode = \"vip\""
  value       = var.k8s_lb_mode == "managed" ? openstack_networking_floatingip_v2.k8s[0].address : try(openstack_networking_port_v2.k8s_vip[0].all_fixed_ips[0], "")
}

output "k8s_lb_health_check" {
  description = "How the Kubernetes API load balancer checks a control plane; null in vip mode (no load balancer)."
  value = var.k8s_lb_mode == "managed" ? {
    protocol = openstack_lb_monitor_v2.k8s_api[0].type
    path     = openstack_lb_monitor_v2.k8s_api[0].url_path # unknown until apply while the monitor is TCP
  } : null
}

output "app_lb_ip" {
  description = "Public IP of the App LB (80/443). Null means no application load balancer on this cluster (deploy_app_lb = false)."
  # one(): returns null on the empty list instead of failing on [0].
  value = one(openstack_networking_floatingip_v2.app[*].address)
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = openstack_networking_floatingip_v2.bastion.address
}
