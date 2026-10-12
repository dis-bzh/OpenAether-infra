---
name: release
description: How to cut an OpenAether release — what has to be proven first, what a version number is allowed to assert, and what the notes must admit. Use when tagging, writing release notes, or deciding whether a release is ready.
---

# Cutting a release

The authority is `docs/release-checklist.md` in OpenAether-infra — run it, do
not summarise it. It is not linked relatively here because this skill is shared
with OpenAether-apps, which has no such file. This is only what the checklist cannot tell you.

## A version number is a claim

A tag asserts that something was proven. The 1.x tags were cut before deploy,
idempotency and upgrade had ever been run on a real cloud — the very things they
were meant to certify — and every one of them, releases included, was deleted.
0.1.0 is the first number this project puts on something it measured. Decide what
the number asserts, prove exactly that, then tag.

**Say which rung each claim reached.** Mocked, emulated, local Docker, real cloud
once by hand, or unattended and repeated. "Proven at the real-cloud rung on
Scaleway, OVH and Outscale, never applied on real Proxmox hardware" is a release
note. "Proven" is a hope.

## The two repositories: a companion, not a pin

Infra's `envs/*.tfvars.example` and the `git_ref` default carry
`refs/heads/main`, on purpose (the comment above `variable "git_ref"` says why: a
tag default would make the repository undeployable between releases, and a branch
keeps two managements off the same `apps/clusters`). So nothing forces an order
between the two repositories, and the apps tag is not an input of infra's apply.
What infra does name is its **companion**: the release notes say which
OpenAether-apps tag `task apps-validate` (Cilium parity, skill parity, the Flux
DAG) passed against, and that a cluster which must be reproducible sets
`git_ref = "refs/tags/<that tag>"` in its own tfvars. A note can only name a tag
that exists, so tag and release OpenAether-apps first, then run `apps-validate`
from infra against a checkout of that tag, then tag infra. If a release ever makes
the examples pin it, the pinned ref has to exist before the thing pointing at it,
and that constraint belongs back in this file the same day.

## Order, and why

1. Everything in `§1`–`§7` of the checklist, on real clouds, **torn down**, with
   `scripts/ops/purge-orphans/` clean on each — except Outscale while the pre-fix
   Net of OpenAether-infra#43 exists: it cannot end clean, so read it as §6 says
   and never tick it clean. Nothing left billing.
2. Re-clone the **release commit**, before it is tagged, into a scratch directory
   and read it as a stranger: licence, changelog, examples, **no real tfvars in
   the archive** — and check that the quick start's commands exist and its values
   are accepted. Infra's `tags` ruleset blocks moving or deleting a tag, so a
   defect found after tagging cannot be re-cut away.
3. Tag it, then a GitHub release, with notes that name the limits.

## The notes must admit what is not fixed

Someone upgrading a cluster that matters will hit the open items before they hit
the features. Name them, say what happens, and point at the open issues. A
release note that only lists what works is a release note that will be believed
about the rest.

## Withdrawing a tag

Only when nothing was published under it — no release, no dependent tag — and
only by saying so in the changelog and the release notes. Anyone who fetched the
old tag gets different content under the same name; that is not something to
discover, it is something to be told.

**Reusing a number that has already carried a published release is a different
act, and a heavier one.** It rewrites what a version means for anyone who
already has it. If the scope has changed enough to justify starting over, the
honest move is usually a new number — a major bump for a breaking change of
scope, or dropping back below 1.0.0 to say plainly that the interface is not yet
settled. Reusing the same number twice teaches people the numbers mean nothing.
That is why the restart is **0.1.0** rather than the next 1.x: those numbers were
published and then deleted, and a first release that ships something proven
belongs below them, where the interface is plainly not settled yet.
