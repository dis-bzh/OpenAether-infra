# Cléa — what this repository pins, and whether the next version survives

🇫🇷 [Version française](clea.fr.md)

> The tool itself is documented where it lives:
> [`scripts/clea/README.md`](../scripts/clea/README.md). This page is only about
> how this repository uses it — what runs, when, and what a green report is
> allowed to claim.

## Why it exists

Renovate proposes bumps here and never auto-merges them. Two things it does not
do, and neither was covered by anything else:

- **It cannot say what it is not watching.** Nine of this repository's twenty-one
  version anchors were inert when Cléa was written: the comment was there, the
  bot never read it, and nothing said so. `task lint` now fails on that.
- **It does not install anything.** A bump that lands is a bump nobody watched
  install. `scripts/dev/feint.sh` carries the evidence: the pin moved to 0.10.0
  and every machine that had already run the lane kept 0.9.0, because presence
  was checked and version was not.

Cléa answers both, and reports daily. Renovate keeps proposing the bumps —
`.github/dependabot.yml` records what happens when two bots fight over one
dependency.

## What runs, and when

| lane | when | what it exercises |
|---|---|---|
| scan + coverage | daily, 04:17 UTC | every anchor read, resolved upstream, and compared against `renovate.json5` |
| tool probes | daily | cold install and in-place upgrade of each tool that moved, in a bare `ubuntu:24.04`, then the repository's own gates (`[lane] repo` in `clea.toml`) on the bumped tree |
| local cluster | weekly, Sunday 03:41 UTC | `task local-up` on the Talos and Kubernetes pair upstream publishes, then `task local-verify`, at 1 control plane + 1 worker |
| real cloud | never | by hand, by someone watching — see [`CONTRIBUTING.md`](../CONTRIBUTING.md) |

The scan also asks when `renovate[bot]` last proposed anything. **That number
alone means nothing** — a bot with nothing to propose is silent and correct. It
becomes a signal only when crossed with what Cléa found: a dependency that is
behind *and* that the bot's own inventory can see, with no proposal for days,
means the bot is not running. That crossing went unmade here for three weeks:
helm 4.2.4 was published 2026-08-13, the scheduled window of 2026-08-17 came and
went, and nobody noticed until Cléa was written. `[report] watch_bot` and
`silent_after_days` in `clea.toml` are the whole configuration.

`.github/workflows/clea.yml` is the whole wiring. It carries no provider
credential and must fail rather than acquire one.

## Where the report is

One GitHub issue, labelled `clea`, **rewritten in place** every run — never a
new one. Its body also holds the previous run's state, in an HTML comment at the
end, which is how "this moved since yesterday" is computed without an artifact
store.

A probe pushes its branch `clea/probe/<dependency>` green **or** red: a red
branch is the reproduction, and deleting it would leave a report describing
something nobody can re-run. `clea prune` removes a branch once its bump has
landed on `main`.

## What a green report does not say

- **Nothing here has ever touched a real cloud.** A deploy on Scaleway, OVH or
  Outscale costs money and is run by hand.
- **A green probe means the tool installs and upgrades, and the repository's own
  checks still pass.** It does not mean the new version behaves the same on a
  running cluster. For Talos and Kubernetes, that is what
  [`upgrade.md`](upgrade.md) is for.
- **The weekly lane proves a pair boots on Docker at 1 + 1**, with Cilium up. It
  is not an HA test and it is not a rolling upgrade.

## Two things that will go red on purpose

- **A Cilium or Flux bump** moves a pin whose *output* is committed. The lane
  re-renders before running the gates, so the probe branch carries both halves —
  but if the render fails, `task render-check` is what says so.
- **A tool this repository does not pin** has no version to compare against, so
  its upgrade lane can only report what it found. `talosctl`, `kubectl`, the AWS
  CLI, shellcheck, yamllint, checkov and pre-commit are all in that state, and
  pinning them is a separate decision — open one if you take it.
- **`commitizen`, `opentofu/opentofu` and `siderolabs/talos`** — anchored (also)
  inside `.github/workflows/ci.yml` — fail their probe with "refusing to allow
  a GitHub App to create or update workflow… without `workflows` permission".
  Measured on this workflow's first real run, 2026-08-24. `GITHUB_TOKEN` cannot
  push that change in any repository, and no `permissions:` grant fixes it.
  A `CLEA_WORKFLOW_TOKEN` secret (classic PAT, scope `workflow`) closes it when
  set; without one, the report still names the three rather than dropping them
  silently — see "Probes that could not record a verdict" in its own section.
  A token GitHub rejects (an expired PAT) does not silence the run either:
  `scripts/clea/push-probes.sh` falls back to `GITHUB_TOKEN`, keeps pushing the
  other branches, and the report opens with a warning naming what it could not
  record. A classic PAT expires: give it an expiry you will see coming.

## Running it by hand

    task clea-scan                         # needs GITHUB_TOKEN
    python3 scripts/clea/clea.py coverage  # offline, and part of task lint

`task lint` runs `coverage`; `task test-scripts` runs Cléa's own assertions.

⚠️ GitHub disables a scheduled workflow after 60 days with no activity on the
repository. A silent Cléa is the failure this whole page is about: check the
report issue's date before trusting it.
