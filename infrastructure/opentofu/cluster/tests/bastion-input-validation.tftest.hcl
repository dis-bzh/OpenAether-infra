# bastion_ssh_keys and bastion_baseline are the operator's input to the bastion's authorized_keys and OS baseline.
# The key rules refuse what OpenSSH cannot use safely (ssh-dss, a short RSA key, a second line smuggled into an
# entry) while accepting every key already deployed; the baseline object refuses settings that would be silently
# ignored. Same shape as admin-ip-validation.tftest.hcl: no provider module activates, only the variables are read.
# The cloud-init these feed is rendered and run in bastion-baseline-check.sh and test-cluster-checks.sh.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
mock_provider "local" {}

variables {
  cluster_name        = "test-cluster"
  environment         = "dev"
  cluster_role        = "management"
  talos_bootstrap     = false
  backup_enabled      = false
  node_distribution   = {}
  admin_ip            = ["203.0.113.4/32"] # RFC 5737 TEST-NET-3
  git_repo_url        = "https://github.com/test/repo.git"
  cilium_manifest     = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"
  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

# A real 2048-bit RSA blob is 372 base64 characters, 3072 bits is 544, 4096 is 716 (measured with ssh-keygen);
# the repeated letters below only have to be that long.

# --- Accepted. ---

run "the_ordinary_ed25519_key_is_accepted" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y94C3NzaC1lZDI1NTE5AAAAIOMpj9y9 me@laptop"] }
  }
  assert {
    condition     = length(var.bastion_ssh_keys["scaleway"]) == 1
    error_message = "An ed25519 key is the case the examples show and must survive validation."
  }
}

run "the_example_placeholder_and_a_truncated_fixture_are_accepted" {
  command = plan
  variables {
    bastion_ssh_keys = { outscale = ["ssh-ed25519 AAAA... user@host"], scaleway = ["ssh-ed25519 test"] }
  }
  assert {
    condition     = length(var.bastion_ssh_keys) == 2
    error_message = "The checks read the type token, not the blob: the examples and the other suites' fixtures carry placeholders."
  }
}

run "hardware_and_ecdsa_keys_are_accepted" {
  command = plan
  variables {
    bastion_ssh_keys = { ovh = [
      "sk-ssh-ed25519@openssh.com AAAAGnNr me",
      "ecdsa-sha2-nistp256 AAAAE2Vj me",
      "ecdsa-sha2-nistp384 AAAAE2Vj me",
      "ecdsa-sha2-nistp521 AAAAE2Vj me",
      "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNr me",
    ] }
  }
  assert {
    condition     = length(var.bastion_ssh_keys["ovh"]) == 5
    error_message = "Every ANSSI-acceptable type must pass."
  }
}

run "an_options_prefix_is_accepted" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["from=\"203.0.113.4\",no-agent-forwarding ssh-ed25519 AAAAC3Nza me"] }
  }
  assert {
    condition     = length(var.bastion_ssh_keys["scaleway"]) == 1
    error_message = "A key already deployed with authorized_keys options must keep planning."
  }
}

run "a_2048_bit_rsa_key_is_accepted_by_default" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["ssh-rsa ${join("", [for i in range(372) : "A"])} me"] }
  }
  assert {
    condition     = var.bastion_ssh_rsa_min_bits == 2048
    error_message = "The default floor stays 2048 so a key deployed today does not stop the next plan."
  }
}

run "a_3072_bit_rsa_key_is_accepted_at_the_strict_floor" {
  command = plan
  variables {
    bastion_ssh_rsa_min_bits = 3072
    bastion_ssh_keys         = { scaleway = ["ssh-rsa ${join("", [for i in range(544) : "A"])} me"] }
  }
  assert {
    condition     = var.bastion_ssh_rsa_min_bits == 3072
    error_message = "A 3072-bit key meets the strict floor."
  }
}

# --- Refused. ---

run "ssh_dss_is_refused" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["ssh-dss AAAAB3NzaC1kc3MAAACBAP me"] }
  }
  expect_failures = [var.bastion_ssh_keys]
}

run "a_1024_bit_rsa_key_is_refused" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["ssh-rsa ${join("", [for i in range(204) : "A"])} me"] }
  }
  expect_failures = [var.bastion_ssh_keys]
}

run "a_2048_bit_rsa_key_is_refused_at_the_strict_floor" {
  command = plan
  variables {
    bastion_ssh_rsa_min_bits = 3072
    bastion_ssh_keys         = { scaleway = ["ssh-rsa ${join("", [for i in range(372) : "A"])} me"] }
  }
  expect_failures = [var.bastion_ssh_keys]
}

run "a_second_line_in_one_entry_is_refused" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["ssh-ed25519 AAAA me\nssh-ed25519 BBBB intruder"] }
  }
  expect_failures = [var.bastion_ssh_keys]
}

run "an_unrecognised_type_is_refused" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["not-a-key AAAA me"] }
  }
  expect_failures = [var.bastion_ssh_keys]
}

run "one_bad_key_among_good_ones_is_refused" {
  command = plan
  variables {
    bastion_ssh_keys = { scaleway = ["ssh-ed25519 AAAA me"], ovh = ["ssh-dss AAAA old"] }
  }
  expect_failures = [var.bastion_ssh_keys]
}

run "an_rsa_floor_other_than_2048_or_3072_is_refused" {
  command = plan
  variables {
    bastion_ssh_rsa_min_bits = 1024
  }
  expect_failures = [var.bastion_ssh_rsa_min_bits]
}

# --- bastion_baseline ---

run "the_default_baseline_is_off" {
  command = plan
  assert {
    condition     = var.bastion_baseline.enabled == false && var.bastion_baseline.audit_logging == true && var.bastion_baseline.restrict_ssh_source == false
    error_message = "Nothing may change for a cluster that never set bastion_baseline."
  }
}

run "an_enabled_baseline_with_options_is_accepted" {
  command = plan
  variables {
    bastion_baseline = {
      enabled             = true
      restrict_ssh_source = true
      time_servers        = ["time.cloudflare.com", "2001:db8::123"]
      revoked_keys        = ["ssh-ed25519 AAAA leaver@example.org"]
    }
  }
  assert {
    condition     = var.bastion_baseline.enabled && length(var.bastion_baseline.revoked_keys) == 1
    error_message = "The documented on-state must validate."
  }
}

run "an_option_without_enabled_is_refused" {
  command = plan
  variables {
    bastion_baseline = { revoked_keys = ["ssh-ed25519 AAAA leaver@example.org"] }
  }
  expect_failures = [var.bastion_baseline]
}

run "restrict_ssh_source_without_enabled_is_refused" {
  command = plan
  variables {
    bastion_baseline = { restrict_ssh_source = true }
  }
  expect_failures = [var.bastion_baseline]
}

run "a_time_server_with_a_space_is_refused" {
  command = plan
  variables {
    bastion_baseline = { enabled = true, time_servers = ["time.example.org iburst\nserver evil.example.org"] }
  }
  expect_failures = [var.bastion_baseline]
}

run "a_revoked_key_with_a_line_break_is_refused" {
  command = plan
  variables {
    bastion_baseline = { enabled = true, revoked_keys = ["ssh-ed25519 AAAA a\nssh-ed25519 BBBB b"] }
  }
  expect_failures = [var.bastion_baseline]
}
