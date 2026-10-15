# Chaîne d'approvisionnement — ce qui est verrouillé, ce qui est vérifié, ce qui est seulement inventorié

🇬🇧 [English version](supply-chain.md)

> Ce qui sépare une version amont hostile ou cassée d'un nœud de cette plateforme, et ce
> qui ne le fait pas. Répond en partie à ANSSI SSDLC CICD-AIP-01c/-03, PROV-REC03,
> CICD-IAM-03/-05, CIO-REC03, SCM-REC06/-07 et SBOM25-1/-2/-3. Contrôles statiques et
> mockés seulement : rien de tout cela n'a tourné contre un cloud.

## Binaires des providers

`infrastructure/opentofu/cluster/.terraform.lock.hcl` et `.../talos-image/.terraform.lock.hcl`
sont versionnés, avec les empreintes linux et macOS en amd64 et arm64. `task validate`,
`task test` et la CI lancent `tofu init -lockfile=readonly` : une contrainte changée sans
rafraîchir le lock échoue là au lieu de résoudre un binaire que personne n'a relu. Les
contraintes des deux racines sont en `~>` (mineure pour les providers en 1.x ou plus, patch
pour ceux en 0.x) ; les modules gardent leurs minimums `>=`.

- Le manager terraform de **Renovate** met le lock à jour lors d'un changement de provider
  (son code le fait, et `registryUrls` le dirige vers registry.opentofu.org, d'où viennent
  les entrées du lock) ; pas encore vu sur ce dépôt.
- **À la main :** `task lock-providers` (réseau, environ 1 Go de `TMPDIR`, aucun identifiant).
- Les locks contiennent les versions qu'un `tofu init` neuf a résolues le 2026-10-13. Aucun
  fichier ne dit sur quelles versions de providers les clusters validés ont tourné : le
  premier `tofu plan` après ce changement ne doit rien montrer, et un écart est ce qu'il faut lire.
- `opentofu-local/` et `opentofu-feint/` (voies de labo) et `modules/talos` (testé seul)
  gardent l'ancien lock local non versionné.

## Images de démarrage Talos

L'identifiant de schematic de l'Image Factory fixe ce qu'on demande, pas les octets reçus.
`infrastructure/opentofu/talos-image/images.lock` enregistre le sha256 de chaque image brute
`<schematic>/<version>/<plateforme>-<arch>` (Scaleway, OVH, Outscale, Proxmox, amd64 et arm64
de la version épinglée par le cluster). `scripts/internal/verify-image-checksum.sh` s'exécute
entre le téléchargement et la conversion dans les trois modules local-exec.

| `image_checksum_mode` | écart, ou aucune empreinte enregistrée |
|---|---|
| `warn` (défaut) | affiché, la construction continue : ce qui se passait avant |
| `enforce` | la construction s'arrête (`TF_VAR_image_checksum_mode=enforce`, pour une construction de release) |
| `off` | non regardé |

- Une nouvelle version de Talos n'a pas encore de ligne : `scripts/bootstrap/talos-image-lock.sh --arch amd64,arm64`
  télécharge chaque fichier (environ 230 Mo, huit au total, environ 1 Go) et l'enregistre ; `--check` retélécharge et compare.
  Rien ne le lance à votre place : une montée Renovate de la version Talos épinglée met `test-image-checksum.sh`
  et le test images-lock au rouge tant que ses lignes ne sont pas commitées (le corps de la PR le dit). C'est la barrière qui
  fonctionne, pas un test instable.
- Si `enforce` fait échouer une construction de release sur un fichier dont rien ne montre qu'il a changé en amont, lancer
  d'abord `--check` : un artefact régénéré est un écart à lire, et `warn` ramène au comportement d'avant.
- Le même fichier est revenu identique octet pour octet sur deux téléchargements espacés d'une
  heure. Que la Factory serve les mêmes octets pendant des mois n'est **pas connu** : c'est
  pourquoi le défaut est `warn`.
- Proxmox télécharge côté serveur : seul `enforce` y fait quelque chose (l'argument `checksum`
  du provider). Que Proxmox prenne cette empreinte avant ou après avoir décompressé le `.zst`
  est **non vérifié** : à essayer d'abord sur un hôte. Dans le provider bpg (0.116), `checksum`
  force le remplacement : activer `enforce` dans une racine qui détient déjà le fichier planifie sa
  destruction et un nouveau téléchargement, donc lire ce plan, ou l'activer dans une racine neuve. La
  ressource `proxmox_virtual_environment_download_file` est aussi dépréciée dans cette version
  (retirée en 1.0) ; elle n'est pas remplacée ici.
