variable "encryption_passphrase" {
  description = "Passphrase (>=32 chars) for OpenTofu client-side state and plan encryption (PBKDF2 → AES-GCM); the object store never sees the key. Supply via TF_VAR_encryption_passphrase; never commit. Generate it: scripts/ops/gen-passphrase.sh."
  type        = string
  sensitive   = true

  # NOTE: length alone is not security. This MUST be a high-entropy, randomly
  # generated secret (e.g. `openssl rand -base64 48`) — NOT a dictionary phrase
  # or keyboard pattern. PBKDF2 only slows brute force; a low-entropy 32-char
  # passphrase remains guessable. Store it in a password manager / KMS.
  validation {
    condition     = length(var.encryption_passphrase) >= 32
    error_message = "encryption_passphrase must be at least 32 characters long (state encryption key derivation). Generate one: scripts/ops/gen-passphrase.sh."
  }
}

# Optional second secret for the gpg-encrypted access artifacts (talosconfig, kubeconfig) and etcd snapshots, so that
# one leaked passphrase does not open the state AND the artifacts AND every Secret in etcd. Unset = they keep using
# encryption_passphrase, as before. The scripts read the same name from the environment (etcd-snapshot.sh).
variable "artifact_passphrase" {
  description = "Optional separate passphrase (>=32 chars) for the gpg-encrypted talosconfig/kubeconfig backups and etcd snapshots. Unset or empty: encryption_passphrase is used. Supply it ONLY via TF_VAR_artifact_passphrase (etcd-snapshot.sh reads the environment, not a tfvars file); keep it in a different place from the state passphrase."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.artifact_passphrase == null ? true : (var.artifact_passphrase == "" || length(var.artifact_passphrase) >= 32)
    error_message = "artifact_passphrase must be unset, empty, or at least 32 characters long."
  }
}

terraform {
  encryption {
    key_provider "pbkdf2" "migration_key" {
      passphrase = var.encryption_passphrase
      # Pinned to what OpenTofu 1.12 defaults to (read back from a state's metadata), so a future default
      # never changes the derivation silently. A state records its own parameters: this only governs new writes.
      iterations    = 600000
      hash_function = "sha512"
      key_length    = 32
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

  # Partial backend: bucket / key / region / endpoint are DERIVED from the
  # cluster's tfvars (the single source of truth) so each cluster gets its OWN
  # encrypted state, following s3-<project>-<provider>-tfstate-<env> (key
  # <cluster_name>.tfstate). Initialise with:
  #   tofu init -reconfigure $(scripts/internal/tf-backend.sh envs/<cluster>.tfvars)
  # The Taskfile does this for you. The state payload is client-encrypted by the
  # encryption{} block above before it ever reaches S3.
  backend "s3" {
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
