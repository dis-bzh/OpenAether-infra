# Support policy — which versions, which providers, what one maintainer can promise

🇫🇷 [Version française](support.fr.md)

> Written for 0.6.0 (owner decisions of 2026-11-20). For each claim, the rung it reached (mocked, emulated, local Docker, real
> cloud). There is one maintainer, and a limit written here is a limit, not a roadmap. Figures and dates live in [`status.md`](status.md), not here.

## 0. Default: no guarantee, no support

OpenAether is an open-source project. **By default the maintainer guarantees nothing and provides no support**: no response time, no fix
commitment, no backport. Issues and pull requests are welcome and read when time allows. Sections 1 and 2 are the policy
that **applies only if a paying customer or user exists**; until then they describe what the project does and measures, not what it owes anyone.
The licence ([`LICENSE`](../LICENSE)) says the rest.

## 1. Versions: N and N-1 only (conditional policy)

If a paying customer or user appears, support is limited to N and N-1. Before 1.0.0 a "version" is a release tag, not a minor. N is the latest tag, N-1 the one before it (with 0.5.1 out, N-1 is 0.5.0).

| | What you can expect |
|---|---|
| **N** | Bugs that reproduce are fixed on `main` and ship in the next tag. A security fix for a pinned component follows the deadline of [`patching.md`](patching.md) (30 days, 7 when exploited or internet-reachable). |
| **N-1** | Supported as the **source of an upgrade**: the section "From N-1 to N" of [`upgrade.md`](upgrade.md) is the path. No backport branch exists: a fix reaches an N-1 install by upgrading to N. A backport is the maintainer's choice, never a promise. |
| **Older** | Unsupported. No path is built or documented; go through each release in turn, or rebuild. When N+1 ships, N-1 stops being supported the same day. |

- **Pairing.** Infra N pairs with OpenAether-apps N (the `git_ref` default and the examples). Mixed pairs are not supported.
- **Kubernetes and Talos** move inside the window `cluster/versions-guard.tf` accepts; an unsupported pair is refused at plan time. Rung: mocked.
- **Reviewed at 1.0.0.** Until then the policy may tighten, never silently loosen.
- **Rung of the paths.** Each "From x to y" section of `upgrade.md` says its own. The last one, 0.5.0 to 0.5.1, was read on a cluster built on `main`
  and moved to the fix branch, **not** a 0.5.0 install moved to the tags (`CHANGELOG.md` `[0.5.1]`). Real cloud, n=1.

## 2. Providers: tiers (what has been measured; a promise only under section 0's condition)

- **Supported**: built from an empty account on real hardware, `cluster-verify` green, a roll or upgrade read. Under section 0's condition, a bug that reproduces is fixed.
- **Constrained**: it runs, with a written limit that stops it carrying the full platform. Issues are read; no promise on the full platform.
- **Unsupported**: the code exists, nothing real has run. Reports are welcome, not fixed on a schedule.

| Provider | Tier | Why, and what is open | Rung |
|---|---|---|---|
| Scaleway | **Supported** | Install from empty (lab 0.5.1 L1, 2026-11-15, 715 s), upgrade 1.36→1.37 and Talos 1.13→1.14 (2026-10-03), the apps commit pin (lab 0.5.2, 2026-11-18). A control-plane roll cuts the API about 55 s (#42); a database primary in a lost zone takes about 2 min (#390). | real cloud, n=1 per figure |
| OVH | **Supported** | Install from empty (lab 0.5.1 L2, 2026-11-16, 706 s), upgrade (2026-10-03), worker replacement with 0 failed API probes of 1632. A node can stay `ACTIVE` while dead until a hypervisor reset, an OVH-side cause (#49). The 24 h Kyverno soak (#183, #83) has not run. | real cloud, n=1 per figure |
| Outscale | **Constrained** | The account quota is 20 vCPU. Install returns rc 0 (lab 0.5.1 L3, 2026-11-16) but under the full platform one worker became unusable and the first seed timed out (#376, open); no nominal install figure exists. A Net that will not delete is with Outscale support (#43). | real cloud, once, degraded |
| Proxmox | **Unsupported** | Never applied on real hardware (#48, #201). Tests are mocked; Feint has no Proxmox emulation. | mocked only |

Not covered by any tier: the `workload` role on any cloud, `deploy_flux = true` beyond the labs above, and the CAPI management overlay. The overlay
is optional and its child-cluster lifecycle has never run (apps #222). Not proven: an unattended run of any lane.

## 3. Escrow: one holder, for now

No customer is served today, so this is a limit of the project, not a breach of any commitment.

- **Break-glass** (`system:masters` kubeconfig, talosconfig, artifact passphrase, K6): one holder, the owner. Decision of 2026-11-17 (#331), recorded in [`admin-access.md`](admin-access.md).
- **Seal-key escrow** (`task escrow`) is designed for two custodians and says so when it has one ([`key-management.md`](key-management.md), "Escrow: how many custodians").
- **A second holder will be named later by the owner.** Until then: the loss or unavailability of that one person is the loss of the escrow, and the release notes say so.
- Rung: documented. `task escrow` is mocked-tested; no recovery from the escrow has been drilled on a cluster.

## 4. What a release publishes, and how to check it

Every release carries, in its notes, the **full SHA of the release commit** (the squash-merge on `main` the tag points at) and the **full SHA of the
OpenAether-apps tag** that `git_ref` pins. A tag can be force-replaced upstream; a SHA cannot. `check-release-tag.sh --apps-sha` refuses notes without them and
`release-tag.yml` repeats the check; the 0.5.1 notes name both. To verify:

```bash
git verify-tag <tag>                  # key: docs/signers/release-vps.asc, fingerprint against signers.txt
git rev-parse <tag>^{commit}          # must equal the SHA in the notes
```

To pin by SHA, set `git_commit` (40 hex) beside `git_ref` ([`supply-chain.md`](supply-chain.md)). Rung: the check is mocked
(`test-check-release-tag.sh`); the pin was read once on a real cluster (Scaleway, 2026-11-18, n=1). **Not covered:** moving a running cluster to a commit
(`cluster-apps-ref` ignores it), and a signature on the SBOM or on the images (no cosign verification anywhere).

## 5. CVE and VEX process

1. **Notice.** Renovate vulnerability alerts, Cléa's daily report, the weekly and per-tag `SBOM` workflow (Trivy: a CRITICAL with a fix fails the scan job). See [`patching.md`](patching.md).
2. **Clock.** 30 days to merge or waive in writing, 7 when exploited (CISA KEV) or reachable from the internet.
3. **Decide, one finding at a time**, and write which: (a) **fix**: pin the fixed digest; (b) **waive** with a VEX statement; (c) **hold** the release. A waiver
   needs a reading of the image and of its exposure with its limits stated, not an assumption.
4. **Record a waiver** in `.vex/openaether-infra.openvex.json`: scoped to the image digest, `not_affected` with a justification, an
   `action_statement` saying what removes it, `Expires:` at most 90 days out, and an issue tracking it. The owner accepts it; the maintainer does not accept their own.
5. **Release.** A red scan does not stop the SBOM asset from being attached: the notes list every red scan and every live waiver with its expiry.
6. **Renew or drop.** Past its expiry a waiver is a missed deadline. Re-read the image and extend, or drop it when a fixed digest is pinned.

Rung: written, exercised once (CVE-2026-123158 on the Flux kustomize-controller image, noticed 2026-11-10, waiver recorded 2026-11-15, expires 2027-01-09, #455).
**No check enforces `Expires:` yet**: today it is read by a person at each release.
