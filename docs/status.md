# Where we stand

What runs, what has been measured on a real account and when, and what is still
unproven. This is the first file to open at the start of a session: it says where
to pick up.

Open work is **not** here — it is in the GitHub issues, each naming what closes it
and the rung it needs. This file answers "what is true today", not "what is left".

**0.1.0, published 2026-08-20 as a pre-release, is the first release that shipped something proven.** Every 1.x tag was
deleted on both repositories; the versions they named never worked. Scope:
**one Talos cluster on one supported provider, floor = Cilium**. Flux is disabled
by default (`deploy_flux`, false) — disabled, not amputated, and it returns as a
user choice. CAPI and multi-cluster are an optional overlay, never the entry point.

**Measured on real clouds**, each row on the date in its `measured` column. Each
provider's first row is a deploy from an empty account; the Scaleway re-run is a
second cycle, not claimed from an empty account. This is the evidence the release
rests on.
`task evidence-check` compares the newest row per provider with the pin in
`infrastructure/opentofu/cluster/variables.tf` and with today.

<!-- Parsed by scripts/dev/check-evidence-age.sh: keep the measured, k8s and Talos headers, one YYYY-MM-DD per row. -->

| | measured | deploy | `task cluster-verify` | idempotency | k8s | Talos | longest outage |
|---|---|---|---|---|---|---|---|
| Scaleway | 2026-08-19 | ✅ 8 min 50, 72 resources | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 5 s (16 fails in 575) |
| Scaleway, re-run | 2026-08-20 | — | ✅ 11/11 | ✅ `No changes.` ×2, one after the upgrade | unchanged at 1.36.3 | ✅ 6/6 nodes 1.13.8→1.13.9 | 2 s (13 fails in 577), Talos only, not comparable: [`upgrade.md`](upgrade.md) |
| Scaleway, 1.14 | 2026-10-03 | ✅ from an empty project, a fresh `bucket_suffix` and encrypted worker data disks | ✅ 13/13 | ✅ `No changes.` after the climb | ✅ 1.36.3→1.37.1 | ✅ 6/6 nodes 1.13.9→1.14.2, in place, a Longhorn volume attached | 2 s (6 fails in 764, Talos step; 9 in 805, Kubernetes step) |
| OVH | 2026-08-19 | ✅ | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 7 s (9-10 in ~540) |
| OVH, 1.14 | 2026-10-03 | ✅ 3+3 across `eu-west-par-a/b/c` with encrypted worker data disks (the first attempt died on the example's `nova` zone, #236) | ✅ 13/13, also with an `os:reader` talosconfig | ✅ plan empty after the climb and after the Kubernetes pin | ✅ 1.36.3→1.37.1 through `talosctl upgrade-k8s`, then the pin (#70) | ✅ 6/6 nodes 1.13.9→1.14.2 with Flux and a CNPG cluster in place (#64) | 1 s (3 in 583, Talos step); `upgrade-k8s` 10 s (11 in 430) |
| Outscale | 2026-08-20 | ✅ 51 resources, then 17 | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 8 s (59 in 1179) |
| Outscale, 1.14 | 2026-10-03 | ✅ 3+3 `tinav5.c2r4p1` with encrypted worker data disks | ✅ 13/13 | ✅ `No changes.` ×3, one after the climb | ✅ 1.36.3→1.37.1 | ✅ 6/6 nodes 1.13.9→1.14.2 | 9 s (68 in 1535: 3 s on the Talos step, 9 s on Kubernetes); service probe 40 failed + 20 blind of 1490, longest 3 s |

The August rows predate the failure-domain check (#38, merged). It was read on real accounts on
2026-10-03: red on Outscale in one subregion (`3 of 3 control planes share one failure domain`), green
with three control planes in three subregions there and in three OVH availability zones. Scaleway over
2 zones is a 2+1 split: still green, with a warning, because the zone holding two takes etcd's quorum
with it.

Three things about that table are the point of it:

- **Versions were read from the kubelets and from each node's own Talos API**,
  never from the tool that performed the upgrade. Talos itself reports
  `stage=running` on 6/6 and the META upgrade fallback dropped — so the upgrade
  survives a reboot, which is what the earlier "6/6 report the new version" never
  established.
- **Idempotency is three assertions, not one**: an empty plan, the SAME nodes
  (name and creationTimestamp), and a kubeconfig that still reaches the apiserver.
- **The interruption got WORSE, and that is a regression, not a footnote.** The
  earlier records were 3 s on Scaleway, 1 s on OVH and 1 s on Outscale. All three
  clouds moved the same way in the same week. First entry below.

**Scaleway re-run on 2026-08-20**, after the roll was changed to take the etcd
leader last: `cluster-up` → `cluster-up` → `cluster-upgrade` → `cluster-up`, all
four green. The two re-runs are the idempotency evidence and they are the command
itself, not a script — `No changes.` on all three roots, `0 added, 0 changed, 0
destroyed`. **The second re-run is new**: idempotency AFTER an upgrade had never
been checked, and it holds because `cluster-upgrade` writes the new pin back into
the tfvars, so a later `cluster-up` does not try to revert. That upgrade moved
Talos v1.13.8→v1.13.9 on 6/6 nodes, `cluster-verify` 11/11. Longest outage 2 s
(13 fails in 577) — see [`upgrade.md`](upgrade.md) for why that does NOT establish
the leader-last fix: that run moved Talos only, the 5 s one also moved Kubernetes.

**Scaleway, third run, 2026-10-02**, from an empty project and under a fresh `bucket_suffix` (#68): `cluster-up`, `cluster-verify` (12/12: the verifier has gained a check since the August rows) and two `cluster-idempotency` passes. Then `cluster-upgrade` to Talos 1.14.2 and Kubernetes 1.37.1. The Talos step rolled six nodes with the apiserver failing 6 times in 474 one-second probes, longest 1 s. The Kubernetes step failed in our own tooling: `infra-apply` read an unreadable state as "no bootstrap" and dropped the Talos resources from the state (#223). The cluster was untouched; `adopt-bootstrap` (#214) and a plain `cluster-up` brought the state back and ended on 1.37.1 everywhere. Also measured: a size change through the roll resized the three control planes at once and took the API down for 56 s (#222), where one node at a time, in place, costs 1 s blips; a control plane powered off for 80 s (3 failed probes in 360, a write succeeded); a second `plan` refused by the state lock (#56, Scaleway); `cluster-up` red when the verifier is (#84); a node added to a live cluster needing a targeted config apply (#59, since fixed: `grow-nodes.sh`, run live three times on 2026-10-03 and merged as #232). Torn down and proven clean the same night.

**Scaleway, the 1.14 climb, 2026-10-03**, from an empty project with encrypted worker data disks. `cluster-up` was interrupted twice on purpose in phase 2 and recovered each time (#40 and #67, closed): the tunnels killed before the bootstrap call (a plain re-run resumed), and `SIGKILL` right after it (`adopt-bootstrap` found 3 etcd members and imported the bootstrap; the stale state lock the kill left needed a `tofu force-unlock`, which `explain-failure.sh` now names). Longhorn 1.13 on the encrypted user volumes at Talos 1.13.9, a 5 MiB blob written, then `cluster-upgrade` 1.13.9/1.36.3 → 1.14.2/1.37.1 with a one-replica stateful pod and a Service probe running: 6 failed apiserver probes in 764 for the Talos step and 9 in 805 for the Kubernetes step (longest 2 s each), the Service 0 failed, the blob's hash unchanged, the stateful pod gapped 20 s and 16 s. The roll stopped once on a defect of ours, the Longhorn gate waiting for a rebuild its own cordon prevented (#229). The same day, on the exact pair #181 names (Talos 1.14.1, Kubernetes 1.37.0): Longhorn written, read from other workers and across a node reboot, and the worker volumes read back by `cluster-verify` (#62). A worker was then added by one `task cluster-up` three times running, 3 to 6 (`grow-nodes.sh`, #59). This row is what moved the pin to 1.14.2 / 1.37.1.

**Removing nodes, 2026-10-04**, on the three clouds' 3-control-plane clusters at Talos 1.14.2: `task cluster-shrink` took a worker and then one control plane (3 to 2, `--allow-below-ha`) off each of Scaleway, OVH and Outscale, `cluster-verify` green after every run, the provider's API listing exactly the machines left. The load balancer kept sending one request in three to the control plane that had left etcd for 40 to 76 s: a few failed `/readyz` probes, which a client that retries does not see. Longhorn ran on Scaleway only, where its eviction was measured (a sole replica moved off the node, data intact, a two-replica volume refused); CNPG ran there too (a replica moved with its volume, data intact; a primary on the departing node failed over: 2 of 368 inserts failed, none acknowledged lost). Figures and mechanism: [`upgrade.md`](upgrade.md#removing-nodes).

**What the release delivers besides a cluster.** Every task is `<noun>-<verb>`
(`cluster-up`, `infra-plan/apply/down`, `tunnels-up`, `cluster-verify/upgrade/roll/down`).
`APPROVE=auto|ask` names WHO answers the approval, never whether there is one:
every apply plans to a file and applies THAT file, and a saved plan never prompts.
Destroy always takes two commands and no flag collapses them. S3 credentials are
namespaced by the cloud that HOLDS the bucket, and a cross-provider backup is
proven — an encrypted tfstate at Outscale while the cluster runs on Scaleway.
Every offline assertion is mutation-tested; the count and harness total are not
written here as a number — a hand-typed one drifted from what `task
test-scripts` actually ran **four** times running (333, then 413, then 468,
then 486, each one stale before the next edit — the last of those from a
branch that, while fixing the same symptom, kept writing a number here; see
[#111](https://github.com/dis-bzh/OpenAether-infra/issues/111)). Measure it
instead: `task test-scripts 2>&1 | grep -oE '^[0-9]+ passed' | awk '{s+=$1;
n++} END {print s, n}'`. The emulated lane's Feint pin, and what it proves:
[`emulated-cloud.md`](emulated-cloud.md).

**The root cause behind a week of upgrade failures is fixed**, and it was ours:
the shared schematic shipped `siderolabs/qemu-guest-agent`, which never starts on
OVH or Outscale (no `hw_qemu_guest_agent` on the image, so the virtio port it
waits for never appears). The boot sequence never finished, Stage never became
Running, the META `Upgrade` key was never dropped, and the next reboot reverted
the upgrade — one extension behind the hung watch, the lost upgrade and the revert.

**Outscale needs a fresh Net, and leaves one behind.** The LBU that sat in
`provisioning` for over an hour was diagnosed by Outscale as a timeout inside
their own load balancer service: it stops waiting after 10 s for an internal VM
that takes about 10.7, so the workflow fails, the resources it already created
stay, and the LBU never leaves `provisioning`. Their instruction is to create no
further LBU in that Net and use a new one — a redeploy on a fresh Net succeeded
on 2026-08-20, the new LBU `active` with 3 backends, and **request 399530 is
closed**. One Net from before the fix still refuses deletion on a dependency no
read returns; only Outscale can clear that, and a second request is open for it.

**A bumped pin used to land nowhere, and every signal said otherwise.** Measured
on a live Scaleway cluster 2026-08-21: with `talos_version` bumped and NOT
applied, `cluster-verify` answered `11 passed, 0 failed`, exit 0 — the fleet a
version behind its own configuration and nothing red anywhere, because the check
compared the running *schematic*, which a version bump does not change. The
verifier now compares the running versions too and answers `12 passed, 1 failed`
on that same state. The convergence half was measured the same day: a seven-step
climb from (Talos 1.12.7, Kubernetes 1.30.0) to (1.13.9, 1.36.3) on six nodes,
longest apiserver outage **5 s**.

**Dependency watch, since 2026-08-24.** Cléa (`scripts/clea/`, `docs/clea.md`)
reads every version this repository claims, resolves what upstream published,
and probes a bump by installing it from cold and upgrading over the old one in
a bare container — daily for tools, weekly for the local Talos/Kubernetes pair,
never for a cloud. Renovate keeps proposing the bumps; Cléa watches, probes and
reports into one issue, rewritten in place.

It found nine of twenty-one version anchors inert (Renovate had never been told
to read them, now fixed), and that Renovate had proposed nothing since its
config landed — its nine pull requests predate `renovate.json5` by three hours,
and helm 4.2.4 (published 2026-08-13) and flux 2.9.4 (2026-08-07) both sat
unproposed through their scheduled windows. The cause was not the schedule: Mend's
hosted job ran in `mode: silent`, so it found the updates and wrote no issue and no
pull request (#88, closed). `renovate.json5` now sets `mode: "full"` behind a
Dependency Dashboard approval box, and the dashboard appeared within a minute of the merge.

Running it, on a workstation rather than only in CI, found five more defects
that a green pipeline never showed: `command -v sudo` asking whether sudo
*exists* rather than whether it can be *used* (eight sites); `install_tofu`
preferring snap, which cannot install a named version; a tool's version
assembled from two commands; the CoreDNS readiness gate failing on a cluster it
had just watched come up; and the teardown proof printing nothing on a clean
account, indistinguishable from a check that never ran. All five are fixed.

**The local and cloud roots now pin the same Talos and Kubernetes.** They had
drifted to `v1.13.3` / `v1.35.3` against `v1.13.9` / `v1.36.3` before either
was anchored; `infrastructure/opentofu-local/variables.tf` now carries the
cloud root's exact pin. Measured 2026-08-24 on the Docker lane at the shipped
default topology (3 control planes + 3 workers, not a smaller probe): all six
nodes Ready, Cilium on 6/6, `task local-verify` 6/6, versions read from the
cluster itself rather than the tool that deployed it — `kubectl get nodes`
reports `v1.36.3` on all six, and `talosctl version` against the control
plane's own API reports server tag `v1.13.9`. `task local-down` afterward left
no container, volume, network or credential.
[#87](https://github.com/dis-bzh/OpenAether-infra/issues/87) is closed on that
basis; what it does not answer is below.

**Not proven**: a failover (provider A treated as gone, the cluster rebuilt on B from B's replica
alone, #57; only `restore-artifacts` was read back byte-identical, on one provider); no lane has ever run
unattended to completion; and a control-plane roll with zero failed probes has not happened on any cloud
(#42: 1 s on Scaleway and OVH, 3 s on Outscale, 9 s once Kubernetes moves there).

**Talos provider 0.12.0 is pinned** ([#241](https://github.com/dis-bzh/OpenAether-infra/issues/241)); a 1.14 node
is rendered under a capped contract, and `config_contract` in `modules/talos/main.tf` says why. Measured on Scaleway on
2026-10-05, one control plane and one worker at Talos 1.14.2 and Kubernetes 1.37.1, no Flux: a cluster built under 0.11
planned empty under the pin and `cluster-up` changed nothing (`cluster-verify` 12/12); rebuilt from an empty state under
0.12.0, `cluster-up` ended on `cluster-verify` 12/12 and `cluster-idempotency` was green. Inside the 1.13 contract 0.12.0
had already run through on OVH and on Outscale (a fresh deploy and a bump 1.13.9→1.13.11, 13/13, plan empty after), with
our `replace_triggered_by` workaround still in (#83, closed).
**Not proven**: a 1.14 cluster under 0.12.0 with three control planes, or on OVH or Outscale; `cluster-upgrade` 1.13.9 to
1.14.2 under 0.12.0 (only offline renders, which differ in the installer image alone); a run without
`replace_triggered_by`; `task local-up` at 1.14.2, which did not start on the one host tried (kernel 6.12), so the
container-mode install image change (v1.13.0 to v1.14.0) is unmeasured there; `talos_machine`
([#44](https://github.com/dis-bzh/OpenAether-infra/issues/44)) is not adopted.

**Six gates were green on something they had stopped checking**, found on
2026-08-28 by auditing what the pipeline actually constrains rather than what it
runs. Each is reproduced in both directions and fixed — see the CHANGELOG. The
two that would have cost money: `tofu validate` answered `Success!` with a
required provider-contract output deleted (`try()` cannot tell an inactive
provider from a missing attribute), and `talos-image.sh` went straight to "image
already up to date" when the Factory answered without a schematic id, one step
from a billable publish with the pin never verified. `tflint` was linting one
directory in fourteen. `provider-contract.md` — the document `CLAUDE.md` calls
the authority — required a variable no module has ever declared.

**Resume here**: the pin is 1.14.2 / 1.37.1 and every cloud's newest row says so. Still unseen on a real
cloud: the failover (#57), a roll with zero failed probes (#42), a Proxmox apply (#48, #201: no hardware),
and the wider cases of #66. Its CA mismatch was reproduced on Scaleway (1 control plane, 2026-10-04) through
`infra-down-plan`'s untracking and recovered two ways (`cluster/README.md`, "Lost the Talos secrets"); the version
flip is refused by `prevent_destroy` and the interrupted-apply path was not broken. Unseen: OVH and Outscale, three
control planes, a replica on another provider, a cluster with no talosconfig and no replica copy. Standing items
only a person can close are in the issues: #43 (Outscale support), #61, #73 (two old staging buckets, a delete the
owner runs). Upstream, Feint's fix for #179 is on its `main` and waits for their next release.
