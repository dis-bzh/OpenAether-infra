# ==============================================================================
# Talos Machine Secrets
# ==============================================================================

resource "talos_machine_secrets" "this" {
  count = var.secrets_prevent_destroy ? 1 : 0

  talos_version = var.talos_version

  lifecycle {
    prevent_destroy = true
  }
}

# Same resource, unprotected — only instantiated when secrets_prevent_destroy
# = false (tofu test). prevent_destroy can't be a variable-driven literal, so
# the toggle is two resource blocks selected by count rather than one
# conditional lifecycle. See locals.machine_secrets below for the resolved
# reference every other resource/data source/output uses instead of
# talos_machine_secrets.this directly.
resource "talos_machine_secrets" "unprotected" {
  count = var.secrets_prevent_destroy ? 0 : 1

  talos_version = var.talos_version
}

locals {
  machine_secrets = one(concat(talos_machine_secrets.this[*], talos_machine_secrets.unprotected[*]))

  # The version a node actually RUNS comes from this installer, not from the
  # image the VM boots. Named once, and exposed as an output, so a test can
  # assert it and an operator can read it back after an upgrade instead of
  # inferring it from `kubectl`, whose node osImage lags a Talos rejoin.
  #
  # ⚠️ It decides the EXTENSIONS too, and that is how this went wrong. The plain
  # `ghcr.io/siderolabs/installer` carries none, so the schematic's extensions
  # lived only in the boot image and any reinstall dropped them. Measured on
  # Scaleway 2026-08-15: after the documented in-place upgrade every node
  # reported zero system extensions, `longhorn-manager` crash-looped on
  # "please make sure you have iscsiadm/open-iscsi installed on the host", its
  # admission webhook lost every endpoint, and `storage-backup-target` could not
  # apply — 34 of 35 Kustomizations, on a cluster whose API had never blinked and
  # whose `tofu plan` was empty.
  installer_image = var.installer_schematic_id == "" ? "ghcr.io/siderolabs/installer:${var.talos_version}" : "factory.talos.dev/installer/${var.installer_schematic_id}:${var.talos_version}"
}

# 32-byte random key for Kubernetes Secrets encryption at rest (AES-256-GCM via
# secretbox). Generated once, stable across applies (stored in tfstate).
# Applied via cluster.secretboxEncryptionSecret in the control plane config patch.
resource "random_bytes" "etcd_encryption_secret" {
  length = 32
}

# 32-byte random passphrase for disk encryption at rest (LUKS2).
# Generated once, stored in tfstate — stable across applies (Talos decrypts at boot).
# Covers: EPHEMERAL (/var — where local-path provisioner writes after remap)
# and STATE (system state, etcd DB, PKI).
# Does NOT protect against runtime compromise (the node must hold the key in RAM).
# Uses random_password (returns plain string) rather than random_bytes to avoid
# double-encoding issues with base64encode().
resource "random_password" "disk_encryption_secret" {
  length  = 32
  special = false
}

# ==============================================================================
# Client Configuration (talosctl)
# ==============================================================================

# ==============================================================================
# Endpoint resolution + delivery mode
# control_plane_endpoints lets local Docker reach nodes via port mappings while
# keeping control_plane_ips as the node identity (etcd/certSANs). Cloud leaves
# the endpoints empty, so they default to the node IPs (unchanged behavior).
# ==============================================================================

locals {
  cp_endpoints     = length(var.control_plane_endpoints) > 0 ? var.control_plane_endpoints : var.control_plane_ips
  worker_endpoints = length(var.worker_endpoints) > 0 ? var.worker_endpoints : var.worker_ips

  # Maintenance-mode apply only for cloud; Docker uses USERDATA injection.
  do_apply = var.config_delivery == "apply"

  # Container platforms need host DNS forwarding (Talos Docker platform docs).
  container_features = var.container_mode ? {
    hostDNS = {
      enabled              = true
      forwardKubeDNSToHost = true
    }
  } : {}
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = local.machine_secrets.client_configuration
  endpoints            = local.cp_endpoints
}

# ==============================================================================
# Inline Manifests — conditional injection
# Cilium is always injected (CNI is required for networking).
# Flux manifests are only injected during initial bootstrap.
# ==============================================================================

