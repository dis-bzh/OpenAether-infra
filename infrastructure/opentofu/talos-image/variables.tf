variable "target_provider" {
  description = "Which provider to build the Talos image for: scaleway, ovh, outscale, or proxmox."
  type        = string
  default     = "scaleway"

  validation {
    condition     = contains(["scaleway", "ovh", "outscale", "proxmox"], var.target_provider)
    error_message = "target_provider must be one of: scaleway, ovh, outscale, proxmox."
  }
}

# No default: a bare apply would replace the image this state holds with whatever a
# default names (the old one went stale unnoticed). talos-image.sh always passes it.
variable "talos_version" {
  description = "Talos version tag (must exist on Image Factory) — the ONE version this state holds."
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

# --- Scaleway / Outscale upload path (unused by the OVH glance build) --------

# NOT "staging": this repository already uses that word for an environment
# (`environment = "dev"` in the cluster tfvars), and reading it here as one is
# what it cost. This is the transit area an image is uploaded to so the provider
# can import it as a snapshot, and `import` is what it does.
#
# No default. It used to carry a literal name with the project AND the provider
# baked in, so a fork got a correct name everywhere except here, and a caller
# that stopped passing -var would have aimed at somebody else's bucket without
# saying so. Empty is refused where it is used, by the two modules that need it.
variable "import_bucket" {
  description = "Object Storage bucket the image is uploaded to for the snapshot import (Scaleway/Outscale path). Derived by talos-image.sh; required on those two providers."
  type        = string
  default     = ""
}

variable "region" {
  description = "Region for the image build (Scaleway bucket + zonal images)."
  type        = string
  default     = "fr-par"
}

variable "zones" {
  description = "Scaleway zones to publish the image into (images are zonal). Unused by OVH/Outscale."
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "s3_endpoint" {
  description = "S3-compatible endpoint for the Object Storage upload (Scaleway/Outscale)."
  type        = string
  default     = "https://s3.fr-par.scw.cloud"
}

# --- Proxmox-specific (unused by the scaleway/ovh/outscale builds) -----------

variable "proxmox_node_names" {
  description = "Proxmox node (host) names to download the image onto (one copy per PVE host). Match the cluster's node_distribution.proxmox.node_names."
  type        = list(string)
  default     = ["pve1"]
}

variable "proxmox_iso_datastore_id" {
  description = "Proxmox datastore to store the downloaded image on. Match the cluster's node_distribution.proxmox.iso_datastore_id."
  type        = string
  default     = "local"
}

# --- Outscale API creds (fed by the orchestrator; same AK/SK as OOS) ----------

variable "outscale_access_key_id" {
  description = "Outscale API access key (the orchestrator sets it from the resolved OOS keys). Empty = use OSC_* env."
  type        = string
  default     = ""
  sensitive   = true
}

variable "outscale_secret_key_id" {
  description = "Outscale API secret key."
  type        = string
  default     = ""
  sensitive   = true
}

# --- State encryption (mirrors the cluster root) -----------------------------

variable "encryption_passphrase" {
  description = "Passphrase encrypting this root's tfstate. Same value as the cluster root — the two states are encrypted by one secret, not two."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.encryption_passphrase) >= 32
    error_message = "encryption_passphrase must be at least 32 characters long."
  }
}
