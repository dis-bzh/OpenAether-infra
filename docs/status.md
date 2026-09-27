# Where we stand

What runs, what has been measured on a real account and when, and what is still
unproven. This is the first file to open at the start of a session: it says where
to pick up.

Open work is **not** here — it is in the GitHub issues, each naming what closes it
and the rung it needs. This file answers "what is true today", not "what is left".

**0.1.0 is the first release that will ship something proven.** Every 1.x tag was
deleted on both repositories; the versions they named never worked. Scope:
**one Talos cluster on one supported provider, floor = Cilium**. Flux is disabled
by default (`deploy_flux`, false) — disabled, not amputated, and it returns as a
user choice. CAPI and multi-cluster are an optional overlay, never the entry point.

**Measured on real clouds, from an empty account** — Scaleway and OVH on
2026-08-19, Outscale on 2026-08-20. This is the evidence the release rests on.

| | deploy | `task cluster-verify` | idempotency | k8s | Talos | longest outage |
|---|---|---|---|---|---|---|
| Scaleway | ✅ 8 min 50, 72 resources | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 5 s (16 fails in 575) |
| OVH | ✅ | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 7 s (9-10 in ~540) |
| Outscale | ✅ 51 resources, then 17 | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 8 s (59 in 1179) |

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
the tfvars, so a later `cluster-up` does not try to revert. Longest outage 2 s
(13 fails in 577) — see [`upgrade.md`](upgrade.md) for why that does NOT establish
the leader-last fix: that run moved Talos only, the 5 s one also moved Kubernetes.

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
unproposed through their scheduled windows. The schedule is now daily; whether
that alone was the cause is [#88](https://github.com/dis-bzh/OpenAether-infra/issues/88).

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

**Not proven**: whether `v1.13.9` — the cloud root's own pin, unrelated to the
change above — has been through the same real-cloud upgrade evidence this page
records for `v1.13.7`→`v1.13.8`; the table stops one patch short of what is
currently pinned, and nothing here re-ran it. No lane has ever run unattended
to completion; nobody has
deployed under a non-empty `bucket_suffix`; and the failover — provider A treated
as gone, the cluster rebuilt on B from B's replica alone — has never been
attempted.

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

**Resume here**: the interruption regression, then rolling-replace's two blind
applies, then decide whether 0.1.0 ships a staging lane at all.
