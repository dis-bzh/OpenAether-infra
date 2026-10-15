# ==============================================================================
# Scaleway — Bastion Host
# Public IP + private network attachment for SSH admin access.
# Provides SSH jump to cluster nodes on port 50000 (Talos) and 6443 (K8s).
# ==============================================================================

resource "scaleway_instance_ip" "bastion" {
  zone = var.zone
}

resource "scaleway_instance_security_group" "bastion" {
  name                    = "${var.cluster_name}-bastion-sg"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "drop"

  dynamic "inbound_rule" {
    for_each = var.admin_ip
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 22
      ip_range = inbound_rule.value
    }
  }

  # Egress: private CIDR (cluster nodes), DNS, NTP, apt (80/443)
  # nftables in-VM is the hard enforcement; this SG provides defence-in-depth.
  # bastion_internet_egress.mode = "closed" (the order of the legacy rules is kept, the provider compares a list):
  # TCP 6443/50000 to the subnet in use instead of ANY to the whole /12, no 80/443, DNS/NTP to the pinned servers,
  # and the instance metadata services on 80.
  dynamic "outbound_rule" {
    for_each = local.bastion_egress_closed ? [] : [1]
    content {
      action   = "accept"
      protocol = "ANY"
      ip_range = local.scw_private_cidr
    }
  }
  dynamic "outbound_rule" {
    for_each = local.bastion_egress_closed ? [6443, 50000] : []
    content {
      action   = "accept"
      protocol = "TCP"
      port     = outbound_rule.value
      ip_range = local.scw_subnet_in_use
    }
  }
  dynamic "outbound_rule" {
    for_each = local.bastion_dns_cidrs
    content {
      action   = "accept"
      protocol = "UDP"
      port     = 53
      ip_range = outbound_rule.value
    }
  }
  dynamic "outbound_rule" {
    for_each = local.bastion_dns_cidrs
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 53
      ip_range = outbound_rule.value
    }
  }
  dynamic "outbound_rule" {
    for_each = local.bastion_ntp_cidrs
    content {
      action   = "accept"
      protocol = "UDP"
      port     = 123
      ip_range = outbound_rule.value
    }
  }
  dynamic "outbound_rule" {
    for_each = local.bastion_egress_closed ? ["169.254.42.42/32", "169.254.169.254/32"] : []
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 80
      ip_range = outbound_rule.value
    }
  }
  dynamic "outbound_rule" {
    for_each = local.bastion_egress_closed ? [] : [80, 443]
    content {
      action   = "accept"
      protocol = "TCP"
      port     = outbound_rule.value
      ip_range = "0.0.0.0/0"
    }
  }
}

locals {
  bastion_egress_closed = var.bastion_internet_egress.mode == "closed"
  # The IPv4 servers DNS/NTP are pinned to in the security group (the firewall in the VM also takes IPv6); anywhere when
  # not pinned. Pinned with no IPv4 entry gives no rule, which is what the pin asks for.
  bastion_dns_cidrs = local.bastion_egress_closed && length(var.bastion_internet_egress.dns_servers) > 0 ? [
    for a in var.bastion_internet_egress.dns_servers : strcontains(a, "/") ? a : "${a}/32" if !strcontains(a, ":")
  ] : ["0.0.0.0/0"]
  bastion_ntp_cidrs = local.bastion_egress_closed && length(var.bastion_internet_egress.ntp_servers) > 0 ? [
    for a in var.bastion_internet_egress.ntp_servers : strcontains(a, "/") ? a : "${a}/32" if !strcontains(a, ":")
  ] : ["0.0.0.0/0"]

  # Scaleway uses IPAM for private IPs (dynamic 172.16.0.0/12 range).
  # nftables uses the full RFC1918 private range as the egress allow CIDR.
  # The route fix must run before nftables so the private NIC is stable first.
  scw_private_cidr = "172.16.0.0/12"
  # closed: the subnet the network really uses (an adopted network keeps its own), not the whole /12
  bastion_private_cidr = local.bastion_egress_closed ? local.scw_subnet_in_use : local.scw_private_cidr

  scw_bastion_extra_write_files = [
    {
      path        = "/usr/local/sbin/fix-priv-route.sh"
      permissions = "0755"
      content     = <<-SCRIPT
        #!/bin/bash
        # The VPC public gateway pushes a default route to every instance on the
        # private network (NAT for the nodes). On this bastion (which also has a
        # public IP) that route hijacks return traffic and breaks inbound SSH
        # (asymmetric routing). The private NIC attaches ~30s after boot, so wait
        # for it, then make it ignore DHCP routes — keeping the public default.
        IF=""
        for i in $(seq 1 60); do
          IF=$(ip -o -4 addr show | awk '$4 ~ /^172\.16\./ {print $2; exit}')
          [ -n "$IF" ] && break
          sleep 5
        done
        [ -n "$IF" ] || exit 0
        printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      dhcp4: true\n      dhcp4-overrides:\n        use-routes: false\n' "$IF" > /etc/netplan/99-no-priv-route.yaml
        chmod 600 /etc/netplan/99-no-priv-route.yaml
        netplan apply
        sleep 3
        ip route show default | awk '$3 ~ /^172\.16\./ {print}' | while read -r R; do ip route del $R || true; done
      SCRIPT
    },
    {
      path        = "/etc/systemd/system/fix-priv-route.service"
      permissions = "0644"
      content     = <<-UNIT
        [Unit]
        Description=Keep the public default route on the bastion (drop VPC-pushed private default)
        After=network.target
        Before=nftables.service
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/fix-priv-route.sh
        [Install]
        WantedBy=multi-user.target
      UNIT
    }
  ]

  scw_bastion_extra_runcmd = [
    "systemctl daemon-reload",
    "systemctl enable --now fix-priv-route.service",
  ]
}

resource "scaleway_instance_server" "bastion" {
  name       = "${var.cluster_name}-bastion"
  type       = var.bastion_instance_type
  image      = var.bastion_image_id
  zone       = var.zone
  project_id = var.project_id
  ip_id      = scaleway_instance_ip.bastion.id

  security_group_id = scaleway_instance_security_group.bastion.id

  user_data = {
    "cloud-init" = templatefile("${path.module}/../_shared/bastion-cloud-init.yaml.tftpl", {
      bastion_user      = "bastion"
      ssh_keys          = var.bastion_ssh_keys
      private_cidr      = local.bastion_private_cidr
      extra_packages    = ["netplan.io"]
      extra_write_files = local.scw_bastion_extra_write_files
      extra_runcmd      = local.scw_bastion_extra_runcmd
      ssh_ca_public_key = var.bastion_ssh_ca_public_key
      ssh_ca_principals = var.bastion_ssh_ca_principals
      baseline          = var.bastion_baseline
      admin_ip          = var.admin_ip
      admins            = var.bastion_admins
      egress            = var.bastion_internet_egress
    })
  }

  tags = ["bastion", var.cluster_name]
}
