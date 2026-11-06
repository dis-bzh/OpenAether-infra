# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file used to document 1.0.0, 1.0.0-withdrawn and 1.1.0. Those tags and
releases were deleted from both repositories and none of them ever worked; a
changelog listing releases nobody can obtain is not a changelog. That history is
in git. 0.1.0 is the first entry describing something proven.

---

## [Unreleased]

## [0.4.3] — 2026-11-05

0.4.3 is a **security-hygiene release**, the infra half of the pair with OpenAether-apps 0.4.3 (apps is tagged first; its scope, among it the forge `//metrics` fix, is in its own CHANGELOG, `[0.4.3]`). What this repository changes at runtime is **one thing: Flux 2.9.6 to 2.10.0**, for brotli-libs CVE-2026-111497 (Critical, in the CISA KEV catalog since 2026-10-27) in the `kustomize-controller` image of 2.9.6, fixed in the 2.10 line only (2.9.6 is the last 2.9 release; infra #444, to be closed by this release once the tag-run scan of the v1.10.1 image is green: see Known open items). The pin is `FLUX_VERSION` (`scripts/bootstrap/render-bootstrap-manifests.sh`, `scripts/setup.sh`, the Flux CLI step of `ci.yml`), the vendored `flux-install.yaml` (its commit records it byte-identical to the v2.10.0 release asset), `flux-image-digests.lock` and `upstream-artifacts.lock`. **No OpenTofu logic changed**: no resource, no module, no variable but the default of `git_ref`; no Talos, Kubernetes or provider version moved. **The move onto a running cluster is two commands, not one** (below). Smaller: two test harnesses (`test-cluster-bootstrap-sync.sh`, `test-pins-verify.sh`) derive their Flux fixture versions from the pin (a hard-coded v1.8.5 meant "one minor behind" until the pin reached 1.10, then meant two, and 13 cases of the first and 2 of the second went red); the shared `release` skill's signed-tag step now covers both repositories, and its two copies (this repository's and OpenAether-apps') are byte-identical, checked with `cmp` (#445); the layer table of the two READMEs says Flux v2.10.0; `docs/upgrade.md` and its French twin have "From 0.4.2 to 0.4.3". The version cut moves the apps pin: the `git_ref` default and the twelve `envs/*.tfvars.example` now pin OpenAether-apps `refs/tags/0.4.3` (they pinned `refs/tags/0.4.2`), and the tftest assertion on the rendered GitRepository follows, so the examples, `variables.tf` and the test agree.

**What the proof covers, stated once for the whole entry.** Every cloud figure below is Scaleway, 3 control planes + 6 workers POP2-4C-16G + a bastion, fr-par-1/2/3, one run per figure (n=1), with Flux following a MOVING branch ref (`refs/heads/claude/0.4.3-rc1`), NOT the tag; not a compliance claim. It covers exactly infra d1d268c and apps e8ca37f. The release tags differ from those heads by the version cut, the docs and this file only (in this repository: the apps pin above, the two READMEs, `docs/` and this file; `git diff --stat d1d268c..<release head>` is stated at the cut, and this entry is corrected if it differs), so **a tag-pinned install or move is NOT proven**. The date of the heading, 2026-11-05, is the day of the proof and of this draft, not the day of a tag: it is provisional until the tag is pushed. Durations are NOMINAL unless said INCIDENT, always with the cluster shape (3 CP + 6 W); WORSE is at least 10 s and at least 10 % worse than the stated baseline, "at the edge" within the resolution of about 6 s; BETTER only without INCIDENT time and with the whole window observed. Baselines are named by what measured them: the first, second and third proof labs of 0.4.1 (labs 29, 30 and 31) and the 0.4.2 retest (lab 32), all Scaleway, 3 CP + 6 W.

**Upgrade path: 0.4.2 to 0.4.3 only** (previous release, the policy before 1.0.0). **Two commands, in this order: `task cluster-bootstrap-sync PROVIDER=… ROLE=…` (a dry run that exits 3 while a controller differs from the pin), then the same with `APPLY=1`; then `task cluster-up PROVIDER=… ROLE=…`** with `git_ref = "refs/tags/0.4.3"` in the tfvars (the examples carry it; a tfvars that leaves `git_ref` unset inherits the new default). `cluster-up` never touches the Flux controllers of a running cluster (by reading the code: it has no Flux step and its closing message says so), so without the first command they would stay at 2.9.6 and `cluster-verify` would be red on "Flux controllers run the pinned version": a reading, not run (`cluster-verify` was seen red on a controller one patch behind its pin in the first proof lab of 0.4.1, and `cluster-up` without the Flux step was not run). The steps, the guidance when the apply stops part way and what the 2.10 release notes change against this platform are in `docs/upgrade.md`, "From 0.4.2 to 0.4.3" (and its French twin). The Talos and Kubernetes pins are the same as in 0.4.2 (v1.14.4, v1.37.1): no node rolls. **What the lab showed (cluster A, the 0.4.2 tags to the heads, branch ref):** the dry run took 20 s and exited 3, listing the seven controllers one minor behind and "the API server accepts 43 object(s)"; `APPLY=1` took 27 s wall, NOMINAL, 9 s of it from the server-side apply to the end of the seven rollouts (the first move of all seven controllers by that command, one minor; it had run before on one controller put one patch behind by hand, 5 s, in the first proof lab of 0.4.1); the controllers came up on the new set, spec image AND pod imageID equal to `flux-image-digests.lock`; 15 CRDs established (`alerts` and `providers` serve `v1` and `v1beta3`, storedVersions `v1beta3,v1`); the HelmRelease histories were identical before and after; no probe failed. **The transient to expect: about 2 minutes after the sync. 7 HelmReleases `SourceNotReady` for 29 to 31 s and `ztunnel` `DependencyNotReady` (on `istio-cni`) for 60 s, 10 Kustomizations not Ready, the last one Ready again about 2 minutes after the sync;** no probe failed during it. **The cause of the transient is not established.** Two readings exist and neither was tested: a node-local Flux restart makes every HelmRelease resolve its source again, or the new `source-controller` fetches the artifacts again. The same cluster then took ONE `cluster-up` (below). **The CAPI-child Flux copy stays at 2.9.6**: the vendored `cluster-api-clusters/flux-gotk` of OpenAether-apps is the copy that apps #103 moved from 2.8.8 to 2.9.6; it still carries the same `kustomize-controller` finding, this move does not touch it, #103 does not cover 2.10 and a new issue is drafted, not filed. **Not shown: the move from `refs/tags/0.4.2` to `refs/tags/0.4.3` itself**, the one you will run: the tag does not exist until the release and the lab followed the branch.

**Cloud proof of the 0.4.3 heads (two clusters, 2026-11-05; the rung is the paragraph above).** Cluster A: an install at the released 0.4.2 tags with the forge brick on, then the move to the heads, the Flux step first and ONE `cluster-up` after. Cluster B: a fresh install at the heads, the forge brick on by the documented live patch at rc 0. No hard stop: no acknowledged write lost, no body of the forge `/metrics` after the fix, no refused Flux CRD. Some figures are WORSE and are listed after the bullets.
- **Cluster A, the arm (the 0.4.2 tags, forge on).** T0 to rc 0 11 min 25 s INCIDENT (the known LB-ACL trap, #361; the second invocation alone 7 min 24 s NOMINAL against 7 min 33 s, 7 min 15 s and 7 min 07 s of earlier labs: SAME); the first day after rc 0 3 min 37 s NOMINAL (the 0.4.2 retest 3 min 18 s: SAME; the second proof lab of 0.4.1 2 min 44 s: **WORSE**, +32 %); 41 of 41 Kustomizations Ready 9 min 45 s after rc 0 (the 0.4.2 retest 9 min 43 s: SAME, but that figure is itself not like for like, because its `cnpg` Kustomization passed its health check with the Clusters still empty and released the dependents early; against the first three proof labs of 0.4.1, the like-for-like comparison, it is lower and not called BETTER); `cluster-verify` 29 passed, 0 failed; the forge pod Ready 79 s after the live patch (NOMINAL, 3 CP + 6 W); requested CPU 249 % of one worker's allocatable for the platform alone and 286 % with the forge and the two fixtures (`lab27-ha`, `lab27-light`; the four writers run on the control planes and are not in this workers-only figure) (the lab's E8 figure). `PLAN_ONLY=1` with the move tfvars 1 min 50 s NOMINAL (the 0.4.2 retest 1 min 52 s: SAME): `0 to add, 3 to change, 0 to destroy`.
- **Cluster A, the Flux step** (above): after it `cluster-verify` read 33 passed, 2 failed, the two being the apps-ref lines the next step closes (the tfvars already declared the new ref); its "Flux controllers" line was green on the new pins (it was already green on the old pins). The seven controllers: helm 1.7.1, image-automation 1.3.0, image-reflector 1.3.0, kustomize 1.10.1, notification 1.10.0, source 1.10.1, source-watcher 2.3.1.
- **Cluster A, ONE `cluster-up` after the Flux step (the apps ref moves): rc 0 in 13 min 05 s NOMINAL, WORSE than the 10 min 30 s of the 0.4.2 retest (+2 min 35 s, +24.6 %), cause NOT established.** A host-load explanation (the 2-vCPU lab host also ran the observers) is a hypothesis only and is not shown. The load of the pre-move plan-only run (1 min 50 s) and of the 3 min 10 s run was not archived. The same plan-only command repeated at 12:36:52, after the observers were stopped, took 1 min 43 s (SAME as 1 min 45 s), with load averages 2.54 / 4.95 / 5.06 before and 2.61 / 4.25 / 4.79 after: that points to host load for the post-move plan-only figure, it does not isolate it, and the 13 min 05 s of the move had no load record. The move is not like for like with the retest (this move also changes Flux, Zitadel, the Grafana sidecar, Forgejo and the Jobs). 43 of 43 Kustomizations Ready 3 min 34 s to 3 min 40 s after the ref switch (the 0.4.2 retest 4 min 05 s, the first proof lab of 0.4.1 3 min 49 s: SAME; those baselines are 41 Kustomizations without the forge, this cluster has 43 because the forge brick is on); the `cnpg` Kustomization was `DependencyNotReady` for about 2 minutes (the dependency cascade of a ref move), and **the `cnpg` health gate was NOT exercised by this move** (no Cluster changed); istiod ×2 and the three Gateway pods kept their names and restartCount 0; no node rolled. `PLAN_ONLY=1` after the move 3 min 10 s against 1 min 45 s (the 0.4.2 retest): WORSE, cause not established (the repeat after the observers stopped took 1 min 43 s: SAME).
- **Cluster A, the workloads the move changed.** Zitadel v4.19.5 to v4.20.1: setup Job 19 s (only `projection_tables`, six repeatable steps and `79_backfill_unique_constraint_owners`), HelmRelease Ready 4 min 15 s after the ref switch (lab 24, 0.3.2, Scaleway 3 CP + 4 W, 4 min 12 s: not like for like, SAME at the edge), pins equal to the declared digests, no pod left on v4.19.5, a session created before the move reads back, the personal access token works, TLS 1.3 to CNPG works, authorize 302 then loginname 200; one 503 on 1 of 2,188 Zitadel probes between 12:03:14 and 12:21:40, cause not shown. The Jobs on alpine/k8s 1.36.6: both vault Jobs were re-created by force inside the TTL (new uids); five of the six alpine/k8s CronJobs (`backup-verify`, `cnpg-dump-load-restore-test`, `cnpg-recovery-restore-test`, `cnpg-store-replicate`, `openbao-escrow-check`) and `etcd-snapshot` were run by hand and ended Complete; `cnpg-pitr-restore-test` was not run, and the escrow check attested nothing (development bootstrap: "no escrow to attest"). The Grafana sidecar 2.14.3: a 61 s roll, restarts 0, a ConfigMap labelled `grafana_dashboard` hot-reloaded, `up` 4 of 4. Forgejo 15.0.11: six of six containers on the new image.
- **Cluster A, zero loss.** 226,978 acknowledged ids over 4 writers (zitadel-db direct, lab27-ha direct, lab27-ha through the Pooler, lab27-light), ids kept outside the cluster, **0 missing**; longest gap between acknowledged writes 2.77 s (the 0.4.2 retest 1.26 s, the third proof lab of 0.4.1 0.53 s: under the 10 s floor, SAME); 2 in-cluster API probe failures (one 3.0 s gap). After the move: 5,000 seed rows with the same md5 on both product databases, OpenBao `secret/lab27/seed` still at v1.
- **Cluster B, a fresh install at the heads (forge on).** T0 to rc 0 18 min 17 s **INCIDENT over 4 invocations** (a worker created `stopped` in fr-par-3, `out of stock` twice, the LB-ACL trap): **WORSE** than 10 min 13 s, 10 min 54 s and 12 min 56 s (+79 %, +68 %, +41 %), provider capacity and a known trap, not a product claim; the third proof lab of 0.4.1 (20 min 25 s) had the same two incident classes. The Talos image was built in this run (44 s). **Flux 2.10.0 from the Talos inline manifest:** 7 of 7 controllers, spec image AND imageID equal to the lock; 15 CRDs established, storedVersions `v1`; `cluster-verify` 32 passed, 0 failed, then 33 / 0, with the "moving ref" warning. Zitadel at v4.20.1 on an empty database through Flux: init 7 s, setup 22 s, 170 migrations, `status.failed` 0, no hook stuck, HelmRelease Ready 1 min 07 s (no baseline exists for a first install at this version). The `cnpg` gate, an OBSERVATION (n=1) and **NOT a proof that the race of the 0.4.2 retest is fixed**: the gate waited ("Health check passed in 6m0.4s"), `cnpg` Ready 1 s after the last Cluster (the retest lost the race: Ready in 40.75 s with empty Clusters); Clusters 3 of 3 at 5 min 39 s and 6 min 05 s after `cnpg` Progressing (5 min 50 s to 6 min 13 s before: SAME); 41 of 41 Ready 9 min 52 s after rc 0 (SAME as 9 min 43 s, which is itself not like for like, above; lower than the proof labs of 0.4.1, not called BETTER, with a known 62 s `observability-vm-customresources` fault inside the window and an unobserved first 1 min 21 s); Grafana restarted 3 times on a replica race for its first migration lock (`failed to obtain lock` ×2, `duplicate key` ×1, no `connection refused`). The first day 1 min 22 s NOMINAL (2 min 44 s to 4 min 00 s before: BETTER by the rule, cause not isolated; the host load may have differed, which is not shown: the 1-minute load average on B's lab host was 1.18 at the start of the window and 0.71 at its end, and A's day-1 load is not archived); requested CPU 259 % of one worker's allocatable for the platform and the forge, 283 % with the `lab27-ha` fixture added (workers only: the two writers run on the control planes and are not in these figures). Zero loss: 64,209 acknowledged ids on 2 writers (zitadel-db direct, lab27-ha direct), 0 missing, longest gap 0.73 s; no failover was run, so **no split-brain test**.
- **The forge `//metrics` security fix is in OpenAether-apps, not here, and so is the correction of an earlier sentence.** Found by the first sweep that included the forge host: on a 0.4.2 cluster with the forge brick on, `https://forge.<domain>//metrics` and four more spellings answered 200 with the forge's Prometheus metrics (about 11 KB, 66 families; no repository content or credential seen), and the sentence of the OpenAether-apps 0.4.1 and 0.4.2 entries that no spelling served metrics, like the claims quoted in the two correction lines of these infra entries below, covered the four hosts they swept (Grafana, Zitadel, OpenBao, a test application) and was false for the forge, which those labs did not deploy. Fixed in 0.4.3 by three layers (istiod path normalisation, two more policy paths, a bearer token on the forge `/metrics`); after the move 540 probes gave 310 × 403 and **0 bodies, run twice with identical results**; on the fresh install of cluster B 540 probes, 0 bodies. The facts, the limits and the correction note are in the apps `[0.4.3]`; a pointer line is added to `[0.4.2]` and `[0.4.1]` below.
- **The forge upgrade, 0.4.2 to 0.4.3 with the forge on (cluster A):** the vault Jobs were re-created by Flux inside the TTL and wrote `secret/forgejo/metrics`; both ExternalSecrets synced, the forge pod rolled with **0 s in CreateContainerConfigError observed** (watch resolution 1 to 3 s; both Secrets existed before the new pod was first seen); forge-away window **50.3 s NOMINAL** (last ok to first ok; 49 probe failures); scrape gap 65 s, back with no manual step; 1,284 acknowledged pushes, 0 missing, fsck clean. **That order was favourable by 76 s and nothing enforces it.** The unfavourable order was tested on cluster B (3 CP + 6 W), **INCIDENT, induced in the lab**, not a natural sequence: Flux was suspended on the root and the `forgejo` Kustomizations, the ExternalSecret was pointed at a missing OpenBao key, the Secret was deleted and the Helm upgrade was triggered by an environment variable (attempt 1, with only the `forgejo` Kustomization suspended, was reverted by Flux after about 65 s and is not the figure; attempt 2 is). With the forge Secret unavailable during that Helm upgrade the pod waited **6 min 30 s** (INCIDENT, induced) in CreateContainerConfigError, the HelmRelease reached UpgradeSucceeded with NO rollback (`timeout: 15m` is set in 0.4.3), the Deployment kept its `GITEA__metrics__TOKEN` reference in 37 of 37 polls and the pod started by itself **19 s** (INCIDENT, induced) after the Secret came back; `up{forgejo}` was 0 for about **7.5 minutes** (INCIDENT, induced) and no alert exists for the forge scrape. On the fresh install the live patch came 14 s BEFORE the vault Jobs were first created (favourable by construction); the pod started at the first try.

**WORSE rows, stated plainly and listed for the owner's re-decision at the gate; none is a claim of a product regression and none is hidden:**

1. The apps-ref move of cluster A: **13 min 05 s NOMINAL against 10 min 30 s (+24.6 %)** (also +96 % and +84 % against the 6 min 41 s and 7 min 06 s moves of the 0.4.1 proof labs, which are other moves; segments against the 0.4.2 retest: launch to ref moved 10 min 22 s against 8 min 55 s, +16 %, and ref moved to rc 0 2 min 43 s against 1 min 35 s, +72 %), and the plan-only run after it, **3 min 10 s against 1 min 45 s** (1 min 43 s when repeated after the observers stopped); cause not established (the load hypothesis above is unproven).
2. T0 to rc 0, INCIDENT: cluster A 11 min 25 s against 10 min 13 s (+11.7 %); cluster B 18 min 17 s against 10 min 13 s, 10 min 54 s and 12 min 56 s (the provider stock-out and the known LB-ACL trap #361).
3. The first day after rc 0: 3 min 37 s (cluster A, the arm) against 2 min 44 s (+32 %), and +70 % against 2 min 08 s in the first run of cluster A, which was stopped at the arm by the forge `//metrics` finding, at the same 0.4.2 tags.
4. Restarts after the install: **21 on cluster A and 15 containers + 3 init-container restarts = 18 on cluster B, against 10 in the third proof lab of 0.4.1** (+110 % on A; on B +50 % counting the 15 main-container restarts only and +80 % with the init containers, 18); the 0.4.2 retest had 34 and OVH 26, higher. On B the 3 init-container restarts are those of the `bootstrap-controller` of the two `lab27-ha-pooler-rw` pods (2 and 1), OOMKilled at its 64Mi limit and recovering by itself (a lab fixture, the optional `cnpg-profile-pooler` component; no data effect). Whether the older count included init containers is unknown.
5. A provider incident of this lab: a Scaleway fr-par-3 POP2-4C-16G stock-out blocked one attempt for 33 minutes (11 `cluster-up` attempts, no cluster built); not a product claim.

**Not proven, or not fixed (stated, not hidden):**

- **A tag-pinned install or move** (the proof followed the branch ref; the tags differ from the heads by the cut only, and that diff is stated at the cut).
- **Flux 2.10.0 as a version string on a live object**: no object carries it; what is proven is that the seven component digests (spec image and imageID) equal `flux-image-digests.lock`. The refusal paths of `cluster-bootstrap-sync` (a refused CRD, a rollout timeout) were not run, and a Flux rollback has no test.
- **The tag-run scan of the Flux kustomize-controller v1.10.1 image** was not run; infra #444 stays open until it is green (see Known open items).
- **The Grafana MFA sign-in** (`grafana-oidc` stays in `SecretSyncedError`, an empty `client_id` on a fresh install: known); **failover and zone drills**, so there is no split-brain test in this release.
- **The unfavourable forge order beyond 15 minutes** (a wait longer than the `timeout: 15m` is not shown; that Helm's default of 5 minutes would have rolled back is reasoning, not run); **the Jobs created fresh after the TTL expired** (the move came inside the TTL), and **the fresh-install case where a vault Job is still running when the forge is enabled** (cluster B enabled it 14 s before the Jobs were first created); **`cnpg-pitr-restore-test` by hand** and the Longhorn canary and restore test (not deployed on this profile); **the `cnpg` gate on a move that changes a Cluster** (cluster A changed none; cluster B is one observation).
- **The forge `//metrics` fix, its limits:** the policy layer was never alone on a cluster (only on the local rig); **a 0.4.1 cluster with the forge brick, swept** (not run: 0.4.1 is INFERRED exposed, from the empty `git diff 0.4.1..0.4.2` under `apps/` and `scripts/` of OpenAether-apps, a read-only check; only the 0.4.2 tags were run); the redirects the sweeps did not follow (first hop only: 159 of 540 probes answered 301, 302, 303 or 307 in each after-move sweep of cluster A and in cluster B's, 114 × 301, 22 × 302, 22 × 303 and 1 × 307; at the arm 257 of 540, 196 × 301, 33 × 302 and 28 × 303); the `%2F`, `%5C`, case and `;param` spellings, which reach the services as written, beyond the first hop (no body seen); the Longhorn opt-in route and Zitadel's `/debug/metrics` body; a request path with `//` now reaches a service merged, so a route whose service gives `//` a meaning would change behaviour (reasoned, not run; nothing in this repository routes such a service). `DECODE_AND_MERGE_SLASHES` is valid and stricter, and is not shipped.
- **PostgreSQL image bumps** are not in 0.4.3 (apps #162 and #163, 0.4.4); **OVH and Outscale** were not run (Scaleway only, by the owner's decision).
- One run per figure, a development OpenBao bootstrap, the proof on a moving branch ref.

**Known open items (stated, not hidden; each to get an issue, drafts written and not filed when this was written):** the open spellings above; the forge token in `app.ini` (observed: exactly one `TOKEN` line equal to the Secret, so the daily Longhorn backup of that volume carries it) and in the generated vmagent configuration Secret; the cleartext scrape; no alert for the forge scrape (the forge page of OpenAether-apps already says so); Alertmanager replica 1 received no alerts; the `forgejo-db` and `forgejo` Kustomizations Ready before their objects exist; the Pooler `bootstrap-controller` OOMKilled at 64Mi; the Grafana first-migration lock race; a new bucket suffix rebuilds the Talos image; the CAPI-child Flux copy (above); nothing orders the forge behind the vault Job on an upgrade; the 2-minute transient after the Flux step is documented, not removed. Flux objects that sit on deprecated `v1beta3` (`Alert`, `Provider`) are an apps change for a later release (`docs/upgrade.md`). **Whether the `SBOM` scan of the Flux kustomize-controller image is green (infra #444) is to be confirmed by the tag-run scan:** the lock and the list of images to scan now name kustomize-controller v1.10.1 and the VEX file holds no statement, but no scan of that image was run for this entry (the commit that moved the pin read the apk database of the image, which lists the fixed brotli-libs 1.2.1-r0; it did not run Trivy). Everything `[0.4.2]` and `[0.4.1]` list as not proven or not fixed is still so unless this entry says otherwise.

**For the release notes:** they name the release commit in full, the squash-merge commit on `main` that the tag points at, not the head of the pull-request branch (`./scripts/dev/check-release-tag.sh <tag> --notes notes.md` refuses notes that do not name `git rev-parse <tag>^{commit}`); the proof covers the two heads above, and the notes say so beside that commit.

## [0.4.2] — 2026-11-04

0.4.2 is the 0.4.1 release plus **one fix**: the `SBOM` workflow attaches the inventory to a DRAFT release (#395), so a release carries `openaether-infra-<tag>.cdx.json` again. **No runtime change since 0.4.1.** The diff from the 0.4.1 tag is the workflow, the `release` skill, the release checklist, `docs/supply-chain.md` and its French twin, `docs/status.md`, `docs/upgrade.md` and its French twin (a short "From 0.4.1 to 0.4.2"), the two READMEs and this file, and the move of the apps pin: the `git_ref` default and the twelve `envs/*.tfvars.example` now pin OpenAether-apps `refs/tags/0.4.2` (they pinned `refs/tags/0.4.1`), and the tftest assertion on the rendered GitRepository follows. No script, no resource and no module logic changed (the default of `git_ref` is the one value that moved), and no Talos, Kubernetes or provider version. It pairs with OpenAether-apps 0.4.2, which must be tagged first and differs from apps 0.4.1 by CI, documentation and one VEX data file, `.vex/openaether-apps.openvex.json`, which Trivy and the CI check read and no cluster does (eight files in all, listed in `docs/release-checklist.md`; the apps half is in its own CHANGELOG).

**Upgrade path: 0.4.1 to 0.4.2 only** (previous release, the policy before 1.0.0). Only the apps ref moves, and there is nothing new to run by hand: no knob, no migration, no node roll (the Talos and Kubernetes pins are the same in 0.4.1 and 0.4.2). The steps are in `docs/upgrade.md`, "From 0.4.1 to 0.4.2" (and its French twin), which points to "From 0.4.0 to 0.4.1" for the mechanics, numbers moved by one: check out the tag, `git_ref = "refs/tags/0.4.2"` in the tfvars (the examples carry it; a tfvars that leaves `git_ref` unset inherits the new default), `task cluster-up PROVIDER=… ROLE=…` with the plan read (it moves the apps ref itself), then `task cluster-verify`. **Not shown: the move from `refs/tags/0.4.2` itself**, the one you will run: the tag does not exist until the release, and the cloud retest below moves a 0.4.1 cluster to the 0.4.2 heads, so it follows the branches, not the tag (as the 0.4.1 retest did).

**Cloud retest of the 0.4.2 heads (two clusters, 3 CP + 6 W each; Scaleway POP2-4C-16G, OVH c3-8 with the replica store at Scaleway), 2026-11-04.** It proves that a 0.4.1 cluster moves to these heads in ONE `task cluster-up` with no acknowledged write lost, no failed probe, no node rolled and no `/metrics` exposure, so nothing regressed in function; some wall-time figures are WORSE and are listed below; it does NOT prove the SBOM workflow (first live proof: the 0.4.2 tag) and the move followed the branch refs, not `refs/tags/0.4.2`. Heads: infra a925703, apps 535813c. Durations are NOMINAL unless said INCIDENT; WORSE is at least 10 s and at least 10 % worse (see the 0.4.1 rule), "at the edge" within the measurement resolution.
- **Scaleway** (baseline: the 0.4.0 to 0.4.1 move of the previous retest). Move: rc 0 in one invocation, **10 min 30 s, WORSE than 6 min 41 s (+57 %, one run, cause not isolated)**: the code path of `cluster-up` is the same as at the previous head except two `cluster-security` files, and 3 min 41 s of the extra 3 min 49 s lie before the ref move (after it: +8 s, SAME). 41 of 41 Kustomizations Ready 4 min 05 s after the ref move and 2 min 30 s after the command returned (SAME). A tunnel source port was held 7.1 s on purpose: `retry 1/3`, then 9 of 9 tunnels. 0 failed probes of 775 / 775 / 1,527 / 1,523 on the four vantages; 102,218 acknowledged writes over the writers' whole run (plan-only run, move and checks), 0 lost; longest gap between acknowledged writes 1.26 s (at the end of the plan-only run, before the move) and 0.78 s during the move; no node rolled; database seed rows and the OpenBao key-value read back identical after the move. `cluster-verify` 31 passed, 0 failed; `cluster-security` 32 of 36 twice, 0 failed; `/metrics` and `/debug/metrics` 403 on every Gateway host (216 probes: 112 x 403, 0 bodies; 748 probes during the move all 403); backup-verify PASS; the dump-load restore test SKIP x4 then PASS x4 after the dump. Plan-only run 1 min 52 s against 1 min 41 s: at the edge (+11 s, +10.9 %). The fresh install of the 0.4.1 arm took 12 min 56 s INCIDENT (the known load-balancer ACL trap, then 7 min 33 s on the re-run). Also WORSE by the rule: the platform databases took 10 min 02 s from the `cnpg` start to 3 of 3, against 5 min 50 s to 6 min 13 s; `cnpg-dump` 31 s against 18 s (+72 %); `backup-verify` after the dump 32 s against 21 s (+52 %); the install wall of 12 min 56 s INCIDENT is +27 % and +19 % against the two earlier INCIDENT installs.
- **OVH** (no earlier OVH move exists: the figures are not like for like with Scaleway). Move: rc 0 in one invocation, 9 min 04 s, of which 133 s are the bucket-protection read-back that `cluster-up` runs twice when `backup_immutability = "versioned"` (6 min 51 s without it, by subtraction, not measured). 41 of 41 Ready 4 min 06 s after the ref move and 2 min 41 s after the command returned (against 2 min 17 s of an earlier Scaleway lab: WORSE by the rule, +24 s, +17.5 %, but SAME as the Scaleway retest above). Source port held 6.5 s: `retry 1/3`, 9 of 9 tunnels. 0 failed probes of 701 / 701 / 1,384 / 1,383 samples (start of the window to the end of the convergence; counting both ends gives 702 / 702 / 1,386 / 1,385); 201,797 acknowledged writes, 0 lost; no node rolled; `cluster-verify` 32 passed, 0 failed; `cluster-security` 32 of 36 twice; `/metrics` the same table as Scaleway. Against the Scaleway figures (not like for like) the move is +36 % (9 min 04 s against 6 min 41 s) and the plan-only run took 2 min 53 s against 1 min 41 s and 1 min 52 s (+71 % and +54 %), 65 s of it the same read-back. The install of the 0.4.1 arm took 17 min 36 s INCIDENT (one node of nine ACTIVE but silent for 2 min 01 s, fixed by the automatic hard reboot at 90 s).
- **Seen, not caused by this release:** on a fresh install the `cnpg` Kustomization can pass its health check before the databases exist (Scaleway: the check passed in 47 s, about 9 minutes before both databases were 3 of 3, so the dependents started then and two Grafana pods restarted; it did not recur on OVH); `observability-vm-customresources` fails its first reconciliations until the VictoriaMetrics CRDs exist (5 min 05 s on Scaleway, 2 min 02 s on OVH, where the event names the missing VMAgent kind); `grafana-oidc` stays in `SecretSyncedError`.
- **Pod restarts after the install of the 0.4.1 arm:** 34 on Scaleway (Longhorn 22, control-plane static pods 6, Grafana 6 in the two restarted pods) against 10 at the same age in the previous retest, WORSE as a count, cause not isolated; 26 on OVH (Longhorn 23, control plane 3); neither count changed during the move.
- **Not shown:** a failover or zone drill (so no split-brain test), the Grafana to Zitadel sign-in, the forge `/metrics`, a NOMINAL install of the 0.4.1 arm, the move from `refs/tags/0.4.2`, the scheduled restore tests, the OVH load-balancer ACL, Outscale (no quota). One run per figure, development OpenBao bootstrap.

**What is proven for the fix, and what is not (the rung is mocked and GitHub, not a cluster):**

- **Proven:** `actionlint` and `yamllint` on the workflow, green. The commands of the upload step replayed against GitHub with a throwaway DRAFT release (the asset attached) and with the published 0.4.1 release (the upload refused).
- **Not run yet:** the workflow itself on a pushed tag, so the trigger on `push: tags`, the "no release yet" path (the workflow creates the draft), the `release-has-asset` job (it needs a publish event) and the skip of `scan-images` on that publish event have never run. **The 0.4.2 release is the first live proof of all four**, and it is not proven until it has gone through. If the run on the tag does not start or its attach job is red, the documented fallback (`docs/release-checklist.md` §8) is `gh release create <tag> --draft --verify-tag --title <tag> --notes-file notes.md`, then `gh workflow run sbom.yml -f tag=<tag>`; the release is published once the asset is there, and the failure is an issue.

**Known open items (stated, not hidden):**

- The weekly `SBOM` scan is red on the Flux kustomize-controller image (infra #444): a CRITICAL finding whose fix has to come from upstream. The pins are those of 0.4.1, so the scan of the 0.4.2 tag is expected to show it too. The scan jobs are separate from the attach job: a red scan does not stop the inventory from being attached.
- OpenAether-apps: the weekly scan is red on the Forgejo image (apps #179) and on the CNPG PostgreSQL images 16.15 and 18.6 (apps #162 and #163). Five apps VEX statements and one Trivy ignore entry expire on 2026-11-20, so the apps check turns red from 2026-11-21 unless each is re-read and renewed, or its image fixed (the apps `CHANGELOG.md`, `[0.4.2]`, "Not fixed").
- The `release` skill is not byte-identical between this repository and OpenAether-apps, so `check-skill-parity.sh` fails when both are side by side (it already did at 0.4.1; in this repository alone it skips). This release does not touch the skill.
- Everything `[0.4.1]` lists as not proven or not fixed is still so: this release changes none of it.

### Fixed

- **The `SBOM` workflow attaches the inventory to a DRAFT release** (#395). Immutable releases (on since 2026-10) take no asset once published: the old `release: published` trigger failed with "Cannot upload assets to an immutable release", and 0.3.2, 0.4.0 and 0.4.1 went out without `openaether-infra-<tag>.cdx.json`. The workflow now starts on the pushed tag (`push: tags`), creates the release as a draft when there is none (or reuses yours), attaches the inventory to it, and fails with a clear message on an already published release. When the release is published, a job (`release-has-asset`, on this repository only like `inventory`) only checks that the asset is there and goes red, with the way to rebuild it, when it is not; `scan-images` is skipped on that publish event. **New procedure** (`docs/release-checklist.md` §8 has every step; the `release` skill has the short form and carries neither the run lookup nor the read of the attach job): push the signed tag, find the `SBOM` run of the tag commit (`gh run list --commit`, confirmed by the `headSha`, `headBranch` and `event` it prints; by `--branch <tag>` if `--commit` matches nothing), wait for it and read its conclusion, check the asset, then `gh release edit <tag> --notes-file notes.md --draft=false`. Never `gh release create` without `--draft`. Rung: see "What is proven for the fix" above.
- **The three missing inventories cannot be attached; they can be rebuilt.** 0.3.2, 0.4.0 and 0.4.1 are published and immutable, so their release stays without the file. `python3 scripts/dev/gen-sbom.py --version <tag>` on a checkout of the tag rebuilds it: run offline on an export of each of the three tags, it ended rc 0 and wrote a CycloneDX 1.5 file (48, 53 and 53 components for 0.3.2, 0.4.0 and 0.4.1). Mocked rung (the generator, no cloud).

### Documented (0.4.2)

- **`docs/release-checklist.md`, `docs/supply-chain.md` (and its French twin) and, in short, the `release` skill** describe the procedure above and the alarm; the checklist gets two more lines: `git grep -n 'RETEST-PENDIN[G]'` must print nothing in this repository, in OpenAether-apps and in the notes, and the date of `[0.4.2]` is the day of the tag, and the scan line keeps the VEX rule with ONE exception, for 0.4.2 and infra #444 by name (the lead's decision under the owner's delegation, recorded by the lead before the tag, with its ACTION, in a file outside this repository; not a standing waiver). Rung: mocked (the doc checks).

**Correction (added in 0.4.3):** "no `/metrics` exposure" and "403 on every Gateway host (216 probes: 112 x 403, 0 bodies)" above cover 27 spellings (among them `//metrics`), over HTTPS and HTTP, on the four hosts swept (Grafana, Zitadel, OpenBao, a test application), not the forge host, which that retest did not deploy. A 0.4.2 cluster with the forge brick on answered `//metrics` and four more spellings on the forge host with the forge's metrics (about 11 KB, 66 families; no repository content or credential seen; measured at the 0.4.2 tags in a later lab); plain `/metrics`, `/metrics/` and `/debug/metrics` were 403 on the forge too, port 80 gave 301 for the `//` spellings. In the sweeps of that later lab (54 spellings x 5 hosts x 2 listeners = 540 probes) only the forge host answered with metrics (Grafana, Zitadel, OpenBao and the test application: 0 bodies on the first response), so a cluster without the forge brick showed no exposure in them; "not affected" is NOT claimed: the Longhorn opt-in route was not tested, redirects were not followed, and the `%2F`, `%5C`, case and `;param` spellings were not followed beyond the first hop. Fixed in 0.4.3; see the OpenAether-apps `[0.4.3]` and the pointer in `[0.4.3]` above.

## [0.4.1] — 2026-11-03

0.4.1 is a **hardening patch** of the 0.4.0 resilience release: gaps that the 0.4.0 labs and two proof labs of this release found, and no new scope. It pairs with OpenAether-apps 0.4.1, which must be tagged first: the `git_ref` default and the twelve `envs/*.tfvars.example` now pin OpenAether-apps `refs/tags/0.4.1` (they pinned `refs/tags/0.4.0`), and the tftest assertion on the rendered GitRepository follows. The apps half is in its own CHANGELOG (among other things the shared Gateway now refuses `/metrics` and `/debug/metrics` for every route: at 0.4.0 Grafana's `/metrics` and Zitadel's `/debug/metrics` answered 200 with a Prometheus body and no login (10 of 216 probes), observed from the lab host through an app load balancer whose ACL allowed that host only, so by reading the exposure is to any caller that reaches the Gateway; on the upgraded cluster of a proof lab the same 216 probes gave 112 × 403 and 0 bodies; a route of yours that serves `/metrics` on purpose gets the 403 too). What this repository adds and fixes:

- **Roll gates that refuse early** (`cluster-roll`, `cluster-replace-node`, `cluster-upgrade`, `cluster-shrink`): a bare pod is refused before the drain, a drain that stalls behind a budget that allows nothing is refused after 120 s and not 900 s, the roll asks before replacing the only copy of a single-instance database (`--accept-sole-copy`), and one failed etcd read no longer refuses a dead-node replacement. Run once on Scaleway (3 CP + 6 W): the stall gate with a stand-in stall (the stall of lab 28 itself did not reproduce), and the bare pod refused 2 min 41 s after the command, not under 60 s (the gate itself answers in under 1 s).
- **The Talos tunnels retry a port that is busy only as someone's source port**: the move from 0.4.0 that needed two invocations in lab 28B ran in one, twice (at infra 255e08f and at infra 67be1e8, the head of the third proof lab), each time with a clash provoked on purpose (a port held for about 7 s); not seen against the host's own probes over time.
- **`task cluster-up … PLAN_ONLY=1`** reads the plan with nothing created (additive: off by default, every other run unchanged). With the Talos image missing it cannot read the plan: on Scaleway, the only provider run, it ended rc 201; the text now says so, and that OVH and Outscale were not run.
- **The disaster-recovery chain, re-proved on a cluster.** Three defects of a candidate of this release (the hold of Grafana and Zitadel undone by their parent, a step `identity` that could never pass on a default install, an OpenBao standby left without a leader) and two stops of 0.4.0 (a Job pruned by its CronJob, Grafana's schema created before the load) are fixed and were each re-run on a Scaleway rebuild (3 CP + 6 W): the chain ran `openbao` to `verify` with no stop after the `cluster` step and 29,387 acknowledged ids, recorded outside the cluster, were all present afterwards. It was not unattended (below).
- **`cluster-verify`** is red, from 5 minutes of age, on a profile CNPG Cluster that does not archive WAL (it was blind to it; the alert alone took 25 minutes) and compares the `cluster-identity` ConfigMap with the rendered map.
- **`task test-scripts` runs every `scripts/dev/test-*.sh` by glob**, so a new harness cannot be left out of the gate by forgetting a line; the OpenTofu, tflint, commitizen and flux-schema pins moved.
- **Documentation:** the DR page (the chain as measured, the last WAL segment before a planned destroy, `iam-admin` after a rebuild), "From 0.4.0 to 0.4.1", the server-side encryption of the CNPG archive read on Scaleway, the lab 28 OVH figures.

**Upgrade path: 0.4.0 to 0.4.1 only** (previous minor, the policy before 1.0.0), by the steps of `docs/upgrade.md`, "From 0.4.0 to 0.4.1": check out the tag, `git_ref = "refs/tags/0.4.1"` in the tfvars, `task cluster-up PROVIDER=… ROLE=…` with the plan read (`0 to add, 3 to change, 0 to destroy`: the control planes' machine configs in place), then `task cluster-verify`. The Talos and Kubernetes pins are the same in 0.4.0 and 0.4.1, so no node rolls. **The move was run twice on Scaleway (3 CP + 6 W, NOMINAL apart from a tunnel port held on purpose), the second time at the heads of a third proof lab, and both times with Flux following the apps BRANCH, not the tag.** At those lab-proven heads (from the 0.4.0 tags to infra 67be1e8 and apps d028aed; what the release adds to them is in the line "The proof covers" below): `PLAN_ONLY=1` first (rc 0 in 1 min 41 s, `0 to add, 3 to change, 0 to destroy`, nothing created: the 10 servers, 9 images, 12 snapshots and the state buckets identical before and after, but for 3 Loki objects the running cluster wrote itself), then ONE `task cluster-up`: rc 0 in 6 min 41 s with the first tunnel port held 7.2 s (`:52000 could not be bound … retry 1/3 in 4s`, then 9 of 9 tunnels), no node rolled (the 9 boot ids and the restart total identical before and after), 41 of 41 Kustomizations Ready on the new revision 4 min 10 s after the ref move (2 min 43 s after rc 0), probes at 1 Hz 0 failed on four vantages (560, 560, 1,102 and 1,102 samples), 109,173 acknowledged commits on four writers, ids recorded outside the cluster, 0 missing, `cluster-verify` 31 passed, 0 failed. At infra 255e08f and apps 75b546d the first move had taken 7 min 6 s, with 41 of 41 Ready 3 min 49 s after the ref move, 37,177 acknowledged commits and 0 missing. On the upgraded cluster the shared Gateway refused `/metrics` and `/debug/metrics` (216 probes: 112 × 403, 0 bodies; 10 bodies before the move) once Flux had applied its policy, 2 min 38 s after the ref move and 71 s after rc 0; the dump-load restore test, which had FAILED four times at 0.4.0, skipped (no dump yet) and passed after a dump. **Not shown: the move from `refs/tags/0.4.1`**, which is what you will run (the tag does not exist until the release; infra pins it then). `docs/upgrade.md`, "From 0.4.0 to 0.4.1", has the figures and what is still unseen. What an operator meets that is new: `--accept-sole-copy=<namespace>/<name>` (an unattended roll that would replace the only copy of a `light` database now stops until it is given), `DRAIN_STALL_AFTER` (120) and `DRAIN_STALL_POLL` (10; `DRAIN_STALL_AFTER=0` restores the plain drain), `ETCD_READ_TRIES` (3) and `ETCD_READ_PAUSE` (3 s), `OA_TUNNEL_BIND_RETRIES` (3) and `OA_TUNNEL_BIND_PAUSE` (4 s), and four new knobs of `task dr-restore-plan`: `OA_DR_STABLE_ROUNDS` (5), `OA_DR_STABLE_TRIES` (60), `OA_DR_STANDBY_TRIES` (18) and `OA_DR_ES_OPTIONAL` (a list of `namespace/name`, empty counts every ExternalSecret); from the apps side, a route of your own that serves `/metrics` gets a 403 (the apps CHANGELOG, Security, has the opt-out).

**WORSE rows, stated plainly, none hidden.** The rule for every label of this release, stated once and applied to every row below and to the move: a step is WORSE when it is both at least 10 s and at least 10 % slower than the run it is compared with (one sample per lab), BETTER when it is both at least 10 s and at least 10 % shorter (BETTER only means shorter), and SAME otherwise; a figure within the measurement resolution of a line (about 6 s: the polls are 5 to 6 s apart) is called "at the edge" and gets no firm label; a wall figure that contains INCIDENT time is never called BETTER. First the figures of a second proof lab (Scaleway, 3 CP + 6 W, a rebuild by the DR chain), NOMINAL unless said, against the first proof lab and lab 28B; the full table is in `docs/disaster-recovery.md`:

- chain step `openbao`: 296 s against 20 s and 9 s (the wait for a stable OpenBao state, the price of the standby fix);
- `hold`: 16 s against 5 s and 6 s;
- `identity`: 168 s against 10 s (lab 28B; the first proof lab's never passed): Zitadel and Grafana now start only after the databases;
- `verify`: 482 s against 385 s (+25 %);
- `dbs`: 487 s, +14 % against lab 28B's 426 s (which ended in a false-negative rc 1) and −6 % against the first proof lab's 518 s;
- **the like-for-like sum of the NOMINAL steps is 2,190 s against 1,747 s: WORSE by 25 %** (the older sum contains 63 s of an `identity` step that failed). The time from the declared disaster to the chain verified, 48 min 43 s (59 min 52 s and 68 min 3 s before), contains INCIDENT time (a 231 s stop on the known LB-ACL trap) and an extra 152 s round of final backups, and is not to be read as BETTER; data was back 37 min 53 s after the declaration. The 8 h target is met by a factor of 9 or more;
- `cnpg-dump`: 32 s against 21 s (+11 s, +52 %), with 15,000 more rows per database in the second lab (not like for like);
- SAME by that rule, listed so that nobody looks for them: `flux` 379 s against 360 s (+19 s, +5 %), `destroy` 96 s against 87 s (+9 s), and the dump-load restore test 18 s against 14 s (+4 s, +29 %).

Then the figures of a third proof lab (Scaleway, 3 CP + 6 W: a fresh install at the 0.4.0 tags, then the move to the lab-proven heads), by the same rule, against the first and second proof labs, one sample each, NOMINAL unless said. **The install and the first day after it ran at the 0.4.0 tags (the n-1 arm): they describe the 0.4.0 install, not 0.4.1 code, and a WORSE on them is not a 0.4.1 regression.** The first proof lab installed at the 0.4.0 tags too, the second at the 0.4.1 heads:

- **the install, from its start to rc 0: 20 min 25 s, INCIDENT** (the provider created a worker `stopped`, then refused three re-creations, `POP2-4C-16G is out of stock`; the known LB-ACL error came first), against 10 min 13 s (first proof lab, 0.4.0 tags) and 10 min 54 s (second, 0.4.1 heads), also INCIDENT: **WORSE** (+10 min 12 s and +9 min 31 s), at the n-1 arm and because of the provider's stock incident, not a measure of 0.4.1. No NOMINAL install time at 0.4.0 was measured in this lab;
- **the first day after rc 0 (receiver, seed, PKI, certificates): 3 min 19 s, at the 0.4.0 tags (n-1 arm)** against 2 min 44 s (second proof lab, 0.4.1 heads): +35 s, +21 %, **WORSE** by the rule; against 4 min (first proof lab, also at 0.4.0) it is BETTER. It is a 0.4.0 figure, so this WORSE is not a 0.4.1 regression: read the other way, the 0.4.1 figure (2 min 44 s) is shorter than both 0.4.0 figures, one sample each, and no BETTER is claimed for it;
- **41 of 41 Kustomizations Ready after rc 0 of the move: 2 min 43 s against 2 min 17 s: +26 s, +19 %, WORSE.** The cause is not isolated: this move carries more change (apps 42 commits and 35 files against 7 and 11, infra 74 commits and 78 files against 51 and 52), and which Kustomizations took the extra time was not measured. Counted from the ref move, 4 min 10 s against 3 min 49 s (+21 s, +9 %) is **at the edge, resolution about 6 s**: 2 s under the WORSE line of 252 s, no firm label;
- **`PLAN_ONLY=1` on the bootstrapped cluster: 1 min 41 s against 1 min 31 s: +10 s, +11 %: at the edge, resolution about 6 s**, so no firm label (WORSE if the figures are taken as measured). The two plans are not alike either (the first one's grow step would have created machines, this one holds three in-place changes): a reason to read the figure with care;
- SAME by the rule: the move, 6 min 41 s against 7 min 6 s (−25 s, −6 %); 41 of 41 after rc 0 of the fresh install (at the 0.4.0 tags), 12 min 16 s against 11 min 59 s and 11 min 47 s (+17 s, +2 %; +29 s, +4 %); the dump-load test after a dump, 19 s against 18 s and 14 s; the requested CPU, 282 % of one worker against 283 % and 281 %; probes, 0 failed in both moves. `cnpg-dump`, 18 s, is SAME against 21 s (−3 s); against 32 s (the second proof lab, with 15,000 more rows per database) it gets no label: not like for like, and a one-off timing, not a claim about the code;
- a gate run that was not clean: `cluster-security` read 31 of 36 with test 1.6 failed on its first run and 32 of 36 on the second (as in the earlier labs): a flaky test, not the cluster; fixed in this release (Fixed, below).

**It was not unattended:** three invocations of the script, ONE stop (the LB-ACL trap on the `cluster` step, known and not fixed in 0.4.1) and ONE hand step (the break-glass root token of the fresh cluster, about 15 s). The zero-loss figure is for a planned destroy and rebuild with the writers stopped 12 s before the disaster was declared, after the extra round that forces the last WAL segment out; "no split brain" is vacuous in a rebuild, which has no failover.

**Not proven, or known and not fixed (stated, not hidden):**

- Every Outscale row waits for the quota and no 0.4.1 lab ran there; no 0.4.1 lab ran on OVH either: every cluster result of this release is Scaleway, 3 CP + 6 W.
- The stall of lab 28 (an RWX share-manager keeping a budget at 0) as such; SIGHUP on a real apiserver; the force-delete of a stuck Cilium agent in the etcd scenario and the node with a dead datapath; the missing-image case of `PLAN_ONLY`, which ended rc 201 on Scaleway (OVH and Outscale not run); `PLAN_ONLY` on a bootstrapped cluster past the grow step was read in a third proof lab (rc 0, nothing created), but its Talos tunnels were already open, so that the plan opens them is still not shown.
- The end-to-end Grafana to Zitadel sign-in (the scripted finalisation was refused and no browser run was made; on the third proof lab's installs Grafana's login redirect carried an empty `client_id`, the known `grafana-oidc` ExternalSecret in `SecretSyncedError`: it reads `grafana/oidc`, which only a console step puts into OpenBao); the fresh-install window of apps #169 (shown only on a rebuilt cluster whose Backup objects were deleted by hand); the `/metrics` rule on the forge (not deployed).
- **The move from `refs/tags/0.4.1`.** Both moves followed the apps branch (`refs/heads/claude/0.4.1-rc1`); an upgrader follows the tag, which does not exist until the release (infra pins it then). The move at the lab-proven heads is shown on the branch only, in one run. No failover or zone drill ran during a move: "no split brain" is true there (no failover happened) and untested. The new `AuthorizationPolicy` of the Gateway applied with an Istio admission warning (a DENY with only HTTP attributes "will deny all traffic to TCP ports under its scope"): harmless today, since the Gateway of the repository declares only the HTTP 80 and HTTPS 443 listeners (read in the file; the live listeners were not archived), but a TCP or TLS listener added to it later would be denied without a message (the policy and its note are the apps repository's). Not seen on an upgraded cluster either: the alert `CnpgWalNeverArchived` (nothing provoked it) and the new message of `backup-verify` (it prints only when a check fails, and none did).
- The DR chain: a DEVELOPMENT OpenBao only (a production-style restore with the share holders' quorum was not run); the replica store at the same Scaleway endpoint (no provider loss); one shape; the OpenBao race proven once (n=1) with its cause still there; the join of the hold with OpenBao's Kustomization still UNPROVEN in the code.
- **Not fixed in 0.4.1:** the LB-ACL trap on every Scaleway build with `app_lb_allowed_cidrs`; a plugin `Backup` that says `completed` before its end WAL is archived (documented, no helper); `iam-admin` and `iam-admin-pat` absent after a rebuild (documented, no design yet); a sealed `openbao-0` after a second restore of the snapshot (cause unknown); apps #180 (41 of 41 Kustomizations Ready 11 min 47 s, 11 min 59 s and 12 min 16 s after rc 0 on three fresh installs, of which the serial observability chain, about 3 min 20 s, includes about 2 minutes of `observability-vm-customresources` in ReconciliationFailed that the diagnosis did not say; seen again on the third, where the cause looks like the VMCluster CRD not yet being registered, the events `no matches for kind "VMCluster"`, then `"VMAgent"`, were archived as `kubectl get events` lines, cut by kubectl, not as full messages; performance only, 0.5.0).
- **`task cluster-security` 1.5, 2.4, 2.7 and 4.1 still read a static checkout** (`$REPO_ROOT/OpenAether-apps`, the sibling directory of whoever runs the script: not the cluster, not the ref Flux follows), and 1.5 (Loki egress) cannot fail on a rule written in block style, since its regexp wants `toEntities` and `world` on one line and the YAML has them on two. Only 1.6 was moved to the cluster in this release (Fixed, below); the rest is not fixed.
- **Scaleway stock at install, seen once (a provider incident, not a product defect; there is no automatic retry).** A `cluster-up` create can fail with `resource POP2-4C-16G is out of stock`: in the third proof lab a worker in fr-par-3 came up `stopped`, then three runs in a row failed on that create, and the fifth run, started about 12 minutes after the start of the install, created it (rc 0 at 20 min 25 s, INCIDENT; the half-built cluster, 3 control planes, 5 workers and a bastion, billed meanwhile). The provider's availability API read `shortage` for that zone and `scarce` for the two others, and still read `shortage` after a create had succeeded: it was no guide in this one occurrence; the create is the test. `docs/upgrade.md` of 0.4.0 covered "out of stock" for a roll and a node replacement only; the one of this release says what to do at an install too (run the same command again), so the pair documents it at an install.
- An alert `PdbBlocksDisruption` was pending twice on the fresh install of the second proof lab (writers running) and was not explained.
- The proof covers, on Scaleway, infra 255e08f and apps 75b546d (the first proof lab: the move, the drills, a first rebuild), infra 303851b and apps 11bd8fd (the second: a fresh install and a second rebuild) and infra 67be1e8 and apps d028aed (the third: a fresh install at the 0.4.0 tags, `PLAN_ONLY=1` and the move to those heads, the upgraded cluster read, no node rolled). **The release heads are these lab-proven heads plus documentation-only commits, with the text edits that are not documentation listed here.** In infra, after 67be1e8: documentation and the `cluster-security` 1.6 fix (the script and its test, mocked only, never run on a cluster). In apps, d028aed is the head the third lab ran, and against the second lab's 11bd8fd it holds, besides documentation, three comment or docstring edits (a Zitadel HelmRelease comment, the comment of the Gateway DENY policy, the docstring of `OpenAether-apps/scripts/zitadel-apply-policies.py`), the new `backup-verify` message of `barman_check.py` (with a `newest` variable, in its FAIL branch only) and the cases added to its mocked test `OpenAether-apps/scripts/dev/test-backup-verify.sh`: the script itself ran at d028aed, on its PASS path, and the message of its FAIL path never ran on a cluster (a mocked test only). `git diff 11bd8fd d028aed` lists them; apps commits after d028aed must be documentation only, which `git diff --stat d028aed <apps release head>` shows at the cut.

The entries below are those of this release, each with the rung it reached. Rung of a line: **mocked** (self-tests and doc checks), unless it says it was run on Scaleway.

### Added

- **`task cluster-up … PLAN_ONLY=1`** (infra #412): a run that only reads the plan. It ensures the state buckets, renders the manifests and runs `tofu init` as in any run, plans the Talos image and reports "it WOULD be built" instead of building it (`talos-image.sh --ensure --plan-only`), lists the machines and nodes the grow step would create or configure without touching anything (`grow-nodes.sh --plan-only`, exit 3 when it would act), shows the phase-1 plan with the node-delete guard unless the grow step would act (the full plan can wait 15 minutes on nodes without a configuration), and ends rc 0 with "plan only: nothing was created" (when the plan can be read: see the rung for a missing image). On a bootstrapped cluster that plan first opens or repairs the local Talos tunnels, as `task plan` does (ssh processes on this machine through the bastion, nothing created in the cloud; `task close-tunnels` closes them). It writes no state either: the one-time copy of a pre-#69 image state is left for a real run. Off by default: `APPROVE=auto` and every other run get the same calls as before (asserted); no rung receipt is recorded for a plan-only run. Rung: mocked (`test-cluster-up.sh`, `test-grow-nodes.sh`, `test-talos-image.sh`, with a mutant check of each), then run twice on Scaleway (a proof lab, 3 CP + 6 W). The grow drill (`workers` 6 to 7, NOMINAL): rc 0 in 1 min 31 s, the 10 servers, 9 instance images, 12 snapshots and the state-bucket listings identical before and after, the four machine resources of the new worker listed as "WOULD be created"; the phase-1 plan itself was not reached there (the grow step would act), so that a plan on a bootstrapped cluster opens the local Talos tunnels stays UNVERIFIED on a cluster. (A third proof lab then read the phase-1 plan of a bootstrapped cluster with nothing to grow: rc 0 in 1 min 41 s, `0 to add, 3 to change, 0 to destroy`, nothing created; its 9 Talos tunnels were already open, so that the plan opens them is still not shown.) **With the Talos image missing (a fresh account), on Scaleway, the run could not stop at a plan it can read:** it said the image "WOULD be built (and was NOT)", then the phase-1 plan failed with "no image found" nine times and the run ended rc 201, nothing created. The banner, the task description and the docs now say so (`test-cluster-up.sh` asserts the banner); the behaviour is not changed. Only Scaleway was run: OVH and Outscale look the image up in that plan too (read in the modules) and may fail there with another message; they were not run. The `cluster-up` blocks now use go-task's `if:`, a first in this `Taskfile.yml`. The tests ran green on go-task 3.53.1 (the development host) and on 3.54.0, the pin of `scripts/internal/install-task.sh`, installed with that script and its checksums; which release first honours `if:` was not established, and a go-task that ignored it would turn the plan-only cases of `test-cluster-up.sh` red.

### Changed

- **OpenTofu 1.13.1 → 1.13.2** (Cléa #91, probed green in a bare container, released 2026-10-21): the five `tofu_version` pins of `ci.yml`, the one of `real-cloud-regression.yml` and `TOFU_VERSION`
- **tflint v0.64.0 → v0.65.0** (Cléa #91, probed green in a bare container, released 2026-10-22): `scripts/internal/install-tflint.sh`, the single pin `task lint` installs it from. Rung: mocked.
- **commitizen 4.19.2 → 4.19.3** (Cléa #91, probed green in a bare container, released 2026-10-24): `ci.yml`, the `pip install` of the commit-message check. Rung: mocked.
- **flux-schema 0.16.0 → 0.17.0** (Cléa #91, probed green in a bare container, released 2026-10-23): `ci.yml` and `scripts/setup.sh`. Rung: mocked.
- **`task test-scripts` runs every `scripts/dev/test-*.sh` by glob** (infra #400, first step): the 97 hand-listed lines of `Taskfile.yml` become `check-jsonpath.sh`, `check-required-checks.sh --self-test` and one loop. The five harnesses it never ran (they need Docker or checkov and have their own task) are named, each with a reason, in `scripts/dev/exclude-from-test-scripts.txt`, and `check-script-reachability.sh` (`task lint`) now fails on an excluded name that no other task runs, on a name that is no file and on a line without a reason; it takes the glob as run only when it is the loop of the `test-scripts` task itself, and a `test-*.sh` in a subdirectory (which the glob does not reach) still needs its own entry. A new harness runs without being listed. The executed set is the same 95 harnesses and 2 checks as the old list (old and new Taskfile compared under go-task with every script stubbed; `test-task-guards.sh` now asserts the new set); the order is now alphabetical and the first failure still stops it. Rung: mocked. A full real run of `test-scripts` was green on an earlier head of this change (an independent run: 95 harnesses, rc 0, about 26 min on a shared 2 vCPU host, no cluster involved; `Taskfile.yml` is unchanged since), so no order dependence showed; a full run on the final head is UNVERIFIED (the three harnesses edited since were each run alone).
- **Renovate: plumber's two pins in one group** (`renovate.json5`): the action in `security.yml` and `PLUMBER_VERSION` in `install-plumber.sh` arrived as two PRs, each red in `task lint` (`check-version-drift.sh`) until the other merged. One `packageRules` entry now names both. Rung: mocked (`test-clea.sh` applies the rules in order to both pins and compares the group). That Renovate itself raises one PR is UNVERIFIED until the next plumber bump; `renovate-config-validator` runs in CI only.

### Fixed

- **`task cluster-replace-node` no longer refuses on ONE failed etcd read (infra #401, lab 25).** `dead_node_survey` counted a surviving control plane healthy on a single `talosctl service etcd` call: lab 25 (Scaleway) refused with two healthy survivors and the identical rerun passed. Each survivor is now read up to 3 times (`ETCD_READ_TRIES`, `ETCD_READ_PAUSE`, 3 s), healthy at the first `HEALTH OK`; a member silent on every try is still refused, named with its address ("no healthy answer from cp-2 (…) after 3 tries"). A silent member now costs two more `talosctl service etcd` reads and the two pauses of 3 s between the three (6 s of pauses; against an endpoint that hangs instead of refusing, two more read timeouts as well). The refusal is not weakened for a member that is really down; the survey is more patient with a transient. Test first in `test-dead-node-roll.sh` (16 passed, 3 failed on the old code; 19 of 19 after); mutants: one try, six tries, silent members unnamed. Rung: mocked; the transient cannot be provoked on demand, so no cloud drill is planned for it.
- **A bare pod (no controller) is refused in seconds, before any wait (infra #402, lab 25 D6).** On a control plane carrying bare pods `kubectl drain` refused at once and the roll still ended in "could not be drained (timeout 900s)" (INCIDENT, Scaleway, 3 control planes + 5 workers). `cordon_drain` now reads the pods of the node FIRST (before the CNPG waits, the budgets wait, the cordon and the drain) and lists those that `kubectl drain` would refuse, by `kubectl`'s own rule: no owner reference with `controller: true` (DaemonSet, static and finished pods are not counted). Unattended (`--yes`, `APPROVE=auto`) it refuses at once, names them and leaves the node untouched; attended it asks, and on yes goes on as before (the drain refuses, the old question follows). A pod list that cannot be read only warns: `kubectl drain` stays the judge. **Not established:** why the roll waited 900 s although `kubectl` refuses at once (the message prints the drain timeout whatever really ran out); the early refusal does not depend on it. Tests first in `test-rwx-drain-gate.sh` (16 passed, 4 failed on the old code; 20 of 20 after; the pod fixture now carries `controller: true`); mutants: no call, any owner counts as a controller, always refusing, finished and static pods counted. Rung: mocked, then run once on Scaleway (a proof lab, 3 CP + 6 W): a roll of a worker carrying a bare pod and a stray client pod was refused naming both ("Nothing was changed"), rc 201, budgets and Flux restored. The gate answered in under 1 s once the drain stage began, but the refusal came 96 s after the node was named (the two per-node `tofu plan` checks, 41 s and 55 s, run first) and 2 min 41 s after the command started: the drill's target of a refusal under 60 s is met by the gate and NOT counted from the command (`docs/upgrade.md`). Why the lab-25 roll waited 900 s stays not established.
- **The drain is watched: a stall against a budget that allows nothing is refused after 120 s, not 900 s (infra #417, lab 28 I3).** A worker with an attached RWX share-manager (and the single instance of a `light` database) held the drain for its whole 900 s and the roll then refused (rc 201 after 1,026 s: INCIDENT, OVH, 3 control planes + 6 workers, no damage). Nothing tells in advance which node does that, and a "node holds a share-manager" refusal would stop rolls that work today, so `cordon_drain` (and with it `cluster-roll`, `cluster-upgrade` and `cluster-shrink`) now runs `kubectl drain` in the background, reads the pods of the node every 10 s (`DRAIN_STALL_POLL`) and stops it, taking the usual refusal (node uncordoned, budgets and Flux restored), when for 120 s (`DRAIN_STALL_AFTER`) the same pods remain, none is terminating and a PodDisruptionBudget that allows 0 and is not short of a pod covers one of them. The message names those pods and budgets and the Longhorn share-managers and RWX clients still on the node. A drain that evicts, whose pods are winding down, or that waits on nothing a budget forbids is left to `kubectl` and its timeout as before; `DRAIN_STALL_AFTER=0` restores the plain drain. A signal (Ctrl+C, SIGTERM, SIGHUP) that arrives while the drain runs kills it, whichever script runs it (a signal the caller ignores, SIGHUP under `nohup`, stays ignored, as for a foreground drain), and takes the same refusal path: a background `kubectl` ignores Ctrl+C, so without this it would outlive a script that dies of the interrupt (`cluster-shrink` has no INT trap) and keep evicting pods from a node already uncordoned; the caller's own traps are put back and the signal is sent to the script again, so the roll's stop request and a plain death behave as they did. A SIGTERM sent to `cluster-roll` alone used to let the drain finish and now ends it (node uncordoned, the run dies unattended: conservative, not unsafe); a stop asked before the drain started does not end it. Cost: the end of a drain is noticed within 0.2 s. Tests first in `test-rwx-drain-gate.sh` on a fake clock (23 passed, 7 failed on the code without the watch; 30 of 30 after), then with REAL signals sent to a script whose stub drain hangs (a Ctrl+C on a script with no INT trap left the drain running; Ctrl+C, SIGTERM, SIGHUP and a signal the caller ignores, HUP as under `nohup`: 32 passed, 6 failed on the unchanged code; 38 of 38 after; the suite runs itself with INT, TERM and HUP at their default, so a parent that ignores one of them, `nohup` for instance, no longer turns it red); mutants: progress not resetting the clock, terminating pods ignored, no budget required, drain not killed, watch not switchable off, DaemonSet pods counted, a pod not on the node counted, no trap, trap without the kill, caller's traps not put back, signal not sent again, TERM not trapped, HUP not trapped, a signal the caller ignores taken over, a stop flag read by the watch. Rung: mocked, then run on Scaleway (a proof lab, 3 CP + 6 W) **with a stand-in stall, not the original cause; the 120 s window is a choice, not a measurement**: it is above the planned drains measured (database gap 10.6-16.6 s: NOMINAL planned drains, lab 28 O4, OVH, 3 control planes + 6 workers). A worker holding a pod behind a budget that allows 0 was refused 2 min 24 s after the drain began (rc 201, 4 min 34 s for the whole command, node uncordoned, budgets and Flux restored 8 s after the refusal); Ctrl+C and a SIGTERM sent to the script alone, 20 s into a drain, left no `kubectl drain` running and everything restored 11 s after the signal; a clean worker roll took 452 s, NOMINAL (790 s and 789 s earlier; not explained by this change), 2 failed HTTP samples of 449 (1 s each), no acknowledged commit lost. **Not shown:** the stall of lab 28 (an attached RWX share-manager) did NOT reproduce: with three Longhorn replicas on six workers the share-manager and the instance manager were evicted within 10 s, so the watch was not triggered by its original cause; SIGHUP on a real apiserver (mocked only); the RWX client and volume lists of the message; and a drain that would have cleared after more than 120 s standing still behind such a budget would be refused where it used to pass.
- **`cluster-roll` and `cluster-replace-node` ask before wiping the only copy of a single-instance database (infra #425, lab 28B I17).** The roll of a worker replaced its disk and the `light` database on it lost 42,583 acknowledged commits, with no word before. Before the first node is touched the survey now names every CNPG Cluster that declares ONE instance and whose volume is pinned by its own node affinity to a node the run replaces (a replicated volume is not pinned and is not named), and asks `[y/N]`. **`--yes` / `APPROVE=auto` does not answer it**: the roll refuses, changes nothing and prints the flag for each Cluster, `--accept-sole-copy=<namespace>/<name>` (repeatable; after the `--` of the task; `node-recovery.sh` forwards it). Not asked with `--upgrade` (the disk is kept) nor by `cluster-shrink` (which already refuses any node-local volume); a read that fails refuses, and so does a node of the run whose Kubernetes name cannot be read from its address (the run names the address and changes nothing: the question is never asked about fewer nodes than the run replaces; a dead node with no Node object needs `--node=<name>`, which `cluster-replace-node` passes). `--dry-run` does not read the databases, so its plan does not mention the loss. **Behaviour change to expect:** an unattended roll or replacement on a cluster that carries a `light` database now stops until the flag is given for it. It warns and asks; it does not move or protect the data. Tests first in `test-rolling-replace.sh` (159 passed, 15 failed on the old code; 185 of 185 after, the name resolution included) and `test-node-recovery.sh` (28 passed, 1 failed; 29 of 29); mutants: pinning ignored, instance count ignored or unset, a loose match of the accepted name, the unattended pass, a failed read passing, each of the three call sites, the flag, an address that gives no name dropped from the question, the dead node's address used as its name. Rung: mocked, then run on Scaleway (a proof lab, 3 CP + 6 W): the unattended roll of the worker holding a `light` instance was refused 33 s after the command started with nothing changed; answering no ended "aborted by operator" with the node unchanged; with the flag the roll went through (7 min 17 s, NOMINAL) and destroyed the instance as accepted, with the 9,078 acknowledged commits of its writer (asked for by name).
- **Talos tunnels retry a port that is busy only as someone's source port** (infra #422). `talos-tunnels.sh` respawns, alone, a tunnel whose ssh died on "Address already in use" with nothing listening there (lab 28B: the host's own 1 Hz probe held `:52100`), up to 3 times after 4 s (`OA_TUNNEL_BIND_RETRIES`, `OA_TUNNEL_BIND_PAUSE`); any other failure is reported at once. A port still busy after the retries is named with its way out: reserve the tunnel block with `net.ipv4.ip_local_reserved_ports` (the printed command keeps the ports already reserved, because `sysctl -w` replaces the list; when the script cannot read that list it says so and prints the read-then-append steps, never a command with the block alone; it says the setting is lost at a reboot unless it is also written in `/etc/sysctl.d/`, in the file that already sets the key if there is one, since the file read last wins at boot) or use another `TALOS_TUNNEL_OFFSET`. `test-talos-tunnels.sh` now holds a port the way the host did and picks its own port block by a bind, not `nc -z`. Rung: mocked, then run on Scaleway twice (proof labs, 3 CP + 6 W, NOMINAL), the second time at the heads of the third proof lab, with the local port of the first tunnel held as the SOURCE port of another connection for 7.0 s and 7.2 s: `:52000 could not be bound … retry 1/3 in 4s`, then 9 of 9 tunnels up, and the move from 0.4.0 to 0.4.1 ended rc 0 in ONE invocation each time (at 0.4.0 the same clash ended rc 201 and needed a second run, lab 28B). Not shown against the host's own probes over time: the holder imitated them. The intermittent CI failure of that test (infra #431, the ssh stub dying on "Address already in use") has the same shape, but that is a reading of the stub, not a measurement, and no CI run has shown it gone: #431 is NOT closed by this entry and stays open until the CI runs of the new test say so.
- **`cluster-upgrade`'s service probe no longer counts a policy as an outage** (infra #403, lab 25: "394 FAIL, 2 BLIND in 396 samples" under the default-deny ingress). The probe namespace gets a `CiliumNetworkPolicy` for the control plane (entities host, remote-node, kube-apiserver, port 8080; none applied without Cilium's CRD), and before the upgrade starts one request through the proxy decides whether the probe can measure: if not, it prints NOT MEASURING and makes no claim (the upgrade goes on, as the probe is reported, not gated). Rung: mocked (`test-cluster-checks.sh`), then run on Scaleway (a proof lab) on a default-deny cluster by sampling through the apiserver proxy at 1 Hz: 0 ok of 20 without the policy (the lab-25 reading reproduced in kind) and 60 ok of 60 with it. Which of the three entities carries the proxy traffic is not isolated; the end-to-end `task cluster-upgrade` was not run (no newer pin) and the NOT MEASURING branch is mocked only.
- **`task cluster-coredns-ha APPLY=1` names the rebalance** (infra #423): after a patch it says the zones can end unbalanced (lab 28B: 2, 3, 2) and gives `task cluster-rebalance … APPLY=1`; nothing is said when nothing was patched. Rung: mocked.
- **`preflight-quotas.py scaleway` says it checks nothing** (infra #429) instead of a usage error: exit 2 (could not conclude), nothing queried, the Console quota to read, and the one known figure with its source. A real Scaleway reader is not done. Rung: mocked.
- **`task cluster-verify` goes red on a database-profile CNPG Cluster whose `ContinuousArchiving` is not True, from 5 minutes of age** (#430, lab 28C: a Cluster created on an archive path that still held another Cluster's WAL was invisible for its first 25 minutes, `CnpgWalArchiveFailing` being a 10 minute window plus `for: 15m`, and wedged at its first failover, 4 of 4). New section "The profile CNPG Clusters: WAL archiving" in `scripts/dev/infra-verify.sh`: every Cluster with the label `openaether.io/db-profile` in ALL namespaces (the platform loop still stops at `OA_CNPG_NAMESPACES`; `rt-*` copies stay out). The age rule is the triage's (a new Cluster is not archiving at second 0): `ContinuousArchiving` False is a warning under 300 s of age (`creationTimestamp`) and BAD from there, naming `namespace/Cluster`, its age, the condition reason and message, and where to read; absent on a Cluster that declares a WAL archiver is a warning under 300 s and UNKNOWN after; a creation time that cannot be read, or more than 60 s ahead of the clock of the machine running the verify (the clock is unknown, the line says so), gives no grace; a Cluster that declares no archiver (`light`) prints nothing. **A polluted profile Cluster younger than 300 s is therefore YELLOW (exit 0), red only from 300 s: a verify run right after its creation cannot fail on it, run it again.** The check reads no alert and needs none; where the apps release carries `CnpgWalNeverArchived` (`for: 5m`), it can fire sooner. No guard removed, none relaxed. One existing read changes, for the better: the platform CNPG list (`OA_CNPG_NAMESPACES`) now keeps stderr apart from the JSON like the two new reads (a warning on stderr with exit 0 used to hide every platform Cluster, and a False `ContinuousArchiving` with them, without a line); an answer that is not a list is UNKNOWN; its checks and lines are otherwise unchanged. Not done here: a unique `serverName` per Cluster incarnation (0.5.0). Run on Scaleway (a proof lab, 3 CP + 6 W) on a Cluster created over an archive path that held another Cluster's WAL (the lab-28C recipe, twice): YELLOW at 132 s of age (exit 0, 31 passed, 0 failed), RED at 589 s with the message above (the 300 s boundary itself was not probed), `ContinuousArchiving` True 13 s and 50 s after the foreign objects were removed, `cluster-verify` back to 33 passed, 0 failed; the alert `CnpgWalNeverArchived` fired 13 min 36 s after creation and `CnpgWalArchiveFailing` 23 min 40 s (lab 28C: 25 min), so the verify line is the fast signal. Still unknown: whether a healthy new Cluster shows False before True.
- **`task cluster-verify` compares the `cluster-identity` ConfigMap with the rendered map** (#409, identity half; with `deploy_flux = true`): a rendered key missing on the cluster or holding another value is BAD, with the key names (never the values) and `task cluster-identity-sync … APPLY=1`; a key the config does not render is not judged (the sync leaves it alone); an unreadable state or ConfigMap, or an answer that is not JSON, is UNKNOWN. A cluster with Flux gets one more line (pass or fail). Not done: the comparison of CAPI child cluster versions (#409, needs a CAPI child to prove, 0.5.0). Tests in `test-pins-verify.sh` (stub kubectl and tofu), mutation-checked; docs in `docs/upgrade.md` and `docs/upgrade.fr.md`. The green line was read on a cluster (a proof lab on Scaleway: "the cluster-identity ConfigMap holds the 6 keys the config renders"); the red cases are mocked only.
- **DR chain: Grafana and Zitadel start only after the databases are loaded, the parent `openaether-platform` stays suspended until step `identity`** (infra #426, lab 28B finding I18, then a proof lab on Scaleway, 3 CP + 6 W): in 0.4.0 `resume` unsuspended everything but `identity*`, so Grafana created its tables in the empty `grafana-db` and `pg_restore --clean` ended rc 1 on three dependency errors (the data was right). A first candidate of this release held `observability` and `identity` but not their parent: the parent is itself in the held list (it is outside OpenBao's closure), step `resume` resumed it with the first group, and it applies every child with no `spec.suspend`, so its first reconcile released the late group when `cnpg` turned Ready: Grafana's pods and Zitadel's `init` Job were created while `dbs` was still loading (no loss seen; a forced reconcile of the parent reset a suspended child within 10 s). Now `hold` suspends the parent first and reads every held Kustomization back as suspended (a reset one is suspended again, 3 attempts, then the step stops naming it), `resume` leaves the parent and the late group (`identity*` and `observability`), `identity` resumes the late group and the parent LAST, and a chain stopped between `hold` and `identity` says that they are still suspended. `load_dump` still tolerates only `cannot drop inherited constraint`. Holding `observability` also removed the Ready check that step `resume` made on the ExternalSecrets of Grafana, Loki and Alertmanager (they did not exist yet) and the Kustomization has `wait: false`, so step `identity` now also requires every ExternalSecret of the cluster to be Ready (next entry) and waits 30 minutes for the DAG instead of 15, which also doubles the time before a hung DAG fails. **WORSE, measured (a second proof lab, NOMINAL): `hold` 16 s against 5 s and 6 s, `identity` 168 s against 10 s (lab 28B).** **Re-proved on a cluster:** `hold` held 33 Kustomizations, the parent first, each read back as suspended; the parent, `identity` and `observability` stayed suspended through the whole of `dbs` (487 s) and were released 1 s after it ended, and the first Zitadel object was created 3 s after that release (4 s after `dbs` ended); `dbs` ended rc 0 with no stop. The hold landed 4 s after `external-secrets-stores` turned Ready; the code marks its join with OpenBao's Kustomization UNPROVEN and that race was not hit. The read-back is one clean read after a pause: it does not prove that a reconcile of the parent already running when it was suspended has ended, so the window is small, not closed. Rung: mocked (a double whose parent resets its children when resumed: red on the first candidate's code, green now; five mutants killed), then run on Scaleway.
- **DR chain, `identity`: the ExternalSecret `services-observability/grafana-oidc` is no longer counted while it is NotReady** (a regression of a candidate of this release, found by the same proof lab): it reads `grafana/oidc`, which only a console step puts into OpenBao and Grafana runs without, so it was `SecretSyncedError` on every default install and the step waited its 30 minutes (`1 of 19 ExternalSecrets are not Ready`; the 0.4.0 chain did not stop there because its check ran before the ExternalSecrets of `observability` existed). It is left out by namespace and name and named in the output; the 18 others stay counted (Loki's S3 keys and Alertmanager's URLs included), and the coverage of step `resume` is unchanged. `OA_DR_ES_OPTIONAL` replaces the list, empty counts every ExternalSecret. Rung: mocked (red on the candidate's code, green now; three mutants killed: no exclusion, name without namespace, the whole namespace), then run on Scaleway (a second proof lab): the step passed on a default install in 168 s and printed that `grafana-oidc` is not counted.
- **DR chain, `openbao`: the step waits for a STABLE state and restarts one pod at a time** (apps #184, same proof lab): the one-shot leader check passed 20 s after the restore (NOMINAL, 3 CP + 6 W), the active node moved to `openbao-2` seconds later and `openbao-0` followed no one for 24 minutes (logins answered 500) until its pod was deleted by hand. Now `OA_DR_STABLE_ROUNDS` (5) surveys in a row, `OA_DR_POLL` apart, must find every pod unsealed and naming an active node, with the same answers as the survey before (a move starts the count again); `OA_DR_STABLE_TRIES` (60) bounds it. A pod sealed or without an active node for `OA_DR_STANDBY_TRIES` (18) surveys is restarted once, ONE pod per survey, and only while the two others are unsealed (nothing is restarted while a pod is down, the one just restarted included) and one of them names an active node (an election is waited out, never restarted into). A pod still bad after its restart, `openbao-0` still sealed after the restore, or a state that does not settle stops the chain with the exact `kubectl delete pod` and `resume with --from-step shares` (not `openbao`, which would restore the snapshot again); a pod whose `sys/leader` cannot be read is a warning, and three of them pass as in 0.4.0. **WORSE on purpose, measured: 296 s (NOMINAL, 3 CP + 6 W, a second proof lab) against 20 s and 9 s; the 296 s add up from the constants of the code (a 180 s grace, the restart, five surveys 10 s apart) and were not timed apart.** A second `--only openbao` left `openbao-0` sealed for 8+ minutes in the lab and a pod restart cured it; the cause is not established, so the script does not restart `openbao-0` for that and the docs say not to re-run the step. Rung: mocked (a double whose active node moves after the first survey and whose old active node then follows no one: red on the 0.4.1 code, green now; eleven mutants killed, among them two pods restarted in one survey, a restart while a pod is down, and a restart while no pod has an active node), then run once on Scaleway: the chain restarted `openbao-0` itself, five surveys in a row found three pods unsealed with one active node, and 23 polls over the next 22 min 58 s found no pod without a leader address and a Kubernetes-auth login that worked on all three; no pod was deleted by hand. The first 2 min 27 s after the step have no valid login proof, it is one run, and the cause is not removed: the restore leaves `openbao-0` leaderless and the chain works around it.
- **`dr-restore-plan` no longer waits 900 s for a Job the CronJob pruned (infra #427, lab 28B finding I19).** `kubectl create job --from=cronjob/...` gives the Job an owner reference to the CronJob, and `successfulJobsHistoryLimit: 1` deleted `dr-replicate` at the next scheduled run, so step `verify` read `NotFound` until its timeout (`cluster-verify` had passed). `job_from_cronjob` now creates the Job and patches the owner reference away (`ownerReferences: null`; a refused patch is a warning); a Job that is NotFound anyway (`dr-replicate`, `dr-check`) fails the step at once and says so, no 900 s wait. A Job that cannot be created stops the step at once with that cause (errexit is off in that part of the step), and a warning that kubectl prints on stderr next to a good answer no longer hides a finished Job. The by-hand recipe of `docs/disaster-recovery.md` (+ fr) carries the same patch. The jobs it creates now stay until deleted by hand or by the next run. Run on Scaleway in two proof labs: `dr-replicate` and `dr-check` ended Complete with no owner reference and step `verify` did not stop (385 s and 482 s).
- **`dr-restore-plan --scenario etcd` frees an agent stuck `Terminating` and the in-place etcd restore has a recipe (infra #428, lab 28B finding I22; recipe: docs, script: mocked; the etcd scenario ran once on a cluster, the force-delete path did not).** After the restore the Cilium rollout waited its 300 s on one agent stuck `Terminating`, and a person force-deleted it. `etcd-check` now force-deletes the agent pods (`k8s-app=cilium`) that are `Terminating` after the first 300 s, ONCE, and waits once more; a rollout that is merely slow, with no pod `Terminating`, still fails after the bound and deletes nothing, and one that does not come back after the single retry stops the chain naming the recipe. The step is no faster (the same 300 s), it needs no person. New section "In-place etcd restore: the hand steps" in `docs/disaster-recovery.md` (+ fr), in order, from lab 28B (3 CP + 6 W, INCIDENT: Talos part under 5 minutes, about 42 minutes to a green `cluster-verify`): reset, script, stuck agent, a node whose pods stay unreachable (reboot, not scripted: the script cannot tell a dead datapath from a slow one), crash-looping controllers, verify. Not drilled as such; a later lab drill of the etcd scenario would give its figures. The etcd scenario ran once on Scaleway (a proof lab, 3 CP + 6 W, INCIDENT-class by design): from the reset of the three control planes the API and the 9 nodes were back 234 s later, `cluster-verify` green at 362 s, everything healthy at 429 s (about 42 minutes in lab 28B); the marker written before the snapshot was kept and the one written after it gone; two hand steps were needed (controllers crash-looping on stale informers, one stale Pending pod). **No agent was stuck `Terminating`, so the force-delete path was NOT exercised: still UNVERIFIED on a cluster, and so is the node with a dead datapath.**
- **Docs: the LB-ACL trap on the DR chain's `cluster` step** (`disaster-recovery.md` and its French twin): `Provider produced inconsistent final plan` on `scaleway_lb_acl.app_allow` stopped the step in both fresh Scaleway builds of the proof lab (INCIDENT, 162 s, then 370 s NOMINAL on the re-run); the page now says to run the same step again (`--only cluster,seedkey,flux,hold,generation` when the chain runs in two segments). Rung: documentation. **Not fixed in 0.4.1** (left to 0.5.0): every Scaleway build with `app_lb_allowed_cidrs` set pays one failed run, the first `cluster-up` of a fresh install as well (2 min 45 s and 3 min 28 s, INCIDENT, in the two proof labs) and the chain's `cluster` step (162 s and 231 s, INCIDENT).
- **`test-passphrase.sh` failed on about 1 hex draw in 16,000** (infra #416): the heuristic flagged a random `openssl rand -hex 32` that held a run of six identical characters (about 1 in 18,000) or `abcdef` / `123456` inside (about 1 in 140,000); figures computed. A Python replica of the old and new rules (checked against the bash function on 326 values, no difference) flagged 62 of 1,000,000 simulated `openssl rand -hex 32` draws under the old rules and 0 under the new (an independent run: 50 and 0); the new rules' own rate is computed at about 1 in 8,000,000, so that 0 shows the chance trips are gone, not a measured rate. For a hex value a run now has to reach ten, a common word has to start it or occur twice, and the distinct-character and repeated-block rules are unchanged; a non-hex value is judged as before. Still flagged for hex: fewer than 10 distinct characters, a repeated block (`0123456789abcdef` four times, `deadbeef` eight times), a run of ten, a common word at the start or twice. No longer flagged: one `abcdef` or `123456` inside, or a run of six to nine, so some typed values pass (for example `0123456789abcdeffedcba9876543210`): a weaker guard, on purpose. The test prints the flagged value and its rules. Rung: mocked (the bash function itself ran on 3,000 real draws, none flagged, which proves little alone: the old rules would flag about 0.2 of them).
- **`rung-receipt.py` accepts `Rung: none`** on a docs-only diff or from a bot (it refused PR #432's `Rung: none (docs-only diff…)`, run 41506308694): "none" counts as nothing declared, so a code diff still needs a rung, a pasted receipt is still judged and any other word is still refused. The reason after `none` goes in brackets or after a dash, with a space before the bracket or the dash (`none (docs-only diff)`, `none — docs only`, `none - docs only`); `none, docs only`, `none: docs only` and `none(docs only)` (no space) are refused like any unknown word. `CONTRIBUTING.md` and the PR template say so, and `test-rung-receipts.sh` runs the examples they give through the parser. Rung: mocked.

- **`task cluster-security` test 1.6 no longer fails on a correct cluster, and asks the cluster.** On the upgraded cluster of a proof lab its first run read 31 of 36 with `1.6 VMAgent scraping bounded: CNP VMAgent missing toEntities: cluster on scraping block`, its second 32 of 36. The check was `grep -A60 "name: vmagent" FILE | grep -q …` under `set -euo pipefail`: `grep -q` leaves at the first match, the upstream `grep` can take SIGPIPE and pipefail turns that into a failure (a race, so its rate depends on the load and the file: between 1 and 26 failures in 1,000 runs of the exact condition, from one archived lab loop (1 in 1,000 at a load of 0.35), an audit re-run (10 in 1,000 idle, 9 in 300 under load) and re-runs while fixing (8 and 20 in 1,000 on the 0.2.0 file, 25 and 26 in 1,000 on the file of apps d028aed; not archived); with a long file it fails every time, status 141). The file was `$REPO_ROOT/OpenAether-apps/…`, the sibling checkout of whoever runs the script (apps 0.2.0 on that host), not the cluster and not the ref Flux follows, so the line said nothing about the cluster, and it passed on a comment. It now reads the `CiliumNetworkPolicy` `vmagent` of `services-observability` from the cluster, puts the `toEntities` of its egress rules in a variable and matches `cluster` as a word: present passes, absent or `world` only fails, an object not found is a skip only when the operator HelmRelease `victoria-metrics-operator` is not found either (two signals, as the mesh checks of section 2 need; the Namespace is declared apart from the stack, so it is no signal), a fail when that HelmRelease exists or cannot be read, and any other API error is a fail. Tests first in `test-security-tests-checks.sh` (41 passed, 10 failed on the old script; 51 of 51 after) with a stub that answers only the exact jsonpath of the script, and a decoy sibling tree (a file that says cluster against a cluster that does not, the reverse, and a 10,000-line file on which the old pipeline condition failed 100 runs of 100); sixteen mutants and the old script, all killed, among them two changes of the jsonpath (`egress[0]`, `ingress`) that an earlier stub, which ignored the path, let through. Rung: mocked, plus a run of the script against kubectl 1.37.1 and a local stand-in API serving the vmagent policy of apps d028aed; not run on a cluster. 1.5, 2.4, 2.7 and 4.1 are not changed (above).

### Documented (0.4.1; infra #390, #392, #406, #419, #420, #424, the infra half of apps #176 and #182, and the pages the proof labs changed; the rung is in each entry)

- **Adding a worker re-applies the machine configuration of every existing worker, in place (infra #420)**: lab 28 (OVH, NOMINAL, a grow of the workers from 5 to 6) planned "0 to add, 5 to change" after the grow step, with no reboot seen. `docs/upgrade.md` and its French twin say so. Why the hash changes is not established; seen on OVH (lab 28, 5 to 6 workers: "0 to add, 5 to change") and again on Scaleway (a proof lab, 3 CP + 6 W, 6 to 7 workers, NOMINAL: "0 to add, 6 to change", applied in place, no reboot), UNVERIFIED on Outscale; left to 0.5.0.
- **What the pages say, corrected to what was established (infra #390, #392, #419, #424 and the infra half of apps #176 and #182).** `backup-policy.md` and `security-architecture.md` (and the French twins): the CNPG archive's server-side encryption: see the next entry (it was first written as "not shown to be applied" and a proof lab then read it). `resilience.md` (and the French twin): a new section records the lab 28 OVH figures with shape and NOMINAL/INCIDENT label, WORSE rows included; a CoreDNS tag change is not rolled out by `tofu apply`, the variable cannot be set from a tfvars and nothing compares the running tag with the declared one (the by-hand `kubectl set image` was not run in a lab); the database targets read 75 s node, 150 s zone, 30 s switchover, so the 122 s of a primary inside a lost zone is inside the zone target (not re-measured with the 30 s grace of 0.4.0; the zone drills since then read 60.0 to 102.2 s for the `ha` primary on Scaleway, 3 CP + 6 W, INCIDENT (59.2 s is the reading of a second test Cluster in lab 28C), and the page now says that two cases run past 150 s, a Cluster on a polluted archive path and a pooler pod pinned to a dead CoreDNS replica, with pointers to the apps pages); the Scaleway 13 s check is documented with its trade-off and as an interval-model reading that may not fit Scaleway (its transient check delay is not modelled, the member-down time was never read from the provider API), and the page no longer calls 13 s a minimum the providers allow (true for the Outscale interval and threshold only; the Scaleway Terraform documentation gives no range, and the 1 s minimum for the interval and the timeout on the Scaleway product page is read from internal review notes and was not re-fetched). The R4 gray-failure rows now carry the OVH lab 28 drill and the range of the three drills, 88.0 to 299.3 s of write gap (INCIDENT, one sample each, two providers), instead of "about two minutes". `capacity.md` (and the French twin) adds the forge-on requests read in labs 27 part B and 28 (262 % on 3 CP + 4 W, 302 % on 3 CP + 6 W); the forge's own share stays derived, not measured (the 1.9 vCPU between the two OVH readings leaves about 0.1 vCPU for it, under the derived +400 m, but the readings are not like for like). F-OVHREPL and F-SHRINKMEM now cite lab 28.
- **Server-side encryption of the CNPG archive is read as AES256 on both Scaleway stores; OVH and Outscale stay UNVERIFIED (infra #406).** A head-object of a WAL object read `ServerSideEncryption: AES256` on the primary bucket and on its replica twin (a proof lab on Scaleway, 3 CP + 6 W, at the 0.4.0 tags; both stores at the same Scaleway endpoint). Lab 25 (Scaleway primary, OVH replica) had read NO header on a WAL object of either store: that contradicts the proof lab for the Scaleway store, was not reconciled and has no known cause. OVH: lab 19 read the header on objects the copy job had written to the OVH replica, lab 25 none on a WAL object, so UNVERIFIED; Outscale was never read. `backup-policy.md`, `security-architecture.md`, `key-management.md` and the French twins say so. Rung: documentation, one head-object per store.
- **`docs/disaster-recovery.md` (and its French twin): the chain as a second proof lab measured it, the final WAL segment before a planned destroy, and `iam-admin` after a rebuild.** A table with NOMINAL and INCIDENT labels and the WORSE rows (above); the corrections of the independent audit (three invocations, one stop, one hand step; the wall figures contain INCIDENT time; "no split brain" is vacuous in a rebuild with no failover); a section for a planned destroy: a completed final base backup is not a restore point until its end WAL is archived (`backup-verify` FAILED on the primary store 86 s after both plugin Backups said `completed`, because the segment that ends the new backups was not archived yet; the page gives a retry-safe recipe and the rule itself is in the backup README of OpenAether-apps: switch the segment, wait until it is archived, copy, verify again, read the PASS lines and not the Job, which ends Complete by design when a check prints FAIL; the lab's own round cost 152 s; the recipe was checked against a stub `kubectl` only, never run on a cluster); the second run of the in-place etcd restore (chain 165 s, everything healthy 429 s after the reset, against about 42 minutes in lab 28B; only the easy half of the incident occurred, so the stuck-agent force-delete and the node reboot were not exercised); a section for the machine user: the Secrets `iam-admin` and `iam-admin-pat` do not exist after a rebuild (the chain restores neither), so the way back in for a locked human administrator that `zitadel-hardening.md` of OpenAether-apps describes is not available; the restored database still holds the pre-disaster user, and signing in again after a rebuild was NOT shown. No product change for either in this repository: no helper task, and the clearer message of `backup-verify` is OpenAether-apps' (0.4.1). Rung: documentation.
- **`docs/upgrade.md` (and its French twin): "From 0.4.0 to 0.4.1", the roll gates as a proof lab ran them, and the bare-pod refusal after two plans.** The refusal of a bare pod comes 96 s after the node is named (two per-node `tofu plan` checks run first) and 2 min 41 s after the command, so a refusal under 60 s of the command was not met; the three roll gates carry what Scaleway showed (above). Rung: documentation.
- **`docs/upgrade.md` (and its French twin): "From 0.4.0 to 0.4.1" says that the move ran at the lab-proven heads, on the apps branch, with the figures, the WORSE rows by the stated rule and what is not shown (the move from the tag); the section on a provider out of stock now covers an install.** Rung: documentation; the figures are those of one proof lab, one run each.
- **`PLAN_ONLY=1`: the banner, the task description and `first-cluster.md`/`upgrade.md` say that on Scaleway, the only provider run, a missing Talos image made the plan unreadable and the run end rc 201, and that OVH and Outscale were not run** (see the entry under Added); `test-cluster-up.sh` asserts the banner (red with the sentence removed, green with it). Rung: mocked for the banner, documentation for the rest.

**Correction (added in 0.4.3):** the 216 probes (27 spellings, among them `//metrics`, over HTTPS and HTTP on the four hosts swept: Grafana, Zitadel, OpenBao, a test application; 112 x 403, 0 bodies) and the Gateway refusal described above do not cover the forge host, which was not deployed in those labs (the list of what was not proven says so). A 0.4.1 cluster with the forge brick on is expected to answer `//metrics` and four more spellings on the forge host with the forge's metrics: measured at the 0.4.2 tags (about 11 KB, 66 families; no repository content or credential seen), the apps tree of 0.4.1 and 0.4.2 being the same (OpenAether-apps `[0.4.3]`), and 0.4.1 itself was not run with the forge. Plain `/metrics`, `/metrics/` and `/debug/metrics` were 403 on the forge too. In the sweeps at the 0.4.2 tags (54 spellings x 5 hosts x 2 listeners = 540 probes) only the forge host answered with metrics (Grafana, Zitadel, OpenBao and the test application: 0 bodies on the first response), so a cluster without the forge brick showed no exposure in them; "not affected" is NOT claimed: the Longhorn opt-in route was not tested, redirects were not followed, and the `%2F`, `%5C`, case and `;param` spellings were not followed beyond the first hop. Fixed in 0.4.3; see the OpenAether-apps `[0.4.3]` and the pointer in `[0.4.3]` above.

## [0.4.0] — 2026-11-01

0.4.0 is the **resilience release**. It pairs with OpenAether-apps 0.4.0, which must be tagged first: the `git_ref` default and the twelve `envs/*.tfvars.example` now pin OpenAether-apps `refs/tags/0.4.0` (they pinned `refs/tags/0.3.2`), and the tftest assertion on the rendered GitRepository follows. What it adds:

- Losing a node, a control plane or a zone, and its rebuild: drills with pass criteria and measured figures (`docs/resilience.md`); the failure limit through a provider load balancer is 15 s by the owner's decision.
- Backups complete, replicated and verified: the application-backups replica bucket exists in every mode and `cluster-verify` fails when it is missing (I16); restore tests; one ordered disaster-recovery chain, data verified 68 min 3 s after the declared disaster in lab 28B (target 8 h; not unattended, see the DR entries).
- No acknowledged data loss as a rule: CNPG synchronous replication, with a tested path to move existing databases from the 0.3.x spec (`docs/upgrade.md`).
- Every pinned thing has a declared pin, a converging command and a verify check (infra #408); the default Talos pin goes from 1.14.2 to 1.14.4; signed release tags with a check; an opt-in second sink outside the cluster for the audit log (class A).

**Upgrade path: 0.3.x to 0.4.0 only** (previous minor, the policy before 1.0.0), by the steps of `docs/upgrade.md`, "From 0.3.x to 0.4.0": lab 27 moved a cluster from 0.3.2 to the 0.4.0 head, lab 28B (Scaleway, 3 control planes + 5 workers) did it in two `cluster-up` invocations (a run stopped at the Talos tunnels is re-run with the same command, I13).

**Not proven, or waiting for quota (stated, not hidden):**

- Every Outscale row (E1, E2, E3, E4b, E6, R2, R3, G11b) waits for the quota increase and was not run at the final heads.
- The `union()` form of the apps alerts `CnpgBackupFailed` and `CnpgBackupStale` is covered by engine unit tests only, not read on a real store.
- The residual pooler exposure (a pod started or a cache expired in the first ~100 s of an outage) was sampled in 6 drills only.
- I5 (OVH hard reboot at 90 s) is mocked and OVH-only.
- The scheduled `backup-verify` run was not read (the manual run passed).
- G10e, E4, the DR chain and the move were proven on earlier heads (since then only docs, the I16 fix, the pooler parameter and the two alert rules changed).
- A production-style OpenBao share restore needs the owner's recovery keys (the development bootstrap is proven).
- G1 in ONE invocation waits for 0.4.1 (the tunnel port fix).
- 14 rows of the release gate are WORSE against the baseline; none is hidden, they are listed in the lab results.

The entries below are those of this release, each with the rung it reached.

Entries of the first part of the cycle (bug fixes, documentation corrections and safety nets after 0.3.1). No new scope there. Rung reached by the lines below: **mocked** (self-tests and doc checks); the infra items were not observed on a cloud. Lab 18 (Scaleway,
infra 7e367d9 / apps 75e464f, on branches) ran a nominal `cluster-up` in 9 min 07 s with `cluster-verify` at 15 passed, 0 failed; it did not exercise #293 or #360. It does not fix the two
infra issues the series set out to look at: #42 (the API unreachable for seconds during a control-plane roll) and #375 (the OVH hard-reboot window) stay open for 0.4.0, see below.
Not a compliance claim. The apps-side results (#134 partial, #143, #144) are in the OpenAether-apps CHANGELOG.


### Fixed (0.4.0, lab 28B finding I16 = infra #391 and the decision of 2026-10-31; rung: mocked, offline, UNVERIFIED on a cluster; the live proof is the next lab with `backup_immutability = off`)
- **A default install now has the application-backups replica bucket (I16, infra #391).** `ensure-buckets.sh` created the pair (`s3-<project>-<provider>-backups-<env>` and its `-backup` twin) only when `backup_immutability` was not `off`, so a default install had no twin, the second copy of the CNPG archive did not exist, and the apps CronJob `cnpg-store-replicate` failed with `NoSuchBucket` every 15 minutes (lab 22, lab 28B). The pair is now created in every mode; with `off` it is a plain pair (no versioning, no lock), as the state and logs buckets are, and `versioned`, `governance` and `compliance` behave as before. A pair created under `off` stays unlocked if `governance` or `compliance` is asked for later (object lock is set at creation): choose the mode before the first `cluster-up`. Tests first in `test-bucket-protection.sh` (the `off` case now expects seven buckets and no write call; failed 9 of 72 before, passes 81 of 81 after) and `test-audit-sink-buckets.sh`. `docs/first-cluster.md`, `docs/backup-policy.md`, `docs/admin-access.md` (and the French twins) count and name the buckets.
- **`task cluster-verify` fails when the named replica bucket is absent.** `app_backups_replica_check` in `scripts/dev/infra-verify.sh`, in "The state is backed up", asks the replica endpoint with the replica store's key whether `<backups bucket>-backup` (the name of `BACKUP_REPLICA_S3_BUCKET` in `cluster-identity`) exists: absent is a failure naming the bucket and what is lost, a store that cannot answer is UNCHECKED. Tested against the fake store in `test-bucket-protection.sh` (present, absent, a rejected key, access denied, and the wiring); `test-bucket-names.sh` pins the name in `main.tf`.
- **Documented, not changed:** the alert `BackupCopyJobFailed` reads the failed Job objects, so on a cluster that already failed it can keep firing after the bucket exists until those Jobs are deleted; a new install no longer fails the first run. The alert is unchanged here.

### Documented (0.4.0, decisions of 2026-10-31 delegated by the owner (FI, DR chain, OpenBao, #405); rung: observed on a cluster in lab 27 and 28B, docs only, nothing changed in the code)
- **The in-place restart of a primary with a connected pool: the target moves from 30 s to 35 s (FI).** `docs/resilience.md` and `docs/upgrade.md` (and the French twins): measured 26.3 s (lab 27 sitting 3), 31.4 s (lab 28B) and 33.6 s (lab 27 sitting 2) with `smartShutdownTimeout` already at 5 s. 30 s stays the design aim; it is the class of a switchover or a failover, not of this restart. Historical measurements are untouched.
- **Where the DR chain may stop (G10b, A11, I18, I19, I22).** `docs/disaster-recovery.md` (and the French twin), new section after the lab 27 measures: lab 28B timed the chain as one run, data back 43 min and verified end to end 68 min 3 s after the declared disaster (target 8 h), but it is NOT unattended: `dbs` ended rc 1 on `pg_restore` dependency errors although the data was back (Grafana, resumed one step earlier, had created its schema in the empty database), and `verify` waited 900 s for a copy Job that the CronJob's history limit had pruned; three steps were by hand (the break-glass token minted between two segments, the canary check and the scratch cleanup, the restore test `dr-check`). Each stop has its exact check by hand. The script fixes and the in-place etcd restore recipe are planned for 0.4.1 (no date).
- **The OpenBao raft restore is proven with the DEVELOPMENT bootstrap only (G10c).** `docs/disaster-recovery.md`: 7.4 s (lab 28B) and 8 s (lab 27 sitting 3) to a 3-member leader, 9 s for the chain's step; a production-style restore (recovery shares encrypted to the holders' keys, a quorum minting the token) needs the owner-held recovery keys and was not run.
- **OpenBao members may land two in one zone; no hard zone term in 0.4.0 (G15).** `docs/resilience.md` (and the French twin): lab 28B ran the experiments (b) and (c): over two zones the hard term gave 2 + 1, and a node without the zone key, or no node with it, leaves members Pending (a fresh install would not start). The risk is stated (a zone loss then loses the raft quorum) with a read-only command that prints the zone of each member; a `cluster-verify` line is planned for 0.4.1 (no date).
- **The image build needs about 12 GiB of free disk (#405).** `docs/first-cluster.md` (and the French twin) states the figure and the `OA_IMAGE_MIN_FREE_GIB` preflight of the E5 fix; the 4.5 GB first reported was too low.

### Documented (0.4.0, owner decision of 2026-10-31 (option A) on the load-balancer limit; rung: docs only, nothing changed in the code)
- **The failure limit of a window that depends on a provider load balancer's health check moves from 10 s to 15 s (G5, R3, E6).** `docs/resilience.md` (and the French twin): the longest run of failed HTTP samples through the app load balancer on a node or zone loss, and the `/readyz` gap through the API load balancer on a control-plane loss, are now at most 15 s (the 10 s of the 2026-10-26 criterion stays for every other window; the 10 % failed-share limit, the database write-gap targets, the zero-acknowledged-loss rule and split brain are unchanged). Reason: the load balancer takes up to 13 s to drop a dead member (a check every 5 s x 2 failed checks + 3 s timeout), already the minimum the providers allow. Evidence, 1 Hz, NOMINAL clusters: Scaleway zone loss 11 of 12 readings within 10 s (one 13 s run, lab 28B) and 10 of 10 on a healthy WAL archive (lab 28C); partitions of a Gateway-pod node 12 of 12 (labs 28 and 28B); API through the load balancer 14 s in R3 (lab 28B); Outscale API load balancer 13 s computed, unproven until an Outscale drill. Earlier entries and lab tables keep the verdicts they were given against the limit of their day.
- **The in-cluster vantage keeps 10 s, with ONE accepted exception (G5, owner decision of 2026-10-31, option A).** `docs/resilience.md` (and the French twin), next to the 15 s paragraph: a probe from a pod does not use a provider load balancer's health check, so the 15 s does not apply to it. One in-cluster zone-loss reading broke 10 s and is accepted as an isolated, documented exception: lab 28 sitting 1 (OVH, 3 CP + 6 W c3-8), zone loss by simultaneous hard reboots (O8b), in cluster 5.6 % failed (13 of 232) with a 13 s longest run, the Gateway ClusterIP sending to a dead endpoint (not the load balancer's check); 13 of the 14 in-cluster zone-loss readings pass at 10 s (by the sample convention of the labs). Not fixed in 0.4.0; the cause is open work after 0.4.0 (no date).

### Documented (0.4.0, lab 28B finding I13 and the owner decision of 2026-10-31 (option A) on the move proof; rung: observed on a cluster in the lab, docs only, nothing changed in the code)
- **A `cluster-up` that stops at the Talos tunnels ("Address already in use") is re-run with the SAME command (I13).** `docs/upgrade.md` (and the French twin), after the lab 27 sitting 3 measure: lab 28B (Scaleway, 3 CP + 5 W) moved from 0.3.2 in TWO invocations; the first ended rc 201 after 3 min 13 s at `7/8 tunnels up ... bind [127.0.0.1]:52100: Address already in use`, with the infra apply COMPLETED (10 added, 5 changed, 10 destroyed) and no node rolled, no presync, no ref move; the same command again ended rc 0 in 37 min 41 s (41 min 56 s from the first launch), nodes already on the target version skipped. Cause: the tunnel ports (block 50000 + offset) lie inside the range Linux gives to outgoing connections, so a busy workstation can hold one. The move proved in two invocations is accepted for 0.4.0 (owner, option A); the fix of the ports is planned for 0.4.1 (no date).

### Documented (0.4.0, lab 28B finding I17 and the owner decision of 2026-10-30 (option A); rung: observed on a cluster in the lab, docs only, nothing changed in the code)
- **A node replace destroys the data of a `light` database (I17).** `docs/upgrade.md` (and the French twin), next to the I3 section: `cluster-roll` and `cluster-replace-node` create a new machine with a new disk, so the single copy of a `light` Cluster (node-local storage, no backup) on that node is gone; lab 28B (Scaleway) lost 42,583 acknowledged commits that way (roll rc 0 in 790 s, the cleanup then refused the volume). Outside the zero-loss rule by the owner's decision; the page lists the two reads to run before a roll and says to use `standard` or `ha`, or to accept the loss. A survey that names such Clusters and asks for an explicit yes is planned for 0.4.1 (no date).

### Changed (0.4.0, lab 28 sitting 1 findings I5, I2, I3 and the owner decision of 2026-10-30 (option A); rung: mocked, offline, UNVERIFIED on a cluster)
- **The OVH port guard hard-reboots a silent new instance after 90 s instead of 300 s (I5, infra #371).** `port_ready_hard_reboot_after_seconds` now defaults to 90 (it was 300; accepted range 60 to 600, it was 120 to 600; 0 still turns it off). Lab 28: 5 of 14 OVH creations were ACTIVE with a silent Talos and the automatic reboot at 300 s freed 5 of 5 at the first attempt (Talos answered within about 30 s), at a cost of 3.5 minutes each. Why 90 s cannot hit a healthy boot: every healthy OVH creation on record (26) answered at the guard's first poll, the guard starts after ACTIVE (about 13 minutes after in `cluster-up`), and a cold boot answers in 28 to 34 s. Tests: `test-wait-talos-port.sh`, `port-ready-recovery.tftest.hcl` (90 and 60 accepted, 59 refused). The 90 s value stays mocked until an OVH creation is trapped again.
- **The CoreDNS replicas spread over zones (I2, infra #388).** Lab 28: after an install all three replicas sat in ONE zone, on three nodes, so a zone loss could take every DNS replica. The zone term is now required (`DoNotSchedule`, `minDomains` 3, `nodeTaintsPolicy: Honor`) when the nodes carry three or more zones and every node has its zone label, a preference otherwise; in the inline manifest (`modules/talos`, from `node_zones`) and in `task cluster-coredns-ha` / `coredns-ha-patch.json` for a running cluster (the upgrade path, run by `cluster-up`). `cluster-verify` ("every critical pod group is spread over the nodes that can hold it") now fails when two CoreDNS replicas share a zone while another zone with an eligible node holds none and three or more zones have one: `cluster-rebalance.py` judges CoreDNS per zone and `task cluster-rebalance APPLY=1` puts it back. 0 extra pods, no new controller. Tests: `coredns.tftest.hcl`, `test-coredns-manifest.sh`, `test-cluster-coredns-ha.sh`, `test-cluster-rebalance.sh`, the drift guard of `test-pins-verify.sh`. UNPROVEN on a cluster (a three-zone cluster: lab 28 sitting 2).
- **Documented, not changed (I3):** a drain or `cluster-roll` of a worker that holds an attached RWX share-manager, or a single-instance (`light`) CNPG cluster, never completes (refusal after 900 s, rc 201, no damage; a worker without them rolls in 789 s): symptom, cause, what to do before rolling such a worker, and the 0.4.1 fix, in `docs/upgrade.md` (and the French twin). The owner accepts the RWX writer gap up to about 100 s on a failure (measured 97, 75 and 68 s): `docs/resilience.md`, targets table.

### Fixed (0.4.0, lab 27 part C, Outscale, 2026-10-28; rung: mocked, offline; each item names what the next Outscale lab must prove, UNVERIFIED on a cluster)
- **Critical pods that share a node while another node is empty are found and put back (E4, blocker class).** After a node loss or a drain the Gateway and the Barman Cloud plugin pods did not return to their spread (a spread rule is read at scheduling time only); both plugin pods landed on one node twice and a partition of it blocked a failover for 204 s (target 75 s). New `task cluster-rebalance PROVIDER=… [APPLY=1]` (`scripts/ops/cluster-rebalance.py`): for the Gateway, the plugin, the CNPG operator, istiod, CoreDNS and the Cilium operator it finds a node holding two pods of a group while an eligible node holds none (a shape with fewer eligible nodes than replicas is not wrong), and with APPLY=1 evicts the newest pod of a stacked node through the Eviction API, one at a time, and fails if it stays stacked. `cluster-up` runs it before its verdict, `cluster-roll` and `cluster-replace-node` at their end; `cluster-verify` FAILS on a stacked group. The apps side makes the plugin's node spread hard (see the apps CHANGELOG). Cost: 0 vCPU, 0 memory, no new pod (a descheduler was weighed and not taken: a new controller, 500 m / 256 Mi by chart default). Test: `scripts/dev/test-cluster-rebalance.sh`. Limit: nothing moves a pod back by itself when a node returns outside those flows.
- **The Outscale app load balancer is open when `app_lb_allowed_cidrs` is empty (E1).** It was closed to everybody (no 80/443 rule in the security group), against the variable's text. Empty now writes a `0.0.0.0/0` rule per port; a list still admits the list plus the cluster egress address. `tofu test`: `outscale_empty_list_with_lb_means_open`, `outscale_no_app_lb_no_rule`.
- **Outscale root volume type and IOPS are variables (E3).** `outscale_root_volume_type` (default `io1`; `gp2` restores the old behaviour, `standard`) and `outscale_root_volume_iops` (default 1500, 1 to 13000, a `check` warns above 300 per GiB): the hard-coded gp2 at 50 GB was 150 IOPS and starved containerd and the kubelet. New nodes only; io1 is billed for the IOPS (not measured). New `check` `outscale_platform_shape` warns when the workers minus one hold less than 9 vCPU with `deploy_flux`. `docs/capacity.md` (and the twin): the minimum supported shape per provider and what the default 20 vCPU quota allows (a bare cluster; the platform needs 3 CP + 4 W of 4 vCPU = 30 vCPU first). UNPROVEN: that the API takes an io1 root for the Talos OMI and that 1500 IOPS removes the starvation.
- **`cluster-down` no longer ends "fleet-down complete" over a provider that still holds the cluster (E5).** On Outscale 2 load balancers, a subnet, a route table, an internet service and the Net outlived it. `verify-provider-clean.py` lists them for Outscale and `fleet-down.sh` runs it after the destroy (4 attempts): a leftover fails the run and names `purge-orphans`; `OA_CLEAN_IGNORE=<id,id>` skips the stuck Net of #43. Tests in `test-teardown.sh` and `test-verify-provider-clean-outscale.sh`.
- **The Talos image build refuses early without about 12 GiB free (E5).** `oa_require_free_gib` in `scripts/lib/common.sh`, asked by `talos-image.sh` before the download (`OA_IMAGE_MIN_FREE_GIB`, 0 = off). Test: `test-image-disk-preflight.sh`.
- **The Outscale API load balancer takes a dead control plane out of rotation faster (E6, owner decision 2026-10-29).** It kept one in rotation 30 to 35 s (19 failed `/readyz` in 64 s on a ForceStop, target 10 s): check every 10 s, timeout 5 s, 3 failures. It now checks every 5 s, timeout 3 s, 2 failures, 2 successes to return, the shape the Outscale app LB already ran, from one local (`local.lb_health_check`, `modules/providers/outscale/lb.tf`) used by both. **Computed worst case 13 s (2 x 5 + 3), 8 s at best, not measured, and above the 10 s target; UNPROVEN until an Outscale drill** (stop a control plane, time its exit from the load balancer, target 10 s total), which waits for the Outscale quota. Plan on an existing cluster: the provider (outscale 1.8.1) marks `health_check` ForceNew, so `outscale_load_balancer_attributes.k8s` is REPLACED (1 to add, 1 to destroy; the destroy calls no API, the create is one `UpdateLoadBalancer`), not updated in place; the load balancer, its DNS name and its backends are not touched. Scaleway and OVH are unchanged. Test: `outscale-lb-health-check.tftest.hcl`. `docs/resilience.md` (and the French twin), "Lab 27 part C".
- **Documented, not changed:** both Outscale load balancers (and the bastion and NAT service) sit in ONE subregion (E2); the effect of losing it is untested and expected to take the whole edge (`docs/resilience.md`, "Lab 27 part C").

### Changed (0.4.0, critical-path HA audit and owner decisions of 2026-10-28; rung: mocked, offline, UNVERIFIED on a cluster)
- **The Cilium operator runs 2 replicas** (it ran 1: the owner believed it replicated). Production render only (`operator.replicas=2`, a PodDisruptionBudget of one disruption, a zone preference; the chart's required node anti-affinity stays, the pods are hostNetwork); the local Docker render keeps 1. `cilium.yaml`, `cilium-hubble-drops.yaml` and `upstream-artifacts.lock` regenerated (image unchanged). A cluster built by an older release keeps its 1 replica (Talos creates inline-manifest objects only when absent): `task cluster-coredns-ha` (inside `cluster-up`, before its verify) also converges the operator with `scripts/ops/cilium-operator-ha-patch.json`, and `cluster-verify` reports "the Cilium operator has 1 replica(s)" as BAD with the command. Tests: `test-pins-verify.sh`, `test-cluster-coredns-ha.sh`.
- **`docs/resilience.md` (and the French twin):** the `externalTrafficPolicy: Local` recommendation (option A of 2026-10-27) is replaced by the owner's decision of 2026-10-28 (Cluster + 3 replicas + hard node and zone spread + drain-safe termination, built in OpenAether-apps); the options table stays as history; new section "Critical-path audit" with the verdict per component; `docs/upgrade.md` states the operator change and its converge step.

### Fixed (0.4.0, lab 27 part B, OVH, 2026-10-27; rung: mocked, offline; the next lab must re-measure, UNVERIFIED on a cloud)
- **`task cluster-replace-node` / `cluster-roll` of a worker on OVH with the app load balancer on (F-OVHREPL, blocker for OVH operations).** The Octavia members `http[i]` and `https[i]` carry the instance's address, which is new after the replacement, so the config plan destroyed 4 resources and the destroy guard (2 expected) refused it at step 2; the targeted apply also left the Talos tunnel, the port check and the node identity on the old address. `rolling-replace.sh` now names the node's members in the config targets and counts them in the bound, and after the instance apply reads the new address from the state, refreshes the outputs, opens the tunnels again and uses the new identity (`SSH_KEY` reaches the script from both tasks). The guard is unchanged. Tests: `test-rolling-replace.sh` (members found and not a neighbour's, `instance_address`, the 4-resource plan passes with the bound and is still refused without it, the order of the steps). Lab 27 part B finished the replacement by hand in 8 minutes.
- **The capacity checks count memory, not CPU only (F-SHRINKMEM).** The pre-roll survey, the shrink guard and the dead-node survey read the memory rows of `kubectl describe nodes` (`worker_memory_requests`) and apply the same bound; lab 27 part B passed a shrink on CPU (272 % of 300 %) whose evacuated pods stayed Pending for lack of memory. A table without memory rows is said, not fatal. Tests: `test-rolling-replace.sh`, `test-shrink-nodes.sh`, `test-dead-node-roll.sh`.
- **An OVH instance that is ACTIVE but whose Talos never answers is hard-rebooted by the port guard (D6 / D11, infra #371).** New root variable `port_ready_hard_reboot_after_seconds` (default 300 in this first version, 90 since lab 28, see above; 0 off; OVH only): `wait-talos-port.sh` calls `node-provider.py hard-reboot ovh --younger-than 3600` after that wait, at most twice, only for a running machine created less than an hour ago (the guard also runs when a tunnel is down on a cluster that has been serving for days). 2 of 12 OVH creations hit the trap in lab 27 part B (+11 min and +5 min 23 s; the hand-run reboot freed them in 28 to 30 s). Tests: `test-wait-talos-port.sh`, `test-node-provider.sh` (the age limit), `port-ready-recovery.tftest.hcl`.
- **Documented, not changed:** the OVH figures of lab 27 part B in `docs/resilience.md` (and the French twin): real hard power loss 53 to 54 s, zone 77 s, R3 and R4, the load balancers, CoreDNS on a lost control plane (D5), the forge after a fast reboot (D7); and the cause of the HTTP rule failing, the options (Local traffic policy, a third replica, topology-aware routing) and the lab protocol with expected figures (D2): nothing of it is proven and nothing in the shipped data path changed.

### Fixed (0.4.0, lab 27 sitting 3, 2026-10-26; rung: mocked, offline; the next lab must re-measure, UNVERIFIED on a cloud)
- **The app load balancer carries an explicit TCP health check on every provider** (G5). Scaleway: `scaleway_lb_backend.http` and `.https` had the provider defaults (check every 60 s, timeout 30 s, 2 retries), so a black-holed worker stayed in rotation: a real partition of a node holding a Gateway pod failed 41 of 327 HTTP samples (12.5 %, longest run 14 s) at the lab-host vantage point. They now check every 5 s, timeout 3 s, 2 failed checks, on their own NodePort. Outscale: the app LB had no health check of its own (platform default: 30 s interval, 10 successes to come back); `outscale_load_balancer_attributes.app` now checks TCP on the http NodePort every 5 s (timeout 3 s, thresholds 2). OVH: already had its Octavia monitors (infra #375), unchanged. Not exposed as variables (the k8s API check is hard-coded the same way). The API load balancer check is NOT changed, and why is written in `docs/resilience.md` ("The app load balancer's health check"). Tests: `app-lb-source-filter.tftest.hcl` (the rendered backends and attributes carry the check; none without the app LB), mutation-checked. **UNVERIFIED:** that Scaleway and Outscale accept these values (the provider documentation gives no range for Scaleway), that the HTTP criterion is met at the lab-host vantage point (a dead Gateway pod stays in the Service endpoints until the node is NotReady, the check cannot remove it), OVH's `max_retries_down` default of 3.
- **`task cluster-up` with `deploy_flux` not true ends rc 0** (it ended rc 201 at the apps-ref step: the Flux CRDs do not exist; step 2 of the DR chain, a regression of the 0.4.0 apps-ref step). The CNPG presync, the cluster-identity sync and the apps-ref step are skipped with one line saying why (`deploy_flux` is read from `TF_VAR_deploy_flux`, else the env file, default false); `cluster-verify` already did not ask for the apps ref without Flux, and stays silent on CNPG when there is no CNPG CRD. **Kept on purpose:** the CoreDNS converge and the verify of CoreDNS, which Talos owns whether or not Flux is on. Test: `test-cluster-up.sh` (file, default and environment cases, with the Flux steps made to fail; a control with Flux on), mutation-checked. Not re-run on a cloud.
- **`cluster-replace-node ... -- --even-if-running` without `--ip=` on a node whose Node object is gone** stopped with a one-line message, and the docs said the address was needed for a control plane. The message now says it is needed for a worker too and prints the whole command with the node's name, and the addresses the state holds (control planes and workers). Docs corrected (`upgrade.md`, `resilience.md`, both languages). Deriving the address from the node name was not done: the index in the name is not an identity the provider agrees on, and a wrong guess in a dead-node replacement destroys a machine. Test: `test-dead-node-roll.sh` runs the real script in a throwaway tree, mutation-checked.
- **`cluster-shrink-plan` refuses on node-local volumes with the next commands** (cordon, delete the claim, delete the PersistentVolume, plan again) and `docs/upgrade.md` ("Removing nodes") has the evacuation recipe, labelled as observed in lab 27 sitting 3: a retained (`Released`) PV keeps the node pinned until it is deleted too. The guard is unchanged. Test: `test-shrink-nodes.sh`, mutation-checked.
- **Documented, not changed:** (1) `cluster-up` without `APPROVE=auto` creates and configures a new node BEFORE the first question (`grow-nodes.sh`, a 0.3.x design since infra #59, present at tag 0.3.2; also the image build and the buckets): `docs/upgrade.md` "Adding nodes", `docs/first-cluster.md`. Moving it behind the question is an owner decision. (2) Scaleway: two clusters cannot share a project (the subnet 172.16.0.0/22 is pinned in the module): `docs/capacity.md`. (3) The sitting 3 figures and their UNVERIFIED labels: `docs/upgrade.md` (one invocation 39 min 13 s, presync to ref 71 s, 40 Kustomizations Ready 6 min 43 s after the ref, primary restart gap 26.3 s), `docs/resilience.md` (real partition 68.6 s against 67.1 s graceful with no split brain, `kill -9` 9.8 s, OOM 10.3 s, the HTTP criterion NOT met at the lab-host vantage point for a partition), `docs/disaster-recovery.md` (OpenBao raft restore 8 s on a DEVELOPMENT bootstrap, the production share-quorum path NOT exercised; PITR 78-84 s; etcd restore into a scratch cluster 85 s), and the OpenBao zone-spread recipe that cannot use `kubectl label ... zone-` because Talos re-applies the label.

### Changed (0.4.0, owner decisions of 2026-10-27 after lab 27 sitting 3; rung: mocked, offline, stub-tested; evidence from ONE lab on ONE provider, UNVERIFIED on a cloud)
- **A live control plane is stopped gracefully before the roll replaces it** (F-CPFLAP). `rolling-replace.sh` (`task cluster-roll -- --node=<cp>` and the control-plane part of a full replacement roll): after the cordon and drain, `talosctl shutdown --force --wait=false`, then a bounded wait (300 s) until the node stops answering, then the unchanged path (etcd member removal, the two saved-plan applies, gates, uncordon). Why: lab 27 sitting 3 measured Lease-renew stalls of 46-97 s at every control-plane replacement of the earlier path and 8-9 s with 0 flaps of healthy workers in 2 of 2 replacements with a graceful stop first (the two load-balancer candidates were refuted: removing the control plane from the load balancer gave 8 flap episodes in 2 replacements). **Cost: about 4 minutes per control plane.** Skipped with a warning (current path) with fewer than 3 control planes, any control plane without a healthy etcd, or no healthy peer; a refused shutdown or a node that does not stop never ends the run. Dead nodes (`cluster-replace-node`) and the in-place `--upgrade` are unchanged. `--dry-run` shows the step. Test: new `test-cp-graceful-stop.sh` (gates, order in the flow, failures, dry run in a throwaway tree), mutation-checked. Docs: `resilience.md` and `upgrade.md`, both languages. **UNVERIFIED:** the shipped step has not run on a cloud (the lab arm was done by hand and then took the dead-node path); two replacements, Scaleway only.
- **OVH Octavia monitors set `max_retries_down = 2` explicitly** (Octavia's default is 3 failed checks before ERROR). Test: `app-lb-source-filter.tftest.hcl`, red at 3 or when absent. The k8s API monitor is not changed. Not measured on OVH.
- **Documented, not changed:** R4 (gray failure: write gaps 88-134 s, 0 false failovers elsewhere, HTTP 44 % failed at the lab host) is a known limit with no tuning of the primary lease, to be measured at OVH and Outscale; R3 (etcd leader partition: the API holds, 2 of 5 healthy workers NotReady 23-25 s, one unplanned failover) with the arithmetic that can be checked and what is not understood (`resilience.md`, both languages).

### Changed (0.4.0, owner decisions of 2026-10-26, lab 27; rung: mocked, offline; evidence from ONE provider, UNVERIFIED on the others)
- **`node_monitor_grace_period_seconds` now defaults to 30** (it was 0 = Kubernetes' 50 s). Why: the node power-off write-gap target (75 s) is met only at 30 s (lab 27, Scaleway: 82-86 s at the default, 62-70 s at 30 s, 49-62 s at 20 s), with 0 NotReady, 0 eviction and 0 failover in a 30 minute nominal soak at 30 s. **Shipped default 30 s, evidence from ONE provider; the default goes back to 0 if the OVH and Outscale labs flap.** The flaps seen while a control plane is replaced are independent of the grace (F-CPFLAP, `docs/resilience.md`). The variable is kept: 0 still means the Kubernetes default (the opt-out), the validation (0 or 20 to 300) and the derived kubelet values (below 40: lease = grace, status frequency = floor(grace / 4)) are unchanged; the default lives on the root variable, `modules/talos` keeps 0. **What an existing cluster sees:** its next `cluster-up` applies a machine config on every control plane and worker (about 7.5 minutes per apply in lab 27, no reboot), as part of the 0.3.x to 0.4.0 move (`docs/upgrade.md`). Tests: new `cluster/tests/node-failure-detection.tftest.hcl` (red if the default goes back to 0); the module test names its zero case explicitly. **UNVERIFIED:** OVH and Outscale, a soak at 30 s during a roll, the heartbeat rate at 100 nodes.
- **The HTTP criterion (D1) is re-posed:** longest run of consecutive failed samples at most 10 s AND failed samples at most 10 % of the drill window, by the 1 Hz probe (`docs/resilience.md`). Measured: longest run at most 9 s in every drill of labs 25 to 27; failed fractions 2-3 % from a pod inside the cluster, up to 9.2 % (40 of 436) from the lab host. The 10 % is fitted to these measurements; the old criterion (at most 5 isolated failures) was never met since lab 15c; two vantage points are used because one lab-host log had holes (10.9 s). Nothing about real clients was measured.

### Added (0.4.0, study LAB-B2 on blocker B2: moving existing CNPG databases from the 0.3.x spec to the 0.4.0 spec; rung: mocked, offline; evidence: a REDUCED real lab, UNVERIFIED on the full platform)
- **`task cnpg-presync PROVIDER=… [ROLE=…] [APPLY=1] [SCALE=1]`** (`scripts/ops/cnpg-presync.sh`): enables the 0.4.0 `spec.postgresql.synchronous` block on the live CloudNativePG Clusters BEFORE the apps ref moves. Selects the Clusters by the
  `openaether.io/managed` label in the platform namespaces (no name in the script; profile and `rt-*` Clusters left out). Dry run by default (exit 3 on a difference, exit 0 and silence when there is no CNPG Cluster); `APPLY=1` patches only that block,
  waits for healthy, all instances ready, `synchronous_standby_names` set and the replicas in the quorum, reloads the configuration on every instance after 120 s (R1), and at the timeout prints the break-glass steps (R2) and fails. It never deletes a pod
  and never forces. Refuses on an unhealthy Cluster, no recent Backup, a Talos or Kubernetes roll (the gate of `cluster-bootstrap-sync`, now shared as `oa_roll_gate` in `scripts/lib/pins.sh`), a pod that predates the plugin sidecar, and fewer than 3
  instances unless `SCALE=1`. `cluster-up` runs its dry run after the roll and before the identity and apps-ref steps (applied at `APPROVE=auto` or a typed "yes", else it fails naming the command). `cluster-verify` gains, for every such Cluster,
  the block, ContinuousArchiving, `synchronous_standby_names`, the replicas' `quorum`/`sync` state and the FailoverQuorum object (BAD with the command, UNKNOWN when unreadable). Tests: `test-cnpg-presync.sh`, `test-cluster-up.sh`, `test-pins-verify.sh`
  (each change mutation-checked).
- **Evidence, said plainly.** The study ran on Scaleway on a REDUCED lab: one k3s node per VM, no Flux, Talos, Cilium or zones, the real Cluster specs of 0.3.2 and the 0.4.0 branch, 20-35 commits/s per database, the recipe twice. Presync 54-57 s with no
  write gap; then the one apply of the 0.4.0 content: healthy in 95-100 s, write gap 17-22 s, 0 acknowledged commits lost, WAL archive contiguous (MISSING 0), replicas in the quorum. The 0.4.0 content applied in one go, without the presync, left a Cluster
  stuck in some runs (cloudnative-pg#11627, and an enabled plugin freezes every pod that predates the sidecar). **Not proven:** the real Flux apply, Talos, Cilium policies, three zones, production load and data, a node loss in the window, Outscale and OVH.
  `docs/upgrade.md` ("From 0.3.x to 0.4.0") has the steps, the break-glass R1/R2 and the rule: no promote or switchover while a pod predates the plugin sidecar. Not a compliance claim.

### Fixed (0.4.0, lab 27 sitting 2 findings F-SHRINK, F-HINT, F-STOCK; rung: mocked, offline, UNVERIFIED on a cluster; lab 27 sitting 2 reproduced each on Scaleway)
- **F-SHRINK** (regression against 0.3.x) `task cluster-shrink-plan` refused every shrink: the zone-label part of `machine_config_version` hashed the per-worker label list, so lowering `workers` changed it and replaced the config apply of every surviving node ("the plan changes more than the removal"). The trigger now covers the control-plane labels and whether any worker is labelled (a node's zone never changes in place); the shrink guard is untouched. `modules/talos/tests/node-zones.tftest.hcl` renders 3 and 2 workers and requires the same trigger and the same labels on the survivors (it fails on the old hash). The CoreDNS manifest hash also follows `min(3, nodes)`, which does not move while three nodes or more remain, the only shape a shrink leaves.
- **F-HINT** The line printed after a dead-node `cluster-replace-node` named `cluster-replace-node ... -- --clean`, which refuses a Ready node; it now names `task cluster-replaced-node-cleanup NODE=<n> -- --clean`. `test-node-recovery.sh` checks the printed text.
- **F-STOCK** A replacement that failed after the destroy (provider out of stock) left Flux suspended and every CNPG budget removed: the EXIT restore of the roll made one attempt, hit "context deadline exceeded" while the API load balancer still sent calls to the destroyed control plane, and its check only reads. `finish_roll` now repeats the restore until it reads back (`RESTORE_TRIES` 6, `RESTORE_RETRY_WAIT` 15 s, all bounded); the re-run is no longer refused because the tainted server counts as a second delete. `docs/upgrade.md` (and the French twin) carry the recovery sequence of the lab. Create-before-destroy is not possible with the same name and address; a stock pre-check is described, not built. Tests: `test-rolling-replace.sh` (the old test that expected the leak now expects the retry; 7 assertions fail without the change).
- **FI** (docs) the in-place primary restart measured 33.6 s, not 12-25 s (`docs/upgrade.md`, `docs/resilience.md`).

### Fixed (0.4.0, lab 27 sitting 1 findings FA, FB, FI, FF; rung: mocked, offline, UNVERIFIED on a cluster; lab 27 reproduced each defect on Scaleway)
- **FA** `cluster-up` of a 0.3.x cluster stopped at the CNPG presync on a Cluster below 3 instances, and the documented rerun refused again: Flux, still on the OLD apps ref, re-applied the 0.3.x `cnpg` content at its 10 minute reconcile and reverted the presync (grafana-db back to 2 instances, `synchronous` gone on both Clusters). Now the presync apply and the apps-ref apply are ONE step with nothing between them but a re-read of the presync (applied again, twice at most, if Flux undid it; the run fails with the ref untouched if it does not hold). **Decision:** under `APPROVE=auto`, and after the typed "yes" of the combined step, `cluster-up` passes `SCALE=1` (a Cluster below 3 goes to 3 in the same patch; the head declares 3, and the stop was worse than the scale). What was measured: lab 27 ran "scale and synchronous in one patch" (2 min 22 s, zero loss); the order "scale, wait, then synchronous" was never run. Other refusals still fail the run. Flux was not suspended (it re-resumes a suspended child, and suspending the root would freeze the ref move). Tests: `test-cluster-up.sh` (mutation-checked against the previous Taskfile: 14 assertions fail).
- **FB** `cluster-up` ended rc 201 on the CoreDNS line of its own verify because the one-time patch was documented after it. New `task cluster-coredns-ha` (`scripts/ops/cluster-coredns-ha.sh`: dry run, exit 3 on a difference, `APPLY=1` patches `scripts/ops/coredns-ha-patch.json` with replicas and `minDomains` `min(3, nodes)`, waits for the rollout, idempotent, `coredns_ha = false` skips) runs inside `cluster-up` before the verify, with the same `APPROVE=auto` / typed "yes" handling as the other steps. Tests: `test-cluster-coredns-ha.sh`, `test-cluster-up.sh`.
- **FI** The in-place restart of a primary that the plugin sidecar forces waited out `smartShutdownTimeout` 180 s with a connected client pool: a 206.4 s write gap in lab 27, not the 17-22 s of the client-less reduced lab (`docs/upgrade.md` corrected). `cnpg-presync` now also patches `spec.smartShutdownTimeout: 5` BEFORE the move (CNPG reads it from its cached Cluster object at shutdown: no restart needed), and the apps repository declares the same value on every platform Cluster. Measured in lab 27 sitting 2: a write gap of 33.6 s with the Zitadel pool connected (6 s of it the first pull of the sidecar image), not the 12-25 s first expected; `docs/upgrade.md` and `docs/resilience.md` say so and keep the 30 s class for switchovers. Test: `test-cnpg-presync.sh`.
- **FF** (docs only) Enabling the Forgejo brick on a running cluster is a live `kubectl patch` of the root Kustomization path; `docs/upgrade.md` gives the exact patch and says `cluster-up` neither sets nor reverts it and `cluster-verify` does not check it. No tfvar was built; the issue stays open.

### Fixed (0.4.0, lab 26 findings F1, K1, K2, K3, C1; rung: mocked, offline, UNVERIFIED on a cluster; lab 26 reproduced each defect on Scaleway)
- **F1** `task cluster-up` ran `cluster-identity-sync.sh` and `cluster-apps-ref.sh` directly, outside the task environment, so `tofu output` stopped with "Backend initialization required" after the 41-minute roll (seen twice). It now runs the tasks (`task -x`), which carry the backend, the S3 credentials and the kubeconfig step. `test-cluster-up.sh` runs the step with no `TF_DATA_DIR` and no S3 variable against a tofu stub that refuses as the real one does (33 assertions fail without the change).
- **K1** A bare `task` reports the scripts' exit 3 ("differs") as 201. The `cluster-up` messages say so and name the exact command with `PROVIDER` and `ROLE` filled in; `docs/upgrade.md` lists the codes.
- **K2** The 0.4.0 CoreDNS HA does not reach a cluster built by an older release (Talos creates inline-manifest objects only when absent). `cluster-verify` gains "CoreDNS runs the declared replica count and spread" (BAD both ways, with the command); `scripts/ops/coredns-ha-patch.json` is the documented one-time patch; `docs/resilience.md` and `docs/upgrade.md` are corrected.
- **K3** `cluster-security` and `cluster-netcheck` export the cluster's `KUBECONFIG` to their scripts.
- **C1** After a drained `cluster-roll -- --node=` the Node object is kept, so `cluster-replaced-node-cleanup` found nothing while local-path pods crash-looped. It now names those pods, exits 1 and prints `... -- --disk-replaced`, which treats every volume pinned to the node as the old disk's with every safety rule kept; `cluster-roll` prints the command after a worker replace.

### Added (0.4.0, lab 26 findings D2 and H1; rung: mocked, default unchanged, UNVERIFIED on a cluster)
- `node_monitor_grace_period_seconds` (plumbing added with default 0 = Kubernetes' 50 s; the default is 30 since the "Changed" entry above): the kube-controller-manager's grace period and the matching kubelet heartbeat, 20 to 300 s. Nothing changes unless it is set, and it is not to be set until a lab proves a value: `docs/resilience.md` ("Failure detection time") gives the numbers, the CNPG `primaryLease` lever on the apps side and the experiment to run.

### Fixed (0.4.0, lab 25 finding D9: new `cluster-identity` values never reached a running cluster; rung: mocked, offline, UNVERIFIED on a cluster)
- **Cause, from the code and Talos's source.** The `cluster-identity` ConfigMap (and the GitRepository and Kustomization `openaether-platform`, hence `git_ref`) are objects of the Talos inline manifest `flux-bootstrap`.
  Talos's manifest-apply controller (`release-1.14`, read through a summarising fetch, not cloned) checks each object with a `Get` and applies it only when it is not found: an object that exists is never updated. The plan's
  "3 to change" is the control-plane machine configs carrying the new manifest text; the objects on the cluster keep their old data. Lab 25 saw exactly that (4 keys kept, `cnpg` and 8 dependants NotReady, `cluster-up` rc 0
  because `cluster-verify` reads neither the ConfigMap nor the Kustomizations). Not shown: a `talosctl get manifests` read, and the same test on the GitRepository and Kustomization.
- **`task cluster-identity-sync PROVIDER=… [ROLE=…] [APPLY=1]`** (`scripts/ops/cluster-identity-sync.sh`): dry run by default, shows the keys to add or change and exits 3 on a difference; `APPLY=1` merges only the rendered keys into
  the ConfigMap, reads them back, asks Flux to reconcile, and is idempotent. It reads the new non-sensitive root output `cluster_identity`, built once in `cluster/main.tf` (`local.cluster_identity`) and used by the bootstrap
  template too, so the two cannot drift (`flux-git-verify.tftest.hcl` compares them). `cluster-up` runs the dry run after the node roll and either writes (`APPROVE=auto`, or a typed "yes") or fails naming the command; it no
  longer ends green over a ConfigMap that is not what the config renders. Tests: `test-cluster-identity-sync.sh` (kubectl and tofu stubs), `test-cluster-up.sh`, the two tofu test runs. Not run on a cluster.
- **`docs/upgrade.md` (+ FR): "From 0.3.x to 0.4.0 (an existing cluster)"**: the ordered steps, the live `git_ref` patch, the identity sync, the Barman plugin note, and what lab 25 did and did not observe. Gateway API CRDs 1.6.0 and
  Istio 1.31.3 on an existing cluster are a REBUILD ASIDE, not an in-place hop; lab 25's 5-minute in-place Istio hop is reported but is not the supported path. Every step not run is marked UNVERIFIED. Still open: the `cnpg`
  Kustomization stayed "Reconciliation in progress" 10 minutes after the keys were added by hand (not investigated); the live `git_ref` command is `task cluster-apps-ref` (see Added, infra #408).
- The apps side (OpenAether-apps `CHANGELOG.md`): the replica bucket and endpoint default to a non-empty placeholder, so a missing key no longer nulls `endpointURL` and turns the database layer NotReady.

### Added (0.4.0, infra #408: every pinned thing gets a declared pin, a converging command and a verify check; rung: mocked, offline, UNVERIFIED on a cluster)
- **Supported upgrade path, owner decision 2026-10-24:** before 1.0.0 only the previous minor to the current one (0.3.x to 0.4.0). No path from older versions is built or documented. The in-place move of the 0.3.x
  apps content (Istio, Gateway API CRDs) was observed once, in lab 25; a rebuild aside stays an option; the supported, tested path is the one the release notes name.
- **`task cluster-apps-ref`** (`scripts/ops/cluster-apps-ref.sh`): dry run shows `git_ref`, the ref the live GitRepository follows and the live `GIT_REF` (exit 3 on a difference); `APPLY=1 [REF=refs/tags/X]` rewrites
  the tfvars (diff, backup `.apps-ref-bak`), patches those two fields only (never `spec.verify`), reconciles and waits for the revision of that ref with a timeout. Validates the ref like `variables.tf`; a branch is
  warned about loudly and refused as `REF=` without `ALLOW_BRANCH=1`. `cluster-up` runs the dry run after the node roll like the identity sync and ends by saying what it did NOT change.
- **`task cluster-bootstrap-sync`** (`scripts/ops/cluster-bootstrap-sync.sh`): compares Cilium and the seven Flux controllers with the lock-checked artifacts; `APPLY=1` server-side applies `flux-install.yaml` only, refusing
  a downgrade, more than one minor, a running controller the artifact dropped, and any Talos or Kubernetes roll in progress, then waits for the rollouts and re-reads. Cilium is never applied (exit 5): rebuild aside, with
  the reasons in `docs/upgrade.md`.
- **`cluster-verify`** (`infra-verify.sh`, shared readers in `scripts/lib/pins.sh`): "Cilium run the pinned version", "Flux controllers run the pinned version" and "the GitRepository and GIT_REF both follow the declared git_ref",
  each failing in both directions (behind and ahead), UNKNOWN when unreadable. Neither pin moved between 0.3.2 and this branch, so a 0.3.x cluster is not red for them.
- **`docs/upgrade.md` (+ FR)**: "Which version lives where, and how it reaches a running cluster" (table with PROVEN / UNVERIFIED) and "Cilium and Flux on a running cluster"; a release channel (semver range over signed tags) is a 1.0 option.
- Tests: `test-cluster-apps-ref.sh`, `test-cluster-bootstrap-sync.sh`, `test-pins-verify.sh` (kubectl stubs, mutation cases), `test-cluster-up.sh`. Not run on a cluster; the Talos inline-manifest rule is still to be shown on a node.
- Gap, not built: a declared-versus-running check for CAPI child clusters (`K8S_VERSION`, `TALOS_VERSION` in OpenAether-apps `apps/clusters/*.yaml`); `check-child-clusters.py` is static.

### Changed (0.4.0: the default Talos pin goes from 1.14.2 to 1.14.4; rung: mocked, offline)
- `talos_version` defaults to v1.14.4 in the cluster and local roots. 1.14.3 and 1.14.4 are patch releases (Linux 6.18.57, containerd 2.3.7, etcd 3.7.2); the only API change that could touch us is that `TimeService/TimeCheck` is no longer open to `os:reader` and PTP device paths are validated strictly: nothing in this repository calls `talosctl time --check` or sets a PTP device. **Not shown on a cluster yet:** the image build for v1.14.4 on each provider, a fresh cluster at 1.14.4, and the roll of a 1.14.2 cluster to 1.14.4 under the customer probes are checks of the final validation lab. A cluster built at 1.14.2 keeps its pin until its owner changes `talos_version`.

### Added (0.4.0, infra #318: a second sink outside the cluster for the audit log, class A, opt-in)

- **Design and settings**: `docs/audit-sink.md` (+ FR): the choice `audit_sink_placement` = `off` (default) | `other_provider` (proposed) | `same_provider_other_region` | `both` with what each survives and does not, the data path, key custody, failure behaviour, honest limits and the lab pass criteria. Variables `audit_sink_*` (endpoint and region per sink, prefix, lock mode `governance` by default or `compliance` only with `audit_sink_compliance_ack = true`, retention days); a `check` block and `scripts/lib/audit-sink.sh` refuse a sink that is not where its choice says (not another provider, the same region) before any bucket exists. Only the host names reach `cluster-identity`, and only when the sink is on.
- **Buckets**: `ensure-buckets.sh` creates the sink bucket WITH object lock on the store of the cloud that holds it, reads the mode and retention back, and **fails** (not warns) on any refusal. `backup-key-recipe.sh <tfvars> audit-sink|audit-sink-secondary`: a pair with no delete right at all; the OVH per-bucket isolation limit is stated.
- **Keys**: `seed-openbao.sh` writes `secret/audit/sink` (and `audit/sink-secondary`), create-only: endpoint, bucket, own S3 pair (`OA_AUDIT_SINK_S3_*`, else the holding cloud's keys, said loudly) and a 48-character repository password drawn there, printed nowhere, distinct from the backups'. `escrow-openbao.sh` escrows it to the custodians and `verify` compares it with the live one.
- **Proof**: `scripts/ops/audit-sink-check.sh` reads the lock back, checks per node and inode that the shipped ranges chain with no hole, reports a loss the shipper recorded, and decrypts a sample with the escrowed password into a scratch directory. Tests: `test-audit-sink-lib.sh`, `-buckets.sh`, `-check.sh` (real restic repositories), seed and escrow cases, `audit-sink.tftest.hcl`, the flux-bootstrap render. The apps side (shipper, delivery check, alerts) is in OpenAether-apps. **Rung: mocked/static; never run against a provider's object store or a cluster.** Not a compliance claim.

### Added (0.4.0, owner rule of 2026-10-22: no acknowledged data loss)

- **Databases replicate synchronously** (OpenAether-apps: `zitadel-db` and `grafana-db`, quorum, `dataDurability: required`, failover quorum; `grafana-db` at 3 instances). The write gap stays bounded, not zero (one writer; clients mask it by retrying); what is zero is the loss of acknowledged commits. Writes block, losing nothing, when no replica streams (alert `CnpgSyncReplicaMissing`). `docs/resilience.md` (+ FR): target row and the lab pass criteria of the zero-loss proof (NOT run on a cluster).
- **Capacity, honestly**: the third `grafana-db` instance adds about 100 m of CPU requests (derived +2.5 points of a worker: 4 workers about 226-231% against 300%, still passing; the two-worker zone still short, by about 1.1-1.2 vCPU instead of 1.0). `docs/capacity.md` (+ FR) say so; `check-doc-inputs.sh` fails if a capacity page stops accounting for it and no longer quotes a stale "0.45 vCPU of margin" in its 4-worker message.

### Added (0.4.0, owner decisions of 2026-10-21: signing, release tags, capacity)

- **Signer table and signed-commit policy** (#332): `docs/signed-commits.md` (+ FR) lists the VPS release key and GitHub `web-flow` with their fingerprints and public keys under `docs/signers/`
  (machine-readable: `docs/signers/signers.txt`). Policy: every commit on `main` is signed by a table key or `web-flow`, squash merges through the web interface, Renovate included. Flux has **no
  warning mode** for `spec.verify`; the warning period is the CI signature report, and `enabled = true` (refuse) is for 1.0.0. **Open: the maintainer's own key fingerprint** (placeholder, not invented).
  Rung: documentation, nothing run on a cluster.
- **Release tags are annotated and signed** (#386): `scripts/dev/check-release-tag.sh` refuses a lightweight tag, an unsigned one, and one signed by a key outside the table; the release checklist and skill
  push the signed tag first and use `gh release create --verify-tag`; `.github/workflows/release-tag.yml` repeats the check on a tag push. Rung: mocked (`test-check-release-tag.sh`, throwaway repository and keys).
- **Capacity, said plainly** (#389): the 4-worker examples survive one worker and either single-worker zone, not the zone holding two (224% requested for 200% left). A documented "5 workers zone-HA" profile (2 + 2 + 1)
  with a commented block in the Scaleway and OVH management examples; `test-failure-domain-check.sh` covers both shapes. Rung: arithmetic on stubs, no zone loss on five workers recorded.

### Added (0.4.0, milestone M4: loss of a node, a control plane or a zone, and its rebuild)

Owner rule: the OpenTofu-built management cluster has NO node self-healing and NO node autoscaling (those stay optional modules for the Cluster API clusters); it survives a loss through
spreading, budgets and replicas (OpenAether-apps `scripts/check-ha.py`), says so loudly with alerts that name the command, and is rebuilt by an operator command. Rung: **mocked** (stub tests,
fake provider API, mocked OpenTofu tests); **UNVERIFIED on a cluster**; the drills and pass criteria are in `docs/resilience.md` (EN, FR). Not a compliance claim.

- **`task cluster-node-state`, `cluster-node-recover`, `cluster-replace-node`** (`scripts/ops/node-recovery.sh`, `node-provider.py`). `state` is read-only (provider state, kubelet, Talos port, `VERDICT=`);
  `recover` hard-reboots a machine the provider says runs but is silent (OVH ACTIVE while dead, #49, #371), refuses when the tunnels rather than the node are down, bounded wait, destroys nothing;
  `replace` runs `rolling-replace.sh --dead --node=…` (new flags `--node`, `--ip`, `--dead`): a survey of the survivors (one node down only; etcd quorum without it, else `dr-restore-plan`), cordon without
  a drain, the etcd member removed BEFORE the Node object is deleted (its pods are freed at once instead of after the 5 minute toleration), the same saved-plan applies and gates as `cluster-roll`.
  Tests: `test-node-recovery.sh` (fake repository, real listeners for the tunnels), `test-dead-node-roll.sh`, `test-node-provider.sh` (fake provider API for OVH, Scaleway, Outscale). Scaleway and
  Outscale calls are written from the API documentation and UNVERIFIED against an account. A set -e trap in the `--node` lookup was found and fixed by the tests.
- **Roll gate for the API blip of a control-plane roll (#42).** After a control plane reboots the roll waits for its kube-apiserver static pod to be Ready and `/readyz` to answer, three polls in a row,
  and refuses to take a control plane down unless every apiserver serves (`wait_apiserver_ready`, `wait_apiservers_all_ready`; `test-roll-apiserver-gate.sh`, fails without the change). Whether this
  removes the 5-8 s blip is a cloud measurement. NOT done, owner decision 2026-10-21 (keep the roll gate only): HTTPS `/readyz` load-balancer checks (needs anonymous access to the health endpoints) and `--shutdown-delay-duration`; `docs/network.md` section 9.
- **Scaleway and OVH examples ship 4 workers of 4 vCPU** (owner decision 2026-10-21; 3 + 4 = 8 instances, 30 vCPU with the bastion; Scaleway 114 GB, OVH 64 GB of RAM). Lab 21 MEASURED the full platform on 4 workers at 223-228% of one worker (about 9 vCPU), 1.2 vCPU above the derivation: on 3 workers the same load is above the 8 vCPU `cluster-roll` leaves, so 3 would be refused and `cluster-roll`'s survey on the 4-worker cluster printed `223% requested, 300% available without one worker` (test fixtures now carry the measured figures; the old 7.55/7.85 derivation is gone from the docs). Losing the zone that holds two of four workers still leaves 200% for 224% (`failure-domain-check` says so; a fifth worker made it green, 243% in 300%). Quota flags, `first-cluster`, README, `check-doc-inputs` (requires 4) updated, EN and FR. The Outscale examples stay inside the 20 vCPU quota and say so. Rung: observed on Scaleway (lab 21).
- **Lab 21 (Scaleway, 3 control planes + 4 workers, 2026-10-21) drilled M4 for the first time; rung: observed on Scaleway.** Worker, control-plane and zone power-offs, undrained reboots, `cluster-roll -- --cp-only` (17 min 34 s, apiserver gate in the log between the three control planes, longest `/readyz` run 1 s), `cluster-replace-node` of a dead worker (260 s) and of a dead control plane (335 s, etcd member removed before the Node object, etcd 3/3, 3 apiservers), `cluster-node-recover` (one hard reboot; tunnels closed on purpose: nothing rebooted; kubelet silence simulated). Table in `docs/resilience.md` ("Measured in lab 21"): no data difference in any drill, HTTP longest failed run at most 3 s, but the criteria NOT met are named there: total failed HTTP samples per node loss 8-16 (target 5), database write gap 287-333 s when DNS or the primary sat on the lost node and 59 s on a reboot (target 30 s), and `NodeUnreachable` firing 6 min after a loss. Found and fixed in OpenAether-apps (NodeScrapeDown, FailureDomainLost on the kubelet scrape, AlertmanagerClusterDegraded, zone spread of the CNPG clusters and operator). Fixed here: `cluster-replace-node` now says what a CNPG instance crash-looping on the replaced disk needs (verified: delete its PVC and pod, clone in under a minute); the docs carry the measured CPU figures and the corrected Alertmanager criterion. Open, with issues: CoreDNS placement (Talos-owned), the 5 minute database failover on a lost node, the capacity of the two-worker zone.
- **`task failure-domain-check`** (`scripts/ops/failure-domain-check.sh`, read-only): for each failure domain, would its loss stop etcd, leave too few workers or too little CPU, break the OpenBao quorum, take a
  database or a Longhorn volume, or remove the Gateway. `worker_zones` joins `control_plane_zones` in the provider contract and the root outputs, and every node now carries the label
  `topology.kubernetes.io/zone` (talos module `node_zones`, `machine.nodeLabels`, folded into the replace trigger; byte-identical when a provider reports nothing). Tests: `test-failure-domain-check.sh`,
  `control-plane-zones.tftest.hcl` (workers), `node-zones.tftest.hcl`. That a Talos node accepts the label is UNVERIFIED.
- **Docs**: new `docs/resilience.md` and `resilience.fr.md`; `upgrade.md` ("A node that is already dead"), `network.md` section 9, `capacity.md` (about 345 m of CPU requests added by the HA work, derived, about 0.45 vCPU of margin left on the shipped 3 x 4 vCPU example), EN and FR.

### Observed and fixed (lab 23, Scaleway cluster + OVH buckets, 3 control planes + 5 workers, rung: observed on a cluster)

- **Synchronous replication, zero-loss proof, observed** (OpenAether-apps does the work; the table is in `docs/resilience.md`, "Measured in lab 23"): 0 acknowledged ids lost in every synchronous run; 817 and 1409 lost in the asynchronous control with a double fault. A primary lost together with a replica is not promoted (FailoverQuorum): a write outage for its whole length.
- **Audit sink (infra #318), first run on a real cluster and a real OVH store**: delivery, GOVERNANCE lock read back, decryption from the escrow, a window of 2 h 29 min without a gap, the outage drill (`AuditSinkStale` 22 min, `AuditSinkDown` 16 min 41 s: now `for: 5m` in the apps rule), the apiserver rotation window recorded. **Measured limit on OVH**: the dedicated pair lists every bucket of the project, can write a delete marker and can change the bucket's default retention (it cannot delete or shorten a locked version): `docs/audit-sink.md` sections 4 and 10 (EN, FR). The fix of the shipper that chased the growing file is in OpenAether-apps.
- `failure-domain-check`: a cluster with no Longhorn volume says so instead of printing UNCHECKED for every zone; it also named the single-instance `light` profile as losing its data with its zone. Capacity measured: 249% with the platform alone, 294% with three database profiles (`docs/capacity.md`, EN, FR).

### Observed and fixed (lab 22, Scaleway, 3 control planes + 5 workers, rung: observed on a cluster)

- The offline changes of the lab 21 follow-up below ran on a cluster: CoreDNS on three nodes (write gap 6 s when a replica's worker is lost, was 287 s), the 30 s toleration (database write gap 44-64 s for a primary on a powered-off worker), kube-state-metrics at two replicas (`NodeUnreachable` fires with one pod killed and the other lost), the 5-worker zone-HA profile (`failure-domain-check` green at 246%; each two-worker zone powered off 10 minutes, nothing Pending for lack of CPU), the replaced-node cleanup. Numbers and what stays open (a database primary inside a lost zone: 122 s) in `docs/resilience.md`, "Measured in lab 22".
- **`replaced-node-cleanup.py --clean` deleted nothing**: it ran `kubectl delete pod NAME pvc CLAIM` (three pod names) and then blocked on `kubectl delete pv`. Now `pod/NAME pvc/CLAIM` and `--wait=false`; the offline test pinned the broken string with a fake kubectl and now fails on any untyped `pvc` argument. Observed: every replica full 61 s after the command.
- `oa_protect_bucket` no longer reports a fully locked bucket as "NOT fully protected" when the store refuses to re-enable versioning on a bucket created with object lock (Outscale: `InvalidBucketState`), as long as the read-back confirms versioning. COMPLIANCE object lock itself was tried on a throwaway bucket per provider (see `docs/backup-policy.md`).
- Capacity numbers of the 5-worker profile measured (243-247%, not the derived 230%), `docs/capacity.md` EN and FR; example comments say 245%.

### Fixed (lab 21 follow-up, offline: infra #388, apps #154; to be proven by the next lab)

Rung: **mocked/static** (`tofu test`, a rendered-manifest test, a fake `kubectl`). Not a compliance claim; the lab pass criteria are in `docs/resilience.md`.

- **CoreDNS** (#388): `coredns_ha` (default on) disables the Talos-owned Deployment (`cluster.coreDNS.disabled`) and injects an inline `coredns` manifest with the same names, labels and ClusterIP:
  `min(3, nodes)` replicas on different nodes (hard hostname spread with `minDomains`, so a replica created before the other nodes exist waits instead of sharing one), a zone preference, a budget
  allowing one disruption, 30 s tolerations, requests 150 m in all (was 200 m). `coredns_image_tag` is Renovate-tracked. `tests/coredns.tftest.hcl` and `test-coredns-manifest.sh`. What a Talos upgrade does is
  written down, with what is UNVERIFIED. A NodeLocal DNS cache was evaluated and not shipped.
- **After `cluster-replace-node`**: `scripts/ops/replaced-node-cleanup.py` lists the volumes the old disk left behind (PVs pinned to the node and older than its new Node object) and the pods stuck on them,
  and prints the `kubectl` commands; `-- --clean` runs them for a CNPG replica with a healthy primary elsewhere, an OpenBao member with a raft majority left, Loki, vmstorage and vmselect with another Ready
  replica, and refuses the rest (the primary of record, an unknown workload, a lost majority). `task cluster-replaced-node-cleanup`; `test-replaced-node-cleanup.sh` (fake `kubectl`, 21 cases).

### Fixed (0.4.0, lab 20 finding, apps #153)

- **A cluster rebuilt by `dr-restore-plan` no longer archives into the dead cluster's WAL path.** New step `generation` (after `hold`): it lists `cnpg/<cluster>/` in both stores, takes the highest archive generation plus one and writes the ConfigMap `cnpg-archive-generation` (flux-system: `CNPG_ARCHIVE_SUFFIX`, `CNPG_ARCHIVE_PREVIOUS_SUFFIX`) that
  Flux substitutes into the Clusters' `serverName` (apps: `<cluster>-g2`…; no ConfigMap, no suffix, so installs and the lab 19/20 paths do not move). `--archive-generation N` forces it. Step `dbs` waits for Flux to apply the new name before the load and its PITR recovery reads the PREVIOUS path; step `verify` takes a base
  backup of each new archive, forces `pg_switch_wal`, requires `ContinuousArchiving` True and runs `cnpg-store-replicate` once before the restore test. `docs/disaster-recovery.md` (EN, FR): the RPO and the paths after a rebuild, what is UNVERIFIED and the pass criteria of the next drill. Test: `test-dr-restore-plan.sh`
  (generation from fake stores, previous path, order, failures, no aws call with `--archive-generation`). Rung: **mocked**; **UNVERIFIED on a cluster**. The apps side is in the OpenAether-apps CHANGELOG.

### Added (0.4.0, milestone M3: restore tests and disaster recovery)

- **`task dr-restore-plan`** (`scripts/ops/dr-restore-plan.sh`): the chain of `docs/disaster-recovery.md` as one command. Dry-run by default (prints the ordered steps with this cluster's commands, the inputs each step needs and which are missing; `--strict` makes
  a missing input an error, for a readiness check before the day). `--execute --confirm <cluster_name>` runs it: restore the artifacts, `cluster-up` with Flux held, the OpenBao seal key Secret, Flux on, hold the Kustomizations outside OpenBao's closure, restore the raft snapshot
  from the chosen store, put the recovery shares back, resume, restore the databases (a scratch Cluster recovered from the ObjectStore, optionally at a point in time, then `pg_dump | pg_restore` into the empty live Cluster, or the restic dump), resume identity, verify with a restore test on the rebuilt
  cluster. A check after each step stops the chain at the first failure and names the step to resume from; a TSV report gives seconds and target per step against the 8 h RTO. `--scenario etcd` restores the newest etcd snapshot with `talosctl bootstrap --recover-from`. Secrets travel on stdin or as
  files, never in argv. Offline test `scripts/dev/test-dr-restore-plan.sh` (stateful kubectl double, stub task, restic and talosctl): dry-run runs nothing, `--execute` needs the cluster name, the order, a failing step stops the chain, no secret in argv or output.
  Rung: **mocked**. The chain has not been run on a cluster; `docs/disaster-recovery.md` (EN and FR) now states the RPO of each dataset, the RTO target, the measured pieces (lab 15A, 15c, 19) and what is not proven.
- The application restore tests (daily CNPG recovery from both stores with a canary compare, weekly point in time, the dumps loaded daily, an opt-in Longhorn canary) are in the OpenAether-apps CHANGELOG; `docs/backup-policy.md` rows follow them.

### Added (0.4.0, milestone M2: backups complete, replicated, verified)

- **Talos API access for the scheduled etcd snapshot** (`etcd_snapshot_api_access`, default true): the control planes enable `machine.features.kubernetesTalosAPIAccess` with the single role `os:etcd:backup` for the namespace `foundation-databases`,
  so the apps `etcd-snapshot` CronJob can take a snapshot without a credential on the bastion. On an existing cluster the next apply re-applies the control planes' machine configuration, one at a time; a reboot is not expected (UNVERIFIED on a
  cluster); `false` keeps the configs as they were. `tofu test` in `modules/talos/tests/talos-api-access.tftest.hcl` (off renders nothing and keeps the replace trigger; on grants only that role, only on the control planes).
- **`cluster-identity` carries `BACKUP_REPLICA_S3_BUCKET` and `BACKUP_REPLICA_S3_ENDPOINT`** (the `-backup` twin of the data bucket and the replica endpoint): the ObjectStores that read the CNPG archive copy from the replica store need them.
- **`scripts/ops/backup-key-recipe.sh`** (#368): prints, for the primary, replica or Loki pair, the rights it needs, its own bucket policy and the operator-only policy of every other bucket, with the real bucket names and no identifier; `docs/backup-policy.md`
  section 4 says how to use it (Scaleway measured, OVH and Outscale expectations, Outscale a source only while #377 stands).
- Documentation (EN and FR): the etcd snapshot and CNPG archive rows of the backup policy (the CNPG archive has no client-side encryption, stated), a deviation row in the key management page, the etcd restore from the restic repository.

### Fixed (found by lab 20, 2026-10-20)

- `dr-restore-plan` looked for the restic repositories under the bare `cluster_name` of the tfvars; they live under `CLUSTER_NAME` of the cluster-identity ConfigMap, which is `<cluster_name>-<environment>-<provider>`. Found by the dry run on a lab cluster; the test now expects the full name.
- `dr-restore-plan` kept the old cluster's kubeconfig and talosconfig after rebuilding: a cluster brought up after its state was destroyed has a new PKI, so the step `cluster` ended "the API does not answer" on a healthy, verified cluster. After each `cluster-up` the chain takes the identity OpenTofu has just written (the restored files stay as `*.old`). It also puts the recovery shares into `openbao-recovery-dev` when the fresh OpenBao is a development one.
- `dr-restore-plan` asked `kubectl get cluster`, which on a management cluster is the Cluster API `Cluster`: the step `dbs` waited 30 minutes for a database that was healthy. It names `clusters.postgresql.cnpg.io`, and the kubectl double refuses the bare name.
- `dr-restore-plan` failed the step `dbs` on `pg_restore --clean` exiting 1 for six "cannot drop inherited constraint" errors on Zitadel's partitioned cache tables, although the data had been loaded (151 tables, the canary chain intact). That one error is tolerated, any other still fails the step; the canary check follows.
- `dr-restore-plan` restored the databases with `pg_restore --no-owner` as postgres, so every table of the rebuilt Zitadel belonged to postgres and Zitadel logged "permission denied for schema queue" (145 tables of one owner, caught on a real rebuild). The restore runs `--role=<owner of the database>`; the double refuses a restore without it.
- The step `verify` of `dr-restore-plan` passed when the restore test Job only skipped (four SKIPs, exit 0). It needs a PASS line and no SKIP.
- `dr-restore-plan --scenario etcd` gave `talosctl` the talosconfig endpoint as the node: behind a bastion that is a tunnel (`127.0.0.1:52000`) and the call ended "invalid target". The node is `--control-plane-ip` (or the talosconfig's first node); the chain refuses a tunnel as the node.
- After an etcd restore the Cilium agents kept the old watch and no backend for the API Service, and about twenty controllers (Flux, CNPG, cert-manager) crash-looped until the agents were restarted; the etcd check restarts the agents and operator once the API and the nodes are back.
- **Documentation (EN and FR, second pass on lab 19):** `docs/backup-policy` says exactly what is not client-side encrypted: the CNPG WAL and base backups, and their copy on the replica store (same bytes, SSE-S3 requested; header read back on OVH objects in lab 19); the restic datasets are. The scheduled etcd snapshot now finds the control planes itself through the Kubernetes API (apps #150, OpenAether-apps CHANGELOG); the Talos API access feature of this repository is unchanged, and its endpoint `talos.default` is not relied on. Not proven on a cluster yet. Open: apps #149.

## [0.3.2] — 2026-10-22

0.3.2 is a **security patch** of 0.3.1. It pairs with OpenAether-apps 0.3.2, which carries the actual change (Zitadel v4.19.5 against three HIGH account-takeover advisories, a generated login session
cookie secret, wait4x 3.7.2, dated VEX waivers and an issue when the image scan fails: see its CHANGELOG). On this side the release only moves the pin: the `git_ref` default and the twelve
`envs/*.tfvars.example` now point at OpenAether-apps `refs/tags/0.3.2` (they pointed at `refs/tags/0.3.1`), so apps 0.3.2 must be tagged first, and the tftest assertion on the rendered GitRepository
follows. Nothing in the infrastructure is patched for these advisories; the infra image scan was green. The fixes below were merged on main after 0.3.1 and ship in this release. Bug fixes, documentation
corrections and safety nets, no new scope. Rung reached by the lines below: **mocked** (self-tests and doc checks); the infra items were not observed on a cloud. Lab 18 (Scaleway,
infra 7e367d9 / apps 75e464f, on branches) ran a nominal `cluster-up` in 9 min 07 s with `cluster-verify` at 15 passed, 0 failed; it did not exercise #293 or #360. It does not fix the two
infra issues the series set out to look at: #42 (the API unreachable for seconds during a control-plane roll) and #375 (the OVH hard-reboot window) stay open for 0.4.0, see below.
Not a compliance claim. The apps-side results (#134 partial, #143, #144) are in the OpenAether-apps CHANGELOG.

### Fixed

- **The repository settings check no longer goes red on a cancelled, unexpanded matrix run** (#293): `check-required-checks.sh` skips a check run whose name still contains a literal
  `${{` AND whose conclusion is `cancelled` (what editing a PR body while CI runs leaves behind). A successful run of that name and a cancelled plain unrequired one still fail. Three
  self-test cases, the first red without the change. Rung: mocked.
- **Documentation: finish every bastion replacement with a plan that says `No changes`** (#360), EN and FR: on Outscale the public IP link did not always come back in the same run (lab 11). The
  OVH and Scaleway equivalents are written as unchecked, and the text was not checked on OVH or Scaleway (lab 18 did not replace a bastion). No script changed.

### Not fixed, on purpose

- **#42 (API unreachable during a control-plane roll)** and **#375 (hard-reboot window behind the OVH load balancer)**: nothing safe is verifiable offline. The roll already hands etcd leadership over
  and gates on etcd 3/3; the remaining candidates (HTTPS health checks on `/readyz`, `--shutdown-delay-duration`, `externalTrafficPolicy: Local`) need a cluster and, for the first, the owner's decision on
  anonymous health endpoints. Both stay open, labelled for 0.4.0.
- **#286** looks fixed already on `main` (the harness unsets `VERSION` and has a case with a hostile `VERSION`): it is for closing after a Cléa run shows a verdict that comes from the dependency.

## [0.3.1] — 2026-10-19

0.3.1 is a **patch release** of 0.3.0: no new scope, the hotfix for the problems that block the goals of 0.4.0 (resilience and monitoring). It pairs with
OpenAether-apps 0.3.1. The `git_ref` default and the twelve `envs/*.tfvars.example` now pin OpenAether-apps `refs/tags/0.3.1` (they pinned `refs/tags/0.3.0`), so
apps 0.3.1 must be tagged first. Rung reached: **mocked** (plan-level tests), then **observed on a real cloud** for the fix below, on OVH in lab 17 (2026-10-19, one cluster, 3 control planes and 3 workers, a
reduced profile, torn down). Not a compliance claim.

### Fixed

- **OVH: the application load balancer pools get a TCP health monitor** (#375): `http` and `https` each have one (5 s delay, 3 s timeout, 2 retries), so a worker that is down
  is expected to leave the pool. **Result: PARTIAL.** Observed on OVH: after `tofu apply` both pools have the monitor and all three members are `ONLINE` (they show
  `ERROR` until the Gateway NodePorts exist, never `NO_MONITOR`; with the monitor deleted by hand they show `NO_MONITOR` again). The **failure window of a hard reboot of one worker is
  not shorter**: 23 s and 25 s with the monitor, 12 s and 23 s without it (n=2 each, curl at 1 Hz through the load balancer): the window follows the node's own downtime,
  and with a 5 s delay and 3 failed checks the member leaves the pool about as late as a quick reboot ends. The monitor helps a node that stays down, not a quick reboot. A plain drain was
  not measured. Two plan-level tests (monitors present, absent without `deploy_app_lb`). Scaleway and Outscale are untouched. `cluster-verify` does not check `NO_MONITOR` yet.

### Known limitations

- #375: the Gateway Service is `externalTrafficPolicy: Cluster`, so a drained node that is still up still answers its NodePort and the monitor cannot take it out of the pool.
- #375 improvement over a quick reboot is not shown (see above); do not rely on the monitor to shorten it.
- On OVH the first `cluster-up` again met the ACTIVE-but-unreachable fault of two nodes (#371); a provider hard reboot and a second `cluster-up` fixed it.
- The OpenBao, CNPG and Flux fixes of 0.3.1 live in OpenAether-apps; their lab results are in its CHANGELOG.
- Unchanged and still open: apps #134, #133, #124 and infra #42 (the issues list what each needs).

---

## [0.3.0] — 2026-10-19

0.3.0 is the second half of the pair with OpenAether-apps 0.3.0: a wave of **security hardening, all of it opt-in and off by default**, a larger
default system disk, and the tooling to check and operate what it adds. The infra code moves no Talos or Kubernetes version (Talos 1.14.2 and
Kubernetes 1.37.1, as in 0.2.0); the version upgrades of 0.3.0 are in the apps repository (table in its CHANGELOG).
The project follows ANSSI recommendations as far as possible. **Nothing here is a claim of compliance with any ANSSI document**: each entry
below names the requirements it addresses and the rung it reached (mocked, emulated, local Docker, or real cloud).

### Summary

- **Hardening, each option off by default:** node network filtering (`rules_only`, a per-port allow-list), node kernel/kubelet baseline and time sources,
  node log forwarding and Hubble drop logs, bastion OS baseline, named bastion operators and an SSH CA, closed bastion Internet egress, bastion log upload,
  an application load balancer source filter, dedicated key pairs and versioning for the backup stores, OpenPGP verification of the commit Flux applies,
  named short-lived Kubernetes identities, passphrase hygiene for the state, OpenBao seal-key escrow and `rotate-secret`.
- **Checks and tools:** `cluster-security`, `cluster-exposure`, `cluster-netcheck`, `rbac-review`, `s3-isolation-check`, `escrow`, `rotate-secret`,
  `bastion-harden-check`, `bastion-logs-pull`, a patch-policy signal, the end-of-life calendar, SBOM, a committed provider lock.
- **A 50 GB system disk by default** (see Changed).
- **Documentation:** a security documentation set with a French twin per page (`security-architecture`, `key-management`, `backup-policy`, `hardening`,
  `incident-response`, `threat-model`, `capacity`, `upgrade`, and others).

### Changed (behaviour of an existing setup)

- **Scaleway: the system volume of every node is 50 GB by default (`scw_root_volume_size_gb`, new variable; the 0.2.x default was 20 GB).**
  At 20 GB the full application stack left about 15.6 GB usable; lab 12 saw DiskPressure and 25 Zitadel pods evicted, lab 15c saw it after hours of
  in-place hops. A validation refuses less than 40 with `deploy_flux = true` (20 stays valid without Flux). An existing cluster gets an **in-place resize
  of its `sbs_volumes` at the next apply (no node replaced)**; Talos grows EPHEMERAL at the node's next reboot, so reboot the workers one at a time,
  drained, afterwards. Pin `scw_root_volume_size_gb = 20` in the tfvars to keep the old size (a full stack will not fit). Read the plan first:
  lab 15c moving a 0.2.1 cluster to this branch with the same tfvars planned the six root volumes 20 -> 50 GB in place and a Talos machine config change.
- **Outscale: `outscale_root_volume_size_gb` (new, default `null`)** sets the BSU root of **new** nodes only (the provider does not resize a running VM's
  volume; `ignore_changes` keeps a running node from being replaced). `null` keeps the OMI's size (about 11-12 GiB), which does not hold the platform:
  set 50, a `check` warns when `deploy_flux` is on and it is null. To grow a running cluster, replace the workers one at a time with `task cluster-roll`.
  **Raise the root IOPS too** (gp2 50 GB = 150 IOPS saturated the node in lab 15b, infra #376).
- **OVH:** the flavour's disk (`b3-8`, `c3-8`: 50 GB) is read from the account and a `check` warns below 40 GB. **Proxmox:** `root_disk_gb` default 50.
- **Scaleway: the application load balancer ACLs are standalone `scaleway_lb_acl` resources** (see Fixed). An existing cluster with
  `app_lb_allowed_cidrs` set sees them created at the next apply.
- **The example tfvars carry `deploy_flux = true` and `deploy_app_lb = true`** (Proxmox: Flux only). A file copied from 0.2.x examples without them
  built an infrastructure-only cluster; `check-doc-inputs.sh` now fails an example without them.
- **`bastion_internet_egress = closed` together with `bastion_baseline` is refused at plan time** unless `audit_logging = false` and no collector is wanted (the
  closed bastion cannot reach the package mirrors that auditd needs).
- **Cluster-up and its checkpoints:** the human checkpoints are unchanged. `APPROVE=auto` is the documented unattended path (it applies the saved plan
  files, never `-auto-approve`); without it the journey stops at three checkpoints and each says nothing was applied (`docs/first-cluster.md`, EN and FR).

**BREAKING:** none for a tfvars that sets nothing new, except the 50 GB disk default above on Scaleway (a plan that resizes volumes in place) and the
new `check`/validation on the disk with `deploy_flux`. Every hardening option defaults to the 0.2.1 behaviour; the default bastion render is byte for byte unchanged.

### Upgrade notes (from 0.2.1)

1. Read the plan: `task cluster-up` stops at it. Expect the volume resize on Scaleway; nothing else changes with unchanged tfvars.
2. After the apply, reboot the Scaleway workers one at a time, **drained** (`task cluster-roll` does it; a hand-typed `talosctl reboot` does not drain, and a worker
   that carries a CNPG instance must never be rebooted undrained, infra #358).
3. The apps side of the pair (0.3.0) moves Longhorn, CNPG, cert-manager, Kyverno, Loki and Grafana across several minors. **Do the hops in the order and
   with the pre-steps of `docs/upgrade.md` and of the apps `docs/patching.md`** (Longhorn 1.9 -> 1.10 -> 1.11 -> 1.12 with the CRD conversion pre-step; Loki chart
   procedure; Kyverno per-namespace Enforce spelling; CNPG operator hops with the switchover method). The `git_ref` default and the twelve `envs/*.tfvars.example` pin OpenAether-apps `refs/tags/0.3.0`, released first.
4. Turn on hardening options one at a time (the documents `docs/hardening.md` and `docs/security-architecture.md` list them with their rollback).
5. Provision the owner-held inputs the options need (operator public keys, SSH CA public key, OpenBao recovery PGP public keys, dedicated S3 key pairs);
   the full list of what an unattended run still needs from a person is in `docs/first-cluster.md`.

### Known limitations

None of these is hidden by a green check; each has an issue.

- **OVH S3 has no bucket policies through the S3 API** (`PutBucketPolicy` answers NotImplemented); OVH runs on the operator's keys and `s3-isolation-check` exits 2
  there. A dedicated pair needs the OVH API. Documented in `docs/backup-policy.md` (infra #379).
- **Outscale does not pass the stability criteria with the full stack (lab 16, infra #376).** On 3 CP + 3 W of 3 vCPU / 6 GB (the largest shape the 20 vCPU quota allows, 50 GB gp2 roots) a fresh
  install converged and passed the first hour; then a backup and restore, and later one drained worker reboot, started an IO and memory-pressure cascade (nodes NotReady in turn, pressure above 97%) that did
  not settle in an hour. A live change to `io1 3000` did not stop it. Probable cause (not isolated): the 6 GB nodes and the shared root disk (Longhorn, etcd and images on one volume); the examples now set the root size, but a shape that
  passes was NOT run on Outscale: it needs a larger quota (3+3 of 4 vCPU, `docs/capacity.md`). OOS also refused the EIM keys of a dedicated pair (infra #377).
- **The checkpoints of `cluster-up` stay in 0.3.0 (infra #381).** Without a terminal it stops at the phase-1 checkpoint on every run; `task bootstrap-phase2` is the way on (the messages name it now), and
  `APPROVE=auto` is the one-command path. Removing them is a later decision. Time to a working platform was 16 to 29 minutes in lab 16 (budget and phases: infra #374, 0.5.0).
- **The CPU gate of `cluster-roll` is all that is checked about losing a worker (infra #378).** Replicas with a required spread (OpenBao) stay short while a worker is out; the behaviour of losing nodes under load is 0.4.0.
- **CNPG `barmanObjectStore` is removed in CNPG 1.31** and **Kyverno `kyverno.io/v1` policies are removed in Kyverno 1.20** (apps #114, #113); 0.3.0 stays on CNPG 1.30.x and Kyverno 1.19.x.
- **The history is unsigned for now** (infra #332, #333): Flux commit verification (`flux_git_verify`) exists but cannot be switched on until a signing key is
  registered, and the GitHub rulesets do not require signatures or reviews yet. The maintainer will create a dedicated signing key later.
- **In-place hops not rehearsed:** Loki chart 6.25 -> 18 and Grafana 11 -> 13 across the major steps, Alloy, the Gateway API CRDs, Flux on the children, Cilium and
  Talos patch hops (apps #121). A fresh install lands on the new versions and was run (lab 12 onward).
- **First install on Scaleway with the app load balancer allow-list needs two applies** (the ACL plan is inconsistent until the NAT address exists, infra #361).
- **MinIO (local/dev profile) is archived upstream;** its waiver runs to 2026-12-31 (apps #104, the end-of-life calendar of the apps repository).
- **Kubernetes 1.37 is outside the range the upstream projects test** (cert-manager, CNPG, Flux and others, apps #105, #120). The labs ran on it.
- **OVH:** instances can go to ERROR at creation or stay ACTIVE but unreachable (infra #371, #362), the app LB pools have no health monitor (infra #375), and the OVH
  column of the first labs never ran (infra #366).
- **Not exercised since lab 11:** `rotate-secret --apply`, the Git break-glass, PKI revocation drill, FIDO hardware keys (infra #370); COMPLIANCE object lock is an owner decision (infra #369).
- **Day-1 steps stay manual:** `seed-openbao.sh`, the PKI signing with an offline root (human by design) and the Zitadel MFA enrolment before the first Grafana login.

### Validated on (all offline suites green on the head commit; the cloud runs are on earlier heads of this branch, the fixes found were re-run by the suites)

Real clouds, with Talos 1.14.2 / Kubernetes 1.37.1, each once, by hand or by script, **never repeated for stability**:

| Lab | Date | What |
|---|---|---|
| 11 | 2026-10-16 | Wave 2 options. Scaleway full DAG, Outscale reduced; OVH did not get past the first apply (platform no-egress, Octavia ERROR). 5 defects fixed. |
| 12 | 2026-10-17 | Fresh install at the final versions. Scaleway full DAG converged (cluster-verify 16/16, cluster-security 34/36 + 2 n/a, strict plan clean); Outscale reduced. |
| 13 | 2026-10-17 | Scaleway fresh install on the **defaults** (50 GB), bastion 37/37, isolation 10/10, RWX hang reproduced then fixed. |
| 14 | 2026-10-17 | Scaleway 3 CP + 3 W, OVH reduced: Longhorn backup/restore, CNPG restore into a new cluster, drained reboot 66 s, checksums intact. |
| 15a | 2026-10-17 | OVH complete: cluster-up 817 s, verify 16/16, security 33/36, bastion with closed egress, forward and reverse node filtering swaps, control planes replaced for real. |
| 15b | 2026-10-18 | Outscale, two full clusters (3 CP + 3 W): cluster-up 805/817 s, verify 16/16, security 33/36, bastion 38/38. |
| 15c | 2026-10-18 | Scaleway lifecycle from infra 0.2.1 + apps 0.2.0: 40 upgrade hops and drills over about 6.5 h; 20896 HTTP probe samples, 135 failed (0.65 %), one 73 s episode (a drain evicting the single Gateway pod). |
| 16 | 2026-10-18 | Final validation, from the shipped example files, unattended apart from what is named. Scaleway (3 CP + 2 W): two `cluster-up` commands (the known first-install ACL error), 54/54 Flux objects Ready 23.5 min after the start, verify 16/16, security 34/36, bastion 37/37, isolation 12/12, Longhorn backup and restore, CNPG restore into a new cluster, Kyverno enforce, TLS 1.3 with a hybrid group, drained and control-plane reboots. OVH (3 CP + 2 W, checkpointed path, 21 min of which about 13 are checkpoints): the same checks passed except the dedicated pair (not possible there). **Outscale (3 CP + 3 W of 3 vCPU / 6 GB) FAILED stability** after the first hour (see Known limitations); control-plane reboot, alert drill and final acceptance were not run there. On Scaleway and OVH `cluster-roll` refused the 2-worker shapes (172% of CPU requested): the examples now ship 3 workers, **not re-run**. |

Every lab was torn down and its provider account checked clean (`purge-orphans`, `verify-provider-clean`).

**NOT run (lab 16 added):** the break-glass and escrow drills, `rotate-secret`, Loki chunk deletion, bastion replacement, node add, and the webhook-receiver leg of the alert drill (alertmanager egress is default-deny); a roll that passes its capacity gate was not run on any cloud. Also not run: an etcd snapshot restore on a second cluster; a real node replacement through `cluster-roll` on Scaleway (printed only); the Istio hops; Alloy, Grafana,
Gateway API CRD hops; the Flux (children) and Cilium/Talos patch hops; Zitadel -> Grafana interactive login (MFA, no browser); OpenBao raft snapshot restore; dedicated key
pairs on OVH and Outscale; Loki retention expiry; FIDO keys; Proxmox; the signed-history path (no signing key yet); the cloud workflow of the CI. Nothing ran for days;
the longest run is the 6.5 h of lab 15c.

---

### Detail of the 0.3.0 entries

ANSSI hardening work, not released yet. **Nothing here is a claim of compliance with any ANSSI document**: each entry names the requirements it addresses and the rung it reached.

### Validated

- **ANSSI first wave on three real clouds, 2026-10-15: once per cloud, by hand, with the apps branch `claude/anssi-wave1` followed by Flux.**
  Infra `1de00a4`, then the fixes listed under Fixed up to `030933d` (the labs were moved to each fix as it landed). Scaleway and OVH ran the
  full DAG (36 Kustomizations), Outscale the reduced apps profile only. What was seen:
  - **Escrow and rotation, on all three clouds:** `escrow export` to two custodians, `verify` (the seal key rebuilt from the escrow alone has
    the live key's sha256, the restic password and the three recovery shares match), `attest`, then `cluster-security` 4.7 green (2 holders);
    the apps CronJob `openbao-escrow-check` read the attestation ("attested 0 day(s) ago by 2 holders", Outscale). `rotate-secret` dry run,
    `--apply` (version 1 to 2, ExternalSecrets nudged) and the refusal of `backup/restic` (OVH, Outscale).
  - **Bucket protection `versioned`:** versioning and a 60-day non-current-version expiry read back on all seven buckets of each cloud.
    `s3-isolation-check` exits 2 and says nothing is isolated when no dedicated key pair is given, as designed.
  - **App load-balancer source filter (Scaleway):** the allow (admin address, the VPC ranges, the NAT gateway) and deny ACLs are on both
    frontends (read back from the provider API). With a list that excluded the admin host, the connection was reset on 80 and 443; with the
    list restored the Gateway answered `301`. Both changes were in-place updates and the public address did not change.
  - **Read-only checks:** `cluster-exposure` (22 and 6443 only, plus 80/443 on the app LB), `cluster-netcheck` (7 of 7 denied on Scaleway and
    OVH), `cluster-security` 34 of 36 on Scaleway and OVH with the escrow check on (the 2 left are skipped checks: no MinIO, shared keys).
    `rbac-review` flagged one binding on every cluster (see Fixed).
  - **Zitadel (apps B14):** the generated 32-character administrator password opens a session (201), `Password1!` does not (400).
  - **A bastion with the baseline, named operator and closed egress (OVH, replaced three times):** the operator `alice` logs in, is in
    `bastion-admins` and has no sudo; with the corrected template the hardening check passes 35 of 35 (80, 443, another address and 8200
    refused; the cluster ports on the subnet allowed; `nc`, `curl` and `tcpdump` purged; sshd directives and kernel settings as asserted).
    Before the fixes it failed 11 and then 4 checks, for the reasons under Fixed. `cloud-init status` says `done`, extended status
    `degraded`: `sudo: false` in the user list is deprecated in cloud-init 22.2 and later, and is in the 0.2.0 render too (left, to keep the
    default render byte for byte).
  - **Strict plan "No changes" on all three clouds at the end**, which also shows that the Scaleway ACL resources do not fight their frontends.
  - **Every replacement of the OVH bastion ended the first `cluster-up` as a 15-minute cluster health check failure** (the tunnels died with
    the bastion); the second run converged each time, and the failure is now explained by `explain-failure.sh`.
  - **Not run:** object lock (governance or compliance), a dedicated key pair for Loki or the backup stores (`OA_LOKI_S3_*`,
    `OA_BACKUP_S3_*`), FIDO hardware keys, the SSH CA end to end, host-key pinning on a real bastion, closed egress on Scaleway and Outscale,
    `bastion-logs-pull` upload, the `app_lb_allowed_cidrs` filter on OVH and Outscale, Proxmox. Of the apps changes only the first wave
    was in the lab (not the OpenBao TLS 1.3 and metrics work, which is on a later branch).

### Fixed

- **The shipped Scaleway and OVH examples can lose a worker and be rolled (#378, lab 16).** With the full stack, two 4 vCPU workers carried 172% of one worker's CPU requests (Scaleway 82% + 90%, OVH
  81% + 91%) and `cluster-roll` refuses above (workers - 1) x 100%. The management and failover examples now ship 3 workers (6 instances on Scaleway, 7 on OVH, 26 vCPU on both;
  quota flags and `first-cluster.md` updated, EN and FR). `docs/capacity.md` shows the arithmetic: about 90% of the limit at 3 workers, an estimate from two measured points, not run again. Outscale cannot
  reach a rollable shape inside the 20 vCPU quota (239% on 3 x 3 vCPU against 200%): its examples say so and name the smallest shape that passes on paper (3+3 of 4 vCPU, 26 vCPU), which was not run there.
  `check-doc-inputs.sh` fails on a 2-worker example.
- **The Outscale examples set `outscale_root_volume_size_gb = 50` (#376, #364).** It was commented out although `deploy_flux = true` needs it. The root volume type is fixed to gp2 in the module (no type or IOPS
  variable) and an `io1 3000` change by hand did not stop lab 16's IO and memory cascade on 6 GB nodes, so nothing here claims the cascade is cured: the examples and `capacity.md` say what was and was not shown.

- **The no-terminal stop of `cluster-up` names the command that goes on (#381, lab 16 on OVH).** Without a terminal and without `APPROVE=auto`, `cluster-up` stops at its phase-1 checkpoint
  on every re-run, even on a plan that says "No changes"; only `task bootstrap-phase2` reaches phase 2, and no message said so (three redundant stops, about 13 of 21 minutes). The stop message now
  names `task bootstrap-phase2` after the apply (and says a "No changes" plan needs no apply), and phase 2's own stop names `task kubeconfig` and `task cluster-verify`. The checkpoints themselves are
  kept for 0.3.0 on purpose (`APPROVE=auto` stays the unattended path); `docs/first-cluster.md` already described the sequence. `test-cluster-up.sh` fails without the messages.

- **`test-kubeconfig-new.sh` runs on OpenSSL 3.0 (found by CI on the 0.3.0 pull request).** The stub signer used `openssl x509 -not_after` (OpenSSL 3.4 and later) and the test read the
  subject in the 3.4 spelling; the CI image has 3.0. The stub signs with `openssl ca -enddate` and the subject is normalised. Run on 3.0.13 (a container) and 3.5.7.

- **The node roll docs warn about an undrained reboot of a worker with a CNPG instance (infra #358).** `docs/upgrade.md` (EN, FR): drain first; the roll commands do, a hand-typed
  `talosctl reboot` does not; the recovery after one. No tooling guard was added (the roll tooling does not run that reboot).

- **`s3-isolation-check.sh` asserts HeadBucket on each dedicated pair's own bucket (infra #356, #359).** A Scaleway pair without `ObjectStorageBucketsRead` and `s3:ListBucket`
  listed and wrote, passed the check, and then got a 403 on the first call of every barman-cloud WAL archive. The check now exits 1 naming HeadBucket and the IAM set to
  add; `docs/backup-policy.md` (EN, FR) states the rule and that OVH and Outscale are not verified. Tests in `test-s3-isolation.sh`.

- **`bastion-logs-pull.sh` shows tofu's error when it cannot read the backend (infra #352).** With `OA_LOGS_UPLOAD=1` and no saved copy, a tofu that could not
  initialise its backend printed "apply the infra first", which is wrong when the infra is applied. It now prints tofu's first lines and names the way out
  (the shell that applied the infra, `OA_TOFU_DIR`, or `OA_BACKUP_TARGETS_JSON`). Test case in `test-bastion-logs-pull.sh`.

- **`bastion-harden-check.sh` says which check it skipped (infra #372).** Without a control plane address (4th argument, `OA_CP_IP`, or the tofu output, which
  needs the shell that applied the infra) check 5 is skipped as before, but the summary now lists it (`SKIPPED: 5 (...)`), and `BASTION_REQUIRE_ALL=1`
  turns it into a failure for CI or an unattended entity. Test cases added to `test-bastion-harden-check.sh`.

- **`task check-alerts` no longer calls `kube_job_failed` and the volume stats blind (infra #357).** They have no series while the platform is healthy
  (a failed Job, a CSI-mounted volume), so they are printed apart as "healthy state" and never fail `--strict`; a metric nobody produces is still
  reported. Test `scripts/dev/test-check-alert-metrics.py` (in `task test-scripts`).

- **The example tfvars set the platform switches, and the unattended path is written down (lab 15c).** The management and workload examples
  of the four providers now carry `deploy_flux = true` and `deploy_app_lb = true` (Proxmox: Flux only): an entity that copied the file got
  an infrastructure-only cluster. `check-doc-inputs.sh` fails an example without them. `docs/first-cluster.md` (EN, FR) names
  `APPROVE=auto` as the one-command unattended path (it applies the saved plan files, never `-auto-approve`), the three checkpoints
  without it, and that a harness that refuses a blind apply needs the owner's permission for that command. The approval gates themselves are
  unchanged (skipping the question for a plan that changes nothing was considered and left to the owner). #361 keeps its hint: the
  two-phase ACL needs a real Scaleway apply to prove.

Found by the labs above, each with the rung it reached after the fix (mocked tests plus the real run that found it).

- **Scaleway: the app LB ACLs are standalone `scaleway_lb_acl` resources.** With the list in the frontend's inline `acl` block a real apply
  failed ("Provider produced inconsistent final plan: `.acl[0].match[0].ip_subnet` was null, but now ..."): the allow list holds the NAT
  gateway address, unknown before apply, and a mocked provider knows it, so no test saw it. The frontends ignore their `acl` attribute.
- **`rbac-review` flagged `system:public-info-viewer`**, a binding of every cluster (anonymous read of `/healthz` and `/version`). Only that
  binding to that role is exempt now; the same name bound to another role is still flagged.
- **`seed-openbao.sh` reloads the CloudNativePG clusters.** A Secret that appears after the database pods started is not seen by the instance
  manager ("failed to get envs: cache miss", `ContinuousArchiving` False) until the Cluster is annotated `cnpg.io/reloadedAt`; seen on
  Scaleway when the seeding came 30 minutes after the pods. The annotation brought archiving back in about a minute on both clusters.
- **`bastion-harden-check.sh` on a baseline bastion.** The unprivileged operator account (no sudo, by design) cannot read the 0600 sshd
  drop-ins or `/proc/sys/fs`; the check died silently after "=== 3", counted a loopback listener (the resolver stub) as an exposed port, and
  judged sshd from a commented line of the world-readable `sshd_config`. The baseline drop-in is now 0644 (directives, no secret); the check
  judges what it cannot read from outside (it must see exactly `publickey`), ignores loopback, skips `fs.protected_regular` and, with
  `BASTION_AUDIT=0`, the log-reader checks.
- **`bastion_internet_egress = closed` with `bastion_baseline` is refused at plan time unless `audit_logging = false` and no
  `time_servers`.** The security group is closed from creation, so the first boot reaches no mirror: auditd and chrony were never installed
  and cloud-init ended in error. Closed mode now purges `nc`, `curl` and `tcpdump` offline. The documentation said first boot was unaffected;
  it is corrected (EN and FR).
- **`explain-failure.sh`** explains a replaced bastion that ends as a cluster health check failure, like the refused-port shape.
- **Bastion with the baseline: `cloud-init status` says `done`, not `degraded` (lab 11, Scaleway and Outscale).** The baseline render writes `sudo: null` for the shared and named accounts (cloud-init 22.2 deprecates `false`; `null` also means "no sudoers entry"). The render without the baseline keeps `sudo: false`, byte for byte, because a changed user data replaces the bastion on OVH and Outscale (the released hash is pinned by `test-cluster-checks.sh`). Rung: render tests; `cloud-init schema` on a real image not run here.
- **A bastion without `audit_logging` can be read and pulled (lab 11, Scaleway and Outscale; closed egress forces `audit_logging = false`).** The persistent journald drop-in, `/var/log/journal` and the `adm` / `systemd-journal` membership of the shared account need no package and moved out of the `audit_logging` conditional of the baseline cloud-init (the render without the baseline, and the audit-on render apart from comments, are unchanged). `bastion-logs-pull.sh` checks what the account can read first (a denied `journalctl` used to read as "nothing new"), refuses with the reason when it is outside both groups, and skips the audit tarball with a message when `/var/log/audit` is absent (exit 0; it used to end `tar: Cannot open`, rc 2, nothing written). `bastion-harden-check.sh` with `BASTION_AUDIT=0` now skips only auditd and still asserts the journal, groups and login line; `BASTION_AUDIT=0` is documented in `docs/admin-access.md`. Rung: render tests and stub harnesses; a bastion built before this keeps the old template until it is replaced.
- **`task cluster-verify` can be green on a `deploy_flux = true` cluster (lab 11, Scaleway and Outscale).** The floor checks followed the infra-only default whatever the config said, so a seeded full-DAG cluster always ended `14 passed, 2 failed` ("flux-system exists", "an application load balancer exists and is billed"), with a message that called the first red "expected until the Day-1 seeding" (it is not). `infra-verify.sh` now reads `deploy_flux`, `deploy_app_lb` and `flux_namespace` (`TF_VAR_*`, else the env file; anything but `true` is false): asked for, Flux must exist with every controller Available and the balancer must be in the state; not asked for, Flux or a balancer still FAILS, with a message that names the variable. `.receipts/` is git-ignored, so the red run's receipt never dirtied the worktree; a green run now records rc 0. Rung: stub harness (`test-cluster-checks.sh`), not run on a cluster.
- **`bastion-fingerprints.sh` no longer says "apply the infra first" when it simply cannot read the backend (lab 11).** tofu's stderr was thrown away (`2>/dev/null || echo null`). It now keeps it: a state that cannot be read prints tofu's own last lines and the way out (the backend credentials and `TF_DATA_DIR` of the cluster exported, or `-f keys.json`); only a missing or null output says to apply the infra. Rung: stub tofu in `test-bastion-fingerprints.sh`. `bastion-logs-pull.sh` has the same pattern for `backup_targets` (unchanged here).
- **`etcd-snapshot-cron.sh`: a run that loses the lock no longer closes the winner's tunnels (lab 11).** The EXIT trap that closes the tunnels and prints "complete" was armed before the `flock`, so a second run (a cron run during a manual one) ended by closing the first run's tunnels and announcing a snapshot it never took. The cleanup trap is armed after the lock is acquired; before it, a trap only reports an early failure. New `test-etcd-snapshot-cron.sh` runs two real processes against one lock (stub `task`, tunnels and tools). Rung: stub harness.
- **Closed bastion egress also purges `wget` (lab 11).** The Ubuntu image ships it and the offline purge list (`curl`, `netcat`, `tcpdump`) left a downloader on a bastion whose point is that nothing leaves it. The closed render purges it too, and `bastion-harden-check.sh` (closed) now fails when `wget` is still there. Other tools on the image that can open a connection (`python3` and bash's `/dev/tcp`, which the check itself uses, `openssl`, the `ssh`/`scp`/`sftp` client) are not purged: they are needed by cloud-init, the checks or access, and a firewall in the VM is what closes the egress. Rung: render and stub tests; the purge itself was not run on a real image.
- **`cluster-security` 4.7: `OA_ESCROW_ANNOTATION_CHECK=1` alone is skipped on purpose, and now says so (lab 11).** The seal-key escrow record is required on `prod` only (the existing test "a dev cluster is skipped" is that intent), so the opt-in needs `ENVIRONMENT=prod` (`OA_ENVIRONMENT`) too. The skip used to read "strict only with OA_ENVIRONMENT=prod", which looked like an ignored opt-in; it now names both switches, the environment it saw (`unset` included) and the command. The header of the script and the task description say "both". Behaviour unchanged. Rung: stub harness.
- **`cluster-up` explains a failure of its second phase too (lab 11, OVH).** `bootstrap-phase2` failed with "Error bootstrapping node ... time is not in sync yet" and printed no hint, although `explain-failure.sh` knows the OVH router-without-egress shape: only `infra-apply` and `infra-plan` were wired to it. Phase 2 now drops the transcript first, tees its plan and apply into `.tofu-run.log` under `pipefail`, and defers to the explainer on failure; `test-explain-failure.sh` pins the wiring (it also checks that every deferring task tees). `grow-nodes.sh` runs tofu too but keeps its own tail-on-failure log, and `converge-versions.sh` runs none. Rung: Taskfile wiring tests and the real go-task harness (`test-cluster-up.sh`); not run on a cluster.

### Security

- **Review fixes of the first and second ANSSI waves (infra review of B10-B30). Static / mocked, not run on a cluster.**
  - `check-commit-signatures.sh` skips merge commits: on a PR run HEAD is GitHub's unsigned synthetic merge commit, so the documented `--strict`
    switch-on would have failed every PR. Its test now has a merge-commit case and expired-key/signature cases (status X/Y, throwaway key signed in the past).
  - `docs/signed-commits.md` (+ `.fr.md`) and the `flux_git_verify` comment no longer say Flux checks OpenPGP only: the vendored Flux also takes
    SSH keys (`.sshpub`). OpenPGP is this repository's choice, and SSH keys are NOT wired (the validation and the Secret take armored OpenPGP keys).
  - `kubeconfig-new.sh` no longer needs GNU `realpath -m`, `base64 -w0` or `date -d` (macOS operators); its test now checks that the temporary directory
    holding the private key is removed. The tests still run on Linux only, so the macOS path is untested.
  - `rotate-secret.sh --restart` waits only for the ExternalSecrets that read the rotated path, not every ExternalSecret of the cluster.
  - `task render-manifests` renders the dropped-flow Cilium variant too and `task render-check` runs the effective-config check on it (a Cilium bump no
    longer leaves the lock with the old variant hash).
  - The pid and lock files of `etcd-snapshot-cron.sh` and `local-admin-portforward.sh` live in `~/.cache/openaether` only (cron has no runtime dir, an
    SSH session has one: two lock files let a cron run and a manual run overlap).
  - `escrow-openbao.sh attest` refuses `--holders` above the receipt's recipients; the https-only Keystone guard is now tested in all five scripts.
  - Wording: `node_log_forwarding` is global (one apply re-applies every node; there is no "one node first"); the 192-bit passphrase threshold is 33, not 40;
    the Proxmox and Scaleway examples no longer offer `restrict_inter_node`, the Outscale one gained the `flux_git_verify` block.
  - It does NOT: add SSH signature support, a per-node switch for the log forwarding or the node baseline, or run anything on a cluster.

- **Critic follow-ups and the ops scripts that hold provider admin keys (B28, infra half). Static / mocked, not run on a cloud.**
  - `CKV_OA_3` (new Checkov custom check): an Outscale inbound `outscale_security_group_rule` with a literal `/0` range fails the hard gate.
    CKV_OA_2 cannot cover Outscale (no default-policy attribute), so such a rule used to pass unseen. Tested by mutating the real tree
    (`test-checkov-custom-checks.sh`). It reads literals only: a range coming from `admin_ip` is not judged, and Proxmox is still uncovered.
  - The five OpenStack-facing ops scripts (`purge-orphans/ovh.py`, `verify-provider-clean.py`, `delete-openstack-resource.py`, `ensure-capo-fip.py`,
    `preflight-quotas.py`) refuse an `OS_AUTH_URL` that is not `https://` (exit 2, nothing sent): the Keystone request carries the account password.
  - `local-admin-portforward.sh` and `etcd-snapshot-cron.sh` keep their pid and lock files under `~/.cache/openaether` (mode 0700; first written with `$XDG_RUNTIME_DIR` as an option, then fixed, see the review entry below)
    instead of a fixed name in `/tmp`, where another local user could plant a symlink (the lock redirection) or a pid list (`--stop` kills what it lists).
  - `disk_encryption_passphrase_length` (default 32, the released value, about 190 bits): 33 or more reaches the 192 bits the critic measured against
    PG-083's symmetric key size. For a NEW cluster only; on a live one it would replace the LUKS passphrase. Does not re-key an existing cluster.
  - Corrected a documentation defect: `docs/admin-access.md` told operators to forward `-L 8443:<gateway>:443`, which the bastion's `PermitOpen` refuses.
    The page now says so instead of promising a path that was never run. It does not open 443.

- **`flux_git_verify`: opt-in OpenPGP verification of the commit Flux applies, and a signature report in CI (default off; ANSSI SSDLC-CICD-AIP-03, SSDLC-CONT-REC06, B27).**
  `flux_git_verify = {enabled, public_keys}` makes the bootstrap manifest carry the Secret `git-signers` before the GitRepository and
  `spec.verify {mode: HEAD, secretRef: git-signers}` on it; off, the render is byte-identical (asserted). Validation refuses an empty
  key list, a non-armored or private key and a duplicate. `check-commit-signatures.sh` reports unsigned commits of a PR as a warning
  (`--strict` fails); CODEOWNERS names `.github/` and the bootstrap manifests; `docs/signed-commits.md` (+ `.fr.md`) holds the standard
  and the break-glass. Rung: mocked/static (`tofu test`, throwaway-key script test), not run on a cluster. It does NOT change any
  GitHub ruleset, check fingerprints, verify tags, or make the apps side carry the block (its component `git-verify` must be used too).

- **Named, short-lived Kubernetes identities through the CSR API, and an RBAC review that knows them (addresses ANSSI PA-022 R38/R40, PG-078 R15, NSA-12 AUTH-02/AUTH-03; audit B26, infra half: F04, F13, F20).** Rung: **mocked/static (`test-kubeconfig-new.sh` with a stub kubectl and the real openssl, `test-rbac-review.sh`, `test-security-tests-checks.sh`), not run on a cluster.**
  - `scripts/ops/kubeconfig-new.sh` and `task kubeconfig-new` (new, additive: nothing existing changes): files a CertificateSigningRequest (`kubernetes.io/kube-apiserver-client`, `expirationSeconds`, default 8 h, 10 min to 24 h accepted) for `CN=<name>`, `O=oa:readers` (default) or `O=oa:admins` (`ACCESS=admin`), using the `system:masters` kubeconfig only to file and approve it; key generated locally; request deleted afterwards; 0600 file outside the repository (a path inside it is refused); a signer that grants more than asked is refused. The groups mean nothing without the apps `platform-rbac` brick.
  - `rbac-review` and `cluster-security` 3.7 allow exactly the brick's two bindings (`oa-admins`: Group `oa:admins` to `cluster-admin`; `oa-readers`: Group `oa:readers` to `view`, cluster scope) and nothing else under those names (an extra subject, another group, another role or a RoleBinding is still flagged).
  - It does NOT: add OIDC or MFA (`apiserver_oidc` is not implemented: it needs a stable external issuer and can lock out the control plane, see the issue list of the batch), ship the apiserver audit log, revoke a single holder of a group before expiry (delete the group binding, or bind the user by name), remove or shorten the `system:masters` kubeconfig, or make anything compliant.

- **Node network filtering, explicit, a per-port allow-list, both off by default (addresses ANSSI PA-022 R16/R17/R19/R20; audit B24 OSN/F13 and ADM/F07).** Rung: **mocked/static (`tofu test`, `test-flow-matrix.sh`), not run on a cluster**.
  - One port list: the Scaleway `node_inbound_ports` map moved unchanged to `modules/providers/_shared/node-ports`, a locals-only module that Scaleway, OVH, Outscale and the Talos module all read, so the layers cannot drift. `tests/node-firewall.tftest.hcl` pins the four against it.
  - `restrict_inter_node` (new, default `false`, OVH and Outscale): `true` replaces the all-protocol `inter_node` rule and the `wireguard` rule (which named 51820 while Cilium listens on 51871) by one rule per entry of the list, members only, no DHCP. The two rules gained a `count` with `moved` blocks, so a default plan shows no change. The swap is not atomic.
  - `node_firewall_mode` (new, default `"off"`, byte-identical configs) with `node_firewall` (source CIDRs; `node_cidrs` required): `"port_allowlist"` (first named `rules_only`, renamed before any release because it promised a rule that drops nothing) appends a `NetworkDefaultActionConfig` with `ingress: accept` and one `NetworkRuleConfig` per flow, sources by subnet (nodes, bastion, pods, LB range), and changes `machine_config_version` so existing nodes receive the documents (config apply, no reboot expected).
  - It is NOT inert (lab 11, live nftables on Outscale nodes): a `NetworkRuleConfig` is an allow-list for its port even beside a default action of `accept`, so each listed port drops every source outside its listed subnets, ports that are not listed stay open, and a source missing from a list breaks the cluster. The sources per rule are in `docs/network.md` section 6; `etcd` is split so that the metrics port 2381 also admits the pod range (vmagent scrapes it from a pod). A rule with no source at all is refused at plan.
  - It does NOT: have a blocking default action (no such mode exists), filter Scaleway's private network, narrow etcd/kubelet to control planes, cover Talos services while Cilium is down (no Cilium host firewall), filter egress, or change `k8s_lb_mode`. Where a load balancer's health checks come from is unconfirmed per provider (listed in `docs/network.md`). `docs/network.md` section 5 and 6 and `LAB-CHECKLIST` B24 say what a cluster must show first.

- **Node logs and network-policy drops can leave the node, opt-in and off by default (addresses ANSSI PA-012 R2/R9, HYG-42 M36, BP-028 R71; audit B22, infra half).** Rung: **mocked/static, not run on a cluster.**
  - `node_log_forwarding` (new, default `null`): Talos service logs (`machine.logging`, `json_lines`) and, unless `kernel = false`, the kernel log (a `KmsgLogConfig`) sent over TCP to `endpoint`. TCP only (a UDP endpoint is refused at plan); the transport is **plaintext**, so private network only, and the receiver must be reachable from the host network (a ClusterIP is not, under `socketLB.hostNamespaceOnly`): a `hostNetwork` receiver on every node, or a fixed LB address. A hash of the settings is in `machine_config_version`, so an existing cluster actually receives them; unset, the machine configs and that trigger are byte-identical (tested).
  - `cilium_hubble_drop_log` (new, default `false`) boots Cilium from the new committed `cilium-hubble-drops.yaml`: the Hubble server only (no relay, no UI, no TLS material, **no TCP listener**), exporting only DROPPED/ERROR flows, field-masked (no payload), to the agent's stdout, where the existing pod-log collector reads it. `render-bootstrap-manifests.sh --hubble-drops` renders it, `--check` and `upstream-artifacts.lock` cover it, `check-cilium-effective-config.py` refuses a widened export. `cilium.yaml` is unchanged byte for byte.
  - It does NOT: ship anything by itself (the receiver and the Loki side live in OpenAether-apps), change the kube-apiserver audit policy (Talos's default Metadata policy stays; the file is collected by the apps opt-in collector), add a second sink outside the cluster, or touch the bastion. The `hubble-peer` Service and a declared (not listening) `hostPort` 4244 come with the chart.

- **Node kernel/kubelet baseline and node time sources, opt-in and off by default (addresses ANSSI BP-028 R9/R12/R13, PA-012 R5; audit B23, infra half: F18, F03, F19, F10, LOG-09, TLS-11, F14).** Rung: **mocked/static (`tofu test`, 63 runs in the talos module when written, 71 after B24/B28), not run on a cluster.**
  - `node_baseline` (new, default `null`): `sysctls` writes `machine.sysctls` on every node (`kernel.sysrq=0`, perf sampling limits, no ICMP/secure redirects or source routing in IPv4 and IPv6, `tcp_syncookies=1`, `tcp_rfc1337=1`), `sysctls_extra` adds or overrides, `panic_on_oops` is its own switch (a panic with a zero panic timeout hangs the node); `worker_default_seccomp` gives the workers the RuntimeDefault seccomp default the control planes already had; `pod_pids_limit` sets the kubelet `podPidsLimit`; `kubelet_server_tls` sets `serverTLSBootstrap`. A hash is in `machine_config_version`; unset (or all-default), configs and that trigger are byte-identical (tested).
  - `node_time_servers` (new, default `[]`): several NTP sources as `ntp.servers`, merged with the encrypted-DNS `bootTimeout` into the one `TimeSyncConfig` document. The bastion half already exists (`bastion_baseline.time_servers`).
  - `docs/hardening.md` (EN/FR): the sysctl deviation table (`ip_forward`, `rp_filter`, `pid_max`, `modules_disabled`, IPv6 kept) and a decision note on SELinux, sandboxed runtimes and `hostUsers`.
  - It does NOT: enable SELinux enforcing or mitigation kernel arguments (decision note; schematic change, not run), ship a kubelet-serving CSR approver (so `kubelet_server_tls` must stay off until the apps side has one; the `insecureSkipVerify` scrapes, Postgres `sslmode`, Istio TLS floor, LimitRange/ResourceQuota and the clock-skew alert are apps work), add NTS (Talos has none), or set `rp_filter`/`ip_forward`/`pid_max`.

- **Bastion OS baseline, opt-in: sysctl, auditd, journald, sshd directives, mounts, root-owned `authorized_keys.d`, in-VM nftables logging, key-type validation (ANSSI BP-028 R9/R11/R12/R14/R28/R29/R36/R38/R58/R73, NT-007 R14/R15/R23/R24/R26, NT-006 R3/R6, NT-SSH R8/R10; addresses the audit's F16, F04, F05, F07, F09, F03, TLS-15 and LOG-08).**
  New variable `bastion_baseline` (`enabled` default **false**; `audit_logging` default true; `restrict_ssh_source`, `time_servers`, `revoked_keys` default off/empty). With it off the cloud-init is **byte for byte
  what 0.1.0 shipped** (`test-cluster-checks.sh` pins the hash, now with the two extra template inputs), so no deployed bastion changes. **Turning `enabled` on changes `user_data`, which
  REPLACES the bastion on OVH and Outscale** (new IP, new host key, the Talos tunnels die with it; the plan decides on Scaleway and Proxmox): apply it on a fresh cluster or in a planned window with a second session
  open, never during a bootstrap or an upgrade, and read the plan first. `restrict_ssh_source` and `revoked_keys` put `admin_ip` / the revoked keys into `user_data`, so changing them replaces the bastion too.
  On: a sysctl file (R9 minus modules_disabled, R11, R12 minus the ARP options, R14), auditd with execve/`/etc`/mount/module/ptrace rules and **no `-e 2`**, a persistent journald capped at 200 MB / 90 days, a second sshd drop-in
  (`LogLevel VERBOSE`, `StrictModes`, `PermitUserEnvironment no`, `AllowStreamLocalForwarding no`, `GatewayPorts no`, `RevokedKeys`) that the runcmd deletes again if `sshd -t` rejects it, `AcceptEnv` commented out of the main file with a
  copy kept, `authorized_keys.d/<user>` root:root 0644, `/var/tmp` tmpfs noexec, `/boot` 700, umask 0077, sudo 4750 root:sudo, snapd/ModemManager masked, no tcpdump/netcat on new VMs, chrony on `time_servers`, and nftables
  rate-limited `nft-drop-in/out` log rules and ICMP in limited to echo-request and fragmentation-needed. Not changed: port 22, the user, the keys, `AllowTcpForwarding`/`PermitOpen`, the egress rules, `talos-tunnels.sh`.
  Always on (no resource changes): `bastion_ssh_keys` refuses `ssh-dss`, unknown types, a line break inside an entry and an `ssh-rsa` under `bastion_ssh_rsa_min_bits` (default 2048 so a deployed key keeps planning; 3072 selectable),
  checked on the type token (options prefixes and the truncated fixtures still pass). New: `scripts/ops/bastion-logs-pull.sh` (journal since a cursor + audit log off the VM, gpg-encrypted with `OA_LOGS_PASSPHRASE`; the upload came with the logs entry below),
  `bastion-harden-check.sh` probes with `/dev/tcp` instead of `nc` and gains section 9 (`BASTION_BASELINE=1`), and `task bastion-baseline-check`.
  Rung: **local Docker for the rendered files only** - `bastion-baseline-check.sh` runs the exact bytes on Ubuntu 22.04 and 24.04 (sshd -t, a real key login, the fingerprint in the login line, tunnels through `PermitOpen`, a revoked key refused,
  the guard removing a broken drop-in, `nft -c` and the ruleset loaded in a container network namespace accepting 22 from the admin source only, sysctl names in `/proc/sys`, audit rules parsed by libaudit, sudo mode, umask), `cloud-init schema`,
  `tofu test` for the input rules, stub harnesses for the two scripts. **Nothing booted a cloud image**: not proven are cloud-init ordering on a real first boot, auditd loading the rules in a real kernel, `journalctl` match syntax of the pull script,
  chrony taking the source file, `rp_filter=1` on a Scaleway bastion with its private NIC, that a provider keeps the admin source address, and the unattended-upgrades interaction (statoverride, masked units).
  Measured on the way: OpenSSH 8.9 already refuses unix-socket forwarding while `PermitOpen` is set, so `AllowStreamLocalForwarding no` is defence in depth, and the `Accepted publickey ... SHA256:` line already carries the fingerprint at the default log level (what `LogLevel VERBOSE` adds is the `authorized_keys` line number of the key and the session start/close).
  **Not done**: `restrict,port-forwarding` key options (they would change the interactive login path; `bastion-harden-check.sh` would need rewriting first), removing the `sudo` group from the login user (done below, with the baseline on),
  client-side `Ciphers`/`KexAlgorithms` in `talos-tunnels.sh`, `ListenAddress`, a cloud audit-trail export (documented as a manual procedure below, not automated), and the documented Grafana tunnel `-L ...:443` that `PermitOpen` refuses (a documentation defect in `docs/admin-access.md`, untouched).
  Also: the Feint lane renders the same template and now passes the two new inputs with the baseline off; `task test-scripts` runs the three 0.2.0 ops harnesses (netcheck, exposure scan, RBAC review) that `task lint`'s reachability check found unwired.

- **Bastion identity: named operators, the SSH CA from the root, a plan-time hardware-key check, `SSH_USER`, and a host key that is kept and checked (ANSSI NT-SSH R6/R21/R30, NT-007 R6, PA-022 R21/R30, HYG-M8; audit ADM/F05, TLS-13, TLS-16, OSN/F10, NET/F16).**
  New `bastion_admins` (map of account name to `{ ssh_keys }`, default **{}**): each entry is one more unix account in `bastion-admins` (no sudo, no password) with its own `authorized_keys.d/<name>`; with a CA configured
  it also gets a principals file holding its own name, so a certificate cannot be used as another person. `ssh_keys = []` makes a certificate-only account. `bastion_ssh_keys` and the shared account are unchanged (automation, `auto_tunnels`,
  break-glass). `bastion_ssh_ca_public_key` and `bastion_ssh_ca_principals` are now variables of the cluster root (the modules always had them; the root never passed them), validated so a quote or a line break cannot reach the
  YAML. `bastion_require_hardware_key` (default false) refuses at plan any key in `bastion_admins` that is not `sk-ssh-ed25519@openssh.com` / `sk-ecdsa-sha2-nistp256@openssh.com`; it does **not** cover `bastion_ssh_keys` and
  cannot see what a CA signs. `talos-tunnels.sh` reads `SSH_USER` (the state's `bastion_user` stays the shared account; the single-apply tunnels keep it). New output `bastion_access_keys` and
  `scripts/ops/bastion-fingerprints.sh` (account, SHA256 fingerprint, type, comment; `--find`) to map the fingerprint in a login line to a person. With the baseline on, the bastion user also leaves the `sudo` group.
  Host key: new `scripts/lib/bastion-hostkey.sh`; with `OA_BASTION_PIN_HOSTKEY=1` the first key seen is accepted once (fingerprint printed, flagged unverified), kept in `.talos-bastion-known-hosts` after a successful login and
  required from then on; `=verify` refuses a first contact unless `OA_BASTION_HOSTKEY_FP=SHA256:...` matches; a different key on a pinned address is refused until `OA_BASTION_FORGET=1` with the new fingerprint.
  `bastion-harden-check.sh` no longer uses `StrictHostKeyChecking=no` (pinned file when it holds the bastion, else a private file, fingerprint printed, `OA_BASTION_HOSTKEY_FP` checked) and `bastion-logs-pull.sh` takes
  the pinned file when it holds the bastion. **Everything is off by default**: with the defaults the rendered cloud-init is byte for byte the previous one (hash in `test-cluster-checks.sh`, now also asserting the new inputs render nothing);
  the scripts behave as before without the variable. Setting `bastion_admins` or the CA changes `user_data` (replaces the bastion on OVH and Outscale; ignored by a running instance elsewhere): plan window, never during a bootstrap.
  Rung: **mocked and local Docker**. `tofu test` (25 cases: names, keys, hardware, CA, egress inputs), stub harnesses (`test-talos-tunnels.sh` pinning, first contact, changed key, forget, verify, `SSH_USER`, `open-direct`;
  `test-bastion-harden-check.sh`; `test-bastion-fingerprints.sh`) and the new `task bastion-identity-check` (`scripts/dev/bastion-identity-check.sh`, Ubuntu 22.04 and 24.04): a real sshd takes each person's key for that account only,
  names the person and key in the login line, accepts an 8 h certificate for the matching principal only, refuses an expired one, refuses a key in `RevokedKeys` (and, measured, every certificate for that key) while the others log in.
  **Not proven**: any cloud image, cloud-init ordering on a first boot, a FIDO token (no `sk` login, no `verify-required`), that each provider shows the host key in a console log, that a plan on a running cluster is empty.
  **Not done**: a host certificate signed by the CA (no first-contact step), injecting host keys (deliberately refused: they would live in the state), operating the CA (it stays offline or in OpenBao, outside this repository),
  an OIDC login, session recording, and moving `bastion_image_id` to Ubuntu 24.04 with the hybrid `sntrup761x25519` KEX (TLS-01/TLS-19: it replaces the bastion on a running cluster and OpenSSH 8.9 on 22.04 does not know that KEX).

- **Bastion Internet egress can be closed, opt-in `bastion_internet_egress` (ANSSI PA-022 R10/R19, HYG-M27, NT-006 R2; audit ADM/F06, OSN/F14, SCC/F18, NET/F04).**
  `mode = "closed"` (default `"legacy"`: nothing changes) removes 80/443 to any address from the bastion's nftables and from the security group on Scaleway, OVH and Outscale; replaces the Scaleway "ANY to 172.16.0.0/12" and
  the OVH "every protocol to 10.0.0.0/24" rules by TCP 6443 and 50000 to the subnet the network really has (Scaleway: `scw_subnet_in_use`, which follows an adopted network; OVH: the subnet resource's CIDR; Outscale: the Net);
  limits outbound ICMP to that subnet; drops 8200 from the firewall and from `PermitOpen` (grep: no script or document in this repository or in OpenAether-apps forwards 8200 through the bastion); keeps the metadata
  addresses reachable on port 80 (a security group applies to them on OpenStack); and installs neither `curl`, `netcat`, `tcpdump` nor `unattended-upgrades` and switches the apt timers off, since no mirror is reachable: **a closed
  bastion is patched by replacing it** (`docs/admin-access.md` gives the `-replace` addresses). `dns_servers` / `ntp_servers` (addresses only) pin DNS and NTP in the VM's firewall (IPv4 and IPv6) and, IPv4, in the security group;
  empty keeps them open. The OVH and Outscale rule resources gain `count` / `for_each` with `moved` blocks, so a cluster that never sets the variable plans no change (tests pin the legacy rule lists, in order for Scaleway,
  where the provider compares a list). With the baseline on, the bastion user also leaves the `sudo` group. `bastion-harden-check.sh` no longer expects port 80 blocked (the shipped rules never did): it checks an arbitrary port in
  legacy, and with `BASTION_EGRESS=closed` 80, 443, another public address and 8200 refused, no tools, timers off. Rung: **mocked and local Docker**: `tofu test` on the security-group rules of the three providers (legacy and
  closed, pinned servers), a render test of the template, and `task bastion-identity-check`, which loads the closed and the legacy ruleset in a container's network namespace and shows 80, 443 and 8200 dropped and 6443 and
  50000 kept only when closed. **Not proven**: a closed bastion on a real cloud (first boot, the Scaleway private-NIC route fix, DHCP renewals and the metadata address under the new rules, the Scaleway metadata address
  `169.254.42.42` is from memory), tunnels to control planes, workers and the VIP, a plan on a running cluster. **Not done**: an ephemeral jump host or a baked-image replacement schedule (S13.6), disk encryption of the
  bastion (it holds no secret at rest; the exception is not argued in a separate document), a provider mirror allowlist (not possible by name in nftables), and a changed default.

- **Bastion logs off the VM: upload with a watermark, a fingerprint-to-person table (ANSSI PA-012 R2/R9/R14, HYG-42 M8; audit LOG-08).**
  `bastion-logs-pull.sh` with `OA_LOGS_UPLOAD=1` stores the encrypted journal and audit archives in the artifacts bucket of both object stores under `backups/bastion-logs/` (SSE on top, the credentials of
  `etcd-snapshot.sh`), refuses to upload anything in clear, keeps a per-store marker so a failed store is retried and nothing is re-sent, and keeps the journal cursor in the bucket too (moved only when both stores hold
  everything), so a pull from another machine resumes. `docs/admin-access.md` documents reading a file back, the fingerprint table, and the cloud audit trails (Scaleway Audit Trail, OVH Activity logs, Outscale API logs,
  Proxmox syslog) as a **manual** export. Rung: **mocked** (stub `ssh` and `aws`: both stores, per-store credentials, a store down then retried, a fresh directory resuming from the bucket cursor, the clear-text refusal);
  restoring and reading goes through `systemd-journal-remote`, shown on a hand-built export in a container, not on a real `journalctl -o export`. **Not run against a real bucket.** The logs on the VM are still not
  tamper-proof between two pulls, and nothing schedules the pull.

- **Ops verification tooling: encryption at rest read back, an exposure scan, a behavioural network check, an RBAC review (ANSSI HYG M37/M38 evidence, NT-006 R14; NSA/CISA AUTH-03 and the Cilium encryption control).**
  `infra-verify.sh` now reads `STATE` and `EPHEMERAL` back from each node's Talos API and fails unless they are `ready` and `luks2`, and
  fails when the kube-apiserver has no `--encryption-provider-config` (the volume id is taken from Talos' source and has never been read on a
  node: a node that does not know it is reported as unchecked, not as red). `cluster-security-tests.sh` gains 1.8 (Cilium WireGuard enabled in
  `cilium-config` and reported by the agent), 4.6 (`openbao-recovery-dev` fails with `OA_ENVIRONMENT=prod`, is only reported otherwise) and
  4.7 (the seal-key `openaether.io/escrowed-at` annotation; **opt-in** with `OA_ESCROW_ANNOTATION_CHECK=1` until the apps escrow step that sets it
  exists, prod only). New: `task cluster-exposure` (`scripts/ops/exposure-scan.sh`: TCP probes of the bastion, API and app load balancers,
  `FROM=denied` from an address outside `admin_ip`), `task cluster-netcheck` (`cluster-netcheck.sh`: a throwaway non-root pod in a temporary
  namespace must be unable to reach a Service of each platform namespace, with an API-server reachability control; `CILIUM=1` adds
  `cilium connectivity test`, never run here), `task rbac-review` (`rbac-review.sh` + `rbac-review.jq`, a dated `.tsv` flagging named User/Group
  subjects, anonymous bindings and `cluster-admin` outside the allowlist) and a "review at staff change" paragraph in `docs/admin-access.md`.
  The regression workflow runs the exposure scan and the netcheck after `cluster-verify`. Everything is read-only except the netcheck's temporary
  namespace. Rung: mocked/static (stub `kubectl`/`talosctl`, loopback listener, failure and mutant cases; `shellcheck`), **not run on a cluster**.
  It does **not** prove that a real node answers the way the stubs do, that the netcheck image can be pulled under the cluster's policies,
  or that any of the new checks is green on a good cluster; it adds no OIDC and no named-human access (K8S/F13 steps 2-4 are not done), no etcd
  or barman restore test and no backup-policy document (DP-16's apps and policy part), and no UDP probing.

- **Supply chain: committed provider locks, a checksum lane for the Talos boot images, an SBOM, a protected environment for the cloud workflow, rulesets as code (ANSSI SSDLC CICD-AIP-01c/-03, PROV-REC03, CICD-IAM-03/-05, CIO-REC03, SCM-REC06/-07, SBOM25-1/-2/-3 in part).**
  `.terraform.lock.hcl` of `cluster/` and `talos-image/` is committed (linux and macOS, amd64 and arm64); both roots' `>=` provider
  constraints become `~>`; `task validate`/`test` and CI run `tofu init -lockfile=readonly` (shown to fail on a constraint bumped without
  a refresh); `task lock-providers` refreshes by hand and Renovate looks providers up on registry.opentofu.org. `talos-image/images.lock`
  records the sha256 of the Factory raw image per platform and arch for the pinned Talos version; `verify-image-checksum.sh` runs after
  the download in the Scaleway, OVH and Outscale modules, driven by `image_checksum_mode` (**`warn` by default**: today's behaviour plus a
  message; `enforce` stops the build; `off`), and Proxmox passes the provider's `checksum` under `enforce` only. `talos_tunnels` hands its
  values to `local-exec` as environment variables (a key path with a space or `$(...)` stays data; it stays off by default). `real-cloud-regression.yml`
  runs in an environment `sandbox`. `sbom.yml` (weekly and on release) attaches a CycloneDX 1.5 inventory (`gen-sbom.py`: tool pins, locked
  providers, bootstrap images with digests, Factory images with hashes) and Trivy-scans the bootstrap images; `.vex/` holds an empty OpenVEX file.
  `.github/rulesets/` holds the two rulesets as exported; `check-required-checks.sh` compares them with GitHub, requires a pull request,
  no force-push and no deletion on main, and **warns** (fails under `--strict-main`) on 0 approving reviews, no required signatures and the
  admin bypass on main; it also checks the `sandbox` environment. `docs/supply-chain.md` has the rotation table. Rung: mocked/static
  (`tofu test` on the image root and the Proxmox module, stub harnesses, 79 offline cases for the settings check); the settings check was
  also run once, read-only, against the live repository; the Factory was downloaded for real to write the lock. Nothing was run on a cloud or
  a Proxmox host, Trivy and the Renovate validator were not run, and the new workflow has not run. It does **not**
  prove the Factory serves stable bytes over months, that Proxmox's checksum covers the compressed file, that provider versions in the locks
  are the ones the clusters ran on, or that the `sandbox` environment exists with reviewers (create it, then move the secrets); it adds no OIDC,
  no bucket versioning, no image signature verification, and it covers none of what `OpenAether-apps` deploys.

- **Patch policy and the signals behind it (ANSSI hygiene measure 34, audit ids HYG-M34, SSDLC CICD-AIP-01a/-03, NT-35 R2 in part).**
  `docs/patching.md` states the rule (security fix merged or waived in writing within 30 days, 7 when exploited or internet-reachable)
  and what feeds it. `renovate.json5` gains `vulnerabilityAlerts` (label only: Renovate's default for that block already skips the
  schedule, the dashboard approval and `minimumReleaseAge`) and `osvVulnerabilityAlerts`. Cléa gets an optional
  `[policy] max_minors_behind` (set to 2 in `clea.toml`): its report lists every pin more than that many minor releases, or a major,
  behind upstream, held back or not; report only, 15 new assertions in `test-clea.sh`. `scripts/dev/check-image-pins.sh --enforce` runs in
  `task lint` and fails on an `image:` pinned by tag with neither `@sha256` nor an entry in `flux-image-digests.lock` (none today);
  `.github/workflows/image-digests.yml` runs `check-flux-image-digests.sh` weekly (anonymous ghcr.io, no credential, never on a PR).
  Rung: mocked/static; the digest check was also run once against ghcr.io. Renovate's validator was not run (no Node here), and
  the new Renovate keys are checked only against its published JSON schema. It does **not** upgrade Istio, cert-manager, Kyverno or
  CNPG (those pins live in `OpenAether-apps`), does not move the bastion image off Ubuntu 22.04 (a replacement of a deployed
  bastion, left to its own change), does not enable Renovate `pinDigests` (this repository has no manifest a Renovate manager would
  rewrite: the Flux and Cilium manifests are generated), and the 30 days are a commitment of one maintainer, not a control.

- **Passphrase hygiene for the state, the access artifacts and the etcd snapshots (ANSSI PG-083 weak-entropy rule, B2 one key / one use, PA-079 R4 and R14 in part).**
  `scripts/ops/gen-passphrase.sh` prints `openssl rand -base64 48`. `task cluster-up` runs an entropy heuristic on the
  passphrase after the existing placeholder check (distinct characters, repeated block, runs, common words; random base64 and hex
  pass): **warn by default**, `OA_PASSPHRASE_CHECK=enforce` refuses, `=off` silences. New optional `artifact_passphrase`
  (`TF_VAR_artifact_passphrase`, default null = unchanged behaviour and no plan diff) encrypts the gpg talosconfig/kubeconfig
  backups and the etcd snapshots; `restore-artifacts.sh` tries it first and falls back to the state passphrase, so older objects
  open. The pbkdf2 parameters of the state encryption are pinned to OpenTofu 1.12's defaults (600000 / sha512 / 32, read back
  from a state's own metadata: existing states decrypt unchanged). `task kubeconfig` writes both files 0600, the snapshot cron
  warns on a `.env.sh` readable by others, and the false "SSE-C" and "authenticated/OCB" wording is gone. Rung: mocked (`tofu
  test`, the stub harnesses with real gpg, a real go-task), plus a local-backend decrypt check of the pbkdf2 defaults; nothing
  run on a cluster or against a real store. It does **not** make gpg an AEAD (still CFB + SHA-1 MDC), does not add `enforced = true`
  (an unencrypted state would stop planning), does not move artifacts to PGP public keys, and splitting the secrets is only as
  good as the places they are kept.
- **Secrets-at-rest cipher said as it is (ANSSI PA-079 R12).** The comments in `modules/talos/main.tf` called the etcd
  encryption `AES-256-GCM`; Talos' `secretbox` is XSalsa20-Poly1305. `docs/upgrade.md` now records the deviation (not a
  listed AEAD; Talos offers no AEAD alternative) and that the key has no verified in-place rotation. Docs and comments
  only, nothing run; it does not add a rotation procedure, a KMS provider or a new cipher.
- **Review fixes for the passphrase, supply-chain and ops-check changes above (ANSSI PG-083, SSDLC CICD-AIP-03, CICD-IAM-03; found by an independent review).**
  `test-passphrase.sh` now greps that `backup.tf` hands the backup script `local.artifact_passphrase` (reverting it to the state
  passphrase left every test green before; the line was changed and the new check went red). `artifact_passphrase_set` is
  `nonsensitive()`: it derived from a sensitive variable and so hid the whole `triggers_replace` map in every plan, set or not (a
  test asserts it is readable; no value changes, so no plan diff is expected, **not run against a real state**). `etcd-snapshot.sh` warns
  when `artifact_passphrase` is in a tfvars file but not in `TF_VAR_artifact_passphrase`, the case where artifacts and snapshots would
  silently end up under different passphrases (the variable's description now says environment only). The sandbox-environment
  check fetches the deployment-branch patterns and fails on anything but `main` (a `*` policy passed before) and warns on
  "protected branches" only (82 self-test cases, 3 new). `task kubeconfig` creates its two files with `touch` and `chmod 0600`
  (BSD `install` on macOS may refuse `/dev/null`; **not run on macOS**). `test-talos-tunnels.sh` checks that `OA_TUNNEL_KEY` is
  still `pathexpand()`ed. `test-passphrase.sh` checks a fixed hex value instead of a random one (a random 32-character hex string
  has fewer than 10 distinct characters about once in 10^4 draws and was flagged, so the line flaked). Docs and variable text now say that `checksum_mode = enforce` on a Proxmox root that already holds
  the image plans its re-download (bpg 0.116 `checksum` forces replacement; the resource is deprecated there), that a Talos bump
  needs `talos-image-lock.sh` run by hand (the Renovate PR body says so), and what `osvVulnerabilityAlerts` actually reaches.
  Rung: mocked/static, nothing run on a cluster or a Proxmox host. It does **not** automate the lock update, and
  does not replace the deprecated Proxmox resource.

- **The security documentation set, each page with a French twin (ANSSI rules on key impact, crypto-period and erasure; incident handling and PG-078 R26; backup policy, restore tests and destruction; a documented recovery plan; a documented architecture, flow matrix and trust zones; a documented administration system and privileged accounts; patching, vulnerability watch and written deviations; audit ids DP-06, DP-07, DP-17, TLS-12, TLS-19, TLS-20, F-BKP-07, F-BKP-10, F-BKP-16, LOG-17, ADM/F11, ADM/F13, NET/F07, NET/F09, OSN/F13 stage 0, OSN/F18, SCC/F11).**
  New in `docs/`: `key-management` (every key K1 to K13 with purpose, algorithm, crypto-period, impact if lost and if leaked, replacement, revocation, erasure and archive; the Talos PKI, state-passphrase and etcd-key replacement procedures; the recorded deviations for
  the software seal key, the AES-GCM wrap, the three CAs and the absent post-quantum hybrid), `incident-response` (detection sources, severity, contact placeholders, evidence capture with `talosctl` before a node is replaced, backups protected first, containment, a rotation table per secret, restore-point choice,
  degraded access when Zitadel or the bastion is down, a register template), `backup-policy`, `disaster-recovery` (one ordered chain, OpenBao's snapshot before Zitadel's database because the masterkey lives in OpenBao, prerequisites, time targets, a yearly drill with a result table), `security-architecture`, `network`,
  `hardening`, `threat-model`, `component-selection` (with the VEX register) and `audit-register`; linked from `SECURITY.md` and both READMEs; "Quarterly security review" added to `release-checklist.md`.
  **Two statements the code contradicts are corrected** in `admin-access` (EN and FR): section 6 said the gateway was "nothing public" (with `deploy_app_lb` the application load balancer forwards public 80/443 to it, with no source filter) and showed bare `bao token create`
  commands that need a token this platform does not hand out (`openaether-admin` explicitly cannot mint one); the maintenance-mode apply is written up as a residual risk in `first-cluster` and in the `modules/talos` header (DP-17).
  New checks: `scripts/dev/check-doc-twins.sh` (in `task lint`: each pair opens with a link to the other, the security pairs have the same sections and code blocks on both sides, relative links resolve; its own test `test-check-doc-twins.sh`), and `scripts/dev/gen-flow-matrix.sh` with `test-flow-matrix.sh`
  (in `task test-scripts`): the node-inbound tables of `network.md` and `network.fr.md` are generated from `scw/security.tf` (the `node_inbound_ports` map), `ovh/security.tf` and `outscale/security.tf` and compared with the code, and every rule must have a justification row.
  Rung: **documents, read against the code, plus mocked tests of the two checks; nothing was run on a cluster, and no procedure in these pages was drilled.** RPO and RTO figures are proposed targets, the periods marked "proposed" are the maintainer's to confirm, and two joins of the recovery chain are named as unsettled (how the seal-key Secret is placed before OpenBao starts on a cluster built with Flux; the restic repository prefix of a rebuilt cluster).
  It does **not** add a mechanism, an object lock or versioning on the buckets (recorded as a gap), a rotate-secret task, a host firewall (stage 0 of OSN/F13 is the page), named Kubernetes identities, the Talos node baseline (sysctls, kernel arguments, Secure Boot: rows left open in `hardening`), or end-of-support dates for the infrastructure pins; the application-side inventory it points to (`OpenAether-apps/docs/key-inventory.md`) ships with the apps half of the same work.

- **Optional source filter on the application load balancer, `app_lb_allowed_cidrs` (ANSSI PA-022 R15/R16, HYG-M28, BP-028 R79; the infra half of the audit's OSN/F15 and ADM/F03).**
  New variable (list of IPv4 CIDRs, default **empty = no filter = exactly the previous behaviour**, so no deployed cluster changes). With `deploy_app_lb` and a non-empty list: Scaleway gets inline allow-then-deny ACLs
  on the `http` and `https` frontends (the pattern of the Kubernetes API frontend, an in-place update), OVH `allowed_cidrs` (sorted) on the two Octavia listeners, Outscale inbound 80/443 rules from the list in the
  cluster security group, which is the load balancer's group. Each module also admits the cluster's own egress address (Scaleway NAT gateway, OVH router address, Outscale NAT service: pods reach
  `https://zitadel.openaether.local` through the load balancer) and, on Scaleway and OVH, the private range; Proxmox and local are left out (no cloud load balancer). `["0.0.0.0/0"]` is accepted to turn the machinery on while
  staying open. A `check` warns when the list is set but nothing can apply it. `network.md`/`.fr.md` (generated flow tables, section 6 gap 5) and `admin-access.md`/`.fr.md` section 6 describe it and the staged roll-out.
  Rung: **mocked/static, not run on a cloud**: `tests/app-lb-source-filter.tftest.hcl` (ten cases: no ACL by default, allow before deny on both frontends, listener lists sorted, Outscale rule sources, input refused for a bare
  address and for IPv6, the warning), the flow-matrix generator and its test. **Not proven**: that any of the three clouds enforces it, that the update is in place (no LB replacement, hence the same public IP), that pods still
  reach Zitadel, that health checks and the client source address survive the NodePort path, and, on Outscale, whether the load balancer is filtered by its group at all (the group has had no 80/443 rule until now). It does
  **not** authenticate anyone (a listed address still reaches every route's own login), does not remove any route (the apps half is another change), does not change the default to `admin_ip`, and does not cover Proxmox.

- **Opt-in versioning, expiry and object lock on the buckets that hold copies and logs, `backup_immutability` (ANSSI RW-SAUV-2/-3, GH-BKP-1, HYG-M37; the infra half of the audit's F-BKP-01, LOG-07 and DP-05).**
  New variables `backup_immutability` (`off` default | `versioned` | `governance` | `compliance`) and `backup_retention_days` (default 60), read from the tfvars by `scripts/internal/ensure-buckets.sh`
  (no resource reads them: the buckets exist before OpenTofu runs). **`off` changes nothing**: no call is made, no bucket is created. Otherwise the script creates the application-backups bucket and its `-backup`
  twin (until now the operator's to create by hand; the seed and the apps need them) and, on all seven buckets, turns on versioning and a lifecycle rule `oa-noncurrent-expiry` (non-current versions expire after
  `backup_retention_days`); with `governance`/`compliance` the five buckets that hold copies or logs (application backups and their replica, the state and artifact replicas, Loki's logs) are CREATED with object lock
  and get a default retention of the same length (the primary state and artifact buckets are versioned, never locked: tofu writes them). Everything is read back from the store and a refusal is a loud warning naming the
  bucket and the provider's words, never a silent pass (`OA_BUCKET_PROTECTION_STRICT=1` makes it exit 1). Lifecycle rules someone else set are merged, not replaced, and nothing is written when they cannot be read.
  A check warns for `compliance` on a dev cluster with more than 7 days: such a bucket cannot be emptied or deleted before the retention ends. Rung: **mocked/static, not run on a cluster**: a fake store
  (`testdata/fake-aws-s3.sh`) that refuses object lock on a bucket not created with it, 56 assertions in `test-bucket-protection.sh`, seven `tofu test` cases. **Not proven**: that Scaleway, OVH or Outscale accept any of
  these calls (versioning, a lifecycle on non-current versions, create-with-lock, a default retention), that restic, Barman, Longhorn and Loki keep working against a versioned or locked bucket, or that the expiry fires.
  It does **not** stop a key that may call `DeleteObjectVersion` from removing an unlocked version (that is the key policy, below), does not touch an existing cluster unless its tfvars ask, and does not enable
  object lock on a bucket that already exists without it on providers that refuse it (reported, not forced).

- **Key pairs of their own for the backup stores, and a check of who can open what (ANSSI RW-SAUV-2, GH-BKP-1, PA-012 R26/R26+, HYG-M37; the infra half of the audit's F-BKP-01, F-BKP-04, LOG-07, F05 and DP-05).**
  Extends 0.2.1's Loki bucket and `OA_LOKI_S3_*`. `seed-openbao.sh` takes the same optional, both-or-neither pairs for the two backup stores: `OA_BACKUP_S3_ACCESS_KEY_ID` / `OA_BACKUP_S3_SECRET_ACCESS_KEY` for
  `backup/s3-primary` and `OA_BACKUP_REPLICA_S3_*` for `backup/s3-replica`, each meant to be limited by the operator to its bucket. **Without them nothing changes** (the cluster still gets the operator's keys, which also open the
  state, artifact and logs buckets and may delete in them) **and the script now says so, from OpenBao's answers**, for the backups as it already did for Loki; a pair set against an entry that exists is reported as not applied (the
  seed is create-only). New `scripts/ops/s3-isolation-check.sh <tfvars>` reads, with the pairs in the environment, which identity lists which bucket and whether a dedicated pair may call DeleteObjectVersion (a version that does not
  exist is named: nothing is deleted), and compares the buckets with `backup_immutability`; exit 0 held, 1 not, 2 nothing dedicated in scope. Rung: **mocked/static, not run on a cluster**: `test-seed-openbao.sh` (96 assertions) and
  `test-s3-isolation.sh` (23, on the fake store). **Not proven**: that any provider lets a key be limited to one bucket, or to everything but DeleteObjectVersion (the policy is the operator's to write and is not shipped:
  `docs/backup-policy.md` lists the actions each identity needs), or that restic prune, Barman, Longhorn and Loki run with such a key. It does **not** move `forget --prune` out of the cluster (that is apps and needs restic locking
  checked against a reduced key), does not rotate a seeded key (create-only: `bao_admin kv put`, documented), and does not touch an existing cluster's entries.
  Documented in `backup-policy.md`/`.fr.md` (section 3 the modes and their limits, new section 4 the identity-to-bucket table and the rotation order), `admin-access`, `incident-response` (step 5 no longer says "no object lock is configured" without the opt-in), `key-management`, `security-architecture`, `audit-register`, `.env.example` and the teardown message of `fleet-down.sh` (a locked bucket cannot be emptied).

- **`task cluster-security` checks that Loki writes to a bucket of its own and does not hold the backups' keys (4.8, 4.9; ANSSI PA-012 R26, RW-SAUV-3; the live-cluster half of the audit's F-BKP-04 and F05).**
  Reads `loki-s3-credentials` and `backup-restic-env`, compares the encoded values and prints none. 4.8 **fails** when Loki's bucket is the backups bucket (what a cluster seeded before 0.2.1 still has, create-only);
  4.9 is a **skip**, not a failure, when the key pair is the same (the seed's default without `OA_LOKI_S3_*`), and says what that leaves open. A cluster that lacked a dedicated pair keeps its 0.2.1 count
  of passes, with one more skip and one more pass. Rung: **mocked/static**, six cases in `test-security-tests-checks.sh` (21 in all); not run on a cluster. Already there and not repeated: the Cilium WireGuard
  check (1.8) and `check-cilium-effective-config.py`, which answer the audit's cleartext Alloy-to-Loki hop (WireGuard, no application-layer TLS); the `insecure: true` of `loki.yaml` is the apps repository's.

- **`task escrow`: the OpenBao seal key, recovery shares and restic password escrowed to at least two custodians, proved against the live key, then attested (ANSSI GH-M37-5, RW-PRA-1, B2 recovery rule, PA-022 R45 in part; the infra half of the audit's F-BKP-05, DP-02 and F15).**
  New `scripts/ops/escrow-openbao.sh` (`task escrow -- export|verify|attest`). `export` reads the three items from the cluster (the restic password through the `openaether-admin` path, the token on stdin), encrypts the seal key and the
  password to every custodian (`-r KEYID` twice or more, or `--recipients-from-tfvars`), copies the already PGP-encrypted shares and writes a receipt of hashes (no secret); it refuses fewer than two **distinct** keys (two names for one key
  count once), a directory inside a git work tree, a non-empty directory and a development bootstrap, and never puts a value on a command line or in a file unencrypted. `verify` reconstructs the key from the escrow alone (or from `--key-file`
  for a hand-made k-of-n split) and compares its sha256 with the receipt and with the live Secret, and does the same for the restic password and the share copies; `attest` runs `verify` and only then writes the ConfigMap
  `openbao-escrow-ack` and the annotation `openaether.io/escrowed-at`, exactly as the apps Day 0 step 5 does. **`cluster-security` check 4.7 now compares the attested hash with the live key**, and also fails on one holder, an attestation
  older than 400 days or undated, and an annotation without the ConfigMap: the case the apps CronJob cannot see (it never reads the key) is an escrow of a key that was rotated since. 4.7 stays opt-in (`OA_ESCROW_ANNOTATION_CHECK=1`, prod only).
  Rung: **mocked/static with real crypto**: `test-escrow-openbao.sh` (37 assertions, real gpg keys, a stub cluster, mutants run) and 29 in `test-security-tests-checks.sh`. **Not run on a cluster**: the pod exec, the apps CronJob
  accepting the ConfigMap this writes, the `ssss`/`gfsplit` split (not tried), a restore from the escrow. It does **not** split the key (several recipients means any one opens it: it survives losing a person, not one leak), prove that each custodian
  can open their copy (each runs `verify`), move the key out of the cluster, or run the disaster-recovery drill. Docs: `admin-access`, `key-management`, `disaster-recovery`, `release-checklist`, `audit-register` (EN and FR).

- **`task rotate-secret`: the replace path that `seed-openbao.sh` (create-only) does not have (ANSSI B2 renewal rule, PG-078 R7/R26; the infra half of the audit's F-BKP-10, ADM/F11 and DP-07).**
  New `scripts/ops/rotate-secret.sh <path> [--apply] [--restart ns/kind/name]`. As `openaether-admin` (token exchanged inside the pod, on stdin) it reads the entry, replaces only the fields it is given from `OA_ROTATE_*` in the environment
  (the S3 pairs of `backup/s3-primary`, `backup/s3-replica` and `observability/loki-s3` with an optional bucket or endpoint; `OA_ROTATE_VALUE` for the two Alertmanager URLs and `grafana/oidc`), writes a new version with a check-and-set on the version it read,
  nudges every ExternalSecret and, for `--restart`, waits until they have refreshed before restarting the named consumer (and restarts nothing if they did not). A dry run is the default. It **refuses, with the reason**, `backup/restic`, `zitadel/masterkey`,
  `longhorn/encryption`, `zitadel/db`, `grafana/db`, `zitadel/admin`, `grafana/admin` and `minio/root`: each has a step outside OpenBao (a repository key, a database role, an encrypted volume) that this tool cannot do. Implemented as its own script rather than a mode of
  `seed-openbao.sh`: the seed's identity may only create, and a replace mode would have widened it. Rung: **mocked/static**, `test-rotate-secret.sh` (39 assertions, stub kubectl, mutants run); not run against an OpenBao or a cluster. It does **not** rotate
  the Talos PKI, the state passphrase or the etcd and disk keys (written procedures only, `key-management.md` section 3), does not create the new key at the provider, and does not revoke the old one. `incident-response.md` section 7 and `backup-policy.md` section 4 point to it (EN and FR).

## [0.2.1] — 2026-10-15

**The infra half of the pair with OpenAether-apps 0.2.0: Day-1 seeding without a root token, a bucket of its own for Loki, a language check shared with the apps, and the Day-1 documentation corrected. A patch: no new scope.** It pins apps `refs/tags/0.2.0`. Read the entries below with their rung: real cloud means once, by hand, on the clouds named; nothing is repeated or unattended, and `cluster-up` with `deploy_flux = true` still ends 201 until the Day-1 seeding has run.

**Not fixed, and not observed:** the dedicated Loki key pair was never run on a cloud; infra #302 stays open for it. `task cluster-upgrade`'s pre-upgrade safeguards (#270) have never run on a cloud. Outscale ran the reduced apps profile only. An OVH worker can stay `ACTIVE` while dead (#49): it happened once and was hard-rebooted. No disaster-recovery restore, no rolling upgrade with Flux, no Proxmox hardware.

### Security

- **Loki writes to a bucket of its own (#302).** `seed-openbao.sh` seeded `observability/loki-s3` with the backups bucket and the
  backup keys, so a compromised Loki could erase the backups, against what the docs and the ExternalSecret said. It now seeds
  `s3-<project>-<provider>-logs-<env>` (`oa_logs_bucket`, created by `ensure-buckets.sh` beside the artifacts bucket) and, when
  `OA_LOKI_S3_ACCESS_KEY_ID` and `OA_LOKI_S3_SECRET_ACCESS_KEY` are both set, that pair (half a pair is refused before any write).
  **Without them Loki still gets the primary's keys, which are account-wide on the providers, and the script says that the
  separate bucket then protects against a mistake and not against a compromise.** Scoped keys are the operator's to create; this
  repository does not create them. A cluster seeded earlier keeps its entry (create-only). Rung: mocked (seed and name tests), and real
  cloud once by hand on Scaleway and OVH with the shared keys (Validated); the dedicated pair was never run on a cloud.
- **Day-1 seeding without a root token (#296, #297).** `scripts/ops/seed-openbao.sh` read the root token from the Secret
  `openbao-recovery` and passed it, with every value, on the `kubectl exec` command line. With OpenAether-apps 0.1.1 there is
  no such Secret (the bootstrap revokes the root token), and the script now uses the ServiceAccount `openbao-seeder`:
  Kubernetes issues a 10-minute token, OpenBao exchanges it inside the pod for a token whose policy `secret-seeder` can
  **create** five paths and read their metadata. The token and the documents travel on stdin, never on a command line; every
  secret is written with `cas=0`, so a re-run cannot overwrite one. The script no longer seeds `backup/restic`,
  `grafana/db`, `zitadel/db` or `longhorn/encryption`: `openbao-vault-bootstrap` generates them inside OpenBao, create-only,
  and prints none, which removes the race of #297 (the script could win it and the escrow print was lost). **Needs apps 0.1.1:**
  on a cluster still bootstrapped by apps 0.1.0 the script fails and says to use the infra 0.2.0 tag's script. Rung: mocked (a stub
  `kubectl`, 66 checks); the remote loop was run once against a real OpenBao 2.7.1 with the real policy (create, left alone,
  refused). The Kubernetes-auth login was exercised on real clusters running apps 0.1.1 and later (Scaleway and OVH full, Outscale reduced profile: see Validated).
- **`openbao_recovery_pgp_keys` / `openbao_recovery_threshold`: who holds the OpenBao recovery shares.** OpenBao unseals itself
  with a static key, so no human holds an unseal share; what operators hold are recovery shares, used only to generate a root
  token. Given at least three PGP public keys, the Flux bootstrap manifest also publishes the ConfigMap
  `openbao-operator-keys`, which switches the apps bootstrap to production mode: one share per key, encrypted to it. Without
  keys the bootstrap is a development one (a single plaintext share in a labelled Secret). `environment = "prod"` with
  `deploy_flux = true` refuses to plan without three keys, and a threshold above the number of keys, below 2, a duplicate key
  or a private key pasted by mistake are refused. Rung: mocked (`tofu test`, 9 runs; the template rendered by OpenTofu
  in both shapes and validated by `check-flux-schema.sh`).
- **`task cluster-up` checks the OpenBao recovery-share keys before it bills** (`scripts/internal/check-openbao-keys.sh`, tested against real
  gpg keys): `sys/init` commits the cluster before it encrypts the shares, so a key with no usable encryption subkey (a signing-only or
  expired key) ends the first run in a re-init. Each key's fingerprint is printed. Found by an independent review of the redesign.
- `cluster-security-tests.sh` 4.5 now asserts that no Shamir-share or root-token Secret exists in `foundation-vault` (it asserted
  that an unsealer was running).

### Changed

- **The `git_ref` default and the twelve `envs/*.tfvars.example` pin OpenAether-apps `refs/tags/0.2.0`** (they pinned 0.1.0). The pair
  is infra 0.2.1 with apps 0.2.0, validated end to end with the pins as shipped (see Validated). Infra 0.2.1 with apps 0.1.1 was **not run**
  (the only validated 0.1.1 pair is an infra commit on main, `f127a26`); infra 0.2.0 stays on apps 0.1.0 and cannot move. apps 0.1.1 and 0.2.0
  initialise OpenBao with a static seal: **a cluster built from infra 0.2.0 and apps 0.1.0 cannot be moved to this pair in place; build a
  new cluster, on new buckets** (a rebuild on the old backup bucket meets the old WAL archive and CloudNativePG refuses to archive into it,
  `OpenAether-apps/docs/traps.md`). A cluster on apps 0.1.1 moving to 0.2.0 must recreate its VictoriaMetrics volumes and loses their metric
  history (apps CHANGELOG, Upgrade notes). Nothing here ran an upgrade.
- **`scripts/dev/check-language.sh` is the OpenAether-apps copy again** (`check-skill-parity.sh` compares them byte for byte and
  `task apps-validate` against the apps tag was red on it). It now reads inline comments, Python strings and accents, so it
  found eight genuinely French lines here, now English: the Cilium parity message, two preflight messages, the Flux bootstrap
  template header and the Proxmox VIP comments. Its own cases come with it (`test-check-language.sh`, wired into `test-scripts`).
  The name of the dependency watcher, Cléa, is no longer read as French (taught in both repositories at once).
### Added

- **The environment-data rules of `.gitleaks-envdata.toml` judge the token, not the line, and know more names.** An independent review of the
  copy added to OpenAether-apps showed that one private range or one word like `shared` on a line excused a real address next to it, that
  `outscale_account_id` and `OSC_ACCOUNT_ID` (prefixed names) were not matched, and that the logs and artifact buckets were not covered. The same
  file is fixed here; the probe now holds 16 values it must catch and 13 it must leave alone. Known limit: a line carrying a version word is
  excused whole. Rung: the probe, run before the scan in CI.

- **`explain-failure.sh` points at the OVH router's SNAT port** when a run says `time is not in sync` and touched `module.ovh`.
  Seen once on a real account: a router whose `network:router_centralized_snat` port stayed DOWN left every node without DNS or
  NTP, and a fresh router of the same code was ACTIVE. The message gives the read-only command and says a bad router does not
  recover (tear down and run `cluster-up` again). It is a hint on the transcript, not a guard: a guard that fails a healthy
  apply on a transient DOWN has not been measured. Rung: mocked (three cases in `test-explain-failure.sh`).
- **`task cluster-upgrade` secures the way back before it moves anything (#270).** An encrypted etcd snapshot
  (`backups/etcd/pre-upgrade-etcd-<timestamp>.snap.gpg`, both artifact buckets) and a labelled copy of the state
  (`<state key>.pre-upgrade.<timestamp>` in the replica) are written first, under names no retention removes, and the run
  does not start when it cannot take them (`UPGRADE_SKIP_SNAPSHOT=1` starts without, and prints what that costs). The
  drill of #270 measured that the way back for the control planes across a minor is a restore of exactly these two;
  nothing took them. `SNAPSHOT_LABEL` (etcd-snapshot.sh) and `STATE_LABEL` (backup-state.sh, `--list` shows them) are the
  mechanism. Rung: mocked (new checks in test-state-backups.sh and test-cluster-checks.sh); not run on a cloud, and the state copy back is still the
  unmeasured part named in docs/upgrade.md. The route decisions of #270 (a supported flag to lower a pin, the Kubernetes
  rule) stay open.

### Fixed

- **`ensure-buckets.sh` refused a deploy over a bucket it had itself created.** On a real OVH run with the replica on Scaleway, the
  AWS CLI retried a create whose answer was lost, and the retry was told `BucketAlreadyOwnedByYou`; the script counted that as a
  failure of the replica store and stopped `cluster-up` before anything billed. That answer now counts as the bucket existing; any
  other refusal still stops it and is printed. Rung: mocked (two cases in `test-backup-creds.sh`); the defect was seen once, on a real cloud.

- `docs/admin-access.md` (and its French twin) read the PKI CSR from KV (`bao_admin kv get -field=csr secret/pki/intermediate-csr`),
  not from the bootstrap Job's log, which is removed an hour after the Job ends; the page and the seed script say apps 0.1.1,
  not 0.2.0, and tell a 0.1.0 cluster to be rebuilt.

- **`seed-openbao.sh` seeded the replica store with the primary provider's S3 keys (#296).** The replica's pair is now asked
  for with its own endpoint (`resolve-s3-cred.sh <provider> ak|sk backup <replica endpoint>`), as every other replica
  consumer does, and the run fails before any write when that pair is empty. A cluster seeded earlier keeps what it has
  (create-only): correct `backup/s3-replica` by hand (docs/admin-access.md, section 3). Rung: mocked (a cross-provider tfvars).
- **The red of a `deploy_flux = true` cluster pointed nowhere (#298, #300).** The `flux-system exists` line now names
  `seed-openbao.sh` and `admin-access.md` § 3, the app-load-balancer line states that its "nothing serves" holds for an
  infra-only cluster, and `README.md` / `admin-access.md` no longer say that Day-1 belongs to a later release: it applies to
  any cluster built with `deploy_flux = true`. The assertion that Flux is absent is unchanged.
- **Day-1 inputs written nowhere (#299, documented part).** `docs/admin-access.md` § 3 now names `source .env.sh`, the two
  alerting variables, the replica cloud's `<CLOUD>_BACKUP_AWS_*` keys and the two bucket names (`ensure-buckets.sh` creating
  them stays an open decision on #299).

### Validated

- **The pair as shipped, 2026-10-15 (infra `dcd1ace`, no `git_ref` in the tfvars so the default `refs/tags/0.2.0` applied; apps tag 0.2.0 at
  `22b00cc`).** Rung: real cloud, **once per cloud**, by hand. **Scaleway and OVH**, management role, 3 control planes + 2 workers,
  `deploy_flux = true`, three throwaway PGP recovery keys: Flux followed `refs/tags/0.2.0` at `22b00cc`; `cluster-up` ended 201 on
  `flux-system exists` only (13 passed, 1 failed); the seeding printed the shared-keys warning from OpenBao's answers; 35 of 35
  Kustomizations, every pod Running; the Kyverno report held 2 results (the Istio-generated proxies, apps #70); `grafana-db` and
  `zitadel-db` Ready with archiving True; Longhorn BackupTarget available; Loki's first objects in its own logs bucket after its 30-minute
  idle flush, the backups bucket holding only `cnpg/`; `cluster-security` 30 of 31; strict plan "No changes". `task apps-validate` is green
  against the tag. **Not run on the shipped pins:** Outscale (its quota only holds the reduced apps profile, which needs a branch, so the
  Outscale run below is with a branch), an upgrade, the dedicated Loki key pair, Proxmox. Both clusters torn down, `purge-orphans` and
  `verify-provider-clean` clean, lab buckets and images deleted.
- **The 0.2.1 candidate with the apps 0.2.0 candidate on three clouds, 2026-10-15** (the apps branches are not tags; see that repository's
  CHANGELOG for what ran inside). Rung: real cloud, **once per cloud**, by hand; `cluster-up` ended 201 on `flux-system exists` only
  (13 passed, 1 failed), as documented until the Day-1 seeding. **Scaleway** (infra `4ae2357`): `seed-openbao.sh` printed the shared-keys
  warning, wrote five paths; Loki wrote to the new `…-logs-<env>` bucket created by `ensure-buckets.sh` and nothing of Loki's reached the
  backups bucket; 35 of 35 Kustomizations; `cluster-security` 30 of 31; strict plan "No changes". **OVH** (infra `39df1b8`): same, and the
  run that exposed the `BucketAlreadyOwnedByYou` defect (Fixed above) first; one worker was dead after boot (issue #49), hard-rebooted and
  `up` re-run. **Outscale, reduced apps profile only** (infra `39df1b8`): up in 1020 s (13 passed, 1 failed: the same line), seeding and the OpenBao snapshot job fine; `cluster-security` 25 of 31, the four failures being the mesh checks (that profile has no Istio).
  **Changed after the last lab run (mocked only):** the seed script's closing message (now built from OpenBao's answers), the wording of
  the `ensure-buckets` retried-create message, the logs bucket in the teardown list and docs, the gitleaks rules, the release checklist and
  status text. **Not run:** the dedicated Loki key pair (the lab used the shared keys), `task cluster-upgrade` with the new safeguards, a second
  `cluster-up`, the OVH SNAT hint (its failure did not recur), Proxmox. All three labs torn down; `purge-orphans` clean on Scaleway and OVH, and on
  Outscale it lists only the standing OMI, kept on purpose (deleting it is the owner's call); lab buckets and images deleted by hand (Outscale's
  image-lane buckets kept: state of that OMI).

- **The Day-1 path of the OpenBao redesign, `deploy_flux = true`, Scaleway, 2026-10-13, on this branch (8d4a036 for the apply and the
  seeding; later commits touched the upgrade path and documentation only), with OpenAether-apps `claude/security-bootstrap`.**
  Management role, 3 control planes + 2 workers, replica store on OVH. `cluster-up` ended 201 after 570 s on
  the `flux-system exists` line (13 passed, 1 failed), which now names `seed-openbao.sh`. Three PGP public keys in `openbao_recovery_pgp_keys` produced the
  ConfigMap `openbao-operator-keys` in the Flux bootstrap manifest and OpenBao bootstrapped in production mode (three shares encrypted
  to the keys, threshold 2). `seed-openbao.sh` ran with a ServiceAccount token (no root token exists): five paths written in 2.6 s, all
  five left alone on the second run; `backup/s3-replica` carried the replica cloud's endpoint and keys, not the primary's (#296 observed
  on a real cross-provider setup). `task cluster-security` 30 of 31 passed (one skipped: no MinIO namespace), including the new 4.5. Torn
  down in the two commands (53 resources), `purge-orphans` and `verify-provider-clean` clean, the lab's seven buckets and its images
  deleted. **A second run on the hardened code (87daaf4, same day):** `task cluster-up` refused a signing-only key in
  `openbao_recovery_pgp_keys` in one second, before any resource was created, printing each key's fingerprint; with the key replaced it
  applied and bootstrapped unaided, the seeding wrote five paths, the hardened apps bootstrap passed (see that repository's CHANGELOG),
  35 of 35 Kustomizations were Ready 132 s after the seeding began, `cluster-security` 30 of 31. **Not run:** `cluster-upgrade` with its new
  pre-upgrade safeguards on a cloud, a second `cluster-up`, another cloud or role. What the runs found in OpenAether-apps is in that
  repository's CHANGELOG.

- **`deploy_flux = true`, Scaleway, 2026-10-12, on the 0.2.0 tag commit, once, stage by stage from a maintainer's lab
  script.** Management role, 3 control planes across three zones + 2 workers (`POP2-4C-16G`), `git_ref = refs/tags/0.1.0`
  (OpenAether-apps 0.1.0). `cluster-up` applied and ended 201 after 486 s on `cluster-verify`: 13 passed, 1 failed, 0
  could not be checked, the failure being `flux-system exists`. Flux followed the tag and reconciled the `management`
  profile. Counted from the first Flux object: 12 of 35 Kustomizations Ready at 2 minutes, 29 of 35 at 6.5 minutes, then
  the same six not Ready for about 17 minutes (`cnpg` waits on the ExternalSecret `cnpg-backup-s3`, which reads
  `backup/s3-primary`; its first 15-minute health check failed and it retried after 2 minutes). Counted from the start of
  `scripts/ops/seed-openbao.sh scaleway` (docs/admin-access.md, section 3; five paths written, four left alone): `cnpg`
  Ready after 11 s and the last of the six after 114 s (about 60 s of it the 1-minute retry of
  `observability-vm-customresources`, whose first dry-run found no VMAlert CRD), then every Kustomization Ready (61 of 62
  Flux objects; the 62nd is an OCI HelmRepository, which has no Ready condition) until the last sample 7.5 minutes later;
  15 HelmReleases InstallSucceeded, 127 pods Running and 6 Completed. The 17 minutes are the lab's order (seeding after
  the observation snapshots), not a product latency; the product facts are that it does not converge without the seeding
  and that it converged in 114 s with it. Figures come from the Kustomizations' lastTransitionTime and the controller
  logs. It corrects, for this lab and without moving the 0.2.0 text, the 0.2.0 statements that no cluster has followed the
  apps tag: only `refs/tags/0.1.0` was followed, `refs/heads/main` was not. Torn down in the two commands (52 resources,
  `purge-orphans` clean, `verify-provider-clean` rc 0). Not run: a second `cluster-up`, `cluster-idempotency`, an upgrade
  or a roll with Flux, the PKI signing, Grafana SSO, a backup or a restore, another cloud or role.

### Added

- **`docs/upgrade.md`, "Going back": what was measured of rolling an upgrade back (#270).** Real cloud, by hand, Scaleway,
  2026-10-12, the `0.1.0` and `0.2.0` tags (Talos 1.13.9 and Kubernetes 1.36.3 to 1.14.2 and 1.37.1, 3 control planes + 2
  workers). A worker comes back with `talosctl rollback` in 21 to 39 s, also with Kubernetes at 1.37.1. A control plane
  does not, across a minor that moves etcd's storage version: Talos 1.13.9's etcd refuses the data Talos 1.14.2's wrote
  (`version "3.7.0" is not supported`) and two rolled-back control planes cost the quorum for about 11 minutes. The way back
  for the control planes is a restore of an etcd snapshot taken before the upgrade: three members 52 s after the
  `bootstrap`, the API back 4.3 minutes after the first rollback, everything since the snapshot lost. Lowering the pins
  afterwards makes the plan replace the Talos secrets (the state has to go back too). Not measured: the state copy back,
  a restore after the Kubernetes bump, other clouds, a patch-level control plane rollback. `cluster-upgrade` still takes
  no snapshot and #270 stays open for the tooling and the decisions it lists.

### Fixed

- **`task local-up` refuses, in a second, a host whose kernel cannot build Talos 1.14's `/etc` overlay (#291).** Talos 1.14
  passes the overlay's layers as O_PATH file descriptors (`fsconfig` `FSCONFIG_SET_FD`, `lowerdir+`), which Linux accepts
  from 6.15 (6.13 added layers by descriptor, 6.15 the O_PATH ones). On 6.12.107 the call answers `EBADF`, every node died at
  boot and the bootstrap waited ten minutes. `scripts/dev/check-host-overlay-fd.sh` reads the Docker daemon's kernel; below
  6.15 and on this machine's own kernel it asks that kernel with the same call, in a user namespace, and refuses only on a
  refusal. A daemon it cannot ask (a Docker Desktop VM, a WSL2 kernel) gets a warning. Rung: mocked (a stubbed daemon, kernel
  and probe, every branch removed once to see its test go red); the real probe refused on the kernel 6.12.107 host that found
  the defect. The guard asks only for Talos 1.14 and later: Talos 1.13.9 / Kubernetes 1.36.3 booted on that host and
  `local-verify` passed (1 control plane + 1 worker, apart from the pin comparison; 3 + 3 ran the 3.8 GB host out of
  memory). Not run: the guard on a kernel 6.15 or newer, where it passes by version.

---

## [0.2.0] — 2026-10-12

**A Talos cluster that is upgraded to Talos 1.14 and Kubernetes 1.37, grown and shrunk while it runs, and rebuilt once on
a second cloud from its replica (OVH to Scaleway, one control plane and one worker), with Cilium still the only
platform above Talos.** The climb, node growth and node removal ran by hand on real accounts between 2026-10-02 and
2026-10-04, on Scaleway (two climbs), OVH and Outscale (one each); on 2026-10-05 the failover, the image lane, the
nodes' resolver and the Talos provider 0.12.0 pin ran at one control plane and one worker. The climbs of 2026-10-02 and
2026-10-03 ran under provider 0.11, which 0.2.0 no longer ships. The climbs from a 0.1.0 cluster (2026-10-06) and a
deploy from empty at the shipped pin (2026-10-10 and 2026-10-11) ran under 0.12.0 on all three clouds (Validated).
Nothing is unattended. A bullet's rung is its evidence: what does not say real cloud is mocked, emulated or local
Docker. Read Known limits and Upgrade notes before pulling this onto a cluster that matters.

### Added

- **`task teardown-all`: take a dev cluster down in one guarded command (#277).** It plans, asks the cluster's full id (or
  `CONFIRM=<id>`), destroys, then runs `purge-orphans` as a dry run and `verify-provider-clean`. It refuses anything that is
  not exactly `environment = "dev"` in the tfvars, with no flag to lift a refusal; `PROVIDER=all` guards every target before
  destroying any; `OA_NO_TEARDOWN_ALL` or a `.no-teardown-all` file locks it for a shell or a checkout. It never runs
  `purge-orphans --apply` and never deletes buckets, images or keypairs. The guard trusts the declared `environment`:
  a production cluster deployed as `dev` is not protected by it. Rung: mocked (each guard removed once to see its test
  go red); real cloud on Scaleway, from the pull request's branch before main was merged into it: a 3 control plane +
  2 worker dev cluster to a provider-side zero in under three minutes, and a `prod`-labelled tfvars refused. Not run:
  OVH, Outscale, `PROVIDER=all`, and the typed id on a real cloud. `task cluster-down` stays two commands for
  everything else.
- **The replica of the state keeps dated generations (#267).** `<key>.<UTC stamp>` objects beside the current one, the
  newest five kept, written only for a state that holds the Talos secrets; `backup-state.sh --list` lists them and
  `task restore-state` reads one for a failover (`STATE_GENERATION=`). Rung: mocked (a fake object store); real stores,
  Scaleway's and OVH's S3 as replicas, listed and copied down 2026-10-06: the current object plus five keys, the newest
  byte-identical to the current object. Not run: a restore from a generation, Outscale's store as a replica.
- **Cléa offers a bump only once it is old enough (#263).** A release younger than `min_release_age_days` (7) is "too young,
  eligible on <date>", a yanked, draft, retagged or advised-against release is held with its reason, an age that cannot be
  read is never eligible, and Renovate carries the same `minimumReleaseAge`. Rung: mocked; then seen on a hosted runner
  in the scheduled scan of 2026-10-11 (`893a395`), which resolved upstream for real (PyPI, GitHub releases and tags,
  OSV) and held every bump behind upstream back as "too young, eligible on <date>", offering none. Not seen: a bump
  offered after its cooling-off, or a hold for any other reason (yanked, draft, retagged, advised against).
- **`cluster-verify` asks where the control planes sit, and whether the workers' data volumes exist (#38, #62).** Each
  provider module outputs `control_plane_zones` (a required contract row), read from each server resource in the state.
  Three control planes in one failure domain end red and the red line names the knob; a 2+1 split (Scaleway over two
  zones) warns, since losing the zone that holds two loses etcd quorum; a missing output is UNCHECKED, fatal, never a
  pass. Each worker's own Talos API is asked, through the first control plane's tunnel, for every `worker_storage` volume
  (`ready`, `luks2`); that needs `task tunnels-up`, and without a tunnel the volume and schematic checks warn instead of
  passing. Rung: mocked; real cloud 2026-10-03: the verdict read on Outscale (red in one subregion, green across three)
  and OVH (green across three zones), matching the provider's own listing; 13/13 on all three clouds with encrypted
  worker disks, the read-back named only for Scaleway, green and red (red: a volume the workers lack). Again at 893a395
  on all three clouds, 2026-10-10 and 11: three failure domains read as HA (Scaleway's over three zones) and every
  worker's volumes read back, `cluster-verify` 14/14. Mocked only: OVH's one-zone red (read from the config; whether OVH
  reads its zone back or echoes the config is unknown) and Scaleway's 2+1 warning (not deployed when the check landed).
- **`task cluster-up` grows a live cluster (#59).** The apply that created a node also waited on its Talos port, reachable
  only through a tunnel that cannot exist before the node. `scripts/bootstrap/grow-nodes.sh` now runs first: it creates
  the machines, opens the tunnels and configures only the nodes the state has no configuration for; a no-op on a fresh
  cluster. Rung: mocked; real cloud by hand, 2026-10-03 (Validated, Growth).
- **`task cluster-up` lands the versions its tfvars declare.** A bumped `talos_version` used to reach the machine config
  and roll no node, with an empty plan and `cluster-verify` green (11 passed, 0 failed, Scaleway 2026-08-21). The
  verifier now compares running versions with the pin (12 passed, 1 failed on that state; a fleet split between two
  versions reads MIXED, a roll stopped part way); `cluster-up` prints the roll (`converge-versions.sh --check`) before
  its approval question and rolls the fleet after the bootstrap; `cluster-upgrade` climbs one minor at a time from
  `version-support.json`, which now knows Talos 1.14 (Kubernetes 1.32 to 1.37). Rung: real cloud once, Scaleway
  2026-08-21: a seven-step climb from Talos 1.12.7 / Kubernetes 1.30.0 to 1.13.9 / 1.36.3, longest outage 5 s, and a
  `cluster-up` on a matching fleet that rolled nothing. Also real cloud, Scaleway and Outscale, 2026-10-05: `cluster-up`
  read a worker left on v1.14.1 under a v1.14.2 pin (`cluster-verify` red, `MIXED`) and rolled it to v1.14.2
  (Validated). Mocked only: a `cluster-up` that carries a minor climb; the measured climbs used `cluster-upgrade`.
- **`task cluster-up` adopts a bootstrap the state forgot (#67, #40).** An apply interrupted after the node accepted the
  Bootstrap call left no bootstrap in the state, and phase 2 sent it again to a live etcd, which refuses it.
  `adopt-bootstrap.sh` asks every control plane for `etcd members` and imports the bootstrap only if one answers with a
  member row; a fresh cluster pays up to 15 s per control plane. The import lands before phase 2's approval question and
  declining does not undo it (the script prints the `tofu state rm` that does). Rung: mocked; real cloud, Scaleway only:
  2026-10-02, a state lost to PR #223's defect (three etcd members found, bootstrap imported, `cluster-verify` 12/12,
  `cluster-idempotency` passed), and 2026-10-03, a `SIGKILL` right after the Bootstrap call. Not on OVH or Outscale.
- **`task cluster-upgrade` also measures a Service (#41).** A 2-replica workload behind a Service (with a PDB when two
  nodes can take it) is polled through the apiserver proxy for the whole roll; failed samples and longest outage are
  reported beside the apiserver's, and samples taken while the apiserver is down count apart as BLIND. Reported, not
  gated. Rung: mocked; real cloud 2026-10-03 on Scaleway, OVH (the `upgrade-k8s` step in `docs/upgrade.md`, the
  Flux/CNPG roll in Validated) and Outscale.
- **`task cluster-shrink-plan` then `task cluster-shrink` remove nodes from a live cluster (#249).** Two commands, like
  destroy: `PLAN=` is required and `APPROVE=auto` does not collapse them; the scope comes from the saved plan and is
  derived again at apply. A worker run may take several nodes, highest index first; a control-plane run takes exactly
  one, never in the same run as a worker; the cluster keeps at least one of each, and below three control planes it needs
  `-- --allow-below-ha` on both commands. Per node: Longhorn eviction (workers only), drain, `talosctl shutdown`, delete the
  Node, a targeted destroy of exactly that node's resources; a control plane also takes an etcd snapshot, hands leadership
  off and runs `etcd leave`; the run ends with `_backup-state` and `cluster-verify`. Refusals, mechanism and figures:
  `docs/upgrade.md`, Removing nodes. The closing step applies every pending machine-config update, so make a config edit
  separately. A lowered count through `cluster-up` is now refused (Fixed). Rung: mocked, the only rung of every refusal
  but Longhorn's two-replica one (a real cluster refused that too); real cloud 2026-10-04 (Validated).
- **`task restore-state` rebuilds a cluster on another provider from the replica the first one left (#57).** When provider
  A is gone its tfstate survives as the `-backup` replica on B's store, the only carrier of the Talos PKI and the etcd
  secretbox key. `task restore-state PROVIDER=<b> ROLE=failover FROM=<A's env name>` (the file under `envs/` without
  `.tfvars`, e.g. `management-<a>`) copies the replica to B's state key and untracks everything but the three state-only
  Talos resources, so `task cluster-up` builds a cluster that A's saved kubeconfig and talosconfig still open. It is a
  rebuild, not a restore: etcd contents and application data are not in the replica. It refuses a target that holds
  resources or whose state cannot be read, a replica that is its own target, a plaintext replica, a state with no PKI and
  a `talos_version` below the one the PKI was made for; from the upload on, any failure removes the copy again (a `kill
  -9` leaves it, and the next run refuses, naming the object). The replica is only ever read. A's env file is gitignored
  and in no store, so after losing the workstation it is rebuilt by hand (runbook:
  `infrastructure/opentofu/cluster/README.md`, "Cross-provider failover"). Rung: mocked; real cloud once, OVH to Scaleway,
  2026-10-05 (Validated). Not run: any other provider pair, three control planes, Talos discovery with a live A.
- **`node_nameservers`: DNS-over-TLS or -HTTPS for the nodes' own resolver (#173).** Opt-in. A list of `{address,
  protocol, tls_server_name}` is rendered as one Talos `ResolverConfig` appended to every node, plus a `TimeSyncConfig`
  `bootTimeout` (`node_dns_boot_timeout`, default `90s`) when a server is encrypted; unset, every node's config is
  byte-identical. A list that mixes encrypted and plain entries is refused (a plain entry beside an encrypted one fell
  back to plaintext on a local QEMU node, not on a cloud), and a change replaces the apply resources, all in one apply.
  **A list no node can reach is found only at the next reboot, and that node then has no Talos API**: replacing it is
  the recovery, `nc -zvw5 <ip> 853` from a pod is the check beforehand, and `cluster-verify` does not read the resolver.
  Rung: mocked; real cloud once, DoT on OVH, 2026-10-05, 1 control plane + 1 worker (Validated). DoH and plain Do53:
  rendered and `talosctl validate`d only, no node run. Not recorded: Outscale, three control planes, a cold first boot
  with the list set, the apply on Scaleway (only its egress was read).
- **The Talos tunnels keep what their ssh said, and `ensure` and a short `open` quote it (#65).** Every tunnel's ssh
  output went to `/dev/null`, so a tunnel reported up with no listener left nothing to read. Each ssh now appends its
  `LogLevel=VERBOSE` output to `.talos-tunnel-<port>.log` beside the pidfile (gitignored: it names the bastion, so
  redact it before pasting it anywhere public); `open` and `open-direct` quote the log of each port that did not come
  up, and `ensure` quotes each tunnel that does not answer and says whether its ssh still runs. A log says how an ssh
  ended, not who asked it to; the cause of the 2026-08-18 deaths is still unknown (the issue is closed as not reproduced).
  Rung: mocked; seen once on a real Scaleway bastion with 2 tunnels, on the first version of this change (after a TERM,
  `ensure` quoted the client's closing lines and rebuilt 2/2). Not seen: a drop by the bastion, a KILL, `open-direct`.
- **A manual real-cloud deploy, verify and teardown workflow, dormant until its secrets exist (PR #257).**
  `.github/workflows/real-cloud-regression.yml` (`workflow_dispatch` only, one provider or all three, a "these are
  sandbox accounts" box, the teardown and an account-clean proof under `if: always()`). Its prerequisites step names
  whichever secret is missing, and none of them exists in the repository. Secrets reach a step only through `env:`,
  `kubectl` is the cluster's own pin and checksum-verified, and Outscale is judged on its VMs and public IPs because of
  #43. Rung: mocked (each shell step lifted out of the YAML and run with fake secrets); **never run against an account**.
- **`task state`, `task purge-orphans`, `task talosconfig-new`, `task local-rbac`.** `state PROVIDER=… [ADDR=…]` lists what
  a cluster's state holds and tells an absent state from an empty one, read-only; `purge-orphans PROVIDER=… [APPLY=1]`
  is the command the release checklist already named and the repository did not have. `talosconfig-new` issues a
  role-scoped talosconfig with a TTL (`os:reader`, 8 h by default) from the admin one, which the deploy hands out as
  `os:admin` valid a year; it refuses to report success if the node grants other roles. `local-rbac` asks the Docker
  cluster whether Talos enforces those roles. Rungs: `state` mocked (no real listing recorded); `purge-orphans` mocked
  and emulated; real cloud, read-only dry runs after the teardowns of 2026-10-10 and 11 on all three clouds (Scaleway
  and OVH: nothing to purge; Outscale: only the stuck Net of #43 is targeted, exit 1 as expected; Fixed, teardown);
  `talosconfig-new` Docker lane, then real cloud once, OVH 2026-10-03; `local-rbac` Docker only (2026-08-24, Talos
  v1.13.3; not run at the shipped pin, #291).
- **`task cluster-up` refuses, before it spends, a never-applied `prod` cluster whose replica is on the primary's cloud
  (#57).** Only the verifier said so, after the apply; it is now also red on a prod replica in another region of the same
  cloud. A self-hosted S3 only has to be another endpoint; a cluster name that already has a state object is only warned
  (it may be live). Rung: mocked.
- **A changed `admin_ip` can be applied.** The documented remedy stopped at the tunnel check on a bootstrapped cluster,
  because the bastion no longer let this machine in, and the escape hatch lived in a Taskfile comment. The check is
  `scripts/internal/tunnel-guard.sh`; its failure names `OA_SKIP_TUNNEL_GUARD=1`, and `docs/admin-access.md` has the
  procedure. Rung: mocked; real cloud once, Scaleway 2026-10-04 (Validated).
- **`docs/capacity.md`: what a cluster needs, per provider (#72).** The sizing floor and its evidence, what each module
  creates, the totals and `preflight-quotas` flags of every shipped example
  but the two emulated-lane ones; derived figures marked apart from measured.

### Changed

- **Talos v1.14.2 and Kubernetes v1.37.1 are the default pin (#181).** Both roots move together; 0.1.0's cluster root
  was v1.13.9 and v1.36.3, its Docker root v1.13.3 and v1.35.3. Rung: real cloud on all three clouds, 2026-10-03, under
  provider 0.11 (next bullet). The Docker lane follows the pin, and did not boot at it on the two hosts tried (kernel
  6.12, #291). It booted once, with 1 control plane + 1 worker, on a hosted runner (Cléa's weekly lane, 2026-10-11); its
  recorded 3 + 3 run (2026-08-24) is at v1.13.9 and v1.36.3.
- **The Talos provider is pinned at 0.12.0, and the module renders a 1.14 node under the v1.13 config contract (#241,
  #44).** Provider 0.12 reads `talos_version` on the machine-configuration data source as the config contract, not as
  the node's Talos, and for a 1.14 contract renders Talos's multi-document config, which the module's v1alpha1 patches
  collide with (seven errors on every config apply, measured on OVH); 0.11 could not render that contract and silently
  gave the 1.13 shape. One local, `config_contract` (v1.13, or the node's own version when older), now feeds both data
  sources, so a 1.14 node's rendered config equals 0.11's (offline, real providers, no node). The cluster root and the
  local lane pin `0.12.0` exactly (no lock file is committed, so a range could change the rendered text unseen) and the
  module's ceiling is `< 0.13.0`. `replace_triggered_by` (upstream `siderolabs/terraform-provider-talos#352`, fixed in
  0.12.0) stays: no run without it has happened (#83). **Existing checkouts must run `tofu init -backend=false -upgrade` in
  `infrastructure/opentofu/cluster`** (Upgrade notes). Rung: mocked; real cloud, Scaleway, 2026-10-05, 1 control plane +
  1 worker, then 3 control planes + 2 workers on all three clouds, `cluster-verify` 14/14, and a 0.1.0 cluster climbed
  by `cluster-upgrade` on each, 2026-10-06, the fresh builds repeated at the shipped pin on 2026-10-10 (Scaleway, OVH)
  and 2026-10-11 (Outscale) (Validated; Known limits has what was not measured).
- **The image lane keeps one state per Talos version (#69).** Each version has its own state
  (`talos-image-<provider>-<version>.tfstate`), so a build touches only its own version: building v1.14.2 no longer
  replaces v1.14.1 (0.1.0 replaced it, silently, #93). `task image-build PROVIDER=<p>` takes `LIST=1` (the versions
  held), `PRUNE=1 VERSION=<v>` (destroy one, refused while a
  tfvars pins it) and `RETAIN=1` (next bullet). Images only: there is one cluster state, and a node built from
  an older image joins the same cluster. The image state takes no lock: one operator per lane, one run at a time per
  checkout. Rules and recoveries: `infrastructure/opentofu/talos-image/README.md`; the first-build migration and its
  refusals are in Upgrade notes. Rung: mocked; real cloud, 2026-10-05, Scaleway and Outscale (Validated; Known limits
  has what was not run).
- **`RETAIN=1` keeps the cluster's Talos version and the one below it, and `task cluster-up` offers it (#69).** With N
  the newest `talos_version` a tfvars pins, it keeps N and the highest version held below it and destroys the rest,
  lowest first, so a node can still be created on the previous image while the cluster runs N: on a cluster moved from
  1.14.1 to 1.14.2 it keeps both, after the move to 1.14.3 it destroys 1.14.1. A version above N and a version a tfvars
  names (`talos_version`, or an `image_name` or `talos_image_file_id` override) are kept; an `image_id` or an unreadable
  tfvars refuses the run. "Still needed" is judged from this checkout's `envs/*-<provider>.tfvars` only: a cluster
  whose tfvars is on another workstation is not asked, and with none present `PRUNE=1` only warns. `cluster-up` runs it
  after its `cluster-verify`, asks tofu's own yes for each image it destroys and only warns if it fails; **under
  `APPROVE=auto` it never prunes** (it prints the command), and `cluster-upgrade` does not run it, so run it by hand
  once a climb is verified. Rung: mocked; real cloud, 2026-10-05, Scaleway and Outscale (Validated).
- **`task cluster-up` ends with `cluster-verify` and fails when it does (#84).** It used to print "complete" without
  asking the cluster, so a red cluster exited 0; `cluster-idempotency`, which runs `cluster-up`, now ends non-zero on a
  red verifier (`cluster-upgrade` already did in 0.1.0). Rung: mocked; seen red on a real Scaleway cluster, 2026-10-02.
- **Outscale spreads its nodes over the subregions listed in `availability_zones` (#58).** It read only the first entry,
  so three control planes shared one subregion. It now builds a private subnet per entry and places control planes and
  workers by index, a worker's data volumes in its node's subregion; the public subnet, bastion, NAT and load balancers
  stay in the first subregion (a load balancer takes one subnet, measured) and reach every node. A node's subnet is
  ignored after creation: **a cluster built before this keeps its layout and ends red, and no setting clears it**; so
  does a one-entry list. Rung: real cloud 2026-10-03 for the new layout (three control planes in three subregions,
  13/13, the load balancer UP on all three); the red was seen on the old module, 2026-10-03 (12 passed, 1 failed), the
  kept layout is the mocked plan's reading, and the new module has not been applied live over an old cluster.
- **OVH examples and defaults name availability zones OVH accepts (#72).** They said `["nova"]`, which Nova tolerates and
  Cinder rejects on EU-WEST-PAR, so the first apply died creating the workers' data volumes. Now `eu-west-par-a/b/c` in
  the examples, the cluster default and the module default. Rung: mocked for those; the three zone names deployed and
  verified 13/13 on a real OVH account, 2026-10-03, through a private tfvars, so the shipped defaults never ran.
- **Examples.** The Scaleway examples move to `POP2-4C-16G`, the sizing floor (0.1.0 shipped `POP2-2C-8G` and, for the
  workload one, `DEV1-M`, absent from `fr-par-3`), and stop pinning an image the lane no longer holds. Outscale stays at
  `tinav5.c2r4p1`, below the floor on purpose (the floor on five nodes plus the bastion is 22 vCPU against a default
  quota of 20): a bare cluster only, deployed and verified 2026-10-03 (`docs/capacity.md`). The examples that hard-pinned
  Talos v1.13.3 and Kubernetes v1.35.3, a pair no recorded cloud run used, now inherit the default pin.
- **The Docker lane is not a provider, and says so.** The cloud tasks (`cluster-*`, `infra-*`, `image-build`, `tunnels-up`
  and the rest) refuse `PROVIDER=local`: `cluster-up`, `cluster-down`, `cluster-upgrade`, `cluster-idempotency`,
  `image-build` and `teardown-all` with a message naming the family that applies, the others on the credential resolver's
  `unknown provider 'local'`; `task local-verify` exists because `cluster-verify PROVIDER=local` is refused.
  `K8S_API_PORT` moves the host port 6443 (a WSL2 reserved range made `local-up` unrunnable); `local-up` refuses in about
  a second on a host where `capsh` shows no `CAP_SYS_RESOURCE` (silent without `capsh`) instead of hanging 90 s;
  `local-down` runs on a clone with only this repository; `opentofu-local` pins what the cloud root pins; `task
  local-test` now fails when workers never become schedulable or Flux never comes up, where it printed "validated
  end-to-end" regardless (no run of either failure is recorded). Rung: local Docker 2026-08-24, default 3+3: six nodes
  Ready, Cilium 6/6, `local-verify` 6/6; the `PROVIDER=local` refusals: mocked (`task --dry`).
- **Provider contract, for module authors.** `control_plane_zones` is a required output, and a new rule 5 (scale-in)
  says how a node's resources must be indexed and named for `shrink-nodes.sh`. The contract's tables are
  executed by `check-provider-contract.sh`, by name and type (it required a `bastion_ssh_key` string no module declares;
  all four declare `bastion_ssh_keys`), and `tofu validate` now fails on a missing contract output where it answered
  `Success!` (`try()` could not tell an inactive provider from a missing attribute). Rung: mocked.
- **Decisions written down (#82, #56, #70, #80, #172), and `flux_namespace` validated.** The bastion stays, hardened in
  place; revisit with two or more operators, or a stateful service whose restore has been run. Outscale has no state lock
  by design: one operator at a time. `talosctl upgrade-k8s` measured no gentler than the config-driven Kubernetes step,
  which stays. For read-only work, mint one `os:reader` talosconfig by hand and reuse it until it expires rather than one
  per run (#80); the tasks still default to the admin one. `flux_namespace` must be `flux-system`, the only namespace the
  vendored Flux install creates. Steering traffic between two live clusters is health-checked DNS from a zone that shares
  no fate with either, not BGP or anycast across providers: none of the three documents a customer BGP peer or prefix for
  a VM (vendor pages read 2026-10-04). Not evaluated: a customer-operated router reaching each cloud over InterLink or
  DirectLink. DNS failover time (check interval times threshold, plus the TTL) is not measured.
- - **The examples and the default pin OpenAether-apps at its tag 0.1.0.** The twelve `envs/*.tfvars.example` that carry a
  `git_ref` (the two `feint-*` examples carry none) and the `git_ref` default in `variables.tf` now say `refs/tags/0.1.0`,
  so an apps commit cannot change a cluster that follows them; `refs/heads/<branch>` is how to develop against apps
  (Upgrade notes). The apps tag asserts only the static gates: its `CHANGELOG.md` says what it does not, and `task
  apps-validate` (Cilium parity between the foundation here and the CAPI children there, skill parity, the Flux DAG) is
  the check between the two. Flux is off by default and no validation leg of this release turned it on, so no cluster of
  this release has followed that tag. Rung: mocked (example values, a variable default and documentation); Cilium parity
  and the Flux DAG were run against a checkout of the tag.
- **Dependencies, final values (pins):** OpenTofu 1.13.1, Talos provider 0.12.0 (above), Cilium 1.20.2 (0.1.0 shipped
  1.20.0; the manifest is re-rendered; the cloud legs of 2026-10-10 and 2026-10-11 deployed it (`cluster-verify` counts
  Cilium running on every node), none of them isolates the bump), flux2 2.9.6 (the vendored install refreshed and its
  controller digests recorded for the first time (`task check-flux-digests`); it reaches only a `deploy_flux=true`
  cluster, which no lab sets), helm 4.3.0, flux-schema 0.15.0, go-task 3.54.0, `kubectl-cnpg` 1.30.1, gitleaks 8.30.1,
  plumber 0.5.20, commitizen 4.19.1, yamllint 1.38.0, Feint 0.13.0, and in `setup.sh` kubectl 1.37.1, aws-cli 2.37.9,
  checkov 3.3.22 and pre-commit 4.6.2; the pre-commit hooks lag (commitizen v4.9.1, yamllint v1.35.1). A workstation's
  `talosctl` is pinned, checksum-verified and taken from the cluster's own `talos_version`. Rung: mocked; the pinned
  binaries were installed and run, with no cloud, and `setup.sh` ran to the end in a bare `ubuntu:24.04` container with
  all five of its newest pins.
- **Maintainer tooling; mostly nothing an operator types.** `task evidence-check` goes red when a provider's newest
  `docs/status.md` row is not at the pin, is older than 45 days (`OA_EVIDENCE_MAX_AGE_DAYS`) or carries a ❌ or ⚠; it is in
  neither `task lint` nor `task test`, and `task preflight`, which an operator does type, runs it with `--warn` (a stale
  row warns, an unreadable table fails). Gates that were green on something they had stopped checking now fail:
  `render-check` offline (`RENDER_CHECK_ALLOW_OFFLINE=1` is the deliberate way around, and `preflight` then says
  INCOMPLETE), `tflint` skipping most directories, a typo in a Cilium `--set` flag (#112). Cléa (`docs/clea.md`) probes
  each pinned bump from cold in a bare container and never reaches a cloud; its push-token and `action-sha` fixes are not
  yet seen on a runner (#91). Cléa's lane exports `VERSION`, which made `test-talos-image.sh` fail in every probe until
  the harness defined its own environment (#286; mocked, no Cléa run has shown a verdict since, and whether the lane
  should stop exporting it is open). For contributors: rung receipts let CI check a pull request's declared rung (`task
  receipts`), the hand-kept backlog file is gone (tasks are GitHub issues, "where we stand" is `docs/status.md`) and
  `Assisted-by:` is a tool-only trailer with no model version. The rest is in `task --list-all`. Rung: mocked, each gate
  reproduced in both directions.

### Validated

Measured by hand on real accounts. Dates and figures come from `docs/status.md` and `docs/upgrade.md`, and, for the
passes of 2026-10-06 to 2026-10-11, from the maintainer's step records, kept outside the repository; control-plane
growth and the plan-only refusal from `docs/deployment-test-matrix.md` (growth also `docs/first-cluster.md`); the
changed `admin_ip` from `docs/admin-access.md`; the lock refusals from `docs/release-checklist.md`; the failover and the provider pin from
`docs/status.md`; the node resolver from the matrix and PR #268; the image lane's runs from the message of PRs #269 and
#272 only. Versions were read from the kubelets and each node's own Talos API, never from the tool that performed the
upgrade. A longest outage is the longest run of consecutive failed one-second probes.

- **The release code (`893a395`) on all three clouds, 2026-10-10 and 2026-10-11, each from an empty state under a fresh
  `bucket_suffix`, 3 control planes + 2 workers, at the shipped pin (Talos 1.14.2, Kubernetes 1.37.1, provider 0.12.0).**
  Scaleway over the example's three zones, OVH over `eu-west-par-a/b/c`, Outscale into a fresh Net over three subregions.
  On each: `cluster-up` (Scaleway 650 s, OVH 545 s on its first deploy, Outscale 1661 s, about 15 minutes of it the image
  build); `cluster-verify` 14 passed, 0 failed, 0 could not be checked, with the control planes read in three failure
  domains and every worker's encrypted data volume read back from its node; `cluster-idempotency` with the same nodes and
  no control plane rebooted; the lab's health suite (every node Ready, every pod healthy, a Service reachable from every
  node, DNS, egress, a NetworkPolicy that allows and denies, Cilium) 14 ok, 0 failed; a stand-alone `task etcd-snapshot`,
  encrypted, written to both buckets; `backup-state`, the encrypted state replicated to another cloud's store (Scaleway's
  to OVH's, OVH's and Outscale's to Scaleway's); an empty strict plan; the pinned schematic on every control plane; then
  the two commands of `task cluster-down` (52 resources in the plan on Scaleway, 62 on OVH, 64 on Outscale) and the
  provider's own answer. Scaleway: `purge-orphans` clean and `verify-provider-clean` rc 0. OVH: `purge-orphans` clean on
  its first pass; the `openstack` mode of `verify-provider-clean` was not run. Outscale never reads clean (#43):
  `verify-provider-clean` rc 0 (no VM, no unassociated public IP), the `purge-orphans` dry run exit 1 with only the stuck
  Net and what hangs on it, the run's own Net gone. Rung: real cloud, once per cloud (OVH twice), the repository's tasks
  and scripts called stage by stage by a maintainer's lab script that stops at the first red; the script and the health
  suite are outside the repository. Not run: OVH's one-zone red, read from the config only. An earlier pass on
  2026-10-06, on older commits, is superseded by this one.
- **OVH, 2026-10-10: two deploys and two teardowns in a row in one project; the second met #49 at first boot.** The first
  ran as above. The second stopped at its first `cluster-up`: phase 2 waited 900 s for control plane 2's Talos API and
  ended 201 after 1349 s, the other two answering. Nova said all three servers `ACTIVE`, power state 1, and the console
  showed no kernel message; the node stayed silent from the first seconds of its first boot for about twenty minutes. This
  is the situation of #49, again: the first OVH deploy of 2026-10-06 (`21c4a73`) ended the same way, at control plane 1. A
  Nova hard reboot of that one server, the hypervisor reset #49 prescribes, brought its Talos API up 5 s later; the same
  command resumed (326 s on the partial state) and every stage above then passed, `cluster-idempotency` with no control
  plane rebooted since the reset. No defect of the repository is shown and no cause: #49 stays open, blocked on the
  provider, with one more occurrence. Both teardowns ended `purge-orphans` clean on the first pass: the second teardown
  the release checklist asks for.
- **Outscale, 2026-10-11, into a fresh Net.** The first attempt, the evening before, stopped after 37 s at the image
  build, before an image, a snapshot or a machine existed: the account held an image of the pin's name that no state
  tracks (made 2026-10-03, untagged), and the plan would have created the same name, which Outscale refuses after the
  snapshot import. The same-name gate refused it. On the account owner's go, that one image and its one snapshot were
  deleted (checked by id, name and mapping first), the account's other images untouched; the second attempt rebuilt the
  image and ran as above in one `cluster-up`, `cluster-verify` 14 of 14 with three control planes in three subregions (a
  cluster built before #58 ends 13 of 14, by design). The pass of 2026-10-06 had needed several runs (transient API
  errors, and the same gate). Left standing, on purpose: the stuck Net of #43 and the three Talos images the lane keeps
  (v1.13.8, v1.14.1 and the rebuilt v1.14.2).
- **0.1.0 to this release, 2026-10-06, on `2f8bd02`, `task cluster-upgrade` through the same lab script, versions unset
  in the tfvars.** Each started from a cluster built by the 0.1.0 tag (3 control planes + 2 workers, under Talos
  provider 0.11); the climb ran under 0.12.0. Talos 1.13.9 to 1.14.2 and Kubernetes 1.36.3 to 1.37.1 on 5/5 nodes, read
  from the nodes. **Scaleway and OVH in one uninterrupted run** (1064 s and 962 s): `cluster-verify` 14/14, no control
  plane rebooted by the `cluster-idempotency` after it, the health suite 14/14, an empty strict plan, then teardown
  (Scaleway: `purge-orphans` clean and `verify-provider-clean` rc 0; OVH: `purge-orphans` clean). Through the load
  balancer, probed at 1 Hz: Scaleway `/readyz` 18 failed of 1056, longest run 3 s; OVH 6 of 956, longest 3 s. **Outscale
  was not one run:** the first apply modified the bastion in place and the run stopped on its dead tunnels (Upgrade
  notes); the same command resumed and converged, `cluster-verify` read 13 of 14 (the red line is the single-subregion
  verdict, Upgrade notes), the health suite 14/14, the strict plan empty, then teardown (`verify-provider-clean` rc 0; the
  `purge-orphans` dry run listing as many targets as the stuck Net of #43 holds, their ids not kept). Its interruption is
  the worst measured (Known limits). Before the four fixes under Fixed, none of these climbs completed: the first
  Scaleway attempt replaced the private network (16 to destroy, the API unreachable on every backend for 68 s), OVH's
  lost its tunnels with a replaced bastion, and a plain `cluster-up` was refused by the nodes four minutes into the
  apply. Outscale's climb on `2f8bd02` was not one clean run, and the idempotency re-run was not asserted there (its
  verify is red by design). **No climb was re-run on `893a395`.** Its apply path is `2f8bd02`'s, read in the diff and not
  re-run: no module of Scaleway, OVH, Outscale or Talos, no `.tf` of the cluster root beyond a comment and an output
  description, and the scripts that `cluster-up`, `cluster-upgrade` and `infra-apply` run changed only by a diagnostic
  paragraph added to `explain-failure.sh`, a helper added to `scripts/lib/common.sh` and a task name added to the receipt
  writer. The diff also adds `task teardown-all`, the Proxmox VM bastion's user and PyYAML in `setup.sh`.
- **Scaleway, 2026-10-02 and 2026-10-03, each from an empty project under a fresh `bucket_suffix` (#68).** The first:
  `cluster-up`, `cluster-verify` 12/12, two `cluster-idempotency` passes; the Talos step rolled six nodes with the
  apiserver failing 6 times in 474 probes, longest 1 s; the Kubernetes step stopped on a defect of ours (PR #223, Fixed),
  and `adopt-bootstrap` plus a plain `cluster-up` brought the state back, after which the fleet read 1.37.1 everywhere
  (whether that run rolled anything is not recorded). A control plane powered off for 80 s cost 3 failed
  probes in 360 and a write succeeded. Torn down and proven clean that night. The second, with encrypted worker disks, a
  Longhorn volume and a Service probe: `cluster-upgrade` 1.13.9 / 1.36.3 to 1.14.2 / 1.37.1 in place on 6/6 nodes,
  `cluster-verify` 13/13, `No changes.` after. Longest outage 2 s (6 failed in 764, Talos step; 9 in 805, Kubernetes
  step); the Service failed 0 times, a blob written before the climb read back with the same hash, the stateful pod was
  gapped 20 s and 16 s. The roll stopped once on PR #229's defect (Fixed). On the pair #181 names (Talos 1.14.1,
  Kubernetes 1.37.0) the same day, Longhorn was written, read from other workers and across a node reboot, and the worker
  volumes read back by `cluster-verify`.
- **OVH, 2026-10-03.** 3+3 across `eu-west-par-a/b/c`, encrypted worker disks, `cluster-verify` 13/13. Kubernetes 1.36.3 to
  1.37.1 through `talosctl upgrade-k8s` (#70), 10 s (11 failed in 430), then the pin; plan empty after the climb and
  after the pin. Its Talos step, 1.13.9 to 1.14.2 on 6/6 nodes, was the roll with Flux and CNPG below.
- **A roll with Flux and CNPG, OVH, 2026-10-03 (#64).** A lab, not a `deploy_flux` cluster: the vendored Flux controllers
  (v2.9.3, the vendored install until 2026-10-05), the CNPG operator 1.23.1 and local-path storage installed by hand, a
  three-instance CNPG cluster owned by a Flux Kustomization. `cluster-upgrade` took Talos 1.13.9 to 1.14.2: before every
  node the roll suspended the Kustomization and the CNPG budget, and at the end of each of its two rolls it checked both
  were restored (longest outage 1 s, 3 failed in 583; the Service 3 failed and 3 blind in 621). The surrounding
  `cluster-upgrade` exited 201, because its closing `cluster-verify` found `flux-system`; `cluster-verify` read 13/13 only
  after the lab was removed.
- **Outscale, 2026-10-03.** 3+3 `tinav5.c2r4p1`, encrypted worker disks, `cluster-verify` 13/13, 6/6 nodes to Talos 1.14.2
  and Kubernetes 1.37.1, `No changes.` three times, one after the climb. Longest outage 9 s (68 failed in 1535: 3 s on
  the Talos step, 9 s on Kubernetes); the Service probe failed 40 times with 20 blind samples in 1490, longest 3 s.
- **Growth, 2026-10-03.** Scaleway workers 3 to 6, one worker per `task cluster-up`, three runs in a row (3 to 4 to 5 to
  6), each ending `cluster-verify` 13/13. After those three the following full plan was not empty (`0 to add, N to
  change`, N one fewer than the worker count; not investigated); the 2026-10-04 grow-back ended with
  `cluster-idempotency` passed. Control planes 1 to 3: Outscale by one `cluster-up` (three control planes and two
  workers, 13/13, the load balancer UP on all three); Scaleway and OVH are recorded as 1 to 3 only. Worker growth on OVH
  and Outscale is not recorded.
- **Removing nodes, 2026-10-04**, on each cloud's 3-control-plane cluster at Talos 1.14.2, Cilium only: a worker, then a
  control plane (3 to 2). `cluster-verify` green after every run (13/13 after a worker, 12/12 after the control plane,
  which reads `~ NOT HA` at two), etcd with exactly the members left, the provider's API listing exactly the machines
  left. Each control-plane run took an etcd snapshot, encrypted and uploaded to both buckets, before the leave. During
  the control-plane removal the load balancer kept sending one request in three to the member that had left etcd, for 40
  to 76 s (12 to 13 failed `/readyz` per cloud; the figures and what they do not separate are in `docs/upgrade.md`); a
  client that retries does not see them. Worker removals: Outscale 1 failed probe of 215, OVH none (bar the probe's own
  kubeconfig read), Scaleway not probed. Scaleway was grown back to 3+2 by one `cluster-up`: 13/13,
  `cluster-idempotency` passed. On that cluster only: Longhorn 1.13.0 moved a sole replica to the worker that stays
  before the drain (the volume stayed healthy and attached, its blob's checksum held) and refused a volume wanting two
  replicas at `--plan`; CloudNativePG 1.30.1, on one control plane and two workers, moved a replica on the departing
  worker with its volume (1000 rows on both instances, the budget and the maintenance window restored) and, with the
  primary on the departing node, failed over to the replica on the other worker (of 368 inserts sent once a second
  through the read-write service 2 failed, a run of 2 s, and none acknowledged was lost). The refusal of a lowered count
  ran plan-only on two real Scaleway shrink plans, 2026-10-03: both refused.
- **An interrupted bootstrap, Scaleway only, 2026-10-03.** `cluster-up` interrupted twice on purpose in phase 2: tunnels
  killed before the bootstrap call (a plain re-run resumed), then `SIGKILL` right after it (`adopt-bootstrap` found 3 etcd
  members and imported it). The stale state lock that kill left needed `tofu force-unlock`, which `explain-failure.sh` now
  names, with the holder, and says to check that run is really gone first.
- **The reader talosconfig, OVH only, 2026-10-03.** `TALOSCONFIG=<os:reader file> task cluster-verify` passes 13/13 through
  the tunnels while `talosctl get machineconfig` is refused. Mint one and reuse it until it expires.
- **Lock behaviour.** Scaleway refused a second `plan` by name (2026-10-02, #56); OVH refused the second run (HTTP 412,
  undated); Outscale holds no lock by design and none appeared while an apply waited (re-measured 2026-10-03).
- **A changed `admin_ip`, Scaleway, 2026-10-04.** Set to an address that is not ours (SSH to the bastion timed out); the
  plain apply stopped at the tunnel check; `OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true` applied in under four
  minutes, SSH worked again, `cluster-verify` 13/13. Not run on OVH or Outscale.
- **A failover, OVH to Scaleway, 2026-10-05 (#57).** A = OVH (1 control plane + 1 worker, `environment = prod`) with its
  replica on Scaleway's store; B = Scaleway (1 + 1) with its replica on Outscale's; both under one fresh
  `bucket_suffix`. A reached `cluster-verify` 13/13 and was destroyed in the two commands. In a shell holding only B's
  and Outscale's keys, `restore-artifacts` read A's kubeconfig and talosconfig back byte-identical from the replica,
  `restore-state` put A's PKI in B's state key, and B's `cluster-up` ended on `cluster-verify` 13/13 with an empty
  strict plan. A's saved kubeconfig listed B's nodes Ready and A's talosconfig answered on B's control plane; A's stores
  were unchanged afterwards. Both purges were clean. The drill found `image-build` ignoring `ROLE=` (Fixed) and left its
  buckets on the three accounts for their owner.
- **The image lane, Scaleway and Outscale, 2026-10-05 (#69),** at 1 control plane + 1 worker, Talos 1.14.2. The legacy
  state was copied to its version's key (`No changes`, nothing rebuilt) and a second version built beside it. A worker
  created with an `image_name` override naming v1.14.1 booted that image, joined Ready on v1.14.1 and stayed on it;
  `cluster-verify` read the fleet `MIXED` (red), and with the override removed `cluster-up` rolled the node to v1.14.2
  and the verifier read green. `PRUNE=1` destroyed v1.14.1 and left the other versions untouched. Outscale's same-name
  gate refused a build of v1.13.8, an OMI of the account's that no state tracks, in 13 s with the snapshots unchanged;
  it asks the account (`ReadImages`) because the provider's `outscale_images` data source fails a whole plan on a name
  nobody holds, which the mocked provider hid.
- **Image retention, Scaleway and Outscale, 2026-10-05 (#69).** With a second tfvars pinning v1.14.0, `RETAIN=1` kept it
  and destroyed nothing; with that file gone it destroyed v1.14.0's images and snapshots, the provider's own listing
  agreed (the untracked v1.13.8 OMI on Outscale untouched), and a second `RETAIN=1` said `nothing to destroy`.
- **The Talos provider 0.12.0, Scaleway, 2026-10-05 (#241).** 1 control plane + 1 worker, Talos 1.14.2. A cluster built
  under 0.11 planned empty under the pin and `cluster-up` changed nothing (`cluster-verify` 12/12); rebuilt from an
  empty state under 0.12.0, it ended on `cluster-verify` 12/12 with `cluster-idempotency` green. Inside the 1.13
  contract 0.12.0 had already run on OVH and Outscale (a fresh deploy and a bump 1.13.9 to 1.13.11, 13/13, plan empty
  after). At the shipped pin it has since run with three control planes: the climb from a 0.1.0 cluster on all three
  clouds (2026-10-06) and a deploy from empty on all three (2026-10-10 and 2026-10-11), both above.
- **The node resolver, OVH, 2026-10-05 (#173).** 1 control plane + 1 worker, Talos 1.14.2. Unset planned empty; setting
  the list replaced both `talos_machine_configuration_apply` with no "inconsistent final plan" (upstream #352),
  `cluster-up` applied it with no reboot and the strict plan was empty after. Both nodes resolved over DoT (a capture
  during image pulls showed tcp/853 and no udp/53), pods resolved names with a DoT-only list, and a healthy worker
  reboot was Ready in 47 s. A list no node can reach: the rebooted worker never started its Talos
  API (port 853 unreachable) and was still NotReady after 10 minutes with the 90 s bound in place; only replacing it
  recovers it.

### Fixed

- **The Proxmox VM bastion's user is `bastion`, not the image's `ubuntu` (PR #285).** cloud-init ignores a second
  definition of a user the image already has, so `ubuntu` would never join `bastion-admins` and sshd would refuse the key
  (measured on OVH). One local feeds the VM and the output. Rung: mocked; never applied on a real Proxmox host.
- **A bastion change under the Talos tunnels is explained (#65).** When an apply modifies, replaces or stops the bastion and
  the config applies then fail on refused tunnel ports, `explain-failure` says the change landed and that re-running is the
  fix. The apply still kills the tunnels (Upgrade notes; #288). Rung: mocked, the pattern checked against the real Outscale
  transcript; no real run is recorded where `explain-failure` said it.
- **Upgrading a 0.1.0 cluster to this release, found by running it on real clouds (PR #280, refs #79, #81, #278, #279).**
  Four defects stood between `git pull` and a working upgrade. A Scaleway network built under 0.1.0 had its subnet
  replaced by the new pin, and every private NIC behind it. The shared bastion cloud-init had four comment lines edited,
  which replaced the bastion on OVH mid-apply and killed the Talos tunnels (the default render is 0.1.0's bytes again, and
  a test pins its hash). `task cluster-up` pushed a Kubernetes pin the running Talos refuses, four minutes into the apply
  (`converge-versions.sh` now stops before the plan and names `task cluster-upgrade`). `cluster-upgrade` left the axis
  that does not move at the shipped default, so its first step did the same (it pins that axis where it runs). **To
  upgrade: `task cluster-upgrade`.** Rung: mocked for each guard (the Scaleway one pins two lines of HCL; no mocked plan
  shows a replacement), each removed once to see its test go red; real cloud: Scaleway and OVH climbs (Validated), the
  bastion fix observed on OVH only (Upgrade notes for Outscale).
- **Two more defects the validation hit, both in our own code: a check and the image lane.**
  The replica check of `cluster-verify` read
  `aws s3 ls | grep -q` as "not found" when `grep` exited first under `pipefail` (PR #275), and the Image Factory request of
  the image lane had no retry and failed the plan on one failed request (PR #276, up to four retries now). A test that
  captured output into
  `grep -q` through a pipe failed once the same way (PR #284); the harnesses use here-strings now. Rung: mocked; PR #275's
  fix was also run six times each way on a real replica (2 of 6 failed piped, 0 of 6 once captured). Not shown: that
  PR #276's retry rescues a real failed request (the failure was not reproduced on demand).
- **Lowering `control_planes` or `workers` destroyed the highest-index machine and its data volumes, with no drain, no
  etcd leave and no Node delete, and nothing said so.** `cluster-up`, `infra-apply` and `grow-nodes.sh` now stop on a plan
  that deletes a node of a bootstrapped cluster (`grow-nodes.sh` allows creates only), and `node_distribution` is
  refused when an entry has workers and no control plane (PR #246). Removal has its own commands (Added). Rung: mocked;
  two real Scaleway plans refused, plan only.
- **The roll deadlocked on Longhorn when it had as many replicas as workers (PR #229).** It waited for Longhorn to be
  healthy before uncordoning the node it had just rebuilt, but Longhorn puts no replica on a cordoned node, so the 600 s
  gate ran out. The node is uncordoned first. Rung: mocked; real cloud once, Scaleway 2026-10-03: found there (healthy 63 s
  after a manual uncordon), then the resumed `cluster-upgrade` ran the new order on two workers, the gate passing, rc 0.
  Not measured: a volume with fewer replicas than workers, where the old order also passed.
- **A roll exits 1 and names what is left when a Flux Kustomization is still suspended or a CNPG budget is missing
  (#64).** The exit trap restored them and nothing looked afterwards. The roll now waits (about two minutes, up to 211 s
  with the apiserver down; `RESTORE_TIMEOUT`, `RESTORE_POLL`, `RESTORE_REQUEST_TIMEOUT`), and a failed owner-label read
  refuses the roll on the way in. Ctrl+C ends the wait (exit 130); a roll stopped between nodes says so instead of
  "complete". The verdict comes after the last node is replaced, so do not re-run replacement mode to clear it (it
  replaces every node again): fix what is named and run `scripts/ops/backup-state.sh`, which `task cluster-roll` then
  skips, while `cluster-upgrade` stops between its two rolls. Rung: mocked; one real roll, the OVH lab above, green path
  only. CNPG 1.23.1 creates `<name>-primary` for a one-instance cluster (local Docker, scratch script, no receipt); a real
  cloud saw only three instances. Not observed: the failure branches on a real cluster (a Kustomization that stays
  suspended, a budget the operator never re-creates), a real Ctrl+C, and the two task effects (mocked only).
- **A size change through `cluster-roll` resized every node at once (#51, PR #222).** Scaleway 2026-10-02: with
  `instance_type` raised, `-- --workers-only` replaced worker 0 and its config step resized all three control planes, the
  API down 56 s. The roll now plans both steps before the cordon and refuses a plan that changes another node; a size
  change goes one node at a time, in place, 1 s blips (`docs/upgrade.md`). Rung: mocked; the refusal was seen at worker 0
  on that cluster, from an uncommitted pre-review tree. A resize is in place on every provider: measured on OVH
  (2026-08-15) and Scaleway (2026-10-02); Outscale and Proxmox from provider source and an offline plan.
- **`infra-plan` and `infra-apply` read an unreadable state as "no bootstrap" (PR #223).** On any read failure (an S3 error,
  a bad credential) a bootstrapped cluster's node counts were zeroed and its bootstrap, machine configs and kubeconfig
  dropped from the state; a live Scaleway upgrade ended that way on 2026-10-02, and `adopt-bootstrap` plus a plain
  `cluster-up` brought it back. It now answers only when the state is read or absent. Rung: mocked; against that cluster's
  state the helper answered true, a wrong secret key made it stop quoting OpenTofu's error, an absent state read as
  absent. Why the original read failed is not known.
- **A state that lost its Talos secrets is refused, and the teardown plan replicates the state before it untracks them
  (#66).** `task infra-down-plan` takes `talos_machine_secrets` out of the state to compute a destroy plan
  (`prevent_destroy` is a plan-time check), and so does `tofu state rm` by hand. Declining the destroy left nodes that
  trust a PKI the state no longer held: the next `cluster-up` minted another and every Talos call ended in `x509:
  certificate signed by unknown authority` while Kubernetes stayed healthy. Now `bootstrap-in-state.sh` refuses, before
  any plan of `cluster-up`, `infra-plan`, `infra-apply`, `cluster-roll` and `cluster-shrink`, a state that holds the
  bootstrap, a machine config or the kubeconfig without the secrets; `backup-state.sh` refuses to replicate it, so the
  replica stays the undo; `infra-down-plan` replicates first and never blocks a teardown. The cluster README's "Lost the
  Talos secrets" gives two recoveries. Rung: mocked; real cloud, Scaleway and OVH, 1 control plane + 1 worker,
  2026-10-04 and 2026-10-05: the symptom, the refusals and the recoveries (both on Scaleway; recovery 2 on OVH, the
  provider of the original incident). At the merged head the happy path ran for real in the teardowns of 2026-10-10 and
  2026-10-11 on all three clouds (the state replicated to another cloud's store, the secrets untracked, the undo
  printed); the refusals by `backup-state.sh` and the `cluster-roll` guard are mocked only (Known limits has what was not
  seen).
- **`restore-artifacts` read the wrong replica, and `image-build` ignored `ROLE=` (#57).** A replica on another cloud
  was opened with the cluster's own key, or not at all: the replica's keys were looked up without its endpoint, the
  bucket was named from `--role` (which picks the file) instead of the file's `cluster_role`, the last quoted string of
  a tfvars line became the replica endpoint (the `"dev"` of an inline comment), and every fetch error read as "not
  found". The `image-build` task never told the script which role it served, so on a machine holding only a failover
  file the lane looked for `management-<provider>.tfvars` and fell back to the shared `openaether` bucket namespace, a
  name another customer may own; the failover cluster could not be created. Rung: mocked; the `image-build` defect was
  found by the real failover drill (Validated), which also ran the fixed `restore-artifacts` on real stores (PR #271).
- **The roll applied a plan other than the one it counted (#55), and missed a worker's data disk (PR #247).** Each per-node
  apply now plans to a file, counts deletes from it and applies it. `node_targets` matched `worker_data[<n>]` where OVH's
  attach and Outscale's link resources are keyed `"w<worker>-d<disk>"`, so a replaced worker lost its data disk until the
  next full apply (inferred from the graph, not run). Rung: mocked for both. #55's change merged 2026-09-26 and the
  receipts of the real rolls of 2026-10-03 on Scaleway and OVH are from heads that contain it, and #55 closed on a real
  Scaleway roll of 2026-10-02 (three workers replaced one at a time, each plan saved and counted before its apply, rc 0).
  PR #247's OVH and Outscale attach and link targets have never run on a real cloud (the 2026-10-03 climbs were in-place
  `--upgrade` rolls, which keep the node's disk).
- **`task cluster-upgrade` could not upgrade Talos, and could read another cluster's fleet (#181, PR #200).** It built
  the image before moving `talos_version`, and the image lane then refused to build while any tfvars pinned another
  version. It now moves the pin first (a failed build leaves it at the target and the previous image untouched, and the
  message says how to put the pin back) and fetches its own kubeconfig, not whichever cluster wrote the shared one last.
  Rung: mocked; the 2026-10-03 climbs on all three clouds ran in this order, on the single-image lane #69 replaced.
- **`cluster-roll` rolled the management state whatever `ROLE=` said (PR #37).** `cluster-upgrade ROLE=workload` applied the
  workload tfvars and then rolled the management cluster; both now follow `ROLE=`. Rung: mocked; the workload role has no
  real-cloud run.
- **`task upgrade PROVIDER=x DRY_RUN=1` started a real upgrade (PR #218), `UPGRADE_TALOS_TO` and `UPGRADE_K8S_TO` on the
  command line were ignored too; `task cluster-up` checked the passphrase after creating the buckets (PR #217) and
  advertised a `VERSION=` it ignored.** A Task variable is not an environment variable, so the script never saw them; the
  target now passes all three on; the passphrase check runs first; the tfvars pin decides the version. A dry run also
  leaves no rung receipt. Rung: mocked.
- **`etcd-snapshot.sh` retention deleted almost everything while a cluster had the fewest snapshots (PR #167).**
  The prune slice went
  negative below `KEEP` objects and jq counts a negative end from the end: at `KEEP=30`, 29 snapshots became 1, every
  run. Two siblings fell out: an optional tfvars key silently killed the scripts that read it, and `s3_cred` with kind and
  type swapped printed the secret where an access-key id belongs. Rung: mocked. The script also ran inside the three real
  control-plane removals of 2026-10-04 (snapshot, encryption, upload to both buckets, retention; each run rc 0), and
  stand-alone as `task etcd-snapshot` on each cloud (2026-10-10 on Scaleway and OVH, 2026-10-11 on Outscale, and once
  before on 2026-10-06 on an older commit; real cloud, by hand): the object encrypted and in both buckets, rc 0.
  Retention was not read, and none of those snapshots was restored.
- **Building a Talos image for one cluster could delete the image another cluster's tfvars still pinned (#93), and a
  Factory answer without a schematic id went to "image already up to date" one step from a billable publish.** The lane
  held one image per provider and nothing failed until the other cluster's next plan; with one state per version a
  build can no longer replace another version's image (Changed; retention and prune still read only this checkout's
  tfvars). `talos-image.sh` also refuses when the Factory answers without a schematic id
  (`TALOS_IMAGE_ALLOW_OFFLINE=1` is the deliberate way around). Rung: mocked for the refusal; the lane's real runs are
  in Validated.
- **`seed-openbao.sh` named a backups bucket that did not exist on any cluster deployed under a `bucket_suffix` (#166).**
  Restic and Loki were seeded with the wrong name and the seeder reported success. The name now comes from the derivation
  every other caller uses. Rung: mocked.
- **The Scaleway node security group opened every port (#79).** The provider stored an omitted port and `port = 0` as the
  same rule, so an earlier fix changed nothing. The group now lists the ports this repository's layers serve over the
  private network, from the module's own subnet, pinned to the private network's own /22; `100.64.0.0/10` keeps only the
  load balancer backend ports, and the rules sourced from the load balancers' public IPs, the dead bastion-public-IP rule
  and the `10.0.0.0/8` rule are gone. Rung: mocked, and emulated (apply, empty re-plan, destroy of the whole root); real
  cloud on Scaleway, 2026-10-02, where the load balancer read 3 backends `running` and its last health check `passed`.
  Applying it to an existing cluster is in Upgrade notes.
- **The teardown proofs read "could not ask" as "clean".** Scaleway had no check in `verify-provider-clean.py` (exit 2); it
  now lists the cluster's servers, load balancers, gateways, security groups and networks plus every detached IP and
  volume. The Scaleway purge (`task purge-orphans PROVIDER=scaleway APPLY=1`) now also lists and deletes what it never
  touched, public gateways, their IPs, load balancer IPs left without a load balancer, security groups and instance
  volumes, and it read the first 50 items of each list only; it now reads page by page. A kind no zone answered, missing
  credentials, a refused OVH login or region, and a refusing endpoint under `--apply` exit 2, not the 1 that means
  "leftovers" or a clean 0; `--apply` no longer ends on "The project is clean" and asks for a re-run; `ovh.py` counts
  refused calls (#63); `edge-down.sh` no longer sends a Scaleway or Outscale operator to the OpenStack-only deleter;
  Outscale lists leftover snapshots (#71, PR #108) and this account's images, never deleting either (#107). Rung: mocked
  and emulated; real cloud, read-only: Outscale's image read, and the Scaleway checker (rc 0) and purge dry run (nothing
  to purge) after the teardowns of 2026-10-06 and 2026-10-10. Buckets are not listed.
- **The bastion's SSH-CA hooks shipped inert (#81).** `TrustedUserCAKeys` and `AuthorizedPrincipalsFile` were hardcoded
  to an empty file; `bastion_ssh_ca_public_key` and `bastion_ssh_ca_principals` are now variables of all four provider
  modules, default `""`, identical rendered bytes when unset. **The cluster root does not forward them, so no tfvars
  can turn SSH-CA on yet:** enabling it means editing the root. `task ssh-ca-check` now refuses to start without Docker
  instead of skipping with exit 0. Rung: local Docker (`task ssh-ca-check`, a real sshd); never on a cloud bastion, and
  `bastion-harden-check.sh` has no recorded run against one.
- **`converge-versions.sh` had no downgrade guard of its own (#90).** It survived a downgrade only by accident, on two
  layers it does not own. It now refuses a pin semver-lower than what the fleet runs, naming both. Rung: mocked.
- **Statements about a deploy that were wrong.** The Taskfile said `cluster-up` asks once; it asks twice (the phase-1
  plan and `bootstrap-phase2`'s). `cluster-upgrade` said its applies ask; they run with `APPROVE=auto`. On Proxmox with
  `enable_bastion` the root now reports the VM's user, `bastion` (PRs #209 and #285; Known limits).
  0.1.0's docs said the first
  apply after a `talos_version` bump fails once on OVH and Outscale and must be re-run (upstream
  `siderolabs/terraform-provider-talos#352`); the module already carried the workaround (`replace_triggered_by`) in the
  0.1.0 tag, and the 2026-10-03 climbs applied the bump in one apply on all three clouds, through `cluster-upgrade`,
  which has no retry.
- **`setup.sh` died, or silently kept an old tool, on a bare machine.** `talosctl` is installed from a pinned,
  checksummed release; OpenTofu is pinned instead of asking the GitHub API for the newest (a 403 took the bootstrap
  down) and no longer goes through snap or brew, which cannot install a named version; the pinned ShellCheck installer
  installs `xz-utils` when missing (its absence also made Cléa blame flux2, #174); `check_cmd` compares versions, so an
  upgrade is no longer skipped; `sudo` is asked whether it can be used, not whether it exists; checkov goes in a venv so
  `task security`'s checkov step can finish on Ubuntu 24.04 (its trivy step needs a trivy `setup.sh` does not install); it
  now also installs actionlint, gitleaks, plumber and the flux-schema
  plugin; kubectl (checksum-verified), aws-cli, checkov, yamllint and pre-commit, installed at whatever upstream served
  that day, are pinned, so Cléa's probes compare a version instead of watching one move. Rung: mocked; run from cold on
  one machine the repository had never been set up on; a bare `ubuntu:24.04` is recorded for the OpenTofu 403, the
  missing `xz` and the five new pins (run to the end, all five at their pin).
- **`task preflight` died on a clean machine while `setup.sh` said the environment was ready (#289, #290).** `render-check`
  now reads Cilium's effective config with PyYAML (`import yaml`; 0.1.0's did not) and nothing installed it; CI hid it, its
  runner image ships it. `setup.sh` now installs `python3-yaml` (apt) or `pyyaml` (brew), or names the package and carries
  on. The same clean-machine clone found `test-cluster-checks.sh` printing `command not found` on every run (its stubs were
  defined after their first call). Rung: mocked; local Docker: a bare `ubuntu:24.04` clone of the fix's merge commit ran
  `setup.sh` and then `task preflight` to the end, 2026-10-10. Not run: macOS (the brew branch is stub-only), another
  distribution.
- **A real `envs/*.tfvars` turned `task lint` red and was rewritten or deleted by the tooling (#191).** `task fmt` and the
  pre-commit hook rewrote the ignored files, the hook while saying Passed, and several harnesses wrote and deleted their
  fixtures in `envs/`. Both leave the real directory alone. Rung: mocked, with synthetic tfvars planted in `envs/`.

### Security

- **`admin_ip` refuses to open the cluster to the internet.** The variable had no `validation`, so `["0.0.0.0/0"]` was
  accepted in silence, and it feeds bastion sshd and the 6443 LB ACL on all four providers at once. Behind that ACL sits a
  `system:masters` kubeconfig Kubernetes cannot revoke. Three rules now reject an empty list, an entry without a prefix
  (including the `YOUR_IP/32` of a copied example) and any `/0`, read from the prefix. Rung: mocked (`tofu test`); each
  rule was deleted in turn and the suite watched to go red before it was kept.
- **Admin access is documented as unrevocable where it is unrevocable.** [`docs/admin-access.md`](docs/admin-access.md)
  says what a leaked kubeconfig costs, instead of leaving the reader to find out.
- **The Scaleway node security group lists ports instead of opening every one (#79, Fixed).** Scaleway's security groups
  filter public traffic only and these nodes have no public IP, so on this provider the list declares the perimeter; it
  does not enforce it.
- **Credential lifetime can be narrowed:** `task talosconfig-new` (Added) issues a role-scoped talosconfig that expires;
  it is not the default, and the deploy still hands out `os:admin` valid a year.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **Proxmox has never been applied on real hardware (#48).** The module is code and mocked tests; no tunnel has gone
  through a Proxmox VM bastion. Its user is `bastion` like on the other clouds (it was the image's `ubuntu`, which
  cloud-init cannot add to `bastion-admins`), mocked only (#201).
- **The real-cloud workflow has never run.** Its secrets, a dedicated SSH key, the tfvars of sandbox accounts and a
  decision on `admin_ip` (a hosted runner has no small stable IP) are the owner's to create; the first dispatch is where
  a real account gets to disagree with it.
- **Removing a node: a half-way stop has only run against fixtures, never on a real cluster.** Longhorn's eviction and
  CNPG (a replica, and a primary) ran on Scaleway only. A node that holds a node-local volume is refused, not migrated.
  The load balancer keeps sending one request in three to the departed control plane for 40 to 76 s (measured on all
  three clouds); taking the member out first is not built, and its effect was not measured.
- **A control-plane roll with zero failed probes has not happened on any cloud (#42).** Longest outage in the runs of
  2026-10-02 and 2026-10-03, Talos step: 1-2 s on Scaleway, 1 s on OVH, 3 s on Outscale; Kubernetes step: 2 s on Scaleway,
  9 s on Outscale (OVH: 10 s through `upgrade-k8s`). **Outscale on a cluster built by 0.1.0 (2026-10-06): about 22 s with
  all three apiservers down at once and 48 consecutive failed `/livez` samples through the load balancer (25 on `/readyz`)
  in the Kubernetes step** (`cluster-upgrade`'s own probe read 8 s for the same run; the two disagree and it is not
  explained). Plan for a gap, and for a longer one on Outscale.
- **The failover ran for one provider pair, and only as a rebuild (#57).** OVH to Scaleway, 1 control plane + 1 worker
  each, 2026-10-05 (Validated). Not run: any other pair, three control planes, Talos discovery with a live A (its
  records can outlive A by up to 30 minutes: read `talosctl get members` on B). Etcd contents and application data are
  not in the two stores. A's gitignored env file is in no store, and backing it up is undecided.
- **Flux is off by default, and `cluster-verify` fails a cluster that has a `flux-system` namespace.** The one roll with
  Flux and CNPG was a hand-installed lab on OVH (Validated). Flux's own controllers no longer record
  `gotk_reconcile_condition` (by about Flux 2.5, inferred from flux2's `go.mod`, not measured), so no per-object Ready
  signal comes from them: per-object state is `gotk_resource_info` through kube-state-metrics, whose manifests live in
  `OpenAether-apps` (#46). The vendored install is flux2 2.9.6 and has run on no cluster. There is no CAPI and no
  multi-cluster; a management cluster is an optional overlay.
- **Outscale: a Net that will not delete (#43).** One Net from before the load balancer fix still refuses deletion on a
  dependency no read returns; only Outscale can clear it, `purge-orphans` there cannot read clean while it exists, and
  Outscale's instruction is to create no further load balancer in that Net and use a fresh one. After `fleet-down`
  completes, the account lists a load balancer and a Net as `deleting` for about three minutes: read it again before
  calling it dirty. There is no state lock: one operator at a time.
- **Scaleway over two zones is a 2+1 split and a warning that has only run mocked.** Over the shipped example's three
  zones `cluster-verify` read three failure domains on a real account (2026-10-10, by hand). The Outscale
  examples sit below the sizing floor on purpose (bare cluster only).
- **The Talos provider is 0.12.0, and the climbs of 2026-10-02 and 2026-10-03 ran under 0.11 (#241).** Under 0.12.0, real
  cloud by hand, `cluster-upgrade` took clusters built by 0.1.0 (3 control planes + 2 workers) from 1.13.9 to 1.14.2 on
  all three clouds on 2026-10-06 (Outscale after one resume), and a fresh 1.14.2 cluster of that shape was built and
  verified on all three (2026-10-06, then the release code on 2026-10-10 and 2026-10-11); at 1 control plane + 1 worker a
  1.14 cluster was built and verified on Scaleway (2026-10-05); inside the 1.13 contract it ran on OVH and Outscale (a
  fresh deploy and a bump 1.13.9 to 1.13.11, 13/13), with `replace_triggered_by` still in. Not measured: a run without
  `replace_triggered_by` (#83). `talos_machine` (#44) is not adopted.
- **A state that lost the Talos secrets is refused, and comes back only from a replica copy or a talosconfig the nodes
  still trust (#66).** With neither there is no way back from here. The cause of the 2026-08-15 mismatch is not
  established; the version flip is refused by `prevent_destroy` and the interrupted-apply path was not broken. Not seen
  on a real cloud: Outscale, three control planes, a replica on another provider, `cluster-verify` on a lost PKI.
- **Rolling an upgrade back is not proven (#270).** The image lane keeps the cluster's version and the one below it
  (#69), which is the medium for a node on the previous Talos, and nothing more: `converge-versions.sh` refuses a pin
  below what the fleet runs, `talosctl rollback` is wrapped by no script and described by no runbook, and no run is
  recorded that took a rolled node back. A node created on the previous image joined Ready on it and stayed there; the
  fleet read red, `MIXED`, until `cluster-up` rolled it forward.
- **The image lane's extra paths ran on Scaleway and Outscale only (#69, 2026-10-05), and its retention needs a person.**
  The extra paths are the legacy-state copy, a second version beside, `PRUNE`, `RETAIN` and a node on the previous image;
  its plain build ran inside the release deploys of 2026-10-10 and 2026-10-11 on all three clouds. Not run: those extra
  paths on OVH, Proxmox, the retention hook inside `cluster-up` under a real terminal and tofu, the destroy of a held set
  through it, a legacy state holding the oldest version on a real backend, `--import-snapshot` (stand-ins only), a node
  one minor behind, a control plane on an older image. Retention never prunes under `APPROVE=auto` and `cluster-upgrade`
  does not run it, so an unattended run keeps every image; it reads this checkout's tfvars only, so a cluster whose tfvars
  is elsewhere is not asked.
- **Buckets stand on the three accounts, and only a person empties them.** Each of the final validation runs (2026-10-10
  and 2026-10-11) left its state, its etcd snapshots and a replica of the state on another cloud. The old `-talos-staging`
  buckets were emptied and deleted by hand on 2026-10-06 (#73, closed). The image lane's `-talos-import` and
  `-talos-image` buckets stand too, those of the final runs included, on Scaleway and Outscale. No script enumerates
  buckets, and `purge-orphans` matches resources, not buckets.
- **Destroying a cluster whose pinned image is gone is unproven (#269).** On Outscale `infra-plan` fails on the missing
  image and `infra-down-plan` takes its `-refresh=false` fallback; that fallback's plan was never applied (an equal plan,
  made after the override was removed, was), and Scaleway did not reproduce the failure.
- **The Docker lane at 1.14.2 did not boot on either host tried by hand, both kernel 6.12 (#291).** On the second (Docker
  29, containerd image store) the guards passed, six containers started and every node log read ended in the same fatal
  error while the node set up its `/etc` overlay (`FSCONFIG_SET_FD`); the bootstrap then waited until interrupted, at ten
  minutes, and nothing refuses such a host. The recorded 3 control plane + 3 worker run is at v1.13.9 and v1.36.3
  (2026-08-24). At 1.14.2 and 1.37.1 the lane booted once, on a hosted runner (kernel 6.17, Cléa's weekly lane, 1 control
  plane + 1 worker, `local-verify` 8 passed, 2026-10-11). Rung: local Docker. Not run: the default 3 + 3 at this pin.
- **The purged address is still served by GitHub, by its SHA and in the original pull request's diff (#61).** Only GitHub
  can remove it; a published value is published.
- **The emulated lane is weaker than the cloud:** the lanes that destroy run the Scaleway provider below 2.83.0 while real
  clusters run newer, the fix waiting on a Feint release (#179); `module.scw` was recorded twice on a real Scaleway
  account (2026-10-05, 2026-10-08; one control plane and one worker) and replayed against the emulator, where the replay
  diverges and the first divergence of each chain is not isolated; Outscale was never recorded, and `feint shapes
  --check`, which compares a fixed read list, was dropped as the bar (#76, closed); `talos-image` is outside the lane
  (#47).
- **`task security` was not run for this release** (the validating host had no `trivy`): skipped, not passed. CI's IaC
  Security Scan was green on `main` at the release code, `893a395`.
- **Never recorded against real infrastructure:** `bastion-harden-check.sh` on a real bastion, `k8s_lb_mode = "vip"` on
  OVH, the `workload` role.
- **The tag ruleset blocks moving or deleting any tag, 0.1.0 included**, so a release tag cannot be re-cut. That the ruleset
  has no bypass actors is checked only by an admin's run of `check-required-checks.sh` (CI's token cannot read them), and
  the admin run of 2026-10-10 found none.
- **Also open:** an apply that changes the bastion kills the Talos tunnels mid-run, and nothing refuses or splits that
  plan (#288); why the tunnels died on Outscale in August (#65, closed as not reproduced on 2026-10-08; transcripts are
  now kept, one induced TERM was quoted correctly and no unprompted death is recorded), and an OVH node that can stay
  `ACTIVE` while dead (#49, blocked on the provider): seen on a real account at the first boot of a fresh deploy on
  2026-10-06 and again on 2026-10-10 (one deploy of two that day), recovered each time by a Nova hard reboot of that node
  alone and the same `cluster-up` resumed; the cause is not known and no frequency is claimed.

### Upgrade notes

For an operator on 0.1.0. Read the plan before you approve it, and the roll `cluster-up` prints.

- **A tfvars that leaves `talos_version` and `kubernetes_version` unset now inherits v1.14.2 and v1.37.1, and `cluster-up`
  is built to converge the fleet onto them.** It prints the roll before it asks, but a plain pull then `cluster-up` is a
  Talos 1.13 to 1.14 and Kubernetes 1.36 to 1.37 upgrade, and `cluster-verify` is red until it lands. A minor climb
  through `cluster-up` has only run mocked, and so has its stop before the plan; the measured climbs used
  `cluster-upgrade`. **Use `task cluster-upgrade` for a 0.1.0 fleet:** a plain `cluster-up` across a Talos minor and a
  Kubernetes minor stops before the plan (the running Talos 1.13 cannot host Kubernetes 1.37, #278), and `cluster-upgrade`
  walks the pair one minor at a time, with each axis pinned where it runs (#279). It asks nothing (its applies run with
  `APPROVE=auto`) and writes each pin it lands into the tfvars; `task cluster-upgrade PROVIDER=<p> DRY_RUN=1` works out
  the walk on a copy of them and stops. A plain `cluster-up` has rolled one worker, v1.14.1 to v1.14.2, on two clouds
  (2026-10-05). Set both explicitly to stay where you are; a downgrade is refused. A tfvars copied from an example that
  hard-pinned v1.13.3 and v1.35.3 keeps that pair, which no recorded cloud run used (Changed).
- **After pulling, run `tofu init -backend=false -upgrade` in `infrastructure/opentofu/cluster` (or `task validate`,
  which shares the lock).** The Talos provider is pinned at 0.12.0 and the lock file is local and gitignored, so every
  `infra-*` task stops at init on a stale 0.11 lock. `-upgrade` moves every provider within its constraint: read the
  next plan. To move only talos, delete its block from `.terraform.lock.hcl` and run a plain `tofu init`. A cluster
  built under 0.11 planned empty under the pin (Scaleway, 1 control plane + 1 worker; and, after the climb of
  2026-10-06, the three clusters the 0.1.0 tag built, 3 control planes + 2 workers).
- **Three control planes in one failure domain now end red:** OVH built on `nova` (read from the config, never seen on a
  live cluster; the verifier's red line names the knob that clears it for a new cluster, and what changing it does to
  nodes already built is not measured), an Outscale cluster built before the subregion spread (Changed: its layout is
  kept, no setting clears it), Proxmox on one host. `cluster-up` ends at its verify, so `cluster-up`,
  `cluster-idempotency` and `cluster-upgrade` end non-zero there. A state older than the `control_plane_zones` output
  reads UNCHECKED, which is fatal, until one apply.
- **`git_ref` now defaults to `refs/tags/0.1.0`, not `refs/heads/main`.** It only matters with `deploy_flux = true`: a
  tfvars that omits it re-points Flux's source from the branch to the tag at the next apply, and a tfvars copied from
  0.1.0's example keeps whatever it names. Say `git_ref = "refs/heads/main"` to stay on the branch. Nothing of this
  release has followed either ref on a cluster.
- **A lowered count is refused**; use `task cluster-shrink-plan` then `task cluster-shrink`. Do not route a node size
  change through `cluster-roll`: it is an in-place update of every node at once, and `docs/upgrade.md` has the one-node
  procedure. The new Scaleway examples' `instance_type` is a size change on a running cluster.
- **`admin_ip` and `flux_namespace` are validated:** an empty list, an entry with no prefix and any `/0` now fail the
  plan, and so does a `flux_namespace` other than `flux-system` (inert unless `deploy_flux`, validated all the same).
  Changing `admin_ip` on a bootstrapped cluster needs `OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true`
  (`docs/admin-access.md`).
- **OVH's default `availability_zones` moved from `nova` to the three EU-WEST-PAR zones.** A tfvars that leaves it unset
  changes zone; whether that replaces a node or a volume was not run, so pin what the cluster was built with and read the
  plan for replacements. A tfvars copied from 0.1.0's example names `["nova"]` itself: the default does not touch it, and
  the verifier is expected to end red on it (read from the config, never seen on a live OVH cluster; the failure-domain
  note above).
- **Scaleway clusters built under 0.1.0:** the private network keeps the subnet it has (`ignore_changes`), the pin only
  decides a new one, and the node security rules follow the subnet in use. Measured on a 0.1.0 cluster (2026-10-06): the
  first step plans `7 to add, 8 to change, 7 to destroy` (seven replacements: the five Talos configuration applies,
  `terraform_data.backup` and the local talosconfig; the in-place updates include the three node security groups; no
  network, subnet, private NIC or node). Without it the same climb replaced the network and every private NIC. Read the
  plan and stop at any network or node replacement all the same.
- **The bastion carries the Talos tunnels, and a change to it stops them mid-apply.** OVH: the bastion's default
  cloud-init renders 0.1.0's bytes, so it is not replaced. Outscale: the cloud-init now renders the Net CIDR (#58), so the
  first apply of the upgrade MODIFIES the bastion in place, the VM restarts (32 s), the tunnels die and the run stops with
  `connection refused` on the tunnel ports: **re-run the same command**, the tunnels are rebuilt at its start and it
  converges (one resume on Outscale, 2026-10-06). `explain-failure` now says the change landed (mocked only: that run
  predates the message). Nothing yet refuses or splits a plan that changes the bastion under live tunnels (#288).
- **An Outscale cluster built under 0.1.0 ends `cluster-verify` red, for good:** its three control planes are in one
  subregion, a node's zone is fixed when it is created, and the verdict is `13 passed, 1 failed` (the failure domain).
  `cluster-up` and `cluster-upgrade` then end non-zero although the versions converged.
- **The image lane:** the first build of the version the old `talos-image.tfstate` holds copies it to its own key and
  renames the old object, never deleted. A legacy state with a deposed or tainted object, or objects naming two
  versions, refuses the build of the version it holds (the image README names the way out). On Outscale the same-name
  gate runs on `--ensure` only: a plain `task image-build` still reaches the provider's 409 after the 8 to 14 minute
  import, and only the account's owner can delete the untracked OMI that caused it, which the script never does.
  `cluster-up` now ends by asking tofu's own yes for each image below the cluster's version and the one under it
  (skipped under `APPROVE=auto`; Changed).
- **Teardown:** the plan step of `task cluster-down` replicates the state before it untracks the Talos secrets, and a
  state without them is refused until restored (#66).
- **The Docker lane's default pin moves from v1.13.3 / v1.35.3 to v1.14.2 / v1.37.1, and `task local-up` did not start at
  it on the two kernel 6.12 hosts tried (#291, open; Known limits).** It booted at it on a hosted runner (Cléa's weekly
  lane, 1 control plane + 1 worker, 2026-10-11). Rung: local Docker; the default 3 control planes + 3 workers has no
  recorded boot at this pin.
- **Smaller:** `task cluster-up VERSION=` is not an argument; `cluster-*` tasks refuse `PROVIDER=local`; `cluster-up`
  refuses a never-applied `prod` cluster whose replica shares the primary's cloud, and fails when its verifier does.

---

## [0.1.0] — 2026-08-20

> **This tag does not point at the commit first cut as 0.1.0.** That one,
> `421c1ee`, carried a real admin IP that had been serving as a test fixture in
> `check-gitleaks-rules.sh` since 2026-08-13 — found by reading the published tag
> as a stranger, which is what §9 of the release checklist is for. History was
> rewritten and the tag re-cut, twice: once on the purged history, once more to
> take in this record of it. No release was ever published under the first tag
> and nothing depended on it. GitHub still serves the old blob by direct SHA and
> the diff of the pull request that introduced it; only GitHub Support can remove
> those, and anyone who cloned before the rewrite keeps it.

**One Talos cluster, on one supported cloud, with one fixed foundation: Cilium.**
Infrastructure only — nothing above that layer. Start at
[`docs/first-cluster.md`](docs/first-cluster.md).

### Added

- **Every task is `<noun>-<verb>`**: `cluster-up`, `infra-plan`, `infra-apply`,
  `tunnels-up`, `cluster-verify`, `cluster-upgrade`, `cluster-idempotency`,
  `cluster-roll`, `infra-down`, `cluster-down`. Upgrades:
  [`docs/upgrade.md`](docs/upgrade.md). Day-1 access:
  [`docs/admin-access.md`](docs/admin-access.md).
- **An approval you cannot lose by accident.** `APPROVE=auto|ask` names *who*
  answers the question, never whether one is asked: every apply plans to a file
  and applies that file, and `tofu apply <saved plan>` does not prompt.
  `-auto-approve` is gone from the cloud path, CI included. Destroy always takes
  two commands and no flag collapses them.
- **State and artifacts encrypted client-side in S3**, with an optional replica
  on a second cloud. S3 credentials are namespaced by the cloud that *holds the
  bucket*, not by the cluster. Proven across providers: an encrypted tfstate at
  Outscale while the cluster ran on Scaleway.

### Validated

Measured on real accounts: Scaleway and OVH on 2026-08-19, Outscale on
2026-08-20. Versions were read back from the kubelets and from each node's own
Talos API, never from the tool that performed the upgrade.

- **Scaleway, from an empty account**: deploy in 8 min 50 for 72 resources,
  `cluster-verify` 11/11, idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos
  v1.13.7 → v1.13.8 confirmed by Talos itself on 6/6 nodes (`stage=running`,
  fallback dropped).
- **OVH**: the same five pillars — deploy, verify, idempotency, and both
  upgrades — the same versions, 11/11, idempotency 3/3.
- **Outscale**: the same five pillars again, measured the same way — deploy (51
  resources, then 17), `cluster-verify` 11/11, idempotency 3/3, the same two
  upgrades on 6/6 nodes. It had to go onto a **fresh Net**: see the known limits.
- **Idempotency is a property of the command.** Run `task cluster-up` once or a
  hundred times and you land in the state you asked for; the evidence is the
  command's own plan, which prints `No changes.` on a cluster that already
  matches. `task cluster-idempotency` adds the two assertions OpenTofu cannot
  make — the *same* nodes (name and `creationTimestamp`), and a kubeconfig that
  still reaches the apiserver — because an empty plan alone would not catch a
  node replaced underneath it.
- **A second Scaleway cycle on 2026-08-20**: `cluster-up`, `cluster-up`,
  `cluster-upgrade`, `cluster-up`, all four green, both re-runs applying nothing
  on all three roots. **Idempotency after an upgrade had never been checked**; it
  holds because `cluster-upgrade` writes the new pin back into the tfvars. Talos
  v1.13.8 → v1.13.9 on 6/6 nodes, and `cluster-verify` compared the running
  *schematic*, not just the version tag.
- **An upgrade is not seamless.** Longest apiserver outage 5 s on Scaleway (16
  failed probes out of 575), 7 s on OVH (9-10 out of ~540) and 8 s on Outscale.
  All three are *worse* than the best figures this project ever recorded (3 s,
  1 s and 1 s), and why has not been established. Plan for a gap.
  A later Scaleway run measured **2 s**, with the roll taking the etcd leader
  last and handing leadership over first. **That does not establish the fix**:
  that run moved Talos alone, while the 5 s run also moved Kubernetes, which
  restarts an apiserver per control plane by itself. Two workloads, two numbers
  that do not compare — quote the 5/7/8 figures.
- **358 offline assertions across 11 harnesses**, every one mutation-tested
  (`task test-scripts`). The emulated lane runs feint 0.10.0 against Scaleway provider
  2.81.0 — the same version the clusters run.

### Fixed

- **The shared schematic shipped `siderolabs/qemu-guest-agent`, and that one
  extension cost every upgrade.** It never starts on OVH or Outscale, whose
  images carry no `hw_qemu_guest_agent` device: the boot sequence never
  completed, Stage never became Running, the META Upgrade key was never dropped,
  and the next reboot reverted the upgrade the tool had just reported as
  successful. Root cause, not a workaround.
- **A failed purge no longer exits 0 saying "purge complete".** The teardown for
  this release found six Outscale resources, was refused on all six, and the
  script still reported success — the refusals were printed but never counted, so
  the exit code every caller reads said the account was clean. All three
  `purge-orphans` scripts now count failed deletions and end on one of three
  verdicts, the third being *N of M failed, NOT clean*.

### Removed

- **The staging CI lane.** 479 lines that never deployed anything: the workflow's
  one recorded run died for want of secrets that were never set, and part of it
  verified a platform this release disables (35 Flux Kustomizations). A weekly
  red that measures nothing teaches you to ignore red. 0.1.0 ships **no CI lane
  that deploys** — the credentialed rung is run by hand, by someone watching. The
  code is on the `archive/staging-lane` branch.

### Changed

- **`talos-image`'s "staging" bucket is now the "import" bucket.** This repository
  already spends that word on environments (`environment = "dev"`), and reading
  it as one here is what it cost. The variable is `import_bucket`, the bucket is
  `…-talos-import`, and the default is no longer a literal name with the project
  and the provider baked into it — it is empty, and refused where it is named.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **No Flux and no applications.** `deploy_flux` defaults to `false`. Flux is
  disabled, not amputated — the Talos module already reads an empty manifest as
  "no Flux", so turning it on moves no resource address — and it returns as a
  user choice in a later release. Everything it reconciles lives in
  `OpenAether-apps`.
- **No CAPI and no multi-cluster.** A management cluster is an optional overlay
  on top of this, never the entry point.
- **Outscale needs a fresh Net, and leaves one behind.** A load balancer that
  never left `provisioning` was diagnosed by Outscale as an internal timeout in
  their LBU service — support request 399530, now closed, with the instruction
  not to create another load balancer in that Net. One Net created before the
  fix still refuses deletion on a dependency no read returns; only the provider
  can clear it, and a second request is open for that.
- **No state lock on Outscale.** Its object store accepts a conditional write
  (`If-None-Match`) that Scaleway's and OVH's refuse, so `use_lockfile` is
  enabled on those two and deliberately not there — a lock that announces itself
  and holds nothing is worse than none. Two concurrent runs against an Outscale
  cluster's state are not stopped by anything.
- **Scaleway, OVH and Outscale are the clouds that were measured.** Proxmox has
  never been applied on real hardware; the local Docker rung proves
  `modules/talos` without credentials and nothing about a cloud. Anything else is
  code, not a claim.
- **Two release-checklist lines were not met, and are not ticked.** The OVH
  teardown was run once where the checklist asks for twice — an Octavia load
  balancer orphaned by one teardown was once silently reused by the next deploy,
  and only a second teardown proves the check that now covers it. And the
  Outscale purge is not clean: the pre-fix Net above is still there and no
  deletion is accepted for it.
- **One image bucket is orphaned by this release's own rename.** The old
  `…-talos-staging` still holds every QCOW2 it was given, on every cloud built
  from. `purge-orphans` lists it; emptying it is by hand.
- **`ovh.py` cannot tell a refused question from an empty account.** Its two
  siblings count refused calls and exit 2 when they found nothing but asked
  nothing; it has no such counter. A total auth failure crashes it rather than
  reporting clean, so this is a gap and not the same defect — but a partial
  refusal would shrink its findings in silence.