locals {
  # Cilium CNI is always required — without it, nodes cannot communicate
  base_manifests = [
    {
      name     = "cilium"
      contents = var.cilium_manifest
    },
  ]

  # Flux is only needed during initial bootstrap. On upgrades/DRP,
  # Flux is already running and manages itself via GitOps.
  flux_manifests = var.bootstrap_manifests_enabled && var.flux_manifest != "" ? [
    {
      name     = "flux-install"
      contents = var.flux_manifest
    },
    {
      name     = "flux-bootstrap"
      contents = var.flux_bootstrap_manifest
    },
  ] : []

  inline_manifests = concat(local.base_manifests, local.flux_manifests)
}

# ==============================================================================
# Worker data volumes — encrypted Talos UserVolumeConfig documents.
# One additional config document per worker_storage.volumes entry, appended to
# the worker machine config as a separate patch. Mounted at /var/mnt/<name>,
# LUKS2-encrypted with the same passphrase as the system disk (random_password).
# Skipped entirely in container mode (Docker has no block devices) and when no
# volumes are declared (e.g. local). volumeType defaults to "partition", so
# several volumes can share one data disk (selected via disk_match).
# ==============================================================================

locals {
  # Talos Layer2 VIP for the apiserver, additively merged onto whatever network
  # config the platform (nocloud static IP, DHCP, ...) already applies — only
  # `vip` is set on the interface, never `addresses`/`dhcp`. Skipped entirely
  # when unset or in container mode (no shared L2 to hold a VIP on).
  apiserver_vip_network_patch = var.apiserver_vip == null || var.container_mode ? {} : {
    network = {
      interfaces = [merge(
        var.apiserver_vip_device_selector != null ? {
          deviceSelector = { for k, v in var.apiserver_vip_device_selector : k => v if v != null }
        } : { interface = var.apiserver_vip_interface },
        { vip = { ip = var.apiserver_vip } }
      )]
    }
  }

  # machine.certSANs (apid) already covers the VIP via k8s_lb_ip when active;
  # this is cluster.apiServer.certSANs (kube-apiserver's own serving cert) —
  # needed so kubectl over a localhost SSH tunnel (127.0.0.1) and the VIP both
  # validate cleanly.
  apiserver_vip_certsans = var.apiserver_vip == null ? {} : {
    apiServer = {
      certSANs = ["127.0.0.1", var.apiserver_vip]
    }
  }
}

locals {
  worker_volume_encryption = {
    provider = "luks2"
    keys = [{
      slot = 0
      static = {
        passphrase = random_password.disk_encryption_secret.result
      }
    }]
  }

  worker_user_volume_patches = var.container_mode ? [] : [
    for v in var.worker_storage.volumes : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = v.name
      provisioning = merge(
        { diskSelector = { match = v.disk_match } },
        v.min_size != null ? { minSize = v.min_size } : {},
        v.max_size != null ? { maxSize = v.max_size } : {},
        # Talos requires minSize or maxSize — default to 1GiB when both are
        # omitted (avoids "min size or max size is required" apply errors).
        v.min_size == null && v.max_size == null ? { minSize = "1GiB" } : {},
        v.grow ? { grow = true } : {},
      )
      encryption = local.worker_volume_encryption
    })
  ]
}

# ==============================================================================
# Control Plane Machine Configuration
# ==============================================================================

