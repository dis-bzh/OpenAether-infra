output "image_id" {
  description = "Outscale OMI ID — set this as image_id in the cluster envs/*.tfvars (Outscale)."
  value       = outscale_image.talos.image_id
}

output "image_name" {
  description = "Name of the created OMI."
  value       = var.image_name
}

output "same_name_ids" {
  description = "IDs of the OMIs already holding image_name (the lane's own, or an untracked one)."
  value       = [for i in data.outscale_images.same_name.images : i.image_id]
}
