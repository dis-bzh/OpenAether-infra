# ==============================================================================
# Separate, encrypted state from the cluster root: the image is built once per
# Talos version and reused by every cluster apply (decoupled lifecycle).
#
# Partial backend: bucket / key / region / endpoint are passed at init time by
# scripts/bootstrap/talos-image.sh. State lives on the TARGET provider's S3
# (s3-<project>-<provider>-talos-image), one key per version
# (talos-image-<provider>-<version>.tfstate), reached with AWS_* = that provider's S3
# keys — the same cred rule as deploying a cluster on it. State payload is
# client-encrypted by the encryption{} block below.
# ==============================================================================

terraform {
  encryption {
    key_provider "pbkdf2" "migration_key" {
      passphrase = var.encryption_passphrase
    }

    method "aes_gcm" "migration_method" {
      keys = key_provider.pbkdf2.migration_key
    }

    state {
      method = method.aes_gcm.migration_method
    }

    plan {
      method = method.aes_gcm.migration_method
    }
  }

  backend "s3" {
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
