# Politique de sauvegarde — ce qui est copié, à quelle fréquence, combien de temps, qui peut l'ouvrir, et ce qui n'est pas copié

🇬🇧 [English version](backup-policy.md)

> Écrit pour répondre aux règles ANSSI sur la politique de sauvegarde, les tests de restauration et la destruction des supports (id d'audit F-BKP-07,
> avec GH-M37-8). C'est un seul tableau sur des mécanismes qui existent, pas un nouveau mécanisme. **Les chiffres de RPO et de RTO sont des objectifs
> proposés par le mainteneur, pas des mesures** : quand quelque chose a été mesuré, la date et le lieu sont donnés. Il ne revendique aucune
> conformité à un document ANSSI.

Deux couches conservent des données. La couche infrastructure (ce dépôt) copie l'état, les artefacts d'accès, les snapshots etcd et les journaux du bastion.
La couche applicative (`OpenAether-apps`, `apps/base/backup/README.md`, « Backup policy ») copie OpenBao, les bases de données et, à la demande, les volumes
Longhorn. Le tableau applicatif fait foi pour ses lignes ; elles sont répétées ici seulement pour que la politique se lise en un seul endroit, et l'ordre
de reprise est `disaster-recovery.fr.md`.

Termes : le **RPO** est la donnée que vous pouvez perdre (le pire écart entre deux copies) ; le **RTO** est le temps pour être de nouveau utilisable, depuis la décision de restaurer.
Le **primaire** est le store du provider propre au cluster ; le **réplica** est le store `-backup`, chez un autre provider en production.

## 1. Politique, par jeu de données

| Donnée | Mécanisme et fréquence | RPO / RTO visé | Rétention | Destination | Clé et détenteur | Test de restauration | Destruction |
|---|---|---|---|---|---|---|---|
| tfstate (contient la PKI Talos K1, K3, K4) | Écrit dans le primaire par chaque `tofu apply` (chiffré côté client) ; `backup-state.sh` le copie vers le réplica après chaque apply, avec une **génération** datée quand l'état contient des secrets Talos | RPO : depuis le dernier apply (l'état ne change qu'à l'apply) / RTO 2 h | l'objet courant, les `STATE_GENERATIONS` (5) dernières générations, et les copies `STATE_LABEL` (`pre-upgrade`) jamais élaguées | buckets primaire et réplica `s3-<project>-<provider>-tfstate-<env>[-backup]` | K5, détenue par l'opérateur ; les clés S3 K7 | Un basculement complet a été exécuté une fois, OVH vers Scaleway, 2026-10-05 (`status.md`) ; les recettes de génération sur deux vrais stores, 2026-10-06 (`cluster/README.md`) ; `test-restore-state.sh` hors ligne. Aucun test planifié | section 3 |
| `talosconfig`, `kubeconfig` | Chiffrés gpg et envoyés par `backup-artifacts.sh` pendant l'apply de la phase 2 et à chaque changement de l'un des fichiers | RPO : dernier changement / RTO 30 min | l'objet courant, écrasé | les deux stores, `s3-<project>-<provider>-<role>-<env>[-backup]` | K6 si posée, sinon K5 | `task restore-artifacts` identique à l'octet depuis le primaire et depuis un réplica chez un autre cloud (OVH et Scaleway, 2026-10-05), depuis les deux stores d'un cluster Outscale sur son propre endpoint (2026-10-03) | section 3 |
| Snapshot etcd (Secrets écrits par des Jobs, liaisons de PVC, tout ce qui ne vit que dans etcd) | `etcd-snapshot.sh`, à la main ou depuis le cron de l'opérateur (`etcd-snapshot-cron.sh`, exemple 03:40 UTC chaque jour) ; `cluster-upgrade` en prend un `pre-upgrade` | RPO : 24 h si le cron tourne, **rien ne le lance pour vous** / RTO 2 h | les `KEEP` (30) derniers par store ; les snapshots étiquetés jamais élagués | les deux stores, `backups/etcd/` | K6 si posée, sinon K5 (et le contenu est protégé par K3 à l'intérieur) | Restauré sur OVH pendant l'exercice de mise à jour (`upgrade.md` : membres etcd revenus 52 s après `bootstrap`, API 4,3 min après le rollback). Pas exercé comme reprise depuis un compte vide | section 3 |
| Journaux du bastion (journal, audit) | `bastion-logs-pull.sh` depuis le cron de l'opérateur, `OA_LOGS_UPLOAD=1` | RPO : l'intervalle entre deux extractions (quotidien proposé) ; les journaux sur la VM ne sont pas infalsifiables / n/a | aucune règle : conservés jusqu'à suppression | les deux stores, `backups/bastion-logs/` | `OA_LOGS_PASSPHRASE` | Relecture vérifiée seulement sur un export construit à la main (`admin-access.md`) | section 3 |
| OpenBao (raft : KV, intermédiaire PKI, politiques) | apps : CronJob `openbao-snapshot`, chaque jour 02:17 UTC, restic | 24 h / 4 h | 14 j, 8 s, 12 m | les 2 dépôts restic (`s3-primary`, `s3-replica` dans OpenBao) | mot de passe restic ET clé de scellement OpenBao, les deux en séquestre hors ligne | apps : `openbao-snapshot-restore-test` mensuel ; une restauration complète : manuelle, seulement des morceaux mesurés (README vault apps) | section 3, et README apps « Decommissioning a bucket » |
| Bases CNPG (zitadel, grafana) : dump | apps : CronJob `cnpg-dump`, chaque jour 02:47 UTC, restic | 24 h / 4 h | 14 j, 8 s, 12 m | les 2 dépôts restic | mot de passe restic | apps : `cnpg-dump-restore-test` mensuel (`pg_restore --list`) | idem |
| Bases CNPG : archive WAL | apps : `barmanObjectStore` CNPG et `ScheduledBackup` | minutes / 4 h | 30 j | le provider propre au cluster seulement (CNPG n'offre qu'une destination) | identifiants S3 ; **pas de chiffrement côté client** | aucun automatisé ; la procédure PITR du README apps **n'a pas été exécutée** | cycle de vie du bucket chez le provider |
| Volumes Longhorn | apps : groupe RecurringJob optionnel | par job / non fixé | par job | le `backupTarget` de l'environnement | passphrase LUKS | aucun | chez le provider |
| Ressources Kubernetes | aucun : Flux ré-applique le dépôt | n/a / le DAG qui converge (35 Kustomizations mesurées, environ 2 minutes après le seed sur Scaleway) | historique Git | Git | n/a | le DAG sur un cluster neuf, chaque labo | n/a |

