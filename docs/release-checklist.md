# Release checklist — 0.1.0

English only: rewritten each release, and two copies would drift.

What to run before tagging 0.1.0 and telling anyone about it. Ordered by what
fails cheapest. **Stop at the first red** — every later step assumes the earlier
ones held.

Record the result next to each line as you go. A line with no result is a line
nobody ran, and that is the answer this checklist exists to make visible. The
ticks below carry the evidence 0.1.0 rests on; everything unticked is yours to
run and to write down.

0.1.0 is infrastructure only: one Talos cluster, Cilium as the whole platform,
Flux off (`deploy_flux = false`), no applications and no CAPI. Anything about
Flux, `OpenAether-apps` or a child cluster belongs to a later release and is not
a gate on this one. Three clouds are proven and no bare metal is — the
checklist says on what, and so must the announcement.

---

## 1. Clean-machine bootstrap (the first five minutes)

The point is a **fresh clone in a fresh directory**. Your working tree has files
a clone does not — that is exactly how the CNI defect survived.

```bash
cd $(mktemp -d)
git clone https://github.com/dis-bzh/OpenAether-infra
cd OpenAether-infra && git checkout <the 0.1.0 candidate>
./scripts/setup.sh
```

Your workstation is not a clean machine and a fresh clone on it proves little —
run this in a bare container instead, which is what a newcomer actually meets:

```bash
git archive --format=tar HEAD > /tmp/repo.tar
docker run --rm -v /tmp/repo.tar:/tmp/repo.tar:ro ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
  mkdir /oa && tar -xf /tmp/repo.tar -C /oa && cd /oa && ./scripts/setup.sh'
```

- [x] `setup.sh` completes and installs **helm** → 2026-08-20, `ubuntu:24.04`
      container from `git archive HEAD`: exit 0, helm v4.2.3, task 3.52.0,
      tofu v1.12.6.
- [x] **`nc`**: absent from the image, `✖ nc is missing` then `Installing
      netcat…`, and `/usr/bin/nc` present afterwards. This line used to read "it
      warns, and does not claim to install it" — the script installs it now, on
      purpose (`setup.sh:331`), and only warns where `apt-get` is absent. The
      line was describing a behaviour that had changed, which is the failure this
      checklist exists to catch.
- [x] every command the README quick start names exists → 18/18 against
      `task --list-all` plus aliases. Checked to fail too: an invented name and
      two just-deleted scripts all came back absent.
- [x] `task preflight` green — lint, render, validate, `tofu test` and the script
      harnesses. 358 offline assertions across 11 harnesses, every one
      mutation-tested. **It went DOWN from 364 and that is not silent**: the
      staging lane was deleted this release and 14 of those assertions tested a
      script that no longer exists.
- [ ] no bucket is orphaned by a rename in this release. `…-talos-staging` became
      `…-talos-import` (2026-08-20): the old one still holds every QCOW2 it was
      ever given, on every cloud built from. No script enumerates buckets — see
      `verify-provider-clean.py`'s own `UNCHECKED` list and `purge-orphans/`'s
      README — so check and empty each cloud's bucket by hand.

## 2. Local Docker — the credential-free rung

Still in the **fresh clone**, no `.env.sh`, no credentials in the shell.

```bash
task local-up
task local-status
task local-test
task local-down
```

Run 2026-08-20 on a cluster torn down first, so the Docker snapshot is a
baseline and not a picture of what was already there.

- [x] `local-up` renders `cilium-local.yaml` itself when the manifest is absent
      → removed, then rendered at 57374 bytes.
- [x] **Cilium is actually running** — 6/6 pods `1/1 Running`, one per node, on a
      cluster whose 6 nodes all reached Ready.
- [x] `local-status` prints etcd members → 3.
- [x] `local-test` reaches its green banner **and** its checks are fatal. Green
      first; then `kubectl -n kube-system delete daemonset cilium` and it went
      RED — `✗ Cilium pods running: 0/6 — the cluster has no working CNI`, exit
      201. The CNI check is fatal; two issues next to it still say they
      are only warnings.
- [x] `local-down` leaves no container, volume or network behind → 1/0/4 before,
      1/0/4 after, nothing added. The diff was itself checked against two
      deliberately different snapshots, because the first version of it compared
      a file that did not exist and reported zero for that reason.
- [x] a second `local-up`, with the manifest already rendered, does not re-render
      it → same mtime, same size, same **inode**.

## 3. Emulated cloud — no account, real provider binaries

