# Node private IPs (via IPAM)
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = [for ip in scaleway_ipam_ip.control_plane : split("/", ip.address)[0]]
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = [for ip in scaleway_ipam_ip.worker : split("/", ip.address)[0]]
}

output "control_plane_zones" {
  description = "Zone of each control plane, in control_plane_private_ips order"
  value       = scaleway_instance_server.control_plane[*].zone
}

output "worker_zones" {
  description = "Zone of each worker, in worker_private_ips order"
  value       = scaleway_instance_server.worker[*].zone
}

# Load Balancer IPs
output "k8s_lb_ip" {
  description = "Public IP of the Kubernetes API LB (6443), or the private Talos VIP when k8s_lb_mode = \"vip\""
  value       = var.k8s_lb_mode == "managed" ? scaleway_lb_ip.k8s[0].ip_address : split("/", scaleway_ipam_ip.k8s_vip[0].address)[0]
}

output "app_lb_ip" {
  description = "Public IP of the App LB (80/443). Null means no application load balancer on this cluster (deploy_app_lb = false)."
  value       = one(scaleway_lb_ip.app[*].ip_address)
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = scaleway_instance_ip.bastion.address
}

# NAT Gateway
output "nat_gateway_ip" {
  description = "Public IP of the NAT gateway (for LB ACL whitelisting)"
  value       = scaleway_vpc_public_gateway_ip.this.address
}

# Test-only: a test cannot read a child module's resources, so this is how
# scaleway.tftest.hcl checks the generated inbound rules (#79).
output "inbound_rules" {
  description = "Every inbound_rule (protocol, port, port_range, ip_range) of each zone's node group and of the bastion group, for tests"
  value = {
    for name, sg in merge(scaleway_instance_security_group.this, { bastion = scaleway_instance_security_group.bastion }) : name => [
      for r in sg.inbound_rule : { protocol = r.protocol, port = r.port, port_range = r.port_range, ip_range = r.ip_range }
    ]
  }
}

# Test-only, like inbound_rules: the bastion's outbound rules as "protocol port destination", for the egress tests.
output "bastion_egress_rules" {
  description = "Every outbound_rule of the bastion security group as 'protocol port ip_range', for tests"
  value = [
    for r in scaleway_instance_security_group.bastion.outbound_rule :
    "${lower(r.protocol)} ${r.port != null && r.port != 0 ? tostring(r.port) : "-"} ${r.ip_range}"
  ]
}

# Test-only: a test cannot read a child module's resources. Each app LB frontend's ACLs as "action subnets", in index order.
output "app_lb_acls" {
  description = "The ACLs of the app LB http and https frontends as 'action subnet,subnet', in evaluation order, for tests"
  value = {
    for k in ["http", "https"] : k => [
      for a in concat(
        [for x in [try(scaleway_lb_acl.app_allow[k], null)] : x if x != null],
        [for x in [try(scaleway_lb_acl.app_deny[k], null)] : x if x != null],
      ) : "${a.action[0].type} ${try(join(",", a.match[0].ip_subnet), "(known after apply)")}"
    ]
  }
}

# Test-only: the health check the app LB backends carry (a test cannot read a child module's resources); null = no app LB.
output "app_lb_health_checks" {
  description = "Health check of the app LB http and https backends, for tests (null = no app LB)"
  value = {
    for k, b in { http = scaleway_lb_backend.http, https = scaleway_lb_backend.https } : k => one([
      for x in b : {
        delay       = x.health_check_delay
        timeout     = x.health_check_timeout
        max_retries = x.health_check_max_retries
        port        = x.health_check_port
        tcp         = length(x.health_check_tcp) > 0
      }
    ])
  }
}
