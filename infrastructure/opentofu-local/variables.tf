variable "cluster_name" {
  type    = string
  default = "openaether-local"
}

variable "environment" {
  type    = string
  default = "dev"
}

# Kept EQUAL to the cloud root's pin (infrastructure/opentofu/cluster/
# variables.tf) — they drifted six patches and a whole Kubernetes minor apart
# before either was anchored (see docs/status.md, "Dependency watch"), and
# nothing compared them until they were. The two are bumped together by hand:
# Renovate proposes each independently, and a PR that moves one without the
# other is a regression, not a bump — check-version-drift.sh does not (yet)
# compare them to each other, only to their own anchors.
variable "talos_version" {
  type = string
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "v1.14.0"
}

variable "kubernetes_version" {
  type = string
  # renovate: datasource=github-releases depName=kubernetes/kubernetes
  default = "v1.36.3"
}

variable "talos_bootstrap" {
  description = "Phase 2: bootstrap the cluster (containers + etcd + kubeconfig). Set to true for a full cluster; false generates config only."
  type        = bool
  default     = false
}

variable "control_plane_count" {
  description = "Number of control plane containers (3 for a real etcd quorum, 1 for a quick smoke test)"
  type        = number
  default     = 3
  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "control_plane_count must be 1 or 3 for a valid local quorum."
  }
}

variable "worker_count" {
  description = "Number of dedicated worker containers. 2 gives schedulable, untainted nodes for HA/scheduling tests; 0 falls back to scheduling on the (untainted) control planes."
  type        = number
  default     = 3
  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 3
    error_message = "worker_count must be between 0 and 3 for local testing."
  }
}

# ⚠️ Base for the Talos API HOST ports: cp_i → base+i, worker_i → base+10+i.
#
# On Windows/WSL2, Hyper-V reserves blocks of 100 ports and Docker Desktop then
# refuses to publish them, with a message that never names the cause:
#   docker: Error response from daemon: ports are not available: exposing port
#   TCP 127.0.0.1:41002 -> 127.0.0.1:0: /forwards/expose returned unexpected
#   status: 500
# The cluster then dies later on "Talos API not ready after 90s".
#
# ⚠️ There is NO safe constant. This comment used to claim that staying under
# 49152 (the dynamic range) made a value stable; 41000 was picked on that basis
# and the reservations landed on 40625-41224 after a reboot. The blocks MOVE and
# they are NOT confined to the dynamic range.
# Hence `task local-up` preflights against the live exclusions
# (scripts/dev/check-host-ports.sh) rather than trusting this default.
variable "talos_api_port_base" {
  description = "Base host port for the Talos API (cp_i → base+i, worker_i → base+10+i). Preflighted against the Hyper-V exclusions by scripts/dev/check-host-ports.sh."
  type        = number
  default     = 45000
  validation {
    condition     = var.talos_api_port_base >= 1024 && var.talos_api_port_base <= 65400
    error_message = "talos_api_port_base must be between 1024 and 65400."
  }
}

# The HOST side of the Kubernetes API mapping. modules/providers/local publishes
# `127.0.0.1:<this>:6443` — 6443 inside the container is what Kubernetes serves on
# and never moves; only the host side is ours to choose.
#
# It was hardcoded to 6443 here while the module had accepted a variable all
# along, so a Hyper-V block landing on 6404-6503 (measured 2026-08-21) left the
# credential-free rung unrunnable with no way around it. The Talos ports were
# already movable; this was the one that was not.
variable "k8s_api_port" {
  description = "Host port mapped to control plane 0's Kubernetes API. Preflighted against the Hyper-V exclusions by scripts/dev/check-host-ports.sh."
  type        = number
  default     = 6443
  validation {
    condition     = var.k8s_api_port >= 1024 && var.k8s_api_port <= 65535
    error_message = "k8s_api_port must be between 1024 and 65535."
  }
}

# Accept cilium manifest override (for local simplified variant)
variable "cilium_manifest" {
  description = "Cilium manifest content. Set via TF_VAR_cilium_manifest from cilium-local.yaml."
  type        = string
  default     = null
}
