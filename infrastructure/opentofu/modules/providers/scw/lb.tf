# ==============================================================================
# App LB — public 80/443, the Gateway's NodePorts on the workers
# Whole block gated by deploy_app_lb: without the apps, this LB is billed while
# forwarding to NodePorts where nothing listens.
# ==============================================================================

locals {
  # Caller list + the cluster's own egress (pods reach the Gateway through this LB's
  # public address) + the VPC ranges, as the k8s API ACL below. Empty = no ACL.
  app_lb_acl_sources = length(var.app_lb_allowed_cidrs) == 0 ? [] : concat(
    distinct(concat(var.app_lb_allowed_cidrs, ["172.16.0.0/12", "10.0.0.0/8"])),
    ["${scaleway_vpc_public_gateway_ip.this.address}/32"],
  )
}

resource "scaleway_lb_ip" "app" {
  count      = var.deploy_app_lb ? 1 : 0
  zone       = var.zone
  project_id = var.project_id
}

resource "scaleway_lb" "app" {
  count      = var.deploy_app_lb ? 1 : 0
  name       = "${var.cluster_name}-app-lb"
  ip_ids     = [scaleway_lb_ip.app[0].id]
  zone       = var.zone
  type       = "LB-S"
  project_id = var.project_id

  # Same patience the other two providers needed. Scaleway has not been seen to
  # exceed the provider default, but "not seen" is not "cannot": Outscale died at
  # 10m on 2026-08-16 and OVH on 2026-08-18, both on a load balancer that was
  # still provisioning, and both left a TAINTED resource that the next run
  # destroys and rebuilds. Waiting longer costs nothing; the loop costs the run.
  timeouts {
    create = "30m"
  }

}

resource "scaleway_lb_private_network" "app" {
  count              = var.deploy_app_lb ? 1 : 0
  lb_id              = scaleway_lb.app[0].id
  private_network_id = scaleway_vpc_private_network.this.id
}

resource "scaleway_lb_backend" "http" {
  count = var.deploy_app_lb ? 1 : 0
  lb_id = scaleway_lb.app[0].id
  name  = "http-backend"
  # Worker-side port = the Gateway's fixed NodePort (public inbound_port stays 80).
  forward_port           = var.app_lb_node_ports.http
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.worker : split("/", ip.address)[0]]
}

resource "scaleway_lb_frontend" "http" {
  count        = var.deploy_app_lb ? 1 : 0
  lb_id        = scaleway_lb.app[0].id
  backend_id   = scaleway_lb_backend.http[0].id
  name         = "http-frontend"
  inbound_port = 80

  # The ACLs are the standalone scaleway_lb_acl resources below.
  lifecycle {
    ignore_changes = [acl]
  }
}

resource "scaleway_lb_backend" "https" {
  count                  = var.deploy_app_lb ? 1 : 0
  lb_id                  = scaleway_lb.app[0].id
  name                   = "https-backend"
  forward_port           = var.app_lb_node_ports.https
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.worker : split("/", ip.address)[0]]
}

resource "scaleway_lb_frontend" "https" {
  count        = var.deploy_app_lb ? 1 : 0
  lb_id        = scaleway_lb.app[0].id
  backend_id   = scaleway_lb_backend.https[0].id
  name         = "https-frontend"
  inbound_port = 443

  # The ACLs are the standalone scaleway_lb_acl resources below.
  lifecycle {
    ignore_changes = [acl]
  }
}

# ==============================================================================
# LB Kubernetes API (permanent) — Port 6443 only
# Only created when k8s_lb_mode = "managed" (default). In "vip" mode the API
# is fronted by a Talos Layer2 VIP instead (see network.tf's k8s_vip IPAM
# reservation) — no LB, no public IP.
# No 50000/TCP — Talos API is accessed via bastion tunnel.
# ACL-restricted to admin_ip + private network ranges.
# ==============================================================================

resource "scaleway_lb_ip" "k8s" {
  count      = var.k8s_lb_mode == "managed" ? 1 : 0
  zone       = var.zone
  project_id = var.project_id
}

