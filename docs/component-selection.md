# Component selection and the VEX register — why each part is here, how it is kept, and what we say about a vulnerability that does not apply

🇫🇷 [Version française](component-selection.fr.md)

> Written to answer ANSSI rules on the choice of components with their maintenance and security-contact criteria, and on recording the exploitability of known vulnerabilities (audit id SCC/F11, the
> component-selection and VEX parts). The choices below are the ones this repository **already made**; the "why" column is what the project's own documents say, not a fresh evaluation.
> "No third-party review recorded" means exactly that: nobody wrote one down in this repository, which is not the same as none existing. Claims no compliance with any ANSSI document.

## 1. Criteria

A component is admitted when it has (1) a way to be pinned to an exact version or digest, (2) an upstream with releases in the last year, (3) a **published channel for security advisories**, (4) a reason this project needs it that is not satisfied by something already here. It is reviewed when it falls two minor releases behind (Cléa flags this), when an advisory touches it, and at each quarterly review. A component that fails (2) or (3) needs a written exception in section 4.

## 2. Components owned by this repository

| Component | Role | Why this one (from the project's documents) | Advisory channel | Pinned in | Third-party review |
|---|---|---|---|---|---|
| Talos Linux | Node OS | Immutable, API-only, no shell or SSH (`hardening.md`); built-in LUKS2 and secretbox; one image for all providers | Talos GitHub Security Advisories and release notes | `talos_version` (`cluster/variables.tf`), image sha256 lock | none recorded |
| Kubernetes | Orchestrator | The workload platform; the version pairs with Talos (`version-pair.tftest.hcl`) | Kubernetes security announcements and the GitHub advisories | `kubernetes_version` default | none recorded |
| Cilium | CNI (a fixed base) | Network policies, WireGuard encryption between nodes, replaces kube-proxy (the two frozen bases are Cilium and Flux, `CLAUDE.md`) | Cilium GitHub Security Advisories | `bootstrap-manifests/` (rendered), Renovate anchor | none recorded |
| Flux | GitOps controller (a fixed base) | Applies `OpenAether-apps` at `git_ref`; the second frozen base | Flux GitHub Security Advisories | `bootstrap-manifests/`, `flux-image-digests.lock` | none recorded |
| OpenTofu | Provisioning | Client-side **state encryption** (`encryption{}`) which the state's protection relies on; open governance | OpenTofu GitHub Security Advisories | CLI pin (Renovate anchor) | none recorded |
| Providers `siderolabs/talos`, `scaleway/scaleway`, `terraform-provider-openstack/openstack`, `outscale/outscale`, `bpg/proxmox` | Talos, the clouds, Proxmox | One module per provider behind a contract (`provider-contract.md`) | each project's GitHub advisories; the registry | `.terraform.lock.hcl` (hashes) | none recorded |
| Ubuntu + OpenSSH + nftables + auditd | The bastion | A conventional host for the one place that must stay reachable; cloud-init is available on every provider | Ubuntu Security Notices (USN), OpenSSH release notes | the bastion image id; updates by `unattended-upgrades` or replacement | none recorded |
| gpg, `aws` CLI, `restic`... on the operator machine | Client-side encryption and S3 access | Already on every operator workstation; `setup.sh` checks for them | each project | `scripts/internal/install-*.sh` for what is installed | none recorded |
| Renovate, Cléa, gitleaks, Trivy, actionlint, shellcheck, yamllint, tflint, checkov | Dependency bumps and the checks | See `clea.md`, `supply-chain.md`, `CONTRIBUTING.md` | each project | workflows, `.pre-commit-config.yaml`, tool-pin lint | none recorded |

Components of `OpenAether-apps` (Istio, cert-manager, CNPG/PostgreSQL, OpenBao, External Secrets, Kyverno, Longhorn, Zitadel, VictoriaMetrics, Loki, Alloy, Grafana, restic) are selected and pinned there;
their end-of-support dates are in `OpenAether-apps/docs/eol-calendar.md` (apps ANSSI work). This page does not repeat them. A brick added to the platform needs a row in the apps repository's documents and a name on the watch list of `hardening.md`, section 4.

**End-of-support dates of the infrastructure pins** (Talos, Kubernetes, Cilium, Flux, OpenTofu) are not recorded in this repository: read them at the upstream support pages at each quarterly review and note any pin within six months of its end in `audit-register.md`. A supported-versions table kept here would age faster than it is read.

## 3. The VEX register

When a scanner (Trivy on the bootstrap images, the SBOM job) reports a vulnerability that **does not apply** here, we say so in a machine-readable statement instead of ignoring the finding or lowering the scanner.

- **File**: `.vex/openaether-infra.openvex.json` (OpenVEX 0.2.0). Today it holds **no statement** (version 1, written 2026-10-13): nothing has needed one yet. The weekly scan only reads it once it has a statement
  (`.github/trivy-image-vex.yaml` is what Trivy is given), because an empty file makes the scan's job harder, not easier.
- **A statement** names the product (a package URL), the vulnerability id, a status (`not_affected`, `fixed`, `affected`, `under_investigation`), and for `not_affected` one of OpenVEX's justifications
  (`component_not_present`, `vulnerable_code_not_present`, `vulnerable_code_not_in_execute_path`, `vulnerable_code_cannot_be_controlled_by_adversary`, `inline_mitigations_already_exist`) with an impact statement a reader can check.
- **Rule**: no statement without the evidence in the pull request (the code path, the flag, the configuration that makes it inapplicable); it is reviewed like code; it expires with the pin: when the component is bumped, its statements are re-read.
  A finding that applies is **not** a VEX matter: it is a patch or a written waiver with an expiry date (`patching.md`).

**Triage record** (one row per scanner finding that needed a decision; the statement itself lives in the JSON, the reasoning here or in the pull request):

| Date | Component | Vulnerability | Applies? | Decision | Evidence | Expires / re-read |
|---|---|---|---|---|---|---|
| _none yet_ | | | | | | |

## 4. Exceptions to the criteria

None recorded. A component with no advisory channel or no release in a year goes here with the reason, the compensating measure and a review date.

## 5. Review

Each quarter with the checklist (`release-checklist.md`); when a component is added, replaced or two minors behind; after an advisory that touches a row.
