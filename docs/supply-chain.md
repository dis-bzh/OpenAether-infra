# Supply chain — what is locked, what is checked, what is only inventoried

🇫🇷 [Version française](supply-chain.fr.md)

> What stands between a hostile or broken upstream release and a node of this platform,
> and what does not. Addresses ANSSI SSDLC CICD-AIP-01c/-03, PROV-REC03, CICD-IAM-03/-05,
> CIO-REC03, SCM-REC06/-07 and SBOM25-1/-2/-3 in part. Static and mocked checks only:
> nothing here has been run against a cloud.

## Provider binaries

`infrastructure/opentofu/cluster/.terraform.lock.hcl` and `.../talos-image/.terraform.lock.hcl`
are committed, with hashes for linux and macOS on amd64 and arm64. `task validate`,
`task test` and CI run `tofu init -lockfile=readonly`: a constraint bumped without a lock
refresh fails there instead of resolving a binary nobody reviewed. Constraints in the two
roots are `~>` (minor for providers at 1.x or later, patch for 0.x ones); the modules keep
their `>=` minimums.

- **Renovate**'s terraform manager updates the lock on a provider bump (its source does, and
  `registryUrls` points it at registry.opentofu.org, where the lock's entries come from);
  not yet seen on this repository.
- **By hand:** `task lock-providers` (network, about 1 GB of `TMPDIR`, no credential).
- The locks hold the versions a fresh `tofu init` resolved on 2026-10-13. No file says which
  provider versions the clusters validated so far ran on: the first `tofu plan` after pulling
  this must show no change, and a diff there is the thing to read.
- `opentofu-local/` and `opentofu-feint/` (lab lanes) and `modules/talos` (tested alone) keep
  the old local, uncommitted lock.

## Talos boot images

The Image Factory schematic id fixes what is asked for, not the bytes returned.
`infrastructure/opentofu/talos-image/images.lock` records the sha256 of each
`<schematic>/<version>/<platform>-<arch>` raw image (Scaleway, OVH, Outscale, Proxmox, amd64
and arm64 of the version the cluster pins). `scripts/internal/verify-image-checksum.sh` runs
between the download and the conversion in the three local-exec modules.

| `image_checksum_mode` | a mismatch, or no recorded hash |
|---|---|
| `warn` (default) | printed, the build goes on: what happened before |
| `enforce` | the build stops (`TF_VAR_image_checksum_mode=enforce`, for a release build) |
| `off` | not looked at |

- A new Talos version has no line yet: `scripts/bootstrap/talos-image-lock.sh --arch amd64,arm64`
  downloads each file (about 230 MB, eight of them, about 1 GB) and records it; `--check` re-downloads and compares.
  Nothing runs it for you: a Renovate bump of the pinned Talos version turns `test-image-checksum.sh` and the
  images-lock test red until its lines are committed (the PR body says so). That is the gate working, not a flake.
- If `enforce` fails a release build on a file that has not changed upstream in any way you can see, run `--check`
  first: a regenerated artifact is a mismatch to read, and `warn` is the way back to today's behaviour.
- The same file came back byte-identical on two downloads an hour apart. Whether the Factory
  keeps serving the same bytes for months is **not known**: that is why the default is `warn`.
- Proxmox downloads server-side, so only `enforce` does anything there (the provider's
  `checksum` argument). Whether Proxmox takes that digest before or after it decompresses the
  `.zst` is **unverified**: try it on a host first. In the bpg provider (0.116) `checksum`
  forces a replacement: turning `enforce` on in a root that already holds the file plans a
  destroy and a new download of it, so read that plan, or turn it on in a fresh root. The
  `proxmox_virtual_environment_download_file` resource is also deprecated in that release
  (removed in 1.0); it is not replaced here.
- The installer reference in the machine config (`factory.talos.dev/installer/<schematic>:<version>`)
  is still a tag, not a digest.

## Images, tools and the inventory

- `task lint` fails on an `image:` in a tracked manifest with neither `@sha256` nor a digest
  recorded in `flux-image-digests.lock` (`check-image-pins.sh`). `image-digests.yml` re-resolves
  the Flux tags weekly.
- **SBOM:** `scripts/dev/gen-sbom.py` writes a CycloneDX 1.5 inventory of the tool pins
  (`# renovate:` anchors), the locked providers, the bootstrap images and the Factory images.
  The `SBOM` workflow runs it weekly and on every published release, attaches it as
  `openaether-infra-<tag>.cdx.json`, and scans each bootstrap image with Trivy (CRITICAL with a
  fix upstream fails).
- **VEX:** a finding that does not apply is recorded as an OpenVEX statement in
  `.vex/openaether-infra.openvex.json` (a purl per product, `not_affected` with a
  justification); the scan reads the file once it has a statement.
- **Not covered:** what `OpenAether-apps` deploys (charts, the other images), the layers inside
  the images (the inventory reads references, Trivy reads the layers), and signatures (no cosign
  verification anywhere yet).

## Who may run the cloud workflow, and what the keys are

`real-cloud-regression.yml` runs in the GitHub environment **`sandbox`**. Create it once
(Settings, Environments): required reviewers, deployment branches limited to `main`, and
**move the provider secrets there** from the repository secrets (the names do not change).
GitHub creates a missing environment without protection, so `repo-settings.yml` reports
one that has none (an absent one is only a warning while the workflow stays dormant).

| Credential | Where | Rotation (target, not enforced) |
|---|---|---|
| Provider API keys of the sandbox accounts | `sandbox` environment secrets | at most 90 days, and after anyone with access leaves; keys scoped to the sandbox project only |
| `CI_BASTION_SSH_PRIVATE_KEY` | `sandbox` environment secret | with the keys above; its public half in the CI tfvars |
| `TF_VAR_ENCRYPTION_PASSPHRASE` | `sandbox` environment secret | never reuses a production passphrase; a rotation re-encrypts the sandbox state |
| `CLEA_WORKFLOW_TOKEN` | repository secret, optional | a fine-grained token limited to this repository (Contents and Workflows: write) with an expiry of 90 days at most, rather than a classic one with the `workflow` scope. Not tried here: the classic token is what ran |

There is no OIDC federation to Scaleway, OVH or Outscale in this repository, so the keys stay
long-lived; short expiry and scope are the compensating measures. Bucket versioning and
policies for the state and artifact buckets are not handled here.

## Repository settings as code

`.github/rulesets/main.json` and `tags.json` are the two rulesets as GitHub returns them.
`check-required-checks.sh` (daily and on every push to main, `repo-settings.yml`) compares
them field for field with the live ones (bypass actors only when the token can read them),
checks that main requires a pull request and blocks force-push and deletion, and reports as
**warnings** what a single maintainer cannot meet yet: 0 approving reviews, no required
signed commits, and the admin bypass on main. `--strict-main` turns those into failures.
To change a ruleset: change it in GitHub, re-export it into the JSON in the same PR.
