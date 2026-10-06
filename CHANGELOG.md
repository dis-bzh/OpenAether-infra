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

---

## [0.2.0] — TBD

**A Talos cluster that is upgraded to Talos 1.14 and Kubernetes 1.37, grown and shrunk while it runs, and rebuilt once on
a second cloud from its replica (OVH to Scaleway, one control plane and one worker), with Cilium still the only
platform above Talos.** The climb, node growth and node removal ran by hand on real accounts between 2026-10-02 and
2026-10-04, on Scaleway (two climbs), OVH and Outscale (one each); on 2026-10-05 the failover, the image lane, the
nodes' resolver and the Talos provider 0.12.0 pin ran at one control plane and one worker. The climbs ran under provider
0.11, which 0.2.0 no longer ships: no 1.13 to 1.14 climb has run under 0.12.0. Nothing is unattended. A bullet's rung is
its evidence: what does not say real cloud is mocked, emulated or local Docker. Read Known limits and Upgrade notes
before pulling this onto a cluster that matters.

### Added

- **`cluster-verify` asks where the control planes sit, and whether the workers' data volumes exist (#38, #62).** Each
  provider module outputs `control_plane_zones` (a required contract row), read from each server resource in the state.
  Three control planes in one failure domain end red and the red line names the knob; a 2+1 split (Scaleway over two
  zones) warns, since losing the zone that holds two loses etcd quorum; a missing output is UNCHECKED, fatal, never a
  pass. Each worker's own Talos API is asked, through the first control plane's tunnel, for every `worker_storage` volume
  (`ready`, `luks2`); that needs `task tunnels-up`, and without a tunnel the volume and schematic checks warn instead of
  passing. Rung: mocked; real cloud 2026-10-03: the verdict read on Outscale (red in one subregion, green across three)
  and OVH (green across three zones), matching the provider's own listing; 13/13 on all three clouds with encrypted
  worker disks, the read-back named only for Scaleway, green and red (red: a volume the workers lack). Mocked only: OVH's
  one-zone red (read from the config; whether OVH reads its zone back or echoes the config is unknown) and Scaleway's
  2+1 warning (not deployed when the check landed).
