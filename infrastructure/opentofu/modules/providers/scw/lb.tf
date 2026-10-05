# ==============================================================================
# App LB — public 80/443, the Gateway's NodePorts on the workers
# Whole block gated by deploy_app_lb: without the apps, this LB is billed while
# forwarding to NodePorts where nothing listens.
# ==============================================================================

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

  # HTTPS /readyz at 2 s / 1 s (vendor minimums 1 s). A backend going down is re-checked every
  # health_check_transient_delay (0.5 s default), so DOWN comes in a few seconds, not 3 x 2 s. The
  # certificate is not verified (no TLS on the backend).
  health_check_delay       = var.k8s_lb_health_https ? "2s" : "15s"
  health_check_timeout     = var.k8s_lb_health_https ? "1s" : "10s"
  health_check_max_retries = var.k8s_lb_health_https ? 3 : 5
  health_check_port        = 6443

  dynamic "health_check_tcp" {
    for_each = var.k8s_lb_health_https ? [] : [1]
    content {}
  }
  dynamic "health_check_https" {
    for_each = var.k8s_lb_health_https ? [1] : []
    content {
      uri    = "/readyz"
      method = "GET"
      code   = 200
    }
  }
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
