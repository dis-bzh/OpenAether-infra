# Release checklist — 0.2.0

English only: rewritten each release, and two copies would drift.

What to run before tagging 0.2.0 and telling anyone about it. Ordered by what
fails cheapest. **Stop at the first red** — every later step assumes the earlier
ones held.

Nothing below is ticked: a checklist records what to run, not what was run. Write
the result next to each line as you go — a date, a number, the command's own
words. A line with no result is a line nobody ran, and that is the answer this
checklist exists to make visible. What a line says `docs/status.md` records is an
older measurement, not a result for this release; re-read that file at the release
commit, it moves. Name the rung every claim reached: mocked, emulated, local
Docker, or real cloud — once by hand, or repeated. Nothing has run unattended to
completion.

0.2.0 keeps the 0.1.0 scope: one Talos cluster, Cilium as the whole platform, Flux
off (`deploy_flux` defaults to false, and `cluster-verify` fails on a
`flux-system` namespace), no applications, no CAPI. None of that is a gate here
and the notes must not claim it. What 0.2.0 adds is §7. Three clouds have
real-cloud rows and no bare metal does — say on what.

---

## 1. Clean-machine bootstrap (the first five minutes)

Not your working tree: it has files a clone does not, which is how the CNI defect
survived, and your workstation is no clean machine either. Build the archive from
the **release commit** and run it in a bare container, as a newcomer would — this
is also §9:

```bash
git archive --format=tar <release commit> > /tmp/repo.tar
docker run --rm -v /tmp/repo.tar:/tmp/repo.tar:ro ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
  mkdir /oa && tar -xf /tmp/repo.tar -C /oa && cd /oa && ./scripts/setup.sh'
```

- [ ] `setup.sh` completes and installs **helm**. Record the versions it prints:
      they are its own pins, so they are not copied here.
- [ ] **`nc`** is absent from the image: `setup.sh` says so and installs netcat.
      It only warns where `apt-get` is absent.
- [ ] every command the README quick start names exists (`task --list-all` plus
      aliases) and its example values are accepted. Check it can fail: an
      invented name must come back absent.
