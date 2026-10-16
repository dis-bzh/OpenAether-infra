# Modèle de menaces de la chaîne de livraison — GitHub, Actions, Renovate, Flux, le bastion et l'état

🇬🇧 [English version](threat-model.md)

> Écrit pour répondre aux règles ANSSI sur l'appréciation des risques de la chaîne CI/CD et de livraison (id d'audit SCC/F11, la partie modèle de menaces). C'est une **liste raisonnée de ce qui pourrait mal tourner entre un commit et un nœud en marche,
> de ce qui s'y oppose aujourd'hui et de ce qui ne s'y oppose pas**. Ce n'est pas un test d'intrusion, et les contrôles qu'il nomme sont ceux présents dans le dépôt
> (lus, pas attaqués). Les menaces d'exécution sur le cluster lui-même sont dans `security-architecture.fr.md` et `network.fr.md` ; les pins et leurs verrous dans `supply-chain.fr.md` ; le délai de correctifs dans `patching.fr.md`.
> Il ne revendique aucune conformité à un document ANSSI.

## 1. La chaîne, et où la confiance est placée

```text
 maintainer ──push/PR──> GitHub (infra, apps) ──Actions──> checks, SBOM, releases
      │                       │  ^
      │                       │  └── Renovate App, Cléa (PRs, never merged by them)
      │                       └────── tags: refs/tags/<version> of apps, pinned in git_ref
      v
 operator workstation ──tofu apply / task──> provider APIs, state bucket, bastion ──tunnels──> nodes
                                                                             Flux in the cluster <── pulls apps at git_ref (public repository)
```

