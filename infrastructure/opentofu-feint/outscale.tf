# Outscale fixture — the shapes modules/providers/outscale builds, minus what
# the emulator does not serve.
#
# Feint 0.6.0 moved this a long way: security groups, public IPs, the internet
# service, the NAT service, route tables and NICs are all served now, so the
# egress plan below is the production one rather than a sketch of it. The load
# balancer is left out by design to keep this fixture small: `feint-apply-root`
# applies the real root with it (CreateLoadBalancer answers 200 since Feint 0.12.0).
#
# This is also the first apply-mode coverage Outscale has in this repository:
# cluster/tests/*.tftest.hcl mocks it at plan level only.

resource "outscale_net" "this" {
  count    = local.outscale_active
  ip_range = "10.0.0.0/16"

  # The provider calls CreateTags on almost everything, and tag order is a
  # permanent diff waiting to happen.
  tags {
    key   = "Name"
    value = "${var.cluster_name}-net"
  }
}

# Two subnets, as in production: the nodes sit private and reach the internet
# through the NAT service, the bastion sits public behind the internet service.
resource "outscale_subnet" "private" {
  count          = local.outscale_active
  net_id         = outscale_net.this[0].net_id
  ip_range       = "10.0.0.0/24"
  subregion_name = "eu-west-2a"

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-subnet"
  }
}

resource "outscale_subnet" "public" {
  count          = local.outscale_active
  net_id         = outscale_net.this[0].net_id
  ip_range       = "10.0.1.0/24"
  subregion_name = "eu-west-2a"

  tags {
    key   = "Name"
    value = "${var.cluster_name}-public-subnet"
  }
}

# --- Egress: internet service for the public subnet, NAT for the private one ---

# Tagged on purpose, and on more kinds than the module strictly needs: Feint's
# CreateTags knew four identifier prefixes against sixteen it minted, so ten
# taggable kinds answered "the resource does not exist" about resources it had
# just created (stephrobert/feint#99, fixed in 0.7.1). These blocks are what
# keeps that regression visible here rather than on a real account.
resource "outscale_internet_service" "this" {
  count = local.outscale_active

  tags {
    key   = "Name"
    value = "${var.cluster_name}-igw"
  }
}

resource "outscale_internet_service_link" "this" {
  count               = local.outscale_active
  internet_service_id = outscale_internet_service.this[0].internet_service_id
  net_id              = outscale_net.this[0].net_id
}

resource "outscale_public_ip" "nat" {
  count = local.outscale_active

  tags {
    key   = "Name"
    value = "${var.cluster_name}-nat-ip"
  }
}

# A bare internet service only NATs a machine that owns a public IP, so the
# private subnet needs its own NAT service for outbound — the same egress path
# the other providers get from a public gateway or a router.
resource "outscale_nat_service" "this" {
  count        = local.outscale_active
  subnet_id    = outscale_subnet.public[0].subnet_id
  public_ip_id = outscale_public_ip.nat[0].public_ip_id

  depends_on = [outscale_internet_service_link.this, outscale_route_table_link.public]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-nat"
  }
}

resource "outscale_route_table" "public" {
  count  = local.outscale_active
  net_id = outscale_net.this[0].net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-public-rt"
  }
}

resource "outscale_route" "public_internet" {
  count                = local.outscale_active
  route_table_id       = outscale_route_table.public[0].route_table_id
  destination_ip_range = "0.0.0.0/0"
  gateway_id           = outscale_internet_service.this[0].internet_service_id
}

resource "outscale_route_table_link" "public" {
  count          = local.outscale_active
  route_table_id = outscale_route_table.public[0].route_table_id
  subnet_id      = outscale_subnet.public[0].subnet_id
}

resource "outscale_route_table" "private" {
  count  = local.outscale_active
  net_id = outscale_net.this[0].net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-rt"
  }
}

resource "outscale_route" "private_nat" {
  count                = local.outscale_active
  route_table_id       = outscale_route_table.private[0].route_table_id
  destination_ip_range = "0.0.0.0/0"
  nat_service_id       = outscale_nat_service.this[0].nat_service_id
}

resource "outscale_route_table_link" "private" {
  count          = local.outscale_active
  route_table_id = outscale_route_table.private[0].route_table_id
  subnet_id      = outscale_subnet.private[0].subnet_id
}

# --- Security groups: inbound drop by default, rule 4 of provider-contract.md ---

