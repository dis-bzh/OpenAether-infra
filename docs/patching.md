# Patching policy — what is pinned, how a fix is noticed, how long it may wait

🇫🇷 [Version française](patching.fr.md)

> Written to answer ANSSI hygiene measure 34 (audit id HYG-M34): a defined update
> policy, security fixes applied within a month. It states a target and the signals
> that feed it. It is not a measurement: nothing here has been exercised on a cluster.

## The rule

A security fix released for a component this repository pins is **merged, or waived
in writing, within 30 days of its release.** Faster (target: 7 days) when the
advisory is exploited in the wild or sits on a path reachable from the internet
(Talos API, Kubernetes API, the load balancers, the bastion's sshd).

A waiver is a GitHub issue naming the component, the advisory, the reason the fix
cannot land yet and an **expiry date**; past it, the waiver is a missed deadline.

## What this repository pins

| Pin | Where | Bumped by | Applied to a cluster by |
|---|---|---|---|
| OpenTofu providers | `versions.tf`, `.terraform.lock.hcl` | Renovate | `tofu plan` / `apply`, by hand |
| Talos, Kubernetes | `variables.tf` defaults | Renovate (`cluster-version` label) | `task cluster-upgrade`, [`upgrade.md`](upgrade.md) |
| Cilium, Flux manifests | `bootstrap-manifests/` | Renovate bumps the pin, `task render-manifests` regenerates (`needs-regen`) | rendered at the next bootstrap; a running cluster follows `OpenAether-apps` |
| CI actions, pre-commit hooks, tool versions | workflows, `.pre-commit-config.yaml`, `scripts/` | Renovate | merged PR |

Components that run on the cluster (Istio, cert-manager, Kyverno, CNPG, Longhorn...)
are pinned in `OpenAether-apps`, which carries its own pins and review; this page does
not cover them.

## How a fix is noticed

1. **Renovate `vulnerabilityAlerts`** opens a PR for a pin with a published advisory,
   outside the schedule and the 7-day release age (Renovate's default for that block). It
   needs GitHub's Dependency graph and Dependabot alerts on (alerts are; the graph was not
   checked) and the Renovate App allowed to read them. `osvVulnerabilityAlerts` is
   experimental and reaches direct dependencies of a few ecosystems only (pypi, go, npm...,
   not GitHub releases, providers or images): here, at most the pip pin in a workflow.
2. **Cléa's daily report** lists advisories on the pins in force (OSV) and, since
   `max_minors_behind` in `clea.toml`, every pin more than two minor releases behind.
   A pin that far back is outside what upstream usually patches.
3. **`image-digests.yml`, weekly**, goes red when a Flux controller tag moves.
4. **`task lint`** fails on an `image:` pinned by tag with no recorded digest.

## What this does not do

- It does not apply anything: every bump is a reviewed PR, and Talos, Kubernetes and
  providers still go through the rung they need ([`CONTRIBUTING.md`](../CONTRIBUTING.md)).
- One maintainer reviews and merges: the deadline is a commitment, not a control with a
  second person behind it.
- Cléa and Renovate see what carries a `# renovate:` anchor or a manager they know.
  A component pulled in some other way is invisible to both.
