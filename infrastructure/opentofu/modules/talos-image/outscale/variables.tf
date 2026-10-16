# ==============================================================================
# Talos image — Outscale
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
  description = "Name of the resulting OMI."
  type        = string
}

variable "bucket_name" {
  description = "OOS bucket the raw image is uploaded to for the snapshot import."
  type        = string

  # The root defaults this to "" so that a literal project name is not baked into
  # a default nobody passes. Empty reaches here only when a caller forgot, and an
  # empty bucket name would fail deep inside `aws s3 cp` with a message naming
  # neither this variable nor the caller. Refuse it where it is named.
  validation {
    condition     = length(var.bucket_name) > 0
    error_message = "bucket_name is empty: pass -var import_bucket=… (scripts/bootstrap/talos-image.sh derives it)."
  }
}

variable "region" {
  description = "Outscale region (e.g. eu-west-2)."
  type        = string
}

variable "s3_endpoint" {
  description = "OOS S3-compatible endpoint (e.g. https://oos.eu-west-2.outscale.com)."
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
