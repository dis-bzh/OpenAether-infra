# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file used to document 1.0.0, 1.0.0-withdrawn and 1.1.0. Those tags and
releases were deleted from both repositories and none of them ever worked; a
changelog listing releases nobody can obtain is not a changelog. That history is
in git. 0.1.0 is the first entry describing something proven.

---

## [Unreleased]

### Added

- **A lowered node count is refused before anything is applied (refs the 0.2.0 scale-in audit).**
  Lowering `control_planes` or `workers` made OpenTofu destroy the highest-index machine and its
  worker data volumes with no drain, no etcd leave and no Node delete, and neither `cluster-up` nor
  `infra-apply` said so. `scripts/internal/refuse-node-deletes.sh` now reads the saved plan and, on a
  bootstrapped cluster, stops on any pure delete of a node-class resource; `grow-nodes.sh` runs it in
  `--creates-only` mode, so a mixed edit cannot delete while adding. `node_distribution` is validated
  against the counts. Rung: mocked (`test-refuse-node-deletes.sh`, 18 assertions, mutants killed;
  `node-counts.tftest.hcl`) plus the guard run on two real Scaleway shrink plans (workers 2 to 1,
  control planes 3 to 2): both refused, nothing applied.

- **`cluster-verify` fails an "HA" cluster whose control planes all sit in one
  failure domain (refs #38, offline half).** Three control planes in one zone
  passed as HA: the verifier counted nodes and never asked where they sit. Each
  provider module now outputs `control_plane_zones`, read from its control-plane
  resources (`zone`, `availability_zone`, `placement_subregion_name`,
  `node_name`); it is a required row of `provider-contract.md`, which the
  contract check enforces, and the root passes it through. `infra-verify.sh`
  fails when they all share one domain, and its red line names the knob that
  clears it. A missing, short, null or empty-named output is UNCHECKED, never a
  pass; only the missing one suggests an apply (`infra-plan` then `infra-apply`).
  **Behaviour change:** 3 control planes in one zone now end red: OVH on the
  default `nova`, every Outscale cluster (all nodes in `availability_zones[0]`,
  #58: no setting clears it), Proxmox on one host. `cluster-up` ends at its
  verify, so `cluster-idempotency` and `cluster-upgrade` end non-zero there.
  **Known limit:** a 2+1 split (Scaleway over 2 zones, the topology 0.1.0 was
  measured on) passes, still 11/11, with a warning: losing the zone holding two
  loses etcd quorum.
  The value is what was placed, not measured: whether OVH reads its zone back or
  echoes the config is unknown, and no real account has re-run the check.
  Mocked rung: `control-plane-zones.tftest.hcl` (5 runs; `task test` 71 → 76), a
  root assertion for each provider, and cases in `test-cluster-checks.sh`
  (77 → 93) run against a stub `tofu` for the first time.
- **`cluster-verify` reads the workers' encrypted data volumes back (#62).**
  `worker_storage` asks for LUKS2 user volumes on each worker and nothing checked
  one existed. The verifier now asks each worker's own Talos API, through the
  first control plane's tunnel, for every volume the tfvars name: `ready` and
  `luks2`, or red. A worker no tunnel reaches is a warning. Seen on a real
  Scaleway cluster: green, and red (3 failed) with a volume named that the
  workers do not carry.
- **Cléa can probe and bump an `action-sha` pin (plumber).** `getplumber/plumber`
  is pinned as `uses: ...@<sha>  # v0.5.12` and as a release URL; the first shape
  made `bump` refuse, so its probe was red every day and the dependency could
  never be proven. The scan now resolves the commit a tag points at (peeling an
  annotated tag; one lookup per action pin) and the matrix carries it, so `bump
  --sha` moves the commit and the comment together, only when the `uses:` names
  the dependency's own repository and the commit is 40 lowercase hex. A refusal
  at the last site no longer leaves the first one rewritten. A `precommit-rev` is
  still refused. Mocked rung (`test-clea.sh`); not run on a runner yet.

- **`task evidence-check` dates the real-cloud evidence in `docs/status.md`
  (refs #121).** Nothing aged the table 0.1.0 rests on, so a measurement stayed
  "true today" after the versions it measured had moved. The table gains a
  `measured` column and a Scaleway re-run row (2026-08-20, Talos v1.13.8 to
  v1.13.9), transcribed from `upgrade.md` and the release checklist. The new
  `scripts/dev/check-evidence-age.sh` takes the newest row per provider and is
  red when its Talos or Kubernetes is not the pin, when it is older than 45 days
  (`OA_EVIDENCE_MAX_AGE_DAYS`), or when the row carries a ❌ or ⚠ (a failed run
  is no evidence). The pin is the tracked default in `cluster/variables.tf`,
  read with no tfvars: what a `management-*` example that leaves the pins unset
  inherits, and the one Renovate bumps. This departs from the issue, which names
  the `talos_version` / `kubernetes_version` of the `envs/*.tfvars.example`: 9 of
  the 14 pin `v1.13.3` / `v1.35.3`, they are unwatched and stale, and a
  workstation's own `envs/*.tfvars` must not change the verdict either. Exit 0
  current, 1 stale, 2 not verifiable (no table, a bad or future date, a cell
  with no version), so a broken extractor never reads as stale. On this tree it
  exits 1: OVH and Outscale measured Talos v1.13.8 against the pin v1.13.9,
  Scaleway is current (41 days old on 2026-09-30) but goes stale on 2026-10-05.
  It is in neither `task lint` nor `task test`, where a date-driven red would
  appear with no commit, and it records no receipt.
  `task preflight` runs it with `--warn`, before its banner: stale prints a
  warning and exit 2 fails, so the last lines stay true either way. Mocked rung:
  `test-evidence-age.sh` (63 assertions, fixtures and an injected clock) sees
  each verdict red and green, and asserts the real table parses, never that it
  is current; each of 31 mutations of the gate and of the Taskfile wiring turns
  it red. Nothing else in a row is read: a row that re-ran only the upgrade
  counts, and it cannot tell a measured row from a typed one. Turning it green
  takes, for every provider, a row at the pin dated within the limit: real OVH
  and Outscale runs, then Scaleway again. The issue stays open until then.

- **A pull request's rung is checked against a receipt the harness wrote
  (#120).** CONTRIBUTING asks every PR to name the rung it reached, but nothing
  recorded that a rung ever ran, so neither a reviewer nor CI could check the
  sentence. The 24 rung targets listed in `scripts/dev/rung-receipt.py` now
  start with a defer that appends `{rung, target, tool, version, rc, sha,
  dirty, utc, provider}` to the gitignored `.receipts/<rung>.jsonl`, red runs
  included. The nine other `test`/`feint-`/`local-`/`infra-`/`cluster-` targets
  are listed there with the reason they record nothing, and the harness fails
  on a new one that is in neither list. The sha and the dirty flag (untracked
  files count, and so does a `git status` that fails) are taken when the run
  starts, so a commit or an edit made during a long run cannot rewrite them.
  `task ssh-ca-check` now refuses to start without Docker instead of skipping
  with exit 0, which would have written a green receipt for a proof that never
  ran. `task receipts` prints the receipts for `HEAD`, and a PR template asks
  for `Rung:` and those lines.
  The new **Rung receipt** CI job passes only when a target that stands for the
  declared rung has a green receipt for the PR head, started on a clean tree.
  A pasted red run at or below that rung fails it, and a plan alone does not
  stand for real cloud. A missing, stale or lower-rung receipt fails it too, as
  does one `record` could not have written. The check reads the body through a
  model of what GitHub displays (block structure, raw HTML, images, link
  destinations, titles and labels, reference and footnote definitions). It
  agrees with GitHub's renderer on 55 of the 59 self-test bodies GitHub rendered
  and is stricter by design on the other 4; it is proven on nothing else. Where
  an HTML comment or tag is left open with more after it, only GitHub's HTML
  parser knows how much it hides, so the check refuses and asks to close it. It also refuses quotes, list items and
  footnotes nested more than 32 deep. Of 153 bodies up to GitHub's
  65536-character limit built to make it slow, the slowest took 0.80 s on a
  two-CPU host: backtick runs of distinct lengths, which cost more than
  linearly, so GitHub's limit is what bounds them. Renovate, Dependabot and
  docs-only diffs may leave the rung out, but a rung they declare is checked
  like any other. The body reaches the check only through `env:`. A receipt
  makes the claim falsifiable, not unforgeable. The job is a required check of
  the `main` ruleset. CONTRIBUTING now lists four rungs, adding local Docker as
  in the issue form. Mocked rung:
  `test-rung-receipts.sh` (121 assertions) runs the real Taskfile under
  go-task against a stub `feint` and drives every verdict the check can give,
  each within 2 s; each of 77 mutations turns it red. With the body
  interpolated into `run:`, actionlint and plumber's `templateInjection` both
  go red.

- **Repository settings are checked against what actually happens (#122).**
  The required-check list lives in a GitHub ruleset, where no diff shows it
  drift: CodeQL ran on every PR while nothing declared it, and two layers of
  protection disagreed (7 required checks in the ruleset, 13 in classic
  protection). The `main` ruleset is now the only one, requiring 17 checks
  pinned to GitHub Actions, and a `tags` ruleset blocks moving or deleting
  any tag, `0.1.0` included, with no bypass. New
  `.github/workflows/repo-settings.yml` (push to main, daily, on demand, never
  on a PR) runs `check-required-checks.sh` live: the required checks against
  the check runs on the head of the last merged PR (main's own commits also
  carry Cléa's scheduled jobs), the tag ruleset, and the private
  vulnerability reporting `SECURITY.md` promises. An empty or unreadable
  answer fails as "not verifiable". A workflow token cannot read a ruleset's
  bypass actors, so CI warns on that one item; an admin's run, now a line of
  `docs/release-checklist.md`, verifies it. Evidence, from this script on top
  of `f8d6bd3`, anonymous and read-only: against the head of PR #192, the last
  merged, 17 of 17 required checks match what reported, so it exits 0 with
  `--tolerate-unreadable-bypass` and 2 without (that token cannot read the
  bypass actors); with that flag, forced onto `f8d6bd3` it exits 0 too, and
  forced onto `96e02ca` it lists 10 unrequired checks and exits 1. Offline,
  51 cases against a canned API (`task test-scripts`) see each check red and
  green. The workflow token's path is proven by its first run after merge.

- **`docs/capacity.md`: what a cluster needs, per provider (refs #72).** The
  sizing floor and its evidence (the 2026-08-15 drain measurement), what each
  module creates (instances, disks, public IPs, LBs, security groups), and the
  totals and `preflight-quotas` flags for every shipped example. Derived figures
  are marked apart from measured ones. It flags, without changing them, the
  Scaleway and Outscale examples that sit below the floor.

- **`task cluster-upgrade` also measures a Service, not just the apiserver
  (#41).** For the whole roll a 2-replica workload behind a Service (with a PDB
  when two nodes can take it) is polled through the apiserver proxy; its FAIL
  count and longest outage are reported next to the apiserver's, samples taken
  while the apiserver is down count apart as BLIND, and the workload is deleted
  on success, failure or interrupt. Reported, not gated. Mocked rung:
  `test-cluster-checks.sh` covers all three exits, the single-node case and the
  summary arithmetic. No real roll has produced the number yet, so #41 stays
  open.

- **`task cluster-up` refuses, before it spends, a `prod` cluster never applied
  before whose replica shares the primary's cloud (#57).** Until now only
  `infra-verify.sh` said so, after the apply. `ensure-buckets.sh --preflight`,
  passed by `cluster-up` alone, refuses when `s3_replica_endpoint` is the
  primary's endpoint (case and trailing `/` ignored) or the same provider; a
  self-hosted S3 only has to be another endpoint. A cluster name with a state
  object is only warned: it may be live, or rebuilt after `cluster-down`, which
  keeps the state bucket. No plan, upgrade, roll or destroy runs the rule, which
  is why it is not a variable validation. `infra-verify.sh` shares the
  predicate: a prod replica in another region of the same cloud is now red
  there too. Proven in `test-backup-creds.sh`, which also holds the eight prod
  examples to the rule; eleven mutations each turn it red.

- **`task state PROVIDER=…` lists what a cluster's state holds; `ADDR=` shows
  one resource (#53).** By hand, a wrong directory, data dir or key answers "No
  state file was found", which reads as an empty state. The target refuses a
  missing env file, key or passphrase by name and tells an absent state from an
  empty one. It only reads the state. Mocked rung: `test-state-task.sh` runs it
  under the real go-task and tofu on a local-backend fixture. A real S3 backend
  is still to come.

- **`version-support.json` knows Talos 1.14: Kubernetes 1.32–1.37.** Read
  from `MinimumKubernetesVersion` / `MaximumKubernetesVersion` in
  `siderolabs/talos` `pkg/machinery/compatibility/talos114/` at v1.14.1 (the
  docs site is unreachable from the sandbox; the same file gives 1.31–1.36 for
  1.13, matching the existing entry). The floor moves up, so 1.14 + 1.31 is
  refused. Defaults are unchanged: this only lets the guard accept a Talos 1.14
  pair, the prerequisite for bumping Talos and Kubernetes together (#149).

- **`task check-flux-digests`: the network half of #119.** `flux-install.yaml`
  pins its seven controller images by tag only — a tag force-moved upstream
  changes not one byte of the committed YAML, so `task render-check` sees
  nothing, Cléa has no `# renovate:` anchor on these lines, and Trivy skips
  the file. `scripts/dev/check-flux-image-digests.sh` resolves each tag to
  the digest ghcr.io serves today (an anonymous token, same as `docker pull`)
  and compares it to `flux-image-digests.lock`, recorded alongside
  `upstream-artifacts.lock`. Needs the network but never a cloud account, so
  it stays out of `task lint`. Proven by mutating one recorded digest: the
  check went red naming the drift, then green again once restored.

### Changed

- **The roll's gates and helpers live in `scripts/lib/roll-gates.sh`, moved verbatim.** The scale-in
  command needs the same drain, CNPG, PDB, etcd and plan gates, and a copy would drift. The original
  `rolling-replace.sh` rebuilds byte for byte from the new script with the logging block and the function
  region spliced back in; the harnesses that extract or grep by name now read both files. No behaviour change.

- **The shipped Scaleway examples meet the sizing floor; the Outscale ones say why they do not (#72).**
  Scaleway's examples move to `POP2-4C-16G` (4 vCPU / 16 GB; `DEV1-M` was a local-SSD type
  absent from `fr-par-3`) and stop pinning `talos-scaleway-amd64-v1.13.3`, an image the lane no
  longer holds. Outscale stays at `tinav5.c2r4p1`: the floor on five nodes plus the bastion is 22
  vCPU against a 20 vCPU default quota, so a bare cluster only (`docs/capacity.md`).
- **`talosctl upgrade-k8s` and the read-only talosconfig were each tried on a real cloud, and the answers are written down (#70, #80).**
  `upgrade-k8s` measured no gentler than the config-driven Kubernetes step
  (`docs/upgrade.md`); the `os:reader` talosconfig minted through the tunnels runs
  `cluster-verify` green (`docs/admin-access.md`), so mint one and reuse it.

- **Two decisions are written down instead of left as questions (#82, #56).** The
  bastion stays and is hardened in place until there are two operators or a restore
  that has been run (`docs/admin-access.md`). Outscale has no state lock by design, so
  its rule is one operator at a time (`docs/release-checklist.md`); Scaleway and OVH
  refuse a second run by name, seen on both through the project's own tasks.
- **Outscale spreads its nodes over the subregions in `availability_zones` (#58).**
  The module read only the first entry, so three control planes shared one
  subregion. It now builds a private subnet per entry (the first keeps `10.0.0.0/24`),
  places control planes and workers by index and keeps a worker's data volumes in its
  subregion. A node's subnet is ignored after creation, so a cluster built before this
  keeps its layout. The public subnet, bastion, NAT and load balancers stay in the first
  subregion: a load balancer takes one subnet ("multiple subnets is not implemented",
  measured) and still reaches nodes in every subregion.

- **`opentofu/opentofu` 1.12.6 → 1.13.1** (`ci.yml` ×5, `setup.sh`) and
  **`fluxcd/flux-schema` 0.13.0 → 0.15.0** (`ci.yml`, `setup.sh`), both probed
  green by Cléa (#91). Proven with the real binaries, not the sandbox's cached
  ones: OpenTofu 1.13.1 (sha256 OK) first on the PATH and `flux plugin install
  schema@0.15.0` (`flux schema version` = 0.15.0), then `task lint`,
  `render-check`, `test-scripts`, `validate` (both roots) and `task test` (71/71)
  green, plus checkov (32/0), its custom checks (6/0) and gitleaks. `trivy` not
  run in this sandbox — relies on CI. Left out: `getplumber/plumber` v0.5.17
  (probed green, but `clea bump` refuses its `action-sha` pin, same as #170);
  `go-task` 3.54.0 and the `kubectl-cnpg` plugin 1.30.1 are in #226;
  `fluxcd/flux2` v2.9.6 and `siderolabs/talos` v1.14.2 not probed;
  `kubernetes/kubernetes` v1.37.1 probe failed (`versions-guard.tf`, #181).
- **Talos v1.14.2 and Kubernetes v1.37.1 are the default pin (#181).** Both roots
  (`cluster` and `opentofu-local`) move together. On a real Scaleway cluster, with a
  Longhorn volume attached and a Service probe running, `cluster-upgrade` took
  v1.13.9 / v1.36.3 to this pair in place: six nodes, no failed Service probe, the
  data written before the climb read back identically, `cluster-verify` 13/13. The
  Longhorn question the bump waited on is answered on the pair the issue names
  (v1.14.1 / v1.37.0). OVH and Outscale have not seen 1.14: their rows still read
  Talos 1.13.8.
- **`go-task/task` 3.53.1 → 3.54.0** (`install-task.sh`) and the
  **`kubectl-cnpg` plugin 1.30.0 → 1.30.1** (`install-kubectl-cnpg.sh`), the two
  of Cléa's #91 rows that sit outside `.github/`. Both installed from the pinned
  release with their checksum verified; `task lint`, `test-scripts` (33
  harnesses, 1262 passed), `test`, `render-check` and both `validate` roots pass
  with `task` 3.54.0 first on the PATH. The release notes were not read.

- **`getplumber/plumber` v0.4.51 → v0.5.12** in `security.yml` (SHA and comment
  together) and `install-plumber.sh`, by hand: `clea bump` refuses an
  `action-sha` pin, so Cléa's daily run had been red on it since at least
  2026-09-17, and Renovate, which should move it, has proposed nothing since
  2026-07-30 (#88). The one breaking change since v0.4.51 (0.5.0) re-keys
  dismissals on the hosted platform, which this repository does not use. Proof:
  both versions, installed through `install-plumber.sh` (checksum OK) and run
  tokenless on this tree, give the same verdict on each of the 24 controls — 22
  passed, `requiredActionsResult` skipped, `branchProtectionResult` unevaluated
  without a token. The token path rests on CI's "Pipeline audit" job.

### Fixed

- **Documents that still described the 0.1.0 measurements as the latest.** The README's "Honest status",
  layer table, providers table, roadmap and document index; `docs/status.md` (#59 "still open", the
  Renovate cause); `docs/first-cluster.md` (a control plane could not be added, nobody had used a
  `bucket_suffix`, the image's "staging area"); `docs/upgrade.md` (no roll had produced a number, the first
  apply after a bump fails once); the test matrix (header, OVH and storage rows, priorities; new rows for
  growing and for the refused shrink); `docs/capacity.md`. Nine example tfvars hard-pinned Talos v1.13.3 and
  Kubernetes v1.35.3, a pair never measured on a cloud; they now inherit the tracked defaults, as the
  management examples do. Renovate's note for Cilium and Flux bumps named `task up FORCE=1`, a cloud
  bring-up; it now names `task render-manifests`. French twins follow.

- **`roll-lab.sh self-test` was red on main.** Its check that the upgrade path still skips a node already on
  the target version looked four lines past the comparison for the `return 0`, and the schematic check added
  later put it ten lines down. It now asks for the `return 0` right after the "already runs … skipping" line;
  deleting that `return` or commenting the line out fails it.

- **The roll finds a worker's attach/link resources, and `task --list` stops advertising it for a resize.**
  `node_targets` matched `worker_data[<n>]`, but the OVH attach and Outscale link resources are keyed
  `"w<worker>-d<disk>"`, so a replaced worker came back without its data disk until the next full apply
  (inferred from the graph, not run). The pattern now matches the real keys, tested against OVH and Outscale
  state with worker 10 beside worker 1. The `cluster-roll` description and the script header said to use it for
  a node size change; `docs/upgrade.md` measured the opposite and they now point there.
- **Outscale's red-HA hint and example tfvars stopped saying only `availability_zones[0]` is used (#58).**
  The layout landed; a single-zone list is what is left red, and the hint and the three examples say so.
  `test-cluster-checks.sh` pinned the old wording and follows.

- **Renovate is switched from silent to full mode, behind an approval canary (#88).** Mend's hosted job
  ran with `mode: silent`, so it found 17 updates and wrote no issue and no pull request. `renovate.json5`
  now sets `mode: "full"` (a repo-level value is merged over Mend's) and `dependencyDashboardApproval: true`:
  the Dependency Dashboard appears, and nothing opens a PR until its box is ticked. Revert this one commit
  to go back to silent; the portal's Silent/Interactive switch is the other way.

- **Renovate can bump the pre-commit hooks, and no longer proposes two bumps that break the repository (#88).**
  The hosted job log (2026-10-03) showed the native `pre-commit` manager reading each SHA in
  `rev: <sha>  # v1.2.3` as a tag ("Tag … not found"), so the five hooks were never bumped
  (`commitizen` sat at v4.9.1, 4.19.1 exists). A custom manager now reads the SHA and its tag
  comment and moves both. The same log showed what the first PR flood would have contained:
  the Scaleway cap `< 2.83.0` widened to `< 2.85.0` (the Feint lane, #179) and the Talos
  provider moved to 0.12 (a 1.14 cluster, #241); both are ruled out, and `tofu_version` is no
  longer tracked twice (native and anchored). `clea.toml` no longer
  claims the native manager covered pre-commit revs.

- **A roll exits 1 and names what is left when a Flux Kustomization is still
  suspended or a CNPG budget is missing (refs #64).** The exit trap resumed the
  owner chain and set `enablePDB` back, and nothing looked afterwards: a failed
  resume patch was one warning and exit 0, and budgets the operator never
  recreated went unnoticed. `finish_roll` now restores in a subshell, then
  `assert_restored` polls until no owner Kustomization is suspended and every
  cluster has its `<name>-primary` budget, else exits 1 naming what is left. The
  roll's own failure status is kept, and a cluster without CNPG is asked the CRD
  question and nothing else. A read that fails is a problem, never a pass: an
  owner-label read failing other than NotFound now dies instead of cutting the
  ancestor walk short, so on the way in it also refuses the roll.

  What the operator sees at the exit. The wait runs on the clock
  (`RESTORE_TIMEOUT` 120s, `RESTORE_POLL`, each call capped by
  `RESTORE_REQUEST_TIMEOUT` 10s) and takes up to 211s, measured with an
  unreachable apiserver. Ctrl+C or SIGTERM ends the wait (exit 130, "restore NOT
  verified"); during the restore itself they are ignored, since a signal kills
  its subshell half way. A roll stopped between nodes is not called complete: it
  says a stop was requested and keeps its status (0 when the restore verifies,
  else 1). The "complete" line is `finish_roll`'s alone, printed only once the
  check passes; otherwise the exit says the roll finished and only the restore
  did not, and not to re-run replacement mode (it replaces every node again).
  Two effects follow a non-zero exit after the last node: `task cluster-roll`
  skips `_backup-state`, as after any failure, so the exit names
  `scripts/ops/backup-state.sh`; and `task cluster-upgrade` stops between its
  `--cp-only` and `--workers-only` rolls, which keeps the second from suspending
  Flux on top of a first that did not resume it.

  Not observed, with its consequence: whether CNPG creates `<name>-primary` for a
  ONE-instance cluster. If it does not, every roll of a cluster with a
  single-instance database exits 1 after the full wait naming that budget as
  missing, skips `_backup-state` and stops `task cluster-upgrade` between its
  rolls, although the roll itself succeeded. Also not observed: a real roll with
  Flux and CNPG together (0.1.0 ships no Flux), how long the operator takes to
  recreate the budget, a real terminal Ctrl+C (the test signals a process
  group), and the two task effects, since `task cluster-roll` refuses a local
  run. #64 stays open at the real-cloud rung.

  The wiring assertion "after the maintenance call" matched the per-node
  re-assert, not the main block; it now matches the main one. Mocked rung only:
  `test-rolling-replace.sh` 66 → 114 assertions against a stateful fake
  apiserver with two clusters, red first (rc 127 on the old script, and the old
  exit path on the same fake leaves the root suspended with rc 0); 15 mutants
  (budget matcher, cluster loop, `;` for `&&`, owner walk, clock, exit words),
  then 11 more on the final head (failed roll and failed restore, stopped roll,
  signals, owner warning, empty cluster list, the three defaults), each turn at
  least one assertion red.
- **The OVH examples and defaults name AZs OVH accepts (#72).** They said `["nova"]`;
  on EU-WEST-PAR, Nova tolerates it but Cinder rejects it, so the first apply died
  creating the workers' data volumes. The examples, the cluster default and the module
  default now name `eu-west-par-a/b/c`. Seen on a real OVH account: all three zones
  deploy and verify.
- **The Outscale purge reports this account's images, not just its snapshots (#107).**
  `purge-orphans` listed leftover snapshots but never images, because `ReadImages`
  answers every OMI the account may launch (646 of 64 owners on a real account, 2
  ours). It now reads the account id first and scopes the call with `AccountIds`;
  a refused `ReadAccounts` or `ReadImages` is "unverified", never an unscoped list
  nor a clean. Images are still never deleted here. Seen on a real account: exactly
  its two OMIs, read-only.

- **`workers = N+1` and one `task cluster-up` now work on a bootstrapped cluster (#59).**
  The apply that created a node also waited for its Talos port through a tunnel that
  cannot exist before the node, and once the tunnels were opened by hand the next plan
  blocked 15 minutes on a health check no unconfigured node can pass. `cluster-up` now
  runs `scripts/bootstrap/grow-nodes.sh` first: it creates the machines (a plan of the
  provider module alone), refreshes the outputs the tunnels read, opens the tunnels,
  and configures only the nodes the state has no configuration for. A no-op on a fresh
  cluster or when no node is new. Measured on Scaleway, 3 to 5 workers.
- **CI no longer "checks kube-proxy is disabled" by matching an unrelated default.**
  The step grepped `disabled: true` in a config made by plain `talosctl gen config`,
  which carries none of this repository's patches; the line it matched was the
  Kubernetes discovery registry's own, which Talos 1.14 stopped writing, so the step
  went red on the pin bump and had never tested kube-proxy. `test-kube-proxy-disabled.sh`
  reads the patches the Talos module builds, for control planes and workers.
- **A stale state lock is now named, with the command that releases it.** A run
  killed hard (SIGKILL, a crashed runner, a closed laptop) never releases its state
  lock, and every later `cluster-up`, plan and apply stopped on `Error acquiring the
  state lock` while nothing in the repository mentioned `tofu force-unlock`.
  `explain-failure.sh` now prints the holder (ID, operation, who, when), says to
  check that run is really gone first, and gives the exact command for the data dir
  the run used. Measured on a live Scaleway cluster, after a `SIGKILL` of phase 2.
- **The roll no longer deadlocks on Longhorn when it has as many replicas as workers.**
  `rolling-replace` waited for Longhorn to be healthy and only then uncordoned the
  node it had just rebuilt, but Longhorn does not put a replica on a cordoned node:
  with 3 replicas on 3 workers the volume stayed degraded for the whole 600 s gate
  and the roll stopped (Scaleway: healthy 63 s after a manual uncordon). The node is
  uncordoned first; the gate still holds the roll before the next node.
- **A dry run no longer leaves a rung receipt.** `task cluster-upgrade DRY_RUN=1`
  (and `cluster-roll -- --dry-run`) exits 0 having touched nothing, yet recorded
  `real-cloud … rc=0`, which satisfies the "Rung receipt" check for that head
  with nothing run. The receipt task now records nothing when `DRY_RUN` is set or
  `--dry-run` is passed.
- **`infra-plan` and `infra-apply` no longer read an unreadable state as "no
  bootstrap".** `tofu state list 2>/dev/null | grep -q …` answered `false` on any
  failure to read (an S3 error, a bad credential); on a bootstrapped cluster that
  zeroes the node counts and drops the bootstrap, machine configs and kubeconfig
  from the state. A live Scaleway upgrade ended that way, with an empty kubeconfig
  output. `scripts/internal/bootstrap-in-state.sh` answers only when the state is
  read or absent. Measured: a wrong secret key now stops it with the provider's
  message. Why that upgrade's read failed is not established. Refs #67.
- **A size change through `cluster-roll` no longer resizes every node at once.**
  Measured on Scaleway: with `instance_type` raised, `-- --workers-only` replaced
  worker 0 and its targeted config apply dragged in the in-place resize of all
  three control planes (API down 56 s); the destroy count could not see it. The
  roll now plans both steps before the cordon and refuses a plan that changes
  another node. A size change goes one node at a time, in place:
  `docs/upgrade.md`, measured with 1 s blips only. Refs #51, #42.
- **A rejected `CLEA_WORKFLOW_TOKEN` no longer silences Cléa.** From 2026-09-24
  every `Push probe branches` job failed with `Invalid username or token`: the
  secret was set but rejected, the script never fell back to `GITHUB_TOKEN`, and
  its first failure aborted the rest, so the report read "not probed" for probes
  that had passed. The push is now `scripts/clea/push-probes.sh`: the PAT, then
  `GITHUB_TOKEN`, and one failed branch does not stop the others; git's whole
  output reaches the log, without any token. The report opens with a warning when
  the push job failed or a finished probe job has no verdict on its branch, and
  names them. Mocked rung (`test-clea-push.sh`, `test-clea.sh`); that the PAT
  expired is a hypothesis, the secret is not readable from here.

- **`task cluster-up` refuses a missing or placeholder passphrase before it
  creates the buckets.** The check ran after `ensure-buckets.sh --preflight`,
  which creates the four buckets, so the refusal came once resources existed. It
  now runs first. `test-cluster-up.sh` gains a control and two cases (empty,
  `change-me`): the refusal, and no `ensure-buckets.sh` or `talos-image.sh` call;
  12 passed / 2 failed on the old order, 14 / 0 on the fix. `EXTRA` is now applied
  last, so a case can override the default passphrase. Mocked rung only.

- **A Scaleway kind that no zone answered is no longer read as clean.**
  `scaleway.py` skipped a kind that every zone answered 404/501 as "not
  offered", so a listing that asked nothing ended "the project is clean" (exit
  0) and `edge-down.sh` printed "fully deleted". Such a kind is now refused
  (exit 2) in the purge and in `verify-provider-clean.py`, whose all-clear also
  names the region and zones it read. A 200 that is not JSON, or an item with
  no `id`, is exit 2 too, not a traceback (exit 1, "leftovers"). `--apply` no
  longer closes on "The project is clean": a terminated server leaves the
  listing late, so it asks for a re-run. Mocked rung: `test-purge-orphans.sh`
  78 → 95 assertions and `test-teardown.sh` +4; 8 mutants each turn one red.
- **`feint.sh` no longer checks and stops the emulator on the default port
  when `FEINT_ENDPOINT` names another (#195).** `feint status` and `feint stop`
  default to :4599 and were called without `--addr`; `feint_cli` now adds it.
  `test-feint-restart.sh` goes 14 passed / 3 failed → 17 / 0 on the fix.
- **`task cluster-upgrade` could not upgrade Talos, and could read another
  cluster's fleet (refs #181).** The Talos step built the target image before
  it moved `talos_version`, and since #93 `talos-image.sh` refuses to build
  while any tfvars for the provider pins another version, so the step stopped
  on the cluster's own pin: "pins talos_version = <old>, but this build
  targets <new>". The harness stubbed `task` and could not see it. The step
  now checks the provider's other tfvars first, the way the guard does, then
  moves the pin, then builds. A failed build leaves the pin at the target: on
  OVH and Outscale the build can fail after its apply replaced the old image.
  The script also read the fleet through the checkout's single kubeconfig,
  whichever cluster wrote it last, and its schematic check passed `talosctl`
  no talosconfig at all. A real run now fetches both for its own cluster and
  exports them; a dry run, which needs no credentials, exports both paths but skips
  the `task kubeconfig` fetch. Mocked rung:
  `test-cluster-checks.sh` runs the real `talos-image.sh` inside the upgrade,
  and its `talosctl` stub answers only the cluster's talosconfig. On main's
  script: 70 passed, 7 failed; now 77/0, and each of seven mutants turns it
  red. No live upgrade has run in this order yet.

- **A real `envs/*.tfvars` no longer turns `task lint` and `test-talos-image`
  red (#191).** The `tofu fmt` step no longer walks ignored files, and the #93
  guard reads `OA_ENVS_DIR` (default unchanged), which the harness points at a
  sandbox, so it neither reads nor writes the real `envs/`. Reproduced with a
  gitignored tfvars pinning another Talos version: fmt rc 3 → 0, harness 16/21
  → 37/0; each of the three changes reverted alone turns the harness red again.
- **The Scaleway node security group still opened every port, and its test
  could not see it (#79, mocked part).** The earlier fix (further down) dropped
  `port = 0` from the two `protocol = "ANY"` rules and asserted that no rule
  carries `port == 0`. Dropping it changed nothing: applied with the real
  provider (2.83.1) to a private Feint, an omitted port and `port = 0` were
  stored as the same rule (no port range, so every port), and both read back as
  `port = 0`. Only a mock plans the omitted port as null, which is why the
  assertion passed on two all-ports rules. The group now lists the ports this
  repository's layers serve over the private network, from the module's own
  subnet: Talos apid and trustd, etcd and its metrics, the apiserver, the
  kubelet, Cilium's VXLAN, WireGuard, health and metrics ports, ICMP,
  node-exporter, DHCP, and the App LB's NodePorts. `100.64.0.0/10` was open on
  every port "for LB health checks"; it now keeps only the LB backend ports.
  The rules sourced from the LBs' public IPs are removed, because both LBs
  reach the nodes over the private network, from that subnet. The test reads a
  rule as the provider sends it (a set `port_range` wins over `port`, a missing
  port counts as 0) and rejects `ANY`, port 0, a range from 0 (`0-0` included)
  or `1-65535`, on the bastion's group too. It pins each node group to the
  reviewed list in three configurations: App LB on (17 rules), the root
  defaults (13) and vip mode (12), so a port added, widened, duplicated or
  opened to the carrier range fails it. Each of 21 reintroduced defects turned
  it red.
  Emulated rung: `feint-plan`, plus an apply / empty re-plan / destroy of the
  whole root with the App LB on. `security.tf` now also says what Scaleway
  documents: security groups filter public traffic only. The nodes have no
  public IP, so on this provider the list declares the perimeter; it does not
  enforce it. Still open: one real deploy to confirm the LB health checks pass.
- **Scaleway's teardown proof now answers, and missing credentials no longer
  read as leftovers.** `verify-provider-clean.py` listed `scaleway` as supported
  but had no check for it, so it exited 2. It now reads `purge-orphans/scaleway.py`'s
  own listing: servers, LBs, public gateways, security groups and private
  networks named or tagged after the cluster (the whole name, so `edge-1` does
  not own `edge-10`), plus every detached flexible IP, LB IP, gateway IP and
  volume in the project, from the block API and from the instance API that
  DEV1/GP1 servers still use. The purge never listed public gateways, their
  IPs, LB IPs left without an LB, security groups or instance volumes, so a
  project holding only those read as clean, and it read the first 50 items of
  each list only. It now lists and deletes them, page by page, and a list that
  answers page 1 then fails is refused, not read as "not offered in this zone".
  A missing
  `SCW_SECRET_KEY` or `SCW_DEFAULT_PROJECT_ID` raised `KeyError` and exited 1,
  the code for "leftovers found". It now exits 2, "could not check". So does an
  `--apply` run where an endpoint refused to answer, on all three purges: it
  used to end "clean" with exit 0. `ovh.py` and `outscale.py` had the same bare
  credential read, and a refused OVH authentication, like a region missing from
  its catalog, exited 1 with a traceback; both now exit 2. `edge-down.sh` no
  longer sends a Scaleway or Outscale operator to the OpenStack-only deleter.
  Mocked rung: `test-purge-orphans.sh` went from 26 to 78 assertions, 41 of the
  first 74 red on `main`'s scripts, and 22 mutants measured on those 74 each
  turn it red;
  `test-teardown.sh` from 105 to 109. Emulated rung, on Feint 0.13.0, with the
  API base swapped in-process (the scripts read no endpoint from the
  environment): one resource of each of the 10 kinds plus another cluster's
  server gives 10 leftovers from verify and 11 targets from the purge, which
  covers the whole project. A single `--apply` pass deletes 14, the 11 and 3
  that the emulator released while terminating servers and deleting the
  gateway; both then report 0. 56 detached volumes give 58 targets, 52 when
  only the first page is read. Not yet run on real cloud, so a volume that
  both volume APIs list (counted once, by id) is untested. Buckets are still
  not listed.

- **`feint-record`'s proxy always listened on 4600, and a dead one went
  unnoticed (#204).** Two record lanes on different endpoints shared that port.
  With it taken the proxy died at bind, and the lane's apply went to whatever
  held it, through it to that lane's emulator. The proxy now takes the
  endpoint's port + 1 (4599 gives 4600, so the default is unchanged), and a
  proxy that is not running after its startup wait stops the lane before tofu
  runs. Emulated rung, Feint 0.13.0, a record lane on 4699: with 4600 taken
  the proxy listened on 4700 and the lane recorded, rc 0; with 4700 taken it
  stopped on feint's bind error, rc 1. `test-feint-restart.sh` keeps one stub
  emulator per address. Fixing the port at 4600 turns 2 of its assertions red,
  dropping the liveness check turns 1, and reverting #196's `--addr` turns 10.

- **The rest of `task test-scripts`, `task fmt` and the fmt hook leave the real
  `envs/` alone (#191).** Four harnesses (bucket-names, seed-openbao,
  converge-versions, teardown) wrote their fixture there and `rm -f`'d it: a
  file planted under each fixture's name was gone after the run. They use a
  sandbox now, through `OA_ENVS_DIR`, which the four scripts they drive honour;
  with 20 synthetic tfvars in `envs/`, a full `task test-scripts` reads, writes
  and deletes none of them. It also fails now if anything under `envs/` is
  newer than its start, a file written and deleted again included: #192's
  converge-versions harness passes 10/0 and turns it red.
  `test-bucket-names.sh` read its state-lock assertions from the operator's
  `envs/management-*.tfvars`: red with a synthetic one present (24/1), and in
  CI they asserted nothing, so a `tf-backend.sh` locking Outscale passed 24/0.
  They read the shipped examples and fail on a crashed `tf-backend.sh`.
  `task fmt` and the pre-commit `terraform_fmt` hook (`-recursive`) rewrote the
  ignored tfvars, the hook while saying Passed; both leave them alone now. The
  hook also selects a staged `.tftest.hcl` itself: upstream's filter skips it,
  and only `-recursive` from a staged `.tf` used to reach it. `task lint` fails
  if that `files:` pattern and the Taskfile's `TF_FMT_RE` differ. `task lint`
  and `task fmt` share one file list (tracked and new, never ignored or
  deleted), so lint catches a new unformatted `.tf` again, no longer dies on a
  deleted one not yet `git rm`'d, and fails on a `TF_ROOTS` entry that no
  longer exists, as the recursive walk did.

- **A node size change resizes every node at once, on all four providers
  (#51, mocked part).** The Scaleway and Proxmox modules said `type` and
  `cpu`/`memory` were ForceNew. They are not: at scaleway 2.83.1,
  openstack 3.4.0, outscale 1.8.0 and bpg/proxmox 0.114.0, the provider stops
  and resizes the instance in place (or reboots it). A plain apply therefore
  plans updates, destroys nothing, and slips past `rolling-replace`'s destroy
  count. This comes from reading the provider source. It was confirmed offline
  by planning each size change with the real provider binaries against a seeded
  state (Scaleway's plan-time API calls answered by a local stub): every one
  came out `update`. Positive controls on a ForceNew attribute came out
  `delete, create`. `docs/upgrade.md` sent a size change through
  `task cluster-roll`; that was wrong on Scaleway (entry under Fixed). `node-size-change.tftest.hcl` checks that the size
  reaches each node and that nothing turns it into a replacement: Scaleway's
  `replace_on_type_change` stays unset and Proxmox's `reboot_after_update` is
  not false. Setting either one turned its run red. A mock cannot tell
  replace from update, since it planned a ForceNew change as an update, so the
  provider verdict itself is not pinned. No live bump yet; #51 stays open.

- **`rolling-replace` applies the plan it counted (#55, still open).** Its two
  per-node applies were `-auto-approve` re-plans, so the "one node at a time"
  count guarded a plan nobody applied. Each apply now plans with `-out`, counts
  deletes from `tofu show -json` of that file and applies that file; `--dry-run`
  prints the same. Also fixes a loop that overwrote `replace_node`'s `$t`,
  which skipped the etcd gate after a control-plane replacement. Mocked rung:
  `test-rolling-replace.sh`, red on the old code; a real roll is still due.
- **`feint.sh` could report a live emulator as down, intermittently.**
  `running` piped the eight lines of `feint status` into `grep -q`, which
  exits on the first; `status` then dies on SIGPIPE and `pipefail` reads
  "not running". Observed on the real binary, one machine, varying by run:
  6/100, 6/300 and 3/300 false negatives. It failed one `feint-test` with
  "no emulator". `running` now reads the whole output; a stub `status` that
  keeps printing in `test-feint-restart.sh` is red with the old code, green
  with the new.
- **`task feint-apply-root PROVIDER=scaleway` was red at destroy (#179).**
  The cluster root resolves scaleway 2.83.x, whose private NIC destroy calls a
  route Feint still answers 501 on 0.13.0. The lane's backend override now also
  caps the provider `< 2.83.0`, and parks the root's lock file for the run so
  the cap never reaches a real init. Green on 0.13.0 with 2.82.0: 27 created,
  empty re-plan, 26 destroyed, lock file restored byte-identical.
- **`feint.sh` said "no log" on machines without `XDG_RUNTIME_DIR`.** It looked
  under `/tmp`, while feint then writes to `XDG_STATE_HOME` or
  `~/.local/state`. It now uses feint's own lookup; a new
  `test-feint-restart.sh` case is red with the old path, green with the new.
- **The Scaleway emulated lanes went red on any PR once scaleway provider
  2.83.0 shipped (#179).** No lock file is committed, so CI resolved the newest
  `~> 2.68`; from 2.83.0, destroying `scaleway_instance_private_nic` first calls
  `instance/v2alpha1/.../detach-private-network-interface`, which Feint 0.12.0
  answers 501. Bisected on the fixture root: 2.82.0 applies and destroys clean,
  2.83.0 reproduces the 501. `opentofu-feint` is capped `< 2.83.0` until Feint
  serves the route; the real roots keep 2.83's detach-before-delete fix.

- **`install-shellcheck.sh` died extracting its own download on a bare box,
  which Cléa's probe misreported as a `fluxcd/flux2` bump failure (#174).**
  ShellCheck's release asset is a `.tar.xz`; a bare `ubuntu:24.04` (Cléa's
  probe image) has no `xz`, so `curl` and the checksum both succeeded and
  `tar -xJf` then died with "xz: Cannot exec: No such file or directory" —
  after which `setup.sh` carried on, `flux` never got installed either, and
  the probe blamed flux2 for an environment gap that had nothing to do with
  it. Same shape `install-tflint.sh` already hit and fixed for `unzip`:
  install `xz-utils` when `xz` is missing and apt is available, refuse
  by name otherwise. Reproduced the exact failure in a bare `ubuntu:24.04`
  container (red without the fix, green with it, idempotent on a second run).
- **`feint.sh` checked whether the emulator had restarted exactly once, with
  no retry (#169).** `feint start` returning — even after printing its own
  "listening on ..." line — does not guarantee `feint status` already
  answers. `reset_emulator` (used before every apply/record lane) and the
  `start` command hit this on a GitHub-hosted runner: CI's "Feint Evidence
  (outscale)" job on PR #168 failed with "the emulator did not come back",
  then passed on an unmodified re-run of the same commit. Both now poll for
  up to `FEINT_RESTART_TIMEOUT` (default 10s, integer sleep only — feint also
  ships Darwin binaries and BSD `sleep` rejects a fractional argument) before
  failing, and the failure path prints the emulator's own log (previously
  only `require_emulator` did). New `scripts/dev/test-feint-restart.sh`: a
  stub `feint` puts the startup delay under control; `FEINT_RESTART_TIMEOUT=0`
  reproduces the exact pre-fix behavior through the real code path, not a
  diff revert.
- **`seed-openbao.sh` named a backups bucket that did not exist on any
  cluster deployed under a `bucket_suffix` (#166).** It rebuilt
  `s3-<project>-<provider>-backups-<env>` by hand from `cluster_name`'s first
  segment, while `cluster/backup.tf` and every other shell caller append the
  suffix through `oa_project`; restic and Loki were seeded with the wrong
  name and the seeder printed ✓. It now derives the name through the new
  `oa_backup_bucket()` in `lib/common.sh`, and `test-bucket-names.sh` runs the
  seeder against a stub kubectl and reads the bucket it announces — the
  seventh derivation, compared with the six it already covered.
- **`etcd-snapshot.sh` retention deleted almost everything while a cluster had
  the fewest snapshots to lose.** The prune slice `.[0:(length - KEEP)]` went
  negative with fewer than `KEEP` objects, and jq counts a negative end from
  the END: at `KEEP=30`, 29 snapshots became 1, 20 became 10, every run. The
  end is now clamped at 0. Found by the first harness for the data-loss
  scripts, `scripts/dev/test-state-backups.sh` (backup-state.sh,
  etcd-snapshot.sh, resolve-s3-cred.sh — stub tofu/aws/talosctl recording
  argv AND the credential each call ran with, real gpg round-trip on the
  artifact) and `scripts/dev/test-seed-openbao.sh` (write-if-absent on a
  re-run, which path but never what). Two more defects fell out of writing
  them: an optional tfvars key (`s3_replica_endpoint`, `bucket_suffix`) made
  `grep` exit 1 under `pipefail`, and `seed-openbao.sh`'s `tfvar()` — and
  `lib/common.sh`'s `tfv()` behind six other scripts — killed the caller at
  the assignment with no output at all; both read with `sed -n` now. And
  `s3_cred` with `<kind>`/`<type>` swapped printed the SECRET where an
  access-key id was expected; it refuses.
- **Building a Talos image for one cluster could silently delete the image
  another cluster's tfvars still pinned (#93).** talos-image's root tracks
  exactly one image per provider (`backend.tf`: `key=talos-image.tfstate`, not
  per-version) — retargeting `talos_version` replaced the sole tracked image
  instead of adding a second, and nothing failed until that OTHER cluster's
  next plan/apply, with no visible sign on the account before then.
  `scripts/bootstrap/talos-image.sh` now scans every real
  `cluster/envs/*-<provider>.tfvars` for the version being built (same
  resolution path as `scripts/internal/talos-version.sh`) and refuses, naming
  the conflicting file and both versions, right after the provider is
  resolved — before any credential resolution, bucket creation or
  `tofu init`. New coverage in `scripts/dev/test-talos-image.sh` (a throwaway
  fixture tfvars under the real, gitignored `envs/` dir, removed via
  `trap EXIT`) proves the refusal fires with zero `tofu`/`aws` calls recorded,
  names both versions and the file, and does not fire when the pin matches.

- **`cluster-up` said "complete" without ever asking the cluster**
  ([#84](https://github.com/dis-bzh/OpenAether-infra/issues/84), partial —
  mocked rung only). Its closing banner read "the plan is the verdict, not
  this line" while nodes-Ready, control-plane count, Cilium, CoreDNS, the
  schematic and the state-backup replica all went unchecked, and the task
  always exited 0 regardless. `cluster-up` now ends with `cluster-verify`
  (ROLE/PROVIDER forwarded): a failing verify fails `cluster-up`, and the
  success line prints only once it has passed. `scripts/dev/test-cluster-up.sh`
  runs the real `cluster-up` under go-task with only the leaves stubbed (tofu,
  and every script it calls but the S3 credential resolver): a red verifier
  exits it non-zero with no success line, a green one prints the line after
  the verdict, and the verifier re-fetches kubeconfig after the roll, since
  every cluster in a checkout writes the same path. Seen red on each way of
  breaking that — `ignore_error: true` on the call, the call removed or
  `|| true`-ed, the line moved first, a hardcoded ROLE or PROVIDER, the
  re-fetch deduplicated — so it replaces `test-unattended.sh`'s static read
  of the same edge. `task lint` now fails when a `scripts/dev/test-*.sh`
  harness has no Taskfile `cmds` entry: its reachability check took a comment
  or a CHANGELOG line naming the harness as enough, so dropping this one from
  `task test-scripts` stayed green. Real-cloud rung — the failure seen red on a cluster that
  does not match its config — is still open: Feint only emulates the
  provisioning API, no kubelet/apiserver/Cilium/CoreDNS ever exists under it.

- **The Scaleway security group's documented perimeter and its enforced one
  had drifted apart** (#79). `security.tf`'s own comment said "Talos API —
  From Bastion ONLY" and admitted `:50000` from the bastion's **public** IP —
  a rule that never fires, since the bastion reaches nodes over its private
  NIC. The rule written to admit that traffic (and everything else) was a
  `port = 0`/`protocol = "ANY"` rule matching `172.16.0.0/12` — Scaleway's
  whole IPAM range, not this cluster's own subnet — plus a redundant
  `10.0.0.0/8` rule nothing in this module ever gets an address in. Fixed by
  pinning the private network's own `/22` (`network.tf`, matching OVH's and
  Outscale's existing self-declared-CIDR pattern instead of trusting IPAM
  auto-assignment), scoping the mesh rule to that `/22`, dropping the dead
  bastion-public-IP rule and the `10.0.0.0/8` rule. It also dropped `port = 0`
  from the `protocol = "ANY"` rules and added a `tofu test` run asserting no
  SCW `inbound_rule` carries `port == 0`; neither changed what the API receives
  nor could fail on those rules, and Scaleway groups do not filter private
  traffic at all (see the #79 entry under Fixed). Rung:
  mocked + `task feint-plan`/`feint-apply` against the emulator; the
  real-cloud confirmation (does pinning the subnet force a disruptive
  replacement on an already-provisioned network, do LB health checks and
  Talos API access still work after narrowing) is still open.

- **Four places where `ci.yml`/`task lint` claimed or should have verified
  something and did not — same shape each time, closed or narrowed together.**
  - **Three tool installs in `ci.yml` carried no version pin** (#113) —
    `pip install yamllint`, `apt-get install -y shellcheck`,
    `npx -p renovate`, sitting between a comment arguing against exactly
    that. New `scripts/dev/check-tool-pins.sh` (wired into `task lint`)
    scans every tracked `.sh`/workflow file for the same three shapes and
    fails on any unpinned line outside a small, one-reason-each allowlist —
    generic OS utilities, and the Incus install already pinned by its
    Zabbly channel + GPG key fingerprint rather than an apt version. All
    three are now pinned; shellcheck gets a new
    `scripts/internal/install-shellcheck.sh` (pinned + checksum-verified —
    ShellCheck's releases publish no checksums file, so the four platform
    hashes are pinned inline), called from both `ci.yml` and `setup.sh`.
  - **`flux-bootstrap.yaml.tftpl` was read by nothing, and a comment in
    `ci.yml`'s security job claimed Trivy scanned it** (#114) — `.tftpl`
    matches no Trivy detector, and every yamllint invocation is scoped to
    `*.yaml`/`*.yml`. New `scripts/dev/check-flux-schema.sh` renders the
    template with fixed dummy values and validates it with
    `flux schema validate`, against CRD schemas extracted from the
    VENDORED `flux-install.yaml` — not upstream, which would reintroduce
    the drift `check-version-drift.sh` exists to kill. `ci.yml`'s lint job
    and `setup.sh` both now install the flux CLI and the pinned
    `flux-schema` plugin; the false Trivy claim is corrected.
  - **The seven controller images `flux-install.yaml` pins by tag carried no
    lock** (#119, offline half only — resolving tags to ghcr digests stays
    in Cléa's daily lane, out of scope here). New
    `infrastructure/opentofu/cluster/bootstrap-manifests/upstream-artifacts.lock`
    records the sha256 of `cilium.yaml`/`flux-install.yaml`;
    `render-bootstrap-manifests.sh` regenerates it after every production
    render, and new `scripts/dev/check-upstream-artifacts-lock.sh` (wired
    into `task lint`) verifies it offline.
  - **A 14th check (CodeQL) ran on every PR with no workflow file and no
    mention anywhere in the tree** (#122) — `security.yml`'s "13 required
    checks" was a comment nothing verified. New
    `scripts/dev/check-required-checks.sh` compares the required checks with
    what reports on a commit: offline at first, now live — see "Repository
    settings are checked" above.

- **Three checks that could not fail** ([#75](https://github.com/dis-bzh/OpenAether-infra/issues/75)).
  `test-talos-local.sh`'s Step 5 (schedulable workers Ready) and Step 6 (Flux
  controllers running) still degraded to `warn` after the same bug was fixed
  for the etcd and CNI checks right above them — a cluster where workers never
  became schedulable-Ready, or Flux never came up, still reached the
  unconditional "validated end-to-end" banner. Both are now fatal, same
  `if`/`error`/`exit 1` shape as their neighbors. `check-skill-parity.sh`
  diffed the shared `SKILL.md` files between this repo and its
  `OpenAether-apps` sibling but not `check-language.sh` itself, so widening
  the French-word list in one copy and not the other would pass silently;
  added the same byte-for-byte `diff -q`. `check-language.sh`'s prose scanner
  read comment lines, `echo`/`print`/`printf`/`puts` lines and
  `help=`/`description=` lines, but not the body of a `cat <<EOT` heredoc —
  exactly the shape that hid the `fleet-down.sh` `<projet>`/`<project>`
  mismatch; reused the existing heredoc state machine (already handled HCL's
  `description = <<-EOT`), triggered by a narrow `cat`/`cat >&N` opener that
  excludes `cat > file <<EOF` and piped heredocs on purpose.

- **`test-talos-image.sh` and `test-unattended.sh` had gaps an adversarial
  pass could walk through** ([#60](https://github.com/dis-bzh/OpenAether-infra/issues/60)).
  `test-talos-image.sh`: the `-var` assertion was anchored to `-var ` with a
  trailing space, so the single-token `-var=` form passed while the message
  said it did not; nothing tied the saved plan's filename to the `$TGT`
  discriminator `talos-image.sh` bakes into it, so dropping `$TGT` from the
  filename went unnoticed. `test-unattended.sh`'s embedded Python shell
  reader: its "interactive exemption" credited an `exit` found anywhere in an
  `if`/`else` block, not scoped to the branch actually reached when the tty
  test fails, so a script that prompts but does not refuse headless could
  still claim it; `blank` for a `$(`/`$((` scope was computed from the WHOLE
  quote stack instead of the active frame, so a heredoc opened inside
  `"$(...)"` (reproduced against `test-bucket-names.sh`'s own heredoc) read as
  quoted text and the heredoc-skip path never fired, corrupting the parse of
  everything after it; `task_call()` skipped every `-`-prefixed token as a
  bare flag with no notion of a go-task flag that consumes the next one
  (`-d`, `-t`, `-o`), so `task -d somedir cluster-up` read `somedir` as the
  callee and the real one went unseen; the anti-abuse check was a literal
  path substring search, missing a script CI reaches only through a Task
  wrapper; the floors asserted "non-zero", so a real count of 8 dropping to 1
  stayed green; the `ENSURE` check accepted any non-empty string, including
  an unresolved forward like `ENSURE: "{{.ENSURE}}"`. Each fix was proven
  against a mutation shaped like its defect — confirmed red before the fix,
  green after, on the harness itself as well as on the real unmutated tree.

- **Cléa's report-issue picker grabbed the newest `clea`-labelled issue, not
  necessarily its own report** (#127). The workflow's "Previous state, from
  the report issue" step fetched with `per_page=1` on the API's created-desc
  default sort, so any newer issue a human labelled `clea` — to cross-reference
  a finding, the natural thing to do — won over the real report and got
  PATCHed over wholesale on the next scheduled run; #104 clobbered #91 exactly
  this way on 2026-08-28. The selection logic now lives in
  `scripts/clea/clea.py` (`pick_report_issue`, wired as the `pick-issue`
  subcommand) and picks by what only the automation itself ever writes — the
  `render_report` marker as the first line of the body, from an issue authored
  as `[report] bot_login` (default `github-actions[bot]`) — instead of
  creation order. `clea.yml` now fetches every open, labelled issue and calls
  `clea pick-issue` rather than trusting `per_page=1`.

- **The bastion's SSH-CA hooks shipped inert since they were written** ([#81](https://github.com/dis-bzh/OpenAether-infra/issues/81)).
  `_shared/bastion-cloud-init.yaml.tftpl` hardcoded `TrustedUserCAKeys` and
  `AuthorizedPrincipalsFile` to an always-empty file and directory, so no
  caller could ever turn SSH-CA on — every bastion stayed on a static key
  only a `tofu apply` can revoke. Both are now real template variables
  (`ssh_ca_public_key`, `ssh_ca_principals`), default `""`, threaded through
  all four providers' `bastion.tf` and the Feint fixture — identical
  rendered bytes when unset. New `scripts/dev/ssh-ca-check.sh`
  (`task ssh-ca-check`) proves it on a real sshd in Docker: a CA-signed
  certificate authenticates, the same bare key without it is refused, and
  `ssh -o ExitOnForwardFailure=yes -L` carries traffic through `PermitOpen`.
  Rung: emulated.

- **A comment beside the Outscale provider block claimed the top-level
  `region` argument was deprecated and warned on every real command**
  (#77). Stale: `outscale/terraform-provider-outscale` reverted that
  deprecation in its own PR #817, shipped in 1.8.0 — the version this repo
  already pins. Real commands no longer warn, so there is nothing left to
  avoid by building the API URL ourselves (which would mean hardcoding
  Outscale's DNS). Comment now records the decision instead of a stale
  premise; no behavior change.
- **`docs/emulated-cloud.md`/`.fr.md` documented three Feint gaps as
  permanent** — Outscale load balancers ("this one will not move"), Scaleway
  IPAM reservations, Scaleway LB and public gateway ("genuinely absent") —
  and Feint 0.12.0 closed all three. Re-measured 2026-08-31 with
  `task feint-record` on both providers: *"every operation the client called
  is served by a pack"*, zero unserved calls where the 0.7.3 recording listed
  three. `feint-record`'s own apply is a real `tofu apply
  -target=module.<provider>` on the cluster root itself, so this is also
  proof that root's provider module can now be applied against the emulator,
  not only planned — `feint-plan`'s "plan only" framing was stale for the
  same reason. Docs updated in both languages; the closed gaps moved from
  the table to the "left this list" history alongside the ones 0.6.0/0.7.0
  already closed.
- **The docs-only CI gating (just added below, same cycle) left every
  genuinely docs-only PR permanently "blocked"** ([#146](https://github.com/dis-bzh/OpenAether-infra/pull/146),
  the first PR to hit the skip path for real). Root cause is a documented
  GitHub Actions limitation (actions/runner#952): a job-level `if:` that
  evaluates false skips a matrix job *before* its matrix expands, collapsing
  every combination into ONE check reported under the job's raw, unexpanded
  name — `Validate` instead of `Validate (cluster)` / `Validate
  (talos-image)`, literally `Emulated Cloud (${{ matrix.provider }})` instead
  of `(scaleway)` / `(outscale)`. None of those match the per-matrix
  required-check names branch protection expects, so the PR sits blocked
  forever. Fix: `validate` and `emulated` (the two matrix jobs) no longer
  carry a job-level `if:` — the job always runs and the matrix always fully
  expands; the substantive steps inside are gated instead, so every
  per-combination check name always exists and reports fast when
  `code == 'false'`. The four non-matrix gated jobs (`manifests`, `test`,
  `talos`, `security`) keep job-level gating, unaffected by this. The
  `changes` job itself also no longer skips on push (short-circuits to
  `code=true` internally instead) — a skipped `changes` job would fail the
  matrix jobs' own `needs` gate the same way.

- **`check-commit-authors.sh` could read its own `git log` failure as "no
  commit is authored by a tool" (#132).** `set -e` does not propagate a
  failure inside a process substitution (`< <(git log … )`) — a malformed
  rev-range from a future CI edit would leave the `while read` loop with
  nothing to read, zero iterations, and the script printed its success line
  over a check that never ran. `git log` now writes to a file first and its
  own exit status is checked before anything reads it. Not yet exercised by
  CI's own wiring (the `commits` job always passes a valid range), so this
  was latent, not live — reproduced and fixed anyway.

- **`test-talos-local.sh` hung for 90s on a host missing `CAP_SYS_RESOURCE`,
  then failed on an unrelated-looking timeout**, instead of the ~1s refusal
  its siblings give when no local cluster is reachable
  ([#54](https://github.com/dis-bzh/OpenAether-infra/issues/54)). New
  `scripts/dev/check-docker-talos-capability.sh` (same fail-open shape as
  `check-host-ports.sh`) catches it in milliseconds via the `capsh` probe
  `infrastructure/opentofu-local/README.md` already documented; wired into
  both `test-talos-local.sh` and `task local-up`, which shares the identical
  exposure.
- **Six gates were reporting green on something they had stopped checking.**
  Found by auditing what the pipeline actually constrains, and each one is
  reproduced in both directions — broken on purpose, watched go red, fixed,
  watched go green.
  - **`tflint` linted one directory out of fourteen.** The config lived in
    `cluster/`, and `tflint --recursive` resolves `.tflint.hcl` per directory —
    so the preset, the naming rule and the documentation rules applied nowhere
    else and the gate exited 0. Hoisting the file alone does **not** fix it (a
    parent config is never found either): `scripts/dev/tflint-all.sh` names the
    config through `TFLINT_CONFIG_FILE` and proves it loaded against a fixture
    that must draw a rule only this config enables — by rule *name*, since the
    default rules reject that fixture too and the exit code proves nothing.
    First finding on the newly-linted directories: `talos-image/variables.tf`'s
    `encryption_passphrase` had no description.
  - **`try()` hid a broken provider contract.** `cluster/main.tf`'s junction
    point read every provider output through `try(module.x[0].out, null)`, which
    cannot tell "this provider is inactive" from "this output does not exist".
    Measured: with `k8s_lb_ip` deleted from a provider module, `tofu validate`
    answered **Success!** and an apply would have yielded `null`, falling back to
    the literal `127.0.0.1` and failing at Talos, on a paid cluster. Now `one()`,
    which returns null at count 0 and refuses an undeclared attribute: the same
    tree answers `This object does not have an attribute named "k8s_lb_ip"`.
  - **Sixteen of the eighteen shell assertion harnesses could pass without
    asserting anything.** Thirteen ended on a bare `[ "$FAIL" -eq 0 ]` — true
    when the file died before its first assertion — and three more said the same
    thing in their own shape (`report()`, an `RC` accumulator, an `if`). All
    eighteen now carry the floor that `test-talos-image.sh` and
    `test-unattended.sh` already had. Worse, `test-endpoint-probe.sh` printed ✓ for a function that did not
    exist: `fn … && bad … || ok …` takes the `||` branch on rc 127 too. New
    `oa_require_fn` refuses to grade a function that is not defined.
  - **Two checks abstained in silence.** `render-bootstrap-manifests.sh --check`
    printed one warning mid-scroll when upstream was unreachable and `task
    preflight` still announced "every free rung passed"; it now fails, says
    *could not check* rather than *does not match*, and takes
    `RENDER_CHECK_ALLOW_OFFLINE=1` for a deliberate offline run — which
    `preflight` then reports as incomplete. `talos-image.sh` was worse: when the
    Factory answered with no schematic id in it (a rate limit, an error body — a
    *failing* curl aborts under `set -e`, so that was never the case), both the
    refusal and the reassurance were skipped and the run went straight to "image
    already up to date", one step from a billable publish. Now refused, or
    stated aloud under `TALOS_IMAGE_ALLOW_OFFLINE=1`, and covered by four new
    assertions in `test-talos-image.sh`.
  - **`provider-contract.md` had zero implementers on one of its rows.** It
    required a variable named `bastion_ssh_key` of type `string`; all four
    modules have always declared `bastion_ssh_keys` as `list(string)`, and a grep
    for the contract's name found exactly one hit in the repository — the
    contract's own line. This is the document `CLAUDE.md` and the
    `provider-module` skill both call the authority. The tables are now executed
    by `scripts/dev/check-provider-contract.sh`, by name and by type.
  - **The French detector could not read an HCL `description` heredoc**, so a
    whole French sentence sat mid-paragraph in an otherwise English block in
    `ovh/variables.tf` — in text `tofu` prints to the operator. The heredoc body
    is neither a comment nor a `description=` line, which is all the scanner
    looked at. Detector extended, sentence translated.

- **The French `admin-access` runbook was missing the fix that PR #14 landed for
  the English one**: the four CNPG/Longhorn seed paths and the warning above
  them. A French-speaking operator following it hit the silent auth failure that
  block exists to prevent — and both files carried the same last commit, which is
  exactly why "we commit them together" is not parity.

- **A tool could be the git author of a commit, and nothing looked.** The trailer
  check reads the message; GitHub builds a squash commit's `Co-authored-by` from
  the *branch* commits' authors, so by the time a message carries the trailer it
  is already on `main` — seventeen of the fifty commits there do. Measured on
  PR #106: its `0764f61` is authored by `Claude <noreply@anthropic.com>`. New
  `scripts/dev/check-commit-authors.sh`, run in CI on the PR range, which is the
  only place it can still be refused.

- **The version-pair guard was only tested on its start and end points, never
  the path between them (#50).** A valid pair joined to another valid pair by
  a step that is neither still passes if nothing evaluates the step. Seven
  new `tofu test` run blocks in `version-pair.tftest.hcl` walk every
  intermediate pair of the documented climb from (v1.12.7, v1.31.0) to
  (v1.13.9, v1.36.3) — Talos moving first, then Kubernetes one minor at a
  time — plus one trap pair (v1.13.9, v1.30.0: Talos ahead of Kubernetes
  catching up) that the guard must refuse. Mutation-verified: narrowing
  `k8s_min` in `version-support.json` turned one of the new intermediate runs
  red before the revert.

- **`task talosconfig-new` could not find a node on any cloud lane, and would
  have signed with another cluster's admin config (refs #80, mocked part).**
  The script asked the state for `control_plane_ips`, an output only the Docker
  root declares (the cluster root's is `control_plane_private_ips`), and the
  task ran with no data dir and no S3 key, so it always stopped at "no node to
  ask". The script now picks the output by lane, and the task runs `kubeconfig`
  first, for the cluster's own data dir and S3 key and a fresh copy of its
  admin talosconfig, a file every cluster in a checkout shares. It also takes
  `ROLE=`. `kubeconfig` now captures `tf-backend.sh`'s answer before
  `tofu init`, so a mistyped `ROLE=` stops instead of initialising a bare
  backend; eight other tasks still use the old form. New
  `scripts/dev/test-talosconfig-new.sh`, in `task test-scripts`, runs the real
  task under go-task with tofu and talosctl stubbed: 2 passed and 7 failed on
  the previous code, 9 and 0 now, and red on each of eight one-line mutants.
  The cloud path, through the tunnels, has still never run.

- **`task cluster-up VERSION=…` was advertised and ignored.** A task-level
  `VERSION` read from the tfvars shadowed the command line: with the pin at
  v0.0.1, `VERSION=v9.9.9` built v0.0.1 without a word (go-task 3.53.1,
  stubbed leaves). It leaves the usage instead of being wired, because the
  tfvars pin decides the version and `talos-image.sh` refuses a build that
  differs from it (#93). `cluster-up` still ignores a `VERSION`, typed or
  exported for another reason: it passes `ROLE` to `image-build`, which reads
  the pin itself, and blanks `VERSION`, which go-task would otherwise hand
  down. `test-cluster-up.sh` covers both forms and a workload cluster's own
  pin. `task image-build VERSION=…` is unchanged.

- **Wrong statements about a deploy.** The Taskfile said `cluster-up` asks
  once; it asks twice, on the phase-1 infrastructure plan and on
  `bootstrap-phase2`'s (the image build and the version roll apply without a
  question), as `docs/first-cluster.md` already said. `cluster-upgrade`'s
  description said its applies ask for approval; it runs them all with
  `APPROVE=auto`. The `bastion_user` output said root on Scaleway and ubuntu on
  OVH and Outscale; the value is `bastion` on all three, and `host_ssh_user` on
  Proxmox.

- **The mocked suite now sees what a review of #198, #199, #200 and #202 found it
  could not.** `test-feint-restart.sh` asserts that the record lane's apply goes
  to the proxy (its stub `tofu` passes on request and logs the apply) and that a
  dead proxy fails the lane. `task fmt` formatted the current directory on an empty
  file list; the check now sits in `TF_FMT_FILES`, which `lint` shares. The new
  `test-task-guards.sh` runs the real Taskfile for that list, the `TF_ROOTS` check,
  the hook/`TF_FMT_RE` comparison and the `envs/` write guard of `test-scripts`.
  `task talosconfig-new` pins `TALOSCONFIG` to the admin config it has just
  fetched: an exported one from another cluster signed the reader config. Its
  hints and that case are asserted. Wording: the upgrade skill, the CHANGELOG
  on dry runs, "those tfvars". Ten mutants, each turning its test red.

- **The rung check's docs now say what it cannot see, and the required-checks
  audit covers two more shapes (follow-up to #205).** `repo-settings.yml` is
  skipped on forks, which have no such rulesets. `check-required-checks.sh
  --self-test` gains two cases: a required context pinned to another app, and a
  tag ruleset matching `refs/tags/*` only, which misses tags with a slash. The
  rung check cannot tell what a green run exercised, so a verify or teardown
  target backs its rung like any other; `rung-receipt.py` says so instead of
  implying otherwise, and `ssh-ca-check.sh` names its rung `local-docker`, not
  `emulated`.

- **With `enable_bastion = true` on Proxmox, the root now reports the user the
  bastion VM creates (#201).** `local.bastion_user` was `host_ssh_user` whatever
  the module did; the VM's user is `ubuntu`, so the tunnels and `talosconfig-new`
  would have logged in as `root`. It now reads the module's `bastion_user` output.
  A `tofu test` asserts the root against the module for both values of
  `enable_bastion`. A real tunnel through a Proxmox VM bastion is not observed, and
  whether `ubuntu` joins `bastion-admins` (the OVH/Outscale collision) is still
  open on that issue.

- **A Talos bootstrap the state forgot is adopted before phase 2 re-sends it
  (refs #67, refs #40).** An apply that is interrupted after the node accepted
  the Bootstrap RPC leaves no `talos_machine_bootstrap` in state, so the next
  phase 2 sends it again at a live etcd, which refuses it with `AlreadyExists`.
  `bootstrap-phase2` now runs the new `scripts/bootstrap/adopt-bootstrap.sh`
  once the tunnels are open. If
  the state lacks `module.talos.talos_machine_bootstrap.this[0]` and any control
  plane answers `talosctl etcd members` with exit 0 and a `:2380` row, it runs
  `tofu import -var skip_health_check=true` on it (the import also reads the
  cluster-health data source, which runs to its 15m timeout and fails it when no
  healthy cluster answers);
  otherwise, including a node that does not answer within `ADOPT_PROBE_TIMEOUT`
  (15s), it changes nothing. A fresh cluster pays up to that timeout per control
  plane. The import fails the task only after etcd has answered, with the command
  to run by hand. A successful import writes state BEFORE phase 2's approval
  prompt, and declining that plan does not undo it (the state is not backed up
  first): `tofu state rm 'module.talos.talos_machine_bootstrap.this[0]'` does,
  and the script prints it.
  `test-adopt-bootstrap.sh` (stubbed `tofu` and `talosctl`) holds each of those
  branches, and `test-cluster-up.sh` the call order. `test-bootstrap-import.sh`
  runs the pinned talos provider offline: a create against a closed port leaves
  the resource out of state, an import reads the health data source and fails on
  its timeout unless that is skipped, an import with any ID then succeeds, the
  plan is an in-place update that applies in under a second with no RPC, and the
  re-plan is empty. Not observed: what `talosctl etcd members` prints on a real
  node in each state, so whether the guard ever fires; the import on the real
  cluster root (the scratch config holds only the provider and that data source,
  with the real module's `count` line, which the harness refuses to run without
  `skip_health_check`); the data source against a reachable, unhealthy cluster
  (seen only against a closed port); that a control plane with an empty disk accepts a
  second Bootstrap and forks etcd (upstream behaviour, and the reason every
  control plane is asked and any member row counts). The other control planes'
  etcd (#40) is not touched, and both issues stay open for a real interrupted
  bootstrap.
- **`task infra-down-plan` is tested against a pinned image that is gone (refs
  #69).** #69 says such a cluster cannot be destroyed, because the destroy plan
  still evaluates the image lookup. The `-refresh=false` fallback, added for the
  Outscale load balancer, plans such a destroy, and nothing tested that.
  `test-task-guards.sh` now runs the real target under the real tofu, on a root of
  builtin providers standing in for the lookups: a data source that errors
  (Scaleway, OVH) and a `coalesce` over an empty answer (Outscale). The refreshed
  plan fails and the state-only plan is written, with its deletion; with the image
  present there is one refreshed plan; with both plans failing the target exits
  non-zero and writes none. The warning now names the pinned image as a cause. Five
  mutants of the target (no fallback, fallback first, fallback without
  `talos_bootstrap=false` or `-out`, failure swallowed) each turn it red. Mocked
  rung, plan half only. Not shown: that the real providers fail their lookups like
  the stand-ins, which only #69's own measurement says; that the apply of the
  state-only plan destroys anything; and #69 itself, two versions kept side by
  side with a node created on the older one, which stays open on a real cloud.

- **`task upgrade PROVIDER=x DRY_RUN=1` now makes a dry run.** A Task variable is
  not an environment variable, and `cluster-upgrade.sh` reads `DRY_RUN`,
  `UPGRADE_TALOS_TO` and `UPGRADE_K8S_TO` from the environment, so the
  command-line form was ignored and a real upgrade started. The target now passes
  the three on, empty when unset. `test-task-guards.sh` runs it against a stub
  script, from the command line and from the shell; deleting the `env:` block
  turns it red. Mocked rung; no upgrade was run.

### Added

- **New `feint-apply-root` lane: an untargeted apply on the REAL cluster
  root, not a fixture or a `-target`-scoped one (#76, first half).**
  `feint-plan` only plans `infrastructure/opentofu/cluster`; `feint-apply`
  drives the separate reduced fixture (`infrastructure/opentofu-feint/`);
  `feint-record`'s own apply is `-target=module.<provider>`-scoped to the
  provider module alone. Nothing ran a full `tofu apply` on the real root
  itself — Talos config, bootstrap manifests, everything. `task
  feint-apply-root PROVIDER=scaleway|outscale` (`scripts/dev/feint.sh
  apply-root`) now does that: untargeted apply → verify the second plan is
  empty → the two-step destroy the root README already documents (`tofu
  state rm module.talos.talos_machine_secrets.this[0]` first, since that
  resource carries `prevent_destroy`, then `destroy -var
  talos_bootstrap=false`). Verified both providers: 27 resources added on
  Scaleway, 41 on Outscale, second plan empty, destroy clean. Closes #76's
  first criterion; the second (`feint shapes --check` against a real-cloud
  recording) stays open — real-cloud only, not attempted here.

- **The Scaleway feint lane resolves its image by name instead of skipping
  the lookup (#150).** `data.scaleway_instance_image.talos` in
  `modules/providers/scw/main.tf` — the real, production `image_name`
  lookup — had a `count` of 0 on every feint run because
  `envs/feint-scaleway.tfvars.example` pinned `image_id` instead, dating
  back to when Feint declined `instance/v1 ListImages` outright. As of
  0.12.0 that route is served, along with `CreateSnapshot` and
  `CreateImage` (the latter enforces a real dependency: a made-up snapshot
  id gets a genuine 404, not a rubber stamp). `scripts/dev/feint.sh` now
  registers a throwaway image under the name the tfvars ask for — volume →
  snapshot → image — before planning or applying, so the data source
  resolves it for real. Verified on both lanes: `feint-plan` completes with
  the data source resolved (a failed lookup errors `tofu plan` outright,
  it does not silently degrade), and `feint-record`'s transcript now shows
  the module calling `instance/v1/API.ListImages` and `GetImage`, which a
  pinned `image_id` never triggered.

- **`feint evidence baseline`/`evidence verify` wired in, with a real,
  committed baseline (#151).** Feint 0.12.0 lets a downstream project pin
  the level of proof — seven independent axes per operation — it actually
  relies on, and fail its own CI the day Feint stops delivering one,
  instead of finding out from the outside after the fact. `feint evidence
  baseline` refuses unconditionally, before any `--axes` filtering, when
  the record it is pinning was earned with no machine runtime
  (`internal/cli/evidence_baseline.go`'s `reachesARuntime`) — every
  `dataplane` verdict would be a hardcoded `false`, and pinning that would
  report nothing on the day it regressed for real. New `scripts/dev/feint.sh
  evidence|evidence-baseline|evidence-verify`, `task
  feint-evidence`/`feint-evidence-verify`, and a `feint-evidence` CI job
  that installs Incus (the same Zabbly-stable recipe `stephrobert/feint`'s
  own CI proves on GitHub-hosted runners) and runs the fixture's full
  apply/destroy cycle under it — unverifiable locally, this environment's
  egress policy blocks the Zabbly package host outright.

  `.feint-evidence-scaleway.json` / `.feint-evidence-outscale.json` are the
  real committed artefacts: pulled from two independent green CI runs of
  that job (not hand-transcribed — a log line is not a build artifact, so
  the job also uploads the baseline it captured, and this is that upload,
  downloaded back), byte-identical between them, and `feint evidence
  verify` now runs against them on every push. One of those two runs also
  measured the only rough edge so far: `Feint Evidence (outscale)` failed
  once with the emulator gone entirely between `feint start` confirming
  "running" and the next command's own check — passed clean on the
  immediate re-run and on scaleway throughout, so this reads as a
  startup race under Incus rather than a real defect. The job stays
  `continue-on-error` until that is either reproduced and fixed or seen
  stable across enough runs to trust as a hard gate.

- **Two Checkov custom checks close the gap for the three providers Checkov
  ships no policy family for (#123).** `.checkov.yaml` is a hard gate, but
  measured on this tree Checkov's built-in rules land on OpenStack (OVH)
  alone — 84 of 131 provider resources (Scaleway, Outscale, Proxmox) passed
  through it in silence, indistinguishable in a CI log from a clean scan.
  `infrastructure/opentofu/checkov-custom-checks/` expresses two rows of
  `provider-contract.md` as checks instead of prose: `CKV_OA_1` (every
  control_plane/worker node ignores its boot-image attribute — without it a
  routine `tofu apply` after a `talosctl upgrade` replaces every node at
  once, all control planes together, and etcd loses quorum) and `CKV_OA_2`
  (a security group's inbound default policy must be `drop`). Both are
  mutation-tested against the real tree (`test-checkov-custom-checks.sh`,
  wired into `task security`): break either rule, watch it name the exact
  resource, restore, watch it pass again. The directory's `__init__.py` is
  load-bearing — without it Checkov registers nothing and still exits 0,
  the exact false green this fix exists to close, confirmed by removing it.
- **`check-dead-references.sh`, wired into `task lint` (#118).** A path stops
  resolving and nothing notices — read once in a comment, or read (and
  copy-pasted) on every run in a printed string. lychee finds none of this:
  this repository writes commands as bare paths inside fences, not Markdown
  links, and lychee reads neither comments nor printed strings. Scope is
  deliberately PATHS only, inside a fenced block, a backtick span, a code
  comment, or a printed string — `task [a-z-]+` alone gave ~45 false positives
  ("task is", "task and", "task was") against real ones while scoping this.
  First run on this tree found two real stale references, both citing the
  now-deleted docs/backlog.md: `scripts/setup.sh` and
  `scripts/ops/verify-provider-clean.py`, now fixed.
  `.deadreferencesignore` allowlists what a regex genuinely cannot see (a doc
  narrating its own removed file's name, an example value in a portable
  tool's own README, a cross-repo path stated bare) — scoped per
  file:candidate pair, never a whole file, and each entry carries a reason.
- **`task pipeline-audit`** runs the CI policy scanner (plumber) locally —
  before this, the only way to see its verdict before pushing was to fetch
  the binary by hand ([#52](https://github.com/dis-bzh/OpenAether-infra/issues/52)).
  New `scripts/internal/install-plumber.sh` (pinned, checksum-verified, same
  shape as `install-gitleaks.sh`); wired into `task security`, last, since
  without `GH_TOKEN` it legitimately exits 3 ("incomplete data" — branch
  protection cannot be evaluated) and must not swallow the checks that CAN
  succeed offline.
- **`task purge-orphans PROVIDER=… [APPLY=1]`.** `docs/release-checklist.md`
  already told the reader to run it; it did not exist. The scripts it wraps are
  the last sentence between a failed teardown and a bill, and they were reachable
  from prose only.
- **`flux_namespace` is validated.** The vendored `flux-install.yaml` creates
  exactly one namespace, `flux-system`, and every namespaced object in it points
  there. Any other value renders inlineManifests aimed at a namespace nothing
  creates — and Talos applies inlineManifests with no ordering and no namespace
  creation, so it fails on a paid cluster with every offline gate green. No
  schema validator can see it: `namespace: gitops` is valid YAML.

- **`task talosconfig-new`** — issues a role-scoped talosconfig with a TTL
  (`os:reader`, 8 h by default) from the admin one, which the deploy hands out
  as `os:admin` valid a **year**, identical for every task and every person.
  It refuses to report success if the node grants roles other than those asked.
  ⚠️ Proven on the Docker lane only; the cloud path needs open tunnels and has
  never been run.
- **`task local-rbac`** — asks the Docker cluster whether Talos *enforces* those
  roles, which nothing here had ever established. Seven assertions, and each
  denial carries its admin control beside it so a broken command cannot read as
  a refused one. Measured 2026-08-24 on Talos v1.13.3: the node reports
  `Enabled: RBAC` with no `machine.features.rbac` anywhere in this repository,
  an `os:reader` config is refused a host read the admin config gets, and it
  cannot mint itself an `os:admin` one.

- **Cléa — a daily watch on what this repository pins, and a probe that installs
  the bump before anyone merges it.** `scripts/clea/` holds a generic engine
  (Python, standard library only, no knowledge of this project); `clea.toml`
  holds everything specific to it; `.github/workflows/clea.yml` runs it. Renovate
  keeps proposing the bumps — Cléa watches, probes and reports, and no lane of it
  can reach a cloud.
  - **Daily**: resolve every pin against upstream, then for each tool that moved,
    install it from cold and upgrade it over the old version in a bare
    `ubuntu:24.04`, then run `task lint`, `task render-check` and
    `task test-scripts` on the bumped tree. The upgrade half is the one that
    finds things: an installer that checks whether a binary exists, rather than
    which version it is, installs correctly once and refuses every upgrade after
    that — which is exactly what `scripts/dev/feint.sh` had done until
    2026-08-21.
  - **Weekly**: `task local-up` on the Talos and Kubernetes pair upstream
    publishes, then `task local-verify`. Real cloud stays manual.
  - **One report issue**, rewritten in place, which also carries the previous
    run's state so "this moved since yesterday" needs no artifact store.
  - **A heartbeat on the bot that proposes the bumps.** The scan records when
    `renovate[bot]` last opened a pull request, and crosses it with what Cléa
    found: a dependency behind *and* visible to the bot's own inventory, with no
    proposal for days, means the bot is not running. Silence on its own raises
    nothing — a bot with nothing to propose is silent and correct.
  - What it refuses to do: a datasource that answers nothing, a tree with no
    anchors and a writer that writes nothing all exit 1. An unauthenticated
    GitHub API answer is an error naming `GITHUB_TOKEN`, never "up to date" —
    60 requests an hour from a shared runner IP is what took `main` red on
    2026-08-13. Documented in [`docs/clea.md`](docs/clea.md).
  - **The probe found its first defect, and the same probe proved the fix.**
    `setup.sh` installed helm 4.2.4 from cold and left 4.2.3 in place when
    upgrading over it — the exact shape the upgrade lane exists to catch. After
    the fix, three lanes of three green. That loop, not the daily report, is
    what this is for.
  - **What the first real scan found**, running against live upstreams:
    `commitizen` pinned at 4.9.1 against 4.18.0 — nine minor versions, on one of
    the anchors that was inert — and the Cilium chart one patch behind at 1.20.0
    against 1.20.1. A Cilium bump was then walked through by hand: `task
    render-check` goes red on the stale manifest, the render lane closes it, and
    both go green. The GitHub datasources answered 403 in that session and were
    reported as failures, which is the behaviour that matters most: a
    datasource that did not answer is not a dependency that is up to date.
  - **The workflow's own first real run found what a bare-container probe
    could not.** Triggered by hand 2026-08-24 (`daily` lane): three probes —
    `commitizen`, `opentofu/opentofu`, `siderolabs/talos` — failed with
    "refusing to allow a GitHub App to create or update workflow… without
    `workflows` permission". All three are anchored (also) inside
    `.github/workflows/ci.yml`, and `GITHUB_TOKEN` cannot push a change to a
    workflow file in any repository — there is no `permissions:` grant for it.
    Two fixes: the Report job now cross-references the run's own job list, so
    a probe that fails before it can push is *named*, not silently absent from
    the report; and an optional `CLEA_WORKFLOW_TOKEN` secret (classic PAT,
    scope `workflow`), wired into both push sites with a clean fallback to the
    default token when unset, closes the gap for real where it is set.

### Changed

- **`stephrobert/feint` 0.12.0 → 0.13.0; the Scaleway image is now cut from
  a never-started server's root disk (#177).** 0.13.0 refuses, like fr-par,
  to snapshot a volume nothing was ever attached to, so `feint.sh` died on its
  bare volume. It now snapshots a helper server's `l_ssd` root, then deletes
  the helper and its disk, on failure too. 0.13.0 also refuses `b_ssd`, so the
  fixture's data volume is `l_ssd`. Proof on 0.13.0: `task feint-test` green,
  both providers.
- **`fluxcd/flux-schema` 0.12.1 → 0.13.0** in `.github/workflows/ci.yml` and
  `scripts/setup.sh`, probed green by Cléa (issue #91). `task lint` (including
  a real re-install of the `schema@0.13.0` plugin and a re-run of
  `check-flux-schema.sh` against it, not just the cached 0.12.1 already on
  this sandbox), `task render-check`, `task test-scripts`, `task validate`
  (both roots), `task test` (61/61), checkov (32/0) + custom checks, and a
  default-rules gitleaks dir scan all green on the bump.

- **`helm/helm` 4.2.4 → 4.3.0** in `.github/workflows/ci.yml` and
  `scripts/setup.sh`, probed green by Cléa in a later refresh of the same
  issue #91 report and added to this same branch/PR (this routine keeps at
  most one open `claude/clea-bump-*` PR at a time). Major stays 4, so
  `HELM_MAJOR_EXPECTED` in `scripts/bootstrap/render-bootstrap-manifests.sh`
  needs no change. Proven against the real binary, not just the sandbox's
  cached 4.2.4: downloaded `helm-v4.3.0-linux-amd64.tar.gz`, verified its
  sha256 against the upstream checksum file, installed it, then re-ran
  `task render-check` (cilium.yaml + flux-install.yaml regeneration) against
  it — green. Full gate set green: `task lint`, `task render-check`,
  `task test-scripts`, `task validate` (both roots), `task test` (61/61),
  `check-version-drift.sh`, checkov (32/0) + custom checks (6/0), and
  gitleaks (matching `task security`'s own tracked-files-only invocation,
  not a raw `gitleaks dir .` — the sandbox's own untracked, gitignored Feint
  state file flagged a false positive under the naive form).

- **`commitizen` 4.18.0 → 4.18.1** in `.github/workflows/ci.yml`'s single
  `pip install` anchor, probed green by Cléa in a further refresh of the same
  issue #91 report and added to this same branch/PR. Proven against the real
  package, not just the sandbox's absent install: `pip install
  commitizen==4.18.1`, then `cz check --rev-range origin/main..HEAD` — the
  exact command CI runs — passed against this branch's own commits. Full gate
  set green: `task lint`, `task render-check`, `task test-scripts`,
  `task validate` (both roots), `task test` (61/61), `check-version-drift.sh`,
  checkov (32/0) + custom checks (6/0), and gitleaks (same tracked-files-only
  invocation as above).

  Left out of this batch, all `❌ probe failed` or `not probed` in the same
  report: `flux2` (3 anchors, probe container missing `xz`, see #174),
  `plumber` v0.4.51 → v0.4.62 (2 anchors — the `security.yml` one is
  `action-sha`-pinned and `clea bump` correctly refuses it, same as the
  v0.4.51 bump above), `talos`/`kubernetes` (blocked on the Kubernetes
  support-matrix range for Talos 1.14, tracked in draft PR #149), and `feint`
  0.12.0 → 0.13.0 (probe fails on stale doc version references).
  `task security`'s `trivy` step could not run in this sandbox (no
  network) — relies on CI.

- **`cilium` 1.20.1 → 1.20.2** in `scripts/bootstrap/render-bootstrap-manifests.sh`,
  probed green by Cléa in a later refresh of the same issue #91 report and
  added to this same branch/PR. Manifest re-rendered immediately after the
  bump (`bootstrap-manifests/cilium.yaml` and `upstream-artifacts.lock`
  regenerated), per the routine's own rule for a cilium version change. The
  `README.md`/`README.fr.md` "Layer status" tables, which stated the old
  1.20.1 as the current CNI version, are updated together. Full gate set
  green: `task lint` (including `check-upstream-artifacts-lock.sh` against
  the regenerated lock), `task render-check` (including
  `check-cilium-effective-config.py`), `task test-scripts`, `task validate`
  (both roots), `task test` (61/61), checkov (32/0, `--config-file
  .checkov.yaml`) + custom checks (6/0), and gitleaks (same tracked-files-only
  invocation as above, plus `check-gitleaks-rules.sh`). `trivy` again not run
  in this sandbox — relies on CI.

- **`commitizen` 4.18.1 → 4.19.0** in `.github/workflows/ci.yml`'s single
  `pip install` anchor, probed green by Cléa in a further refresh of the same
  issue #91 report and added to this same branch/PR. Proven against the real
  package, not just the sandbox's absent install: `pip install
  commitizen==4.19.0`, then `cz check --rev-range origin/main..HEAD` — the
  exact command CI runs — passed against this branch's own commits. Full gate
  set green: `task lint`, `task render-check`, `task test-scripts`,
  `task validate` (both roots), `task test` (61/61), checkov (32/0) + custom
  checks (6/0), and gitleaks (same tracked-files-only invocation as above).
  `trivy` again not run in this sandbox — relies on CI.

- **`getplumber/plumber` v0.4.48 → v0.4.51** in `.github/workflows/security.yml`
  and `scripts/internal/install-plumber.sh`, bumped by hand rather than by
  Cléa: the `security.yml` anchor is `action-sha`-pinned
  (`uses: getplumber/plumber@<sha> # vX.Y.Z`), and `clea bump` refuses to
  rewrite only the trailing comment there since it cannot also move the SHA —
  doing so would claim a version the pinned commit does not carry. Both sites
  were not yet probed by Cléa (issue #91), so this bump carries its own
  evidence in place of a probe: the release notes for v0.4.49 → v0.4.51 show
  no breaking change (GitLab-platform-mode features and an additive
  report-schema field only); the pinned SHA was checksum-verified against
  `getplumber/plumber`'s own `checksums.txt` via `install-plumber.sh`; and a
  real `plumber analyze` run against this tree on v0.4.51 was diffed against
  the same run on v0.4.48 — identical 24-control set, identical
  `dataCollectionDegraded: true` (this sandbox's GitHub session is
  repository-scoped, so `branchProtectionResult` and the action-CVE lookups
  can't resolve — the same limitation the v0.4.48 baseline hits, not a
  regression), and every real policy control (`actionPinningResult`,
  `excessivePermissionsResult`, `permissionsResult`, `dangerousTriggersResult`,
  `checkoutCredentialsResult`, …) passing on both. `task lint` (including
  `check-version-drift.sh`'s pin-agreement check), `task test-scripts`,
  `task validate` (both roots), `task test`, checkov (32/0) + custom checks,
  and a default-rules gitleaks dir scan all green. `task security`'s `trivy`
  step could not run in this sandbox (no network) — relies on CI.

- **`yamllint` 1.35.1 → 1.38.0** in `.github/workflows/ci.yml`, probed green
  by Cléa (issue #91). `task lint`, `task test-scripts`, `task validate`
  (both roots), `task test`, checkov (32/0) + custom checks, and a default-rules
  gitleaks dir scan all green on the bump. `task security`'s `trivy` step
  could not run in this sandbox (no network) — relies on CI. Left out of this
  batch, all `❌ probe failed` or `not probed` in the same report: `flux2`
  2.9.3 → 2.9.5 (three anchors), `plumber` v0.4.48 → v0.4.50 (two anchors —
  `clea bump` now refuses the `security.yml` one outright: an `action-sha`
  anchor whose SHA it cannot also move, so rewriting only the comment would
  claim a version the pinned commit does not carry), and `kubernetes/kubernetes`
  v1.36.3 → v1.37.0 (still refused by `cluster/versions-guard.tf`, tracked in
  draft PR #149).

- **`gitleaks/gitleaks` 8.22.1 → 8.30.1**, probed by Cléa. `install-gitleaks.sh`
  (the binary CI and `task security` actually run) and
  `.pre-commit-config.yaml`'s `gitleaks-system` hook rev now agree — the probe
  branch had only bumped the former, which `check-version-drift.sh` caught.
  `task lint` (includes the drift check) and the `gitleaks-system` hook itself
  both green on the bumped pin.

- **CI no longer runs feint, `task validate`/`test`, Talos config validation
  and the IaC security scan on a docs-only PR.** A new `changes` job diffs the
  PR against its base and classifies it by exclusion (anything outside
  `docs/`, `README*`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE`, `*.md` is
  "code"); the six heavy jobs gate on `needs.changes.outputs.code == 'true'`.
  Gates the job, never the trigger: a `paths-ignore` on the workflow itself
  would stop those jobs from running at all, and a required check that never
  reports stays pending forever — the PR could never merge. A job that runs
  and is skipped by its own `if:` still reports "skipped", which satisfies a
  required check exactly like success. `commits`, `leaks` and `lint` (the job
  that actually validates docs) stay unconditional; `security.yml`'s
  `secret-scan` and `pipeline-audit` are untouched — both are already cheap
  and repo-wide, not infra-specific.

- **`helm/helm` 4.2.3 → 4.2.4**, probed green by Cléa ([#104](https://github.com/dis-bzh/OpenAether-infra/issues/104)) on both anchors (`ci.yml`, `setup.sh`). Left out this cycle: `getplumber/plumber` (still not probed — its job keeps failing before it can push a verdict branch), `kubernetes/kubernetes` v1.37.0 and `fluxcd/flux2` v2.9.4 (both `❌ probe failed` — the former on `cluster/versions-guard.tf`, the latter on `task render-check` drift against the upstream Flux manifest), `stephrobert/feint` v0.12.0 (`❌ probe failed`, same doc-drift gate as before — a fix is already up in PR #137, unmerged as of this cycle). `task lint`, `task render-check`, `task test-scripts`, `task validate` (`cluster` and `talos-image`), `task test`, checkov and gitleaks all green on the bumped tree (`trivy` unreachable from this sandbox).

- **Six dependencies Cléa's first report ([#91](https://github.com/dis-bzh/OpenAether-infra/issues/91)) found behind upstream and probed green, bumped for real**:
  `go-task/task` 3.52.0 → 3.53.1, `cloudnative-pg/cloudnative-pg` 1.23.6 →
  1.30.0, `opentofu/opentofu` 1.12.5 → 1.12.6 (four anchors in `ci.yml` plus
  `setup.sh`), `cilium` 1.20.0 → 1.20.1 (chart re-rendered,
  `task render-check` green against the new manifest) and `commitizen` 4.9.1 →
  4.18.0. `helm/helm` and `fluxcd/flux2` stay put: the report's own verdict for
  both is "not probed" (they ride the weekly lane, `daily = false`), so there is
  nothing yet to act on. `stephrobert/feint` stays at 0.10.0: its probe failed
  outright — the installer at the current pin reported no version, so the
  upgrade lane had nothing to upgrade over — a defect in the installer, not
  something this bump could paper over.
  `task lint`, `task render-check`, `task test-scripts`, `task validate`
  (`cluster` and `talos-image`), `task test` and `task security` (checkov and
  gitleaks; `trivy` was not reachable from this sandbox) all green on the
  bumped tree.
  - **`kubernetes/kubernetes` v1.36.3 → v1.37.0, also reported probed green,
    is deliberately left out.** `task test` — not part of Cléa's own gate list
    — fails immediately on the bumped tree:
    `cluster/versions-guard.tf`'s Talos↔Kubernetes support matrix caps Talos
    1.13 at Kubernetes 1.36, and none of the three checks Cléa's daily lane
    does run (`task lint`, `task render-check`, `task test-scripts`) exercise
    that guard. The pairing is unproven, not confirmed broken — Cléa's weekly
    local-cluster lane is what would actually boot it, and the report says
    that lane "has not reported yet". `clea.toml`'s `[lane].repo` now also runs
    `task test`, so a probe branch hitting this guard is reported for what it
    is instead of green.

- **`talosctl` is pinned and checksum-verified** by
  `scripts/internal/install-talosctl.sh`, instead of piping `talos.dev/install`
  into a shell — the last tool in `setup.sh` that was neither, in a repository
  that checksums helm, task, tflint and feint. The version is not a new anchor:
  it is the cluster's own `talos_version` via `talos-version.sh`, so a
  workstation cannot end up with a CLI two patches from the fleet it talks to,
  and `siderolabs/talos` leaves `clea.toml`'s `[[unpinned]]` for a weekly probe
  row. It runs unconditionally rather than behind `check_cmd`, which probes with
  `talosctl version` — that prints the SERVER's tag too, so a stale client
  against a current cluster would satisfy the pin. Surfaced on a machine whose
  egress policy refuses `www.talos.dev`, where the old installer took the whole
  bootstrap down with it at step 2 under `set -e`.

- **`stephrobert/feint` 0.10.0 → 0.12.0, and `getplumber/plumber` v0.4.39 →
  v0.4.48** — checked by hand at the maintainer's request, not from a Cléa
  "probed green" verdict: feint's own probe had failed only on doc drift (the
  installer/upgrade checks all passed), fixed here alongside the bump; plumber
  isn't `clea bump`-safe at all — its anchor is a SHA-pinned `uses:` line where
  the tool only rewrites the trailing `# vX.Y.Z` comment, which would leave the
  old commit pinned under a new-looking version. Bumped past what Cléa's stale
  report knew about (0.11.0) once a direct check of `stephrobert/feint`'s tags
  showed 0.12.0 already released; plumber's new commit SHA was read straight
  from its `v0.4.48` tag and verified against the tag's own commit before
  writing it, never derived from the version string. Proof: `task lint`,
  `task render-check`, `task test-scripts`, `task validate` (`cluster` and
  `talos-image`), `task test`, checkov and gitleaks (`trivy` unreachable from
  this sandbox) all green, plus `task feint-test` — a full create / verify /
  empty-replan / destroy cycle against the real v0.12.0 binary, both Scaleway
  and Outscale. `plumber`'s own audit is unexercised outside GitHub Actions;
  this PR's CI run is what proves that pin.

  The plumber bump itself surfaced a real, if low-severity, finding: v0.4.48
  added a control ("Checkout must not persist credentials", `ISSUE-307`)
  that v0.4.39 never evaluated, and it was right — 11 `actions/checkout` steps
  across `ci.yml` and `security.yml` left `GITHUB_TOKEN` in `.git/config` for
  the rest of their job with no later step needing it (none of them push).
  `persist-credentials: false` added to all 11, the same fix `clea.yml`
  already carries on the two checkouts that DO push — this is every read-only
  job catching up to that pattern.

- **Renovate moves from a six-hour weekly window to a daily one**, and
  `dependencyDashboard` becomes explicit. It has proposed nothing since its
  config landed on 2026-07-30 — its nine pull requests were created three hours
  *before* that file existed — and one measurement rules the schedule out as the
  explanation: helm 4.2.4 was published 2026-08-13, `setup.sh:225` pins 4.2.3,
  that anchor is one Renovate could always see, and the window of 2026-08-17
  passed four days later with nothing. The weekly window existed to batch noise;
  Cléa's daily report does that now, so it cost a week of latency and bought
  nothing. The dashboard is the visible heartbeat: issues were disabled on this
  repository until 2026-08-21, so Renovate had nowhere to report a configuration
  problem or its own state, and three weeks of silence looked exactly like three
  weeks of nothing to do.

### Fixed

- **`docs/status.md`'s assertion count, hand-typed, had drifted from what
  `task test-scripts` actually ran three times running** (333, then 413, then
  468, each stale before the next edit —
  [#111](https://github.com/dis-bzh/OpenAether-infra/issues/111)). The page no
  longer states a number: it points at the one-line command that measures it
  instead, so a fourth drift is not possible — there is nothing left to drift.
- **`CONTRIBUTING.md` required what `check-commit-trailers.sh`'s own example,
  and the `change-process` skill, forbade** — naming the model in the
  `Assisted-by:` trailer, when the skill's "Never" section says the identifier
  must never appear in a pushed artifact
  ([#125](https://github.com/dis-bzh/OpenAether-infra/issues/125)).
  `CONTRIBUTING.md` now matches the skill (tool-only trailer, no model
  version) and the script's example agrees.
- **Two tracked scripts were reachable from nothing**: `scripts/ops/ensure-capo-fip.py`
  (whose own docstring calls it "the only CAPO child resource created outside
  both OpenTofu and CAPI … the only one a teardown leaves behind and billing")
  and `scripts/ops/bastion-harden-check.sh`, a check nothing ever asked for.
  New `check-script-reachability.sh`, wired into `task lint`, requires every
  tracked script to be named by a task, a workflow, another script, or a
  document — a plain basename `git grep`, same shape as the reproduction in
  [#116](https://github.com/dis-bzh/OpenAether-infra/issues/116). Both scripts
  are kept: `ensure-capo-fip.py` is now documented in `docs/capi-bootstrap.md`
  / `.fr.md` (the CAPO floating-IP pitfall it exists to close), and
  `bastion-harden-check.sh` in `docs/release-checklist.md`'s "worth the extra
  spend" list.

- **The `gitleaks` pre-commit hook could not run at all in some sandboxes**,
  blocking every local commit. `.pre-commit-config.yaml` used the upstream
  `gitleaks` hook (`language: golang`), which pre-commit compiles from source
  on first use; that build panics inside `wasilibs/go-re2`'s WASM regex
  engine (`invalid table access`, in `wazero`) on at least one environment —
  reproduced across a full `go`-build-cache wipe and two Go toolchains, while
  the exact same version as an official release binary runs clean against the
  same tree. New `scripts/internal/install-gitleaks.sh` (pinned,
  checksum-verified, same shape as `install-task.sh`) installs that binary;
  `.pre-commit-config.yaml` now uses upstream's own `gitleaks-system` hook id
  against it instead of building one, with the `pass_filenames: false`
  upstream's `gitleaks-system` entry omits (without it pre-commit appends
  every changed file as a positional arg, and gitleaks' `git` subcommand
  accepts at most one). `check-version-drift.sh` now compares the two pins.
  [#126](https://github.com/dis-bzh/OpenAether-infra/issues/126)

- **A `--set` typo in `render-bootstrap-manifests.sh` was silent end to end.**
  `helm template` exits 0 on an unknown key (it just lands under another name
  in `.Values`), `task render-check` only diffs the render against itself, and
  `check-cilium-parity.py` skipped a `--set` key it could not resolve instead
  of flagging it — so a one-character typo (`hostNamespaceOnl` for
  `hostNamespaceOnly`) reached the cluster with nothing anywhere saying so.
  New `check-cilium-effective-config.py`, wired into `task render-check`,
  reads the EFFECTIVE settings the committed `cilium-config` ConfigMap
  carries rather than the flags that produced them; `check-cilium-parity.py`
  now fails when the production block does not set a `CHECKED` key at all,
  instead of silently treating that as "nothing to enforce".
  [#112](https://github.com/dis-bzh/OpenAether-infra/issues/112)

- **`outscale.py`'s purge never looked at leftover snapshots**, so a
  duplicate snapshot from a failed image build sat in the account while
  "account is clean" was true of everything the script asked and false of
  the account. It now lists them (`ReadSnapshots`) and refuses to claim clean
  while any are present — reported, never auto-deleted: same policy
  `scaleway.py` already documents for Talos build artifacts, and
  `fleet-down.sh`'s own "left standing on purpose" list. Images are
  deliberately still not enumerated — `ReadImages`' documented default scope
  can include Outscale's own public OMI catalogue, and scoping that safely
  needs verification against a live account, tracked separately as
  [#107](https://github.com/dis-bzh/OpenAether-infra/issues/107). Two paths
  used to say "clean" wrongly: an account with nothing else at all
  (`TOTAL == 0`), and — found while fixing the first — the successful
  `--apply` path itself, which said "resource(s) deleted, the account is
  clean" even with a snapshot still sitting there; a REFUSED `ReadSnapshots`
  call after a successful purge fell through the same way and is now
  reported as unconfirmed rather than silently clean.
  Refs [#71](https://github.com/dis-bzh/OpenAether-infra/issues/71) — the
  issue's own bar is real cloud; this closes the mocked-rung defect only.
- **`ovh.py`'s purge could not tell a refused endpoint from an empty account.**
  `scaleway.py` and `outscale.py` both count a refused call and refuse to
  claim "clean" on zero findings and zero reachable endpoints; `ovh.py` had no
  such counter, so a partial refusal — one endpoint answering 403 while the
  others still worked — crashed the run instead of being counted and
  continuing. It now shares the same `UNREACHABLE` counter and exit code.
  [#63](https://github.com/dis-bzh/OpenAether-infra/issues/63)
- **`converge-versions.sh` had no downgrade guard of its own.** It survived a
  Talos/Kubernetes downgrade attempt only by accident, on two layers it does
  not own (the talos provider's forced PKI replacement, and
  `secrets_prevent_destroy` turning that into a hard refusal — a variable that
  is explicitly false in `tofu test`). It now refuses a pin that is
  semver-lower than what the fleet runs, naming both, before calling either
  `infra-apply` or `cluster-roll`. [#90](https://github.com/dis-bzh/OpenAether-infra/issues/90)

- **`task local-down` refused to run on a clone that had only this repository.**
  `test-talos-local.sh` resolves `APPS_DIR` and exits 1 when it cannot find
  `OpenAether-apps/apps/flux/local` — before it reads `--destroy`, which never
  uses that directory. So the one command that cleans up after a failed deploy
  needed a second repository cloned, and refused exactly when containers,
  volumes and state were already on disk. Measured 2026-08-26 on the Docker
  lane; `--destroy` is now exempt from the check.

- **`task security` could not be completed on a machine set up by
  `scripts/setup.sh`.** `install_checkov` tried pipx, then `python3 -m pip`,
  then apt — and Ubuntu 24.04 ships python3 with neither pip nor pipx, so the
  only branch left wanted sudo. A venv needs neither and carries its own pip;
  it now sits between them, and `install_yamllint` finally gets the
  "`pip3` is not always a binary" lesson its neighbour documented and never
  received.

- **`command -v sudo` asks whether sudo EXISTS, not whether it can be USED**,
  and eight places asked it. On a workstation where `/usr/local/bin` is not
  writable and sudo wants a password, that answers yes, the installer then dies
  on a prompt nobody can answer, and `set -e` ends the bootstrap. The rule is
  now one function in `scripts/lib/common.sh` — `oa_sudo_usable`, `oa_bin_dir`,
  `oa_sudo_for` — used by `setup.sh` and by the four pinned installers instead
  of the same six lines repeated: passwordless sudo, or a terminal to be asked
  on, or neither, and a directory that does not exist yet is judged by its
  parent.

- **`install_tofu` preferred snap and brew, and neither can install a NAMED
  version.** `snap install --classic opentofu` serves whatever the channel
  holds, so on any machine with snap the pin was decorative — which is how this
  repository's own workstation ran 1.12.6 against a pinned 1.12.5. A pin an
  installer cannot honour is a pin that guarantees drift, and
  `check-version-drift.sh` now compares this one. Only the standalone installer
  remains: it takes `--opentofu-version`, and `--install-path` /
  `--symlink-path` let it install without root.

- **`infrastructure/opentofu-local/variables.tf` pinned a different Talos and
  Kubernetes than the cloud root** — `v1.13.3` / `v1.35.3` against `v1.13.9` /
  `v1.36.3`, drifted before either was anchored. The credential-free lane the
  README calls the best first step was exercising a pair that is not the one
  that ships. Now pinned equal. Measured on the shipped default topology
  (3 control planes + 3 workers, Docker): all six nodes Ready, Cilium on 6/6,
  `task local-verify` 6/6 — versions read from the cluster itself, not the tool
  that deployed it (`kubectl get nodes` → `v1.36.3` on all six; `talosctl
  version` against the control plane's own API → server tag `v1.13.9`).
  Closes [#87](https://github.com/dis-bzh/OpenAether-infra/issues/87). The
  cloud root's own pin — `v1.13.9`, one patch past what this repository's
  real-cloud evidence table covers — is untouched and unrelated.

- **`scripts/setup.sh` asked whether a tool was present, never which version it
  was** — so it installed the pin on a fresh machine and refused every upgrade
  afterwards, in silence, on every machine that had run it once. Found by the
  Cléa probe on a real bump: a cold install reached helm 4.2.4 while upgrading
  over 4.2.3 left 4.2.3. `check_cmd` now takes the pin and compares, bounded on
  both sides, for the three tools this file pins; the others have no version to
  compare against and pinning them is a separate decision.
  `scripts/dev/test-setup-checks.sh` guards it offline, so it does not need
  Docker to stay fixed.

- **The OpenTofu install asked the GitHub API which version was newest** —
  unauthenticated, 60 requests an hour from a shared IP, and it is the FIRST
  step, so a 403 there took the whole bootstrap down with `set -e` and nothing
  at all got installed. Exit 2 on a bare `ubuntu:24.04`, measured 2026-08-23.
  OpenTofu was the last tool here neither pinned nor verified; it now carries
  the same pin as `ci.yml`, passed to the installer explicitly, and
  `check-version-drift.sh` compares the two.

- **Nine of twenty-one version anchors were inert, and nothing said so.** The
  `# renovate:` comment was there and Renovate had never been told to read the
  file or the key, so the pin looked watched and was not: `go-task/task`,
  `terraform-linters/tflint`, `cloudnative-pg/cloudnative-pg`,
  `stephrobert/feint`, and `commitizen`, `gitleaks` and `helm` inside
  `ci.yml`. The two anchors in `Taskfile.yml` marked no version at all — the
  value moved into `talos-version.sh` and the anchors stayed behind. The six
  custom managers are now three, matched on the **shape** of a value rather than
  on the names of the keys that hold it, and written in the current
  `managerFilePatterns` spelling rather than the deprecated `fileMatch`.
  `task lint` now runs `clea coverage`, which fails on the next one.

- **`infrastructure/opentofu-local/variables.tf` carried no anchor at all**, so
  the credential-free lane drifted to Talos `v1.13.3` / Kubernetes `v1.35.3`
  against `v1.13.9` / `v1.36.3` in the cloud root. Anchored, so a proposal now
  reaches it; the pins themselves are not moved here. Measured 2026-08-24 on the
  Docker lane: the newer pair (`v1.13.9` / `v1.36.4`) boots, 6/6 on
  `task local-verify`. Unifying the two roots and a real-cloud upgrade are
  [#87](https://github.com/dis-bzh/OpenAether-infra/issues/87).

---

### Security

- **`admin_ip` refuses to open the cluster to the internet.** The variable had
  no `validation`, so `["0.0.0.0/0"]` was accepted in silence — and it feeds
  bastion sshd *and* the 6443 LB ACL on all four providers at once. Behind that
  ACL sits a `system:masters` kubeconfig Kubernetes cannot revoke. Three rules
  now reject an empty list, an entry without a prefix (including the `YOUR_IP/32`
  of a copied example) and any `/0` — read from the prefix, so `198.51.100.7/0`
  is caught too. Nine cases in
  `cluster/tests/admin-ip-validation.tftest.hcl`; each rule was deleted in turn
  and the suite watched to go red before it was kept.
- **Admin access is documented as unrevocable where it is unrevocable.**
  [`docs/admin-access.md`](docs/admin-access.md) now says what a leaked
  kubeconfig costs, instead of leaving the reader to find out.


## [0.1.0] — 2026-08-20

> **This tag does not point at the commit first cut as 0.1.0.** That one,
> `421c1ee`, carried a real admin IP that had been serving as a test fixture in
> `check-gitleaks-rules.sh` since 2026-08-13 — found by reading the published tag
> as a stranger, which is what §9 of the release checklist is for. History was
> rewritten and the tag re-cut, twice: once on the purged history, once more to
> take in this record of it. No release was ever published under the first tag
> and nothing depended on it. GitHub still serves the old blob by direct SHA and
> the diff of the pull request that introduced it; only GitHub Support can remove
> those, and anyone who cloned before the rewrite keeps it.

**One Talos cluster, on one supported cloud, with one fixed foundation: Cilium.**
Infrastructure only — nothing above that layer. Start at
[`docs/first-cluster.md`](docs/first-cluster.md).

### Added

- **Every task is `<noun>-<verb>`**: `cluster-up`, `infra-plan`, `infra-apply`,
  `tunnels-up`, `cluster-verify`, `cluster-upgrade`, `cluster-idempotency`,
  `cluster-roll`, `infra-down`, `cluster-down`. Upgrades:
  [`docs/upgrade.md`](docs/upgrade.md). Day-1 access:
  [`docs/admin-access.md`](docs/admin-access.md).
- **An approval you cannot lose by accident.** `APPROVE=auto|ask` names *who*
  answers the question, never whether one is asked: every apply plans to a file
  and applies that file, and `tofu apply <saved plan>` does not prompt.
  `-auto-approve` is gone from the cloud path, CI included. Destroy always takes
  two commands and no flag collapses them.
- **State and artifacts encrypted client-side in S3**, with an optional replica
  on a second cloud. S3 credentials are namespaced by the cloud that *holds the
  bucket*, not by the cluster. Proven across providers: an encrypted tfstate at
  Outscale while the cluster ran on Scaleway.

### Validated

Measured on real accounts: Scaleway and OVH on 2026-08-19, Outscale on
2026-08-20. Versions were read back from the kubelets and from each node's own
Talos API, never from the tool that performed the upgrade.

- **Scaleway, from an empty account**: deploy in 8 min 50 for 72 resources,
  `cluster-verify` 11/11, idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos
  v1.13.7 → v1.13.8 confirmed by Talos itself on 6/6 nodes (`stage=running`,
  fallback dropped).
- **OVH**: the same five pillars — deploy, verify, idempotency, and both
  upgrades — the same versions, 11/11, idempotency 3/3.
- **Outscale**: the same five pillars again, measured the same way — deploy (51
  resources, then 17), `cluster-verify` 11/11, idempotency 3/3, the same two
  upgrades on 6/6 nodes. It had to go onto a **fresh Net**: see the known limits.
- **Idempotency is a property of the command.** Run `task cluster-up` once or a
  hundred times and you land in the state you asked for; the evidence is the
  command's own plan, which prints `No changes.` on a cluster that already
  matches. `task cluster-idempotency` adds the two assertions OpenTofu cannot
  make — the *same* nodes (name and `creationTimestamp`), and a kubeconfig that
  still reaches the apiserver — because an empty plan alone would not catch a
  node replaced underneath it.
- **A second Scaleway cycle on 2026-08-20**: `cluster-up`, `cluster-up`,
  `cluster-upgrade`, `cluster-up`, all four green, both re-runs applying nothing
  on all three roots. **Idempotency after an upgrade had never been checked**; it
  holds because `cluster-upgrade` writes the new pin back into the tfvars. Talos
  v1.13.8 → v1.13.9 on 6/6 nodes, and `cluster-verify` compared the running
  *schematic*, not just the version tag.
- **An upgrade is not seamless.** Longest apiserver outage 5 s on Scaleway (16
  failed probes out of 575), 7 s on OVH (9-10 out of ~540) and 8 s on Outscale.
  All three are *worse* than the best figures this project ever recorded (3 s,
  1 s and 1 s), and why has not been established. Plan for a gap.
  A later Scaleway run measured **2 s**, with the roll taking the etcd leader
  last and handing leadership over first. **That does not establish the fix**:
  that run moved Talos alone, while the 5 s run also moved Kubernetes, which
  restarts an apiserver per control plane by itself. Two workloads, two numbers
  that do not compare — quote the 5/7/8 figures.
- **358 offline assertions across 11 harnesses**, every one mutation-tested
  (`task test-scripts`). The emulated lane runs feint 0.10.0 against Scaleway provider
  2.81.0 — the same version the clusters run.

### Fixed

- **The shared schematic shipped `siderolabs/qemu-guest-agent`, and that one
  extension cost every upgrade.** It never starts on OVH or Outscale, whose
  images carry no `hw_qemu_guest_agent` device: the boot sequence never
  completed, Stage never became Running, the META Upgrade key was never dropped,
  and the next reboot reverted the upgrade the tool had just reported as
  successful. Root cause, not a workaround.
- **A failed purge no longer exits 0 saying "purge complete".** The teardown for
  this release found six Outscale resources, was refused on all six, and the
  script still reported success — the refusals were printed but never counted, so
  the exit code every caller reads said the account was clean. All three
  `purge-orphans` scripts now count failed deletions and end on one of three
  verdicts, the third being *N of M failed, NOT clean*.

### Removed

- **The staging CI lane.** 479 lines that never deployed anything: the workflow's
  one recorded run died for want of secrets that were never set, and part of it
  verified a platform this release disables (35 Flux Kustomizations). A weekly
  red that measures nothing teaches you to ignore red. 0.1.0 ships **no CI lane
  that deploys** — the credentialed rung is run by hand, by someone watching. The
  code is on the `archive/staging-lane` branch.

### Changed

- **`talos-image`'s "staging" bucket is now the "import" bucket.** This repository
  already spends that word on environments (`environment = "dev"`), and reading
  it as one here is what it cost. The variable is `import_bucket`, the bucket is
  `…-talos-import`, and the default is no longer a literal name with the project
  and the provider baked into it — it is empty, and refused where it is named.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **No Flux and no applications.** `deploy_flux` defaults to `false`. Flux is
  disabled, not amputated — the Talos module already reads an empty manifest as
  "no Flux", so turning it on moves no resource address — and it returns as a
  user choice in a later release. Everything it reconciles lives in
  `OpenAether-apps`.
- **No CAPI and no multi-cluster.** A management cluster is an optional overlay
  on top of this, never the entry point.
- **Outscale needs a fresh Net, and leaves one behind.** A load balancer that
  never left `provisioning` was diagnosed by Outscale as an internal timeout in
  their LBU service — support request 399530, now closed, with the instruction
  not to create another load balancer in that Net. One Net created before the
  fix still refuses deletion on a dependency no read returns; only the provider
  can clear it, and a second request is open for that.
- **No state lock on Outscale.** Its object store accepts a conditional write
  (`If-None-Match`) that Scaleway's and OVH's refuse, so `use_lockfile` is
  enabled on those two and deliberately not there — a lock that announces itself
  and holds nothing is worse than none. Two concurrent runs against an Outscale
  cluster's state are not stopped by anything.
- **Scaleway, OVH and Outscale are the clouds that were measured.** Proxmox has
  never been applied on real hardware; the local Docker rung proves
  `modules/talos` without credentials and nothing about a cloud. Anything else is
  code, not a claim.
- **Two release-checklist lines were not met, and are not ticked.** The OVH
  teardown was run once where the checklist asks for twice — an Octavia load
  balancer orphaned by one teardown was once silently reused by the next deploy,
  and only a second teardown proves the check that now covers it. And the
  Outscale purge is not clean: the pre-fix Net above is still there and no
  deletion is accepted for it.
- **One image bucket is orphaned by this release's own rename.** The old
  `…-talos-staging` still holds every QCOW2 it was given, on every cloud built
  from. `purge-orphans` lists it; emptying it is by hand.
- **`ovh.py` cannot tell a refused question from an empty account.** Its two
  siblings count refused calls and exit 2 when they found nothing but asked
  nothing; it has no such counter. A total auth failure crashes it rather than
  reporting clean, so this is a gap and not the same defect — but a partial
  refusal would shrink its findings in silence.
