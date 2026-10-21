# Commits signés et vérification de la source Git par Flux (côté infra)

🇬🇧 [English version](signed-commits.md)

L'accès en écriture à Git est la racine de confiance de la plateforme : Flux applique ce que contient la ref suivie, avec
cluster-admin. Aucun commit de l'historique antérieur à la politique de commits signés ci-dessous ne vérifie comme signé. Cette page est le standard des
mainteneurs et l'interrupteur optionnel pour le dépôt d'infrastructure ; le dépôt apps a sa page jumelle
(`docs/signed-commits.md` là-bas) et le composant correspondant. Elle traite ANSSI SSDLC-CICD-AIP-03 et
SSDLC-CONT-REC06 ; ce n'est **pas** une déclaration de conformité. Niveau de preuve : simulé/statique (`tofu test`, test
de script avec clé jetable), jamais exécuté sur un cluster (checklist de labo B27).

## Étape 1 - côté dépôt (sans risque pour le cluster)

- **Standard : signatures OpenPGP (GPG).** Ce dépôt standardise sur OpenPGP, un choix et non une limite de Flux : le Flux
  embarqué accepte aussi des clés publiques SSH dans le Secret des signataires (clés suffixées `.sshpub`), ce qui n'est PAS
  câblé ici (la validation de `flux_git_verify` et le Secret `git-signers` ne prennent que des clés OpenPGP armorées). Un
  commit signé par une clé SSH satisferait le ruleset GitHub mais échouerait à la vérification de Flux dans ce montage :
  signer avec GPG. Configuration : `git config --global user.signingkey
  <empreinte>` et `git config --global commit.gpgsign true`, puis publier la clé publique sur le compte GitHub.
- **CI** : `scripts/dev/check-commit-signatures.sh` s'exécute sur chaque PR, sur les commits ajoutés (job `commits`). C'est
  un **avertissement** tant que tous les mainteneurs ne signent pas ; ajouter `--strict` dans `ci.yml` pour échouer. Un
  runner sans les clés voit une signature « invérifiable » et la compte comme signée : le verdict cryptographique est
  celui de GitHub et de Flux.
- **Ruleset (action du propriétaire dans les réglages GitHub)** : sur `main`, PR obligatoire, checks obligatoires,
  commits signés, pas de force push, pas de contournement. `scripts/dev/check-required-checks.sh` signale déjà
  l'absence de règle `required_signatures` (avertissement, échec avec `--strict-main`) ; exporter le ruleset dans
  `.github/rulesets/main.json` dans la même PR.
- **CODEOWNERS** nomme `.github/` et les manifestes de bootstrap ; avec un seul propriétaire, cela n'impose rien tant
  qu'il n'y a pas de second relecteur.

### Signataires et politique (décidé le 2026-10-21, issue #332)

Tout commit de `main` est signé par une clé de ce tableau, ou par la clé `web-flow` de GitHub. Les merges sont des **squash merges faits dans
l'interface web GitHub** (web-flow signe le commit de squash ; un rebase garde la signature de l'auteur, et son absence échoue) ; les PR Renovate
sont squashées de la même façon. La vérification Flux tourne en **mode avertissement dès la 0.4.0** (voir plus bas) et **refuse** un commit non
signé ou inconnu à partir de la 1.0.0.

| Signataire | Empreinte | Fichier de clé publique | Rôle |
|---|---|---|---|
| Clé de release du VPS (Vincent Dislaire, ed25519, expire le 2028-10-17) | `1D5895FDC14F5BAD6D1B170B5CA26229559044A2` | `docs/signers/release-vps.asc` | tags de release et commits des branches de release |
| GitHub `web-flow` (clé de signature des commits) | `968479A1AFF927E37D1A566BB5690EEEBB952194` | `docs/signers/web-flow.asc` | squash et merges web. Prise sur `https://github.com/web-flow.gpg` (qui liste aussi une ancienne clé, expirée le 2024-01-16, non gardée) |
| Clé propre du mainteneur | **À REMPLIR : le propriétaire donne l'empreinte (l'ancienne clé a été supprimée)** | `docs/signers/maintainer.asc` une fois donnée | commits |

