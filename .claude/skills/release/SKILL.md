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

## The two repositories: infra pins apps

Infra's `envs/*.tfvars.example` pin OpenAether-apps at a tag (`git_ref =
"refs/tags/0.1.0"` for infra 0.2.0), so a release of infra names the apps it was cut
with and an apps commit cannot change a cluster that follows the example. **The pinned
ref has to exist before the thing pointing at it**: tag and release OpenAether-apps
first, check that `git ls-remote --tags` prints the tag, run `task apps-validate` from
infra against a checkout of that tag (Cilium parity, skill parity, the Flux DAG), then
tag infra. Nothing pins the other way: apps does not know the infra version. The `git_ref`
default in infra is that tag too, so a tfvars that omits it follows the tag; set
`refs/heads/<branch>` to develop against apps. Flux is off by default and no infra
validation leg turned it on, so what the pin asserts is that the tag exists and
`apps-validate` passes against it, not that a cluster has reconciled it.

## Order, and why

1. Everything in `§1`–`§7` of the checklist, on real clouds, **torn down**, with
   `scripts/ops/purge-orphans/` clean on each — except Outscale while the pre-fix
   Net of OpenAether-infra#43 exists: it cannot end clean, so read it as §6 says
   and never tick it clean. Nothing left billing.
2. Re-clone the **release commit**, before it is tagged, into a scratch directory
   and read it as a stranger: licence, changelog, examples, **no real tfvars in
   the archive** — and check that the quick start's commands exist and its values
   are accepted. The `tags` ruleset of either repository blocks moving or deleting a
   tag, so a defect found after tagging cannot be re-cut away.
3. Tag it, then a GitHub release, with notes that name the limits. The tag is an **annotated, signed** tag made with
   the release key of the signer table in OpenAether-infra's `docs/signed-commits.md` (OpenAether-apps releases are
   tagged with the same key), pushed **before** the release exists, and the release is created against it. In this order:
   - `git tag -s -u <fingerprint> -m "<repository> <tag>" <tag> <release sha>` (`<repository>` is `OpenAether-infra` or
     `OpenAether-apps`);
   - the check of the tag, before anything is pushed, because a pushed tag cannot be moved or deleted in either
     repository (both have the same `tags` ruleset): in OpenAether-infra `./scripts/dev/check-release-tag.sh <tag>`
     (annotated, signer in the table). That script exists in OpenAether-infra only; in OpenAether-apps check by hand
     that `git cat-file -t <tag>` prints `tag` and that `git tag -v <tag>` names a fingerprint of the table;
   - `git push origin <tag>`.

   The `SBOM` workflow (started by the pushed tag) then creates the **draft** release and attaches the inventory. Read
   that run: publish with `gh release edit <tag> --notes-file notes.md --draft=false` only when its
   `Attach to a draft release` job is green (red scan jobs do not hold the attach; the steps and the fallback are in
   section 8 of the checklist, and in `docs/supply-chain.md` of OpenAether-apps). An immutable release takes no asset
   once published: never `gh release create` without `--draft` (infra #395). The notes carry the release commit SHA in
   full. A client checks it with `git verify-tag <tag>` (the public key is `docs/signers/release-vps.asc` of
   OpenAether-infra; compare its fingerprint with the table) and `git rev-parse <tag>^{commit}` against the notes.
   Immutable releases are on; no admin token is used in CI, so bypass actors are checked by hand each release
   (`check-required-checks.sh`, checklist section 8).

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
