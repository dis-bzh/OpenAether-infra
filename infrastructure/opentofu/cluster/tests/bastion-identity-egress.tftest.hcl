# bastion_admins, bastion_require_hardware_key and bastion_internet_egress: the operator's input to the per-person accounts
# and to the closing of the bastion's Internet egress. Same shape as bastion-input-validation.tftest.hcl: no provider
# module activates, only the variables are read. The security-group rules these produce are checked in
# scaleway.tftest.hcl, the rendered cloud-init in scripts/dev/test-cluster-checks.sh and bastion-baseline-check.sh.

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

# --- bastion_admins: accepted ---

run "the_default_has_no_named_operator_and_no_pin" {
  command = plan
  assert {
    condition     = length(var.bastion_admins) == 0 && var.bastion_require_hardware_key == false && var.bastion_internet_egress.mode == "legacy"
    error_message = "Nothing may change for a cluster that never set these variables."
  }
}

run "named_operators_with_any_acceptable_key_type_are_accepted" {
  command = plan
  variables {
    bastion_admins = {
      alice = { ssh_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y9 alice@laptop", "sk-ssh-ed25519@openssh.com AAAAGnNr alice-token"] }
      bob   = { ssh_keys = ["ecdsa-sha2-nistp256 AAAAE2Vj bob@laptop"] }
      c_3-d = { ssh_keys = ["from=\"203.0.113.4\" sk-ecdsa-sha2-nistp256@openssh.com AAAAInNr carol"] }
    }
  }
  assert {
    condition     = length(var.bastion_admins) == 3
    error_message = "Every key type bastion_ssh_keys accepts must be accepted for a named operator too."
  }
}

run "hardware_keys_only_passes_when_every_operator_key_is_a_token" {
  command = plan
  variables {
    bastion_require_hardware_key = true
    bastion_admins = {
      alice = { ssh_keys = ["sk-ssh-ed25519@openssh.com AAAAGnNr alice-token"] }
      bob   = { ssh_keys = ["sk-ecdsa-sha2-nistp256@openssh.com AAAAInNr bob-token", "sk-ssh-ed25519@openssh.com AAAAGnNr bob-spare"] }
    }
    # The shared automation account is out of scope on purpose: a CI or tunnel key cannot touch a token.
    bastion_ssh_keys = { scaleway = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y9 automation"] }
  }
  assert {
    condition     = var.bastion_require_hardware_key
    error_message = "A token-only operator list, with a software automation key beside it, must validate."
  }
}

# --- bastion_admins: refused ---

run "an_account_name_that_is_not_a_plain_unix_name_is_refused" {
  command = plan
  variables {
    bastion_admins = { "Alice Smith" = { ssh_keys = ["ssh-ed25519 AAAA a"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "a_name_that_is_the_shared_account_or_an_image_default_user_is_refused" {
  command = plan
  variables {
    bastion_admins = { ubuntu = { ssh_keys = ["ssh-ed25519 AAAA a"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "the_shared_account_name_is_refused" {
  command = plan
  variables {
    bastion_admins = { bastion = { ssh_keys = ["ssh-ed25519 AAAA a"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "a_name_longer_than_32_characters_is_refused" {
  command = plan
  variables {
    bastion_admins = { "${join("", [for i in range(33) : "a"])}" = { ssh_keys = ["ssh-ed25519 AAAA a"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "an_operator_without_a_key_is_refused_when_there_is_no_ca" {
  command = plan
  variables {
    bastion_admins = { alice = { ssh_keys = [] } }
  }
  expect_failures = [var.bastion_admins]
}

run "a_certificate_only_operator_is_accepted_with_a_ca" {
  command = plan
  variables {
    bastion_ssh_ca_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y9 ca@example"
    bastion_admins            = { alice = { ssh_keys = [] } }
  }
  assert {
    condition     = length(var.bastion_admins["alice"].ssh_keys) == 0
    error_message = "With a CA, an account that only a certificate opens must validate: that is how a login ends with the certificate."
  }
}

run "the_default_has_no_ca" {
  command = plan
  assert {
    condition     = var.bastion_ssh_ca_public_key == "" && var.bastion_ssh_ca_principals == ""
    error_message = "A cluster that never set the CA must keep the empty trust file."
  }
}

run "a_ca_key_with_a_quote_is_refused" {
  command = plan
  variables {
    bastion_ssh_ca_public_key = "ssh-ed25519 AAAA\" evil: yes"
  }
  expect_failures = [var.bastion_ssh_ca_public_key]
}

run "a_ca_key_that_is_not_a_key_is_refused" {
  command = plan
  variables {
    bastion_ssh_ca_public_key = "not-a-key AAAA ca"
  }
  expect_failures = [var.bastion_ssh_ca_public_key]
}

run "a_principal_with_a_space_is_refused" {
  command = plan
  variables {
    bastion_ssh_ca_principals = "ops\nbad principal"
  }
  expect_failures = [var.bastion_ssh_ca_principals]
}

run "principals_one_per_line_are_accepted" {
  command = plan
  variables {
    bastion_ssh_ca_principals = "ops\nci-deploy@example.org\n"
  }
  assert {
    condition     = var.bastion_ssh_ca_principals != ""
    error_message = "One principal per line must validate."
  }
}

run "ssh_dss_for_an_operator_is_refused" {
  command = plan
  variables {
    bastion_admins = { alice = { ssh_keys = ["ssh-dss AAAAB3NzaC1kc3MAAACBAP alice"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "a_second_line_in_an_operator_key_is_refused" {
  command = plan
  variables {
    bastion_admins = { alice = { ssh_keys = ["ssh-ed25519 AAAA a\nssh-ed25519 BBBB intruder"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "a_short_rsa_key_for_an_operator_is_refused" {
  command = plan
  variables {
    bastion_admins = { alice = { ssh_keys = ["ssh-rsa ${join("", [for i in range(204) : "A"])} alice"] } }
  }
  expect_failures = [var.bastion_admins]
}

run "a_software_key_is_refused_when_hardware_keys_are_required" {
  command = plan
  variables {
    bastion_require_hardware_key = true
    bastion_admins = {
      alice = { ssh_keys = ["sk-ssh-ed25519@openssh.com AAAAGnNr alice-token"] }
      bob   = { ssh_keys = ["sk-ssh-ed25519@openssh.com AAAAGnNr bob-token", "ssh-ed25519 AAAAC3Nza bob-software"] }
    }
  }
  expect_failures = [var.bastion_require_hardware_key]
}

run "requiring_hardware_keys_with_no_operator_is_refused" {
  command = plan
  variables {
    bastion_require_hardware_key = true
  }
  expect_failures = [var.bastion_require_hardware_key]
}

# --- bastion_internet_egress ---

run "closed_with_pinned_dns_and_ntp_is_accepted" {
  command = plan
  variables {
    bastion_internet_egress = { mode = "closed", dns_servers = ["192.0.2.53", "198.51.100.0/24", "2001:db8::53"], ntp_servers = ["192.0.2.123"] }
  }
  assert {
    condition     = var.bastion_internet_egress.mode == "closed" && length(var.bastion_internet_egress.dns_servers) == 3
    error_message = "The documented on-state must validate."
  }
}

run "closed_alone_is_accepted_and_leaves_dns_and_ntp_open" {
  command = plan
  variables {
    bastion_internet_egress = { mode = "closed" }
  }
  assert {
    condition     = length(var.bastion_internet_egress.dns_servers) == 0
    error_message = "closed with no server list is the first, lowest-risk step."
  }
}

run "an_unknown_egress_mode_is_refused" {
  command = plan
  variables {
    bastion_internet_egress = { mode = "restricted" }
  }
  expect_failures = [var.bastion_internet_egress]
}

run "a_pinned_server_without_closed_is_refused" {
  command = plan
  variables {
    bastion_internet_egress = { dns_servers = ["192.0.2.53"] }
  }
  expect_failures = [var.bastion_internet_egress]
}

run "a_server_name_instead_of_an_address_is_refused" {
  command = plan
  variables {
    bastion_internet_egress = { mode = "closed", ntp_servers = ["pool.ntp.org"] }
  }
  expect_failures = [var.bastion_internet_egress]
}

run "a_server_value_that_would_inject_a_firewall_rule_is_refused" {
  command = plan
  variables {
    bastion_internet_egress = { mode = "closed", dns_servers = ["192.0.2.53 }; accept; #"] }
  }
  expect_failures = [var.bastion_internet_egress]
}