data "talos_machine_configuration" "control_plane" {
  count              = var.control_plane_count
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = local.machine_secrets.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = merge(
        {
          certSANs = concat(
            ["127.0.0.1", "localhost"],
            compact([var.k8s_lb_ip]),
            var.control_plane_ips
          )
          kubelet = {
            defaultRuntimeSeccompProfileEnabled = true
          }
          features = merge({
            diskQuotaSupport = true
            kubePrism = {
              enabled = true
              port    = 7445
            }
          }, local.container_features)
          # Disk encryption at rest (LUKS2). Safe in container mode — Talos ignores
          # it when no block device is present.
          systemDiskEncryption = {
            state = {
              provider = "luks2"
              keys = [{
                static = {
                  passphrase = random_password.disk_encryption_secret.result
                }
                slot = 0
              }]
            }
            ephemeral = {
              provider = "luks2"
              keys = [{
                static = {
                  passphrase = random_password.disk_encryption_secret.result
                }
                slot = 0
              }]
            }
          }
        },
        # In container mode (Docker local testing), skip disk install.
        # Talos detects the container platform and runs without a block device.
        var.container_mode ? {} : {
          install = {
            disk  = "/dev/vda"
            wipe  = true
            image = local.installer_image
          }
        },
        local.apiserver_vip_network_patch
      )
      cluster = merge(
        {
          network = {
            cni = {
              name = "none" # Cilium injected via inlineManifests
            }
          }
          proxy = {
            disabled = true # kube-proxy replaced by Cilium
          }
          # Encrypt all Kubernetes Secrets in etcd at rest (AES-256-GCM / secretbox).
          # Key is generated once and stored in tfstate — stable across applies.
          secretboxEncryptionSecret = random_bytes.etcd_encryption_secret.base64
          inlineManifests           = local.inline_manifests
          etcd = {
            # Serve etcd's own metrics on :2381 so VMAgent can scrape them.
            # Losing quorum is the one failure a Talos cluster cannot recover
            # from on its own, and nothing else in the stack reports it: the
            # kubelet keeps saying Ready while writes fail.
            # 0.0.0.0 and not 127.0.0.1: VMAgent is a pod and reaches the node
            # by its address. The port carries NO secret (no keys, no object
            # contents).
            # Reachable node-to-node because all three providers allow the full
            # intra-cluster mesh (scw: ANY from 10.0.0.0/8 + 172.16.0.0/12;
            # ovh: remote_group_id on its own SG; outscale: protocol -1 on
            # security_groups_members) — that mesh rule is what makes the scrape
            # work at all. Not reachable from outside: each SG defaults to deny
            # and only opens 6443, 50000 and the app NodePorts, each from a
            # named source.
            extraArgs = {
              listen-metrics-urls = "http://0.0.0.0:2381"
            }
          }
        },
        local.apiserver_vip_certsans
      )
    }),
    # Our images are `metal` builds, so Talos has no cloud metadata to name the
    # node from: the name came from DHCP, and the generated config falls back to
    # `auto: stable` when a lease arrives without one. That is how a control
    # plane rebooted by `talosctl upgrade` came back as talos-xxxxx and orphaned
    # its own node object. A static hostname outranks DHCP and holds across
    # reboots, identically on every provider.
    # Two documents, not one: since Talos 1.12 the name lives in HostnameConfig
    # rather than machine.network.hostname, and `auto` and `hostname` are
    # mutually exclusive — so the generated document has to go first.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      "$patch"   = "delete"
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = "${var.cluster_name}-cp-${count.index}"
    })
  ]

  lifecycle {
    precondition {
      # Match a distinctive sentinel rather than the generic word "Placeholder",
      # so a real manifest that happens to contain that word in a comment can't
      # falsely trip the guard.
      condition     = var.control_plane_count == 0 || !strcontains(var.cilium_manifest, "CILIUM-MANIFEST-PLACEHOLDER")
      error_message = "Cilium manifest is an unrendered placeholder. Run ./scripts/bootstrap/render-bootstrap-manifests.sh (add --local for the Docker cluster) before bootstrapping."
    }
  }
}

# ==============================================================================
# Worker Machine Configuration
# ==============================================================================

data "talos_machine_configuration" "worker" {
  count              = var.worker_count
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = local.machine_secrets.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  # Base patch (machine + cluster) plus one UserVolumeConfig patch per declared
  # worker data volume (see local.worker_user_volume_patches).
  config_patches = concat([
    yamlencode({
      machine = merge(
        {
          # Same as the control plane: the node's apid cert must be valid for
          # 127.0.0.1 because Phase 2 reaches every node through an SSH tunnel on
          # localhost. Without this the tunneled apply fails TLS verification
          # ("certificate is valid for <node IP>, not 127.0.0.1").
          certSANs = concat(
            ["127.0.0.1", "localhost"],
            var.worker_ips
          )
          features = merge({
            diskQuotaSupport = true
            kubePrism = {
              enabled = true
              port    = 7445
            }
          }, local.container_features)
          # Disk encryption at rest (LUKS2). Safe in container mode — Talos ignores
          # it when no block device is present.
          systemDiskEncryption = {
            state = {
              provider = "luks2"
              keys = [{
                static = {
                  passphrase = random_password.disk_encryption_secret.result
                }
                slot = 0
              }]
            }
            ephemeral = {
              provider = "luks2"
              keys = [{
                static = {
                  passphrase = random_password.disk_encryption_secret.result
                }
                slot = 0
              }]
            }
          }
        },
        # In container mode (Docker local testing), skip disk install.
        # Talos detects the container platform and runs without a block device.
        var.container_mode ? {} : {
          install = {
            disk  = "/dev/vda"
            wipe  = true
            image = local.installer_image
          }
        }
      )
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    }),
    # Same reason as the control planes — see the HostnameConfig note there.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      "$patch"   = "delete"
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = "${var.cluster_name}-worker-${count.index}"
    })
  ], local.worker_user_volume_patches)
}

