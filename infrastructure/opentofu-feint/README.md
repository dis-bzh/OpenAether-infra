# OpenAether — Emulated cloud fixture (Feint)

A real `apply` / `destroy` cycle against a **local emulator** of the Scaleway and
Outscale APIs — no account, no credentials, no bill. Driven by
`task feint-apply PROVIDER=scaleway|outscale`.

What this lane proves, what it does not, and the exact coverage wall:
**[`docs/emulated-cloud.md`](../../docs/emulated-cloud.md)**. Read that first —
this file only explains why the root exists separately.

> No backend (local, disposable state). Renders the bastion cloud-init from the
> shared `../opentofu/modules/providers/_shared/` template.

## Why a separate root rather than the cluster root

The real cluster root applies against the emulator too (`task feint-apply-root`,
see [`docs/emulated-cloud.md`](../../docs/emulated-cloud.md)). This root is kept
as a small, fixed set of shapes: CI applies it on every code PR, and
`.feint-evidence-*.json` pins the operations it drives. It is **not** a
deployable cluster and never will be: no Talos, no LB, no bootstrap.

## What the runner asserts

`scripts/dev/feint.sh apply <provider>` does init → validate → plan → apply →
**second plan must be empty** → destroy, and then:

- after apply, the machines are re-read **from the API**, not from the state — a
  state file that agrees with itself is not evidence that anything exists;
- the empty second plan is the real assertion: it holds only if every attribute
  the provider sent comes back identical, which is where an invented or dropped
  field surfaces;
- after destroy, the same ids (captured *before* the destroy) are asked for
  again. On Outscale a deleted VM stays readable as `terminated`, on the real API
  as here, so the check reads state rather than counting rows.

## What this fixture cannot carry

The list of limits lives in
**[`docs/emulated-cloud.md`](../../docs/emulated-cloud.md)**, under "Known gaps",
and is not repeated here — it used to be, and the two copies were already
wording the same limits differently. Pin: `FEINT_VERSION` in `scripts/dev/feint.sh`.

What is specific to this root rather than to the lane: it is reduced on
purpose. On Scaleway it leaves out shapes the emulator serves (LB, public
gateway, IPAM reservations, SBS data volumes, an explicit root `volume_type`)
so the operations `.feint-evidence-scaleway.json` pins stay the same;
`feint-apply-root` applies all of them except the data volumes (its tfvars
declare no `disks`). With no `volume_type`, the roots get the emulator's
default `sbs_volume`. The data volume is `l_ssd` because Feint refuses `b_ssd`
from 0.13.0, as the real API does.