- **`task cluster-up` grows a live cluster (#59).** The apply that created a node also waited on its Talos port, reachable
  only through a tunnel that cannot exist before the node. `scripts/bootstrap/grow-nodes.sh` now runs first: it creates
  the machines, opens the tunnels and configures only the nodes the state has no configuration for; a no-op on a fresh
  cluster. Rung: mocked; real cloud by hand, 2026-10-03 (Validated, Growth).
- **`task cluster-up` lands the versions its tfvars declare.** A bumped `talos_version` used to reach the machine config
  and roll no node, with an empty plan and `cluster-verify` green (11 passed, 0 failed, Scaleway 2026-08-21). The
  verifier now compares running versions with the pin (12 passed, 1 failed on that state; a fleet split between two
  versions reads MIXED, a roll stopped part way); `cluster-up` prints the roll (`converge-versions.sh --check`) before
  its approval question and rolls the fleet after the bootstrap; `cluster-upgrade` climbs one minor at a time from
  `version-support.json`, which now knows Talos 1.14 (Kubernetes 1.32 to 1.37). Rung: real cloud once, Scaleway
  2026-08-21: a seven-step climb from Talos 1.12.7 / Kubernetes 1.30.0 to 1.13.9 / 1.36.3, longest outage 5 s, and a
  `cluster-up` on a matching fleet that rolled nothing. Also real cloud, Scaleway and Outscale, 2026-10-05: `cluster-up`
  read a worker left on v1.14.1 under a v1.14.2 pin (`cluster-verify` red, `MIXED`) and rolled it to v1.14.2
  (Validated). Mocked only: a `cluster-up` that carries a minor climb; the measured climbs used `cluster-upgrade`.
- **`task cluster-up` adopts a bootstrap the state forgot (#67, #40).** An apply interrupted after the node accepted the
  Bootstrap call left no bootstrap in the state, and phase 2 sent it again to a live etcd, which refuses it.
  `adopt-bootstrap.sh` asks every control plane for `etcd members` and imports the bootstrap only if one answers with a
  member row; a fresh cluster pays up to 15 s per control plane. The import lands before phase 2's approval question and
  declining does not undo it (the script prints the `tofu state rm` that does). Rung: mocked; real cloud, Scaleway only:
  2026-10-02, a state lost to PR #223's defect (three etcd members found, bootstrap imported, `cluster-verify` 12/12,
  `cluster-idempotency` passed), and 2026-10-03, a `SIGKILL` right after the Bootstrap call. Not on OVH or Outscale.
- **`task cluster-upgrade` also measures a Service (#41).** A 2-replica workload behind a Service (with a PDB when two
  nodes can take it) is polled through the apiserver proxy for the whole roll; failed samples and longest outage are
  reported beside the apiserver's, and samples taken while the apiserver is down count apart as BLIND. Reported, not
  gated. Rung: mocked; real cloud 2026-10-03 on Scaleway, OVH (the `upgrade-k8s` step and the Flux/CNPG roll,
  `docs/upgrade.md`) and Outscale.
- **`task cluster-shrink-plan` then `task cluster-shrink` remove nodes from a live cluster (#249).** Two commands, like
  destroy: `PLAN=` is required and `APPROVE=auto` does not collapse them; the scope comes from the saved plan and is
  derived again at apply. A worker run may take several nodes, highest index first; a control-plane run takes exactly
  one, never in the same run as a worker; the cluster keeps at least one of each, and below three control planes it needs
  `-- --allow-below-ha` on both commands. Per node: Longhorn eviction, drain, `talosctl shutdown`, delete the Node, a
  targeted destroy of exactly that node's resources; a control plane also takes an etcd snapshot, hands leadership off
  and runs `etcd leave`; the run ends with `_backup-state` and `cluster-verify`. Refusals, mechanism and figures:
  `docs/upgrade.md`, Removing nodes. The closing step applies every pending machine-config update, so make a config edit
  separately. A lowered count through `cluster-up` is now refused (Fixed). Rung: mocked, the only rung of every refusal
  but Longhorn's two-replica one (a real cluster refused that too); real cloud 2026-10-04 (Validated).
- **`task restore-state` rebuilds a cluster on another provider from the replica the first one left (#57).** When
  provider A is gone its tfstate survives as the `-backup` replica on B's store, the only carrier of the Talos PKI and
  the etcd secretbox key. `task restore-state PROVIDER=<b> ROLE=failover FROM=<A's env name>` (the file under `envs/`
  without `.tfvars`, e.g. `management-<a>`) copies the replica to B's state key and untracks everything but the three state-only Talos resources, so `task cluster-up` builds a cluster that
  A's saved kubeconfig and talosconfig still open. It is a rebuild, not a restore: etcd contents and application data
  are not in the replica. It refuses a target that holds resources or whose state cannot be read, a replica that is its
  own target, a plaintext replica, a state with no PKI and a `talos_version` below the one the PKI was made for; from
  the upload on, any failure removes the copy again (a `kill -9` leaves it, and the next run refuses, naming the
  object). The replica is only ever read. A's env file is gitignored and in no store, so after losing the workstation it
  is rebuilt by hand (runbook: `infrastructure/opentofu/cluster/README.md`, "Cross-provider failover"). Rung: mocked;
  real cloud once, OVH to Scaleway, 2026-10-05 (Validated). Not run: any other provider pair, three control planes,
  Talos discovery with a live A.
- **`node_nameservers`: DNS-over-TLS or -HTTPS for the nodes' own resolver (#173).** Opt-in. A list of `{address,
  protocol, tls_server_name}` is rendered as one Talos `ResolverConfig` appended to every node, plus a `TimeSyncConfig`
  `bootTimeout` (`node_dns_boot_timeout`, default `90s`) when a server is encrypted; unset, every node's config is
  byte-identical. A list that mixes encrypted and plain entries is refused (a plain entry beside an encrypted one fell
  back to plaintext on a local QEMU node, not on a cloud), and a change replaces the apply resources, all in one apply.
  **A list no node can reach is found only at the next reboot, and that node then has no Talos API**: replacing it is
  the recovery, `nc -zvw5 <ip> 853` from a pod is the check beforehand, and `cluster-verify` does not read the resolver.
  Rung: mocked; real cloud once, DoT on OVH, 2026-10-05, 1 control plane + 1 worker (Validated). DoH and plain Do53:
  rendered and `talosctl validate`d only, no node run. Not recorded: Outscale, three control planes, a cold first boot
  with the list set, the apply on Scaleway (only its egress was read).
- **The Talos tunnels keep what their ssh said, and `ensure` and a short `open` quote it (#65).** Every tunnel's ssh
  output went to `/dev/null`, so a tunnel reported up with no listener left nothing to read. Each ssh now appends its
  `LogLevel=VERBOSE` output to `.talos-tunnel-<port>.log` beside the pidfile (gitignored: it names the bastion, so
  redact it before pasting it anywhere public); `open` and `open-direct` quote the log of each port that did not come
  up, and `ensure` quotes each tunnel that does not answer and says whether its ssh still runs. A log says how an ssh
  ended, not who asked it to; the cause of the earlier deaths is still unknown. Rung: mocked; seen once on a real
  Scaleway bastion with 2 tunnels (after a TERM, `ensure` quoted the client's closing lines and rebuilt 2/2). Not seen:
  a drop by the bastion, a KILL, `open-direct`.
- **A manual real-cloud deploy, verify and teardown workflow, dormant until its secrets exist (PR #257).**
  `.github/workflows/real-cloud-regression.yml` (`workflow_dispatch` only, one provider or all three, a "these are
  sandbox accounts" box, the teardown and an account-clean proof under `if: always()`). Its first step names whichever
  secret is missing, and none of them exists in the repository. Secrets reach a step only through `env:`, `kubectl` is the
  cluster's own pin and checksum-verified, and Outscale is judged on its VMs and public IPs because of #43. Rung: mocked
  (each shell step lifted out of the YAML and run with fake secrets); **never run against an account**.
- **`task state`, `task purge-orphans`, `task talosconfig-new`, `task local-rbac`.** `state PROVIDER=… [ADDR=…]` lists what
  a cluster's state holds and tells an absent state from an empty one, read-only; `purge-orphans PROVIDER=… [APPLY=1]`
  is the command the release checklist already named and the repository did not have. `talosconfig-new` issues a
  role-scoped talosconfig with a TTL (`os:reader`, 8 h by default) from the admin one, which the deploy hands out as
  `os:admin` valid a year; it refuses to report success if the node grants other roles. `local-rbac` asks the Docker
  cluster whether Talos enforces those roles. Rungs: `state` mocked (no real listing recorded); `purge-orphans` mocked
  and emulated, real read-only for Outscale's image listing only (Fixed, teardown); `talosconfig-new` Docker lane, then
  real cloud once, OVH 2026-10-03; `local-rbac` Docker only (2026-08-24, Talos v1.13.3).
- **`task cluster-up` refuses, before it spends, a never-applied `prod` cluster whose replica is on the primary's cloud
  (#57).** Only the verifier said so, after the apply; it is now also red on a prod replica in another region of the same
  cloud. A self-hosted S3 only has to be another endpoint; a cluster name that already has a state object is only warned
  (it may be live). Rung: mocked.
- **A changed `admin_ip` can be applied.** The documented remedy stopped at the tunnel check on a bootstrapped cluster,
  because the bastion no longer let this machine in, and the escape hatch lived in a Taskfile comment. The check is
  `scripts/internal/tunnel-guard.sh`; its failure names `OA_SKIP_TUNNEL_GUARD=1`, and `docs/admin-access.md` has the
  procedure. Rung: mocked; real cloud once, Scaleway 2026-10-04 (Validated).
- **`docs/capacity.md`: what a cluster needs, per provider (#72).** The sizing floor and its evidence, what each module
  creates, the totals and `preflight-quotas` flags of every shipped example; derived figures marked apart from measured.

### Changed

- **Talos v1.14.2 and Kubernetes v1.37.1 are the default pin (#181).** Both roots move together; 0.1.0's was v1.13.9 and
  v1.36.3. Rung: real cloud on all three clouds, 2026-10-03, under provider 0.11 (next bullet). The Docker lane follows
  the pin; its recorded run (2026-08-24) is at v1.13.9 and v1.36.3.
- **The Talos provider is pinned at 0.12.0, and the module renders a 1.14 node under the v1.13 config contract (#241,
  #44).** Provider 0.12 reads `talos_version` on the machine-configuration data source as the config contract, not as
  the node's Talos, and for a 1.14 contract renders Talos's multi-document config, which the module's v1alpha1 patches
  collide with (seven errors on every config apply, measured on OVH); 0.11 could not render that contract and silently
  gave the 1.13 shape. One local, `config_contract` (v1.13, or the node's own version when older), now feeds both data
  sources, so a 1.14 node's rendered config equals 0.11's (offline, real providers, no node). The cluster root and the
  local lane pin `0.12.0` exactly (no lock file is committed, so a range could change the rendered text unseen) and the
  module's ceiling is `< 0.13.0`. `replace_triggered_by` (upstream `siderolabs/terraform-provider-talos#352`, fixed in
  0.12.0) stays: no run without it has happened (#83). **Existing checkouts must run `tofu init -backend=false -upgrade` in
  `infrastructure/opentofu/cluster`** (Upgrade notes). Rung: mocked; real cloud once, Scaleway, 2026-10-05, 1 control
  plane + 1 worker (Validated; Known limits has what was not measured).
- **The image lane keeps one state per Talos version (#69).** Each version has its own state
  (`talos-image-<provider>-<version>.tfstate`), so a build touches only its own version: building v1.14.2 no longer
  replaces v1.14.1, and the refusal #93 needed (no build while another tfvars pins another version) is gone with its
  cause. `task image-build PROVIDER=<p>` takes `LIST=1` (the versions held), `PRUNE=1 VERSION=<v>` (destroy one, refused
  while a tfvars pins it) and `RETAIN=1` (next bullet). Images only: there is one cluster state, and a node built from
  an older image joins the same cluster. The image state takes no lock: one operator per lane, one run at a time per
  checkout. Rules and recoveries: `infrastructure/opentofu/talos-image/README.md`; the first-build migration and its
  refusals are in Upgrade notes. Rung: mocked; real cloud, 2026-10-05, Scaleway and Outscale (Validated; Known limits
  has what was not run).
- **`RETAIN=1` keeps the cluster's Talos version and the one below it, and `task cluster-up` offers it (#69).** With N
  the newest `talos_version` a tfvars pins, it keeps N and the highest version held below it and destroys the rest,
  lowest first, so a node can still be created on the previous image while the cluster runs N: on a cluster moved from
  1.14.1 to 1.14.2 it keeps both, after the move to 1.14.3 it destroys 1.14.1. A version above N and a version a tfvars
  names (`talos_version`, or an `image_name` or `talos_image_file_id` override) are kept; an `image_id` or an unreadable
  tfvars refuses the run. "Still needed" is judged from this checkout's `envs/*-<provider>.tfvars` only: a cluster
  whose tfvars is on another workstation is not asked, and with none present `PRUNE=1` only warns. `cluster-up` runs it
  after its `cluster-verify`, asks tofu's own yes for each image it destroys and only warns if it fails; **under
  `APPROVE=auto` it never prunes** (it prints the command), and `cluster-upgrade` does not run it, so run it by hand
  once a climb is verified. Rung: mocked; real cloud, 2026-10-05, Scaleway and Outscale (Validated).
- **`task cluster-up` ends with `cluster-verify` and fails when it does (#84).** It used to print "complete" without
  asking the cluster, and always exited 0; `cluster-idempotency` and `cluster-upgrade` now end non-zero wherever the
  verifier is red. Rung: mocked; seen red on a real Scaleway cluster, 2026-10-02.
- **Outscale spreads its nodes over the subregions listed in `availability_zones` (#58).** It read only the first entry,
  so three control planes shared one subregion. It now builds a private subnet per entry and places control planes and
  workers by index, a worker's data volumes in its node's subregion; the public subnet, bastion, NAT and load balancers
  stay in the first subregion (a load balancer takes one subnet, measured) and reach every node. A node's subnet is
  ignored after creation: **a cluster built before this keeps its layout and ends red, and no setting clears it**; so
  does a one-entry list. Rung: real cloud 2026-10-03 for the new layout (three control planes in three subregions,
  13/13, the load balancer UP on all three); the red was seen on the old module (12 passed, 1 failed), the kept layout is
  the mocked plan's reading, and the new module has not been applied live over an old cluster.
- **OVH examples and defaults name availability zones OVH accepts (#72).** They said `["nova"]`, which Nova tolerates and
  Cinder rejects on EU-WEST-PAR, so the first apply died creating the workers' data volumes. Now `eu-west-par-a/b/c` in
  the examples, the cluster default and the module default. Rung: mocked for those; the three zone names deployed and
  verified 13/13 on a real OVH account, 2026-10-03, through a private tfvars, so the shipped defaults never ran.
- **Examples.** The Scaleway examples move to `POP2-4C-16G`, the sizing floor (0.1.0 shipped `POP2-2C-8G` and, for the
  workload one, `DEV1-M`, absent from `fr-par-3`), and stop pinning an image the lane no longer holds. Outscale stays at
  `tinav5.c2r4p1`, below the floor on purpose (the floor on five nodes plus the bastion is 22 vCPU against a default
  quota of 20): a bare cluster only, deployed and verified 2026-10-03 (`docs/capacity.md`). The examples that hard-pinned
  Talos v1.13.3 and Kubernetes v1.35.3, a pair never measured on a cloud, now inherit the default pin.
- **The Docker lane is not a provider, and says so.** `cluster-*` tasks refuse `PROVIDER=local` and name the family that
  applies; `task local-verify` exists because that refusal names it. `K8S_API_PORT` moves the host port 6443 (a WSL2
  reserved range made `local-up` unrunnable); `local-up` refuses in about a second on a host without `CAP_SYS_RESOURCE`
  instead of hanging 90 s; `local-down` runs on a clone with only this repository; `opentofu-local` pins what the cloud
  root pins; `task local-test` now fails when workers never become schedulable or Flux never comes up, where it printed
  "validated end-to-end" regardless (no run of either failure is recorded). Rung: local Docker 2026-08-24, default 3+3:
  six nodes Ready, Cilium 6/6, `local-verify` 6/6.
- **Provider contract, for module authors.** `control_plane_zones` is a required output. The contract's tables are
  executed by `check-provider-contract.sh`, by name and type (it required a `bastion_ssh_key` string no module declares;
  all four declare `bastion_ssh_keys`), and `tofu validate` now fails on a missing contract output where it answered
  `Success!` (`try()` could not tell an inactive provider from a missing attribute). Rung: mocked.
- **Decisions written down (#82, #56, #70, #80, #172), and `flux_namespace` validated.** The bastion stays, hardened in
  place; revisit with two or more operators, or a stateful service whose restore has been run. Outscale has no state
  lock by design: one operator at a time. `talosctl upgrade-k8s` measured no gentler than the config-driven Kubernetes
  step, which stays. `flux_namespace` must be `flux-system`, the only namespace the vendored Flux install creates.
  Steering traffic between two live clusters is health-checked DNS from a zone that shares no fate with either, not BGP
  or anycast across providers: none of the three documents a customer BGP peer or prefix for a VM (vendor pages read
  2026-10-04). Not evaluated: a customer-operated router reaching each cloud over InterLink or DirectLink. DNS failover
  time (check interval times threshold, plus the TTL) is not measured.
- **Dependencies, final values (pins):** OpenTofu 1.13.1, Talos provider 0.12.0 (above), Cilium 1.20.2 (0.1.0 shipped
  1.20.0; the manifest is re-rendered, no cloud run of its own is recorded), flux2 2.9.6 (the vendored
  install and its controller digests refreshed; it reaches only a `deploy_flux=true` cluster, which no lab sets), helm 4.3.0, flux-schema 0.15.0, go-task 3.54.0, `kubectl-cnpg` 1.30.1, gitleaks 8.30.1, plumber
  0.5.20, commitizen 4.19.1, yamllint 1.38.0, Feint 0.13.0, and in `setup.sh` kubectl 1.37.1, aws-cli 2.37.9, checkov
  3.3.22 and pre-commit 4.6.2; the pre-commit hooks lag (commitizen v4.9.1, yamllint v1.35.1). A workstation's
  `talosctl` is pinned, checksum-verified and taken from the cluster's own `talos_version`. Rung: mocked; the pinned
  binaries were installed and run, with no cloud, and `setup.sh` ran to the end in a bare `ubuntu:24.04` container with
  all five of its newest pins.
- **Maintainer tooling; mostly nothing an operator types.** `task evidence-check` goes red when a provider's newest
  `docs/status.md` row is not at the pin, is older than 45 days (`OA_EVIDENCE_MAX_AGE_DAYS`) or carries a ❌ or ⚠; it is
  in neither `task lint` nor `task test`, and `task preflight`, which an operator does type, runs it with `--warn` (a
  stale row warns, an unreadable table fails). Gates that were green on something they had stopped checking now fail:
  `render-check` offline (`RENDER_CHECK_ALLOW_OFFLINE=1` is the deliberate way around, and `preflight` then says
  INCOMPLETE), `tflint` skipping most directories, a typo in a Cilium `--set` flag (#112). Cléa (`docs/clea.md`) probes
  each pinned bump from cold in a bare container and never reaches a cloud; its push-token and `action-sha` fixes are
  not yet seen on a runner (#91). For contributors: rung receipts let CI check a pull request's declared rung (`task
  receipts`), the hand-kept backlog file is gone (tasks are GitHub issues, "where we stand" is `docs/status.md`) and
  `Assisted-by:` is a tool-only trailer with no model version. The rest is in `task --list-all`. Rung: mocked, each
  gate reproduced in both directions.

### Validated

Measured by hand on real accounts. Dates and figures come from `docs/status.md` and `docs/upgrade.md`; control-plane
growth and the plan-only refusal from `docs/deployment-test-matrix.md` (growth also `docs/first-cluster.md`); the
changed `admin_ip` from `docs/admin-access.md`; the lock refusals from `docs/release-checklist.md`; the failover and
the provider pin from
`docs/status.md`; the node resolver from the matrix and PR #268; the image lane's runs from the message of PRs #269 and
#272 only. Versions were read from the kubelets and each node's own Talos API, never from the tool that performed the
upgrade. A longest outage is the longest run of consecutive failed one-second probes.

- **Scaleway, 2026-10-02 and 2026-10-03, each from an empty project under a fresh `bucket_suffix` (#68).** The first:
  `cluster-up`, `cluster-verify` 12/12, two `cluster-idempotency` passes; the Talos step rolled six nodes with the
  apiserver failing 6 times in 474 probes, longest 1 s; the Kubernetes step stopped on a defect of ours (PR #223, Fixed),
  and `adopt-bootstrap` plus a plain `cluster-up` brought the state back, after which the fleet read 1.37.1 everywhere
  (whether that run rolled anything is not recorded). A control plane powered off for 80 s cost 3 failed
  probes in 360 and a write succeeded. Torn down and proven clean that night. The second, with encrypted worker disks, a
  Longhorn volume and a Service probe: `cluster-upgrade` 1.13.9 / 1.36.3 to 1.14.2 / 1.37.1 in place on 6/6 nodes,
  `cluster-verify` 13/13, `No changes.` after. Longest outage 2 s (6 failed in 764, Talos step; 9 in 805, Kubernetes
  step); the Service failed 0 times, a blob written before the climb read back with the same hash, the stateful pod was
  gapped 20 s and 16 s. The roll stopped once on PR #229's defect (Fixed). On the pair #181 names (Talos 1.14.1,
  Kubernetes 1.37.0) the same day, Longhorn was written, read from other workers and across a node reboot, and the worker
  volumes read back by `cluster-verify`.
- **OVH, 2026-10-03.** 3+3 across `eu-west-par-a/b/c`, encrypted worker disks, `cluster-verify` 13/13. Kubernetes 1.36.3 to
  1.37.1 through `talosctl upgrade-k8s` (#70), 10 s (11 failed in 430), then the pin; plan empty after the climb and
  after the pin. Its Talos step, 1.13.9 to 1.14.2 on 6/6 nodes, was the roll with Flux and CNPG below.
- **A roll with Flux and CNPG, OVH, 2026-10-03 (#64).** A lab, not a `deploy_flux` cluster: the vendored Flux controllers,
  the CNPG operator 1.23.1 and local-path storage installed by hand, a three-instance CNPG cluster owned by a Flux
  Kustomization. `cluster-upgrade` took Talos 1.13.9 to 1.14.2: before every node the roll suspended the Kustomization
  and the CNPG budget, and at the end of each of its two rolls it checked both were restored (longest outage 1 s, 3
  failed in 583; the Service 3 failed and 3 blind in 621). The surrounding `cluster-upgrade` exited 201, because its
  closing `cluster-verify` found `flux-system`; `cluster-verify` read 13/13 only after the lab was removed.
- **Outscale, 2026-10-03.** 3+3 `tinav5.c2r4p1`, encrypted worker disks, `cluster-verify` 13/13, 6/6 nodes to Talos 1.14.2
  and Kubernetes 1.37.1, `No changes.` three times, one after the climb. Longest outage 9 s (68 failed in 1535: 3 s on
  the Talos step, 9 s on Kubernetes); the Service probe failed 40 times with 20 blind samples in 1490, longest 3 s.
- **Growth, 2026-10-03.** Scaleway workers 3 to 6, one worker per `task cluster-up`, three runs in a row (3 to 4 to 5 to
  6), each ending `cluster-verify` 13/13. After those three the following full plan was not empty (`0 to add, N to
  change`, N one fewer than the worker count; not investigated); the 2026-10-04 grow-back ended with
  `cluster-idempotency` passed. Control planes 1 to 3: Outscale by one `cluster-up` (three control planes and two
  workers, 13/13, the load balancer UP on all three); Scaleway and OVH are recorded as 1 to 3 only. Worker growth on OVH
  and Outscale is not recorded.
- **Removing nodes, 2026-10-04**, on each cloud's 3-control-plane cluster at Talos 1.14.2, Cilium only: a worker, then a
  control plane (3 to 2). `cluster-verify` green after every run (13/13 after a worker, 12/12 after the control plane,
  which reads `~ NOT HA` at two), etcd with exactly the members left, the provider's API listing exactly the machines
  left. Each control-plane run took an etcd snapshot, encrypted and uploaded to both buckets, before the leave. During
  the control-plane removal the load balancer kept sending one request in three to the member that had left etcd, for 40
  to 76 s (12 to 13 failed `/readyz` per cloud; the figures and what they do not separate are in `docs/upgrade.md`); a
  client that retries does not see them. Worker removals: Outscale 1 failed probe of 215, OVH none (bar the probe's own
  kubeconfig read), Scaleway not probed. Scaleway was grown back to 3+2 by one `cluster-up`: 13/13,
  `cluster-idempotency` passed. On that cluster only: Longhorn 1.13.0 moved a sole replica to the worker that stays
  before the drain (the volume stayed healthy and attached, its blob's checksum held) and refused a volume wanting two
  replicas at `--plan`; CloudNativePG 1.30.1, on one control plane and two workers, moved a replica on the departing
  worker with its volume (1000 rows on both instances, the budget and the maintenance window restored) and, with the
  primary on the departing node, failed over to the replica on the other worker (of 368 inserts sent once a second
  through the read-write service 2 failed, a run of 2 s, and none acknowledged was lost). The refusal of a lowered count
  ran plan-only on two real Scaleway shrink plans, 2026-10-03: both refused.
- **An interrupted bootstrap, Scaleway only, 2026-10-03.** `cluster-up` interrupted twice on purpose in phase 2: tunnels
  killed before the bootstrap call (a plain re-run resumed), then `SIGKILL` right after it (`adopt-bootstrap` found 3 etcd
  members and imported it). The stale state lock that kill left needed `tofu force-unlock`, which `explain-failure.sh` now
  names, with the holder, and says to check that run is really gone first.
- **The reader talosconfig, OVH only, 2026-10-03.** `TALOSCONFIG=<os:reader file> task cluster-verify` passes 13/13 through
  the tunnels while `talosctl get machineconfig` is refused. Mint one and reuse it until it expires.
- **Lock behaviour.** Scaleway refused a second `plan` by name (2026-10-02, #56); OVH refused the second run (HTTP 412,
  undated); Outscale holds no lock by design and none appeared while an apply waited (re-measured 2026-10-03).
- **A changed `admin_ip`, Scaleway, 2026-10-04.** Set to an address that is not ours (SSH to the bastion timed out); the
  plain apply stopped at the tunnel check; `OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true` applied in under four
  minutes, SSH worked again, `cluster-verify` 13/13. Not run on OVH or Outscale.
- **A failover, OVH to Scaleway, 2026-10-05 (#57).** A = OVH (1 control plane + 1 worker, `environment = prod`) with its
  replica on Scaleway's store; B = Scaleway (1 + 1) with its replica on Outscale's; both under one fresh
  `bucket_suffix`. A reached `cluster-verify` 13/13 and was destroyed in the two commands. In a shell holding only B's
  and Outscale's keys, `restore-artifacts` read A's kubeconfig and talosconfig back byte-identical from the replica,
  `restore-state` put A's PKI in B's state key, and B's `cluster-up` ended on `cluster-verify` 13/13 with an empty
  strict plan. A's saved kubeconfig listed B's nodes Ready and A's talosconfig answered on B's control plane; A's stores
  were unchanged afterwards. Both purges were clean. The drill found `image-build` ignoring `ROLE=` (Fixed) and left its
  buckets on the three accounts for their owner (#73).
- **The image lane, Scaleway and Outscale, 2026-10-05 (#69),** at 1 control plane + 1 worker, Talos 1.14.2. The legacy
  state was copied to its version's key (`No changes`, nothing rebuilt) and a second version built beside it. A worker
  created with an `image_name` override naming v1.14.1 booted that image, joined Ready on v1.14.1 and stayed on it;
  `cluster-verify` read the fleet `MIXED` (red), and with the override removed `cluster-up` rolled the node to v1.14.2
  and the verifier read green. `PRUNE=1` destroyed v1.14.1 and left the other versions untouched. Outscale's same-name
  gate refused a build of v1.13.8, an OMI of the account's that no state tracks, in 13 s with the snapshots unchanged;
  it asks the account (`ReadImages`) because the provider's `outscale_images` data source fails a whole plan on a name
  nobody holds, which the mocked provider hid.
- **Image retention, Scaleway and Outscale, 2026-10-05 (#69).** With a second tfvars pinning v1.14.0, `RETAIN=1` kept it
  and destroyed nothing; with that file gone it destroyed v1.14.0's images and snapshots, the provider's own listing
  agreed (the untracked v1.13.8 OMI on Outscale untouched), and a second `RETAIN=1` said `nothing to destroy`.
- **The Talos provider 0.12.0, Scaleway, 2026-10-05 (#241).** 1 control plane + 1 worker, Talos 1.14.2. A cluster built
  under 0.11 planned empty under the pin and `cluster-up` changed nothing (`cluster-verify` 12/12); rebuilt from an
  empty state under 0.12.0, it ended on `cluster-verify` 12/12 with `cluster-idempotency` green. Inside the 1.13
  contract 0.12.0 had already run on OVH and Outscale (a fresh deploy and a bump 1.13.9 to 1.13.11, 13/13, plan empty
  after).
- **The node resolver, OVH, 2026-10-05 (#173).** 1 control plane + 1 worker, Talos 1.14.2. Unset planned empty; setting
  the list replaced both `talos_machine_configuration_apply` with no "inconsistent final plan" (upstream #352),
  `cluster-up` applied it with no reboot and the strict plan was empty after. Both nodes resolved over DoT (a capture
  during image pulls showed tcp/853 and no udp/53), pods resolved names with a DoT-only list, and a healthy worker
  reboot was Ready in 47 s. A list no node can reach: the rebooted worker never started its Talos
  API (port 853 unreachable) and was still NotReady after 10 minutes with the 90 s bound in place; only replacing it
  recovers it.

### Fixed

- **Lowering `control_planes` or `workers` destroyed the highest-index machine and its data volumes, with no drain, no
  etcd leave and no Node delete, and nothing said so.** `cluster-up`, `infra-apply` and `grow-nodes.sh` now stop on a plan
  that deletes a node of a bootstrapped cluster (`grow-nodes.sh` allows creates only), and `node_distribution` is
  validated against the counts. Removal has its own commands (Added). Rung: mocked; two real Scaleway plans refused.
- **The roll deadlocked on Longhorn when it had as many replicas as workers (PR #229).** It waited for Longhorn to be
  healthy before uncordoning the node it had just rebuilt, but Longhorn puts no replica on a cordoned node, so the 600 s
  gate ran out. The node is uncordoned first. Rung: mocked; real cloud once, Scaleway 2026-10-03: found there (healthy 63 s
  after a manual uncordon), then the resumed `cluster-upgrade` ran the new order on two workers, the gate passing, rc 0.
  Not measured: a volume with fewer replicas than workers, where the old order also passed.
- **A roll exits 1 and names what is left when a Flux Kustomization is still suspended or a CNPG budget is missing
  (#64).** The exit trap restored them and nothing looked afterwards. The roll now waits (about two minutes, up to 211 s
  with the apiserver down; `RESTORE_TIMEOUT`, `RESTORE_POLL`, `RESTORE_REQUEST_TIMEOUT`), and a failed owner-label read
  refuses the roll on the way in. Ctrl+C ends the wait (exit 130); a roll stopped between nodes says so instead of
  "complete". The verdict comes after the last node is replaced, so do not re-run replacement mode to clear it (it
  replaces every node again): fix what is named and run `scripts/ops/backup-state.sh`, which `task cluster-roll` then
  skips, while `cluster-upgrade` stops between its two rolls. Rung: mocked; one real roll, the OVH lab above, green path
  only. CNPG 1.23.1 creates `<name>-primary` for a one-instance cluster (local Docker, scratch script, no receipt); a real
  cloud saw only three instances. Not observed: the failure branches on a real cluster (a Kustomization that stays
  suspended, a budget the operator never re-creates), a real Ctrl+C, and the two task effects (mocked only).
- **A size change through `cluster-roll` resized every node at once (#51, PR #222).** Scaleway 2026-10-02: with
  `instance_type` raised, `-- --workers-only` replaced worker 0 and its config step resized all three control planes, the
  API down 56 s. The roll now plans both steps before the cordon and refuses a plan that changes another node; a size
  change goes one node at a time, in place, 1 s blips (`docs/upgrade.md`). Rung: mocked; the refusal was seen at worker 0
  on that cluster, from an uncommitted pre-review tree. A resize is in place on every provider: measured on OVH
  (2026-08-15) and Scaleway (2026-10-02); Outscale and Proxmox from provider source and an offline plan.
- **`infra-plan` and `infra-apply` read an unreadable state as "no bootstrap" (PR #223).** On any read failure (an S3 error,
  a bad credential) a bootstrapped cluster's node counts were zeroed and its bootstrap, machine configs and kubeconfig
  dropped from the state; a live Scaleway upgrade ended that way on 2026-10-02, and `adopt-bootstrap` plus a plain
  `cluster-up` brought it back. It now answers only when the state is read or absent. Rung: mocked; against that cluster's
  state the helper answered true, a wrong secret key made it stop quoting OpenTofu's error, an absent state read as
  absent. Why the original read failed is not known.
- **A state that lost its Talos secrets is refused, and the teardown plan replicates the state before it untracks them
  (#66).** `task infra-down-plan` takes `talos_machine_secrets` out of the state to compute a destroy plan
  (`prevent_destroy` is a plan-time check), and so does `tofu state rm` by hand. Declining the destroy left nodes that
  trust a PKI the state no longer held: the next `cluster-up` minted another and every Talos call ended in `x509:
  certificate signed by unknown authority` while Kubernetes stayed healthy. Now `bootstrap-in-state.sh` refuses, before
  any plan of `cluster-up`, `infra-plan`, `infra-apply`, `cluster-roll` and `cluster-shrink`, a state that holds the
  bootstrap, a machine config or the kubeconfig without the secrets; `backup-state.sh` refuses to replicate it, so the
  replica stays the undo; `infra-down-plan` replicates first and never blocks a teardown. The cluster README's "Lost the
  Talos secrets" gives two recoveries. Rung: mocked; real cloud, Scaleway and OVH, 1 control plane + 1 worker,
  2026-10-04 and 2026-10-05: the symptom, the refusals and the recoveries (both on Scaleway; recovery 2 on OVH, the
  provider of the original incident). Nothing real ran at the merged head: the reworked untrack printing and the
  `backup-state.sh` and `cluster-roll` guards are mocked only (Known limits has what was not seen).
- **`restore-artifacts` read the wrong replica, and `image-build` ignored `ROLE=` (#57).** A replica on another cloud
  was opened with the cluster's own key, or not at all: the replica's keys were looked up without its endpoint, the
  bucket was named from `--role` (which picks the file) instead of the file's `cluster_role`, the last quoted string of
  a tfvars line became the replica endpoint (the `"dev"` of an inline comment), and every fetch error read as "not
  found". The `image-build` task never told the script which role it served, so on a machine holding only a failover
  file the lane looked for `management-<provider>.tfvars` and fell back to the shared `openaether` bucket namespace, a
  name another customer may own; the failover cluster could not be created. Rung: mocked; the `image-build` defect was
  found by the real failover drill (Validated).
- **The roll applied a plan other than the one it counted (#55), and missed a worker's data disk (PR #247).** Each per-node
  apply now plans to a file, counts deletes from it and applies it. `node_targets` matched `worker_data[<n>]` where OVH's
  attach and Outscale's link resources are keyed `"w<worker>-d<disk>"`, so a replaced worker lost its data disk until the
  next full apply (inferred from the graph, not run). Rung: mocked for both. #55's change merged 2026-09-26 and the
  receipts of the real rolls of 2026-10-03 on Scaleway and OVH are from heads that contain it; PR #247's replace path has
  never run on a real cloud (those climbs were in-place `--upgrade` rolls, which keep the node's disk).
- **`task cluster-upgrade` could not upgrade Talos, and could read another cluster's fleet (#181, PR #200).** It built
  the image before moving `talos_version`, and the image lane then refused to build while any tfvars pinned another
  version. It now moves the pin first (a failed build leaves it at the target and the previous image untouched, and the
  message says how to put the pin back) and fetches its own kubeconfig, not whichever cluster wrote the shared one last.
  Rung: mocked; the 2026-10-03 climbs on all three clouds ran in this order, on the single-image lane #69 replaced.
- **`cluster-roll` rolled the management state whatever `ROLE=` said.** `cluster-upgrade ROLE=workload` applied the
  workload tfvars and then rolled the management cluster; both now follow `ROLE=`. Rung: mocked; the workload role has no
  real-cloud run.
- **`task upgrade PROVIDER=x DRY_RUN=1` started a real upgrade (PR #218), `UPGRADE_TALOS_TO` and `UPGRADE_K8S_TO` on the
  command line were ignored too; `task cluster-up` checked the passphrase after creating the buckets (PR #217) and
  advertised a `VERSION=` it ignored.** A Task variable is not an environment variable, so the script never saw them; the
  target now passes all three on; the passphrase check runs first; the tfvars pin decides the version. A dry run also
  leaves no rung receipt. Rung: mocked.
- **`etcd-snapshot.sh` retention deleted almost everything while a cluster had the fewest snapshots.** The prune slice went
  negative below `KEEP` objects and jq counts a negative end from the end: at `KEEP=30`, 29 snapshots became 1, every
  run. Two siblings fell out: an optional tfvars key silently killed the scripts that read it, and `s3_cred` with kind and
  type swapped printed the secret where an access-key id belongs. Rung: mocked. The script also ran inside the three real
  control-plane removals of 2026-10-04 (snapshot, encryption, upload to both buckets, retention; each run rc 0); no
  stand-alone `task etcd-snapshot` run is recorded.
- **Building a Talos image for one cluster could delete the image another cluster's tfvars still pinned (#93), and a
  Factory answer without a schematic id went to "image already up to date" one step from a billable publish.** The lane
  held one image per provider and nothing failed until the other cluster's next plan; with one state per version a
  build can no longer replace another version's image (Changed; retention and prune still read only this checkout's
  tfvars). `talos-image.sh` also refuses when the Factory answers without a schematic id
  (`TALOS_IMAGE_ALLOW_OFFLINE=1` is the deliberate way around). Rung: mocked for the refusal; the lane's real runs are
  in Validated.
- **`seed-openbao.sh` named a backups bucket that did not exist on any cluster deployed under a `bucket_suffix` (#166).**
  Restic and Loki were seeded with the wrong name and the seeder reported success. The name now comes from the derivation
  every other caller uses. Rung: mocked.
- **The Scaleway node security group opened every port (#79).** The provider stored an omitted port and `port = 0` as the
  same rule, so an earlier fix changed nothing. The group now lists the ports this repository's layers serve over the
  private network, from the module's own subnet, pinned to the private network's own /22; `100.64.0.0/10` keeps only the
  load balancer backend ports, and the rules sourced from the load balancers' public IPs, the dead bastion-public-IP rule
  and the `10.0.0.0/8` rule are gone. Rung: mocked, and emulated (apply, empty re-plan, destroy of the whole root). No run
  is recorded as confirming the load balancers' health checks under the new group, or as applying it to an existing
  cluster (Upgrade notes).
- **The teardown proofs read "could not ask" as "clean".** Scaleway had no check in `verify-provider-clean.py` (exit 2); it
  now lists the cluster's servers, load balancers, gateways, security groups and networks plus every detached IP and
  volume. The Scaleway purge (`task purge-orphans PROVIDER=scaleway APPLY=1`) now also lists and deletes what it never
  touched, public gateways, their IPs, load balancer IPs left without a load balancer, security groups and instance
  volumes, and it read the first 50 items of each list only; it now reads page by page. A kind no zone answered, missing
  credentials, a refused OVH login or region, and a refusing endpoint under `--apply` exit 2, not the 1 that means
  "leftovers" or a clean 0; `--apply` no longer ends on "The project is clean" and asks for a re-run; `ovh.py` counts
  refused calls (#63); `edge-down.sh` no longer sends a Scaleway or Outscale operator to the OpenStack-only deleter;
  Outscale lists leftover snapshots (#71, PR #108) and this account's images, never deleting either (#107). Rung: mocked
  and emulated; real cloud for Outscale's image read (read-only). The Scaleway checker has no recorded real-cloud run
  (`docs/status.md` says only that the 2026-10-02 project was proven clean that night). Buckets are not listed.
- **The bastion's SSH-CA hooks shipped inert (#81).** `TrustedUserCAKeys` and `AuthorizedPrincipalsFile` were hardcoded
  to an empty file; `bastion_ssh_ca_public_key` and `bastion_ssh_ca_principals` are now variables of all four provider
  modules, default `""`, identical rendered bytes when unset. **The cluster root does not forward them, so no tfvars
  can turn SSH-CA on yet:** enabling it means editing the root. `task ssh-ca-check` now refuses to start without Docker
  instead of skipping with exit 0. Rung: local Docker (`task ssh-ca-check`, a real sshd); never on a cloud bastion, and
  `bastion-harden-check.sh` has no recorded run against one.
- **`converge-versions.sh` had no downgrade guard of its own (#90).** It survived a downgrade only by accident, on two
  layers it does not own. It now refuses a pin semver-lower than what the fleet runs, naming both. Rung: mocked.
- **Statements about a deploy that were wrong.** The Taskfile said `cluster-up` asks once; it asks twice (the phase-1
  plan and `bootstrap-phase2`'s). `cluster-upgrade` said its applies ask; they run with `APPROVE=auto`. On Proxmox with
  `enable_bastion` the root now reports the VM's user, `ubuntu` (PR #209; Known limits). 0.1.0's docs said the first
  apply after a `talos_version` bump fails once on OVH and Outscale and must be re-run (upstream
  `siderolabs/terraform-provider-talos#352`); the module already carried the workaround (`replace_triggered_by`) in the
  0.1.0 tag, and the 2026-10-03 climbs applied the bump in one apply on all three clouds, through `cluster-upgrade`,
  which has no retry.
- **`setup.sh` died, or silently kept an old tool, on a bare machine.** `talosctl` is installed from a pinned,
  checksummed release; OpenTofu is pinned instead of asking the GitHub API for the newest (a 403 took the bootstrap
  down) and no longer goes through snap or brew, which cannot install a named version; the pinned ShellCheck installer
  installs `xz-utils` when missing (its absence also made Cléa blame flux2, #174); `check_cmd` compares versions, so an
  upgrade is no longer skipped; `sudo` is asked whether it can be used, not whether it exists; checkov goes in a venv so
  `task security` can finish on Ubuntu 24.04; it now also installs actionlint, gitleaks, plumber and the flux-schema
  plugin; kubectl (checksum-verified), aws-cli, checkov, yamllint and pre-commit, installed at whatever upstream served
  that day, are pinned, so Cléa's probes compare a version instead of watching one move. Rung: mocked; run from cold on
  one machine the repository had never been set up on; a bare `ubuntu:24.04` is recorded for the OpenTofu 403, the
  missing `xz` and the five new pins (run to the end, all five at their pin).
- **A real `envs/*.tfvars` turned `task lint` red and was rewritten or deleted by the tooling (#191).** `task fmt` and the
  pre-commit hook rewrote the ignored files, the hook while saying Passed, and several harnesses wrote and deleted their
  fixtures in `envs/`. Both leave the real directory alone. Rung: mocked, with synthetic tfvars planted in `envs/`.

### Security

- **`admin_ip` refuses to open the cluster to the internet.** The variable had no `validation`, so `["0.0.0.0/0"]` was
  accepted in silence, and it feeds bastion sshd and the 6443 LB ACL on all four providers at once. Behind that ACL sits a
  `system:masters` kubeconfig Kubernetes cannot revoke. Three rules now reject an empty list, an entry without a prefix
  (including the `YOUR_IP/32` of a copied example) and any `/0`, read from the prefix. Rung: mocked (`tofu test`); each
  rule was deleted in turn and the suite watched to go red before it was kept.
- **Admin access is documented as unrevocable where it is unrevocable.** [`docs/admin-access.md`](docs/admin-access.md)
  says what a leaked kubeconfig costs, instead of leaving the reader to find out.
- **The Scaleway node security group lists ports instead of opening every one (#79, Fixed).** Scaleway's security groups
  filter public traffic only and these nodes have no public IP, so on this provider the list declares the perimeter; it
  does not enforce it.
- **Credential lifetime can be narrowed:** `task talosconfig-new` (Added) issues a role-scoped talosconfig that expires;
  it is not the default, and the deploy still hands out `os:admin` valid a year.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **Proxmox has never been applied on real hardware (#48).** The module is code and mocked tests; no tunnel has gone
  through a Proxmox VM bastion, and whether `ubuntu` joins `bastion-admins` is unmeasured (#201).
- **The real-cloud workflow has never run.** Its secrets, a dedicated SSH key, the tfvars of sandbox accounts and a
  decision on `admin_ip` (a hosted runner has no small stable IP) are the owner's to create; the first dispatch is where
  a real account gets to disagree with it.
- **Removing a node: a half-way stop has only run against fixtures, never on a real cluster.** Longhorn's eviction and
  CNPG (a replica, and a primary) ran on Scaleway only. A node that holds a node-local volume is refused, not migrated.
  The load balancer keeps sending one request in three to the departed control plane for 40 to 76 s (measured on all
  three clouds); taking the member out first is not built, and its effect was not measured.
- **A control-plane roll with zero failed probes has not happened on any cloud (#42).** Longest outage observed, Talos step: 1-2 s on
  Scaleway, 1 s on OVH, 3 s on Outscale; Kubernetes step: 2 s on Scaleway, 9 s on Outscale (OVH: 10 s through
  `upgrade-k8s`). Plan for a gap.
- **The failover ran for one provider pair, and only as a rebuild (#57).** OVH to Scaleway, 1 control plane + 1 worker
  each, 2026-10-05 (Validated). Not run: any other pair, three control planes, Talos discovery with a live A (its
  records can outlive A by up to 30 minutes: read `talosctl get members` on B). Etcd contents and application data are
  not in the two stores. A's gitignored env file is in no store, and backing it up is undecided. The drill's buckets
  stand on the three accounts until their owner deletes them, as for #73.
- **Flux is off by default, and `cluster-verify` fails a cluster that has a `flux-system` namespace.** The one roll with
  Flux and CNPG was a hand-installed lab on OVH (Validated). Flux's own controllers no longer record
  `gotk_reconcile_condition` (by about Flux 2.5, inferred from flux2's `go.mod`, not measured), so no per-object Ready
  signal comes from them: per-object state is `gotk_resource_info` through kube-state-metrics, whose manifests live in
  `OpenAether-apps` (#46). The vendored install is flux2 2.9.6 and has run on no cluster. There is no CAPI and no
  multi-cluster; a management cluster is an optional overlay.
- **Outscale: a Net that will not delete (#43).** One Net from before the load balancer fix still refuses deletion on a
  dependency no read returns; only Outscale can clear it, `purge-orphans` there cannot read clean while it exists, and
  Outscale's instruction is to create no further load balancer in that Net and use a fresh one. After `fleet-down`
  completes, the account lists a load balancer and a Net as `deleting` for about three minutes: read it again before
  calling it dirty. There is no state lock: one operator at a time.
- **Scaleway over three zones has no run on record**, though the shipped example names three; over two it is a 2+1 split
  and a warning. The Outscale examples sit below the sizing floor on purpose (bare cluster only).
- **Runs not repeated:** a non-empty `bucket_suffix` has been deployed on Scaleway (#68) and on OVH (the failover
  drill, 2026-10-05; Outscale only held a replica bucket named by it), and on no Outscale cluster of its own; the OVH
  teardown has no tracked record of a second run, where the release checklist asks for two (0.1.0's limit, still open).
- **The Talos provider is 0.12.0, and the 1.14 climb has not run under it (#241).** The climbs of 2026-10-02 and
  2026-10-03 ran under 0.11. Under 0.12.0 a 1.14 cluster was built and verified on Scaleway at 1 control plane + 1
  worker; inside the 1.13 contract it ran on OVH and Outscale (a fresh deploy and a bump 1.13.9 to 1.13.11, 13/13) with
  `replace_triggered_by` still in. Not measured: three control planes, `cluster-upgrade` 1.13.9 to 1.14.2, a 1.14
  cluster on OVH or Outscale, a run without `replace_triggered_by` (#83). `talos_machine` (#44) is not adopted.
- **A state that lost the Talos secrets is refused, and comes back only from a replica copy or a talosconfig the nodes
  still trust (#66).** With neither there is no way back from here. The cause of the 2026-08-15 mismatch is not
  established; the version flip is refused by `prevent_destroy` and the interrupted-apply path was not broken. Not seen
  on a real cloud: Outscale, three control planes, a replica on another provider, `cluster-verify` on a lost PKI.
- **Rolling an upgrade back is not proven (#270).** The image lane keeps the cluster's version and the one below it
  (#69), which is the medium for a node on the previous Talos, and nothing more: `converge-versions.sh` refuses a pin
  below what the fleet runs, `talosctl rollback` is wrapped by no script and described by no runbook, and no run is
  recorded that took a rolled node back. A node created on the previous image joined Ready on it and stayed there; the
  fleet read red, `MIXED`, until `cluster-up` rolled it forward.
- **The image lane ran on Scaleway and Outscale only (#69), and its retention needs a person.** Not run: OVH's lane,
  Proxmox, the retention hook inside `cluster-up` under a real terminal and tofu, the destroy of a held set through it,
  a legacy state holding the oldest version on a real backend, `--import-snapshot` (stand-ins only), a node one minor
  behind, a control plane on an older image. Retention never prunes under `APPROVE=auto` and `cluster-upgrade` does not
  run it, so an unattended run keeps every image; it reads this checkout's tfvars only, so a cluster whose tfvars is
  elsewhere is not asked.
- **The old `-talos-staging` buckets still hold every QCOW2 they were given (#73)**, one per cloud built from
  (`docs/status.md` counts two); only a human can empty them, and no script enumerates buckets.
- **Destroying a cluster whose pinned image is gone is unproven (#269).** On Outscale `infra-plan` fails on the missing
  image and `infra-down-plan` takes its `-refresh=false` fallback; that fallback's plan was never applied (an equal plan,
  made after the override was removed, was), and Scaleway did not reproduce the failure.
- **The Docker lane at 1.14.2 is unmeasured.** `task local-up` at 1.14.2 did not start on the one host tried (kernel
  6.12); the recorded Docker run is at v1.13.9 and v1.36.3.
- **The purged address is still served by GitHub, by its SHA and in the original pull request's diff (#61).** Only GitHub
  can remove it; a published value is published.
- **The emulated lane is weaker than the cloud:** the lanes that destroy run the Scaleway provider below 2.83.0 while real
  clusters run newer, the fix waiting on a Feint release (#179); `feint shapes` has no real-cloud recording (#76);
  `talos-image` is outside the lane (#47).
- **Never recorded against real infrastructure:** `bastion-harden-check.sh` on a real bastion, `k8s_lb_mode = "vip"` on
  OVH, a stand-alone `task etcd-snapshot`, the `workload` role.
- **The tag ruleset blocks moving or deleting any tag, 0.1.0 included**, so a release tag cannot be re-cut. That the ruleset
  has no bypass actors is checked only by an admin's run of `check-required-checks.sh` (CI's token cannot read them), and
  no such run is recorded.
- **Also open:** why the tunnels died on Outscale (#65; transcripts are now kept, one induced TERM was quoted correctly
  and no unprompted death is recorded), and an OVH node that can stay `ACTIVE` while dead (#49, blocked on the
  provider).

### Upgrade notes

For an operator on 0.1.0. Read the plan before you approve it, and the roll `cluster-up` prints.

- **A tfvars that leaves `talos_version` and `kubernetes_version` unset now inherits v1.14.2 and v1.37.1, and
  `cluster-up` is built to converge the fleet onto them.** It prints the roll before it asks, but a plain pull then
  `cluster-up` is a Talos 1.13 to 1.14 and Kubernetes 1.36 to 1.37 upgrade, and `cluster-verify` is red until it lands.
  A plain `cluster-up` has rolled one worker, v1.14.1 to v1.14.2, on two clouds (2026-10-05); a minor climb through it
  has only run mocked, and the measured climbs used `cluster-upgrade`. Set both explicitly to stay where you are; a
  downgrade is refused. A tfvars copied from an example that hard-pinned v1.13.3 and v1.35.3 keeps that pair, which was
  never measured.
- **After pulling, run `tofu init -backend=false -upgrade` in `infrastructure/opentofu/cluster` (or `task validate`,
  which shares the lock).** The Talos provider is pinned at 0.12.0 and the lock file is local and gitignored, so every
  `infra-*` task stops at init on a stale 0.11 lock. `-upgrade` moves every provider within its constraint: read the
  next plan. To move only talos, delete its block from `.terraform.lock.hcl` and run a plain `tofu init`. A cluster
  built under 0.11 planned empty under the pin (Scaleway, 1 control plane + 1 worker); no three-control-plane cluster,
  no OVH or Outscale 1.14 cluster and no climb has done so.
- **Three control planes in one failure domain now end red:** OVH built on `nova` (read from the config, never seen on a
  live cluster; the verifier's red line names the knob that clears it for a new cluster, and what changing it does to
  nodes already built is not measured), an Outscale cluster
  built before the subregion spread (Changed: its layout is kept, no setting clears it), Proxmox on one host. `cluster-up`
  ends at its verify, so `cluster-up`, `cluster-idempotency` and `cluster-upgrade` end non-zero there. A state older than
  the `control_plane_zones` output reads UNCHECKED, which is fatal, until one apply.
- **A lowered count is refused**; use `task cluster-shrink-plan` then `task cluster-shrink`. Do not route a node size
  change through `cluster-roll`: it is an in-place update of every node at once, and `docs/upgrade.md` has the one-node
  procedure. The new examples' `instance_type` is a size change on a running cluster.
- **`admin_ip` is validated:** an empty list, an entry with no prefix and any `/0` now fail the plan. Changing it on a
  bootstrapped cluster needs `OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true` (`docs/admin-access.md`).
- **OVH's default `availability_zones` moved from `nova` to the three EU-WEST-PAR zones.** A tfvars that leaves it
  unset changes zone; whether that replaces a node or a volume was not run, so pin what the cluster was built with and
  read the plan for replacements. A tfvars copied from 0.1.0's example names `["nova"]` itself: the default does not touch it, and it ends
  red (the failure-domain note above).
- **Scaleway clusters built under 0.1.0:** the module now pins the private network's subnet and rewrites the node security
  group's rules. No recorded run applied that to an existing cluster: read the plan and stop at any network or node
  replacement.
- **The image lane:** the first build of the version the old `talos-image.tfstate` holds copies it to its own key and
  renames the old object, never deleted. A legacy state with a deposed or tainted object, or objects naming two
  versions, refuses the build of the version it holds (the image README names the way out). On Outscale the same-name
  gate runs on `--ensure` only: a plain `task image-build` still reaches the provider's 409 after the 8 to 14 minute
  import, and only the account's owner can delete the untracked OMI that caused it, which the script never does.
  `cluster-up` now ends by asking tofu's own yes for each image below the cluster's version and the one under it
  (skipped under `APPROVE=auto`; Changed).
- **Teardown:** the plan step of `task cluster-down` replicates the state before it untracks the Talos secrets, and a
  state without them is refused until restored (#66).
- **Smaller:** `task cluster-up VERSION=` is not an argument; `cluster-*` tasks refuse `PROVIDER=local`; `cluster-up`
  refuses a never-applied `prod` cluster whose replica shares the primary's cloud, and fails when its verifier does.

---

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
