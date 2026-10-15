# ==============================================================================
# Talos image — OVH (OpenStack Glance)
# Downloads the Talos Image Factory artifact for the `openstack` platform,
# converts it to QCOW2, and uploads it to Glance as a private image. The image is
# region-wide (not zonal); the cluster's OVH module references it by ID.
# ==============================================================================

variable "talos_version" {
  description = "Talos version tag (e.g. v1.13.3) — must match an Image Factory release."
  type        = string
}

variable "arch" {
  description = "Image architecture (amd64 or arm64)."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "arch must be amd64 or arm64."
  }
}

variable "schematic_id" {
  description = "Image Factory schematic ID (resolved by the root from schematic.yaml)."
  type        = string
}

variable "image_name" {
  description = "Name of the resulting Glance image."
  type        = string
}

variable "cache_dir" {
  description = "Local directory used to stage the downloaded/converted image."
  type        = string
}

variable "expected_sha256" {
  description = "sha256 of the Factory raw.zst this module downloads, from talos-image/images.lock. Empty = none recorded."
  type        = string
  default     = ""

  validation {
    condition     = var.expected_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.expected_sha256))
    error_message = "expected_sha256 must be empty or 64 lowercase hex characters."
  }
}

variable "checksum_mode" {
  description = "off | warn | enforce: what to do when the downloaded image does not match expected_sha256 (or none is recorded). See scripts/internal/verify-image-checksum.sh."
  type        = string
  default     = "warn"

  validation {
    condition     = contains(["off", "warn", "enforce"], var.checksum_mode)
    error_message = "checksum_mode must be off, warn or enforce."
  }
}
