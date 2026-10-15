# ==============================================================================
# OVH / OpenStack — Bastion Host
# Private network only + floating IP for SSH admin access.
# Provides SSH jump to cluster nodes on port 50000 (Talos) and 6443 (K8s).
# ==============================================================================

data "openstack_images_image_v2" "bastion" {
  name        = var.bastion_image_id
  most_recent = true
  visibility  = "public"
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name                 = "${var.cluster_name}-bastion-sg"
  description          = "OpenAether bastion — SSH from admin IPs only"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  for_each = toset(var.admin_ip)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

locals {
  bastion_egress_closed = var.bastion_internet_egress.mode == "closed"
  # The IPv4 servers DNS/NTP are pinned to (the firewall in the VM also takes IPv6); anywhere when not pinned.
  bastion_dns_cidrs = local.bastion_egress_closed && length(var.bastion_internet_egress.dns_servers) > 0 ? [
    for a in var.bastion_internet_egress.dns_servers : strcontains(a, "/") ? a : "${a}/32" if !strcontains(a, ":")
  ] : []
  bastion_ntp_cidrs = local.bastion_egress_closed ? [
    for a in var.bastion_internet_egress.ntp_servers : strcontains(a, "/") ? a : "${a}/32" if !strcontains(a, ":")
  ] : []
  # Not pinned: the two DNS rules below, without a destination, exactly as before.
  bastion_dns_pinned = local.bastion_egress_closed && length(var.bastion_internet_egress.dns_servers) > 0
}

# Egress restricted to: established/related, DNS, NTP, apt, private subnet.
# nftables (in-VM) is the hard enforcement; this SG rule provides defence-in-depth
# by allowing egress to the private subnet and well-known services only.
# bastion_internet_egress.mode = "closed": TCP 6443/50000 to the subnet instead of every protocol, no 80/443 (only the
# instance metadata service), DNS/NTP to the pinned servers. The `moved` blocks keep the legacy rules at their state
# address, so a cluster that never sets the variable plans no change.
resource "openstack_networking_secgroup_rule_v2" "bastion_egress_private" {
  count             = local.bastion_egress_closed ? 0 : 1
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = openstack_networking_subnet_v2.private.cidr
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_cluster" {
  for_each          = local.bastion_egress_closed ? toset(["6443", "50000"]) : toset([])
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = openstack_networking_subnet_v2.private.cidr
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns" {
  count             = local.bastion_dns_pinned ? 0 : 1
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 53
  port_range_max    = 53
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns_tcp" {
  count             = local.bastion_dns_pinned ? 0 : 1
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 53
  port_range_max    = 53
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns_pinned" {
  for_each          = { for pair in setproduct(["udp", "tcp"], local.bastion_dns_cidrs) : "${pair[0]} ${pair[1]}" => pair }
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = each.value[0]
  port_range_min    = 53
  port_range_max    = 53
  remote_ip_prefix  = each.value[1]
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

# No NTP rule existed on this provider; with the pin, the listed servers get one (the firewall in the VM allows them too).
resource "openstack_networking_secgroup_rule_v2" "bastion_egress_ntp_pinned" {
  for_each          = toset(local.bastion_ntp_cidrs)
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 123
  port_range_max    = 123
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

# Neutron applies the egress rules to the metadata address too: without this, a closed bastion cannot reach it.
resource "openstack_networking_secgroup_rule_v2" "bastion_egress_metadata" {
  count             = local.bastion_egress_closed ? 1 : 0
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "169.254.169.254/32"
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_http" {
  count             = local.bastion_egress_closed ? 0 : 1
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_https" {
  count             = local.bastion_egress_closed ? 0 : 1
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

moved {
  from = openstack_networking_secgroup_rule_v2.bastion_egress_private
  to   = openstack_networking_secgroup_rule_v2.bastion_egress_private[0]
}
moved {
  from = openstack_networking_secgroup_rule_v2.bastion_egress_dns
  to   = openstack_networking_secgroup_rule_v2.bastion_egress_dns[0]
}
moved {
  from = openstack_networking_secgroup_rule_v2.bastion_egress_dns_tcp
  to   = openstack_networking_secgroup_rule_v2.bastion_egress_dns_tcp[0]
}
moved {
  from = openstack_networking_secgroup_rule_v2.bastion_egress_http
  to   = openstack_networking_secgroup_rule_v2.bastion_egress_http[0]
}
moved {
  from = openstack_networking_secgroup_rule_v2.bastion_egress_https
  to   = openstack_networking_secgroup_rule_v2.bastion_egress_https[0]
}

resource "openstack_networking_port_v2" "bastion" {
  name               = "${var.cluster_name}-bastion-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]

  # ⚠️ DO NOT remove this block. `network_id` alone creates NO dependency on
  # the subnet: OpenTofu may create the port before it, and Neutron then leaves
  # it without an IPv4 address. The apply fails further along, on two errors
  # that do not name the cause:
  #   « Port <id> requires a FixedIP in order to be used »     (booting the bastion)
  #   « Cannot add floating IP to port <id> that has no fixed
  #     IPv4 addresses »                                       (associating the FIP)
  # The block forces the ordering AND guarantees allocation. It is a race, so
  # an INTERMITTENT failure: several OVH deployments went through without it
  # (observed 2026-07-27). The control-plane ports and the VIP already declare it.
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_compute_instance_v2" "bastion" {
  name        = "${var.cluster_name}-bastion"
  image_id    = data.openstack_images_image_v2.bastion.id
  flavor_name = var.bastion_flavor_name

  network {
    port = openstack_networking_port_v2.bastion.id
  }

  user_data = templatefile("${path.module}/../_shared/bastion-cloud-init.yaml.tftpl", {
    # ⚠️ NOT "ubuntu": that is the OVH image's default user, hence already
    # created by `users: [default]`. cloud-init then ignores the second
    # definition and the user is NEVER added to the bastion-admins group →
    # sshd rejects it through AllowGroups (observed for real:
    # "Permission denied (publickey)" with the right key). A dedicated name,
    # as on Scaleway, avoids the collision.
    bastion_user      = "bastion"
    ssh_keys          = var.bastion_ssh_keys
    private_cidr      = openstack_networking_subnet_v2.private.cidr
    extra_packages    = []
    extra_write_files = []
    extra_runcmd      = []
    ssh_ca_public_key = var.bastion_ssh_ca_public_key
    ssh_ca_principals = var.bastion_ssh_ca_principals
    baseline          = var.bastion_baseline
    admin_ip          = var.admin_ip
    admins            = var.bastion_admins
    egress            = var.bastion_internet_egress
  })

  tags = ["bastion", var.cluster_name]
}

resource "openstack_networking_floatingip_v2" "bastion" {
  pool = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "bastion" {
  floating_ip = openstack_networking_floatingip_v2.bastion.address
  port_id     = openstack_networking_port_v2.bastion.id

  # ⚠️ depends_on on the router interface is MANDATORY. Neutron REFUSES to
  # associate a floating IP until the port's subnet has a route to the external
  # network:
  #   ExternalGatewayForFloatingIPNotFound: External network <id> is not
  #   reachable from subnet <id>
  # No reference links these two resources, so OpenTofu creates them in
  # PARALLEL → an INTERMITTENT failure depending on who wins the race. Observed
  # on the bastion on 2026-07-28; both LBs had been getting through by luck, a
  # load balancer being slower to create.
  depends_on = [openstack_networking_router_interface_v2.private]
}
