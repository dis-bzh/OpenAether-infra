---
name: change-process
description: The process for landing a feature or a fix in OpenAether — what to read first, what counts as proof, what to update, and the failure mode this project keeps hitting. Use when adding, fixing or reviewing anything in OpenAether-infra or OpenAether-apps.
---

# Landing a change in OpenAether

Kept **identical** in `OpenAether-infra` and `OpenAether-apps`. Change both, or
the copies drift and the one you did not touch becomes the wrong instruction.

## The failure mode this project keeps hitting

**A check that cannot fail, or cannot run where it runs.** Over twenty defects
have had this shape: a language detector that flagged its own word list; a
gitleaks config that silently retargeted three consumers; a test assertion that
compared a value to itself; a port probe fooled by its own SSH tunnel; a purge
script that said nothing when the account was clean; an etcd eviction reporting
"already absent" for a member that was still there; a preflight that counted a
cordoned node as unhealthy and so blocked its own retry; a manifests job that
compared against a file the repository deliberately never commits; a setup
script that aborted before installing anything.

None was visible from a green pipeline. Every one of them was found by running
the thing for real, and several were found only because a *second* environment
disagreed with the first.

So the rule underneath everything below: **a check is not trusted until it has
been seen to fail.** Break it on purpose, watch it go red, then fix it and watch
it go green. A check you have only ever seen pass is a check you have not tested
— you have tested the happy path it happens to sit next to.

## Before you start

1. Read `docs/status.md` — it says what runs,
   what is proven on real cloud, and where to pick up.
2. Read `CLAUDE.md` (repository rules) and `CONTRIBUTING.md` (the rungs).
3. If you are touching the Flux DAG in `OpenAether-apps`: `task apps-validate`.

## While you work

**Prove it, don't assert it.** `CONTRIBUTING.md` defines the rungs, from
mocked (`task test`) up to real cloud. Say which one you reached
**and which you skipped**. "It should pass" is not a rung. Put that sentence in
the commit body, not only in the PR.

**Verify in a bare environment, not on your machine.** A machine that works hides
the defect. Real examples: a validation container that already had `curl`, so a
`setup.sh` that aborted on a truly bare image looked fine; a local `helm` on a
different major than CI pinned, so a vendored manifest was reproducible for one
person and nobody else; `checkov` that existed only in CI, so `task security`
could never pass for a contributor. When a fix is about "works on a clean
machine", the proof is a clean machine — `docker run --rm ubuntu:24.04`.

**Look for the defect's siblings.** Every fault found here has had them. `curl`
was missing from a prerequisite list already fixed for two other tools; the
worker upgrade path was broken in a way `--cp-only` could never reveal; a
hardened `gitleaks` invocation in one repository stayed bare in the other. Fixing
one instance and stopping leaves the rest. Search for the pattern, not the line.

**Know what your tests write and delete.** `tofu test` renders `local_file`
resources for real and removes them on teardown — it deleted a live cluster's
kubeconfig and talosconfig. Mock every provider a test can reach, including
`local`, and never assume a suite is read-only because it is called a test.

**A generator's output depends on its tool versions.** Pin them and say so where
the artifact is produced, or two people rendering the same pinned chart will
commit different bytes.

**Measure, don't assert.** "No interruption" is a number or it is an impression:
a one-second probe against the endpoint in the kubeconfig, and the count of
failed samples. "Idempotent" is `tofu plan` reporting no changes, quoted.

- **A create that times out leaves the resource tainted**, and re-running DESTROYS
  what the provider was still building. Ask the provider's own API for the status,
  then `tofu untaint` — `task infra-apply` prints the addresses and the command.
- **A resource count driven by a phase variable is not idempotent.** Gating
  `control_plane_count`/`worker_count` on `var.talos_bootstrap` zeroed them on every
  re-run and dropped `talos_machine_bootstrap` from state, which was then RECREATED
  — re-sending the bootstrap RPC to a live etcd.

## Before you open the PR

- `task lint`, `task validate ROOT=cluster`, `task validate ROOT=talos-image`,
  `task test`, `task security` — all five, locally, not just in CI.
- **Update what the repository now says wrongly.** A claim is part of the change.
  Grep for what you just altered: a checklist that says a path does not work, a
  matrix that says a provider was never exercised, a changelog that says a script
  is fixed, an example pinning a tag that no longer exists. A stale claim misleads
  more than a missing one.
- **Close the issues you finished, and open one for what you found.** The
  backlog holds open items only; a finished entry belongs to git history. Re-read
  it at the end of the session, not only at the start.
- **CHANGELOG entry** written for a reader who was not there: what broke, how it
  showed itself, what it now does, and the evidence.
- Real-cloud work is not finished until teardown and `scripts/ops/purge-orphans/`
  both report clean. Nothing left billing.

- **Three files can pin the same tool and only one be enforced.** helm was pinned
  in CI and in the renderer but not in `setup.sh`, invisible to everyone who
  already had helm 4.
- **A generated artifact drifts silently** — hence `task render-check` and
  `pick.py --check`. Prefer a guardrail that compares over one that assumes.

## Never

- Real data in either repository — they are public. IPs, account ids, bucket
  names, image ids. `envs/*.tfvars` is gitignored and derived copies must be too.
- `Co-Authored-By` or `Signed-off-by` for a model. The trailer is
  `Assisted-by: Claude Code (<model>)`, and the model identifier never appears in
  a commit message, a PR, or a code comment.
- Credentials on an untrusted branch: no `pull_request_target` in a credentialed
  workflow, and no agent carrying credentials on a fork branch. `CLAUDE.md`,
  `.claude/**`, `Taskfile.yml` and `scripts/**` are instructions an agent will
  follow — a PR touching them is a code-execution PR, so read that diff before
  running anything on it.
- French in code, commits or canonical docs. English is the source; `*.fr.md` is
  the translation.
