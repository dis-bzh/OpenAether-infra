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

# Test-only: the bastion's egress rules as "protocol port destination", for the egress tests.
output "bastion_egress_rules" {
  description = "Every egress rule of the bastion security group as 'protocol port remote_ip_prefix', for tests"
  value = concat(
    [for r in openstack_networking_secgroup_rule_v2.bastion_egress_private : "all - ${r.remote_ip_prefix}"],
    [for k, r in openstack_networking_secgroup_rule_v2.bastion_egress_cluster : "${r.protocol} ${r.port_range_min} ${r.remote_ip_prefix}"],
    [for r in openstack_networking_secgroup_rule_v2.bastion_egress_dns : "${r.protocol} ${r.port_range_min} any"],
    [for r in openstack_networking_secgroup_rule_v2.bastion_egress_dns_tcp : "${r.protocol} ${r.port_range_min} any"],
    [for k, r in openstack_networking_secgroup_rule_v2.bastion_egress_dns_pinned : "${r.protocol} ${r.port_range_min} ${r.remote_ip_prefix}"],
    [for k, r in openstack_networking_secgroup_rule_v2.bastion_egress_ntp_pinned : "${r.protocol} ${r.port_range_min} ${r.remote_ip_prefix}"],
    [for r in openstack_networking_secgroup_rule_v2.bastion_egress_metadata : "${r.protocol} ${r.port_range_min} ${r.remote_ip_prefix}"],
    [for r in openstack_networking_secgroup_rule_v2.bastion_egress_http : "${r.protocol} ${r.port_range_min} any"],
    [for r in openstack_networking_secgroup_rule_v2.bastion_egress_https : "${r.protocol} ${r.port_range_min} any"],
  )
}

# Test-only: a test cannot read a child module's resources. The allowed_cidrs of the app LB listeners (null = no filter).
output "app_lb_allowed_cidrs" {
  description = "allowed_cidrs of the app LB http and https listeners, for tests (null = unfiltered)"
  value = {
    http  = one(openstack_lb_listener_v2.http[*].allowed_cidrs)
    https = one(openstack_lb_listener_v2.https[*].allowed_cidrs)
  }
}

# Test-only: the member-to-member rules in the shared list's notation ("TCP 6443", "ICMP -"), and whether the
# two broad rules are still there.
output "inter_node_rules" {
  description = "restrict_inter_node: the explicit member rules as 'PROTOCOL ports' and whether the all-protocol and 51820 rules exist, for tests"
  value = {
    all_protocol = length(openstack_networking_secgroup_rule_v2.inter_node) > 0
    wireguard    = length(openstack_networking_secgroup_rule_v2.wireguard) > 0
    explicit = sort([for k, r in openstack_networking_secgroup_rule_v2.inter_node_ports :
      "${upper(r.protocol)} ${r.port_range_min == null || r.port_range_min == 0 ? "-" : (r.port_range_min == r.port_range_max ? tostring(r.port_range_min) : "${r.port_range_min}-${r.port_range_max}")}"
    ])
  }
}

output "flavor_disk_gb" {
  description = "Root disk (GB) of flavor_name, or null when look_up_flavor_disk is off."
  value       = one(data.openstack_compute_flavor_v2.node[*].disk)
}
