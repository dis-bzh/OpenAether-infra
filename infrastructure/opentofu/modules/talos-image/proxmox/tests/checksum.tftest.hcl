# The Proxmox download is server-side, so the only integrity check is the provider's own `checksum`, and it is sent only
# under checksum_mode = "enforce". Anything else must leave the resource exactly as it was (no plan diff on a deployed file).

mock_provider "proxmox" {}

variables {
  talos_version = "v1.14.2"
  schematic_id  = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"
  node_names    = ["pve1"]
}

run "warn_sends_no_checksum" {
  command = plan

  variables {
    expected_sha256 = "d27a246643fb98bb817d58dcca1277e72ad346b0e7e12d4fbc8825e6eb061863"
  }

  assert {
    condition     = proxmox_virtual_environment_download_file.talos["pve1"].checksum == null && proxmox_virtual_environment_download_file.talos["pve1"].checksum_algorithm == null
    error_message = "in warn mode the download_file must carry no checksum: adding one to a deployed file is a plan diff."
  }
}

run "enforce_sends_the_locked_hash" {
  command = plan

  variables {
    checksum_mode   = "enforce"
    expected_sha256 = "d27a246643fb98bb817d58dcca1277e72ad346b0e7e12d4fbc8825e6eb061863"
  }

  assert {
    condition     = proxmox_virtual_environment_download_file.talos["pve1"].checksum == "d27a246643fb98bb817d58dcca1277e72ad346b0e7e12d4fbc8825e6eb061863" && proxmox_virtual_environment_download_file.talos["pve1"].checksum_algorithm == "sha256"
    error_message = "enforce must hand the provider the recorded sha256 and name its algorithm."
  }
}

run "enforce_refuses_when_nothing_is_recorded" {
  command = plan

  variables {
    checksum_mode = "enforce"
  }

  expect_failures = [proxmox_virtual_environment_download_file.talos]
}

run "a_malformed_hash_is_refused" {
  command = plan

  variables {
    expected_sha256 = "not-a-hash"
  }

  expect_failures = [var.expected_sha256]
}
