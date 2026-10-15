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

  # Inline, like the k8s API frontend: an in-place update, never a new LB (that would change the public IP).
  dynamic "acl" {
    for_each = length(var.app_lb_allowed_cidrs) > 0 ? [1] : []
    content {
      name = "app-allow"
      action {
        type = "allow"
      }
      match {
        ip_subnet = local.app_lb_acl_sources
      }
    }
  }
  dynamic "acl" {
    for_each = length(var.app_lb_allowed_cidrs) > 0 ? [1] : []
    content {
      name = "app-deny"
      action {
        type = "deny"
      }
      match {
        ip_subnet = ["0.0.0.0/0"]
      }
    }
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

  # Inline, like the k8s API frontend: an in-place update, never a new LB (that would change the public IP).
  dynamic "acl" {
    for_each = length(var.app_lb_allowed_cidrs) > 0 ? [1] : []
    content {
      name = "app-allow"
      action {
        type = "allow"
      }
      match {
        ip_subnet = local.app_lb_acl_sources
      }
    }
  }
  dynamic "acl" {
    for_each = length(var.app_lb_allowed_cidrs) > 0 ? [1] : []
    content {
      name = "app-deny"
      action {
        type = "deny"
      }
      match {
        ip_subnet = ["0.0.0.0/0"]
      }
    }
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
