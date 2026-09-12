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

### Fixed

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
  always exited 0 regardless. `cluster-up` now runs `cluster-verify`
  (ROLE/PROVIDER forwarded) right after `converge-versions.sh` and before the
  closing echo — go-task 3.52.0 propagates a failing step's exit code up
  through the parent task, so a red verify halts `cluster-up` there instead
  of past it. The banner no longer disclaims itself. New `test-unattended.sh`
  section statically confirms the call graph reaches `cluster-verify` and
  that the edge is neither `ignore_error: true` nor trailed by `|| true`
  (checked negative: both defects made it fail, VERIFIED offline), wired
  into `task test-scripts`. Real-cloud rung — the failure actually seen red
  on a cluster that does not match its config — is still open: feint only
  emulates the provisioning API, no kubelet/apiserver/Cilium/CoreDNS ever
  exists under it.

- **The Scaleway security group's documented perimeter and its enforced one
  had drifted apart** (#79). `security.tf`'s own comment said "Talos API —
  From Bastion ONLY" and admitted `:50000` from the bastion's **public** IP —
  a rule that never fires, since the bastion reaches nodes over its private
  NIC. What actually admitted that traffic (and everything else) was a
  `port = 0`/`protocol = "ANY"` rule matching `172.16.0.0/12` — Scaleway's
  whole IPAM range, not this cluster's own subnet — plus a redundant
  `10.0.0.0/8` rule nothing in this module ever gets an address in. Fixed by
  pinning the private network's own `/22` (`network.tf`, matching OVH's and
  Outscale's existing self-declared-CIDR pattern instead of trusting IPAM
  auto-assignment), scoping the mesh rule to that `/22`, dropping the dead
  bastion-public-IP rule and the `10.0.0.0/8` rule, and dropping `port = 0`
  from every remaining `protocol = "ANY"` rule (meaningless there, and
  already the pattern `bastion.tf`'s own `outbound_rule` used). New
  `tofu test` run asserts no SCW `inbound_rule` carries `port == 0`. Rung:
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
  - **A 14th required check (CodeQL) runs on every PR with no workflow file
    and no mention anywhere in the tree** (#122) — `security.yml`'s "13
    required checks" was a comment nothing verified. New
    `scripts/dev/check-required-checks.sh` diffs GitHub's declared rulesets
    against what actually reported on a commit, and refuses ("not
    verifiable") rather than passing when the rulesets response is empty —
    proven offline against two canned fixtures (a 13-context ruleset, a
    14-entry check-runs capture with a CodeQL-shaped extra), run via
    `task test-scripts`. **Not wired into any workflow yet**: against this
    repository's current classic branch protection the rulesets endpoint
    legitimately returns `[]`, so a live step would fail-closed on every
    future PR until an admin adds a ruleset on `main` — that step is a
    follow-up gated on it.

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

- **`fluxcd/flux-schema` 0.12.1 → 0.13.0** in `.github/workflows/ci.yml` and
  `scripts/setup.sh`, probed green by Cléa (issue #91). `task lint` (including
  a real re-install of the `schema@0.13.0` plugin and a re-run of
  `check-flux-schema.sh` against it, not just the cached 0.12.1 already on
  this sandbox), `task render-check`, `task test-scripts`, `task validate`
  (both roots), `task test` (61/61), checkov (32/0) + custom checks, and a
  default-rules gitleaks dir scan all green on the bump. Left out of this
  batch, all `❌ probe failed` or `not probed` in the same report: `flux2`
  (3 anchors, probe container missing `xz`, see #174), `helm` 4.2.4 → 4.3.0
  (not probed), `plumber` v0.4.51 → v0.4.60 (2 anchors — the `security.yml`
  one is `action-sha`-pinned and `clea bump` correctly refuses it, same as
  the v0.4.51 bump above), `talos`/`kubernetes` (blocked on the Kubernetes
  support-matrix range for Talos 1.14, tracked in draft PR #149), and `feint`
  0.12.0 → 0.13.0 (probe fails on stale doc version references).
  `task security`'s `trivy` step could not run in this sandbox (no
  network) — relies on CI.

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