# ==============================================================================
# Apply Machine Configurations (config_delivery = "apply" only)
# The Talos provider connects to each node's endpoint on 50000/TCP. For cloud,
# endpoints = node IPs (reachable via VPC/tunnel). For Docker (config_delivery =
# "userdata") these resources are skipped — config is injected at container
# creation instead (maintenance-mode apply reboot-loops in containers).
#
# TLS note: nodes boot in maintenance mode with an ephemeral CA that differs
# from the cluster CA held in talos_machine_secrets. The provider retries the
# TLS handshake until the node transitions from maintenance → running (cluster
# CA). Two guards make this reliable on cloud:
#   1. terraform_data.talos_port_ready_* — waits until 50000/TCP is open before
#      starting the provider's retry clock (avoids burning the 15m timeout on a
#      node that is still booting → flaky bootstrap hangs on slow cloud boot).
#      ⚠️ Do not drop it: removing it once made cloud bootstrap hang
#      non-deterministically.
#   2. timeouts.create = "15m" — headroom for slow cloud boot + CA transition.
# In container mode (config_delivery = "userdata") do_apply is false → these
# resources and the config_apply resources below are all skipped (inert local).
# ==============================================================================

resource "terraform_data" "talos_port_ready_cp" {
  count = local.do_apply && !var.skip_port_ready_wait ? var.control_plane_count : 0

  # Re-run when the endpoint changes (e.g. node replacement).
  # The endpoint alone is stable across a replacement (same private IP), so a
  # rebuilt node kept a guard that had already "succeeded". rolling-replace now
  # -replaces this explicitly; the trigger stays endpoint-based for normal applies.
  triggers_replace = [local.cp_endpoints[count.index]]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/wait-talos-port.sh"
    environment = {
      ENDPOINT = local.cp_endpoints[count.index]
      NODE     = var.control_plane_ips[count.index]
    }
  }
}

resource "terraform_data" "talos_port_ready_worker" {
  count = local.do_apply && !var.skip_port_ready_wait ? var.worker_count : 0

  triggers_replace = [local.worker_endpoints[count.index]]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/wait-talos-port.sh"
    environment = {
      ENDPOINT = local.worker_endpoints[count.index]
      NODE     = var.worker_ips[count.index]
    }
  }
}

# Carries nothing but the version pair, and exists only to be referenced by the
# two `replace_triggered_by` below. See the comment on them.
resource "terraform_data" "machine_config_version" {
  count = local.do_apply ? 1 : 0
  input = "${var.talos_version}/${var.kubernetes_version}"
}

resource "talos_machine_configuration_apply" "control_plane" {
  count = local.do_apply ? var.control_plane_count : 0

  client_configuration        = local.machine_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane[count.index].machine_configuration
  endpoint                    = local.cp_endpoints[count.index]
  node                        = var.control_plane_ips[count.index]

  timeouts = {
    create = "15m"
  }

  lifecycle {
    # REPLACE on a version change instead of updating in place. Updating is what
    # trips siderolabs/terraform-provider-talos#352: when the rendered config is
    # only known during apply, the provider keeps the OLD
    # `machine_configuration_hash` in the plan and recomputes it at apply, and
    # OpenTofu rejects the difference — "Provider produced inconsistent final
    # plan", once per machine config, on every provider. A create has no prior
    # value to be inconsistent with.
    # Replacing costs nothing here: this resource's destroy is a no-op (a config
    # cannot be un-applied) and its create re-sends the same config the update
    # would have. Nodes reboot in `rolling-replace --upgrade`, never here.
    # 0.12.0, the first stable release with the upstream fix, is what the roots
    # select. Remove this only once a talos_version bump on OVH and Outscale
    # applies clean without it (#83).
    replace_triggered_by = [terraform_data.machine_config_version[0]]
  }

  depends_on = [terraform_data.talos_port_ready_cp]
}

