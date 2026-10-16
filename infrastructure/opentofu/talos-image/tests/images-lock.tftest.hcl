# images.lock: the root hands each image module the sha256 recorded for its (schematic, version, platform, arch), and the
# lock covers the version the cluster pins on every platform. The downloads and local-exec are not run here:
# scripts/dev/test-image-checksum.sh owns the verifier, and the Factory is never contacted (the schematic is overridden).

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "http" {}

# The cluster root's talos_installer_schematic_id default; scripts/dev/test-image-checksum.sh keeps the two equal.
override_data {
  target = data.http.schematic
  values = { response_body = "{\"id\":\"613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245\"}" }
}

variables {
  encryption_passphrase = "test-mock-passphrase-for-validation-only-0123456789"
  talos_version         = "v1.14.2"
  import_bucket         = "example-image-import"
  target_provider       = "ovh"
}

run "locked_version_has_a_hash_on_every_platform" {
  command = plan

  assert {
    condition     = alltrue([for p, h in output.image_expected_sha256 : can(regex("^[0-9a-f]{64}$", h))])
    error_message = "images.lock has no sha256 for the pinned Talos version on some platform: run scripts/bootstrap/talos-image-lock.sh."
  }
}

run "arm64_is_locked_too" {
  command = plan

  variables {
    arch = "arm64"
  }

  assert {
    condition     = alltrue([for p, h in output.image_expected_sha256 : can(regex("^[0-9a-f]{64}$", h))])
    error_message = "images.lock has no arm64 line for the pinned Talos version."
  }
}

run "an_unlocked_version_has_none_and_still_plans" {
  command = plan

  variables {
    talos_version = "v0.0.1"
  }

  assert {
    condition     = alltrue([for p, h in output.image_expected_sha256 : h == ""])
    error_message = "a version images.lock does not list must give an empty expected hash (warn mode builds anyway)."
  }
}

run "the_default_is_warn_so_nothing_changes_for_a_deployed_lane" {
  command = plan

  assert {
    condition     = var.image_checksum_mode == "warn"
    error_message = "image_checksum_mode must default to warn: enforce would stop a build the lock does not cover."
  }
}

run "an_unknown_mode_is_refused" {
  command = plan

  variables {
    image_checksum_mode = "strict"
  }

  expect_failures = [var.image_checksum_mode]
}
