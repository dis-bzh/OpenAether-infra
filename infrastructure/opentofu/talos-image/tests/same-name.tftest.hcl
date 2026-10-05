# The Outscale same-name lookup must reach the root output talos-image.sh --ensure
# gates on, and only on that target. `command = plan` throughout: a provisioner
# would download an 11 GiB image on apply, and override_resource does not stop it.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "proxmox" {}
mock_provider "external" {}

mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "{\"id\":\"0000000000000000000000000000000000000000000000000000000000000000\"}" }
  }
}

# The mock must carry every attribute of the real object, or the provider shape check refuses it.
mock_provider "outscale" {
  mock_data "outscale_images" {
    defaults = {
      images = [
        {
          account_alias    = "", account_id = "", architecture = "x86_64", block_device_mappings = [], boot_modes = [],
          creation_date    = "", description = "", file_location = "", image_id = "ami-fixture1", image_name = "fixture",
          image_type       = "machine", permissions_to_launch = [], product_codes = [], root_device_name = "/dev/sda1",
          root_device_type = "bsu", secure_boot = false, state = "available", state_comment = [], tags = [], tpm_mandatory = false,
        },
        {
          account_alias    = "", account_id = "", architecture = "x86_64", block_device_mappings = [], boot_modes = [],
          creation_date    = "", description = "", file_location = "", image_id = "ami-fixture2", image_name = "fixture",
          image_type       = "machine", permissions_to_launch = [], product_codes = [], root_device_name = "/dev/sda1",
          root_device_type = "bsu", secure_boot = false, state = "available", state_comment = [], tags = [], tpm_mandatory = false,
        },
      ]
    }
  }
}

variables {
  encryption_passphrase = "test-mock-passphrase-for-validation-only"
  talos_version         = "v0.0.1"
  import_bucket         = "fixture-import"
}

run "outscale_reports_the_omis_already_holding_the_name" {
  command = plan
  variables {
    target_provider = "outscale"
  }
  assert {
    condition     = output.omi_name_collisions == tolist(["ami-fixture1", "ami-fixture2"])
    error_message = "the same-name lookup did not reach omi_name_collisions: ${jsonencode(output.omi_name_collisions)}"
  }
}

run "other_targets_report_none" {
  command = plan
  variables {
    target_provider = "ovh"
  }
  assert {
    condition     = length(output.omi_name_collisions) == 0
    error_message = "a non-Outscale target reported OMI collisions"
  }
}
