# Contract outputs (modules/providers/provider-contract.md)

output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes (Talos on 50000/TCP)"
  value       = local.control_plane_ips
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = local.worker_ips
}

output "control_plane_zones" {
  description = "Hypervisor host each control plane runs on, in control_plane_private_ips order"
  value       = proxmox_virtual_environment_vm.control_plane[*].node_name
}

# No cloud LB on a single Proxmox host: the Kubernetes API is fronted by the
# Talos VIP (owned by the control plane), injected into the machineconfig by
# modules/talos; here we only surface the address.
output "k8s_lb_ip" {
  description = "Kubernetes API endpoint (Talos VIP, port 6443)"
  value       = var.apiserver_vip
}

# SSH jump target for talos-tunnels.sh. Default (host-as-bastion): the Proxmox
# host's public IP. With a VM bastion: its public/failover IP (else private IP).
output "bastion_ip" {
  description = "Public IP used as the SSH jump host (Proxmox host by default, bastion VM if enable_bastion)"
  value = (var.enable_bastion
    ? (var.bastion_public_ip != "" ? var.bastion_public_ip : local.bastion_private_ip)
    : var.host_public_ip
  )
}

output "bastion_user" {
  description = "SSH user for the jump host (host_ssh_user by default; 'ubuntu' for the VM bastion)"
  value       = var.enable_bastion ? "ubuntu" : var.host_ssh_user
}

# No managed app LB: expose the worker IPs so the caller can point ingress/DNS at
# them (or a host haproxy). app_lb_ip intentionally omitted (no floating IP).
output "worker_ingress_targets" {
  description = "Worker private IPs serving ingress on 80/443 (no managed app LB on Proxmox)"
  value       = local.worker_ips
}

# Perimeter is host nftables (out-of-tofu, manual/Ansible). Surface the values it
# must enforce so the host firewall / Ansible template can consume them directly:
# DNAT 80/443 → worker_ingress_targets, SSH accept from admin_cidrs only.
output "admin_cidrs" {
  description = "Admin CIDRs the host nftables should allow for SSH (contract admin_ip passthrough)"
  value       = var.admin_ip
}