resource "talos_machine_configuration_apply" "worker" {
  count = local.do_apply ? var.worker_count : 0

  client_configuration        = local.machine_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  endpoint                    = local.worker_endpoints[count.index]
  node                        = var.worker_ips[count.index]

  timeouts = {
    create = "15m"
  }

  lifecycle {
    # Same reason as the control plane above: upstream #352.
    replace_triggered_by = [terraform_data.machine_config_version[0]]
  }

  depends_on = [terraform_data.talos_port_ready_worker]
}

# ==============================================================================
# Bootstrap
# Triggers the initial etcd/control plane bootstrap on the first CP node.
# One-shot, and NOT idempotent — the comment here used to claim it was. Once the
# node is bootstrapped, a create returns `AlreadyExists: etcd data directory is
# not empty`, so any run whose success was not recorded in state (an interrupted
# apply, a dropped tunnel) is stuck for good against a perfectly healthy
# cluster. Recover by adopting the resource instead of re-creating it:
#   tofu import 'module.talos.talos_machine_bootstrap.this[0]' <first-cp-ip>
# In 'userdata' mode there are no apply resources to wait on — the provider
# retries connection until the (USERDATA-configured) node is up.
# ==============================================================================

resource "talos_machine_bootstrap" "this" {
  count = var.control_plane_count > 0 ? 1 : 0

  client_configuration = local.machine_secrets.client_configuration
  endpoint             = local.cp_endpoints[0]
  node                 = var.control_plane_ips[0]

  # Same 15m as the config_apply resources above, and for a sharper reason: with
  # no bound, this retried "bootstrap is not available yet" for 2h46 against six
  # billed VMs (2026-08-12) and would not have stopped on its own.
  timeouts = {
    create = "15m"
  }

  depends_on = [
    talos_machine_configuration_apply.control_plane
  ]
}

# ==============================================================================
# Health Check
# Waits for the cluster to be healthy after bootstrap.
# Validates etcd, kubelet, apid, and all nodes reporting ready.
# control_plane_nodes uses node identity IPs; endpoints use the reachable addrs.
# ==============================================================================

data "talos_cluster_health" "this" {
  count = var.control_plane_count > 0 && !var.skip_health_check ? 1 : 0

  client_configuration = local.machine_secrets.client_configuration
  control_plane_nodes  = var.control_plane_ips
  worker_nodes         = var.worker_ips
  # A single reachable endpoint is sufficient — apid checks the whole cluster
  # through it (this is how `talosctl health` works). Using all endpoints can
  # stall when some aren't directly reachable (e.g. local Docker port mappings).
  endpoints              = [local.cp_endpoints[0]]
  skip_kubernetes_checks = var.skip_kubernetes_health_checks

  # Allow ample time: a multi-CP cluster pulling Cilium/CoreDNS images on first
  # boot can take several minutes to report fully healthy.
  timeouts = {
    read = var.health_check_timeout
  }

  depends_on = [talos_machine_bootstrap.this]
}

# ==============================================================================
# Kubeconfig
# Retrieved right after bootstrap. Uses the first CP node.
# ==============================================================================

resource "talos_cluster_kubeconfig" "this" {
  count = var.control_plane_count > 0 ? 1 : 0

  client_configuration = local.machine_secrets.client_configuration
  node                 = var.control_plane_ips[0]
  endpoint             = local.cp_endpoints[0]

  # ⚠️ DELIBERATELY DOES NOT DEPEND on `data.talos_cluster_health`.
  #
  # That data source times out on healthy clusters (reproduced on OVH and
  # Outscale). While it gated the kubeconfig, an expiry failed the apply BEFORE
  # the outputs — losing kubeconfig, talosconfig and the artifact backup.
  # Decoupled, an expiry still fails the apply, so the signal is kept, but the
  # kubeconfig is already in state and `task bootstrap-phase2` resumes.
  #
  # The bootstrap obviously remains a prerequisite: apid only serves the
  # kubeconfig once etcd is bootstrapped.
  depends_on = [talos_machine_bootstrap.this]
}
