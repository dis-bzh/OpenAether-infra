# Contributing

Several rules below are adapted from
[Feint's `CONTRIBUTING.md`](https://github.com/stephrobert/feint/blob/main/CONTRIBUTING.md),
met while wiring the emulated-cloud lane. Read it there for the reasoning at
length; kept here is what transfers to an infrastructure repository.

## Issues, and what they are not

**Issues are for what you hit** — a deploy, a task or a manifest that did not do
what it says. Reports from outside are welcome and outrank our own list: the
order in the backlog is a guess about what matters, something that broke on
somebody is a fact.

**Our own work is not in issues.** It lives in
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues), where every one names the command that
would close it. Keeping the two apart is the point: a working list wants to be
read offline, in one file, at the start of a session; an intake wants to be
where a stranger can reach it. Duplicating one into the other would give us two
records that disagree.

Never put a real IP, a cloud account id or a bucket name in an issue. The
repository is public and has had to purge its history once for that.

## Setup

    task setup      # installs OpenTofu, talosctl, kubectl, Task, pre-commit
    pre-commit install

**`pre-commit install` is a real step, not a courtesy.** Git hooks live in
`.git/hooks/`, which is not versioned, so a fresh clone has none of them however
complete `.pre-commit-config.yaml` looks. It installs two hook types —
`pre-commit` and `commit-msg` — declared through `default_install_hook_types`,
so the single command is enough.

## The one rule

**A change to a provider module is not done until something real exercised it.**

A mock asserts what we believe a provider does. The provider binary asserts what
it actually does. Three rungs, and a PR says which one it reached — and says
explicitly what could not be run:

| Rung | Command | What it proves |
|---|---|---|
| Mocked | `task test` | The graph resolves and the assertions hold. The provider binary never speaks. |
| Emulated | `task feint-plan` / `task feint-apply` | The real provider binary, real HTTP, zero credentials — over the subset the emulator serves. See [`docs/emulated-cloud.md`](docs/emulated-cloud.md). |
| Real cloud | `task cluster-up` | The only proof a deployment works. Costs money, so it is not required of every PR — saying you skipped it is. |

The credentialed rung has no CI lane: it is run by hand, by someone watching.
The workflow that was meant to automate it never reached a deploy and was
deleted for 0.1.0 rather than left cronning red — the history is on the
`archive/staging-lane` branch. **No workflow may run cloud credentials on a pull
request**: GitHub withholds secrets from fork PRs on purpose, and
`pull_request_target` would run a stranger's code with this repository's
credentials. Before a release, `docs/release-checklist.md` says what to run by
hand and in what order.

"The tests should pass" is not a rung.

## Before opening a PR

    task lint         # tofu fmt, yamllint, tflint, actionlint, language, version drift, pin coverage
    task validate ROOT=cluster
    task validate ROOT=talos-image
    task test

All four run in CI too — a PR can't merge until they're green (see the required
checks on `main`). `task feint-test` also runs there, on both providers. A new
job that reports on PRs must be added to those required checks too, or
`scripts/dev/check-required-checks.sh` turns `repo-settings.yml` red.

Before touching the Flux DAG in the sibling `OpenAether-apps` repo:

    task apps-validate

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), scope by
area (`feat(outscale):`, `fix(talos):`, `chore(deps):`). Checked twice by the
same tool: the `commit-msg` hook refuses a subject as you write it, and the
`commits` CI job checks every subject a PR adds — because a hook lives in
`.git/hooks/`, which no clone carries.

    cz check --rev-range origin/main..HEAD   # what CI will say

## Conventions

- English for code, comments, commit messages and docs (`*.md` is canonical,
  `*.fr.md` is a translation, never the source). `task lint` runs
  `scripts/dev/check-language.sh`, which reads prose only — Markdown outside
  code fences, comment lines in code — and keys on French *words* rather than
  accents, because accent-free French is what the last three sweeps left behind.
  `.languageignore` lists what is French on purpose, one reason per entry.