Objectifs globaux proposés : **RPO 24 h, RTO une journée de travail (8 h)** pour une reprise complète par `disaster-recovery.fr.md`. Aucune reprise complète n'a été
chronométrée depuis un compte vide ; la somme des morceaux mesurés ci-dessus est plus basse, mais les morceaux ont été mesurés séparément.

## 2. Ce qui n'est pas sauvegardé, et pourquoi

| Donnée | Pourquoi |
|---|---|
| Métriques (VictoriaMetrics, local-path, 30 jours) | Télémétrie reproductible ; sa perte coûte de l'historique, pas du service |
| Journaux (chunks Loki) | Bucket propre `s3-<project>-<provider>-logs-<env>`, sans réplica, rétention d'un an chez Loki : un **stockage de journaux, pas une sauvegarde**. Sa propre paire de clés si vous en donnez une (section 4), versionné ou verrouillé avec `backup_immutability` |
| Volumes `local-path` et silences Alertmanager | Éphémères par décision ; la configuration d'Alertmanager vient de Git, les silences sont perdus |
| Volumes Longhorn hors du groupe de sauvegarde | Aucun composant de la plateforme n'utilise Longhorn aujourd'hui |
| Disques des nœuds et image Talos | Les nœuds se remplacent, ils ne se restaurent pas ; l'image est reconstruite depuis l'Image Factory (le verrou sha256 épingle ce qu'elle doit être) |
| Tout ce qui est dans un namespace que le DAG ne crée pas | Inconnu de ce dépôt |
| Les runners CI et le portable du mainteneur (`.env.sh`, tfvars, coffre de K5/K6) | Hors plateforme : **la perte de K5 et K6 n'est pas récupérable** et leur séquestre est celui de l'opérateur (`key-management.fr.md`) |

## 3. Destruction, expiration et mise hors service

**Il n'y a pas d'expiration automatique au-delà des nombres ci-dessus, sauf si `backup_immutability` est positionné.** Par défaut (`off`), aucun bucket n'a de versionnement, de règle de cycle de vie ni de verrou d'objet posé par ce dépôt : un
objet sorti du nombre de rétention est supprimé, mais une **version** de lui, si le bucket du provider est versionné, ne l'est pas ; et un attaquant qui détient K7 peut tout supprimer. Activer la protection est optionnel
et **non vérifié chez aucun provider** (support et coût diffèrent ; la liste de contrôle de labo du travail de durcissement dit quoi essayer) :

| `backup_immutability` | Ce que `ensure-buckets.sh` pose, puis relit | Ce que ça donne | Ce que ça ne donne pas |
|---|---|---|---|
| `off` (défaut) | rien | rien ne change sur un cluster déployé | une clé S3 volée supprime les copies |
| `versioned` | versionnement sur sept buckets ; une règle `oa-noncurrent-expiry` fait expirer les versions non courantes après `backup_retention_days` (60) | une suppression ou un prune restic par une clé du cluster laisse une version derrière elle | une clé autorisée à faire `DeleteObjectVersion`, `PutBucketVersioning` ou `PutLifecycleConfiguration` le défait : c'est la politique de clés de la section 4 |
| `governance` | comme `versioned`, et un verrou d'objet avec une rétention par défaut de `backup_retention_days` sur les cinq buckets qui portent des copies ou des journaux, créés avec | une clé ordinaire ne peut pas retirer une version avant la fin de la rétention | une clé autorisée au contournement le peut ; le bucket ne peut pas être vidé entre-temps |
| `compliance` | comme `governance` | personne ne peut retirer une version verrouillée avant la fin de la rétention, le propriétaire du compte compris | ça ne se défait pas non plus : le bucket ne peut être ni vidé ni supprimé d'ici là, et le coût des versions est dû |

- **Quels buckets.** Verrouillés (créés avec le verrou) : les sauvegardes applicatives et leur jumeau `-backup`, les réplicas d'état et d'artefacts, les journaux de Loki. Seulement versionnés : les primaires d'état et d'artefacts, qu'écrit tofu.
  La paire des sauvegardes applicatives, jusqu'ici créée à la main, est créée par le script dans tout mode sauf `off`. Le verrou d'objet doit en général être posé à la **création** du bucket : sur un bucket qui existe sans lui,
  l'appel est refusé, signalé, et le bucket n'est ni supprimé ni remplacé (en créer un nouveau, ou se contenter de `versioned` ; changer `bucket_suffix` les renomme tous).
- **Règle pour la rétention.** Loki supprime ses chunks à 365 jours (apps) et une suppression sous versionnement laisse un marqueur et une version pendant `backup_retention_days` de plus ; le prune restic fait de même pour les
  dépôts. Le stockage grossit d'environ le renouvellement de ce nombre de jours. Un journal ou une sauvegarde supprimés restent donc physiquement présents pendant la rétention : ça ne convient pas à une donnée qui doit disparaître sur-le-champ.
- **Une restauration depuis les versions n'est pas répétée.** Après un prune malveillant, le dépôt se récupère en restaurant les versions précédentes de ses objets, ce qui n'est pas une restauration restic et n'a pas été exécuté.

- **Expiration** : les générations et snapshots sont élagués par les scripts. Après un **changement de clé**, supprimer soi-même les anciens objets
  (`key-management.fr.md`, section 4) : l'ancienne passphrase ouvre tout ce qui a été écrit sous elle.
- **Remplacer un dépôt ou un bucket** (un mot de passe restic fuité, un provider quitté) : confirmer que l'autre copie se restaure, révoquer la clé d'accès chez le provider, supprimer **chaque version
  d'objet et marqueur de suppression**, supprimer le bucket, et vérifier chez le provider qu'il a disparu. Un snapshot qu'on ne sait plus lire n'est pas effacé ; seule la suppression de l'objet l'efface.
- **Mettre un cluster définitivement hors service** : `cluster-down` laisse exprès les buckets et l'image. Après la dernière restauration dont vous pourriez avoir besoin : vider (versions comprises) et supprimer les quatre
  buckets du cluster chez les deux providers et le bucket de journaux (un bucket verrouillé ne se vide pas avant la fin de sa rétention), supprimer l'image Talos et ses snapshots (`purge-orphans`, la rétention d'images), révoquer K7 et K8,
  détruire K5 et K6, et retirer les fichiers du cluster de la machine de l'opérateur et des secrets CI `sandbox`. Lister ce qui reste en interrogeant le provider, pas le fichier d'état.
