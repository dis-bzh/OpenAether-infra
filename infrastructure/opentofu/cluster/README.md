# OpenAether — OpenTofu Infrastructure

Multi-cloud Talos Kubernetes cluster provisioning. Supports Scaleway, OVH, and Outscale
with a provider-agnostic architecture via a provider contract.

## Architecture

```
tofu apply -var-file=envs/<cluster>.tfvars
  ├── Provider module (one active at a time)
  │     ├── VPC / private network
  │     ├── Control plane VMs (private IPs, multi-AZ)
  │     ├── Worker VMs (private IPs)
  │     ├── Bastion host (SSH access, public IP)
  │     ├── K8s API LB (public, 6443, ACL-restricted to admin_ip)
  │     └── App LB (public, 80/443)
  │
  ├── Talos module (cloud-agnostic)
  │     ├── Machine secrets (prevent_destroy=true)
  │     ├── Control plane config + inlineManifests:
  │     │     ├── Cilium CNI (always injected)
  │     │     ├── Flux install (bootstrap only)
  │     │     └── Flux root Application (bootstrap only)
  │     ├── Worker config
  │     └── Config apply → bootstrap → health check → kubeconfig
  │
  └── Encrypted backup → primary + replica stores
        ├── tfstate     (client AES-GCM, replicated post-apply by backup-state.sh)
        ├── talosconfig (client gpg AES-256 + SSE, by backup-artifacts.sh)
        └── kubeconfig  (client gpg AES-256 + SSE, by backup-artifacts.sh)
```

### Provider Contract

Every provider module in `modules/providers/<name>/` must implement the
[provider contract](../modules/providers/provider-contract.md). The root module's
junction point uses `coalesce()` to select the active provider's outputs.

**Adding a new provider = implementing the contract interface.** The Talos module
and junction point work without modification.

### Two-Phase Bootstrap

| Phase | Command | What happens |
|-------|---------|--------------|
| Phase 1 | `tofu apply -var-file=envs/<cluster>.tfvars` | VMs, networking, LBs |
| Phase 2 | `... -var talos_bootstrap=true` | Talos config, bootstrap, Flux |

Between phases, establish SSH tunnels via the bastion for Talos API access (port 50000).

### One-shot bring-up: `task cluster-up`

```bash
task cluster-up PROVIDER=scaleway ROLE=management  # or: PROVIDER=ovh ROLE=workload KEY=~/.ssh/yourkey
```

Chains image → render manifests → Phase 1 (`infra`) → tunnels → Phase 2
(`bootstrap-phase2`) → converge → `cluster-verify` in one command, and fails
when the verifier does; `task --summary cluster-up` has the details. Every step
is idempotent (image build skips if already published/downloaded, manifests skip
re-rendering unless `FORCE=1`, `infra`/`bootstrap-phase2` are plain `tofu apply`s) — if any step
fails, fix the issue and re-run `task cluster-up`; completed steps are no-ops. This
doesn't replace the two-phase flow above: it runs the same tasks as above, then
converges and verifies.

**Fully single-apply (`var.auto_tunnels`, EXPERIMENTAL):** set
`auto_tunnels = true` (+ `ssh_key_path`) in the cluster tfvars to collapse
Phase 1 and Phase 2 into one `tofu apply` — a `terraform_data` resource opens
the SSH tunnels itself (`talos-tunnels.sh open-direct`) between the provider
module and `modules/talos`, using node/bastion IPs unknown until the VMs
exist. Default `false`: not exercised against a real host yet, validate on a
disposable environment before relying on it. `talos_bootstrap` remains the
break-glass/two-phase path either way (e.g. for `task infra-down`).

### apiserver VIP / `k8s_lb_mode` (Scaleway, OVH)

By default the Kubernetes API is fronted by each cloud's managed LB
(`k8s_lb_mode = "managed"`). Set `node_distribution.<provider>.k8s_lb_mode = "vip"`
to drop the LB and front the API with a Talos Layer2 VIP instead — like Proxmox
always does — reserving a private address on the node network rather than
paying for a managed LB. Trade-off: the API becomes **private-only**, reachable
via the bastion SSH tunnel (`talos-tunnels.sh` opens an extra `localhost:6443`
tunnel automatically whenever `k8s_lb_ip` resolves to an RFC1918 address), not
from the public internet. Outscale rejects `"vip"` (its Net is an L3 SDN with
no ARP/broadcast domain for a floating VIP). Scaleway's `"vip"` mode is marked
experimental — validate it before relying on it in prod.

