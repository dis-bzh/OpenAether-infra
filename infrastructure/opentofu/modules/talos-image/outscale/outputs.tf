output "image_id" {
  description = "Outscale OMI ID — set this as image_id in the cluster envs/*.tfvars (Outscale)."
  value       = outscale_image.talos.image_id
}

output "image_name" {
  description = "Name of the created OMI."
  value       = var.image_name
}
