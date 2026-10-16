# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security vulnerability. Use
[GitHub's private vulnerability reporting](https://github.com/dis-bzh/OpenAether-infra/security/advisories/new)
for this repository instead — it's enabled (checked daily by
`.github/workflows/repo-settings.yml`) and reaches the maintainers directly.

We'll acknowledge within a few days and keep you updated while we investigate
and fix.

## Scope

This repo provisions infrastructure (OpenTofu) and bootstraps a Talos/Kubernetes
cluster. Findings of interest: secrets or credentials committed to the repo,
supply-chain issues in pinned dependencies (GitHub Actions, pre-commit hooks,
container images), and IaC misconfigurations that would weaken a deployed
cluster.

## Operating a security incident

Reporting a vulnerability (above) is not operating an incident. For a suspected compromise of a cluster (a leaked kubeconfig, passphrase or
key, a departed operator, an unexplained login), the ordered procedure is [`docs/incident-response.md`](docs/incident-response.md): evidence first, backups
protected, then containment, rotation and restore. The rest of the security documentation, each with a French twin:

| Page | What it is |
|---|---|
| [`docs/key-management.md`](docs/key-management.md) | Every key, its period, impact if lost or leaked, replacement and erasure |
| [`docs/backup-policy.md`](docs/backup-policy.md), [`docs/disaster-recovery.md`](docs/disaster-recovery.md) | What is copied and what is not; the ordered recovery chain and the drill |
| [`docs/security-architecture.md`](docs/security-architecture.md), [`docs/network.md`](docs/network.md) | Administration paths and accounts; zones, CIDRs and the flow matrix |
| [`docs/hardening.md`](docs/hardening.md), [`docs/patching.md`](docs/patching.md) | Baseline and written deviations; the patch deadline and the watch routine |
| [`docs/threat-model.md`](docs/threat-model.md), [`docs/component-selection.md`](docs/component-selection.md), [`docs/audit-register.md`](docs/audit-register.md) | The delivery chain's threats; why each component, and the VEX register; audits and corrective actions |

These are documents written from the code; none of the procedures has been drilled on a cluster, and nothing in them claims compliance with any standard.
The application layer's side (OpenBao, the application keys) is in `OpenAether-apps`.
