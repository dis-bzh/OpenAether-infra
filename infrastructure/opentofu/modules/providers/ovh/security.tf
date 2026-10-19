# ==============================================================================
# OVH / OpenStack — Security Groups
# inbound_default = drop (delete_default_rules). Only required ports opened.
#
# OVH Octavia health checks originate from the LB VIP subnet CIDR.
# We allow the full private subnet (10.0.0.0/24) for LB + inter-node traffic.
# K8s API is further restricted by the Octavia listener allowed_cidrs.
# ==============================================================================

# The list shared with Scaleway and the Talos ingress rules.
module "node_ports" {
  source = "../_shared/node-ports"
}

resource "openstack_networking_secgroup_v2" "this" {
  name                 = "${var.cluster_name}-cluster-sg"
  description          = "OpenAether cluster nodes — least-privilege inbound"
  delete_default_rules = true
}

# Kubernetes API — from private subnet (LB health checks + inter-node)
# Additional restriction enforced at LB listener level (allowed_cidrs)
resource "openstack_networking_secgroup_rule_v2" "k8s_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Talos API — from bastion security group only
resource "openstack_networking_secgroup_rule_v2" "talos_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 50000
  port_range_max    = 50000
  remote_group_id   = openstack_networking_secgroup_v2.bastion.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# HTTP/HTTPS — from the private subnet (App LB + its health checks), on the
# Gateway's FIXED NodePorts. Opening 80/443 on the nodes would be pointless:
# it is the Istio Gateway that listens, behind a NodePort.
# Gated on deploy_app_lb: the App LB is the only source these two ever admit,
# so without it they widen the nodes' inbound surface for no traffic at all.
resource "openstack_networking_secgroup_rule_v2" "http" {
  count             = var.deploy_app_lb ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.app_lb_node_ports.http
  port_range_max    = var.app_lb_node_ports.http
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  count             = var.deploy_app_lb ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.app_lb_node_ports.https
  port_range_max    = var.app_lb_node_ports.https
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# WireGuard — Cilium inter-node encryption (UDP 51820)
# Replaced, with restrict_inter_node, by the shared list (51871 is where Cilium's WireGuard listens).
resource "openstack_networking_secgroup_rule_v2" "wireguard" {
  count             = var.restrict_inter_node ? 0 : 1
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 51820
  port_range_max    = 51820
  remote_group_id   = openstack_networking_secgroup_v2.this.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Inter-node — full mesh TCP (etcd, kubelet, Cilium)
resource "openstack_networking_secgroup_rule_v2" "inter_node" {
  count             = var.restrict_inter_node ? 0 : 1
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.this.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Inter-node, explicit (restrict_inter_node): one rule per entry of the shared list, members only.
resource "openstack_networking_secgroup_rule_v2" "inter_node_ports" {
  for_each          = var.restrict_inter_node ? module.node_ports.between_members : {}
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = lower(each.value.protocol)
  port_range_min    = each.value.ports == null ? null : tonumber(split("-", each.value.ports)[0])
  port_range_max    = each.value.ports == null ? null : tonumber(reverse(split("-", each.value.ports))[0])
  remote_group_id   = openstack_networking_secgroup_v2.this.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Outbound — allow all
resource "openstack_networking_secgroup_rule_v2" "egress_v4" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_v6" {
  direction         = "egress"
  ethertype         = "IPv6"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# The two rules gained a count: keep their state (no destroy and recreate on a deployed cluster).
moved {
  from = openstack_networking_secgroup_rule_v2.wireguard
  to   = openstack_networking_secgroup_rule_v2.wireguard[0]
}
moved {
  from = openstack_networking_secgroup_rule_v2.inter_node
  to   = openstack_networking_secgroup_rule_v2.inter_node[0]
}
