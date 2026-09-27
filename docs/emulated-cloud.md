# Emulated cloud (Feint) — testing Scaleway and Outscale without an account

🇫🇷 [Version française](emulated-cloud.fr.md)

[Feint](https://github.com/stephrobert/feint) is a local emulator of the
Scaleway, Outscale and Exoscale APIs: one static Go binary on
`127.0.0.1:4599`, no account, no bill. This repository points the **real**
Scaleway and Outscale provider binaries at it, so the provider talks real HTTP to
a real API with no credentials in scope.

That is one step past what we had. `task validate` checks syntax; `task test`
mocks the provider and never leaves the process; `task local-up` exercises
`modules/talos` on Docker but no cloud provider module at all. Outscale in
particular had **no apply-mode coverage of any kind** before this.

Feint's own coverage and limits are documented upstream — read them there rather
than here, they move: [`docs/limits.md`](https://github.com/stephrobert/feint/blob/main/docs/limits.md).

## Running it

```bash
task feint-up                          # start the emulator (installs the pinned binary if absent)
task feint-plan       PROVIDER=scaleway  # plan the REAL cluster root, no credentials
task feint-apply      PROVIDER=outscale  # apply/destroy cycle on the reduced fixture
task feint-apply-root PROVIDER=scaleway  # untargeted apply/destroy on the REAL cluster root
task feint-record     PROVIDER=scaleway  # rank what our module calls and no pack serves
task feint-test                        # both providers, plan + apply
task feint-down

task feint-evidence PROVIDER=scaleway  # needs Incus: apply under a real machine runtime, then
                                        # print what a baseline of feint's own proof would pin (#151)
task feint-evidence-verify PROVIDER=scaleway  # check a fresh capture against the pinned baseline
```

## Four lanes, because one cannot do all four jobs

**`feint-plan` — the real `cluster` root, plan only.** Real modules, real
provider, `envs/feint-<provider>.tfvars.example`. The script itself still only
plans, but the reasons it used to stop there are gone as of Feint 0.12.0 — see
`feint-apply-root` and `feint-record` below, which now apply the same root end
to end.

The root declares a partial S3 backend, so the lane drops a local-backend
`*_override.tf` in and removes it on exit.

**`feint-apply` — `infrastructure/opentofu-feint/`, a real CRUD cycle.** A
separate root (same idea as `infrastructure/opentofu-local`) carrying the same
shapes over the subset the emulator does serve: init → validate → plan → apply →
**empty second plan** → destroy, with existence and disappearance both re-read
from the API rather than from the state. See its
[README](../infrastructure/opentofu-feint/README.md).

**`feint-apply-root` — the real `cluster` root, untargeted apply.** Same root
and tfvars as `feint-plan`, but a full `tofu apply` (Phase 1:
`talos_bootstrap = false`, already the setting in both
`envs/feint-<provider>.tfvars.example`) — VMs, networking, LBs, everything
`feint-plan` only plans — followed by an empty second plan and the two-step
destroy the [root README](../infrastructure/opentofu/cluster/README.md#teardown-destroy)
documents (machine secrets carry `prevent_destroy`, so `tofu state rm
module.talos.talos_machine_secrets.this[0]` first, then `destroy -var
talos_bootstrap=false`). Closes issue #76's first criterion: 27 resources on
Scaleway, 41 on Outscale, second plan empty, destroy clean — both providers,
measured 2026-08-31. `feint-record` below proved the provider module alone
applies end to end; this is the whole root, not just that module.

**`feint-record` — measure the wall instead of arguing about it.** `feint proxy`
sits between the provider and the emulator and writes one redacted JSON object
per exchange; `feint transcript` then ranks the operations no pack serves,
most-called first. Underneath, this runs a real `tofu apply
-target=module.<provider>` on the cluster root itself — the same root
`feint-plan` only plans — through the proxy, and the apply used to be
*expected* to fail on the first unserved call.

**Closed as of Feint 0.12.0** (re-measured 2026-08-31, both providers):
*"every operation the client called is served by a pack"* — zero unserved
calls, where the 0.7.3 recording below listed three. The apply this measures
now completes end to end on both providers' modules, which is proof the real
cluster root's provider module can be applied against the emulator, not only
planned (see `feint-plan` above). What used to fail and what it moved to is
kept in "Known gaps" below, since it is history now rather than a current
limit.

Upstream here is the emulator, not the cloud. A client that signs the host it
was configured with — the Terraform provider does — cannot be recorded against a
real cloud through a plain reverse proxy, since the cloud checks the signature
against its own name and answers 401. Feint 0.7.0 solves that other half
separately, with `feint shapes` and a per-provider signer; this lane deliberately
stays the credential-free one, and answers *what we call that is missing* rather
than what the real cloud returns.

## The guard

Feint's own repository once created a billable server because a redirection
evaluated to empty and the client fell back to the operator's stored profile.
Every official cloud client does that. So:

- `emulator_api_url` (and the fixture's `endpoint`) **only accept a loopback
  URL** — a remote value is a validation error, not a warning;
- `scripts/dev/feint.sh` refuses a non-loopback endpoint and unsets every
  `SCW_*` / `OSC_*` variable before running anything;
- when the emulator is active the provider blocks **pin** fake credentials, so
  the provider cannot go looking for real ones.

## What it proves, and what it does not

**Proves**: the provider configuration is accepted and the whole graph resolves
with no credential; a real create/read/update/delete cycle over the served
subset; and, through the empty second plan, that every attribute sent comes back
identical — which is where an invented or dropped field surfaces.

**Does not prove that a real deployment works.** The emulator has no inventory:
an image id or machine type that exists nowhere is *accepted*, where the real
cloud refuses. No load balancer, no gateway, no quotas, no latency, state
transitions are instant, and authentication is never verified. Real cloud remains
the only proof of a deployment; this catches wiring regressions before spending.

## Known gaps

Pinned to **Feint 0.13.0** (`scripts/dev/feint.sh`). What this lane still cannot
carry, all recorded in [the open issues](https://github.com/dis-bzh/OpenAether-infra/issues):

| Not exercised | Why |
|---|---|
| Scaleway private NIC destroy, provider ≥ 2.83.0 | The provider then calls `instance/v2alpha1/.../detach-private-network-interface`, which Feint answers 501 (still on 0.13.0). The lanes that destroy (the fixture, and `feint-apply-root` through its override) cap the provider below 2.83.0; the real root does not (#179). |
| Outscale image name resolution | The Outscale tfvars point `image_name` at a fixed catalogue entry, which exercises the lookup mechanism without resolving a name our own pipeline published — see #150 for what it would take. |

Three things left this list first. `outscale_volume_link` in 0.6.0, which
mounted the `LinkVolumeVmIds` filter its wait depends on. `data.outscale_images` in 0.7.0,
which stopped segfaulting the provider — so the Outscale lane now resolves its
image through the data source rather than a pinned id, exercising the
`images[0]` shape the module had carried as an unverified assumption. And
`CreateTags` in 0.7.1 (our issue #99): the prefix table held four kinds against
sixteen the pack minted, so tagging an `igw-` or an `rtb-` was refused on a
resource the emulator had just created. The fixture tags six kinds now rather
than putting back the three it had removed — a table that fell behind once
should be exercised on more than the row that caught it.

Three more left it at 0.12.0, measured 2026-08-31, and this table had called
all three permanent. **Outscale load balancers**: `CreateLoadBalancer` and
`UpdateLoadBalancer` now answer 200 — labelled here as "declined on purpose...
this one will not move" right up to the release that moved it.
**Scaleway IPAM reservations**: `ipam/v1/API.BookIP` now answers 200, not the
`501` this table called a permanent decline. **Scaleway LB and public
gateway**: every `lb/v1/ZonedAPI.*` route the module calls (`CreateLB`,
`CreateFrontend`, `CreateBackend`, `AttachPrivateNetwork`…) now answers 200 —
the two gaps this table called "genuinely absent". `feint-record`'s own apply
(above) is what caught all three: an apply of the real cluster root's
provider module, both providers, completing with zero unserved calls where
0.7.3 stopped hard on the first one.

Scaleway's half of image name resolution closed the same day, not from a
feint version but from `scripts/dev/feint.sh` registering an image under the
name `envs/feint-scaleway.tfvars.example` asks for, before planning or
applying: `data.scaleway_instance_image.talos`, dead code behind a pinned
`image_id` until then, now runs for real, and both `feint-plan` and
`feint-record` resolve it — the latter's transcript shows the module calling
`instance/v1/API.ListImages` and `GetImage` for the first time (#150).
Outscale is not: its tfvars still point `image_name` at a catalogue entry
rather than something this lane created.

The Scaleway root volume type row was stale well before it left: the cluster
root applies the module's `root_volume { volume_type = "sbs_volume" }`, so the
2026-08-31 `feint-apply-root` run above (0.12.0) had already applied it and
re-planned empty, where the row said `sbs_volume` planned for ever. The row
went on 2026-09-26, after the same result on 0.13.0 with provider 2.82.0.