The lane is pinned to Feint 0.13.0, running against the same Scaleway provider
version the clusters run — except the lanes that destroy (the fixture and
`feint-apply-root`), capped below 2.83.0 (#179).

```bash
task feint-up
task feint-test                        # both providers, plan + CRUD
task feint-record PROVIDER=scaleway
task feint-record PROVIDER=outscale
task feint-plan PROVIDER=scaleway FEINT_ENDPOINT=https://api.scaleway.com   # must REFUSE
task feint-down
```

- [x] both providers green on plan and on the apply/destroy cycle, each with an
      empty re-plan and a destroy confirmed against the API → 2026-08-20, feint
      0.9.0: Scaleway 8 added / empty re-plan / 8 destroyed, Outscale 27 / empty
      / 27, both confirmed against the API, no credentials in the shell.
- [x] the ranking is **empty on both providers** — `every operation the client
      called is served by a pack`. It was three under 0.9.0 (`lb ips` and
      `vpc-gw ips` on Scaleway, `CreateLoadBalancer` on Outscale) and four before
      that; 0.10.0 closed the last of them, and the served-and-exercised count rose
      from 19 to 50 on Scaleway and 23 to 27 on Outscale because the plan now
      reaches the load balancers instead of stopping at them. An empty ranking is
      not the alarm this line watches for — a NEW entry is, and there is none.
      Update the line, not the count, when one appears.
- [x] the guard refuses a non-loopback endpoint — check it both ways, as a Task
      variable and as an environment variable. A Task variable is not an
      environment variable, and this test once passed without testing anything.
      → 2026-08-20, both refused with exit 201 and the same sentence: `endpoint
      https://api.scaleway.com is not local; this lane drives an emulator, never a
      real cloud`. **And the normal case was checked too**: the loopback endpoint
      is accepted, exit 0. A guard written for the pathological case has to be run
      against the ordinary one before it ships.

## 4. Cloud — Scaleway first, it is the reference

Use a **throwaway project**, not one holding anything real.

```bash
source .env.sh
cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars{.example,}
$EDITOR infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/your-key
```

`preflight-quotas` has no Scaleway backend — it takes `ovh` or `outscale` only.
`task cluster-up` refuses before spending if the env file, the SSH key, an S3
credential pair or the passphrase is missing.

- [x] **deploy from an empty account** → 2026-08-19: 8 min 50 for 72 resources.
- [x] **`task cluster-verify`** → 11/11.
- [x] **idempotency is three assertions, not one**: an empty plan, the *same*
      nodes (name and `creationTimestamp`), and a kubeconfig that still reaches
      the apiserver → 3/3. Two of the three can pass while the cluster was
      silently rebuilt, which is why one of them is not enough.
- [x] **upgrades, end to end** — Kubernetes v1.36.2 → v1.36.3, then Talos v1.13.7
      → v1.13.8 in place, confirmed on 6/6 nodes by each node's own Talos API
      (`stage=running`, fallback dropped) rather than by the tool that performed
      the upgrade. Longest apiserver outage **5 s**, 16 failed probes out of 575.
- [x] **the replica really is elsewhere** — an encrypted tfstate in a `-backup`
      store at Outscale while the cluster ran on Scaleway, opened with THAT
      cloud's keys. S3 credentials are namespaced by the cloud that holds the
      bucket, not by the cluster.
- [ ] `task etcd-snapshot PROVIDER=scaleway` writes to both buckets. Pass `KEY=`
      if your key is not `~/.ssh/id_ed25519`. **Not run** — the reference cluster
      was destroyed before this line was reached.
- [x] **a second deploy → idempotency → upgrade → idempotency cycle**, 2026-08-20:
      `cluster-up`, `cluster-up`, `cluster-upgrade`, `cluster-up`, all four green.
      Both re-runs printed `No changes.` on all three roots and applied nothing —
      the evidence is the command itself, not a script. **Idempotency AFTER an
      upgrade had never been checked before**; it holds because `cluster-upgrade`
      writes the new pin back into the tfvars. Talos v1.13.8 → v1.13.9 on 6/6
      nodes, `cluster-verify` 11/11, longest apiserver outage **2 s** (13 fails in
      577) — see `upgrade.md` for why that does not establish the leader-last fix.
- [x] **teardown**, two commands and then the provider's own answer:
      ```bash
      task cluster-down PROVIDER=scaleway
      task cluster-down PROVIDER=scaleway PLAN=destroy-management-scaleway.tfplan APPROVE=auto
      python3 scripts/ops/purge-orphans/scaleway.py
      ```
      Record the counts. The 2026-08-19 deploy started from an empty account, so
      what preceded it left nothing — that is a fact about a previous run, not a
      result for yours.
      → 2026-08-20: `Nothing to purge — the project is clean.`

### Worth the extra spend, in priority order

The matrix (`docs/deployment-test-matrix.md` §C) ranks these as the highest-value
untested cases. Take as many as the budget allows, top down:

- [ ] **`SCW-work-ha`** — the `workload` role on real cloud; only `management`
      has ever been exercised. **Skipped for 0.1.0 by decision** — the checklist
      ranks these as worth the spend, not as gates, and none is in the announced
      scope.
- [ ] **`SCW-storage`** — on the **workload** role. "Never applied anywhere" was
      wrong: the reference management cluster carries `worker_storage`, and its
      three block volumes and UserVolumeConfig patches applied on 2026-08-19 and
      again on 2026-08-20. What has never been done is READING BACK that they are
      formatted LUKS2 and mounted at `/var/mnt/<name>` — `cluster-verify` asks
      about no volume at all.
- [ ] **`task cluster-roll`** — re-run it since the Talos version moved.
- [ ] **bastion hardening, read back rather than assumed** —
      `scripts/ops/bastion-harden-check.sh <bastion_ip> <bastion_user> <ssh_key>
      [node_private_ip]` checks SSH tunnel reachability, root login refusal,
      `sshd` hardening (`PermitRootLogin no`, `PasswordAuthentication no`,
      `AllowGroups bastion-admins`), the nftables egress DROP/ALLOW split, that
      only `:22` listens externally, and `bastion-admins` membership. Applies to
      any provider's bastion — never run against the reference cluster.

## 5. Cloud — OVH

```bash
task preflight-quotas PROVIDER=ovh
task cluster-up ROLE=management PROVIDER=ovh
```

- [x] **the same five pillars, the same day** — deploy, `cluster-verify` 11/11,
      idempotency 3/3, and both upgrades to the same versions as Scaleway,
      2026-08-19.
- [x] **the interruption is a number** → longest outage **7 s**, 9-10 failed
      probes out of ~540. Worse than the 1 s this provider once recorded; quote
      this one.
- [ ] teardown **twice**: an Octavia LB orphaned by one teardown was silently
      reused by the next deploy. `verify-provider-clean.py` covers it now — this
      is the run that proves the check, not the fix. **Not run twice**; the
      cluster was destroyed once and the account is empty, which is a weaker
      statement than this line asks for.
- [x] `python3 scripts/ops/purge-orphans/ovh.py` clean on the first pass →
      2026-08-20: `Nothing to purge — the project is clean.`
- [ ] **`OVH-vip`** if budget allows — `k8s_lb_mode=vip` has never been applied
      on OVH, and Neutron's `allowed_address_pairs` is a different mechanism from
      Scaleway's anti-spoofing

## 6. Cloud — Outscale

```bash
task preflight-quotas PROVIDER=outscale
task cluster-up ROLE=management PROVIDER=outscale
```

Deploy into a **fresh Net**. What blocked this provider was a timeout inside
Outscale's own LBU service: it stops waiting after 10 s while the VM the load
balancer needs takes about 10.7, so the workflow fails, the internal resources
are created anyway and the LBU stays in `provisioning` for ever. Support request
**399530** carried that diagnosis and is **closed**; the instruction that came
with it is do not create another LBU in that Net, use a new one.

Do not tick anything here from an earlier cycle — the 2026-08-13 run does not
count, its Talos upgrade reverted on the next reboot.

- [x] **the same five pillars as Scaleway and OVH, measured the same way** →
      2026-08-20: deploy — 51 resources, then 17 — `cluster-verify` 11/11,
      idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos v1.13.7 → v1.13.8
      confirmed on 6/6 nodes by each node's own Talos API (`stage=running`,
      fallback dropped). The new load balancer reached `active` with 3 backends.
