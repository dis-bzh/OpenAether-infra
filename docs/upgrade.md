# Upgrading a live cluster — Kubernetes and Talos

🇫🇷 [Version française](upgrade.fr.md)

> Building a cluster and keeping one are different claims. This is the second.
> Measured by hand on **Scaleway, OVH and Outscale** — the first two on
> 2026-08-19, Outscale on 2026-08-20 — HA topologies, every node upgraded **in
> place** rather than replaced and each node's own Talos API asked what it runs.
> On 2026-10-03 all three went on to Talos 1.14.2 and Kubernetes 1.37.1 through
> `task cluster-upgrade` (`docs/status.md` has the figures). Earlier runs on Outscale
> and on OVH reverted on the next reboot, and the open issues say why.
>
> The scripted version of this same procedure is `task cluster-upgrade`
> ([`scripts/dev/cluster-upgrade.sh`](../scripts/dev/cluster-upgrade.sh)). It is
> run by hand, by someone watching: no CI lane deploys anything on its own. This page is
> what was actually run.

## The two facts everything here follows from

**A node's boot image is only the medium it was installed from.** After
`talosctl upgrade` the instance still reports the old image id, by design. Node
resources therefore carry `ignore_changes` on it — see
[`provider-contract.md` § Node image drift](../infrastructure/opentofu/modules/providers/provider-contract.md).
Without that, bumping `talos_version` would make a routine apply replace every
control plane at once and etcd would lose quorum.

**Talos supports a window of Kubernetes releases, not all of them.**
`cluster/versions-guard.tf` refuses an unsupported pair at plan time, and refuses
a Talos minor nobody has entered in its map rather than passing it silently. The
starting pair, the ending pair *and* the intermediate state all have to sit
inside the window, because the two move one at a time.

## Measure the interruption

Start this before anything, against the endpoint in the kubeconfig — never a
tunnel to one node, because that node is the one you are about to take away.

```bash
while :; do kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 \
  && echo ok || echo FAIL; sleep 1; done | tee probe.log
```

A clean run loses a few seconds while an apiserver restarts. Both upgrades end
to end: **5 s** on Scaleway (16 failed samples in 575) and **7 s** on OVH (9-10
in ~540) on 2026-08-19, then **8 s** on Outscale on 2026-08-20. All three are
worse than the best this project ever recorded (3 s, 1 s and 1 s) — quote these,
not those.

The cause of that regression is not established. The roll now takes the etcd
leader last and hands leadership over with `talosctl etcd forfeit-leadership`
rather than letting its disappearance force an election (2026-08-20).

The first run under that order, Scaleway 2026-08-20, measured **2 s** — 13 failed
samples in 577. **It does not establish the fix**: that run moved Talos only
(v1.13.8 → v1.13.9, Kubernetes unchanged at v1.36.3), while the 5 s run also
moved Kubernetes, which restarts an apiserver per control plane on its own. Two
different workloads, so the two numbers do not compare. What the timestamps do
show is a changed *shape*: of the 13 failures only two adjacent pairs were
consecutive, and the rest were isolated 5-6 s apart — a lone failure means other
backends still served, so there were two real 2 s windows rather than one long
one. The experiment that would settle it is the same Talos-only upgrade with the
leader-last order disabled: one run, one variable.

**Those numbers are the control plane, not a service.** `task cluster-upgrade`
also runs a second probe for the whole roll: a 2-replica workload behind a
Service (with a PDB when two nodes can take it), polled through the apiserver
proxy, reported as FAIL count and longest outage, then deleted. Samples taken
while the apiserver is down are counted apart as BLIND. It is reported, not
gated. Real numbers, 2026-10-03: 0 failed on Scaleway, 40 failed and 20 blind of
1490 on Outscale (`docs/status.md`). How it works:
[`cluster-upgrade.sh` § The service probe](../scripts/dev/cluster-upgrade.sh).

## From 0.2.x to 0.3.0 (the platform, not Talos or Kubernetes)

0.3.0 moves neither Talos (1.14.2) nor Kubernetes (1.37.1). What it changes on a running cluster, in this order:

