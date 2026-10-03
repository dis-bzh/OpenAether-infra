# ==============================================================================
# Outscale — Security Groups
# inbound_default = drop. Only required ports explicitly opened.
# ==============================================================================

resource "outscale_security_group" "this" {
  description         = "OpenAether cluster nodes - least-privilege inbound"
  security_group_name = "${var.cluster_name}-cluster-sg"
  net_id              = outscale_net.this.net_id
}

# Kubernetes API — from LB subnet (health checks) + admin IPs
resource "outscale_security_group_rule" "k8s_api_private" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = outscale_subnet.public.ip_range
}

resource "outscale_security_group_rule" "k8s_api_admin" {
  for_each          = toset(var.admin_ip)
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = each.value
}

# Talos API — from bastion security group only
resource "outscale_security_group_rule" "talos_api" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    from_port_range = 50000
    to_port_range   = 50000
    ip_protocol     = "tcp"
    security_groups_members {
      security_group_id = outscale_security_group.bastion.security_group_id
    }
  }
}

# HTTP/HTTPS — from the LB subnet, on the Gateway's FIXED NodePorts.
# Opening 80/443 on the nodes would be pointless: nothing listens there.
# Tied to the app LB: with no LB on that subnet, these two only widen the
# nodes' inbound surface for a caller that does not exist.
resource "outscale_security_group_rule" "http" {
  count             = var.deploy_app_lb ? 1 : 0
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = var.app_lb_node_ports.http
  to_port_range     = var.app_lb_node_ports.http
  ip_protocol       = "tcp"
  ip_range          = outscale_subnet.public.ip_range
}

resource "outscale_security_group_rule" "https" {
  count             = var.deploy_app_lb ? 1 : 0
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = var.app_lb_node_ports.https
  to_port_range     = var.app_lb_node_ports.https
  ip_protocol       = "tcp"
  ip_range          = outscale_subnet.public.ip_range
}

# WireGuard — Cilium inter-node encryption (UDP 51820)
resource "outscale_security_group_rule" "wireguard" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    from_port_range = 51820
    to_port_range   = 51820
    ip_protocol     = "udp"
    security_groups_members {
      security_group_id = outscale_security_group.this.security_group_id
    }
  }
}

# Inter-node — full mesh (etcd, kubelet, Cilium)
resource "outscale_security_group_rule" "inter_node" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    ip_protocol = "-1"
    security_groups_members {
      security_group_id = outscale_security_group.this.security_group_id
    }
  }
}
