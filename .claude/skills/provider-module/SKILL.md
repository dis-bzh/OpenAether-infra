---
name: provider-module
description: Adding or changing a cloud/on-premise provider module in OpenAether-infra (scw, ovh, outscale, proxmox). Use when touching modules/providers/**, adding a provider, or debugging why one behaves differently from another.
---

# Provider modules

The contract is
[`modules/providers/provider-contract.md`](../../../infrastructure/opentofu/modules/providers/provider-contract.md).
Implement it; do not restate it here. The rest of the stack — `modules/talos`,
`cluster/` — is provider-agnostic and must not change to accommodate a provider.

## What differs between providers, and has bitten

- **ForceNew is not portable.** Changing an instance's image replaces the VM on
  Scaleway and rebuilds the disk in place on OpenStack. A "rolling replace" that
  assumes one behaviour silently does nothing on the other.
- **Node naming has no common source.** These are `metal` images, so Talos has no
  cloud metadata and took its name from DHCP — which is why a reboot renamed
  nodes. Names are pinned in a `HostnameConfig` document now; a new provider
  inherits that and must not reintroduce a platform-specific name.
- **Ordered list attributes.** Octavia returns `allowed_cidrs` sorted; sending it
  unsorted made every plan propose the same no-op update, so OVH was never
  idempotent. When an attribute is a list, ask what order the API returns.
- **Quotas are a design input.** Outscale's 40 GB RAM quota does not fit 3+3, so
  the documented HA topology is unreachable there. `task preflight-quotas` exists
  to say so before the bill, not after.

- **Credentials belong to the cloud that HOLDS the bucket**, not to the cluster's
  provider. Namespacing them the other way makes the variable name argue for the
  wrong value — and it gets one.
- **Outscale `region` ≠ subregion.** `eu-west-2a` in the credentials secret builds
  an API host that does not resolve. Use `eu-west-2`.

## The image lane

`task image-build PROVIDER=<p>` builds and publishes. All three clouds resolve
the image by **name**; `image_id` in `envs/*.tfvars` is an optional override on
OVH and Outscale, and a stale-prone one (`talos-image.sh` refuses it when stale).
The version comes from `scripts/internal/talos-version.sh` — one source, because
two drifted once and `task cluster-up` built an image the cluster then refused to
find.

The lane keeps **one state per version** (`talos-image-<p>-<v>.tfstate`), so a build can only
touch its own version; `LIST=1`, `PRUNE=1`, `RETAIN=1` (the two highest stay) and the Outscale same-name refusal are in
`infrastructure/opentofu/talos-image/README.md`.

A boot image is the medium a node **installs from**, not the version it runs:
node resources ignore that attribute on purpose. Re-imaging is deliberate, via
`rolling-replace` with an explicit `-replace`.

**An OMI's backing snapshot is immutable.** The image must be replaced together
with the snapshot it is built on (`replace_triggered_by` + `create_before_destroy`),
or the destroy order 409s and the account is left with no bootable image.

## Done means exercised

`CONTRIBUTING.md`'s rungs, and a module change is not done at the mocked
one. Two faults in `rolling-replace` were invisible until a *second* provider ran
it, and a third until workers were rolled and not just control planes. If you
only ran one provider or one node role, say which.
