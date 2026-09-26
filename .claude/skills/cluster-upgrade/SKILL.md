---
name: cluster-upgrade
description: Upgrading Kubernetes and Talos on a live OpenAether cluster without taking the API down. Use when bumping talos_version or kubernetes_version, running rolling-replace, or investigating a node that did not come back.
---

# Upgrading a live cluster

`docs/upgrade.md` is the procedure, and `scripts/dev/cluster-upgrade.sh` is that
same procedure unattended — if the two disagree, the script wins, it is the one
that runs. This is the reasoning behind both.

## Upgrade in place; do not replace the node

`rolling-replace.sh --upgrade` calls `talosctl upgrade`, which keeps the node's
disk, identity and etcd membership, drains it, and refuses a control-plane
upgrade that would cost etcd quorum. Replacing the VM throws all of that away and
rebuilds it. Replacement remains correct for anything that is **not** a version
change.

**This is upstream's position, not ours.** Talos documents the upgrade as an API
call and states it refuses a control-plane upgrade that would lose etcd quorum
(docs.siderolabs.com, v1.13, *lifecycle-management/upgrading-talos*). Omni —
Sidero's own fleet product — upgrades in place and explicitly says not to delete
machines out of band, nor to add control-plane nodes to resolve a quorum issue;
Sidero has deprecated its own CAPI control-plane provider for Talos in its
favour. etcd prescribes the opposite of "surge" for a control plane: remove the
old member, then add the new one, because an unreachable new member already
counts toward quorum (etcd.io, v3.6, *runtime-configuration*). Cluster API,
which defaults to replacement, added a delete-first strategy with `MaxSurge: 0`
precisely for resource-constrained clusters — which is what ours are during a
roll.

So: "add a node, then retire the old one" is a defensible *ordering* when you are
already replacing a machine. It is not a reason to replace one instead of
upgrading it.

## Check the pair before moving either

Talos supports the current Kubernetes minor and the five before it. Both the
starting and the ending pair must sit inside that window, and so must the
intermediate state, because one moves before the other. `versions-guard.tf`
refuses an unsupported pair and refuses a Talos minor it has never heard of —
extend its map from the upstream matrix rather than widening it.

## Expect two applies, and know why

Bumping `talos_version` and applying puts the new installer into the machine
configs; nothing reboots yet. That first apply fails once with "Provider produced
inconsistent final plan" on OVH and Outscale. Run it again.

Not a sign you did something wrong, and no longer a mystery: upstream
`siderolabs/terraform-provider-talos` #352. When `machine_configuration_input` is
unknown at plan time, the provider keeps the old `machine_configuration_hash` in
the plan and recomputes it at apply. The second run works because the first
resolved whatever was unknown. 0.12.0 is the first stable release with the
upstream fix, and the roots now select it; whether it ends the first-apply
failure is unproven on a real cloud (#83). **Do not "fix" it locally without
proving the fix on a real cloud**, and do not add a retry: `cluster-upgrade.sh`
deliberately has none, because a retry turns the defect green.

## What to watch, beyond "it came back"

- **The node's name is unchanged.** A `talos-xxxxx` entry means the hostname did
  not hold; the next reboot orphans another node object, and
  `data.talos_cluster_health` then blocks `tofu plan` itself.
- **etcd still lists every member** — by peer URL, not by name: a member keeps the
  name it joined under, so a renamed node no longer matches by hostname.
- **A number for the interruption.** One-second probe against the kubeconfig's
  endpoint — not a tunnel to one node, since the node you are upgrading is
  expected to go away.
- **`tofu plan` clean afterwards.** If it wants to replace nodes, the boot image
  and the running version have disagreed, and that plan would take the cluster
  down.

## A node that comes back on the old version

Observed on OVH and Outscale, never on Scaleway: the installer logs the new
version, `talosctl upgrade` exits 0, and later some nodes report the previous
one.

**SOLVED on 2026-08-19, and the answer was ours.** Read this before theorising:
the mechanism below is real, but on OVH and Outscale it was being triggered by a
system extension WE shipped.

`talos-image/schematic.yaml` carried `siderolabs/qemu-guest-agent`. OpenStack
attaches the virtio channel it waits for only when the IMAGE declares
`hw_qemu_guest_agent`, which ours did not, and Outscale has no equivalent. So:

    ext-qemu-guest-agent  Waiting … for /dev/virtio-ports/org.qemu.guest_agent.0
    phase startEverything (9/9): waiting for 13 services — and never "done"

`startAllServices` never completes → no `SequenceEvent{boot, STOP}` →
`machine_status.go` never sets `Running` → `drop_upgrade_fallback.go` never
deletes the META `Upgrade` tag → **the next reboot reverts the node**, and
`talosctl upgrade --wait` never returns because it waits for `Running`. One
cause, three symptoms. The extension is gone from the schematic.

Proven by difference: a Scaleway node on the SAME schematic showed
`ext-qemu-guest-agent Running`, `stage: running`, no tag. The hypervisor supplies
the device or it does not.

The underlying mechanism, which still applies to any future stuck service: the
installer writes an `Upgrade` tag to the META partition (key 6), a controller
drops it only once the node is `Running` **and** `Ready`, and otherwise the
bootloader reverts to the previous partition. `talos#9088` is closed as intended
behaviour.

**Two gates now enforce it, so this should not recur silently.**
`rolling-replace` refuses to call a node done until Talos reports
`Stage == Running`, and it names the service blocking the boot when it does not.
And every gate compares the running SCHEMATIC, not just the version tag — a node
on the old image at the target version used to be skipped by all of them.

Ask the node, in this order, before theorising:

```
talosctl -e <cp> -n <ip> logs machined | grep -i "reverting failed upgrade"
talosctl -e <cp> -n <ip> get securitystate -o yaml     # bootedWithUKI?
talosctl -e <cp> -n <ip> version --short               # what it actually runs
```

`BOOT_IMAGE=/A/vmlinuz` is legacy GRUB, and since Talos 1.10 GRUB is no longer
used for new UEFI installs — so two providers can exercise different bootloader
code from the same repository. A competing hypothesis, already recorded for
OpenStack in `rolling-replace.sh`, is that the instance boots the image volume
rather than the installed disk, so the reboot simply discards the upgrade.

**Talos drops the META `Upgrade` fallback only at `stage=running`.** A node that
is Ready but stuck at `Booting` reverts on its next reboot, and `upgrade --wait`
never returns. One unstartable extension holds the boot sequence open, so check
`talosctl services` before blaming the provider.

**And a version tag is not an image.** The schematic carries the extensions, and
a new installer reference does not reinstall a running node. Compare the running
schematic (`talosctl get extensions`), never the tag.

## A stuck drain is one budget's fault, not the stack's

A worker drains clean — measured 2026-08-13, exit 0, zero non-DaemonSet pods
left. It did not before, and the cause was singular: `istiod` ran one replica
under a budget requiring one available, so it could never be evicted. It runs two
now.

**Applies only once applications are back; 0.1.0 has none.** A pure-infra cluster
has no PodDisruptionBudget worth the name, and a drain that hangs on one is a
different bug. The remaining zero-disruption budgets are correct and transient —
CNPG guards each cluster's primary until a switchover, Longhorn blocks while
volumes are attached, OpenBao wants 2 of 3 raft replicas. If a drain hangs, look
for a single-replica workload under a `minAvailable: 1` before concluding the
stack cannot be drained. That wrong conclusion was written into a release note
and had to be corrected in public.
