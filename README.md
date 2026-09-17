# OpenAether-infra

> **Store Anywhere, Run Anywhere.**
> An idempotent Talos cluster on any environment — local (Docker), on-prem
> (Proxmox) or cloud (Scaleway/OVH/Outscale) — with one fixed foundation:
> **Cilium**. Applications are a separate choice, in `OpenAether-apps`.

🇫🇷 [Version française](README.fr.md)

## Where to go

Two different people land here, and they want different pages.

**You want a cluster.** Start with the one that needs no account and no
credentials — `task local-up` brings a six-node Talos cluster up in Docker. Then
[Quick start](#quick-start) for a cloud, or
[`docs/first-cluster.md`](docs/first-cluster.md) for the walked-through version,
bare machine to a cluster you can reach, upgrade and destroy.

**You want to contribute.** [`CONTRIBUTING.md`](CONTRIBUTING.md) has the rules
that are not obvious — what counts as proof, the three rungs a change has to
climb, and how commits made with an AI assistant are signed. The open work is
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues), and each one names the rung it
needs: `task test` and `mocked` are the ones you can close without a cloud
account.

## Version

**0.1.0** — published 2026-08-20 as a pre-release. Infrastructure only. Five
things and nothing else:
deploy, a healthy HA cluster (Talos + Cilium), idempotency, Kubernetes and Talos
upgrades, and an OpenTofu state encrypted client-side in S3 with an optional
replica on a second provider. kubeconfig and talosconfig get the same treatment.

Flux is present in the code and **off** (`deploy_flux = false`); it returns as a
user choice in a later release. Every 1.x tag and release was deleted and none
of them ever ran — **0.1.0 is the first release that ships something proven**.