- **Supports** : un disque, un portable ou une clé USB qui a contenu une clé s'efface en le détruisant ou en détruisant sa clé de volume, pas par `shred` (`key-management.fr.md`, section 4).

## 4. Qui peut ouvrir quel bucket

Une identité par store, limitée à son bucket par l'**opérateur** (les clés S3 des providers couvrent tout le compte par défaut, et ce dépôt ne fournit aucune politique : la forme ci-dessous est ce que le contrôle attend, pas
quelque chose de vérifié chez Scaleway, OVH ou Outscale). Sans les paires, le cluster tourne avec les clés de l'opérateur, qui ouvrent tous les buckets du cluster et peuvent y supprimer ; `seed-openbao.sh` le dit.
Les buckets d'état et d'artefacts ne sont écrits que depuis la machine de l'opérateur et la CI : aucune identité du cluster n'est censée les atteindre.

| Identité (variable du seed, chemin OpenBao) | Peut ouvrir | A besoin de | Doit être refusé |
|---|---|---|---|
| Opérateur K7 (`<PU>_AWS_*`, `<PU>_BACKUP_AWS_*` ; jamais dans le cluster) | tous les buckets de son store | tout | n/a |
| Sauvegardes applicatives, primaire (`OA_BACKUP_S3_*`, `backup/s3-primary` : restic, Longhorn, CNPG) | `s3-<project>-<provider>-backups-<env>` | list, get, put, `DeleteObject`, dépôt multipart et son abandon | `DeleteObjectVersion`, versionnement, cycle de vie, verrou d'objet ou rétention, suppression du bucket, tout autre bucket |
| Sauvegardes applicatives, réplica (`OA_BACKUP_REPLICA_S3_*`, `backup/s3-replica`) | le même nom avec `-backup`, sur le store du réplica | idem | idem |
| Loki (`OA_LOKI_S3_*`, `observability/loki-s3`) | `s3-<project>-<provider>-logs-<env>` | idem | idem, et le bucket de sauvegardes |

