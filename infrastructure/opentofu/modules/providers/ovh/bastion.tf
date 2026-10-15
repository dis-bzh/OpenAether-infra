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

# Egress restricted to: established/related, DNS, NTP, apt, private subnet.
# nftables (in-VM) is the hard enforcement; this SG rule provides defence-in-depth
# by allowing egress to the private subnet and well-known services only.
resource "openstack_networking_secgroup_rule_v2" "bastion_egress_private" {
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 53
  port_range_max    = 53
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns_tcp" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 53
  port_range_max    = 53
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_http" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_https" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  security_group_id = openstack_networking_secgroup_v2.bastion.id
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
    private_cidr      = "10.0.0.0/24"
    extra_packages    = []
    extra_write_files = []
    extra_runcmd      = []
    ssh_ca_public_key = var.bastion_ssh_ca_public_key
    ssh_ca_principals = var.bastion_ssh_ca_principals
    baseline          = var.bastion_baseline
    admin_ip          = var.admin_ip
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
