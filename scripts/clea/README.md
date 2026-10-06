# Cléa

Watch what a repository pins, and prove a bump before anyone merges it.

Cléa answers three questions every day, and it answers them about **any**
repository — it holds no knowledge of the project it runs in:

1. **What has moved upstream** since the pins in this tree were written.
2. **Is anything pinned that nothing watches** — an anchor a bot cannot read is
   a pin nobody will ever bump, and it looks exactly like a healthy one.
3. **Does the bump survive** being installed from cold, and being upgraded over
   the version that was already there.

It does **not** open bump pull requests. Renovate or Dependabot already do that,
and two bots proposing the same bump is a collision worth avoiding. Cléa
watches, probes, and reports.

## Dropping it into another repository

Copy `scripts/clea/`, write a `clea.toml`, and wire the workflow. Python 3.11 or
newer, standard library only — no `pip install` anywhere in the path, which is
what lets the probes run inside a bare container.

```
scripts/clea/clea.py      the engine
scripts/clea/probe.sh     the two container lanes
clea.toml                 the only file that knows about your project
```

## The inventory is the tree

Cléa reads the same anchor comment Renovate does:

```bash
# renovate: datasource=github-releases depName=go-task/task extractVersion=^v(?<version>.*)$
TASK_VERSION="3.52.0"
```

One convention, not two. A second inventory is a second thing to drift.

The difference is what happens to a shape nobody declared. Renovate asks you to
write a regex per file and silently ignores any anchor no regex reaches. Cléa
**recognises** a fixed set of value shapes and **fails** on an anchor it cannot
read, or on one whose value is not version-shaped at all:

| shape | example |
|---|---|
| `bash` | `TASK_VERSION="3.52.0"`, `local HELM_VERSION="4.2.3"` |
| `bash-default` | `CILIUM_VERSION="${CILIUM_VERSION:-1.20.0}"` |
| `hcl-default` | `default = "v1.13.9"` |
| `yaml` | `GITLEAKS_VERSION: "8.30.1"`, `tofu_version: "1.12.5"` |
| `pip` | `run: pip install commitizen==4.9.1` |
| `task-default` | `V: '{{.V \| default "1.2.3"}}'` |
| `precommit-rev` | `rev: <sha>  # v4.9.1` |
| `action-sha` | `uses: owner/action@<sha>  # v7` |

An `action-sha` pin is bumped only with the commit its tag points at (`bump --sha`,
recorded by the scan); a `precommit-rev` never. The reasons are in `clea.py`.

Because Cléa's list is a superset of what any one declared inventory reaches,
the difference between the two **is** the set of pins nothing is watching. That
is `clea coverage`, and it is the check worth having even if you run nothing
else here.

The marker is configurable (`[scan] marker`), and it has to be: Cléa's own test
fixtures carry anchors, so a hard-coded word makes the scanner report its own
fixtures as dependencies of the repository under test.

## Commands

| command | needs the network | what it does |
|---|---|---|
| `clea coverage` | no | every anchor readable, and seen by every declared inventory. Exits 1 otherwise. Put it in your lint target. |
| `clea scan` | yes | resolve the newest upstream version of everything; write `clea-state.json`. |
| `clea matrix` | no | what the probe lanes should run, as a GitHub Actions matrix. |
| `clea bump <dep> <version>` | no | rewrite the pin, at **every** site, by the exact inverse of the reader. Exits 1 if nothing changed. |
| `clea report` | no | render Markdown, with the state embedded in an HTML comment at the end. |
| `clea pick-issue --issues <file>` | no | of a fetched, label-matched issue list, which one is Cléa's own report — see below. |
| `clea prune` | no | name the probe branches whose bump has already landed. |

Datasources: `github-releases`, `github-tags`, `pypi`, `helm`,
`terraform-provider`, and `url-text` for a tool installed from a moving target
such as `https://dl.k8s.io/release/stable.txt`.

## The report issue

