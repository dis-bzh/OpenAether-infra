# Upgrading a live cluster — Kubernetes and Talos

🇫🇷 [Version française](upgrade.fr.md)

> Building a cluster and keeping one are different claims. This is the second.
> Measured by hand on **Scaleway, OVH and Outscale** — the first two on
> 2026-08-19, Outscale on 2026-08-20 — HA topologies, every node upgraded **in
> place** rather than replaced and each node's own Talos API asked what it runs.
> Earlier runs on Outscale and on OVH reverted on the next reboot, and
> the open issues say why.
>
> The scripted version of this same procedure is `task cluster-upgrade`
> ([`scripts/dev/cluster-upgrade.sh`](../scripts/dev/cluster-upgrade.sh)). It is
> run by hand, by someone watching: no CI lane deploys anything. This page is
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
gated, and no real roll has produced its number yet (#41). How it works:
[`cluster-upgrade.sh` § The service probe](../scripts/dev/cluster-upgrade.sh).

## Kubernetes first

It reboots nothing, so it isolates the control-plane roll from the node roll.

```bash
# edit kubernetes_version in envs/<role>-<provider>.tfvars, then
task infra-apply ROLE=management PROVIDER=<p>
```

Talos reconciles the static pods and the kubelets; wait for every node to report
the new version before moving on. Note that this bypasses `talosctl upgrade-k8s`,
which sequences those components behind health checks — see the open issues.

## Then Talos, in place

Bump `talos_version`, build the image for the new version (the node resources
ignore the image, but the *data source* still has to resolve), apply, then roll.

```bash
task image-build PROVIDER=<p> VERSION=<new> ENSURE=1
# edit talos_version in the tfvars, then
task infra-apply ROLE=management PROVIDER=<p>
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<key> -- --cp-only --upgrade
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<key> -- --workers-only --upgrade
```

**On Outscale the first line dominates the whole upgrade.** The image is
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
that node-local storage could not move.

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

⚠️ **The first apply after a `talos_version` bump fails on OVH and Outscale**
with "Provider produced inconsistent final plan", once per machine config.
Nothing is left half-applied; re-run it. This is upstream
`siderolabs/terraform-provider-talos` #352, fixed only in the 0.12.0 pre-release
line — details and the decision still open as an issue.

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

⚠️ **A flavour change is not one of them on OpenStack, and that is worse.** OVH
resizes the instance in place, so `task infra-apply` plans it as an update rather than
a replacement and applies it to **every node at once** — measured 2026-08-15,
where six nodes went into `VERIFY_RESIZE` together and the apiserver was
unreachable for several minutes. `rolling-replace`'s "one node at a time" guard
does not catch it either: that guard counts what a plan would DESTROY, and a
resize destroys nothing. Change `flavor_name` one node at a time with
`-target`, or accept the outage knowingly.
