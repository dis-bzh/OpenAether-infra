---
name: teardown
description: Destroying an OpenAether cluster and proving the account is clean — fleet-down, purge-orphans, and the per-provider traps that have left resources billing. Use when finishing a real-cloud run, when a destroy fails partway, or before changing anything the teardown path calls.
---

# Tearing down a cluster

The general discipline is the global `cloud-teardown` skill — read it for *why*.
This is the OpenAether commands and the traps this project has actually met.

## The sequence

```
task cluster-down PROVIDER=<p>                                        # computes, destroys nothing
task cluster-down PROVIDER=<p> PLAN=destroy-<role>-<p>.tfplan APPROVE=auto   # lands exactly it
python3 scripts/ops/purge-orphans/<p>.py
```

Same vocabulary as `cluster-up`: `PROVIDER=`, `ROLE=`, `PLAN=`, `APPROVE=`. The
dash-flags still work behind a bare `--` — `--force-no-edges` is a real escape
hatch and CI passes them — and anything spelled explicitly there wins, with
nothing synthesised on top of it.

**`--force-no-edges` is no longer needed on a pure-infra cluster.** `fleet-down.sh`
still refuses to destroy the management until it has accounted for CAPI child
clusters — a child that outlives its management bills for ever — but it now reads
WHY the query failed. "The server doesn't have a resource type" means the CRDs are
absent, and a management with no CAPI has no children by definition: it says so and
continues. Anything else — unreachable, unauthorized, timed out — is a question it
could not answer, and an unanswered question is not an absence: it still refuses,
quoting what the provider said.

The flag remains accepted and overrides that refusal. Until 2026-08-19 it was
required on every cluster this release builds, so the bare form refused and left
the cloud running — twice, on teardowns that were themselves trying to stop the
bill.

## Two commands, always — and who is allowed to run them

Destroying takes two deliberate commands and cannot be collapsed into one:

```
task cluster-down PROVIDER=<p> -- --plan                              computes, destroys nothing
task cluster-down PROVIDER=<p> -- --plan-file <f> --force-no-edges --yes    lands exactly that
```

`--yes`, `APPROVE=auto` and `TF_CLI_ARGS_destroy` are deliberately powerless on the first
step, and the second refuses a plan file that contains no deletions. The point is
that no single mistyped line, and no variable inherited from somewhere else, can
destroy a cluster.

**CI is allowed to destroy, and that is not a hole.** It was argued and settled:
a lane that cannot clean up is the billing defect this repository has already paid
for twice — seven VMs left running on 2026-07-28, ten Scaleway resources billing
while the check said "clean" on 2026-08-14. `if: always()` on the teardown exists
because the FAILED apply is the run that leaves resources standing, and the failed
run is the one nobody looks at. A CI that can `apply` can destroy anyway, so
"CI cannot destroy" would be a protection you believe you have.

What limits the blast radius is not the tool but the workflow and its credentials:
**if you do not want a destroy in an environment, do not put the job in that
environment's workflow**, and point CI at an account that only holds what it
creates. That choice belongs to whoever writes the pipeline, and the tool should
not make it for them.

## Per-provider, learned the expensive way

- **Outscale — never verify with the EC2-compatible endpoint.** `aws
  ec2 describe-instances` against `fcu.<region>.outscale.com` returned **0
  instances while the native `ReadVms` returned 7 running**. Use the native API;
  `scripts/ops/preflight-quotas.py` already carries the caller.
- **A wedged managed load balancer pins the network — and it is ONE mechanism, on
  BOTH clouds.** Measured on OVH 2026-08-18, and it explains the Outscale case
  that was only described before:

      port  owner=Octavia  status=DOWN  ip=10.0.0.35  name=octavia-lb-<id>
      DELETE /v2.0/lbaas/loadbalancers/<id>?cascade=true
        → HTTP 409 "Invalid state PENDING_CREATE of loadbalancer resource <id>"

  The managed LB reserves a VIP port **inside the customer subnet** the moment it
  is created — before its own backend exists. If the backend never attaches, the
  port stays DOWN, the LB stays in a transitional state, and the API REFUSES to
  delete a resource in that state. The port belongs to the provider, not to you,
  so you cannot remove it either. Subnet → network → teardown, all blocked behind
  a resource only the provider can clear. That is a support ticket, not a bug in
  this repository, and no retry count will change it.

  **What still works, and do it first:** the compute is not blocked. Destroy the
  instances, floating IPs and bastion — the bill is there. Expect the run to fail
  at the end on the subnet, and read that failure as "waiting on the provider",
  not as an incomplete teardown.

- **The provider contradicts ITSELF, and the ERROR is the truthful half.** Measured
  on Outscale 2026-08-18, on a Net with no VM, no volume, no EIP and no NIC left:

      ReadLoadBalancers        → 0          ReadNics → 0
      UnlinkInternetService    → "A load balancer is present on Net '{vpc}'"
      DeleteSubnet             → "The Subnet <id> is in use. It has NICs."

  This project's rule is "ask the provider, not the tool". It is not enough: the
  provider's LISTING said the Net was empty while the provider's REFUSAL named a
  load balancer and NICs that no listing returns. When the two disagree, believe
  the refusal — it is the side that actually holds the lock. A purge that only
  consults listings will report a clean account and leave one pinned for ever.

  Both clouds land in the same place: a managed load balancer leaves a remnant the
  customer cannot see and cannot delete. Nothing in this repository can lift it.
  Collect the two answers side by side, open the ticket, and move on.
- **The destroy races the provider.** Deletions propagate asynchronously;
  `fleet-down.sh` retries three times with a pause (`DESTROY_ATTEMPTS`,
  `DESTROY_BACKOFF`) and still fails at the end if the resource is genuinely
  stuck. Do not raise the retries to make a real failure green.
- **Local Docker cluster:** `task local-down`.

## Left standing on purpose

Talos images and their snapshots (rebuilding costs about an hour on Outscale),
keypairs, and the S3 buckets — state, artifacts, backups. Deleting a state
bucket destroys the ability to restore. `fleet-down.sh` step 3 lists them by
name rather than removing them; that report is the deliverable, not noise.

## Proving it

`scripts/ops/verify-provider-clean.py` and the purge scripts ask the provider,
not the state file. Report the counts. A session is not finished until something
that queries the account says zero. Both exit 0 clean, 1 leftovers found, 2
could not check (credentials missing, or an endpoint refused with nothing else
found); a purge `--apply` exits 3 when a deletion failed. A refusal next to
leftovers or a failed deletion takes their code: never 0, so it never reads clean.
On Scaleway, `verify-provider-clean.py <cluster> scaleway` reads the purge's own
listing, scoped to that cluster (the whole name: `edge-1` is not `edge-10`) plus
any detached IP or volume, block or instance API.

**And two ways that proof has lied.** A `| tail` on the purge output hid the
servers it lists first, so a populated account read as clean — never conclude
from truncated output. And an empty *server* list is not an empty account: seven
Scaleway block volumes billed for three days behind one. Ask for volumes too.

## Before you touch it

`scripts/dev/test-teardown.sh` is the harness, and it found the `--force-no-edges`
defect on its first run. Run it after any change to `fleet-down.sh`, and make a
new assertion fail on purpose before trusting it.
