output "machine_secrets" {
  description = "Talos machine secrets (for backup and DR)"
  value       = local.machine_secrets.machine_secrets
  sensitive   = true
}

output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = local.machine_secrets.client_configuration
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client config file content (talosconfig)"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig_raw" {
  description = "Raw kubeconfig content for kubectl access"
  value       = var.control_plane_count > 0 ? talos_cluster_kubeconfig.this[0].kubeconfig_raw : ""
  sensitive   = true
}

output "control_plane_config" {
  description = "Control plane machine configuration (for backup)"
  value       = length(local.control_plane_configs) > 0 ? local.control_plane_configs[0] : null
  sensitive   = true
}

output "worker_config" {
  description = "Worker machine configuration (for backup)"
  value       = length(local.worker_configs) > 0 ? local.worker_configs[0] : null
  sensitive   = true
}

# Expose for testing and observability
output "cluster_endpoint" {
  description = "Kubernetes API cluster endpoint (https://<lb_ip>:6443)"
  value       = var.cluster_endpoint
}

output "apiserver_vip" {
  description = "Talos Layer2 VIP configured on the control plane interface, if any"
  value       = var.apiserver_vip
}

output "bootstrap_manifests_enabled" {
  description = "Whether bootstrap manifests (Flux) are injected via inlineManifests"
  value       = var.bootstrap_manifests_enabled
}

output "control_plane_count" {
  description = "Number of control plane nodes configured"
  value       = var.control_plane_count
}

# Per-node generated machine configs — consumed by the provider module to inject
# via USERDATA when config_delivery = "userdata" (Docker/container platforms).
output "control_plane_machine_configs" {
  description = "Generated control plane machine configurations (one per node)"
  value       = local.control_plane_configs
  sensitive   = true
}

output "worker_machine_configs" {
  description = "Generated worker machine configurations (one per node)"
  value       = local.worker_configs
  sensitive   = true
}

# Attaches `data.talos_cluster_health` to the graph. Nothing references it any
# more (see talos_cluster_kubeconfig): it is still evaluated on every apply, so
# the signal is kept, but tflint flags it as orphaned. This output silences that
# and surfaces the state to the operator.
output "cluster_health" {
  description = "State of the Talos health verification: 'skipped' (skip_health_check) or 'verified'."
  value       = var.skip_health_check ? "skipped" : (length(data.talos_cluster_health.this) > 0 ? "verified" : "n/a")
}

# The Talos version a node actually runs is decided by this installer, not by
# the image its VM boots from — which is why an image-only bump looks applied
# and changes nothing.
output "installer_image" {
  description = "Installer image the machine config pins; this is what a node upgrades to"
  value       = local.installer_image
}

output "inline_manifest_names" {
  description = <<-EOT
    Names of the inline manifests going into the control-plane machine config:
    "cilium" always, plus "flux-install"/"flux-bootstrap" only when Flux is asked
    for. Exposed because control_plane_config is unknown until apply, so a test
    cannot assert on it at plan time — and an off-switch whose only tested
    position is "off" is a deletion nobody wrote down.
  EOT
  value       = [for m in local.inline_manifests : m.name]
}

output "apiserver_health_patch" {
  description = <<-EOT
    The extra control-plane config patch that opens /readyz, /livez and /healthz
    anonymously and sets the apiserver shutdown delay ([] when neither is on).
    Exposed because control_plane_config is unknown until apply, so a plan-time test
    cannot read it. Holds no secret.
  EOT
  value       = local.apiserver_health_patch
}

output "appended_documents" {
  description = "The ResolverConfig (and TimeSyncConfig) appended to every node's config, empty when node_nameservers is. Exposed because the rendered configs are unknown at plan."
  value       = local.appended_documents
}