- [ ] `task preflight` green. Record the totals it prints and never type them
      here: a hand-typed count drifted repeatedly (#111). It also warns on a
      `docs/status.md` row older than 45 days and fails if that table cannot be
      read. It does not cover `render-check` offline (it says INCOMPLETE), `task
      security` (trivy, checkov), `task apps-validate` (needs
      `../OpenAether-apps`) or `task check-flux-digests` (network, outside lint
      and CI): a skip is not a pass.
- [ ] no bucket is orphaned by a rename in this release. The old
      `…-talos-staging` buckets still hold QCOW2s and only the owner empties them
      (#73): name them in the notes, with the buckets of the failover drill (§7)
      and of the image lane, which stay on the accounts they ran on. No script
      enumerates buckets (`verify-provider-clean.py`'s `UNCHECKED` list says what
      each check does not), so check each cloud's by hand.

## 2. Local Docker — the credential-free rung

On a Docker host, from the same archive unpacked, no `.env.sh`: `task local-up`,
`local-status`, `local-test`, `local-down`. A host that cannot boot Talos in
Docker is refused in about a second (PR #138): record a skip, not a pass.

- [ ] `local-up` renders `cilium-local.yaml` itself when the manifest is absent,
      and a second `local-up` does not re-render it (same mtime, size, inode).
- [ ] **Cilium is actually running** on every node, and `local-status` prints the
      etcd members.
- [ ] `local-test` is green **and** its checks are fatal: delete the `cilium`
      daemonset in `kube-system` and it must go RED (exit 201, `no working CNI`).
- [ ] `local-down` leaves no container, volume or network behind: snapshot before
      and after, and test the diff on two deliberately different snapshots first —
      a diff of a file that does not exist reports zero.
- [ ] at the shipped pin: `docs/status.md` records the Docker lane only at Talos
      1.13.9 / Kubernetes 1.36.3 (2026-08-24), the commit that moved the pin says it
      did not run the lane at the new pair on the host that made it, and `task
      local-up` at 1.14.2 did not start on the one host tried (kernel 6.12): record
      what your host does.

## 3. Emulated cloud — no account, real provider binaries

The lane is pinned to Feint 0.13.0, running against the same Scaleway provider
version the clusters run — except the lanes that destroy (the fixture and
`feint-apply-root`), capped below 2.83.0 (#179, open: Feint's fix is unreleased).

```bash
task feint-up                          # idempotent: feint-test below reuses it
task feint-plan PROVIDER=scaleway      # loopback endpoint: accepted, exit 0
task feint-record PROVIDER=scaleway    # and outscale
task feint-plan PROVIDER=scaleway FEINT_ENDPOINT=https://api.scaleway.com   # must REFUSE
task feint-test                        # both providers, plan + CRUD, then stops the emulator
```

`feint-test` stops the emulator it ends with: `feint-plan` and `feint-record` run
before it, never after (they then exit 1, `no emulator`). The refusal runs before
the emulator check and works either way.

- [ ] both providers green on plan and on apply/destroy, each with an empty re-plan
      and a destroy confirmed against the API. Record the counts it prints.
- [ ] the `feint-record` ranking shows no operation that was not there at the last
      run: a NEW entry is the alarm, an empty ranking is not.
- [ ] the guard refuses a non-loopback endpoint **both ways**, as a Task variable
      and as an environment variable (a Task variable is not an environment
      variable, and this test once passed without testing anything): exit 201,
      `endpoint https://api.scaleway.com is not local; this lane drives an
      emulator, never a real cloud`. **And the normal case**: the loopback
      endpoint is accepted, exit 0.

## 4. Cloud — Scaleway first, it is the reference

Use a **throwaway project**, not one holding anything real. Copy
`envs/management-scaleway.tfvars.example` to `.tfvars`, edit it, `source .env.sh`,
then `task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/your-key`.
`preflight-quotas` has no Scaleway backend (`ovh` or `outscale` only), and
`cluster-up` refuses before spending if the env file, the SSH key, an S3
credential pair or the passphrase is missing, and ends by asking tofu's own yes
for each old image the retention destroys (§7, image lane).

- [ ] **deploy from an empty project** under a fresh `bucket_suffix` (`task
      bucket-suffix`; recorded on Scaleway only, #68). Record duration and
      resource count.
- [ ] **`task cluster-verify`** green. A warning is a finding: it now reads each
      control plane's failure domain and each worker's data volume (the volume read
      needs `task tunnels-up`; without a tunnel it warns instead of passing).
- [ ] **idempotency is three assertions, not one**: an empty plan, the *same*
      nodes (name and `creationTimestamp`), and a kubeconfig that still reaches
      the apiserver. Two of the three can pass while the cluster was rebuilt.
- [ ] **the replica really is elsewhere**: an encrypted tfstate in a `-backup`
      store at another cloud, opened with THAT cloud's keys (S3 credentials are
      namespaced by the cloud that holds the bucket).
- [ ] `task etcd-snapshot PROVIDER=scaleway` writes to both buckets. It ran inside
      the three real control-plane removals of 2026-10-04 (§7, each rc 0);
      **no stand-alone run is recorded**, and its retention once deleted almost
      everything (PR #167, found by a mocked harness).
- [ ] **teardown**, two commands and then the provider's own answer:
      ```bash
      task cluster-down PROVIDER=scaleway
      task cluster-down PROVIDER=scaleway PLAN=destroy-management-scaleway.tfplan APPROVE=auto
      python3 scripts/ops/purge-orphans/scaleway.py
      ```
      Record the counts, volumes included: an empty server list is not an empty
      account (teardown skill). The plan step replicates the state before it
      untracks the Talos secrets and prints the undo (#66): read it before you
      decline a destroy.
- [ ] if the budget allows, none with a recorded result: the **`workload` role on
      any cloud** (`SCW-work-ha`, `SCW-storage`, `OVH-work-ha`, `OVH-storage`,
      `OSC-work-ha`: all untested; worker volumes were read back on the management
      role only) and **bastion hardening**,
      `scripts/ops/bastion-harden-check.sh <bastion_ip> <bastion_user> <ssh_key>`
      (never against the reference cluster).

## 5. Cloud — OVH

`task preflight-quotas PROVIDER=ovh`, then `task cluster-up ROLE=management
PROVIDER=ovh`.

- [ ] the same pillars as §4 on the example's three `availability_zones`
      (`eu-west-par-a/b/c`; the first attempt on the old `nova` default died,
      #72), `cluster-verify` green. One zone must end red (§7): read from the
      config, never seen on a real OVH account.
- [ ] teardown **twice**: an Octavia LB orphaned by one teardown was silently
      reused by the next deploy, and only a second teardown proves the check that
      covers it. **No tracked file records a second teardown.**
- [ ] `python3 scripts/ops/purge-orphans/ovh.py` clean on the first pass.
- [ ] `OVH-vip`, if budget allows: `k8s_lb_mode=vip` has never been applied on OVH.

## 6. Cloud — Outscale

`task preflight-quotas PROVIDER=outscale`, then `task cluster-up ROLE=management
PROVIDER=outscale`, into a **fresh Net** (`docs/status.md` says why). The control
planes land in the subregions of `availability_zones` (#58); a cluster built
before that keeps its one-subregion layout and still ends red (the red was seen
on the old module; the kept layout is the mocked plan's reading).

- [ ] the same pillars as §4, `cluster-verify` green with three subregions.
- [ ] teardown as in §4, then the two reads below instead of "clean". After
      `fleet-down` the account lists a load balancer and a Net as `deleting` for
      about three minutes (#69's lab): read again before calling anything dirty.

**Outscale exemption: `purge-orphans` cannot end clean here, and its line is never
ticked as clean.** While the pre-fix Net of #43 exists, the purge lists its
resources and every deletion is refused (`A load balancer is present on Net`, then
`The Subnet is in use. It has NICs`, then `The Net is in use. It has Subnet(s)`);
with `--apply` it ends `N of M deletion(s) failed — the account is NOT clean`,
exit 3. Read instead, and write down:

- [ ] `python3 scripts/ops/purge-orphans/outscale.py` (dry run) exits **1**, as
      expected; exit 2 is the failure to watch. Every target belongs to the stuck
      Net, matched by id against the ids you noted for it in private (never in this
      repository), and none is a load balancer, NAT service or public IP of the run
      you are proving. Its images and snapshots block lists the Talos image(s) the
      lane built, kept on purpose (`never auto-purged`): match their ids against
      what you built, in private.
- [ ] `python3 scripts/ops/verify-provider-clean.py <cluster> outscale` exits 0: no
      VM left, no unassociated public IP. It asks the native API; the
      EC2-compatible endpoint returned zero VMs while seven ran. Neither read may
      exit 2: a refused call is not an all-clear.

Anything outside the stuck Net and those kept images is yours.
`.claude/skills/release/SKILL.md` still says "purge-orphans clean on each": amend
it (shared with `OpenAether-apps`, so the parity check applies).

**One rule stays here.** This object store accepts a second conditional write, so
`use_lockfile` is on for Scaleway and OVH and deliberately **off** here, where it
would claim a state lock and hold nothing: one operator at a time. Re-measured
2026-10-03: no `.tflock` object appears while an apply waits; on OVH the second
run was refused, HTTP 412.

## 7. Upgrades, growth and removal — a cluster that has to stay up

§§1-6 prove a cluster can be built. They prove nothing about keeping, growing,
shrinking or rebuilding one elsewhere, which is what 0.2.0 adds. The upgrade
procedure is [`upgrade.md`](upgrade.md); what a *release* adds to it:

- [ ] the one-second probe up throughout, and the claim made as a number: the
      LONGEST consecutive run of failed `/readyz` samples, not the total, per step
      (Talos, Kubernetes) because they differ. "No interruption" is not
      measurable, and the leader-last roll is not shown to explain any figure
      (`upgrade.md`).
- [ ] on **three clouds**, every node upgraded **in place** under its own name,
      the running SCHEMATIC compared, not just the version tag; then
      `infra-plan ... STRICT=1` exits 0 and `cluster-up` prints `No changes.`
      `cluster-upgrade.sh` does not retry a failing apply, on purpose.

### Proof rows new since 0.1.0

What to run, what `docs/status.md` records (rung and date), and what it does
**not**: a gap to run, or to name under Known limits.

- [ ] **The 1.14 climb** — `task cluster-upgrade`, then `cluster-verify`,
      `infra-plan STRICT=1`.
      *Recorded:* a row per cloud (Scaleway two), 2026-10-02 and 2026-10-03, real
      cloud by hand; verify green, plan empty after. All under Talos provider 0.11:
      0.12.0, the shipped pin, was built and verified from empty on Scaleway at 1+1
      (2026-10-05) and ran the 1.13 contract on OVH and Outscale.
      **Not recorded:** a second climb run start to finish without a stop
      (Scaleway's 2026-10-02 Kubernetes step ended in PR #223's defect, its
      2026-10-03 roll stopped once on PR #229's); zero failed probes (#42, open);
      Proxmox; the climb under provider 0.12.0 (#241), or a 1.14 cluster under it
      with three control planes or on OVH or Outscale; a cluster built by the 0.1.0
      tag (every row is a fresh deploy); a plain `cluster-up` carrying a minor
      climb (it rolled one worker, v1.14.1 to v1.14.2, on Scaleway and Outscale
      2026-10-05).
- [ ] **Node growth** — raise a count, `task cluster-up` (`grow-nodes.sh`, #59).
      *Recorded:* Scaleway, a worker added by one `cluster-up` three times
      running, 3 to 6, 2026-10-03, real cloud by hand. Only in the matrix and
      `first-cluster.md`: control planes 1 to 3 on all three clouds.
      After the three worker growths the next full plan was not empty (`0 to add,
      N to change`; commit 23b6c19 did not look further); only the 2026-10-04
      grow-back ended with `cluster-idempotency` passing. **Not recorded:** worker
      growth on OVH and Outscale. `first-cluster.md` says Scaleway "3 to 5
      workers", `status.md` says 3 to 6: reconcile.
- [ ] **Node removal** (#249) — lower the count in the tfvars, `task
      cluster-shrink-plan PROVIDER=… [-- --allow-below-ha]`, read the file, `task
      cluster-shrink PROVIDER=… PLAN=<file> [-- --allow-below-ha]` (below three
      control planes both commands take the flag; `cluster-verify` runs at its
      end), then the provider's own listing.
      *Recorded:* a worker, then a control plane (3 to 2), on Scaleway, OVH and
      Outscale, 2026-10-04, real cloud once by hand: verify green, the API listing
      exactly the machines left, failed `/readyz` for 40 to 76 s while the load
      balancer still served the departed control plane (12 of 350 on Scaleway, four
      attributed to the probe's own kubeconfig read; 13 of 374; 13 of 220). On
      Scaleway only, Longhorn's eviction (Longhorn 1.13.0: a sole replica moved before the
      drain, a two-replica volume refused at `--plan`; `status.md`, `upgrade.md`,
      commit a95482d) and CNPG (1.30.1, one control plane and two workers): a
      replica moved with its volume, and a primary failed over (2 of 368 inserts
      failed, none acknowledged lost), 2026-10-04. In the matrix and changelog
      only: a lowered count refused on two real Scaleway plans, applied nowhere.
      **Not recorded:** Longhorn and CNPG on OVH and Outscale (both ran on
      Scaleway only, 2026-10-04); a removal that stops half-way; Proxmox; a real
      refusal for a node not Ready, a short etcd, too little CPU or a plan that
      moved (mocked only).
- [ ] **Failure-domain verdict** — `cluster-verify` fails when all control planes
      share one zone (#38); a 2+1 split warns.
      *Recorded:* read on real accounts 2026-10-03: red on Outscale in one
      subregion; green with three control planes in three subregions there and in
      three OVH zones, matching the provider's own listing (commit 7190d59).
      `status.md` also says Scaleway over 2 zones is 2+1, green with a warning, but
      that commit says Scaleway was not deployed for the check: read the warning as
      mocked.
      **Not recorded:** a 3-zone Scaleway run (`SCW-mgmt-ha` is untested though
      the example now names three zones); OVH red on one zone (read from the
      config); Proxmox (mocked only). Outscale clusters built before #58 end red:
      an upgrade note.
- [ ] **A real roll with Flux and CNPG** — a roll on a cluster running both, ending
      on the roll's restore check (`<name>-primary` budget, Kustomizations resumed).
      *Recorded:* OVH only, 2026-10-03, real cloud once. `status.md` says only "with
      Flux and a CNPG cluster in place" (#64), on the same row as 13/13. Commit
      cedc343's message says how: a hand-installed lab (vendored Flux controllers,
      CNPG 1.23.1, local-path storage), a three-instance CNPG cluster, and
      `cluster-upgrade` ended 201 at its closing verify (it found `flux-system`);
      verify read 13/13 only after the lab was removed. Never proof of
      `deploy_flux`.
      **Not recorded:** that account in `status.md` (write it there); the failure
      branches, a real Ctrl+C and the task effects after a non-zero exit (mocked
      only); another cloud. CNPG 1.23.1 creates `<name>-primary` for a ONE-instance
      cluster on local Docker (scratch script, no receipt); no real cloud has seen
      one.
- [ ] **An interrupted bootstrap** — kill `cluster-up` in phase 2, run it again
      (`adopt-bootstrap`, #67).
      *Recorded:* Scaleway only, real cloud by hand. 2026-10-03: killed before the
      bootstrap call, a plain re-run resumed; `SIGKILL` right after it,
      `adopt-bootstrap` found three etcd members, and the stale lock needed
      `tofu force-unlock`. 2026-10-02: a state lost to PR #223's defect, adopted.
      **Not recorded:** OVH, Outscale.
- [ ] **State lock** — a second plan against the same state.
      *Recorded in `status.md`:* Scaleway refused it (2026-10-02). **Not there:**
      OVH's refusal (HTTP 412, undated anywhere) and Outscale's absent lock (§6,
      the changelog): move them.
- [ ] **`task restore-artifacts`** — kubeconfig and talosconfig out of a real
      bucket, and out of the replica with `FROM=replica`.
      *Recorded:* byte-identical from the primary and from a replica on another
      cloud's store, an OVH and a Scaleway cluster, 2026-10-05 (`status.md`; the
      failover row below). **Not recorded:** an Outscale cluster's own artifacts.
      The drill found four defects of the replica path (#57, Fixed).
- [ ] **Reader talosconfig** — `task talosconfig-new`, then `TALOSCONFIG=<it> task
      cluster-verify`.
      *Recorded:* OVH only, 2026-10-03, real cloud: verify green with it; `get
      machineconfig` refused (`admin-access.md`). That a reader cannot mint an
      admin config: local Docker, `task local-rbac`. **Not recorded:** Scaleway,
      Outscale; an expired config. The Taskfile's comment on `talosconfig-new` still
      says its cloud path never ran: amend it (§8).
- [ ] **Service probe** — `cluster-upgrade`'s workload behind a Service: failures,
      longest outage, BLIND samples apart; reported, never gated.
      *Recorded in `status.md`:* Scaleway 0 failed; Outscale 40 failed and 20 blind
      of 1490, longest 3 s (2026-10-03, real cloud once). **Not there:** OVH: the
      `upgrade-k8s` step (6 s) is in `upgrade.md`, the Flux/CNPG Talos step (3
      failed, 3 blind of 621, longest 1 s) in commit cedc343's message only; any
      threshold. Quote numbers, never "zero downtime".
- [ ] **A changed `admin_ip`** — `OA_SKIP_TUNNEL_GUARD=1
      TF_VAR_skip_health_check=true task infra-apply` (`admin-access.md`).
      *Recorded:* Scaleway only, 2026-10-04, real cloud once (changelog and
      `admin-access.md`, not `status.md`): the plain apply stops at the tunnel
      check, the bypass lands, SSH to the bastion works, verify green.
      **Not recorded:** OVH, Outscale.
- [ ] **Failover** (#57), per release — the drill in
      `infrastructure/opentofu/cluster/README.md`, "Cross-provider failover": A on
      one cloud with its replica on a second cloud's store, B on another; destroy A
      in the two commands, then, in a shell holding only B's and the replica
      store's keys, `task restore-artifacts PROVIDER=<a> FROM=replica OUT=<dir>`,
      `task restore-state PROVIDER=<b> ROLE=failover FROM=<A's env file>`, `task
      cluster-up PROVIDER=<b> ROLE=failover`. Pass when `cluster-verify` is green,
      the strict plan is empty, A's saved kubeconfig and talosconfig open B, and
      A's objects are unchanged afterwards.
      *Recorded:* one pair, OVH to Scaleway (B's replica on Outscale's store), 1+1,
      `prod`, 2026-10-05, real cloud once by hand: 13/13, `No changes`.
      **Not recorded:** any other pair; three control planes; Talos discovery with
      a live A; etcd contents (a rebuild, not a restore). The drill leaves its
      buckets on three accounts: name them in the notes (§1).
- [ ] **Image lane and retention** (#69) — after a verified climb, on each cloud:
      `task image-build PROVIDER=<p> LIST=1`, then `RETAIN=1`
      (`infrastructure/opentofu/talos-image/README.md`). Pass when the lane holds
      the cluster's version N and the one below it (plus what a tfvars names), the
      provider's own listing agrees (images and snapshots), a second `RETAIN=1`
      says `nothing to destroy`, and a worker created on the previous image joins
      and reads `MIXED` until `cluster-up` rolls it. `cluster-up` prunes only when
      a person answers and never under `APPROVE=auto`; `cluster-upgrade` never: a
      release run with `APPROVE=auto` keeps every image, and the notes say so.
      *Recorded:* Scaleway and Outscale, 2026-10-05, real cloud by hand: the legacy
      state migrated, two versions at once, the older-image worker, `PRUNE=1`,
      `RETAIN=1` (the hook was driven with a stub, not a real tofu prompt).
      **Not recorded:** OVH's lane; the hook under a real terminal; a legacy state
      holding the oldest version on a real backend; Proxmox.
- [ ] **Rollback of an upgrade: an OPEN GAP, nothing to run yet (#270).** The lane
      keeps the previous image, which only lets a NEW node boot the previous Talos.
      `converge-versions.sh` refuses a pin below what the fleet runs and no script
      or runbook wraps `talosctl rollback`, so taking upgraded nodes back from N to
      N-1 has no supported route and no recorded run. #270 names the proof to
      obtain (on a real cloud, a climb and a return with the upgrade probe on) and
      the decisions that are the owner's. Until it exists the notes say rollback is
      unproven, and this line stays a gap, not a step.
- [ ] **Node resolver** — `node_nameservers`: unset plans empty, the list applies
      without a reboot, nodes and pods resolve over DoT. Before any reboot with a
      list, `nc -zvw5 <ip> 853` from a pod: `cluster-verify` does not read the
      resolver and an unreachable list is found at the next reboot.
      *Recorded:* OVH only, 1+1, Talos 1.14.2, 2026-10-05, real cloud once (matrix,
      `OP-node-dns`). **Not recorded:** Outscale (no tracked record), Scaleway's
      apply (only its egress), three control planes, a cold first boot with the
      list set.
- [ ] **Lost Talos secrets** (#66) — `task infra-down-plan`, decline the destroy,
      then `task cluster-up`: refused before any plan; the replica put back, or
      recovery 2 of `cluster/README.md`, "Lost the Talos secrets".
      *Recorded:* Scaleway (2026-10-04 and 05) and OVH (2026-10-05), 1+1, real
      cloud by hand: the symptom, the refusals, both recoveries on Scaleway,
      recovery 2 on OVH. **Not recorded:** anything real at the merged head (the
      reworked untrack printing and the `backup-state.sh` and `cluster-roll`
      guards are mocked only); Outscale; three control planes; a replica on
      another provider; a cluster with no talosconfig and no replica copy (not
      recoverable here).

## 8. Release mechanics

Only once everything above is green. There is **no release workflow**
(`.github/workflows` holds `ci`, `clea`, `repo-settings`, `security`, and the manual,
dormant `real-cloud-regression`, which is not one): the tag and
the GitHub release are made by hand. Name the release commit by sha, not `HEAD`.

- [ ] the release commit is on `main` with green checks, `repo-settings` included,
      and `docs/deployment-test-matrix.md` carries what you ran, failures
      included: a row for each §7 row, or a line saying why not.
- [ ] the issues: close what its own observation made done, open what this shook
      out, including what you chose not to fix (`CLAUDE.md`: an audit is not a
      PR). Never write a closing keyword before an issue number in a commit, PR
      or the notes: GitHub reads prose, and an open issue was closed that way.
- [ ] `CHANGELOG.md`: `[0.2.0] — TBD` takes its date and anything merged since
      the text was written is folded into it (`[Unreleased]` stays empty), in the
      voice of 0.1.0: what it claims **and** what it does not, each with its rung,
      no hand-typed counts. Upgrade notes: unset pins inherit the new default and
      `cluster-up` is built to converge the fleet onto it (a minor climb through it
      has only run mocked; the measured climbs used `cluster-upgrade`);
      `tofu init -backend=false -upgrade` after pulling the provider pin; three
      control planes in one failure domain now end red (OVH on `nova`, Outscale
      built before #58).
- [ ] lines the runs above contradict, amended before the tag: the Taskfile's
      comment on `talosconfig-new` ("never been run"; OVH ran it 2026-10-03);
      `docs/status.md`'s OVH 1.14 row (13/13 was read after the lab was removed)
      and its Scaleway 2+1 sentence; `docs/first-cluster.md` ("3 to 5 workers"
      against 3 to 6, and its "What is not proven": OVH and Outscale read red,
      11/11, and the artifacts "never fetched back out of a real bucket" against
      the failover drill, which read both stores); `talos-image/README.md` ("Not
      measured (#69)": a node on the older image, which #269's message measured on
      Scaleway and Outscale); the French twins. `docs/status.md` and the matrix
      have no row for the image lane, #66's recoveries or the provider pin: add
      them or say why not (the first bullet of this section).
- [ ] the self-version anchors agree (no VERSION file or bump config exists):
      ```bash
      git grep -n '0\.1\.0' -- . ':!CHANGELOG.md'     # read every hit, FR twins too
      ```
      History stays; a sentence saying what the *current* release is or is not
      changes: the README (version section, roadmap — add the 0.2.0 row), the
      lede of `docs/status.md`, `first-cluster.md`, `capacity.md`,
      `admin-access.md`, `capi-bootstrap.md`, the matrix header, the `deploy_flux`
      text in `cluster/variables.tf`, code comments, `CONTRIBUTING.md`, the
      `release` and `cluster-upgrade` skills (`check-skill-parity.sh` skips with
      exit 0 when `../OpenAether-apps` is missing: a skip is not a pass).
- [ ] the tag cannot move: a repository admin runs
      `GITHUB_TOKEN="$(gh auth token)" ./scripts/dev/check-required-checks.sh dis-bzh OpenAether-infra`
      and it says `no bypass actors`. CI's token cannot read that list, so
      `repo-settings.yml` only warns about it. The `tags` ruleset blocks moving
      or deleting any tag, so **0.1.0's re-cut is not available**: §9 runs first,
      and the release skill's "Withdrawing a tag" needs an admin to relax it.
- [ ] §9's stranger clone ran on the release commit; then tag it. `git describe
      --tags` is clean and `git rev-parse 0.2.0^{commit}` is the sha §9 tested.
- [ ] a GitHub Release by hand, whose notes name the limits and end with an **Open
      items** list built from the open issue titles that day (`gh issue list
      --state open`): several known limits appear in no tracked file. Link the
      issues, not a backlog file. Pre-release or not is the owner's call.
- [ ] the examples agree on the apps ref (infra pins no `OpenAether-apps` tag):
      `grep -h git_ref infrastructure/opentofu/cluster/envs/*.example | sort -u`
      prints one line, `refs/heads/main`. The two `feint-*` examples carry none.

## 9. Before communicating

- [ ] clone the repo **as a stranger would** — no local state, no `.env.sh` — and
      do §1 and §2 one more time, from `git archive <release commit>` in a bare
      container, **before the tag**. It holds the licence, the changelog and no
      real `*.tfvars`, only the `.example` files.
- [ ] read `README.md` top to bottom as someone who has never seen it: the
      disclaimers (Proxmox never applied on hardware, the undeletable Outscale
      Net, the emulator proving nothing about a real deploy, no applications above
      Cilium) are why a knowledgeable reader will trust the rest. Add what §7 says
      is not recorded. Do not soften any of it. Read flattened text: sentences
      wrap across lines, and a first pass on raw lines matched nothing.
- [ ] decide what the announcement claims, and check each claim against the
      matrix and `docs/status.md`, with its rung: "real cloud, once by hand, on
      Scaleway, OVH and Outscale" holds; "validated on three providers" does not.
- [ ] `task evidence-check` exits 0, or the announcement names each provider whose
      newest row predates the pin, is older than its limit (45 days) or records a
      failure. It dates the table and reads no verdict but a ❌ or ⚠: a row that
      re-ran only the upgrade counts, and a typed row looks measured. The newest
      rows are dated 2026-10-03, so it is red from the 46th day unless a newer row
      at the pin is added.

---

## What this checklist will not tell you

Proxmox. `PMX-*` is code-complete, unit-tested, and has **never touched real
hardware** (#48) — no amount of cloud testing changes that, and the README says so
where it lists the providers. Keep it saying so. Nor does it tell you the failover
on a provider pair it did not run (#57), whether an upgrade can be rolled back
(#270), or anything above Cilium.
