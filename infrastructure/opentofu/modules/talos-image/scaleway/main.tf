# ==============================================================================
# Scaleway has no "import image from URL" primitive, so the flow is:
#   Factory (scaleway-<arch>.raw.zst) -> qcow2 -> Object Storage -> snapshot -> image
# The fetch/convert/upload step is necessarily imperative (local-exec); the
# snapshot and image are then fully declarative and tracked in state.
# ==============================================================================

locals {
  factory_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/scaleway-${var.arch}.raw.zst"
  object_key  = "talos/scaleway-${var.arch}-${var.talos_version}.qcow2"
  qcow2_path  = "${var.cache_dir}/scaleway-${var.arch}-${var.talos_version}.qcow2"
  scw_arch    = var.arch == "arm64" ? "arm" : "x86_64"
}

# Fetch from Image Factory, decompress, convert to QCOW2, upload to the bucket.
# The staging bucket (var.bucket_name) is created externally by ensure-buckets.sh
# before tofu init — it is NOT a Terraform resource here to avoid a 409 on
# BucketAlreadyOwnedByYou when the module is re-applied with an existing bucket.
# Re-runs only when the schematic/version/key changes.
resource "terraform_data" "build_and_upload" {
  triggers_replace = {
    schematic = var.schematic_id
    version   = var.talos_version
    key       = local.object_key
    bucket    = var.bucket_name # re-upload if the staging bucket name changes
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # S3-compatible stores reject the AWS CLI v2.23+ default trailing checksum —
      # only add checksums when the operation actually requires them.
      export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
      for bin in curl zstd qemu-img aws; do
        command -v "$bin" >/dev/null 2>&1 || {
          echo "✗ required tool not found: $bin — run 'task setup' (installs zstd, qemu-utils, awscli)"
          exit 1
        }
      done
      mkdir -p "${var.cache_dir}"
      echo "▶ Downloading Talos ${var.talos_version} (scaleway-${var.arch}) from Image Factory..."
      curl -fL --retry 3 "${local.factory_url}" -o "${var.cache_dir}/image.raw.zst"
      echo "▶ Decompressing (zstd) + converting to QCOW2 (qemu-img)..."
      zstd -f -d "${var.cache_dir}/image.raw.zst" -o "${var.cache_dir}/image.raw"
      qemu-img convert -f raw -O qcow2 "${var.cache_dir}/image.raw" "${local.qcow2_path}"
      echo "▶ Uploading to Object Storage: s3://${var.bucket_name}/${local.object_key}"
      aws s3 cp "${local.qcow2_path}" "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}"
      rm -f "${var.cache_dir}/image.raw.zst" "${var.cache_dir}/image.raw" "${local.qcow2_path}"
      echo "✓ Staged QCOW2 ready for snapshot import."
    EOT
  }

}

# Import the staged QCOW2 as a Block Storage (SBS) snapshot in every target zone.
# Block storage is the current-gen, all-zones, durable path (l_ssd/DEV1 is
# deprecated). Snapshots are zonal, so HA across fr-par-1/2/3 needs one per zone.
# The staged object is read once, at import. Measured 2026-10-02 (Scaleway): deleting the
# current version's object and planning the image lane again gave "No changes", so it is a
# cache, not a plan-stability requirement. It is kept on purpose, not purged: it spares a
# re-download and a conversion if a snapshot is ever re-imported (unmeasured: whether that
# re-stages it by itself). One ~220 MB object per Talos version stays in the bucket; empty
# it by hand. Outscale deletes its copy because the OMI stands alone.
resource "scaleway_block_snapshot" "talos" {
  for_each = toset(var.zones)

  zone = each.value
  name = "${var.image_name}-${each.value}"

  import {
    bucket = var.bucket_name
    key    = local.object_key
  }

  depends_on = [terraform_data.build_and_upload]
}

# One bootable Instance Image per zone from the block snapshot, all sharing the
# same name so the cluster's per-zone `data.scaleway_instance_image` lookup finds
# it everywhere. A block-backed image boots block-storage instances (PRO2/POP2).
resource "scaleway_instance_image" "talos" {
  for_each = toset(var.zones)

  name           = var.image_name
  zone           = each.value
  architecture   = local.scw_arch
  root_volume_id = scaleway_block_snapshot.talos[each.value].id
  tags           = ["talos", var.talos_version, "managed-by-opentofu"]
}