Confiance placée, par ordre d'importance : le compte GitHub du mainteneur et la machine qui détient `.env.sh` (tout est atteignable depuis eux) ; le dépôt OpenAether-apps au
tag de `git_ref` (Flux l'applique avec des droits sur tout le cluster) ; les releases amont des providers OpenTofu, images Talos, charts Helm et images de conteneurs ; GitHub Actions et les actions épinglées dans les workflows ; les plans de contrôle des providers.

## 2. Actifs et frontières

Les comptes cloud et les stores objet ; l'état (il contient la PKI Talos) ; le dépôt apps (il définit ce qui tourne) ; les tags de release (ils définissent ce qu'un cluster suit) ; les
secrets de l'environnement `sandbox` ; le poste de l'opérateur. Frontières : GitHub (dépôt public, n'importe qui peut ouvrir une PR), les runners Actions (hébergés, éphémères), le poste du mainteneur, les comptes cloud, le cluster.

## 3. Menaces, contrôles, risque résiduel

| # | Composant | Menace | Contrôles dans le dépôt | Risque résiduel |
|---|---|---|---|---|
| T1 | Compte GitHub du mainteneur | Prise de contrôle : push sur main, déplacer ou publier un tag, changer un ruleset | Rulesets en code (`.github/rulesets/main.json` : PR obligatoire, pas de force-push, historique linéaire, contrôles de statut obligatoires ; `tags.json` : pas de suppression, de mise à jour ni de non-fast-forward des tags) ; `repo-settings.yml` les compare chaque jour aux réglages réels ; **zéro approbation exigée** tant qu'il y a un seul mainteneur ; un contournement admin existe sur main (signalé comme avertissement) | Un seul compte est tout le contrôle : une prise de contrôle fusionne et publie. Le MFA résistant à l'hameçonnage du compte relève du propriétaire, non vérifié ici. Un second mainteneur, des commits signés obligatoires et un nombre d'approbations changeraient cela |
| T2 | Une pull request d'un fork ou d'une branche empilée | Exécuter du code hostile en CI avec un jeton ; voler des secrets | Aucun workflow exécuté sur une pull request ne touche un cloud ni un secret (0.1.0 a supprimé la voie à identifiants ; `real-cloud-regression.yml` est manuel et dans l'environnement `sandbox`) ; `permissions: contents: read` par défaut ; actions épinglées par SHA de commit ; le job `Pipeline audit` lit les fichiers de workflow pour des actions non épinglées, des déclencheurs dangereux (`pull_request_target`), des permissions larges et des jobs de sécurité affaiblis ; `actionlint` | L'audit de chaîne est un contrôle de motifs, pas une preuve ; le jeton d'une exécution sur pull request est réel, contre un dépôt public |
| T3 | L'environnement `sandbox` (workflow cloud manuel) | Secrets utilisés sur une branche non relue | Relecteurs obligatoires et limite de branche sur l'environnement, créé à la main (`repo-settings.yml` signale son absence) ; dormant : le calendrier est commenté | L'environnement est créé par le propriétaire : un absent n'est qu'un avertissement tant que le workflow reste dormant. Les clés sont de longue durée (pas de fédération OIDC), limitées à un projet sandbox ; la rotation à 90 jours est un objectif (`supply-chain.fr.md`) |
| T4 | Renovate et Cléa | Une release amont malveillante ou compromise est intégrée ; le jeton du bot est détourné | Jamais fusionnées automatiquement ; âge de release 7 jours ; chaque mise à jour est une PR qui passe les contrôles et le palier qu'elle exige ; le rapport quotidien de Cléa ajoute les avis OSV et le retard des pins ; `vulnerabilityAlerts` contournent l'âge pour les correctifs. `CLEA_WORKFLOW_TOKEN` (optionnel) est le seul jeton qui peut écrire des fichiers de workflow | Une attente de 7 jours ne défait que les releases retirées vite ; une compromission patiente passe. Cléa et Renovate ne voient que les pins avec une ancre. La relecture est celle du seul mainteneur |
| T5 | Providers OpenTofu, images Talos, charts, images de conteneurs | Un artefact compromis ou altéré atteint un nœud | Verrous de providers commités (`-lockfile=readonly`) ; verrou sha256 des images Talos (`warn` par défaut, `enforce` pour un build de release) ; `check-image-pins.sh` échoue sur une `image:` sans digest ; SBOM et Trivy sur les images de bootstrap ; registre OpenVEX | Aucune vérification de signature nulle part (cosign) : un digest dit « les mêmes octets qu'à l'épinglage », pas « construit par l'éditeur ». Ce que déploie `OpenAether-apps` est sa propre surface |
| T6 | Flux qui tire `OpenAether-apps` à `git_ref` | Un commit hostile ou un tag déplacé atteint un cluster en marche dans l'intervalle de réconciliation, appliqué avec des droits sur tout le cluster | Le défaut et les exemples épinglent un **tag** immuable (`refs/tags/<version>`), coupé avant le tag infra qui le désigne ; les tags du dépôt apps sont protégés par un ruleset de tags GitHub (posé dans GitHub, non gardé en code là-bas, donc non vérifié d'ici) ; un pin de branche est réservé au développement et le texte de la variable le dit | **Flux applique ce que dit le dépôt à cette ref, avec cluster-admin.** Ce dépôt ne configure aucune vérification de signature de commit ou de tag. Une prise de contrôle du dépôt apps, ou un cluster épinglé sur une branche, est une prise de contrôle du cluster |
| T7 | Le bastion | Compromission du seul hôte d'administration exposé à Internet : tunnels vers l'API de chaque nœud ; vol de clés d'opérateur en cours d'usage | sshd par clé seule, `AllowGroups`, `PermitOpen` vers 6443 et 50000, liste `admin_ip`, socle optionnel, opérateurs nominatifs, certificats, épinglage de clé d'hôte, sortie fermée ; les nœuds exigent toujours le mTLS | Le bastion ne détient ni état ni `talosconfig`, mais un bastion compromis peut capter le trafic transféré par SSH d'une session d'opérateur (TLS à l'intérieur) et attaquer les API des nœuds ; clé d'automatisation partagée |
| T8 | Les buckets d'état et d'artefacts | Vol de l'état (= la PKI Talos), suppression de sauvegardes, altération | Chiffrement côté client (K5, K6) avant envoi, un réplica chez un second provider, des générations datées | Ni verrou d'objet ni versionnement ; clés S3 valables pour tout le compte par défaut ; un attaquant avec les clés supprime (`backup-policy.fr.md`) |
| T9 | Le poste de l'opérateur et `.env.sh` | Une prise de contrôle donne toutes les clés d'un coup | `.env.sh` est ignoré par git et un avertissement de mode existe ; un coffre est recommandé ; les clés matérielles sont optionnelles | La plus grande concentration de secrets ; elle échappe au contrôle de ce dépôt |
| T10 | Un changement malveillant d'un script ou module Terraform, relu mais subtilement nuisible | Un apply destructeur, une fuite | `prevent_destroy` sur les secrets Talos ; détruire demande deux commandes ; refuse-node-deletes ; plan avant apply ; les contrôles de langue, de secrets, de références mortes et de pins d'outils ; la voie cloud émulé | Relecture par une seule personne ; les contrôles attrapent des classes d'erreurs, pas l'intention |
| T11 | La documentation comme chemin d'attaque | Une commande copiée-collée qui fait du mal | Les commandes des docs sont contrôlées pour les chemins morts (`check-dead-references.sh`) et exécutées dans des harnais quand c'est possible | Une commande n'est pas testée parce qu'elle est documentée : les docs disent quel palier chacune a atteint |

## 4. Ce que ce modèle laisse de côté

Les menaces d'exécution dans le cluster (compromission d'une charge de travail, chaîne d'approvisionnement des images apps) relèvent du dépôt apps ; le déni de service des providers ; l'accès physique ; les menaces internes au-delà de « le mainteneur est l'unique opérateur » ;
les mesures juridiques et organisationnelles. Un second mainteneur change surtout T1, T6, T9 et T10.

## 5. Revue

Relire à chaque nouveau workflow, jeton, secret, environnement ou changement de ruleset ; quand un second mainteneur arrive ; après tout incident qui a touché la chaîne ; et au moins une fois par an avec le registre d'audit (`audit-register.fr.md`). Les contrôles nommés ci-dessus (`repo-settings.yml`, `Pipeline audit`, le lint) sont la part qui tourne seule.