- La référence de l'installeur dans la machine config (`factory.talos.dev/installer/<schematic>:<version>`)
  reste un tag, pas un digest.

## Images, outils et inventaire

- `task lint` échoue sur une `image:` d'un manifeste suivi sans `@sha256` ni digest enregistré
  dans `flux-image-digests.lock` (`check-image-pins.sh`). `image-digests.yml` re-résout les
  tags Flux chaque semaine.
- **SBOM :** `scripts/dev/gen-sbom.py` écrit un inventaire CycloneDX 1.5 des outils épinglés
  (ancres `# renovate:`), des providers verrouillés, des images de bootstrap et des images
  Factory. Le workflow `SBOM` le lance chaque semaine et à chaque release publiée, le joint
  sous le nom `openaether-infra-<tag>.cdx.json`, et scanne chaque image de bootstrap avec Trivy
  (un CRITICAL avec correctif amont échoue).
- **VEX :** un constat qui ne s'applique pas est consigné comme déclaration OpenVEX dans
  `.vex/openaether-infra.openvex.json` (une purl par produit, `not_affected` avec une
  justification) ; le scan lit le fichier dès qu'il porte une déclaration.
- **Non couvert :** ce que déploie `OpenAether-apps` (charts, autres images), les couches à
  l'intérieur des images (l'inventaire lit des références, Trivy lit les couches), et les
  signatures (aucune vérification cosign nulle part pour l'instant).

## Qui peut lancer le workflow cloud, et ce que sont les clés

`real-cloud-regression.yml` s'exécute dans l'environnement GitHub **`sandbox`**. À créer une
fois (Settings, Environments) : relecteurs obligatoires, branches de déploiement limitées à
`main`, et **y déplacer les secrets des providers** depuis les secrets du dépôt (les noms ne
changent pas). GitHub crée un environnement manquant sans protection : `repo-settings.yml`
signale donc celui qui n'en a pas (un absent n'est qu'un avertissement tant que le workflow
reste dormant).

| Identifiant | Où | Rotation (cible, non appliquée) |
|---|---|---|
| Clés API des comptes sandbox | secrets de l'environnement `sandbox` | 90 jours au plus, et après le départ de toute personne y ayant eu accès ; clés limitées au projet sandbox |
| `CI_BASTION_SSH_PRIVATE_KEY` | secret de l'environnement `sandbox` | avec les clés ci-dessus ; sa moitié publique dans le tfvars de CI |
| `TF_VAR_ENCRYPTION_PASSPHRASE` | secret de l'environnement `sandbox` | ne réutilise jamais une passphrase de production ; une rotation rechiffre l'état sandbox |
| `CLEA_WORKFLOW_TOKEN` | secret du dépôt, optionnel | un jeton fine-grained limité à ce dépôt (Contents et Workflows : write) expirant sous 90 jours, plutôt qu'un jeton classique à portée `workflow`. Non essayé ici : c'est le classique qui a tourné |

Ce dépôt n'a pas de fédération OIDC vers Scaleway, OVH ou Outscale : les clés restent de longue
durée, l'expiration courte et la portée sont les mesures compensatoires. Le versionnement et
les politiques des buckets d'état et d'artefacts ne sont pas traités ici.

## Réglages du dépôt en tant que code

`.github/rulesets/main.json` et `tags.json` sont les deux rulesets tels que GitHub les rend.
`check-required-checks.sh` (chaque jour et à chaque push sur main, `repo-settings.yml`) les
compare champ par champ aux rulesets vivants (les acteurs de contournement seulement si le jeton
peut les lire), vérifie que main exige une pull request et interdit force-push et suppression,
et signale en **avertissements** ce qu'un mainteneur seul ne peut pas encore satisfaire : 0
relecture approuvante, pas de commits signés exigés, et le contournement admin sur main.
`--strict-main` en fait des échecs. Pour changer un ruleset : le changer dans GitHub, le
ré-exporter dans le JSON dans la même PR.