- [x] **the interruption is a number** → longest outage **8 s**, the worst of the
      three clouds and worse than the 1 s this provider once recorded. Quote this
      one.
- [ ] teardown, then `python3 scripts/ops/purge-orphans/outscale.py` clean —
      **NOT clean, and this line does not get ticked.** 2026-08-20: the cluster
      was destroyed, and the purge found 6 resources of the pre-fix Net and could
      delete none of them. The account's own words, in order, are the whole
      story: `A load balancer is present on Net` → the internet service cannot be
      unlinked → `The Subnet is in use. It has NICs` → `The Net is in use. It has
      Subnet(s)`. The chain hangs off an LBU stuck in `provisioning` that no
      `Read` returns and no `Delete` accepts. **This run is also what exposed a
      defect in the purge scripts themselves**: six failed deletions were printed
      and not counted, and the run still ended "purge complete" with exit 0 — so
      the exit code every caller reads said clean. Fixed the same day in all
      three scripts, with the scenario added to `test-purge-orphans.sh`.

**Two things stay true here and belong in the announcement.** One Net created
before the fix still refuses deletion, on a dependency no read returns — only
Outscale can clear it, and a second support request is open for it; it is not
your leak, and it must not hide one. And this object store does not honour
conditional writes: measured with the same client that got a refusal from
Scaleway and OVH, it accepts the second one — so `use_lockfile` is on for those
two and deliberately **off** here, where it would claim a state lock and hold
nothing. Nothing stops two concurrent runs against an Outscale cluster's state.

