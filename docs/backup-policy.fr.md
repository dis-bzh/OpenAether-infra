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
| Journaux (chunks Loki) | Bucket propre `s3-<project>-<provider>-logs-<env>`, sans réplica, rétention d'un an chez Loki : un **stockage de journaux, pas une sauvegarde** |
| Volumes `local-path` et silences Alertmanager | Éphémères par décision ; la configuration d'Alertmanager vient de Git, les silences sont perdus |
| Volumes Longhorn hors du groupe de sauvegarde | Aucun composant de la plateforme n'utilise Longhorn aujourd'hui |
| Disques des nœuds et image Talos | Les nœuds se remplacent, ils ne se restaurent pas ; l'image est reconstruite depuis l'Image Factory (le verrou sha256 épingle ce qu'elle doit être) |
| Tout ce qui est dans un namespace que le DAG ne crée pas | Inconnu de ce dépôt |
| Les runners CI et le portable du mainteneur (`.env.sh`, tfvars, coffre de K5/K6) | Hors plateforme : **la perte de K5 et K6 n'est pas récupérable** et leur séquestre est celui de l'opérateur (`key-management.fr.md`) |

## 3. Destruction, expiration et mise hors service

**Il n'y a pas d'expiration automatique au-delà des nombres ci-dessus.** Aucun bucket n'a de versionnement, de règle de cycle de vie ni de verrou d'objet posé par ce dépôt : un
objet sorti du nombre de rétention est supprimé, mais une **version** de lui, si le bucket du provider est versionné, ne l'est pas ; et un attaquant qui détient K7 peut tout supprimer.
C'est une lacune connue, consignée ici ; activer le versionnement et un verrou de rétention est une décision par provider (support et coût diffèrent, rien de vérifié ici) et n'est pas prise.

- **Expiration** : les générations et snapshots sont élagués par les scripts. Après un **changement de clé**, supprimer soi-même les anciens objets
  (`key-management.fr.md`, section 4) : l'ancienne passphrase ouvre tout ce qui a été écrit sous elle.
- **Remplacer un dépôt ou un bucket** (un mot de passe restic fuité, un provider quitté) : confirmer que l'autre copie se restaure, révoquer la clé d'accès chez le provider, supprimer **chaque version
  d'objet et marqueur de suppression**, supprimer le bucket, et vérifier chez le provider qu'il a disparu. Un snapshot qu'on ne sait plus lire n'est pas effacé ; seule la suppression de l'objet l'efface.
- **Mettre un cluster définitivement hors service** : `cluster-down` laisse exprès les buckets et l'image. Après la dernière restauration dont vous pourriez avoir besoin : vider (versions comprises) et supprimer les quatre
  buckets du cluster chez les deux providers et le bucket de journaux, supprimer l'image Talos et ses snapshots (`purge-orphans`, la rétention d'images), révoquer K7 et K8,
  détruire K5 et K6, et retirer les fichiers du cluster de la machine de l'opérateur et des secrets CI `sandbox`. Lister ce qui reste en interrogeant le provider, pas le fichier d'état.
- **Supports** : un disque, un portable ou une clé USB qui a contenu une clé s'efface en le détruisant ou en détruisant sa clé de volume, pas par `shred` (`key-management.fr.md`, section 4).

## 4. Ce qui n'est pas fait

- Ni verrou d'objet ni versionnement (ci-dessus) : une clé S3 volée peut supprimer des sauvegardes.
- Pas de test de restauration planifié de la couche infrastructure ; les tests mensuels de la couche applicative lisent des dumps et déballent des snapshots mais ne chargent rien dans une base vivante.
- Le snapshot etcd, la réplication de l'état et l'extraction des journaux du bastion dépendent de l'opérateur qui pense à les planifier. `task check-alerts` et les alertes de sauvegarde apps ne surveillent que la couche applicative.
- Le RPO et le RTO sont des objectifs. Le premier exercice chronométré (`disaster-recovery.fr.md`, section 5) les transforme en chiffres.

## 5. Revue

Relire cette page à chaque changement d'un script de sauvegarde, d'un bucket, d'un calendrier ou d'un nombre de rétention, après chaque restauration (pour corriger les objectifs) et au moins une fois par an.
