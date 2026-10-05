# ==============================================================================
# OVH / OpenStack — Load Balancers (Octavia)
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes (allowed_cidrs = admin_ip)
#   app: public 80/443 → the Gateway's NodePorts on the workers (open)
# ==============================================================================

# --- Kubernetes API LB ---
# Only created when k8s_lb_mode = "managed" (default). In "vip" mode the API
# is fronted by a Talos Layer2 VIP instead (k8s_vip port below) — no LB, no
# floating IP.

resource "openstack_lb_loadbalancer_v2" "k8s" {
  count         = var.k8s_lb_mode == "managed" ? 1 : 0
  name          = "${var.cluster_name}-k8s-lb"
  vip_subnet_id = openstack_networking_subnet_v2.private.id

  # Octavia is SLOW and its slowness is not bounded by the provider's patience:
  # the default create timeout is 10 min, and on 2026-08-18 this load balancer
  # was still PENDING_CREATE (operating_status ONLINE) fifteen minutes in, having
  # already killed the apply at 9m51s — "context deadline exceeded". The resource
  # is then TAINTED, so simply re-running destroys the one that was nearly ready
  # and starts the wait again. That loop is the whole cost.
  #
  # Outscale hit the identical shape on 2026-08-16 and was given create = "30m";
  # the lesson was never carried to its sibling modules. This is that carry.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

}

resource "openstack_lb_listener_v2" "k8s_api" {
  count           = var.k8s_lb_mode == "managed" ? 1 : 0
  name            = "k8s-api"
  protocol        = "TCP"
  protocol_port   = 6443
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s[0].id
  # sort(): Octavia returns this list sorted and the provider treats it as
  # ordered, so an unsorted config diffs against its own state on every plan.
  allowed_cidrs = sort(concat(var.admin_ip, ["10.0.0.0/24"]))
}

resource "openstack_lb_pool_v2" "k8s_api" {
  count       = var.k8s_lb_mode == "managed" ? 1 : 0
  name        = "k8s-api"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k8s_api[0].id
}

resource "openstack_lb_monitor_v2" "k8s_api" {
  count   = var.k8s_lb_mode == "managed" ? 1 : 0
  pool_id = openstack_lb_pool_v2.k8s_api[0].id
  type    = var.k8s_lb_health_https ? "HTTPS" : "TCP"
  delay   = var.k8s_lb_health_https ? 2 : 15
  timeout = var.k8s_lb_health_https ? 1 : 10
  # Octavia: max_retries = successes before ONLINE (75 s with 5 x 15 s), max_retries_down =
  # failures before ERROR. Both set: the API default of 3 for the second is what existing monitors hold.
  max_retries      = var.k8s_lb_health_https ? 2 : 5
  max_retries_down = 3
  url_path         = var.k8s_lb_health_https ? "/readyz" : null
  expected_codes   = var.k8s_lb_health_https ? "200" : null
}

resource "openstack_lb_member_v2" "k8s_api" {
  count         = var.k8s_lb_mode == "managed" ? var.control_plane_count : 0
  pool_id       = openstack_lb_pool_v2.k8s_api[0].id
  address       = try(openstack_networking_port_v2.control_plane[count.index].all_fixed_ips[0], "0.0.0.0")
  protocol_port = 6443
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_floatingip_v2" "k8s" {
  count = var.k8s_lb_mode == "managed" ? 1 : 0
  pool  = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "k8s" {
  count       = var.k8s_lb_mode == "managed" ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.k8s[0].address
  port_id     = openstack_lb_loadbalancer_v2.k8s[0].vip_port_id

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

# --- apiserver VIP (k8s_lb_mode = "vip") ---
# Detached port on the private subnet: not bound to any instance, it only
# reserves the address. Talos claims it via gratuitous ARP on whichever
# control plane currently holds it (see the allowed_address_pairs on each CP
# port in main.tf).

resource "openstack_networking_port_v2" "k8s_vip" {
  count              = var.k8s_lb_mode == "vip" ? 1 : 0
  name               = "${var.cluster_name}-k8s-vip-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.this.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

# --- App LB (HTTP/HTTPS) ---
# Only created when deploy_app_lb = true. Off by default: the members point at
# the Gateway's NodePorts, so without applications this LB and its floating IP
# are billed to forward traffic to ports where nothing listens.

resource "openstack_lb_loadbalancer_v2" "app" {
  count         = var.deploy_app_lb ? 1 : 0
  name          = "${var.cluster_name}-app-lb"
  vip_subnet_id = openstack_networking_subnet_v2.private.id

  # Octavia is SLOW and its slowness is not bounded by the provider's patience:
  # the default create timeout is 10 min, and on 2026-08-18 this load balancer
  # was still PENDING_CREATE (operating_status ONLINE) fifteen minutes in, having
  # already killed the apply at 9m51s — "context deadline exceeded". The resource
  # is then TAINTED, so simply re-running destroys the one that was nearly ready
  # and starts the wait again. That loop is the whole cost.
  #
  # Outscale hit the identical shape on 2026-08-16 and was given create = "30m";
  # the lesson was never carried to its sibling modules. This is that carry.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

}

resource "openstack_lb_listener_v2" "http" {
  count           = var.deploy_app_lb ? 1 : 0
  name            = "http"
  protocol        = "TCP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.app[0].id
}

resource "openstack_lb_pool_v2" "http" {
  count       = var.deploy_app_lb ? 1 : 0
  name        = "http"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.http[0].id
}

resource "openstack_lb_member_v2" "http" {
  count   = var.deploy_app_lb ? var.worker_count : 0
  pool_id = openstack_lb_pool_v2.http[0].id
  address = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  # The Gateway's fixed NodePort; the public listener stays on 80.
  protocol_port = var.app_lb_node_ports.http
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_lb_listener_v2" "https" {
  count           = var.deploy_app_lb ? 1 : 0
  name            = "https"
  protocol        = "TCP"
  protocol_port   = 443
  loadbalancer_id = openstack_lb_loadbalancer_v2.app[0].id
}

resource "openstack_lb_pool_v2" "https" {
  count       = var.deploy_app_lb ? 1 : 0
  name        = "https"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.https[0].id
}

resource "openstack_lb_member_v2" "https" {
  count         = var.deploy_app_lb ? var.worker_count : 0
  pool_id       = openstack_lb_pool_v2.https[0].id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = var.app_lb_node_ports.https
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_floatingip_v2" "app" {
  count = var.deploy_app_lb ? 1 : 0
  pool  = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "app" {
  count       = var.deploy_app_lb ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.app[0].address
  port_id     = openstack_lb_loadbalancer_v2.app[0].vip_port_id

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
