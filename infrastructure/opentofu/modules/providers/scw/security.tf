# ==============================================================================
# Scaleway — node security group
#
# Scaleway filters public traffic only ("How to use security groups", Scaleway
# docs) and the nodes have no public IP, so these rules declare the perimeter
# without enforcing it. Keep them exact for a host firewall to enforce later,
# and never open every port (#79).
# ==============================================================================

# One list for the three layers that filter node traffic (modules/providers/_shared/node-ports).
module "node_ports" {
  source = "../_shared/node-ports"
}

locals {
  # What reaches a node over the private network, from its own subnet.
  # tests/scaleway.tftest.hcl and k8s-lb-mode.tftest.hcl pin the resulting
  # rules: change them together (the list itself is in _shared/node-ports).
  node_inbound_ports = module.node_ports.inbound

  # The App LB's backends and their default TCP health check. Both LBs forward
  # over the private network to IPAM addresses (lb.tf): their source is this subnet.
  gateway_ports = var.deploy_app_lb ? { for k, p in var.app_lb_node_ports : "gateway-${k}" => { protocol = "TCP", ports = tostring(p) } } : {}
  lb_backend_ports = merge(
    var.k8s_lb_mode == "managed" ? { k8s-api = { protocol = "TCP", ports = "6443" } } : {},
    local.gateway_ports,
  )

  # Carrier range 100.64.0.0/10: origin unconfirmed, so it keeps the LB backend
  # ports until a real deploy shows it unused.
  node_inbound_rules = merge(
    { for k, r in merge(local.node_inbound_ports, local.gateway_ports) : k => merge(r, { from = local.scw_subnet_in_use }) },
    { for k, r in local.lb_backend_ports : "carrier-${k}" => merge(r, { from = "100.64.0.0/10" }) },
  )
}

resource "scaleway_instance_security_group" "this" {
  for_each    = toset(var.additional_zones)
  name        = "${var.cluster_name}-sg-${each.key}"
  description = "Security Group for OpenAether Talos Cluster in ${each.key}"

  inbound_default_policy = "drop"

  dynamic "inbound_rule" {
    for_each = local.node_inbound_rules
    content {
      action     = "accept"
      ip_range   = inbound_rule.value.from
      protocol   = inbound_rule.value.protocol
      port       = try(tonumber(inbound_rule.value.ports), null)
      port_range = can(tonumber(inbound_rule.value.ports)) ? null : inbound_rule.value.ports
    }
  }

  # Outbound — allow all for cluster nodes (nftables on bastion handles egress restriction)
  outbound_default_policy = "accept"

  project_id = var.project_id
  zone       = each.key
}
