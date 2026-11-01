# Outscale API load balancer health check (lab 27 part C, E6): a stopped control plane stayed in rotation 30-35 s (19 failed
# /readyz in 64 s) against a 10 s target, because the API LB checked every 10 s, timeout 5 s, 3 failures. It now runs the shape
# the app LB already ran: every 5 s, timeout 3 s, 2 failures (13 s computed at worst), from ONE local shared by both.
# Mocked rung: this proves what is PLANNED, not what the Outscale API accepts nor how long a dead member stays in rotation
# (UNPROVEN until an Outscale drill: stop a control plane, time its exit from the LB, target <= 10 s total).
#
# What this file cannot assert: "in place" versus "replace". A mock provider runs no plan modifier, so ForceNew is invisible
# here. Provider outscale 1.8.1 marks `health_check` ForceNew on outscale_load_balancer_attributes: the plan of an existing
# cluster REPLACES THE ATTRIBUTES RESOURCE (destroy calls no API without policy_names, create is one UpdateLoadBalancer) and
# does not touch the load balancer. That was read in the provider source and shown by a real-provider plan against a crafted
# state (docs/resilience.md). What is pinned below is that the load balancer's own arguments, the attributes resource's
# address and its target name are unchanged, so nothing else moves.

mock_provider "outscale" {}

variables {
  cluster_name        = "lb-hc-test"
  admin_ip            = ["10.0.0.1/32"]
  control_plane_count = 3
  worker_count        = 3
  image_id            = "ami-11111111"
}

run "api_lb_gets_5_3_2" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_load_balancer_attributes.k8s] }

  assert {
    condition = (
      length(outscale_load_balancer_attributes.k8s.health_check) == 1
      && outscale_load_balancer_attributes.k8s.health_check[0].check_interval == 5
      && outscale_load_balancer_attributes.k8s.health_check[0].timeout == 3
      && outscale_load_balancer_attributes.k8s.health_check[0].unhealthy_threshold == 2
      && outscale_load_balancer_attributes.k8s.health_check[0].healthy_threshold == 2
    )
    error_message = "The API load balancer must check every 5 s, timeout 3 s, 2 failures to go down and 2 successes to come back (it was 10 s, 5 s, 3)."
  }

  assert {
    condition     = outscale_load_balancer_attributes.k8s.health_check[0].port == 6443 && outscale_load_balancer_attributes.k8s.health_check[0].protocol == "TCP"
    error_message = "The API load balancer check must stay a TCP probe of the apiserver port 6443."
  }

  # Worst case a dead member needs unhealthy_threshold x check_interval + timeout: 2 x 5 + 3 = 13 s (10 x 3 + 5 = 35 s before).
  assert {
    condition     = outscale_load_balancer_attributes.k8s.health_check[0].unhealthy_threshold * outscale_load_balancer_attributes.k8s.health_check[0].check_interval + outscale_load_balancer_attributes.k8s.health_check[0].timeout == 13
    error_message = "The computed worst case for a dead control plane to leave the API load balancer must be 13 s."
  }

  # The provider ranges (check_interval 5-600, timeout 2-60, thresholds 2-10) are enforced by the real provider only.
  assert {
    condition = (
      outscale_load_balancer_attributes.k8s.health_check[0].check_interval >= 5
      && outscale_load_balancer_attributes.k8s.health_check[0].timeout >= 2
      && outscale_load_balancer_attributes.k8s.health_check[0].timeout < outscale_load_balancer_attributes.k8s.health_check[0].check_interval
      && outscale_load_balancer_attributes.k8s.health_check[0].unhealthy_threshold >= 2
      && outscale_load_balancer_attributes.k8s.health_check[0].healthy_threshold >= 2
    )
    error_message = "The check must stay inside the provider ranges (interval >= 5, timeout >= 2 and below the interval, thresholds >= 2)."
  }
}

run "app_lb_has_the_same_shape_from_the_same_local" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_load_balancer_attributes.k8s, outscale_load_balancer_attributes.app] }

  variables {
    deploy_app_lb = true
  }

  assert {
    condition = (
      outscale_load_balancer_attributes.app[0].health_check[0].check_interval == outscale_load_balancer_attributes.k8s.health_check[0].check_interval
      && outscale_load_balancer_attributes.app[0].health_check[0].timeout == outscale_load_balancer_attributes.k8s.health_check[0].timeout
      && outscale_load_balancer_attributes.app[0].health_check[0].unhealthy_threshold == outscale_load_balancer_attributes.k8s.health_check[0].unhealthy_threshold
      && outscale_load_balancer_attributes.app[0].health_check[0].healthy_threshold == outscale_load_balancer_attributes.k8s.health_check[0].healthy_threshold
    )
    error_message = "The app and API load balancers must carry the same interval, timeout and thresholds (one local, local.lb_health_check)."
  }

  assert {
    condition     = outscale_load_balancer_attributes.app[0].health_check[0].port == 30080 && outscale_load_balancer_attributes.k8s.health_check[0].port == 6443
    error_message = "Only the probed port differs: the app LB probes the http NodePort 30080, the API LB 6443."
  }
}

run "nothing_else_of_the_api_lb_moves" {
  command = plan
  module { source = "../modules/providers/outscale" }
  providers = { outscale = outscale }
  plan_options { target = [outscale_load_balancer.k8s, outscale_load_balancer_attributes.k8s] }

  assert {
    condition = (
      outscale_load_balancer.k8s.load_balancer_name == "lb-hc-test-k8s-lb"
      && outscale_load_balancer_attributes.k8s.load_balancer_name == "lb-hc-test-k8s-lb"
      && length(outscale_load_balancer.k8s.listeners) == 1
      && [for l in outscale_load_balancer.k8s.listeners : l.load_balancer_port] == [6443]
      && [for l in outscale_load_balancer.k8s.listeners : l.backend_port] == [6443]
      && [for l in outscale_load_balancer.k8s.listeners : l.backend_protocol] == ["TCP"]
      && outscale_load_balancer.k8s.load_balancer_type == "internet-facing"
    )
    error_message = "The API load balancer itself (name, type, one TCP listener 6443 to 6443) must be exactly what it was: only the attributes resource carries the new check."
  }
}
