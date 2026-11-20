# Availability contract — what is promised, what was measured, how many times

🇫🇷 [Version française](availability-contract.fr.md)

> 0.6.0 ("enterprise"). Rung: **real cloud, read from results that already exist** ([`resilience.md`](resilience.md), [`status.md`](status.md), the lab 0.5.1
> and 0.5.2 results). Nothing was re-run for this page. It is not an SLA and not a compliance claim.

## How to read it

- **Promise** = the target of [`resilience.md`](resilience.md) (owner decisions). It applies to the HA shape only: 3 control planes and at least 3 workers over
  three failure domains. A 1 control plane + 1 worker cluster promises nothing here.
- **n** = how many times that exact drill ran on that provider with the shipped settings (node grace 30 s, database toleration 30 s). Runs of earlier code
  are left out. A figure seen once is an observation, not an SLO.
- **Verdict** (a rule of this page, not a statistic: three runs give no percentile): **met** = n ≥ 3 and every run inside the target; **seen** = n of 1 or 2,
  inside; **missed** = at least one run outside, and what changed since is said; **not measured**.
- A provider incident inside a run (a stock-out, an instance that is ACTIVE but silent) is not a platform figure: it is named in the source section.

## The contract, by provider

| Promise (target) | Scaleway | OVH | Outscale |
|---|---|---|---|
| Database write gap, node lost (≤ 75 s) | **seen**: 67.1 s power-off, 68.6 s partition (n=1 each) | **met**: n=11, 49.3–74.7 s (hard reboot 4 runs 49.3–57.0; partition 6 runs 63.2–70.7; one run 74.7, inside by 0.3 s) | **missed**: 71.6 s (n=1), but 204.3 s with both plugin pods on the node (n=1); the spread of the plugin pods is fixed offline, not re-run |
| Database write gap, zone lost (≤ 150 s) | **seen**: 62.8–79.0 s (the source gives no run count) | **met**: n=3, 48.9–77.5 s | not measured |
| Database write gap, primary killed or OOM (≤ 30 s) | **seen**: 9.8 s, 10.3 s (n=1 each) | **seen**: 10.8 s, 5.5 s (n=1 each) | not measured |
| Acknowledged commits lost (zero) | **met**: 0 in 9 runs (lab 23) | **met**: 0 in every drill of labs 27B and 28 (about 15 runs, not tallied) | **seen**: 0 (n=1) |
| HTTP through the app load balancer (longest failed run ≤ 15 s, failed samples ≤ 10 %) | **missed** in lab 27: partition 12.5 % / 14 s, zone 9.2 % / 11 s; the health check changed since, **not re-measured** | **met** in lab 28: n=10, at most 7.4 % / 7 s (lab host); one 13 s run from inside the cluster is the accepted exception. Lab 27B, before the change: 3 of 6 missed | **seen**: 5.9 % / 3 s (n=1) |
| API gap, control plane lost (`/readyz` ≤ 15 s in total) | **missed** for a roll: 20 failed of 1054, longest run about 55 s (lab 0.5.2, n=1, infra #42 stays open); partition of the etcd leader 8 of 311, longest 2 s (n=1) | **met**: 9 s, 9 s, then 11 of 310 failed (n=3) | **missed**: 19 failed in 64 s (n=1); the load-balancer check was shortened, **not re-measured** |
| RWX writer gap (accepted up to about 100 s) | **missed**: 89–171 s (lab 27, before the owner decision of 2026-10-30) | **met**: 68, 75, 87, 97 s (n=4) | not measured |
| Replace a dead worker, time to Ready (**no target**) | 378 s and 792 s (n=2) | 781 s with a 331 s provider incident inside, about 450 s without (n=1) | not measured |
| Gray failure, slow and lossy node (**no promise**: a known limit) | write gap 88–134 s (n=1) | 103.7–299.3 s (n=2) | not measured |

Read the table by its worst cell: only the **OVH** column has anything at n ≥ 3, and only for the database, the zone, the API and the RWX gap. Scaleway is one
sitting deep on most rows and **Outscale is one lab on a 20 vCPU quota** (`capacity.md`): neither carries a promise today beyond what the cell says.

## What it does not cover

- A single-replica application: its availability is the time to reschedule it and re-attach its volume (below), not a promise.
- Proxmox (no cloud lab), a non-HA topology (1 control plane), a gray failure, and the provider's own incidents (stock-outs, snapshots that take 17 minutes
  to become available, an instance that is ACTIVE but never answers): [`resilience.md`](resilience.md) records each as it happened.

## Client applications with a RWO volume

**Recommendation, not a platform setting:** give a pod that must move off a lost node the two tolerations the platform already gives its databases.

```yaml
tolerations:
  - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30}
  - {key: node.kubernetes.io/not-ready,   operator: Exists, effect: NoExecute, tolerationSeconds: 30}
```

Without them Kubernetes adds 300 s: the forge was away 471.8 s after a zone cut (Scaleway, n=1). What it buys, measured on the forge (one pod, one RWO volume):

| Setting | Forge away | n |
|---|---|---|
| default 300 s | 471.8 s | 1 (Scaleway) |
| 30 s, Longhorn policy `do-nothing` | 341–372 s | 2 (Scaleway) |
| 30 s, the shipped Longhorn policy | 85–197 s | about 11 (OVH 9: 85–197 s, Scaleway 2: 174, 178 s) |

So: **expect minutes, not seconds**, because the volume attach waits for the old node's detach; the toleration only moves the start of that wait from 300 s to 30 s.
Do not go below 30 s: the node grace is 30 s, a lower value evicts on a node that merely missed a heartbeat (30 minutes at 30 s: 0 flaps, one soak, OVH).
Two replicas on a database or a stateless app are what make a node loss invisible; a RWO volume does not.

## Keeping it true

A cell changes only from a lab result, with the date and the section it came from; a new run raises n or moves the verdict. The cells to move first in the
0.6.0 Scaleway lab: node loss and zone loss twice more (to reach n=3), the HTTP probe after the health-check change, and the API gap of a roll with the probe of lab 21.
