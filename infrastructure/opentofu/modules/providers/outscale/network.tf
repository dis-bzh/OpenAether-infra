# ==============================================================================
# Outscale — Network (AWS-style two-subnet layout for node egress)
#
#   private subnets (one per availability zone; the first is 10.0.0.0/24) — cluster
#     control planes + workers, spread over the zones by index (#58).
#     Default route -> NAT service, so the nodes (which have NO public IP) still
#     reach the internet for image pulls and NTP.
#   public  subnets (one per availability zone; the first is 10.0.1.0/24) — bastion and
#     NAT service (first zone), internet-facing LBs (every zone, so the API endpoint
#     does not live in one subregion).
#     Default route -> Internet Gateway.
#
# A bare Internet Gateway only NATs instances that own a public IP (1:1), so a
# private subnet needs a NAT Service for outbound. This mirrors the egress paths
# the other providers already have (Scaleway public-gateway, OVH router SNAT).
# ==============================================================================

locals {
  net_cidr = "10.0.0.0/16"
  # One private and one public subnet per entry of availability_zones. The numbers are the
  # /24 slots inside the Net: the first zone keeps the 10.0.0.0/24 and 10.0.1.0/24 this module
  # always used, the others take 10.0.2.0/24, 10.0.3.0/24 and 10.0.4.0/24, 10.0.5.0/24.
  private_netnums = [for i in range(length(var.availability_zones)) : i == 0 ? 0 : 1 + i]
  public_netnums  = [for i in range(length(var.availability_zones)) : i == 0 ? 1 : 3 + i]
}

resource "outscale_net" "this" {
  ip_range = local.net_cidr

  tags {
    key   = "Name"
    value = "${var.cluster_name}-net"
  }
}

# --- Private subnets: cluster nodes (egress via the NAT service) ---
resource "outscale_subnet" "private" {
  count          = length(var.availability_zones)
  net_id         = outscale_net.this.net_id
  ip_range       = cidrsubnet(local.net_cidr, 8, local.private_netnums[count.index])
  subregion_name = var.availability_zones[count.index]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-subnet-${count.index}"
  }
}

moved {
  from = outscale_subnet.private
  to   = outscale_subnet.private[0]
}

# --- Public subnets: bastion and NAT service (the first), internet-facing LBs (all) ---
resource "outscale_subnet" "public" {
  count          = length(var.availability_zones)
  net_id         = outscale_net.this.net_id
  ip_range       = cidrsubnet(local.net_cidr, 8, local.public_netnums[count.index])
  subregion_name = var.availability_zones[count.index]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-public-subnet-${count.index}"
  }
}

moved {
  from = outscale_subnet.public
  to   = outscale_subnet.public[0]
}

# --- Internet Gateway (outbound for the public subnet + NAT service) ---
resource "outscale_internet_service" "this" {
  tags {
    key   = "Name"
    value = "${var.cluster_name}-igw"
  }
}

resource "outscale_internet_service_link" "this" {
  internet_service_id = outscale_internet_service.this.internet_service_id
  net_id              = outscale_net.this.net_id
}

# --- NAT service: gives the private nodes outbound internet (no public IP needed) ---
resource "outscale_public_ip" "nat" {}

resource "outscale_nat_service" "this" {
  subnet_id    = outscale_subnet.public[0].subnet_id
  public_ip_id = outscale_public_ip.nat.public_ip_id

  # The NAT service must sit behind a working IGW route before it can forward.
  depends_on = [outscale_internet_service_link.this, outscale_route_table_link.public]
}

# --- Public route table: 0.0.0.0/0 -> Internet Gateway ---
resource "outscale_route_table" "public" {
  net_id = outscale_net.this.net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-public-rt"
  }
}

resource "outscale_route" "public_internet" {
  route_table_id       = outscale_route_table.public.route_table_id
  destination_ip_range = "0.0.0.0/0"
  gateway_id           = outscale_internet_service.this.internet_service_id
}

resource "outscale_route_table_link" "public" {
  count          = length(var.availability_zones)
  route_table_id = outscale_route_table.public.route_table_id
  subnet_id      = outscale_subnet.public[count.index].subnet_id
}

moved {
  from = outscale_route_table_link.public
  to   = outscale_route_table_link.public[0]
}

# --- Private route table: 0.0.0.0/0 -> NAT service ---
resource "outscale_route_table" "private" {
  net_id = outscale_net.this.net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-rt"
  }
}

resource "outscale_route" "private_nat" {
  route_table_id       = outscale_route_table.private.route_table_id
  destination_ip_range = "0.0.0.0/0"
  nat_service_id       = outscale_nat_service.this.nat_service_id
}

resource "outscale_route_table_link" "private" {
  count          = length(var.availability_zones)
  route_table_id = outscale_route_table.private.route_table_id
  subnet_id      = outscale_subnet.private[count.index].subnet_id
}

moved {
  from = outscale_route_table_link.private
  to   = outscale_route_table_link.private[0]
}