**Honest status**, measured on real accounts — three clouds, the same five
pillars on each. Scaleway from an empty account on 2026-08-19: deploy 8 min 50
for 72 resources, `cluster-verify` 11/11, idempotency 3/3, Kubernetes v1.36.2
→ v1.36.3 then Talos v1.13.7 → v1.13.8, confirmed on 6/6 nodes by each node's
own Talos API. OVH the same day, Outscale on 2026-08-20. An upgrade is not
seamless: longest apiserver outage 5 s on Scaleway, 7 s on OVH, 8 s on Outscale
— all three worse than the best figures this project ever recorded, for a
reason that is not established. Proxmox has **never been applied on real
hardware**. Open items: [the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

## Architecture

```
A standalone Talos cluster (fixed foundation: Cilium)
  └── LATER, a modular pick from OpenAether-apps (scripts/pick.py):
      OpenBao, ESO, cert-manager/PKI, Istio ambient, gateway, CNPG,
      Longhorn, observability, Zitadel, Kyverno, restic backups…

OPTIONAL layer — management cluster (CAPI picked):
  Management (hub) ──CAPI+Talos──▶ client clusters (kubeception)
                    ──Flux kubeConfig──▶ Cilium+Flux injected remotely,
                    then each child reconciles ITS OWN git profile (gitception)
```

**Design principle:** the management cluster is **not** in the client data path.
If it becomes unavailable, client workloads keep running — each child has its
own Flux.

## Two ways to birth the first cluster

| Path | When | What it creates |
|---|---|---|
| **OpenTofu** (default) | Every ordinary case | The whole substrate: network, router, security groups, LB, bastion, volumes, S3 buckets — then Talos |
| **CAPI** (optional) | You want the management described like any other cluster, plus CAPI's day-2 tooling | A throwaway cluster creates the management, which then becomes self-managed (`clusterctl move`) |

The CAPI path **does not replace** OpenTofu: on OVH, OpenTofu creates ~44
resources of which only 3 are compute instances. It is an optional overlay and
**0.1.0 deploys no CAPI** — the procedure is kept for the release that does:
**[docs/capi-bootstrap.md](docs/capi-bootstrap.md)**.

## Layer status

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.13.x (immutable) | ✅ |
| **CNI** | Cilium 1.20.2 (WireGuard) | ✅ shipped, inline manifest — the whole of 0.1.0's platform |
| **GitOps** | Flux v2.9.3 | ⬜ code present, `deploy_flux = false` — returns as a choice in a later release |

Everything else — secrets, PKI, mesh, database, storage, identity, observability,
policy, Cluster API — lives in
[`OpenAether-apps`](https://github.com/dis-bzh/OpenAether-apps) and is **not
deployed by this release**. The versions this table used to list were that
repository's, and no string in this one could confirm any of them.

## Providers

One contract for all (`modules/providers/provider-contract.md`) — the
Talos/cluster stack is provider-agnostic. Details:
`docs/deployment-test-matrix.md`.

| Provider | Status | Region / target | Notes |
|----------|--------|-----------------|-------|
| **Scaleway** | ✅ five pillars measured 2026-08-19 | fr-par (3 AZs) | Reference implementation; deploy, verify, idempotency and both upgrades |
| **OVH** | ✅ the same five, the same day | EU-WEST-PAR (OpenStack) | Octavia LB, floating IPs, SNAT router, private network |
| **Outscale / Numspot** | ✅ the same five, measured 2026-08-20 | eu-west-2 | Redeployed on a **fresh Net** after an internal LBU timeout upstream left one stuck in `provisioning` (request 399530, closed). Two scars: a Net created before that fix still refuses deletion and only the provider can clear it, and the object store ignores `If-None-Match`, so the `use_lockfile` state lock is deliberately off here |
| **Proxmox (on-prem)** | 🧪 code-complete, unit-tested — **never applied for real** | PVE single/multi-host | Talos VIP (no managed LB), host nftables NAT/DNAT, manual prerequisites |
| **Local (Docker)** | ✅ validated (`task local-up`) | WSL2 / Docker | 3 CP + 3 workers, etcd quorum, Cilium — credential-free proof of `modules/talos` |

## Repository structure

```
infrastructure/opentofu/
  cluster/        # cluster root (management + workload); envs/ = one tfvars per cluster
  talos-image/    # image builder, its own state
  opentofu-local/ # local Docker root, reuses modules/talos
  modules/talos/  # secrets, config, bootstrap — provider-agnostic
  modules/providers/{scw,ovh,outscale,proxmox,local}/   # provider-contract.md = the contract
scripts/
  bootstrap/  # lifecycle (rare)
  ops/        # day to day: fleet-down, edge-down, rolling-replace, etcd-snapshot,
              # preflight-quotas, check-cilium-parity, purge-orphans…
  internal/   # called by the Taskfile
```

Kubernetes manifests live in
[dis-bzh/OpenAether-apps](https://github.com/dis-bzh/OpenAether-apps).

## Quick start

> **First time here?** Read **[docs/first-cluster.md](docs/first-cluster.md)**
> instead — the same path, step by step, with every value you must supply, what
> each command creates, what tells you it worked, and an honest list of what is
> not proven yet. What follows is the short form for someone who has done it.

### Prerequisites

```bash
./scripts/setup.sh          # tofu, talosctl, kubectl, task, helm, yamllint…

# CLOUD only — local testing needs no credentials at all.
cp .env.example .env.sh     # then edit it
source .env.sh              # git-ignored; also holds TF_VAR_encryption_passphrase
```

⚠️ **Always `source .env.sh` before any cloud-facing `task`.** Without it,
`tofu` prompts interactively for `var.encryption_passphrase` and the command
fails — including a teardown, which can then *look* successful while destroying
nothing.

### Local cluster (Docker — no cloud, no credentials)

Brings up a real **3 control plane + 3 worker** Talos cluster in Docker, on the
**same `modules/talos/` used in production**. Best first step.

```bash
task local-up        # full deploy
task local-status    # etcd members + nodes + Flux
task local-down      # tear down (containers + volumes + state)
```

⚠️ **On Windows/WSL2**: Hyper-V reserves blocks of ports above 49152, and those
blocks move across reboots. The host port base is therefore configurable
(`talos_api_port_base`, default 45000). Diagnose with
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

### Management cluster (cloud)

```bash
source .env.sh

cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \
   infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
```

Six fields have no default and the deploy will not start without them. Everything
else in the example already has a working value.

| field | what to put in it |
|---|---|
| `environment` | `dev` or `prod` — nothing else is accepted. It names the buckets and the resources, and `prod` additionally requires `s3_replica_endpoint` to be a **different** provider |
| `admin_ip` | your public IP as a CIDR. It is the SSH allow-list AND the apiserver LB ACL |
| `s3_primary_endpoint` / `s3_primary_region` | S3 for the encrypted tfstate, on the **same** provider as the cluster (e.g. `https://s3.fr-par.scw.cloud` / `fr-par`) |
| `s3_replica_endpoint` / `s3_replica_region` | S3 for the **backup copy**. In production put it on a **different provider** — a state you can only read from the cloud that just failed is not a backup. It is opened with THAT cloud's `<PU>_AWS_*` keys, so an Outscale replica reads `OUTSCALE_AWS_*` |

Also `bastion_ssh_keys`: the **public** half of the key you will pass as `KEY=`.
They are a pair, and `task cluster-up` refuses to start if they do not match — before it
spends anything. And `git_repo_url` + `git_ref` if you run your own fork of
OpenAether-apps; the defaults point at ours, and its `apps/clusters` is not yours.

```bash
# Quotas: OVH and Outscale only — the script does not cover Scaleway.
# On Scaleway, check the console: 3 control planes + 2 workers needs 5 instances
# of the type in your tfvars, and a new account may be capped at 1.
task preflight-quotas PROVIDER=ovh

task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
task cluster-verify PROVIDER=scaleway               # ask the cluster, not the tool
```

`task cluster-up` is the one command, and it is idempotent: it builds the Talos image if
the account lacks it, renders the bootstrap manifests, applies the
infrastructure, opens the tunnels and bootstraps Talos. Re-run it after fixing
any failure and it resumes. It is also the command CI runs, so it is the path
that gets validated. The individual steps (`task image-build`, `task infra-apply`,
`task bootstrap-phase2`) still exist for when you want to drive one of them
alone.

**After deployment**: `task cluster-verify` is the whole day-1 path for an
infrastructure-only cluster. The application platform's own — escrow, offline
PKI signing, UI access — is [docs/admin-access.md](docs/admin-access.md), and it
belongs to the release that deploys applications.

### Teardown

Two commands, always, and no flag collapses them into one.

```bash
source .env.sh
task cluster-down PROVIDER=ovh                                    # computes, destroys nothing
task cluster-down PROVIDER=ovh PLAN=destroy-management-ovh.tfplan APPROVE=auto
python3 scripts/ops/purge-orphans/ovh.py    # dry-run: confirm nothing is left
```

Same vocabulary as `cluster-up`. `fleet-down` still rules out CAPI children
first, but it now reads why the query failed: absent CRDs mean there are none by
definition, and it says so. `--force-no-edges` remains as an escape hatch for a
cluster it cannot reach at all.

⚠️ Floating IPs pre-allocated outside OpenTofu do not disappear on their own.

### Emulated cloud (Feint — no cloud account, no credentials)

Points the **real** Scaleway and Outscale providers at a local emulator of their
APIs. One step past the mocked `tofu test`: real HTTP, real decode, no bill.

```bash
task feint-up                        # start the emulator (pinned binary, checksum-verified)
task feint-plan   PROVIDER=scaleway  # plan the REAL cluster root, zero credentials
task feint-apply  PROVIDER=outscale  # apply/destroy cycle on the reduced fixture
task feint-record PROVIDER=scaleway  # rank the operations we call that no pack serves
task feint-down
```

⚠️ It does **not** prove a real deployment works — the emulator has no
inventory, no load balancer and no quotas. See
[docs/emulated-cloud.md](docs/emulated-cloud.md).

### Static checks (no cloud, no Docker)

```bash
task validate            # tofu fmt/validate/test
task apps-validate       # Flux DAG integrity + pick.py profiles up to date
task security            # hardening checks
```

## Documentation

| File | Contents |
|---|---|
| [docs/first-cluster.md](docs/first-cluster.md) | **Start here.** Bare machine to a cluster you can reach, upgrade and destroy — and what is not proven |
| [docs/admin-access.md](docs/admin-access.md) | Day-1 path for the application platform: escrow, offline PKI, UI access, browser tests. **Not needed for an infrastructure-only cluster** |
| [docs/capi-bootstrap.md](docs/capi-bootstrap.md) | Bootstrap a management via CAPI and make it self-managed |
| [docs/deployment-test-matrix.md](docs/deployment-test-matrix.md) | What is validated, where, and how |
| [docs/emulated-cloud.md](docs/emulated-cloud.md) | Testing Scaleway/Outscale against a local emulator — and the limits of that |
| [docs/upgrade.md](docs/upgrade.md) | Moving Kubernetes and Talos on a cluster that has to stay up |
| [docs/release-checklist.md](docs/release-checklist.md) | What to run before tagging a release, in the order that fails cheapest |
| [docs/status.md](docs/status.md) | **Source of truth**: current state, debt, improvements (English only — living working document) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | **Read before a first pull request**: what counts as proof, the three rungs, commit trailers, AI-assisted contributions |

## Security

| Control | Implementation |
|---------|----------------|
| No public IPs on cluster nodes | VPC-only, bastion SSH tunnel |
| Bastion SSH | Dedicated unprivileged user, key-only (root login and passwords disabled) |
| State encryption | Client-side AES-GCM + PBKDF2 (`encryption{}`) before S3 |
| Artifact encryption | Client-side authenticated gpg AES-256, plus S3 SSE on top |
| Replication / DR | State and artifacts mirrored to a `-backup` store (prod: a different provider, separate credentials) |
| Kubernetes API access | LB ACL restricted to `admin_ip` |
| Talos API access | SSH tunnel only (port 50000, never on the LB) |
| Inter-node encryption | Cilium WireGuard |

## Roadmap

| Release | Deliverable | Status |
|---------|-------------|--------|
| **0.1.0** | One Talos cluster + Cilium on Scaleway, OVH or Outscale, encrypted state and artifacts, in-place upgrades | ⏳ first release |
| next | Flux back as a user choice, then the modular pick from `OpenAether-apps` | ⏳ planned |
| later | CAPI overlay: a management cluster driving children | ⏳ planned |
| open | Proxmox on real hardware, the full cross-provider failover, the Outscale Net only the provider can delete | ⏳ |

## License

**OpenAether** is licensed under the
[Apache License 2.0](LICENSE). It was AGPLv3 earlier in its history; the change is a
relaxation, so anything you already had under AGPLv3 stays yours under it.

Source: **https://github.com/dis-bzh/OpenAether-infra**