- Environment data — a real IP, an account id, a bucket name — is caught by
  `.gitleaks-envdata.toml` on what a PR adds. The credential rules gitleaks
  ships do not look for any of it, and that is exactly what leaked here once.
  The file is deliberately not named `.gitleaks.toml`: that name is auto-loaded
  from the repository root, which would put these rules on the full-history and
  whole-tree scans too, where every hit is a synthetic fixture.
- Comments explain the *why*, not the *what* — 1-3 lines, no incident narratives.
- Open work items live in the GitHub issues, not scattered TODOs — read them before
  starting non-trivial work, and drop an entry once it's done (that's what git
  history is for). Write an entry as **the symptom, not the diagnosis**: the
  diagnosis is often wrong when the entry is written, and the entry outlives it.
  **Write `closes #N` only when the merge closes it**: GitHub reads "close", "fix"
  or "resolve" + `#N` anywhere in a PR body or commit message, prose included —
  "a real roll is what closes #55" closed #55 on a mocked-rung merge.
- Dependency bumps (OpenTofu providers, Talos, Kubernetes, Cilium, Flux, CI
  actions, pre-commit hooks) are proposed by Renovate and never auto-merged —
  review the diff, especially anything labeled `needs-regen` (the pinned version
  bumped but a vendored manifest needs regenerating by hand) or
  `vendored-manifest`. **A new pin needs an anchor**: the
  `# renovate: datasource=… depName=…` comment on the line above the value.
  `task lint` fails on a pin no inventory watches — nine of them were inert
  once, and an unwatched pin looks exactly like a healthy one. See
  [`docs/clea.md`](docs/clea.md).

## AI-assisted contributions

Welcome, under one condition, and the condition is not about AI: **bring the
evidence, not the intention.** A PR claiming it fixes the Outscale egress path
and showing no run is refused whoever wrote it.

**Disclose it** with the `Assisted-by:` git trailer, naming the tool — the
convention the Linux kernel, Fedora, Mesa and QGIS converged on. It exists so a
future reader of `git log` knows what to re-check.

    feat(outscale): two-subnet egress plan

    Assisted-by: Claude Code

No model version: the sessions that write these commits run under a harness
that forbids a model identifier in anything pushed or posted, so the trailer
stays tool-only here. This narrows the upstream convention rather than
breaking it — `checkpatch.pl` treats the value as free-form and only warns
when it is empty; naming the model was never a hard requirement there either.

`Co-Authored-By` and `Signed-off-by` from a tool are **forbidden**: those
trailers assert authorship and certify origin, and a model can do neither. The
human submitting is the author and takes responsibility for every line,
licensing included. Refused by the `commit-msg` hook and again in CI, which
scopes itself by the tree — a commit is checked only if
`scripts/dev/check-commit-trailers.sh` already existed in it, so history from
before the rule does not fail the build. Skip the trailer entirely
for spelling, formatting, or a completion that saved three keystrokes.

**Run it before you send it** — the rungs above, and say which one.

**Do not send what you have not read.** The failure mode here is not bad code,
it is confident code against an API nobody checked: a plausible attribute name
the provider's schema does not define, with a mock test asserting the invention
— and a mock will assert anything. If you cannot say where an attribute came
from (the provider's schema, its documentation, or a run), do not send it. "The
model produced it" is not a source.

### Refused on sight

- A change to a provider module with no run of any rung, that says so or shows it.
- A batch across several providers with no single reviewable claim.
- A real IP, cloud account id, or any environment-specific value outside the
  gitignored `envs/*.tfvars`. The repository is public and has had to purge its
  history once — see `CLAUDE.md`.
- Anything justified by a metric — resource count, coverage — rather than by
  what it unblocks.

## Pull requests

`main` requires a PR with all CI checks green — including for maintainers, no
direct pushes. No mandatory reviewer count yet (small team), but PRs stay open
for review during that window regardless.