## 7. Upgrades — Kubernetes and Talos, on a cluster that has to stay up

§§1-6 prove a cluster can be built. They prove nothing about keeping one, which
is the half every 1.x tag shipped unverified.

The procedure itself is [`upgrade.md`](upgrade.md) — it is not release-specific
and does not belong here twice. What a *release* adds to it:

- [x] the one-second probe up throughout, and the claim made as a number: the
      LONGEST consecutive run of failed `/readyz` samples, not the total.
      5 s on Scaleway, 7 s on OVH, 8 s on Outscale — every one of them worse than
      this project's own records (3 s, 1 s and 1 s), and all three are what the
      announcement quotes. "No interruption" is not measurable.
      A fix shipped 2026-08-20 — the roll takes the etcd leader LAST and hands
      leadership over with `talosctl etcd forfeit-leadership` instead of letting
      its disappearance force an election — but whether that is what was costing
      the seconds has not been measured. Do not present it as the explanation.
- [x] run on **three clouds**, not only the reference one: the known first-apply
      failure (upstream #352) reproduces on OVH and not on Scaleway.
- [x] every node upgraded **in place**, none replaced, every one back under its
      own name — and the running SCHEMATIC compared, not just the version tag.
      2026-08-20 Scaleway: 6/6 confirmed by each node's own Talos API
      (`stage=running`, META fallback dropped) and `cluster-verify` answered
      `✓ the fleet runs the pinned schematic (613e1592b2da…)` — an assertion, not
      the warning it degrades to when no tunnel is open. The control planes rolled
      in the designed order for the first time: the two followers, then
      `etcd forfeit-leadership`, then the former leader.
- [x] `task infra-plan ... STRICT=1` exits 0 afterwards → `plan empty after the
      upgrade`, and a full `task cluster-up` after it printed `No changes.` on all
      three roots.
- [x] whatever it shook out is filed as an issue before the tag, including what you
      chose not to fix → this cycle added: the purge scripts' uncounted deletions
      (fixed), `ovh.py`'s missing refused-call counter (not fixed), encrypted
      worker volumes applied and never read back, no way to ask what is in the
      state, two harnesses that went red then green unchanged, the bucket this
      release's own rename orphaned, and what deleting the staging lane stopped
      covering.

`scripts/dev/cluster-upgrade.sh` does all of the above unattended and does not
retry the failing apply, on purpose.

## 8. Release mechanics

Only once everything above is green.

- [x] `docs/deployment-test-matrix.md` updated with what you actually ran —
      including the ones that failed → `L-ha` re-run, the new `SCW-mgmt-ha-2az`
      row that is what 0.1.0 rests on, and `SCW-storage` corrected: it said
      "never applied anywhere", which was wrong.
- [x] the issues — close what is now done, open what this shook out →
      idempotency-after-upgrade and the staging-lane decision removed as done;
      seven entries added.
- [x] `CHANGELOG.md` names what 0.1.0 claims **and** what it does not → four
      Known limits carry the honest half, including the two checklist lines below
      that are NOT met.
- [ ] a GitHub Release, with notes that name the open items
- [ ] `git describe --tags` clean
- [x] the `envs/*.tfvars.example` carry `git_ref = "refs/heads/main"` — infra
      pins no `OpenAether-apps` tag, so there is no ordering constraint between
      the two repositories and no matching-version rule to honour → 12/12 files.

## 9. Before communicating

- [ ] clone the repo **as a stranger would** — no local state, no `.env.sh` —
      and do §1 and §2 one more time
- [x] read `README.md` top to bottom as someone who has never seen it: the
      disclaimers (Proxmox never applied on hardware, the undeletable Outscale
      Net, the emulator proving nothing about a real deploy, no applications
      above Cilium) are the reason a knowledgeable reader will trust the rest.
      Do not soften them. → all four present. Checked on flattened text, because
      the first pass matched nothing at all: the sentences wrap across lines. The
      control is that the phrase §9 forbids — "validated on three providers" — is
      absent.
- [ ] decide what the announcement claims, and check each claim against the
      matrix. "Validated on three clouds" holds — Scaleway, OVH and Outscale.
      "Validated on three providers" does not: Proxmox has never touched real
      hardware, and nothing above Cilium is deployed at all.

---

## What this checklist will not tell you

Proxmox. `PMX-*` is code-complete, unit-tested, and has **never touched real
hardware** — no amount of cloud testing changes that, and the README says so
where it lists the providers. Keep it saying so.