The workflow keeps one open issue as both the report and the state store
(`clea report`'s output, state embedded in an HTML comment at the end). It is
found by label, but *not* by "newest labelled issue" — a human labelling an
unrelated issue with the same label, to cross-reference a finding, is the
natural thing to do, and if that issue is newer it must not be mistaken for
the report and overwritten. `clea pick-issue` matches instead on what only
this automation itself ever writes: the `_Generated … by [Cléa](…)_` marker
`render_report` always puts first in the body, from an issue authored as
`[report] bot_login` (default `github-actions[bot]`).

## Two rules it will not bend

**Zero floor.** An extractor that matched nothing, a datasource that returned no
version, a tree with no anchors: all exit 1. A green run that checked nothing is
worse than no check, because it reads as an answer.

**Loud on rate limits.** Unauthenticated, the GitHub API allows 60 requests an
hour from an IP shared with every other customer of the platform. A 401, 403 or
429 raises and names `GITHUB_TOKEN`; it is never reported as "up to date".

## What is offered

A bump reaches the report's action list and the probe matrix only if all four
hold. Otherwise it sits under **Held back**, with every reason:

| rule | read from | when it cannot be known |
|---|---|---|
| released at least `[policy] min_release_age_days` ago (7; 0 = off) | PyPI file upload time, GitHub release publish time, a tag's own date (annotated: tagger, else commit), a Helm chart's `created` | `age unknown` — never offered |
| not withdrawn | PyPI `yanked`, GitHub release `draft` / `prerelease` | — |
| its tag has not moved since the last scan | the commit the tag points at, kept in the state | no earlier scan, nothing to compare; kept until upstream tags another version |
| no OSV advisory against it | `api.osv.dev`: package + exact version (PyPI), commit (GitHub) | `advisories unknown` — shown, does not hold it back |

An advisory against the pin you run **now** is a line of its own: it argues for
bumping sooner. `terraform-provider` and `url-text` have no date source here.

## The probe

`probe.sh` runs two lanes in a bare `ubuntu:24.04`, never on the runner image —
a machine that already carries the tool hides the defect.

- **Cold install.** Bump first, run the installer once, assert the version.
- **Upgrade in place.** Install at the *current* pin, bump, run the installer
  again, assert the *new* version.

The second lane is the one that finds things. An installer that checks whether
the binary exists, rather than which version it is, installs correctly on a
fresh machine and refuses every upgrade afterwards — silently, on every machine
that has already run it once.

Only `curl` and `ca-certificates` are added to the container. Anything else the
installer needs and does not install is a finding, not a prerequisite to paper
over.

Set `CLEA_CA_BUNDLE` to a PEM wherever TLS is intercepted — a corporate proxy,
or a sandbox. Without it every download inside the container fails with
`self-signed certificate in certificate chain`, and the probe reports red for a
reason that is not the bump. A bundle that cannot be read is refused rather than
ignored, for the same reason.

**A dependency anchored only inside `.github/workflows/*.yml` cannot be probed
by CI's own `GITHUB_TOKEN`.** GitHub refuses that push outright, in any
repository, and no `permissions:` grant changes it — there is no such scope.
The workaround is a classic Personal Access Token with the `workflow` scope,
stored as a repository secret and named `CLEA_WORKFLOW_TOKEN`; a workflow that
wires it in falls back to the default token cleanly when the secret is absent
or rejected (`push-probes.sh`), so this is opt-in, not a requirement to get
everything else running.

## Configuration

```toml
[scan]
marker = "# renovate:"          # share the bot's anchors, or use your own
exclude = ["docs/**"]

[report]
title = "Cléa — dependency report"
label = "clea"

[policy]
min_release_age_days = 7        # keep equal to Renovate's minimumReleaseAge

[[inventory]]                   # what to cross-check against
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]    # its own matchStrings quote the anchor verbatim

[[tool]]                        # both probe lanes are derived from these three
name = "go-task/task"           # fields; the engine needs nothing else
installer = "scripts/internal/install-task.sh"
version_cmd = "task --version"
daily = true                    # false: weekly, for an installer that is slow

[[unpinned]]                    # consumed at whatever upstream serves today
name = "kubernetes/kubernetes"
datasource = "url-text"
url = "https://dl.k8s.io/release/stable.txt"
extract = "^(?P<v>v[0-9][0-9A-Za-z.-]*)$"
consumed_by = "scripts/setup.sh (install_kubectl)"

[lane]
regen = ["./scripts/render.sh"] # after the bump, before the gates
repo  = ["task lint"]           # the gates, on the bumped tree
```

## Its own assertions

`scripts/dev/test-clea.sh` — offline, on synthetic fixtures, and every check has
a twin that must fail: a reader that matches nothing, a writer that writes
nothing, a datasource that answers 403, a comparator that would put 1.13.9 above
1.13.10. A check only ever seen to pass is a check nobody has tested.
