# Threat model of the delivery chain — GitHub, Actions, Renovate, Flux, the bastion and the state

🇫🇷 [Version française](threat-model.fr.md)

> Written to answer ANSSI rules on a risk assessment of the CI/CD and delivery chain (audit id SCC/F11, the threat-model part). It is a **reasoned list of what could go wrong between a
> commit and a running node, what stands in the way today and what does not**. It is not a penetration test, and the controls it names are those present in the repository
> (read, not attacked). Runtime threats to the cluster itself are `security-architecture.md` and `network.md`; the pins and their locks are `supply-chain.md`; the patch deadline is `patching.md`.
> It claims no compliance with any ANSSI document.

## 1. The chain, and where trust is placed

```text
 maintainer ──push/PR──> GitHub (infra, apps) ──Actions──> checks, SBOM, releases
      │                       │  ^
      │                       │  └── Renovate App, Cléa (PRs, never merged by them)
      │                       └────── tags: refs/tags/<version> of apps, pinned in git_ref
      v
 operator workstation ──tofu apply / task──> provider APIs, state bucket, bastion ──tunnels──> nodes
                                                                             Flux in the cluster <── pulls apps at git_ref (public repository)
```

Trust placed, in order of how much it matters: the maintainer's GitHub account and the machine that holds `.env.sh` (everything is reachable from them); the OpenAether-apps repository at the
tag in `git_ref` (Flux applies it with cluster-wide rights); upstream releases of OpenTofu providers, Talos images, Helm charts and container images; GitHub Actions and the actions pinned in the workflows; the providers' control planes.

## 2. Assets and boundaries

The cloud accounts and the object stores; the state (it holds the Talos PKI); the apps repository (it defines what runs); the release tags (they define what a cluster tracks); the `sandbox` environment's
secrets; the operator workstation. Boundaries: GitHub (public repository, anyone can open a PR), the Actions runners (hosted, ephemeral), the maintainer's workstation, the cloud accounts, the cluster.

## 3. Threats, controls, residual risk

| # | Component | Threat | Controls in the repository | Residual risk |
|---|---|---|---|---|
| T1 | GitHub account of the maintainer | Takeover: push to main, move or publish a tag, change a ruleset | Rulesets as code (`.github/rulesets/main.json`: PR required, no force-push, linear history, required status checks; `tags.json`: no deletion, update or non-fast-forward of tags); `repo-settings.yml` compares them with the live ones daily; **zero required approvals** while there is one maintainer; admin bypass on main exists (reported as a warning) | One account is the whole control: a takeover merges and releases. Phishing-resistant MFA on the account is the owner's, not checked here. A second maintainer, required signed commits and an approval count are what would change this |
| T2 | A pull request from a fork or a stacked branch | Run hostile code in CI with a token; steal secrets | No workflow that runs on a pull request touches a cloud or a secret (0.1.0 deleted the credentialed lane; `real-cloud-regression.yml` is manual-only and in the `sandbox` environment); default `permissions: contents: read`; actions pinned to a commit SHA; the `Pipeline audit` job reads workflow files for unpinned actions, dangerous triggers (`pull_request_target`), broad permissions and weakened security jobs; `actionlint` | The pipeline audit is a pattern check, not a proof; the token of a pull-request run is real, against a public repository |
| T3 | The `sandbox` environment (manual cloud workflow) | Secrets used on a branch that was not reviewed | Required reviewers and branch limit on the environment, created by hand (`repo-settings.yml` reports its absence); dormant: the schedule is commented out | The environment is created by the owner: an absent one is only a warning while the workflow stays dormant. Keys are long-lived (no OIDC federation), scoped to a sandbox project; 90-day rotation is a target (`supply-chain.md`) |
| T4 | Renovate and Cléa | A malicious or compromised upstream release gets bumped in; the bot token is abused | Never auto-merged; 7-day release age; every bump is a PR that goes through the checks and the rung it needs; Cléa's daily report adds OSV advisories and the lag of pins; `vulnerabilityAlerts` bypass the age for fixes. `CLEA_WORKFLOW_TOKEN` (optional) is the one token that can write workflow files | A 7-day wait defeats only fast-yanked releases; a patient compromise passes. Cléa and Renovate see only pins with an anchor. The review is by the one maintainer |
| T5 | OpenTofu providers, Talos images, charts, container images | A compromised or tampered artifact reaches a node | Committed provider locks (`-lockfile=readonly`); Talos image sha256 lock (`warn` by default, `enforce` for a release build); `check-image-pins.sh` fails an `image:` with no digest; SBOM and Trivy on bootstrap images; OpenVEX register | No signature verification anywhere (cosign): a digest says "the same bytes as when pinned", not "built by the vendor". What `OpenAether-apps` deploys is its own surface |
| T6 | Flux pulling `OpenAether-apps` at `git_ref` | A hostile commit or a moved tag reaches a running cluster within the reconcile interval, applied with cluster-wide rights | The default and the examples pin an immutable **tag** (`refs/tags/<version>`), cut before the infra tag that points at it; the apps repository's tags are protected by a GitHub tags ruleset (set in GitHub, not kept as code there, so not checked from here); a branch pin is for development only and the variable's text says so | **Flux applies whatever the repository at that ref says, with cluster-admin.** No commit signature or tag verification is configured by this repository. A takeover of the apps repository, or a cluster pinned to a branch, is a takeover of the cluster |
| T7 | The bastion | Compromise of the only Internet-facing admin host: tunnels to every node's API; theft of operator keys in use | Key-only sshd, `AllowGroups`, `PermitOpen` to 6443 and 50000, `admin_ip` allowlist, optional baseline, named operators, certificates, host-key pin, closed egress; nodes still require mTLS | The bastion holds no state and no `talosconfig`, but a compromised bastion can capture the SSH-forwarded traffic of an operator session (TLS inside) and attack the nodes' APIs; shared automation key |
| T8 | The state and artifact buckets | Theft of the state (= the Talos PKI), deletion of backups, tampering | Client-side encryption (K5, K6) before upload, a second provider's replica, dated generations | No object lock, no versioning; S3 keys account-wide by default; an attacker with the keys deletes (`backup-policy.md`) |
| T9 | The operator workstation and `.env.sh` | Takeover gives every key at once | `.env.sh` is gitignored and a mode warning exists; a vault is recommended; hardware keys are optional | The single largest concentration of secrets; it is outside this repository's control |
| T10 | A malicious change to a script or a Terraform module that is reviewed but subtly harmful | A destructive apply, a leak | `prevent_destroy` on the Talos secrets; destroy needs two commands; refuse-node-deletes; plan before apply; the language, secret, dead-reference and tool-pin checks; the emulated-cloud lane | Review by one person; the checks catch classes of mistakes, not intent |
| T11 | Documentation as an attack path | A copy-pasted command that does harm | Commands in the docs are checked for dead paths (`check-dead-references.sh`) and run in harnesses where possible | A command is not tested just because it is documented: docs say which rung each reached |

## 4. What this model leaves out

Runtime threats inside the cluster (workload compromise, supply chain of the apps images) are for the apps repository; denial of service of the providers; physical access; insider threats beyond "the maintainer is the one operator";
legal and organisational measures. A second maintainer changes T1, T6, T9 and T10 the most.

## 5. Review

Re-read with each new workflow, token, secret, environment or ruleset change; when a second maintainer joins; after any incident that touched the chain; and at least yearly with the audit register (`audit-register.md`). The checks named above (`repo-settings.yml`, `Pipeline audit`, the lint) are the part that runs by itself.