`DeleteObject` reste autorisé : sur un bucket versionné il écrit un marqueur, et restic, Barman, Longhorn et Loki suppriment dans leur travail normal (non essayé avec une clé sans `DeleteObjectVersion`).
`scripts/ops/s3-isolation-check.sh <tfvars>` lit, avec les paires dans l'environnement, quelle identité liste quel bucket, si chaque paire dédiée se voit refuser `DeleteObjectVersion` (une version qui n'existe pas est nommée :
rien n'est supprimé), et si les buckets portent le `backup_immutability` choisi. Sortie 0 : tenu, 1 : non tenu, 2 : aucune paire dédiée dans l'environnement. Le seed est en création seule : pour **renouveler** une paire, créer la nouvelle chez le provider, l'écrire avec
`task rotate-secret -- <chemin> --apply` (`admin-access.fr.md`, section 3), laisser l'ExternalSecret se rafraîchir, confirmer une sauvegarde ou un flush de journaux, puis révoquer l'ancienne.

**Scaleway : un bucket sans politique de bucket est ouvert à toute paire dédiée.** Les jeux de permissions IAM dont une paire a besoin (les trois jeux
`ObjectStorage*` d'objets, plus `ObjectStorageBucketsRead` pour HeadBucket, voir le README des sauvegardes côté apps) valent pour tout le projet : la portée de la paire
est donc ce que les politiques de bucket laissent ouvert. Le lab 12 l'a mesuré : avec des politiques seulement sur les buckets de sauvegardes et de journaux, les
paires listaient les buckets d'état et de management (`s3-isolation-check.sh` : 4 assertions sur 8 en échec) ; avec une **politique réservée à l'opérateur sur
tous les autres buckets** du projet (état, artefacts, management, les jumeaux `-backup` et les buckets d'images), 10 sur 10 tenaient, y compris la suppression d'une vraie
version d'objet (`OA_ISOLATION_REAL_VERSION=1`). La recette pour une paire, que ce dépôt n'applique pas à votre place (l'IAM du fournisseur est à l'opérateur) : créer
l'application et sa politique IAM, poser la politique réservée à l'opérateur sur tous les AUTRES buckets, la politique de la paire sur son bucket, puis lancer le contrôle. OVH et Outscale : non vérifié.

## 5. Ce qui n'est pas fait

- Le verrou d'objet et le versionnement sont optionnels, et non vérifiés chez aucun provider ; le défaut laisse une clé S3 volée capable de supprimer des sauvegardes. Aucune politique pour les paires limitées n'est fournie.
- Aucune copie que les clés du cluster ne peuvent jamais atteindre : une synchronisation côté opérateur vers un troisième bucket verrouillé n'a pas été construite, et `forget --prune` tourne encore dans le cluster, avec une clé qui doit garder `DeleteObject`. Les journaux n'ont pas de copie chez un second provider.
- Pas de test de restauration planifié de la couche infrastructure ; les tests mensuels de la couche applicative lisent des dumps et déballent des snapshots mais ne chargent rien dans une base vivante.
- Le snapshot etcd, la réplication de l'état et l'extraction des journaux du bastion dépendent de l'opérateur qui pense à les planifier. `task check-alerts` et les alertes de sauvegarde apps ne surveillent que la couche applicative.
- Le RPO et le RTO sont des objectifs. Le premier exercice chronométré (`disaster-recovery.fr.md`, section 5) les transforme en chiffres.

## 6. Revue

Relire cette page à chaque changement d'un script de sauvegarde, d'un bucket, d'un calendrier ou d'un nombre de rétention, après chaque restauration (pour corriger les objectifs) et au moins une fois par an.
