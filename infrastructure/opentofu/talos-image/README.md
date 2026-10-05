# OpenAether — Talos image builder (decoupled)

Builds the Talos boot image **once per Talos version** from the
[Talos Image Factory](https://factory.talos.dev) and publishes it into a cloud
provider, so the cluster apply can use it. Kept in a **separate state** from the
clusters — the image has its own lifecycle and is reused by every cluster/env on
that provider. Building an image **never touches deployed cluster infra**, so it
works the same before or after a cluster exists.

```
schematic.yaml ──POST──▶ Factory schematic ID
                              │
        ┌───────────────┬─────┴──────────────┬────────────────────┐
        ▼ scaleway       ▼ ovh (openstack)     ▼ outscale           ▼ proxmox
  download·zstd·qemu→qcow2 download·zstd·qemu→qcow2  (nocloud raw)   bpg download_file
        │                 │                    │                    (server-side, no
   Object Storage→snapshot Glance image         OOS staging→         local convert step)
   →Instance Image /zone   (region-wide)        snapshot→OMI              │
   (lookup by name)        → image_id (UUID)    (outscale_image)   iso_datastore_id
                                                                    (lookup by name/
                                                                     convention path)
```

Every provider now also supports a **by-name convention lookup**: when
`image_id`/`image_name`/`talos_image_file_id` is left unset in the cluster's
`envs/*.tfvars`, the cluster root falls back to the exact name/path this
builder publishes/downloads under (`talos-<provider>-amd64-<talos_version>`,
or for Proxmox `<iso_datastore_id>:iso/talos-<talos_version>-nocloud-amd64.img`)
— so the operator rarely needs to hand-copy an ID between the two roots
anymore. An explicit value in the tfvars always overrides the convention.

## State

State lives on the **target provider's** S3 — its own bucket per provider
(`s3-<project>-<provider>-talos-image`), so building one provider's image never
disturbs another's, and **one key per version**
(`talos-image-<provider>-<version>.tfstate`), so a build can only touch its own
version: building v1.14.2 never replaces v1.14.1. The state bucket (and the Scaleway
staging bucket) are **auto-created** by `scripts/bootstrap/talos-image.sh`. Proxmox has no
native object storage, so its state lives on an external S3-compatible store
(same convention as the cluster root's Proxmox backend).

### Several versions

```bash
task image-build PROVIDER=ovh LIST=1                  # the versions held, one state each
task image-build PROVIDER=ovh VERSION=<old> PRUNE=1   # destroy ONE version; refused while an envs/*.tfvars pins it
```

- **A node on an older image**: build that version, then set
  `node_distribution.<provider>.image_name = "talos-<provider>-amd64-<older>"` (OVH and
  Outscale also take `image_id`) and add the node. Nodes ignore later changes of that
  attribute. Not measured (#69): whether such a node stays on the older Talos or installs
  the pinned one at its first config; `talosctl version` on it answers. `PRUNE=1` reads
  `talos_version` only, so drop the `image_name` override before pruning that version.
- **The pre-#69 single state** (`talos-image.tfstate`) is read, never guessed: the first
  build of the version it holds copies it to that version's key and renames the old object
  to `.migrated-to-<version>` (never deleted). A build of another version leaves it alone.
  It is read off its objects, not the root output (a failed apply rewrites that).
  **A deposed or tainted object, or objects naming two versions, refuse the version it holds**
  (a copy would carry the half-finished object); no other version is blocked. To clear it:
  the account owner deletes the cloud objects it names (or accepts them as orphans), then
  `tofu state rm` each resource it names, with the root inited on key `talos-image.tfstate`
  as `talos-image.sh` does (measured on a stand-in: one `state rm` removes the tainted and the
  deposed instance together). An object naming no readable version blocks every build
  (unmeasured on older module revisions): copy it by hand (`state pull`, init on the new key,
  `state push`) and rename the old object.
- **Outscale, same-name OMI**: an OMI name is unique in the account, and CreateImage fails
  with 409 only after the 8 to 14 minute build (download, upload, snapshot import). `--ensure`
  (what `cluster-up` runs) refuses, before it, a plan that creates the OMI while one holds the
  name; a plain `image-build` still hits the 409. It asks `ReadImages` for this account's own OMIs
  (`scripts/internal/outscale-omi-ids.py`); an answer it cannot get refuses too. The provider's
  `outscale_images` data source cannot do this: on a real account it fails every plan of a name
  nobody holds. Deleting an OMI this state does not
  track, with its snapshot, is the account owner's call; the script never does. An import that
  outlived a failed apply: `talos-image.sh outscale <version> --import-snapshot <snap-id>`,
  only if that version's state already holds `build_and_upload` (else the next plan replaces
  the adopted snapshot, a second import, and the script refuses).
- **One run at a time per checkout**: runs share one `.terraform` data dir, so a second run
  repoints the first one's backend and its next plan reads the other version's state.
  Scratch files carry the version; each Outscale build needs about 11 GiB of disk.

## Prerequisites

Set credentials once in `.env.sh` (`cp .env.example .env.sh`, edit, `source`) —
[`.env.example`](../../../.env.example) is the documented, authoritative list.
What this builder needs:

- **Compute creds** for the target provider: `SCW_*` (scaleway), `OS_*` (ovh,
  OpenStack), `OSC_*` (outscale), `PROXMOX_VE_*` (proxmox).
- **S3 creds** for the target provider's Object Storage (state + staging),
  namespaced so you keep all providers in `.env.sh` at once:
  - `SCW_AWS_ACCESS_KEY_ID` / `SCW_AWS_SECRET_ACCESS_KEY` — default to `SCW_*` (Scaleway S3 == API keys).
  - `OVH_AWS_ACCESS_KEY_ID` / `OVH_AWS_SECRET_ACCESS_KEY` — **separate** keys (`openstack ec2 credentials create`), *not* `OS_PASSWORD`.
  - `OUTSCALE_AWS_ACCESS_KEY_ID` / `OUTSCALE_AWS_SECRET_ACCESS_KEY` — default to `OSC_*` (OOS == API keys).
  - `PROXMOX_AWS_ACCESS_KEY_ID` / `PROXMOX_AWS_SECRET_ACCESS_KEY` — external S3 (Proxmox has no native object storage); `PROXMOX_S3_ENDPOINT`/`PROXMOX_S3_REGION` pick the store (default: the Scaleway fr-par bucket).
  - (no ambient `AWS_*` fallback — it could silently use another provider's keys.)
- `TF_VAR_encryption_passphrase` (≥32 chars).
- Local CLI tools: `curl`, `zstd`, `qemu-img`, `aws` (installed by `task setup`).

## Usage

```bash
task image-build PROVIDER=scaleway                 # or ovh, outscale, proxmox ; [VERSION=v1.13.3]
# equivalent: ./scripts/bootstrap/talos-image.sh scaleway v1.13.3
```

- **Scaleway** — the cluster looks the image up by **name**
  (`tofu output image_name` → `talos-scaleway-amd64-<version>`), already the
  default in the `envs/*.tfvars.example`.
- **OVH** — looked up by name by default (same convention); Glance also gives a
  UUID (`tofu output image_id`) if you'd rather pin an explicit `image_id`.
- **Outscale** — looked up by name by default; the OMI registration also gives
  an `ami-…` id (`tofu output image_id`) if you'd rather pin it explicitly.
- **Proxmox** — `PROXMOX_NODE_NAMES` (comma-separated, default `pve1`) and
  `PROXMOX_ISO_DATASTORE_ID` (default `local`) control where the image lands;
  match `node_distribution.proxmox.node_names`/`iso_datastore_id` in the
  cluster tfvars. `talos_image_file_id` defaults to the resulting path.

## Customising the image

Add official system extensions in [`schematic.yaml`](schematic.yaml) and re-run.
The schematic ID is deterministic, so the build is reproducible and auditable —
and because it is derived from the content, changing this file means a new image
AND a new `installer_image`, i.e. a real upgrade of every existing node.

**Every extension here must START on every provider.** One that waits for
something a platform never supplies does not sit idle: it blocks
`startAllServices`, the boot sequence never finishes, the node never reaches
`Stage=Running`, Talos therefore never drops the META `Upgrade` tag, and the next
reboot REVERTS the node. `siderolabs/qemu-guest-agent` did exactly that on OVH
and Outscale and was removed on 2026-08-19 — the example this paragraph used to
give was the one that cost us two days. Before adding one: name the platform it
will not start on, or do not add it.

After editing, recompute the ID and update `talos_installer_schematic_id` in
`cluster/variables.tf`; `talos-image.sh` refuses to build while the two disagree.

## Providers

| `PROVIDER` | Status | Mechanism |
|---|---|---|
| `scaleway` | ✅ implemented | qcow2 → Object Storage → block snapshot import → Instance Image (per zone) |
| `ovh` | ✅ implemented | qcow2 → Glance (`openstack_images_image_v2`, local upload — region-wide) |
| `outscale` | ✅ implemented | `nocloud` raw → OOS staging → `outscale_snapshot` import (pre-signed URL) → OMI (`outscale_image`) |
| `proxmox` | ✅ implemented | `nocloud` raw.zst → `proxmox_virtual_environment_download_file` (server-side fetch+decompress, one copy per PVE host) |
