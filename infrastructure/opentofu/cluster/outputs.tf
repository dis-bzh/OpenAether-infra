# ==============================================================================
# Operational Outputs
# ==============================================================================

# --- Cluster Identity ---

output "active_provider" {
  description = "Cloud provider used for this cluster"
  value       = local.active_provider
}

output "cluster_role" {
  description = "Role of this cluster (management or workload)"
  value       = var.cluster_role
}

output "resolved_image_ref" {
  description = "Image identifier actually used by the active provider (name/ID/file_id), after applying the by-name/convention fallback when it was left unset in the tfvars."
  value = lookup({
    scaleway = local.scw_image_name
    ovh      = coalesce(local.ovh_dist.image_id, local.ovh_image_name)
    outscale = coalesce(local.osc_dist.image_id, local.osc_image_name)
    proxmox  = local.pmx_talos_image_file_id
  }, local.active_provider, "n/a")
}

# --- Cluster Access ---

output "k8s_lb_ip" {
  description = "Public IP (or DNS name) of the Kubernetes API LB (6443)"
  value       = local.k8s_lb_ip
}

output "app_lb_ip" {
  description = "Public IP (or DNS name) of the App LB (80/443)"
  value = coalesce(
    one(module.scw[*].app_lb_ip),
    one(module.ovh[*].app_lb_ip),
    one(module.outscale[*].app_lb_ip),
    "N/A"
  )
}

output "worker_ingress_targets" {
  description = "Worker IPs for manual ingress (providers without a managed app LB, e.g. Proxmox)"
  value       = one(module.proxmox[*].worker_ingress_targets)
}

output "kubeconfig" {
  description = "Kubeconfig for kubectl access"
  value       = module.talos.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig for talosctl access"
  value       = module.talos.talosconfig
  sensitive   = true
}

# --- Node IPs ---

output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes (Talos API reachable on 50000/TCP via bastion)"
  value       = local.control_plane_ips
}

output "control_plane_zones" {
  description = "Failure domain of each control plane, in control_plane_private_ips order, as placed and not measured (read by infra-verify.sh)"
  value       = local.control_plane_zones
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = local.worker_ips
}

# --- Bastion ---

output "bastion_ip" {
  description = "Public IP of the bastion host"
  value       = local.bastion_ip
}

output "bastion_user" {
  description = "SSH user of the bastion: \"bastion\" on Scaleway, OVH and Outscale; on Proxmox host_ssh_user (default root), or \"bastion\" with enable_bastion"
  value       = local.bastion_user
}

# --- Secrets (for backup/DR) ---

output "machine_secrets" {
  description = "Talos machine secrets (sensitive, for DR)"
  value       = module.talos.machine_secrets
  sensitive   = true
}

# --- Backup / DR targets (consumed by scripts/ops/backup-state.sh) ---

output "backup_targets" {
  description = "Derived buckets + endpoints for the state and artifact backups (non-sensitive)."
  value = {
    provider                = local.active_provider
    state_bucket_primary    = local.state_bucket_primary
    state_bucket_replica    = local.state_bucket_replica
    state_key               = local.state_key
    artifact_bucket_primary = local.artifact_bucket_primary
    artifact_bucket_replica = local.artifact_bucket_replica
    primary_endpoint        = var.s3_primary_endpoint
    primary_region          = var.s3_primary_region
    replica_endpoint        = var.s3_replica_endpoint
    replica_region          = var.s3_replica_region
  }
}

# --- Operational Instructions ---

output "talos_access_commands" {
  description = "SSH tunnel commands to reach each Talos node's API (50000) via the bastion. CPs map to localhost 50000+i, workers to 50100+i — distinct ports so all tunnels coexist."
  value = merge(
    { for idx, ip in local.control_plane_ips : "cp-${idx}" => "ssh -q -i ~/.ssh/key -L ${50000 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &" },
    { for idx, ip in local.worker_ips : "worker-${idx}" => "ssh -q -i ~/.ssh/key -L ${50100 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &" },
  )
}

output "instructions" {
  description = "Operational instructions for multi-env two-phase bootstrap"
  value       = <<-EOT
    # ─── Cluster: ${var.cluster_name}-${var.environment} (${var.cluster_role}) on ${local.active_provider} ──────
    #
    # Phase 1: Infra Creation
    #   tofu apply -var-file=envs/<cluster>.tfvars
    #
    # Phase 2: Talos Bootstrap (Requires SSH tunnels via Bastion — one per node)
    #   1. Open tunnels (control planes -> localhost 50000+i):
    %{for idx, ip in local.control_plane_ips}#      ssh -q -i ~/.ssh/key -L ${50000 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &
    %{endfor}#      ... and workers -> localhost 50100+i:
    %{for idx, ip in local.worker_ips}#      ssh -q -i ~/.ssh/key -L ${50100 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &
    %{endfor}#
    #   2. Bootstrap:
    #      tofu apply -var-file=envs/<cluster>.tfvars -var talos_bootstrap=true
    #
    # ─── Register as Flux spoke (workload clusters only) ──────────
    #   task register-spoke CLUSTER=${var.cluster_name}-${var.environment} PROVIDER=${local.active_provider}
    #
    # ─── Cross-provider failover (2nd management on another cloud) ──
    #   task restore-state, then task cluster-up — see the cluster README, "Cross-provider failover"
  EOT
}

# The image a node reinstalls from, and therefore which extensions it keeps.
# `rolling-replace --upgrade` reads it from here rather than rebuilding the
# string: it constructed `ghcr.io/siderolabs/installer:<version>` on its own,
# the plain image carries no system extensions, and an upgrade silently left
# every node without iscsi-tools (Scaleway, 2026-08-15). One source, and it is
# the one the machine config actually names.
output "installer_image" {
  description = "Talos installer image the machine config installs from (Image Factory schematic included)"
  value       = var.talos_bootstrap ? module.talos.installer_image : null
}
