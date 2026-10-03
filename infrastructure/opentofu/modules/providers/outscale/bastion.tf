# ==============================================================================
# Outscale — Bastion Host
# Public subnet + EIP for SSH admin access.
# Provides SSH jump to cluster nodes on port 50000 (Talos) and 6443 (K8s).
# ==============================================================================

resource "outscale_security_group" "bastion" {
  description         = "OpenAether bastion - SSH from admin IPs only"
  security_group_name = "${var.cluster_name}-bastion-sg"
  net_id              = outscale_net.this.net_id
}

resource "outscale_security_group_rule" "bastion_ssh" {
  for_each          = toset(var.admin_ip)
  flow              = "Inbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  from_port_range   = 22
  to_port_range     = 22
  ip_protocol       = "tcp"
  ip_range          = each.value
}

# Egress restricted to the Net (every private subnet) + DNS + NTP + apt.
# nftables (in-VM) is the hard enforcement; these SG rules provide defence-in-depth.
resource "outscale_security_group_rule" "bastion_egress_private" {
  flow              = "Outbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  ip_protocol       = "tcp"
  from_port_range   = 0
  to_port_range     = 65535
  ip_range          = local.net_cidr
}

resource "outscale_security_group_rule" "bastion_egress_dns_udp" {
  flow              = "Outbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  ip_protocol       = "udp"
  from_port_range   = 53
  to_port_range     = 53
  ip_range          = "0.0.0.0/0"
}

resource "outscale_security_group_rule" "bastion_egress_dns_tcp" {
  flow              = "Outbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  ip_protocol       = "tcp"
  from_port_range   = 53
  to_port_range     = 53
  ip_range          = "0.0.0.0/0"
}

resource "outscale_security_group_rule" "bastion_egress_http" {
  flow              = "Outbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  ip_protocol       = "tcp"
  from_port_range   = 80
  to_port_range     = 80
  ip_range          = "0.0.0.0/0"
}

resource "outscale_security_group_rule" "bastion_egress_https" {
  flow              = "Outbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  ip_protocol       = "tcp"
  from_port_range   = 443
  to_port_range     = 443
  ip_range          = "0.0.0.0/0"
}

resource "outscale_public_ip" "bastion" {}

resource "outscale_vm" "bastion" {
  image_id           = coalesce(var.bastion_image_id, try(data.outscale_image.ubuntu[0].image_id, null))
  vm_type            = var.bastion_vm_type
  subnet_id          = outscale_subnet.public[0].subnet_id
  security_group_ids = [outscale_security_group.bastion.security_group_id]

  user_data = base64encode(templatefile("${path.module}/../_shared/bastion-cloud-init.yaml.tftpl", {
    # ⚠️ NOT "outscale": that is the default user of Outscale images, hence
    # already created by the shared cloud-init's `users: [default]`. cloud-init
    # then ignores the second definition, the user never joins the
    # bastion-admins group and sshd rejects it through AllowGroups — the same
    # bug as the one hit on OVH with "ubuntu" (2026-07-26). Dedicated name, as on SCW.
    bastion_user      = "bastion"
    ssh_keys          = var.bastion_ssh_keys
    private_cidr      = local.net_cidr
    extra_packages    = []
    extra_write_files = []
    extra_runcmd      = []
    ssh_ca_public_key = var.bastion_ssh_ca_public_key
    ssh_ca_principals = var.bastion_ssh_ca_principals
  }))

  tags {
    key   = "Name"
    value = "${var.cluster_name}-bastion"
  }
}

resource "outscale_public_ip_link" "bastion" {
  vm_id     = outscale_vm.bastion.vm_id
  public_ip = outscale_public_ip.bastion.public_ip
}

# Skipped when bastion_image_id is given: the coalesce above already discards the
# result. Same gate as data.outscale_images.talos in main.tf.
data "outscale_image" "ubuntu" {
  count = var.bastion_image_id == null ? 1 : 0
  filter {
    name   = "image_ids"
    values = ["ami-b29cea33"]
  }
}
