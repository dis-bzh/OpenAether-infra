# Pin the subnet ourselves instead of trusting Scaleway's IPAM auto-assignment —
# OVH and Outscale already self-declare their CIDR (network.tf in each module);
# Scaleway was the outlier, which let security.tf's mesh rule drift from it (#79).
locals {
  scw_cluster_subnet = "172.16.0.0/22"
}

# Private Network for secure internal communication
resource "scaleway_vpc_private_network" "this" {
  name   = "${var.cluster_name}-private-network"
  region = var.region

  ipv4_subnet {
    subnet = local.scw_cluster_subnet
  }

  lifecycle {
    # A network built before the pin keeps the subnet Scaleway gave it. Changing it replaces the network, and with it every
    # private NIC, the gateway and load-balancer attachments: the 0.1.0 to 0.2.0 climb did that to a live cluster.
    ignore_changes = [ipv4_subnet]
  }
}

locals {
  # What the network really uses: the pin for a new one, the existing one for a network built before the pin. The node
  # security rules and the output below follow it, never the constant.
  scw_subnet_in_use = scaleway_vpc_private_network.this.ipv4_subnet[0].subnet
}

# Reserve IPs for control plane nodes via IPAM (VPC v2)
resource "scaleway_ipam_ip" "control_plane" {
  count      = var.control_plane_count
  project_id = var.project_id
  region     = var.region

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

# Attach control plane nodes to private network with reserved IPAM IPs
resource "scaleway_instance_private_nic" "control_plane" {
  count = var.control_plane_count

  server_id          = scaleway_instance_server.control_plane[count.index].id
  private_network_id = scaleway_vpc_private_network.this.id
  ipam_ip_ids        = [scaleway_ipam_ip.control_plane[count.index].id]
  zone               = element(var.additional_zones, count.index)
}

# Reserve IPs for worker nodes via IPAM (VPC v2)
resource "scaleway_ipam_ip" "worker" {
  count      = var.worker_count
  project_id = var.project_id
  region     = var.region

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

# Attach worker nodes to private network with reserved IPAM IPs
resource "scaleway_instance_private_nic" "worker" {
  count = var.worker_count

  server_id          = scaleway_instance_server.worker[count.index].id
  private_network_id = scaleway_vpc_private_network.this.id
  ipam_ip_ids        = [scaleway_ipam_ip.worker[count.index].id]
  zone               = element(var.additional_zones, count.index)
}

# Reserve a private IP for the Talos-managed apiserver VIP (k8s_lb_mode = "vip").
# Deliberately not attached to any NIC — Talos claims it via gratuitous ARP on
# whichever control plane currently holds it; IPAM just guarantees the address
# itself is never handed out to another node.
resource "scaleway_ipam_ip" "k8s_vip" {
  count      = var.k8s_lb_mode == "vip" ? 1 : 0
  project_id = var.project_id
  region     = var.region

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

# Attach bastion to private network (for access to nodes)
resource "scaleway_instance_private_nic" "bastion" {
  server_id          = scaleway_instance_server.bastion.id
  private_network_id = scaleway_vpc_private_network.this.id
  zone               = var.zone
}

# --- NAT & Internet Access for Private Nodes (VPC v2) ---

# IP for the Public Gateway
resource "scaleway_vpc_public_gateway_ip" "this" {
  project_id = var.project_id
  zone       = var.zone
}

# Public Gateway (NAT)
resource "scaleway_vpc_public_gateway" "this" {
  name       = "${var.cluster_name}-gateway"
  type       = "VPC-GW-S"
  project_id = var.project_id
  zone       = var.zone
  ip_id      = scaleway_vpc_public_gateway_ip.this.id

  # Ensure IP is fully created before the gateway
  depends_on = [scaleway_vpc_public_gateway_ip.this]
}

# Bridge Private Network and Public Gateway using IPAM (VPC v2)
resource "scaleway_vpc_gateway_network" "main" {
  gateway_id         = scaleway_vpc_public_gateway.this.id
  private_network_id = scaleway_vpc_private_network.this.id
  enable_masquerade  = true # Enable NAT
  zone               = var.zone

  ipam_config {
    push_default_route = true # Push default route to nodes for Internet access via NAT
  }
}
