# ==============================================================================
# Talos image — Outscale (OMI)
# Outscale has no foreign-image import primitive, so (mirrors Scaleway):
#   Factory (aws-<arch>.raw.zst) -> raw -> OOS (Object Storage)
#     -> outscale_snapshot (import via file_location) -> outscale_image (OMI)
#
# PLATFORM `aws` (not `nocloud`): Outscale is EC2-compatible and exposes
# an EC2 IMDS. Talos's aws variant reads it, which brings TWO things that are
# essential to CAPI (CAPOSC delivers the machine config as user-data, like EC2):
#   1. user-data ingestion  -> without it CAPI VMs would stay in maintenance
#      mode, never configured;
#   2. reading public-ipv4  -> the public IP (1:1 NAT on the Outscale side, so
#      invisible from the NIC) becomes a NodeAddress and enters the apid
#      certificate SANs; without it CACPPT would fail TLS on <IP>:50000
#      ("certificate is valid for 10.x, not <public IP>") and could neither
#      bootstrap etcd nor fetch the child's kubeconfig.
# The OpenTofu flow (two-phase apply) is unchanged: without user-data the aws
# image also boots into maintenance mode and gets its config over the Talos API.
# ==============================================================================

locals {
  factory_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/aws-${var.arch}.raw.zst"
  # Versioned scratch names: one version's leftovers are never another's.
  raw_zst    = "${var.cache_dir}/aws-${var.arch}-${var.talos_version}.raw.zst"
  raw_path   = "${var.cache_dir}/aws-${var.arch}-${var.talos_version}.raw"
  object_key = "talos/aws-${var.arch}-${var.talos_version}.raw"
}

# Fetch from Image Factory, decompress, upload the raw disk to OOS for import.
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
      # S3-compatible stores (OOS/OVH) reject the AWS CLI v2.23+ default trailing
      # checksum — only add checksums when the operation actually requires them.
      export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
      for bin in curl zstd aws; do
        command -v "$bin" >/dev/null 2>&1 || { echo "✗ required tool not found: $bin — run 'task setup'"; exit 1; }
      done
      mkdir -p "${var.cache_dir}"
      echo "▶ Downloading Talos ${var.talos_version} (aws-${var.arch}) from Image Factory..."
      curl -fL --retry 3 "${local.factory_url}" -o "${local.raw_zst}"
      echo "▶ Decompressing (zstd)..."
      zstd -f -d "${local.raw_zst}" -o "${local.raw_path}"
      echo "▶ Uploading to OOS: s3://${var.bucket_name}/${local.object_key}"
      aws s3 cp "${local.raw_path}" "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}"
      rm -f "${local.raw_zst}" "${local.raw_path}"
      echo "✓ Raw image staged for snapshot import."
    EOT
  }
}

# Outscale's ImportSnapshot needs (a) a PRE-SIGNED URL to read the OOS object
# (a plain URL to a private object is denied with 401), and (b) the snapshot size
# in BYTES, >= the file size. Compute both after the upload: presign + head-object
# (ContentLength rounded up to the next GiB). The presigned URL changes every run
# (so file_location is ignored after create); the size is deterministic.
data "external" "oos_object" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
    # ⚠️ TOLERATES A MISSING OBJECT. This data source is evaluated on EVERY
    # plan/refresh, while its values are only used to CREATE the snapshot. If
    # it required the object, the staging `.raw` (~11 GiB, billed continuously)
    # could never be purged without breaking every `tofu plan`.
    # Hence the automatic purge after the OMI is registered, further down.
    if aws s3api head-object --bucket "${var.bucket_name}" --key "${local.object_key}" \
         --endpoint-url "${var.s3_endpoint}" --region "${var.region}" >/dev/null 2>&1; then
      url="$(aws s3 presign "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}" --expires-in 3600)"
      bytes="$(aws s3api head-object --bucket "${var.bucket_name}" --key "${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}" --query ContentLength --output text)"
      gib=1073741824
      size=$(( (bytes + gib - 1) / gib * gib ))
    else
      # Object purged after import: the snapshot already exists, these values
      # are ignored (see the snapshot's lifecycle.ignore_changes).
      url=""
      size=0
    fi
    printf '{"url":"%s","size":"%s"}' "$url" "$size"
  EOT
  ]

  depends_on = [terraform_data.build_and_upload]
}

