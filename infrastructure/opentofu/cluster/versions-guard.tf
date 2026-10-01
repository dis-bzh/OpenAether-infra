# ==============================================================================
# Talos ↔ Kubernetes version pair
#
# Talos supports the current Kubernetes minor and the five before it (n-5), so a
# pair can be individually valid and jointly unsupported — and nothing checked
# it. Only ranges read from the upstream matrix are encoded, in
# version-support.json (its `_source` says where to read them); an unknown
# Talos minor fails on purpose rather than passing silently, so bumping one
# forces a look at that matrix.
# ==============================================================================

locals {
  # The map lives in version-support.json, not here: cluster-upgrade.sh needs the
  # same ranges to build an upgrade path, and a second copy would be a second
  # source of truth. jsondecode reads it natively; jq reads it there.
  k8s_minors_by_talos_minor = jsondecode(file("${path.module}/version-support.json")).talos_minors

  talos_minor_key = join(".", slice(split(".", trimprefix(var.talos_version, "v")), 0, 2))
  k8s_minor_num   = tonumber(split(".", trimprefix(var.kubernetes_version, "v"))[1])
  k8s_supported   = lookup(local.k8s_minors_by_talos_minor, local.talos_minor_key, null)
}

resource "terraform_data" "version_pair_guard" {
  input = "${var.talos_version}/${var.kubernetes_version}"

  lifecycle {
    precondition {
      # Conditional, not `&&`: the range is null for an unknown Talos minor, and
      # reading .min off null would error before the message could be shown.
      condition = local.k8s_supported == null ? false : (
        local.k8s_minor_num >= local.k8s_supported.k8s_min &&
        local.k8s_minor_num <= local.k8s_supported.k8s_max
      )
      error_message = "talos_version ${var.talos_version} and kubernetes_version ${var.kubernetes_version} are not a supported pair. Talos ${local.talos_minor_key} either supports a different Kubernetes range, or is not in cluster/version-support.json yet — read the upstream matrix named by its _source and extend that map rather than widening it blindly."
    }
  }
}