resource "scaleway_lb" "k8s" {
  count      = var.k8s_lb_mode == "managed" ? 1 : 0
  name       = "${var.cluster_name}-k8s-lb"
  ip_ids     = [scaleway_lb_ip.k8s[0].id]
  zone       = var.zone
  type       = "LB-S"
  project_id = var.project_id

  # Same patience the other two providers needed. Scaleway has not been seen to
  # exceed the provider default, but "not seen" is not "cannot": Outscale died at
  # 10m on 2026-08-16 and OVH on 2026-08-18, both on a load balancer that was
  # still provisioning, and both left a TAINTED resource that the next run
  # destroys and rebuilds. Waiting longer costs nothing; the loop costs the run.
  timeouts {
    create = "30m"
  }

}

resource "scaleway_lb_private_network" "k8s" {
  count              = var.k8s_lb_mode == "managed" ? 1 : 0
  lb_id              = scaleway_lb.k8s[0].id
  private_network_id = scaleway_vpc_private_network.this.id
}

# --- K8s API backend (6443) ---

resource "scaleway_lb_backend" "k8s_api" {
  count                  = var.k8s_lb_mode == "managed" ? 1 : 0
  lb_id                  = scaleway_lb.k8s[0].id
  name                   = "k8s-api-backend"
  forward_port           = 6443
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.control_plane : split("/", ip.address)[0]]

  health_check_delay       = "15s"
  health_check_timeout     = "10s"
  health_check_max_retries = 5
  health_check_port        = 6443
  health_check_tcp {}
}

resource "scaleway_lb_frontend" "k8s_api" {
  count        = var.k8s_lb_mode == "managed" ? 1 : 0
  lb_id        = scaleway_lb.k8s[0].id
  backend_id   = scaleway_lb_backend.k8s_api[0].id
  name         = "k8s-api-frontend"
  inbound_port = 6443

  acl {
    name = "k8s-api-whitelist"
    action {
      type = "allow"
    }
    match {
      ip_subnet = concat(var.admin_ip, ["172.16.0.0/12", "10.0.0.0/8"])
    }
  }
  acl {
    name = "k8s-api-deny"
    action {
      type = "deny"
    }
    match {
      ip_subnet = ["0.0.0.0/0"]
    }
  }
}

# --- ACLs K8s API LB (admin_ip only + private subnets) ---
# The ACLs are inline in the frontend to avoid the conflict between standalone
# scaleway_lb_acl resources and the frontend's state.

# --- ACLs of the app LB frontends ---
# Standalone resources, unlike the k8s API frontend above. The allow list holds the NAT gateway's public address, which is
# unknown until apply on a fresh cluster; the provider cannot plan that inside a frontend's inline `acl` block ("Provider
# produced inconsistent final plan: .acl[0].match[0].ip_subnet was null, but now ..."; seen on a real Scaleway apply). The
# frontends ignore their `acl` attribute so that the two ways of declaring ACLs do not fight over the state.
resource "scaleway_lb_acl" "app_allow" {
  for_each    = var.deploy_app_lb && length(var.app_lb_allowed_cidrs) > 0 ? { http = scaleway_lb_frontend.http[0].id, https = scaleway_lb_frontend.https[0].id } : {}
  frontend_id = each.value
  name        = "app-allow"
  index       = 1
  action {
    type = "allow"
  }
  match {
    ip_subnet = local.app_lb_acl_sources
  }
}

# The deny comes after the allow (the LB evaluates by index).
resource "scaleway_lb_acl" "app_deny" {
  for_each    = var.deploy_app_lb && length(var.app_lb_allowed_cidrs) > 0 ? { http = scaleway_lb_frontend.http[0].id, https = scaleway_lb_frontend.https[0].id } : {}
  frontend_id = each.value
  name        = "app-deny"
  index       = 2
  action {
    type = "deny"
  }
  match {
    ip_subnet = ["0.0.0.0/0"]
  }
  depends_on = [scaleway_lb_acl.app_allow]
}