1. **Read the plan** (`task cluster-up` stops at it). With unchanged tfvars the one change you should see is the Scaleway system volumes going from 20 to 50 GB
   **in place** (`scw_root_volume_size_gb`, default 50; no node is replaced) and a Talos machine config change. Pin `scw_root_volume_size_gb = 20` only to keep the old size,
   which does not hold the application stack. On Outscale the root of a running VM is not resized in place: set `outscale_root_volume_size_gb` (and raise the root IOPS,
   infra #376) and replace the workers one at a time with `task cluster-roll`. OVH and Proxmox: the flavour's disk and `root_disk_gb` (50).
2. **Reboot the Scaleway workers one at a time, drained**, so Talos grows EPHEMERAL. Use `task cluster-roll`; a hand-typed `talosctl reboot` does not drain, and
   a worker carrying a CNPG instance must never be rebooted undrained (see below).
3. **Grow the disks before the application hops.** The 0.3.0 images are larger, and a 20 GB node reached DiskPressure after hours of hops (lab 15c).
4. **Then move the apps side** one minor at a time where it says so: Longhorn 1.9 -> 1.10 -> 1.11 -> 1.12 (with the CRD conversion pre-step), cert-manager, the CNPG operator,
   Kyverno, and the Loki chart procedure are in OpenAether-apps `docs/patching.md`. Take a CNPG Backup and a Longhorn backup first; Zitadel and Grafana migrations are forward-only.
5. **Hardening options are off by default.** Turn them on one at a time (`docs/hardening.md`, `docs/security-architecture.md`); each plan is read before it is applied.
   Options that change the Talos machine config (node filtering, baseline, log forwarding) are applied by the plan; if a change needs a reboot, do it with `task cluster-roll`.

Not rehearsed in place: the Loki 6.55 -> 18 step, Grafana, Alloy, the Gateway API CRDs, Flux on the children. A fresh install of every version ran on the three clouds.

## Kubernetes first

It reboots nothing, so it isolates the control-plane roll from the node roll.

```bash
# edit kubernetes_version in envs/<role>-<provider>.tfvars, then
task infra-plan  ROLE=management PROVIDER=<p> OUT=tfplan
task infra-apply ROLE=management PROVIDER=<p> PLAN=tfplan
```

Talos reconciles the static pods and the kubelets; wait for every node to report
the new version before moving on. This bypasses `talosctl upgrade-k8s` on purpose.
Measured on a real OVH cluster (2026-10-03, 1.36.3 to 1.37.1), `upgrade-k8s` left the
apiserver unreachable for up to 10 s and the probe service for 6 s; this step measured
2 s on Scaleway and 9 s on Outscale on the same move. It is no gentler, it needs a
`talosctl` that matches the fleet (a 1.13 client refuses 1.36 to 1.37), and the pin
still has to be bumped and applied afterwards.

## Then Talos, in place

Bump `talos_version`, build the image for the new version (the node resources
ignore the image, but the *data source* still has to resolve), apply, then roll.

```bash
# edit talos_version in the tfvars FIRST, then
task image-build PROVIDER=<p> VERSION=<new> ENSURE=1
task infra-plan  ROLE=management PROVIDER=<p> OUT=tfplan
task infra-apply ROLE=management PROVIDER=<p> PLAN=tfplan
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<key> -- --cp-only --upgrade
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<key> -- --workers-only --upgrade
```

The pin moves before the build (`talos-image.sh` compares a pinned `image_id` only
with the image of the version it builds). Each version has its own image state, so a
build never replaces another image; if it fails, re-run, or set `talos_version` back to
the old version to plan the cluster again. Once the climb is verified, `RETAIN=1` keeps the cluster's
version and the one below it and destroys the other images (`cluster-up` runs it, `cluster-upgrade` does not);
its rules, `LIST=1` and `PRUNE=1` are in
[`talos-image/README.md`](../infrastructure/opentofu/talos-image/README.md). The
2026-10-03 climbs ran in that order on all three clouds, on the single-image lane
this replaces.

`talos_version` is the node's Talos, not the machine-config contract: the module renders under a
capped one (`config_contract` in `modules/talos/main.tf`, which says why). A bump to 1.14 changes
the installer image in the config; offline renders under provider 0.12.0 show nothing else, but
no `cluster-upgrade` has run under it yet.

**After pulling a provider pin**, the committed `.terraform.lock.hcl` of `cluster/` and `talos-image/` already
names the version (docs/supply-chain.md): a plain `tofu init` in `infrastructure/opentofu/cluster` is enough, and
an init that says the lock does not match the constraint means the PR forgot `task lock-providers`. That task
moves every provider within its constraint: read the next plan. A clone that still has an older local lock
(from before it was committed) is fixed by deleting that file and running `tofu init`.

**On Outscale the image build dominates the whole upgrade.** The image is
registered from a snapshot imported through a provider-side queue: 8 min on
2026-08-18, over 60 min on 2026-07-25. It blocks before a single node is touched,
and no node ever boots from it — the roll installs from the Image Factory
(`installer_image`). It is required only because `image_id` is unpinned, so the
data source resolves the OMI by a name carrying the version. `ReadSnapshots`
tells you where the import really is; the apply's "Still creating..." does not.


`--upgrade` calls `talosctl upgrade`, which keeps the node's disk, identity and
etcd membership, drains it itself, and refuses a control-plane upgrade that would
cost etcd its quorum. One node at a time, health-gated between each, and
re-runnable: a node already on the target version is skipped. Control planes
first — a worker needs a healthy control plane to drain against.

### The cluster has to be able to lose a node

Check this before rolling, not after a drain has waited out its timeout:

```bash
kubectl describe nodes -l '!node-role.kubernetes.io/control-plane' | grep -E '^Name:|^  cpu '
```

Requests must leave one node's worth of room. Measured 2026-08-15: Scaleway's
three `DEV1-L` workers sat at 72/47/27% and every drain went through; OVH's
three `b3-8` at 78/99/100% and the first drain waited out its full 900s with no
eviction error to show for it — the evicted pods simply had nowhere to go, so
the budgets they belong to never recovered. Add a worker or a bigger flavour
before rolling; that is a prerequisite, not a symptom.

### What actually blocks a drain, and the two gates that clear it

**A CNPG primary is unevictable while it is primary.** The operator publishes a
`<cluster>-primary` budget at `disruptionsAllowed=0 / currentHealthy=1 /
expectedPods=1`, and `nodeMaintenanceWindow` does not relax it — measured on
Scaleway 2026-08-15: with the window on, CNPG deletes the *replica* budget and
keeps the primary one. That is the whole 900s drain.

So the roll sets **`spec.enablePDB: false`** on every CNPG cluster while it
rolls, and back to `true` on exit. That removes both budgets, primary included;
the operator's own webhook recommends it over the maintenance window. The
primary is then evicted like any other pod and CNPG fails over to a replica —
an unplanned failover, which is what the node reboot was going to cause seconds
later anyway. The maintenance window stays set alongside it, because that is
what tells the operator to reuse the PVC instead of reprovisioning an instance
that node-local storage could not move. On exit the roll checks the restore: it
waits about two minutes (3.5 measured with the apiserver down) for each cluster's
`<cluster>-primary` budget and every owning Kustomization, then exits non-zero
naming what is left. Ctrl+C ends that wait ("restore NOT verified", exit 130); a
roll stopped between nodes says so instead of "complete". The verdict comes after
the last node is replaced, so do not re-run replacement mode to clear it: it
replaces every node again. Fix what is named by hand and run
`scripts/ops/backup-state.sh`, which `task cluster-roll` skips after a non-zero
exit. `task cluster-upgrade` stops at the first roll that
ends this way: if it is the control-plane roll, the workers are not rolled.

**Everything else quorum-shaped blocks it too.** Three runs on 2026-08-14 stopped
on three different pods — CNPG replicas, `kube-state-metrics`, then `openbao-1`
on a raft budget wanting 2 of 3 — with no CNPG primary involved in the last one.
The shape was always the same: the roll arrived at the next node while the
previous one's workloads were still rejoining. So before cordoning, it waits
until **every budget covering a pod on that node reports
`disruptionsAllowed >= 1`**.

It waits only on budgets that can still recover (`currentHealthy < expectedPods`).
Some are zero by construction — `<cluster>-primary`, Longhorn's
`instance-manager-*`, a single-replica `kube-state-metrics` — and waiting on
those is waiting forever.

If a drain still times out, the roll **refuses** and names the pods rather than
rebooting the node under them. Do not force past it: the version this replaced
warned and rebooted anyway, which left `zitadel-db` stuck mid-switchover and
`grafana-db` with no active instance. Re-run the same command once the pod is
healthy — nodes already on the target version are skipped.

```bash
# what is refusing, on the node the roll named
kubectl get pdb -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
ALLOWED:.status.disruptionsAllowed,HEALTHY:.status.currentHealthy,EXPECTED:.status.expectedPods

# CNPG state — the qualified name is required: on a cluster carrying CAPI,
# `kubectl get cluster` means clusters.cluster.x-k8s.io, not this one.
kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,\
NAME:.metadata.name,PRIMARY:.status.currentPrimary,READY:.status.readyInstances

# and, for one database in detail (plugin installed by `task setup`)
kubectl cnpg status <cluster> -n <ns>
```

### Never reboot a node that still hosts a Longhorn RWX volume

A worker that hosts both the share-manager pod of an RWX volume and a pod mounting it did not finish a graceful `talosctl reboot` in lab 12
(Scaleway, Longhorn 1.12.1, Talos 1.14, apps #124): Talos stayed in `unmountPodMounts` (`nfs: server ... not responding`) for more than
12 minutes, twice, and only a provider hard reset ended it. So **never reboot, shut down or `talosctl upgrade` such a node undrained**.
`cordon_drain` (used by `cluster-roll`, `cluster-upgrade`, `cluster-shrink`) now waits, after the drain, until no share-manager pod and
no pod mounting a Longhorn RWX claim is left on the node (`RWX_CLEAR_TIMEOUT`, 300 s by default); when something stays it uncordons the
node, lists the pods and refuses to go on. By hand: drain, then
`kubectl -n longhorn-system get pods -o wide | grep share-manager` must show another node. Offline test: `scripts/dev/test-rwx-drain-gate.sh`.
Not yet proven on a cluster: that a drained node then reboots in about 1.5 minutes (the apps repo also shortens the RWX NFS timeouts).

### Never reboot a worker undrained when it carries a CNPG instance

A node reboot WITHOUT a drain leaves the CNPG instance pods of that node in phase `Succeeded` (the kubelet's graceful shutdown stops postgres with exit 0) and
CNPG 1.23.1 never restarts them: both databases down, Zitadel and the Gateway answer 503 (lab 11, 30+ minutes; the traps page of the OpenAether-apps repository). `cluster-roll`,
`cluster-upgrade` and `cluster-shrink` drain first, so they are safe; a hand-typed `talosctl reboot` or `shutdown` is not. After an undrained reboot:
`kubectl get pods -A --field-selector=status.phase==Succeeded`, then delete the CNPG pods listed (never their PVC). Newer CNPG operators (the apps pin moved past 1.23) are
not known to share the defect; the habit costs nothing. The roll tooling does not guard a reboot it does not run (infra #358): this page is the guard.

### A database left "Failing over" after the roll

The roll finishes, the API never blinked, and minutes later a CNPG cluster sits
at `Failing over` or `Switchover in progress` and does not move. Seen twice on
2026-08-15, both times the same shape: the demoted primary waits for the
switchover to finish while the *target* replica waits for WAL that only a
running primary would produce. A third instance can be perfectly healthy
throughout.

Restarting the operator does nothing. Deleting the **target's** pod resolves it
in about a minute — it restarts, finishes its recovery, and the cluster elects:

```bash
kubectl get clusters.postgresql.cnpg.io -n <ns> <cluster> \
  -o jsonpath='{.status.currentPrimary} -> {.status.targetPrimary}{"\n"}'
kubectl delete pod <targetPrimary> -n <ns>
```

`kubectl cnpg promote` is not the answer here: with the plugin this repository
pins, it exits 0, prints "will be promoted" and leaves `targetPrimary`
untouched. Open as an issue.

The first apply after a `talos_version` bump used to fail once on OVH and
Outscale with "Provider produced inconsistent final plan" (upstream
`siderolabs/terraform-provider-talos` #352, fixed in 0.12.0, which is pinned).
The module replaces each machine-config apply on a version change
(`replace_triggered_by`), so the bump goes through in one apply: the 2026-10-03
climbs ran through `cluster-upgrade`, which has no retry, on all three clouds. The
workaround stays until a run without it passes (#83).

## What to check, beyond "it came back"

After each node, and again at the end:

- **its name is unchanged** — a `talos-xxxxx` entry means the hostname did not
  hold, and the next reboot will orphan another node object
- the node count has not grown, and etcd still reports every member
- the probe's FAIL count has barely moved
- **`tofu plan` is empty.** If it wants to replace nodes, the boot image and the
  running version have disagreed — that plan would take the cluster down. Stop
  and read § Node image drift before running anything else.

```bash
task infra-plan ROLE=management PROVIDER=<p> STRICT=1   # exit 2 = not converged
```

## Iterating on the roll itself, without rebuilding the cluster

Fixing this script used to mean redeploying an 85-minute cluster in order to
exercise its last twenty minutes. It does not have to: both moves below were
used on a live cluster on 2026-08-15, and
[`scripts/dev/roll-lab.sh`](../scripts/dev/roll-lab.sh) is them, made repeatable.
It refuses to run unless the tfvars name a disposable environment **and** the
kubeconfig reaches the cluster that state describes, and it prints what it is
about to change before changing it.

```bash
scripts/dev/roll-lab.sh status <provider> --offset <n>   # what a resume would skip
scripts/dev/roll-lab.sh resume <provider> --offset <n>   # re-run the roll, minutes not hours
scripts/dev/roll-lab.sh inject-cnpg-deadlock <provider> --offset <n>
scripts/dev/roll-lab.sh cleanup <provider> --offset <n>  # uncordon what was left behind
```

**Resume.** A node already on the target version is skipped, so a fixed roll can
be retried in place: `resume` runs `rolling-replace.sh <p> --upgrade
--workers-only --yes` after checking the preconditions the roll itself discovers
too late — a live cluster, and one Talos tunnel per node.

**Inject.** The deadlock in § A database left "Failing over" cost four cloud
rolls to characterise and reproduces in about two minutes: cordon the node
holding a cluster's primary and delete that pod. Its `local-path-retain` PVC
pins it to the cordoned node, so it cannot come back, and CNPG stalls. The
command asserts with the roll's **own** detector and exits non-zero if the
deadlock did not appear — it cannot quietly report a success. `cleanup` undoes
it; CNPG heals once the pod can be scheduled again.

Cheaper still, and where a gate fix belongs first:
[`scripts/dev/test-rolling-replace.sh`](../scripts/dev/test-rolling-replace.sh)
exercises the same logic against a stub kubectl in seconds, with no cluster.

## Going back

An upgrade is not undone by running the upgrade backwards: `converge-versions.sh`
refuses a pin below what the fleet runs ("that is a DOWNGRADE"), and so does
`cluster-upgrade`. What exists is Talos's own A/B switch, and an etcd restore.
Both were run on Scaleway on 2026-10-12 with the `0.1.0` and `0.2.0` tags (Talos
1.13.9 and Kubernetes 1.36.3 to 1.14.2 and 1.37.1, 3 control planes + 2 workers,
the 1 Hz probe of the section above running). One provider, by hand: the timings
are Scaleway's, the mechanism is Talos's. The rest is what was **not** measured.

### A worker: `talosctl rollback`

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
talosctl -n <node-ip> rollback          # boots the previous partition
kubectl uncordon <node>                 # when the node is Ready again
```

Back on 1.13.9 and Ready in 21 s and 39 s. It also worked with Kubernetes already at
1.37.1: the worker came up with kubelet v1.37.1 and ran Cilium and the prober.
`cluster-verify` stays red, `the fleet is MIXED on Talos`, until the node is rolled
forward again; a second `rollback` on the same node switches back to the newer
partition, and `task cluster-upgrade` rolls it forward the usual way. It is valid only
while the node's previous partition still holds the version you want: a further
upgrade overwrites it.

### A control plane: not across a minor that bumps etcd

⚠️ **`talosctl rollback` on a control plane from Talos 1.14 to 1.13 breaks etcd.**
The node boots, joins as Ready, and its etcd crash-loops:

```
discovery failed ... error: version "3.7.0" is not supported
```

Talos 1.14.2 ships etcd 3.7 and the upgrade writes its storage version (3.7.0); Talos
1.13.9 ships etcd 3.6.12, which refuses that data. `etcd members` still lists the
member (membership is not health), so read `talosctl service etcd` on the node. With
two of three control planes rolled back the quorum was lost and the API was down for
about 11 minutes, until a second `rollback` on those two brought them forward again.
Do not roll back a second control plane to see whether the first one is fine.

### A control plane: restore a snapshot taken before the upgrade

The way back for the control planes is a restore, and it needs a snapshot that
**predates the first control plane of the upgrade**. `task cluster-upgrade` takes it for
you before its first step (`backups/etcd/pre-upgrade-etcd-<timestamp>.snap.gpg` in both
artifact buckets, encrypted, `gpg -d` it first; no retention removes it) and refuses to
start when it cannot, unless `UPGRADE_SKIP_SNAPSHOT=1`. By hand: `task etcd-snapshot`
or `talosctl etcd snapshot`, taken on the version you will return to.

```bash
talosctl -n <node-ip> rollback                      # every node, workers included
talosctl -n <cp-ip> reset --graceful=false --reboot \
  --system-labels-to-wipe EPHEMERAL                 # each control plane: wipes etcd
talosctl -n <one-cp-ip> bootstrap --recover-from=etcd.snapshot
```

Measured: three etcd members 52 s after the `bootstrap`, five nodes Ready, the API
answering again 4.3 minutes after the first `rollback` (236 consecutive failed probe
seconds), etcd 3.6.12 again, `cluster-verify` 14/14 once the pins were lowered. **Every
change since the snapshot is gone**: a ConfigMap written after it was missing
afterwards, one written before it was there.

### What does not go back

- **Kubernetes.** `talosctl upgrade-k8s --to 1.36.3` on a 1.37.1 cluster answers
  `unsupported upgrade path 1.37->1.36`. A restore after the Kubernetes bump was not
  tried (the drill held Kubernetes at 1.36.3): start the way back from a snapshot
  taken before the Talos step, and bump Kubernetes only once the Talos step has soaked.
- **The Terraform state and the pins.** After the restore, lowering `talos_version` in
  the tfvars makes `infra-plan` plan `talos_machine_secrets.this[0] must be replaced`
  (the provider replaces the secrets when the version goes down; `prevent_destroy`
  stops an apply, and a regenerated PKI would be worse than the problem). The state has
  to go back too, to a copy taken before the climb: `task cluster-upgrade` writes one
  (`<state key>.pre-upgrade.<timestamp>` in the replica, listed by `task backup-state -- --list`,
  never pruned), because the replica's "newest five" generations are all written during the
  climb. Until then leave the pins where they are: the
  cluster runs the old version and `cluster-verify` reads `MIXED`. Not measured: copying
  a pre-climb state back.
- Not measured either: other clouds, Proxmox, a Longhorn or CNPG workload across the
  restore, and a control plane rollback inside a Talos minor (a patch), where etcd's
  storage version does not move and it may well work.

## Replacing a node rather than upgrading it

`--upgrade` cannot carry a disk or zone change — those need a new VM. Same
script, without `--upgrade`: it drains, applies a targeted `-replace`, and waits,
one node at a time. That path *does* need the new cloud image to exist.

A new **schematic** is a different matter and `--upgrade` does carry it, since
2026-08-19. It did not before: every gate compared the Talos version tag, so a
node on the old schematic at the target version was greeted with "already runs
v1.13.8 — skipping" and a change to the system extensions could be delivered by
no supported path. The roll now reads the schematic off the node
(`talosctl get extensions` publishes it) and rolls a node whose version matches
but whose image does not.

### A node size change is an in-place update, on every provider

⚠️ `instance_type` (Scaleway, Outscale), `flavor_name` (OVH) and
`cpu_cores`/`memory_mb` (Proxmox) are not replacements: the provider stops,
resizes or reboots the instance and keeps its disk. So `task infra-apply` plans
N updates and 0 destroys, and applies them to **every node at once**. Measured
on OVH only, on 2026-08-15: six nodes went into `VERIFY_RESIZE` together and the
apiserver was unreachable for several minutes. For the other three, the verdict
comes from the provider source at the versions resolved on 2026-09-26 and from
an offline plan with the real provider binaries, not from a live bump (#51). `rolling-replace`'s "one node at a time"
guard did not catch it: it counted what a plan would DESTROY, and a resize
destroys nothing. It now also refuses a plan that changes another node (below).

**Do not route it through the roll.** Measured on Scaleway, 2026-10-02: with
`instance_type` raised, `task cluster-roll -- --workers-only` replaced worker 0
and then, in its config step, resized all three control planes in place within
25 s; the apiserver behind the load balancer was unreachable for 56 s. `-target`
pulls in dependencies, and the destroy count cannot see a resize. The roll now
plans both steps before it cordons anything and refuses a plan that changes
another node (`foreign_changes`): against that cluster, with a size change
pending on all six nodes, it stopped at worker 0 before the cordon, naming the
three control planes and the other two workers.
Whether OVH's, Outscale's and Proxmox's targeted config step drags other nodes
along has not been measured; the same refusal covers them if it does.

**Go one node at a time, in place.** `kubectl drain` the node, `tofu plan
-target=<that server>` and check it is exactly one update, apply that file, wait
for Ready, `kubectl uncordon`, next node. Measured on Scaleway the same day,
three control planes then workers: etcd 3/3 after each, 5 failed one-second
probes in 241 and none longer than 1 s, about a minute per node. It has no
budget or etcd gate beyond what you check by hand.

Two cases would turn a size change into a replacement: Scaleway's
`replace_on_type_change`, and on OpenStack a node whose recorded flavour is
empty (for example because the flavour was deleted). A replacement would be
worse, since every node would be destroyed at once.
[`tests/node-size-change.tftest.hcl`](../infrastructure/opentofu/cluster/tests/node-size-change.tftest.hcl)
checks that Scaleway's flag stays unset.

## Removing nodes

Lowering `control_planes` or `workers` in the tfvars used to make OpenTofu destroy the
highest-index machine and its data volumes with no drain, no etcd leave and no Node delete. `cluster-up`,
`infra-apply` and `grow-nodes.sh` now refuse such a plan, and removal has two commands of its own, like destroy:

```bash
# lower the count in envs/<role>-<provider>.tfvars, then
task cluster-shrink-plan PROVIDER=scaleway     # read-only: what goes, and can the cluster lose it
task cluster-shrink PROVIDER=scaleway PLAN=shrink-management-scaleway.json
```

The scope comes from the plan OpenTofu itself makes, never from the tfvars; `cluster-shrink` derives it
again and refuses if it moved. Only the highest indexes can go, a worker run may take several (one at a
time, highest first), a control-plane run takes one, and below three control planes it wants
`-- --allow-below-ha` on both commands. One worker and one control plane stay at least.

| | worker | control plane |
|---|---|---|
| reversible | Longhorn eviction, drain | etcd snapshot, etcd leadership handed off, drain |
| the member's point of no return | | `etcd leave` |
| the machine | `talosctl shutdown`, then delete the Node | the same |
| irreversible | targeted destroy of exactly that node's resources, data volumes included | the same, and its load-balancer membership |
| after | refresh the outputs and tunnels, apply the remaining nodes' config one at a time, empty plan, `cluster-verify` | the same |

It refuses before touching anything when: the plan changes more than the removal (another edit pending, a
disk count edited with its machine staying, a node delete tofu does not attribute to a lowered count); a
volume is pinned to the node (CNPG or local-path data: move it first); Longhorn would have fewer nodes than a
volume has replicas; the workers that stay cannot carry the CPU requests; a node is not Ready; etcd has not
the members it should. "Down" is never taken from the node's own tunnel: Talos must accept the shutdown, a
control plane that is not the one going must stop reaching the machine twice, and its Node must read NotReady.
A run that stopped half-way is finished by running `cluster-shrink-plan` and `cluster-shrink` again; a node
already out of Kubernetes and down, an etcd member already gone, are skipped.

**Measured on a real cloud, 2026-10-04**, on a 3 control plane cluster at Talos 1.14.2 with Cilium and no Longhorn or
CNPG on it: a worker, then one control plane (3 to 2), on each of Scaleway, OVH and Outscale. Every run ended with
`cluster-verify` green (13/13 after a worker, 12/12 after the control plane, which reads `~ NOT HA` at two), etcd with
exactly the members left, and the provider's API listing exactly the machines left (no volume, port, address or
NIC of the removed node). The targeted destroy was exactly the bundle read: a worker is 5 or 6 resources, a control
plane 3 (Outscale) to 5, plus the load balancer's membership updated in the same apply. An authenticated
`/readyz` through the load balancer each second, during the control-plane removal: Scaleway 12 failed of 350
(eight isolated timeouts over 40 s, then four instant failures in a row about 20 s before the end of the run:
attributed, not isolated, to the probe reading the kubeconfig while `task kubeconfig` rewrote it, as for OVH's
worker below), OVH 13 of 374 (isolated, over 76 s), Outscale 13 of 220 (longest run 3 probes, over 57 s). The
isolated failures are the load balancer still sending one request in three to a control plane that has left etcd;
a client that retries does not see them. OVH's span matches its health check (5 × 15 s); Scaleway's is shorter
(40 s against 75 s) and the membership update in the same apply was not timestamped, so what ended the failures
there was not separated. Taking the member out of the load balancer first is not built; its effect was not
measured. Worker removals: Outscale 1 failed probe of 215, OVH none (apart from the moment `cluster-verify`
rewrote the kubeconfig the probe was reading); Scaleway's was not probed. The probe read the live kubeconfig until
the OVH worker run and a private copy after.

On Scaleway the cluster was then grown back to 3 + 2 with one `cluster-up`: `cluster-verify` 13/13, and
`cluster-idempotency` passed (empty plan, the five nodes unchanged).

One limit: the closing step applies every pending machine-config update, one node at a time, not only the one the
counts cause, so a machine-config edit made in the same tfvars rides in with the removal. Make it separately.

**Longhorn, Scaleway, 2026-10-04** (Longhorn 1.13.0 on the encrypted user volumes): a volume whose only replica
sat on the worker going away, holding a checksummed blob written from a pod on the other worker. A second volume
wanting two replicas was refused (`wants 2 replicas, 1 node(s) would remain`). Without it, the removal asked
Longhorn to evict the node, the replica moved to the worker that stays before the drain began, the volume stayed
healthy and attached, the blob's checksum held, and the Longhorn node entry went with the node. Longhorn's webhook
refuses a node edit while it is syncing that node's disks ("please retry later"), so the eviction request is
retried.

**CNPG, Scaleway, 2026-10-04** (CloudNativePG 1.30.1 on a cluster of one control plane and two workers, two instances
on a one-replica Longhorn class, 1000 rows written): the replica sat on the worker going away. The removal opened
CNPG's maintenance window and dropped its budgets before the drain, the instance came back on the worker that
stays with its volume, both instances held the 1000 rows, the cluster read healthy with two instances, and the
budget and the window were put back at the end. That cluster is also the non-HA shape (one control plane), and the
removal ran on it unchanged.

A second run put the **primary** on the worker going away (the same cluster shape, a writer pod on the worker that
stays inserting one row a second through the read-write service). The drain evicted it, CNPG failed over to the
replica on the other worker and recreated the old primary there as a replica with its volume; the cluster read
healthy with two instances, both held the 1000 rows, and of 368 inserts 2 failed (a failing run of 2 s) and every
acknowledged one was on the new primary. The budget and the window were put back at the end.

Not measured: Proxmox, and a removal that stops half-way on a real cloud.

## The Secrets encryption key (etcd) — not rotatable in place

Kubernetes Secrets are encrypted in etcd with the `secretbox` provider (XSalsa20-Poly1305), set through
`cluster.secretboxEncryptionSecret`. It is Kubernetes' recommended local provider, but XSalsa20-Poly1305 is not among
the AEAD modes ANSSI PA-079 R12 lists (GCM, CCM, EAX, ChaCha20-Poly1305). **Documented deviation:** Talos offers only
`secretbox` and `aescbc` here, and `aescbc` is not an AEAD at all. A KMS v2 provider would replace it, but only with a
KMS outside the cluster; OpenBao inside it would be circular.

The key is one `random_bytes` (32 bytes) in the tfstate, which is encrypted client-side, and in every control-plane
machine config. Losing it makes every Secret in an etcd snapshot unreadable.

**There is no rotation procedure here, on purpose.** The machine config takes a single key, so replacing the value
(or tainting `random_bytes.etcd_encryption_secret`) leaves the existing Secrets encrypted under a key the
apiserver no longer holds. A two-key rotation (add the new key, re-write every Secret with
`kubectl get secrets -A -o json | kubectl replace -f -`, drop the old one) is the usual Kubernetes sequence, but whether
Talos can be given the second key has not been verified or run. Until it has, the only path known to be safe after a
suspected key leak is a new cluster, re-seeded from OpenBao. Do not rehearse the sequence above on a cluster you need.
