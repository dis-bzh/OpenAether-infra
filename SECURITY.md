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
