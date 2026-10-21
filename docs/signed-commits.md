# Signed commits and Flux Git source verification (infra side)

🇫🇷 [Version française](signed-commits.fr.md)

Git write access is the root of trust of the platform: Flux applies whatever the tracked ref contains, with cluster-admin.
No commit of the history before the signed-commit policy below verifies as signed. This page is the maintainers' standard and the opt-in switch for the
infrastructure repository; the apps repository has its twin page (`docs/signed-commits.md` there) and the matching
component. It addresses ANSSI SSDLC-CICD-AIP-03 and SSDLC-CONT-REC06; it is **not** a claim of compliance. Rung of
everything below: mocked/static (`tofu test`, a throwaway-key script test), never run on a cluster
(lab checklist B27).

## Stage 1 - the repository side (no cluster risk)

- **Standard: OpenPGP (GPG) signatures.** This repository standardises on OpenPGP, a choice and not a Flux limit: the
  vendored Flux also accepts SSH public keys in the signers Secret (keys suffixed `.sshpub`), which is NOT wired here (the
  `flux_git_verify` validation and the `git-signers` Secret take armored OpenPGP keys only). A commit signed with an SSH key
  would satisfy GitHub's ruleset but fail Flux's verification of this setup, so sign with GPG. Setup: `git config --global user.signingkey <fingerprint>`
  and `git config --global commit.gpgsign true`, then publish the public key on the GitHub account.
- **CI**: `scripts/dev/check-commit-signatures.sh` runs on every PR over the commits it adds (job `commits`). It is a
  **warning** until every maintainer signs; add `--strict` in `ci.yml` to make it fail. A runner without the keys sees a
  signed commit as "cannot be checked" and counts it as signed: the cryptographic verdict is GitHub's and Flux's.
- **Ruleset (owner action in GitHub settings)**: on `main`, require a pull request, status checks, signed commits, no
  force push, no bypass. `scripts/dev/check-required-checks.sh` already reports a missing `required_signatures` rule
  (a warning, a failure under `--strict-main`); export the ruleset into `.github/rulesets/main.json` in the same PR.
- **CODEOWNERS** names `.github/` and the bootstrap manifests; with one owner it enforces nothing until a second
  reviewer exists.

### Signer set and policy (decided 2026-10-21, issue #332)

Every commit on `main` is signed by a key of this table, or by GitHub's `web-flow` key. Merges are **squash merges done in the GitHub web
interface** (web-flow signs the squash commit, a rebase merge would keep the author's signature and a missing one fails); Renovate pull requests
are squash-merged the same way. Flux verification runs in **warning mode from 0.4.0** (see below) and **refuses** an unsigned or unknown commit
from 1.0.0.

| Signer | Fingerprint | Public key file | Role |
|---|---|---|---|
| VPS release key (Vincent Dislaire, ed25519, expires 2028-10-17) | `1D5895FDC14F5BAD6D1B170B5CA26229559044A2` | `docs/signers/release-vps.asc` | release tags and the commits of the release branches |
| GitHub `web-flow` (commit signing key) | `968479A1AFF927E37D1A566BB5690EEEBB952194` | `docs/signers/web-flow.asc` | squash and web merges. Taken from `https://github.com/web-flow.gpg` (which also lists an older key, expired 2024-01-16, not kept) |
| Maintainer's own key | **TO FILL: the owner gives the fingerprint (the previous key was deleted)** | a file `maintainer.asc` in `docs/signers/` once given | commits |

`docs/signers/signers.txt` holds the fingerprints in a machine-readable form (read by `scripts/dev/check-release-tag.sh`); the `.asc` files are the
public keys only (`gpg --armor --export <fingerprint>`), the ones to pass to `flux_git_verify.public_keys` with `file()`. Check a fingerprint
against this table before applying: tofu does not. Adding a signer is a reviewed commit that changes this table, `signers.txt` and the key file together.

### Flux verification in warning mode

Flux has **no warning mode**: with `spec.verify` set, a commit that fails verification makes the GitRepository NotReady and nothing new is applied (the last
good artifact stays); there is no "log and apply anyway" setting in the vendored source-controller. So the warning period of 0.4.0 is made of what this
repository does have: the `commits` CI job reports unsigned or badly signed commits as warnings (`check-commit-signatures.sh`, without `--strict`), the
ruleset on `main` requires signatures once the owner enables it (#333), and `flux_git_verify` stays `enabled = false` by default. To try the verification
itself before 1.0.0, enable it on a dev cluster only, with the three keys above, and read `SourceVerified`; the cost of a mistake there is a NotReady
source that the break-glass section below undoes. The gap (no real warning mode in Flux) is recorded on #332; `Refuse` is simply `enabled = true` in production at 1.0.0.

## Stage 2 - the cluster side (default off)

```hcl
flux_git_verify = {
  enabled     = true
  public_keys = [file("maintainer.asc"), file("web-flow.asc")]   # gpg --armor --export <id>; public keys only
}
```

With `enabled = false` (the default) the rendered bootstrap manifest is byte-identical to the one before the variable.
With `true`, the same Talos inline manifest carries, **before** the GitRepository, the Secret `git-signers`
(`signer-N.asc` per key), and the GitRepository carries `spec.verify {mode: HEAD, secretRef: git-signers}`.
Validation refuses an empty key list, anything that is not an armored public key block (a private key block included)
and a duplicate. Fingerprints are **not** checked by tofu: compare each key to the signer table before applying.

1. Enable it on dev first; the apps side must carry the same block (`components: [../components/git-verify]` in the
   cluster's overlay, apps repository), because the apps repository reapplies Flux's own GitRepository (gitception) and
   a block on one side only is added or removed at the first reconcile.
2. Mode is `HEAD`. `Tag` and `TagAndHEAD` wait until the release flow signs tags.
3. Watch `kubectl -n flux-system get gitrepository openaether -o yaml` (condition `SourceVerified`). A rejected commit
   makes the object NotReady and Flux keeps the last good artifact. Alerting on that is the apps side
   (`FluxObjectNotReady`, 20 minutes).
4. Changing `public_keys` on a running cluster changes the bootstrap manifest: whether Talos re-applies an inline
   manifest on a config apply is a lab question; the Secret can also be updated with `kubectl apply`.

Roll out on a dev cluster for several release cycles before production.

## Break-glass

If a legitimate commit is rejected (lost key, unsigned bot commit), through the bastion with `kubectl`, no shell on the
nodes: suspend the root Kustomization that applies the apps `gitrepository.yaml`, then

```
kubectl -n flux-system patch gitrepository openaether --type merge -p '{"spec":{"verify":null}}'
flux reconcile source git openaether -n flux-system
```

fix the signer set, restore the block (re-enable the component and the variable) and reconcile. While `verify` is off
the cluster trusts every commit of the ref: do it once, short, and note it. `refs/tags/...` pins remain a mitigation.

## Not done here

No ruleset change, no tag verification by Flux (release tags are checked by `scripts/dev/check-release-tag.sh`, see docs/release-checklist.md), nothing run on a cluster, and no check that the vendored
source-controller accepts the block.
