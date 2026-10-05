output "schematic_id" {
  description = "Resolved Image Factory schematic ID (deterministic from schematic.yaml)."
  value       = local.schematic_id
}

output "image_name" {
  description = "Name of the image. Scaleway clusters look the image up by this name."
  value       = local.image_name
}

output "image_id" {
  description = "Image ID for OVH (glance UUID) / Outscale (OMI) — set this as image_id in the cluster envs/*.tfvars."
  value = coalesce(
    try(one(module.ovh[*].image_id), null),
    try(one(module.outscale[*].image_id), null),
    "n/a (scaleway looks up by name, proxmox uses image_file_id)"
  )
}

output "image_ids" {
  description = "Scaleway only: map of zone => Instance Image ID."
  value       = var.target_provider == "scaleway" ? one(module.scaleway[*].image_ids) : null
}

output "image_file_id" {
  description = "Proxmox only: file_id (datastore:iso/filename) — matches the convention cluster/main.tf falls back to, so talos_image_file_id rarely needs to be set explicitly."
  value       = var.target_provider == "proxmox" ? one(module.proxmox[*].image_file_id) : null
}