resource "outscale_security_group" "this" {
  count               = local.outscale_active
  description         = "OpenAether cluster nodes - least-privilege inbound"
  security_group_name = "${var.cluster_name}-cluster-sg"
  net_id              = outscale_net.this[0].net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-cluster-sg"
  }
}

resource "outscale_security_group_rule" "k8s_api" {
  count             = local.outscale_active
  flow              = "Inbound"
  security_group_id = outscale_security_group.this[0].security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = outscale_subnet.public[0].ip_range
}

# Talos API from the bastion side only, never from a load balancer.
resource "outscale_security_group_rule" "talos_api" {
  count             = local.outscale_active
  flow              = "Inbound"
  security_group_id = outscale_security_group.this[0].security_group_id
  from_port_range   = 50000
  to_port_range     = 50000
  ip_protocol       = "tcp"
  ip_range          = outscale_subnet.public[0].ip_range
}

resource "outscale_security_group_rule" "wireguard" {
  count             = local.outscale_active
  flow              = "Inbound"
  security_group_id = outscale_security_group.this[0].security_group_id
  from_port_range   = 51820
  to_port_range     = 51820
  ip_protocol       = "udp"
  ip_range          = var.private_cidr
}

resource "outscale_security_group" "bastion" {
  count               = local.outscale_active
  description         = "OpenAether bastion - SSH from admin only"
  security_group_name = "${var.cluster_name}-bastion-sg"
  net_id              = outscale_net.this[0].net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-bastion-sg"
  }
}

resource "outscale_security_group_rule" "bastion_ssh" {
  count             = local.outscale_active
  flow              = "Inbound"
  security_group_id = outscale_security_group.bastion[0].security_group_id
  from_port_range   = 22
  to_port_range     = 22
  ip_protocol       = "tcp"
  ip_range          = var.admin_cidr
}

# --- Machines and storage ---

# Addressed by name at create and by id at destroy — both must be the same
# identity, which is only visible on a real destroy.
resource "outscale_keypair" "bastion" {
  count        = local.outscale_active
  keypair_name = "${var.cluster_name}-bastion"
  public_key   = local.bastion_ssh_keys[0]
}

resource "outscale_volume" "worker_data" {
  count          = local.outscale_active
  subregion_name = "eu-west-2a"
  size           = 10

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-data"
  }
}

resource "outscale_vm" "control_plane" {
  count              = local.outscale_active
  image_id           = "ami-00000001"
  vm_type            = "tinav6.c1r1p2"
  subnet_id          = outscale_subnet.private[0].subnet_id
  security_group_ids = [outscale_security_group.this[0].security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-cp-0"
  }
}

resource "outscale_vm" "worker" {
  count              = local.outscale_active
  image_id           = "ami-00000001"
  vm_type            = "tinav6.c1r1p2"
  subnet_id          = outscale_subnet.private[0].subnet_id
  security_group_ids = [outscale_security_group.this[0].security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-0"
  }
}

# The worker data disk. Served since 0.6.0 mounted the LinkVolumeVmIds filter
# the provider polls to wait for "attached" — before that the resource could not
# be created at all.
resource "outscale_volume_link" "worker_data" {
  count       = local.outscale_active
  device_name = "/dev/sdb"
  volume_id   = outscale_volume.worker_data[0].volume_id
  vm_id       = outscale_vm.worker[0].vm_id
}

# The bastion user is deliberately not the image default: cloud-init ignores a
# second definition of an existing user, so the account never joins
# bastion-admins and sshd rejects it through AllowGroups.
resource "outscale_vm" "bastion" {
  count              = local.outscale_active
  image_id           = "ami-00000001"
  vm_type            = "tinav6.c1r1p2"
  subnet_id          = outscale_subnet.public[0].subnet_id
  security_group_ids = [outscale_security_group.bastion[0].security_group_id]
  keypair_name       = outscale_keypair.bastion[0].keypair_name
  user_data          = base64encode(local.bastion_cloud_init)

  tags {
    key   = "Name"
    value = "${var.cluster_name}-bastion"
  }
}

resource "outscale_public_ip" "bastion" {
  count = local.outscale_active
}

resource "outscale_public_ip_link" "bastion" {
  count        = local.outscale_active
  vm_id        = outscale_vm.bastion[0].vm_id
  public_ip_id = outscale_public_ip.bastion[0].public_ip_id
}