`docs/signers/signers.txt` contient les empreintes sous forme lisible par machine (lu par `scripts/dev/check-release-tag.sh`) ; les fichiers `.asc`
sont les clés publiques seules (`gpg --armor --export <empreinte>`), à passer à `flux_git_verify.public_keys` avec `file()`. Comparer une empreinte
à ce tableau avant d'appliquer : tofu ne le fait pas. Ajouter un signataire est un commit relu qui change ensemble ce tableau, `signers.txt` et le fichier de clé.

### Vérification Flux en mode avertissement

Flux n'a **pas de mode avertissement** : avec `spec.verify`, un commit qui échoue la vérification rend le GitRepository NotReady et rien de neuf n'est
appliqué (le dernier artefact sain reste) ; le source-controller vendu n'a pas de réglage « journaliser et appliquer quand même ». La période
d'avertissement de la 0.4.0 se compose donc de ce que le dépôt a : le job CI `commits` signale les commits non signés ou mal signés
(`check-commit-signatures.sh`, sans `--strict`), le ruleset de `main` exige les signatures une fois activé par le propriétaire (#333), et
`flux_git_verify` reste `enabled = false` par défaut. Pour essayer la vérification elle-même avant la 1.0.0, l'activer sur un cluster de dev seulement,
avec les trois clés, et lire `SourceVerified` ; une erreur coûte une source NotReady que la section « Bris de glace » défait. Le manque (pas de vrai mode
avertissement dans Flux) est consigné sur #332 ; « refuser » est simplement `enabled = true` en production à la 1.0.0.

## Étape 2 - côté cluster (désactivé par défaut)

```hcl
flux_git_verify = {
  enabled     = true
  public_keys = [file("maintainer.asc"), file("web-flow.asc")]   # gpg --armor --export <id> ; clés publiques seulement
}
```

Avec `enabled = false` (défaut), le manifeste de bootstrap rendu est identique octet pour octet à celui d'avant la
variable. Avec `true`, le même manifeste inline Talos porte, **avant** le GitRepository, le Secret `git-signers`
(`signer-N.asc` par clé), et le GitRepository porte `spec.verify {mode: HEAD, secretRef: git-signers}`. La validation
refuse une liste vide, tout ce qui n'est pas un bloc de clé publique armoré (clé privée incluse) et un doublon. Les
empreintes ne sont **pas** vérifiées par tofu : comparer chaque clé au tableau des signataires avant d'appliquer.

1. Activer d'abord sur dev ; le côté apps doit porter le même bloc (`components: [../components/git-verify]` dans
   l'overlay du cluster, dépôt apps), car le dépôt apps réapplique le GitRepository de Flux (gitception) et un bloc d'un
   seul côté est ajouté ou retiré au premier rapprochement.
2. Le mode est `HEAD`. `Tag` et `TagAndHEAD` attendent que la chaîne de release signe les tags.
3. Surveiller `kubectl -n flux-system get gitrepository openaether -o yaml` (condition `SourceVerified`). Un commit refusé
   met l'objet NotReady et Flux garde le dernier artefact valide. L'alerte est côté apps (`FluxObjectNotReady`, 20 minutes).
4. Changer `public_keys` sur un cluster en marche change le manifeste de bootstrap : savoir si Talos réapplique un
   manifeste inline lors d'un apply de config est une question de labo ; le Secret peut aussi être mis à jour avec
   `kubectl apply`.

Déployer sur un cluster dev pendant plusieurs cycles de release avant la production.

## Bris de glace

Si un commit légitime est refusé (clé perdue, commit de bot non signé), via le bastion avec `kubectl`, sans shell sur les
nœuds : suspendre la Kustomization racine qui applique le `gitrepository.yaml` apps, puis

```
kubectl -n flux-system patch gitrepository openaether --type merge -p '{"spec":{"verify":null}}'
flux reconcile source git openaether -n flux-system
```

corriger l'ensemble de signataires, restaurer le bloc (réactiver le composant et la variable) et rapprocher. Tant que
`verify` est retiré, le cluster fait confiance à tout commit de la ref : à faire une fois, brièvement, et à consigner.
Épingler `refs/tags/...` reste une atténuation.

## Non fait ici

Aucun changement de ruleset, aucune clé publiée, pas de vérification de tag par Flux (les tags de release sont vérifiés par `scripts/dev/check-release-tag.sh`, voir docs/release-checklist.md), rien d'exécuté sur un cluster, et aucune
vérification que le source-controller vendu accepte le bloc.
