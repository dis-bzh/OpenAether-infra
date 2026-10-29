# ==============================================================================
# Outscale — Load Balancers
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes
#   app: public 80/443 → the Gateway's NodePorts on the workers
# Outscale LBs return a DNS name (not IP).
# ==============================================================================

locals {
  # ONE health check shape for both load balancers (lab 27 part C, E6): the app LB ran 5 s x 2 and the API LB 10 s x 3, and a
  # dead control plane stayed in rotation 30-35 s against a 10 s target. A dead member leaves after
  # unhealthy_threshold x check_interval + timeout at worst = 2 x 5 + 3 = 13 s (the old values give 3 x 10 + 5 = 35 s, which is
  # what the lab measured), and 8 s at best. COMPUTED, not measured: UNPROVEN until an Outscale drill (stop a control plane,
  # time its exit from the LB, target <= 10 s total; the worst case is above it). Provider ranges: check_interval 5-600,
  # timeout 2-60, thresholds 2-10, so the interval and the threshold are already at their minimum. Cost: a TCP check does not
  # see a member that accepts the connection but is starved, and one that is slow to accept can flap in and out. Only `port`
  # differs between the two load balancers and stays on each resource.
  lb_health_check = {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    check_interval      = 5
    timeout             = 3
  }
}

# --- Kubernetes API LB ---

resource "outscale_load_balancer" "k8s" {
  load_balancer_name = "${var.cluster_name}-k8s-lb"
  load_balancer_type = "internet-facing"

  # The provider default is 10 minutes, and on 2026-08-16 a pure-infra deploy
  # died on exactly that: "timeout while waiting for state to become 'active'
  # (last state: 'provisioning')". The load balancer then held the Net and every
  # subsequent destroy failed on it too — one slow creation cost the whole run
  # and its teardown. Waiting longer is free; failing here is not.
  timeouts {
    create = "30m"
  }

  listeners {
    backend_port           = 6443
    backend_protocol       = "TCP"
    load_balancer_port     = 6443
    load_balancer_protocol = "TCP"
  }

  subnets         = [outscale_subnet.public.subnet_id]
  security_groups = [outscale_security_group.this.security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-k8s-lb"
  }
}

# ⚠️ Outscale's health check defaults are healthy_threshold = 10 and
# check_interval = 30 s: after the slightest hiccup it takes **5 minutes** for
# a backend to come back UP — during which the Kubernetes API answers `EOF`
# (the LB accepts the connection but has no healthy backend). Observed several
# times on the Outscale management. Since `health_check` is a computed attribute
# on outscale_load_balancer, it is set through this dedicated resource.
#
# local.lb_health_check (5 s x 2, 13 s computed) since lab 27 part C (E6); it was 10 s x 3 with a 5 s timeout and kept a dead
# control plane in rotation 30-35 s. On an existing cluster the provider (outscale 1.8.1) marks `health_check` ForceNew, so
# the plan REPLACES THIS ATTRIBUTES RESOURCE ONLY: its destroy calls no API (no policy_names) and its create is one
# UpdateLoadBalancer on the load balancer that already exists. The load balancer, its DNS name, its listener and its backends
# (outscale_load_balancer_vms.k8s) are not part of the change.
resource "outscale_load_balancer_attributes" "k8s" {
  load_balancer_name = outscale_load_balancer.k8s.load_balancer_name

  health_check {
    healthy_threshold   = local.lb_health_check.healthy_threshold
    unhealthy_threshold = local.lb_health_check.unhealthy_threshold
    check_interval      = local.lb_health_check.check_interval
    timeout             = local.lb_health_check.timeout
    port                = 6443
    protocol            = "TCP"
  }
}

resource "outscale_load_balancer_vms" "k8s" {
  load_balancer_name = outscale_load_balancer.k8s.load_balancer_name
  backend_vm_ids     = outscale_vm.control_plane[*].vm_id
}

# --- App LB (HTTP/HTTPS), only when var.deploy_app_lb ---

resource "outscale_load_balancer" "app" {
  count              = var.deploy_app_lb ? 1 : 0
  load_balancer_name = "${var.cluster_name}-app-lb"
  load_balancer_type = "internet-facing"

  # Same 10-minute provider default, same consequence — see the k8s LB above.
  timeouts {
    create = "30m"
  }

  listeners {
    # backend_port = the Gateway's fixed NodePort; load_balancer_port stays public.
    backend_port           = var.app_lb_node_ports.http
    backend_protocol       = "TCP"
    load_balancer_port     = 80
    load_balancer_protocol = "TCP"
  }

  listeners {
    backend_port           = var.app_lb_node_ports.https
    backend_protocol       = "TCP"
    load_balancer_port     = 443
    load_balancer_protocol = "TCP"
  }

  subnets         = [outscale_subnet.public.subnet_id]
  security_groups = [outscale_security_group.this.security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-app-lb"
  }
}

resource "outscale_load_balancer_vms" "app" {
  count              = var.deploy_app_lb ? 1 : 0
  load_balancer_name = outscale_load_balancer.app[0].load_balancer_name
  backend_vm_ids     = outscale_vm.worker[*].vm_id
}

# The app LB health check. Without this resource the LB keeps the provider default (check_interval 30 s, healthy_threshold
# 10, see the k8s LB above): a dead worker stays in rotation for minutes. One check per LB, not per listener: it probes the
# http NodePort, which the same Gateway Service answers on every node that is up, https included. Ranges (provider docs):
# check_interval 5-600, timeout 2-60, thresholds 2-10. 5 s x 2 plus the 3 s timeout takes a dead member out in about 13 s.
# UNVERIFIED on a real partition (docs/resilience.md). Same values as the k8s LB check above: local.lb_health_check.
resource "outscale_load_balancer_attributes" "app" {
  count              = var.deploy_app_lb ? 1 : 0
  load_balancer_name = outscale_load_balancer.app[0].load_balancer_name

  health_check {
    healthy_threshold   = local.lb_health_check.healthy_threshold
    unhealthy_threshold = local.lb_health_check.unhealthy_threshold
    check_interval      = local.lb_health_check.check_interval
    timeout             = local.lb_health_check.timeout
    port                = var.app_lb_node_ports.http
    protocol            = "TCP"
  }
}
