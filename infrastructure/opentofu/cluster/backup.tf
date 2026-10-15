# S3-compatible encrypted backup / disaster recovery.
#
# Backs up the access artifacts (talosconfig, kubeconfig) to TWO stores: primary
# (the cluster's provider) and replica (a different provider in prod). Machine
# configs are deliberately NOT backed up — they embed ~1.8 MB of inline
# manifests and are derivable from the machine secrets, which already live in
# the encrypted tfstate (the real DR artifact).
#
# Encryption: client-side gpg AES-256 (CFB with a SHA-1 MDC, not an AEAD mode) under artifact_passphrase when set,
# else the tfstate passphrase (that is what protects the data), plus S3 SSE on top (provider-managed, not a control we
# can assess).
#
# ⚠️ Uses the AWS CLI rather than aws_s3_object: that resource hits a
# "version_id known -> now unknown" plan-consistency bug on non-AWS S3 stores.
#
# The tfstate's own replication is a separate post-apply step
# (scripts/ops/backup-state.sh): the backend only flushes it after the apply.
# ==============================================================================

locals {
  # Unset or empty artifact_passphrase = the state passphrase, exactly as before the variable existed.
  # nonsensitive(): that it is set is no secret, and the mark would hide the whole triggers_replace map in every plan.
  artifact_passphrase_set = nonsensitive(var.artifact_passphrase != null && var.artifact_passphrase != "")
  artifact_passphrase     = local.artifact_passphrase_set ? var.artifact_passphrase : var.encryption_passphrase

  # Bucket naming convention: s3-<project>-<provider>-{tfstate|<role>}-<env> (+ -backup).
  # The provider is explicit (not buried in cluster_name) so it's consistent across
  # management and workload clusters; project is cluster_name's first segment.
  # Must stay identical to oa_project() in scripts/lib/common.sh: the shell
  # creates these buckets before OpenTofu ever runs, so the two derivations
  # disagreeing means the backend points at a bucket nothing created.
  backup_project        = join("-", compact([split("-", var.cluster_name)[0], var.bucket_suffix]))
  backup_provider_short = lookup({ scaleway = "scaleway", ovh = "ovh", outscale = "outscale" }, local.active_provider, local.active_provider)
  backup_bucket_prefix  = "s3-${local.backup_project}-${local.backup_provider_short}"

  # Artifacts (kube/talosconfig): the cluster's own provider holds the PRIMARY;
  # a "-backup" store (in prod a different provider) holds the REPLICA.
  artifact_bucket_primary = "${local.backup_bucket_prefix}-${var.cluster_role}-${var.environment}"
  artifact_bucket_replica = "${local.artifact_bucket_primary}-backup"

  # State: the backend (backend.tf, configured via scripts/internal/tf-backend.sh) writes the PRIMARY;
  # scripts/ops/backup-state.sh replicates it to the "-backup" store. Management and
  # workload clusters on the same provider/env share this bucket, distinguished by
  # the per-cluster key. Surfaced via the backup_targets output.
  # Bucket for APPLICATION backups (restic, Longhorn volume backups).
  # Same convention as the others, but it PRE-EXISTS — the operator creates it
  # and seeds its credentials into OpenBao (`secret/backup/s3-primary`). We
  # derive its name here to publish it in the `cluster-identity` ConfigMap that
  # the Longhorn brick consumes: the backup target is a string, it cannot come
  # from a Secret. ⚠️ Must match what is seeded in OpenBao.
  backup_data_bucket = "${local.backup_bucket_prefix}-backups-${var.environment}"

  state_bucket_primary = "${local.backup_bucket_prefix}-tfstate-${var.environment}"
  state_bucket_replica = "${local.state_bucket_primary}-backup"
  state_key            = "${var.cluster_name}.tfstate"
}

resource "terraform_data" "backup" {
  # Only after Phase 2 (talos_bootstrap): before that the kube/talosconfig don't
  # exist yet. backup_enabled=false skips it entirely (local testing).
  count = var.backup_enabled && var.talos_bootstrap && local.total_control_planes > 0 ? 1 : 0

  # Re-upload only when an artifact (or a target) actually changes.
  # The passphrase joins the triggers only when a separate one is set, so a cluster that does not set it sees no diff;
  # setting it re-uploads the artifacts under the new secret.
  triggers_replace = merge({
    talosconfig = sha256(module.talos.talosconfig)
    kubeconfig  = sha256(module.talos.kubeconfig_raw)
    targets     = "${local.artifact_bucket_primary}|${local.artifact_bucket_replica}|${var.s3_primary_endpoint}|${var.s3_replica_endpoint}"
  }, local.artifact_passphrase_set ? { artifact_passphrase = sha256(var.artifact_passphrase) } : {})

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash"]
    command     = abspath("${path.module}/../../../scripts/ops/backup-artifacts.sh")

    # Secrets (passphrase) and the artifacts go via env (binary-safe base64). The
    # script resolves the S3 creds from PROVIDER (primary + <PU>_BACKUP_AWS_*).
    environment = {
      TALOSCONFIG_B64 = base64encode(module.talos.talosconfig)
      KUBECONFIG_B64  = base64encode(module.talos.kubeconfig_raw)
      PASSPHRASE      = local.artifact_passphrase
      PROVIDER        = local.active_provider
      PRIMARY_BUCKET  = local.artifact_bucket_primary
      PRIMARY_EP      = var.s3_primary_endpoint
      PRIMARY_REGION  = var.s3_primary_region
      REPLICA_BUCKET  = local.artifact_bucket_replica
      REPLICA_EP      = var.s3_replica_endpoint
      REPLICA_REGION  = var.s3_replica_region
    }
  }
}