## Prerequisites

| Tool | Required for |
|------|-------------|
| OpenTofu >= 1.12.0 | Infrastructure provisioning |
| `talosctl` | Cluster access + validation |
| `kubectl` | App deployment |
| `helm` | Rendering bootstrap manifests |
| `jq` | backup-state, tunnels, teardown scripts |
| `gpg` (GnuPG >= 2.4) | Client-side encryption of the backed-up artifacts |
| `aws` (CLI) | Streaming the encrypted backups to S3-compatible stores |

**Credentials** — set them once in `.env.sh` (`cp .env.example .env.sh`, edit,
`source .env.sh`). [`.env.example`](../../../.env.example) documents every
variable; the summary:

| Scope | Variables |
|-------|-----------|
| Scaleway (compute) | `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID` |
| OVH (compute, OpenStack) | `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_ID`, `OS_REGION_NAME` |
| Outscale (compute) | `OSC_ACCESS_KEY`, `OSC_SECRET_KEY`, `OSC_REGION` |
| S3 (state + backups) | `<PU>_AWS_ACCESS_KEY_ID` / `<PU>_AWS_SECRET_ACCESS_KEY`, where `PU` = `SCW`/`OVH`/`OUTSCALE`. Scaleway & Outscale **default to their API keys**; OVH needs dedicated S3 keys. **No ambient `AWS_*` fallback** (it could silently use another provider's keys); `task` resolves these and exports `AWS_*` internally. |
| Backup replica | Nothing new: the `-backup` store is opened with the `<PU>_AWS_*` of the cloud `s3_replica_endpoint` names, so an Outscale replica reads `OUTSCALE_AWS_*`. `<PU>_BACKUP_AWS_*` only if you want that one store to have its own pair. |
| All | `TF_VAR_encryption_passphrase` (≥ 32 chars; encrypts state **and** backups) |

## Environment Files

**The model: one env file == one cluster == one separate, encrypted S3 state.**
Each file describes a single cluster (provider + role + sizing). There is no
"global" tfvars — pick the file for the cluster you are acting on. The Talos
**image** is built separately (see [Phase 0](#workflow)) and is *not* an env file.

**`<kind>-<provider>` matrix** — every kind runs on any provider (`scaleway`, `ovh`,
`outscale`). Each cluster is a single `.tfvars` (the source of truth); the S3
backend config is **derived from it** by `scripts/internal/tf-backend.sh` (no separate
backend file, so dev/prod never drift):

| Kind | Role | Template |
|------|------|----------|
| `management-<provider>` | management (hub) | `envs/management-{scaleway,ovh,outscale}.tfvars.example` |
| `workload-<provider>` | workload (spoke) | `envs/workload-{scaleway,ovh,outscale}.tfvars.example` |
| `failover-<provider>` | management (cross-provider failover) | `envs/failover-{scaleway,ovh,outscale}.tfvars.example` |

> **`failover-*` vs everyday recovery.** Re-running your own `management-<provider>`
> rebuilds the cluster on the **same** provider (fresh PKI / from state) — that's
> the routine disaster recovery. A `failover-<provider>` file is the **cross-provider
> failover**: a *second* management cluster on a **different** cloud, for when a
> whole provider is unavailable. Same role, different cloud — so use a `failover-*`
> provider that is **not** your primary.

Only the `*.tfvars.example` templates are versioned. Copy an example to its real name
(`cp envs/management-scaleway.tfvars.example envs/management-scaleway.tfvars`) and fill in
`admin_ip`, `bastion_ssh_keys`, etc. The real `*.tfvars` are git-ignored so
credentials never get committed.

> Local Docker testing (3 CP + 3 workers) is **not** an env file here — it lives in
> [`../../opentofu-local`](../../opentofu-local) (its own root, `TF_VAR_`-driven).

## Workflow

### Deploy management cluster

```bash
# Phase 0 — build the Talos image once per version (separate state, reused by all clusters)
task image-build PROVIDER=scaleway               # -> image "talos-scaleway-amd64-v1.13.3" (or PROVIDER=ovh)

# Generate bootstrap manifests (Cilium, Flux)
./scripts/bootstrap/render-bootstrap-manifests.sh

# Phase 1 — infra (IPs land in the state). The task ensures the buckets + inits the
# per-cluster backend for you. PROVIDER is required (scaleway, ovh, outscale or proxmox), and
# so is PLAN=<file from `task infra-plan … OUT=`> or APPROVE=auto.
task infra-apply ROLE=management PROVIDER=scaleway APPROVE=auto
#   manual equivalent:
#     ./scripts/internal/ensure-buckets.sh envs/management-scaleway.tfvars
#     tofu init -reconfigure $(./scripts/internal/tf-backend.sh envs/management-scaleway.tfvars)
#     tofu apply -var-file=envs/management-scaleway.tfvars -var talos_bootstrap=false
#     ./scripts/ops/backup-state.sh infrastructure/opentofu   # replicate state to the -backup store

# Phase 2 — `task bootstrap-phase2` opens the SSH tunnels (read from the state) then bootstraps
task bootstrap-phase2 ROLE=management KEY=~/.ssh/yourkey   # or: ROLE=management PROVIDER=ovh KEY=...
# (manual equivalent: open one tunnel per node per `tofu output instructions`, then
#  tofu apply -var-file=envs/management-scaleway.tfvars -var talos_bootstrap=true)

# Close the tunnels when done
task tunnels-down
```

### Deploy workload cluster

```bash
task infra-apply ROLE=workload PROVIDER=ovh APPROVE=auto
task bootstrap-phase2 ROLE=workload PROVIDER=ovh KEY=~/.ssh/yourkey
```

### Cross-provider failover — second management on another cloud

There is no failover command. `failover-management.sh` was deleted in 0.5.0: it
re-implemented `task cluster-up` with a hardcoded SSH key and its own tunnel loop, had
never been run, and a broken skeleton is a worse starting point than none. The
prerequisite — a state and artifacts replica on a SECOND provider — is real and
measured (`docs/status.md`); rebuilding a cluster from it is designed work that
has not been done. `envs/failover-*.tfvars.example` still describes the role.

### Upgrade Cilium or Flux

```bash
export CILIUM_VERSION=1.20.0
export FLUX_VERSION=v3.4.0
./scripts/bootstrap/render-bootstrap-manifests.sh
tofu apply -var-file=envs/management-scaleway.tfvars -var talos_bootstrap=true
```

### Teardown (destroy)

```bash
task infra-down-plan ROLE=management PROVIDER=scaleway    # writes destroy.tfplan; read it
task infra-down      ROLE=management PROVIDER=scaleway PLAN=destroy.tfplan
```

Manual equivalent (two steps are required):

```bash
# 1. Untrack the machine secrets first. They carry prevent_destroy (the PKI is the
#    cluster's root of trust) and are state-only (no cloud object). You cannot just
#    -exclude them either: module.talos depends_on module.scw, so excluding the
#    secrets cascades to keeping the whole provider module (0 destroyed).
tofu state rm module.talos.talos_machine_secrets.this[0]

# 2. Destroy with talos_bootstrap=false so the Talos resources resolve to count=0.
#    This skips data.talos_cluster_health, which would otherwise re-read through the
#    SSH tunnels during the destroy plan and hang if the tunnels are closed.
tofu destroy -var-file=envs/management-scaleway.tfvars -var talos_bootstrap=false
```

A later rebuild regenerates fresh machine secrets (new PKI). For a workload cluster,
swap the env file (`envs/workload-<provider>.tfvars`).

## Backup & Restore (DR)

Every DR artifact lives in **two** object stores: a **primary** (the cluster's own
provider) and a **replica** — the `-backup` store, in prod a *different* provider.
Each is opened with the `<PU>_AWS_*` credentials of the cloud that HOLDS it, named
by its endpoint. Bucket names are derived from the cluster:

| Artifact | Primary | Replica | Client encryption |
|----------|---------|---------|-------------------|
| tfstate | `s3-<project>-<provider>-tfstate-<env>` | `…-backup` | OpenTofu `encryption{}` (AES-GCM + PBKDF2) |
| talosconfig / kubeconfig | `s3-<project>-<provider>-<role>-<env>` | `…-backup` | gpg `--symmetric` AES-256 (authenticated) |

where `<project>` is `cluster_name`'s first segment (`openaether`) and `<provider>`
is the cluster's active provider (`scaleway`/`ovh`/`outscale`).

Both reuse the **same** `TF_VAR_encryption_passphrase`. Artifacts are pushed during
the Phase-2 apply (`backup-artifacts.sh`); the state is replicated **after** the
apply (`backup-state.sh` / `task backup-state`), because the backend only flushes
the new state on apply exit.

The four buckets are **auto-provisioned** (idempotent) by `task infra-apply ROLE=management PROVIDER=<p>` /
`task cluster-up` before it builds anything, and `task infra-apply` again before
`tofu init` — `scripts/internal/ensure-buckets.sh` derives their names from the
cluster's tfvars and `aws s3 mb`s any that are missing, each with its own cloud's
keys. It refuses when the replica names another provider it cannot write to, and
says which variable supplied the rejected key. Manual equivalent:
`./scripts/internal/ensure-buckets.sh envs/<cluster>.tfvars`.

```bash
# A cluster on Scaleway keeping its backups on Outscale. No SCW_BACKUP_* needed:
export SCW_AWS_ACCESS_KEY_ID=...          # the primary store
export SCW_AWS_SECRET_ACCESS_KEY=...
export OUTSCALE_AWS_ACCESS_KEY_ID=...     # the -backup store
export OUTSCALE_AWS_SECRET_ACCESS_KEY=...
# then, in the env file:
#   s3_replica_endpoint = "https://oos.eu-west-2.outscale.com"
#   s3_replica_region   = "eu-west-2"
```

### Restore a backup

```bash
# 1. Decrypt a backed-up artifact (same passphrase as the tfstate):
aws s3 cp s3://s3-<project>-scaleway-management-<env>/backups/kubeconfig.gpg - \
  --endpoint-url https://s3.fr-par.scw.cloud --region fr-par | \
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
      -d -o kubeconfig 3< <(printf '%s' "$TF_VAR_encryption_passphrase")
# (swap the bucket/endpoint for the -backup store if the primary is unavailable)

# 2. Recover the tfstate from the -backup store (primary provider down):
#    re-init against the replica bucket, then operate normally.
tofu init -reconfigure \
  -backend-config="bucket=s3-<project>-scaleway-tfstate-<env>-backup" \
  -backend-config="key=<cluster_name>.tfstate" \
  -backend-config="region=<replica-region>" \
  -backend-config="endpoint=<replica-endpoint>"
```

> Rebuilding from scratch on another provider instead? That path has no command
> yet — see the note under "Failover" above. The replica it would read from does
> exist and is verified across providers.

## Module Structure

```
modules/
├── talos/                 # Cloud-agnostic Talos cluster module
│   ├── main.tf            # Secrets, config, bootstrap, health check, kubeconfig
│   ├── variables.tf
│   └── outputs.tf
└── providers/
    ├── provider-contract.md   # Interface specification
    ├── scw/               # Scaleway (reference implementation)
    │   ├── main.tf        # Compute instances
    │   ├── network.tf     # VPC, IPAM, NAT gateway
    │   ├── security.tf    # Security groups
    │   ├── lb.tf          # K8s + App load balancers
    │   └── bastion.tf     # Bastion host
    ├── ovh/               # OVH / OpenStack
    │   └── (same structure as scw/)
    └── outscale/          # Outscale / Numspot
        └── (same structure as scw/)
```

## Tests

```bash
# All unit tests (mock providers — no cloud credentials needed)
tofu test

# Individual test suites
tofu test -filter=tests/scaleway.tftest.hcl       # SCW module
tofu test -filter=tests/talos-config.tftest.hcl   # Talos config logic
tofu test -filter=tests/provider-contract.tftest.hcl  # Junction point
tofu test -filter=tests/proxmox.tftest.hcl        # Proxmox module + VIP + image convention
tofu test -filter=tests/k8s-lb-mode.tftest.hcl     # k8s_lb_mode=vip on scw/ovh, rejected on outscale

# Full local validation
task lint && task validate && task test && task test-scripts
```

## Security

| Control | Mechanism |
|---------|-----------|
| No public IPs on nodes | Private VPC only |
| Talos API | SSH tunnel via bastion (50000/TCP, never on LB) |
| Kubernetes API | LB ACL restricted to `admin_ip` |
| State encryption | Client-side AES-GCM + PBKDF2 (backend.tf `encryption{}`) before S3 |
| Backup encryption | Client-side gpg AES-256 (authenticated) + S3 SSE; mirrored to a `-backup` store |
| Inter-node | Cilium WireGuard |
| Machine secrets | `prevent_destroy = true` lifecycle guard |
