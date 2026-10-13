locals {
  # Must match the file_id convention modules/providers/proxmox and
  # cluster/main.tf fall back to when talos_image_file_id is left unset
  # (version without the "v" prefix, e.g. talos-1.13.3-nocloud-amd64.img).
  file_name   = "talos-${trimprefix(var.talos_version, "v")}-nocloud-${var.arch}.img"
  factory_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/nocloud-${var.arch}.raw.zst"
  # "warn" cannot warn here: Proxmox downloads server-side and nothing local sees the bytes. Only "enforce" acts.
  verify_checksum = var.checksum_mode == "enforce" && var.expected_sha256 != ""
}

# One download per PVE host: ISO/image datastores are typically per-node local
# storage (not shared across a cluster the way Ceph/NFS would be), so a VM
# landing on any node needs the file present on that specific node.
#
# Known caveat (bpg/terraform-provider-proxmox#1740): compressed downloads have
# been reported to show spurious diffs on `size` across applies. overwrite =
# false bounds the damage to a no-op re-read rather than a redownload/replace;
# validate on a real host before relying on this for unattended re-applies.
resource "proxmox_virtual_environment_download_file" "talos" {
  for_each = toset(var.node_names)

  node_name               = each.value
  datastore_id            = var.iso_datastore_id
  content_type            = "iso"
  url                     = local.factory_url
  file_name               = local.file_name
  decompression_algorithm = "zst"
  overwrite               = false

  # Set only under checksum_mode = "enforce": the provider takes `checksum` + `checksum_algorithm`, and Proxmox
  # then refuses a file that differs. UNVERIFIED whether the digest is taken before or after the server
  # decompresses the .zst; images.lock records the compressed file's. Try it on a host before relying on it.
  checksum           = local.verify_checksum ? var.expected_sha256 : null
  checksum_algorithm = local.verify_checksum ? "sha256" : null

  lifecycle {
    precondition {
      condition     = var.checksum_mode != "enforce" || var.expected_sha256 != ""
      error_message = "checksum_mode = enforce, but images.lock records no sha256 for this schematic, version and arch: run scripts/bootstrap/talos-image-lock.sh."
    }
  }
}