# Import the raw disk from OOS as a snapshot (SnapshotSize is in BYTES).
resource "outscale_snapshot" "talos" {
  file_location = data.external.oos_object.result.url
  snapshot_size = tonumber(data.external.oos_object.result.size)
  description   = "Talos ${var.talos_version} (${var.arch}) — imported for OMI registration"

  # ⚠️ The Outscale snapshot import goes through a provider-side queue whose
  # wait is WIDE and outside our control: 8 min end to end (2026-08-18) against
  # > 60 min stuck at `in-queue 0%` (2026-07-25). Size the timeout for the bad
  # day, not the good one — the provider default (40 min) let the apply fail
  # while the import then succeeded, leaving a snapshot OUTSIDE STATE.
  # `ReadSnapshots` reports State/Progress and is the only honest answer about
  # where an import actually is. If the apply dies while the import lives on:
  # DO NOT re-run the apply as-is (it creates a second import) — adopt the
  # existing snapshot into THAT version's state first, then continue:
  #   scripts/bootstrap/talos-image.sh outscale <version> --import-snapshot <snap-id>
  # (it refuses unless that state holds build_and_upload: the next plan would replace the snapshot)
  timeouts {
    create = "120m"
  }

  lifecycle {
    # `file_location` (pre-signed URL, changes every run) AND `snapshot_size`
    # both come from the staging object, which is purged after the import:
    # without ignoring them, every plan would see drift and redo a one-hour
    # import.
    ignore_changes       = [file_location, snapshot_size]
    replace_triggered_by = [terraform_data.build_and_upload]

    # Import the new snapshot BEFORE dropping the old one. Destroy-first would
    # leave the account with no bootable Talos image for the whole import — an
    # hour, in the middle of an upgrade — and an import that then fails leaves
    # neither the old artifact nor a new one. Two versions coexisting costs
    # snapshot storage; being unable to rebuild a node costs the cluster.
    create_before_destroy = true
  }

  depends_on = [terraform_data.build_and_upload]

}

# Register a bootable OMI from the imported snapshot. The cluster references it by
# ID (set image_id in the cluster envs/*.tfvars).
resource "outscale_image" "talos" {
  image_name       = var.image_name
  architecture     = var.arch == "arm64" ? "arm64" : "x86_64"
  root_device_name = "/dev/sda1"

  block_device_mappings {
    device_name = "/dev/sda1"
    bsu {
      snapshot_id = outscale_snapshot.talos.snapshot_id
      # ⚠️ MUST be ≥ the snapshot size, otherwise CreateImage fails
      # ("Volume size must be greater than <snap> size"): the aws image is
      # 11 GiB against 10 for the older nocloud one. Deliberate headroom.
      volume_size           = 16
      volume_type           = "standard"
      delete_on_vm_deletion = true
    }
  }

  lifecycle {
    # An OMI's backing snapshot is IMMUTABLE, so a new snapshot means a new
    # image — but the provider reports block_device_mappings as updatable, so a
    # version bump planned "image: update in place, snapshot: replace". OpenTofu
    # then destroyed the snapshot while this image still pointed at it and
    # Outscale refused:
    #     Unable to delete Snapshot — 409 ResourceConflict, Code 9094
    # (measured 2026-08-18 upgrading v1.13.7 → v1.13.8: the run died before
    # touching a single node, and the API confirmed ami-… still referenced
    # snap-…). Forcing the replacement puts the image back where it belongs in
    # the graph: destroyed BEFORE the snapshot it is built on.
    replace_triggered_by = [outscale_snapshot.talos]

    # Required for the snapshot's create_before_destroy above: OpenTofu refuses
    # the mode unless every dependent shares it. Names carry the version, so two
    # versions coexist; a same-version replacement does not (see refuse_taken_omi in talos-image.sh).
    create_before_destroy = true
  }
}

# Purge of the staging `.raw`, once the OMI is registered.
#
# WHY: the object is ~11 GiB and used to be kept forever, one per Talos version
# — billed for nothing. The DURABLE artifacts are the snapshot and the OMI;
# the `.raw` is only an import intermediate, and it can be rebuilt identically
# from the Image Factory (the schematic ID is deterministic).
#
# ⚠️ This purge is ONLY possible because `data.external.oos_object` now
# tolerates a missing object (see above). Deleting the `.raw` without that fix
# breaks every `tofu plan` of the talos-image root.
#
# Fired by the same trigger as the upload: a new version goes through the
# download → upload → import → OMI → purge.
resource "terraform_data" "purge_staging" {
  triggers_replace = {
    key    = local.object_key
    bucket = var.bucket_name
    image  = outscale_image.talos.image_id
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
      echo "▶ Purging the staging object: s3://${var.bucket_name}/${local.object_key}"
      aws s3 rm "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}" || true
      echo "✓ staging purged (the OMI and the snapshot remain the durable artifacts)"
    EOT
  }

  depends_on = [outscale_image.talos]
}
