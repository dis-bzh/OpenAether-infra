# Reprise après sinistre — une chaîne ordonnée, de rien à une plateforme qui fonctionne

🇬🇧 [English version](disaster-recovery.md)

> Écrit pour répondre aux règles ANSSI sur un plan de reprise documenté, des objectifs de temps et un test de reprise (id d'audit F-BKP-16). Il relie les
> éléments existants dans l'ordre qui marche, et depuis 0.4.0 `task dr-restore-plan` les lance dans cet ordre ; **la chaîne dans son ensemble n'a jamais été exécutée sur un cluster** : chaque morceau a
> été exercé (le palier est dit pour chaque étape), pas les jonctions entre eux. Les objectifs de temps sont des propositions, pas des
> mesures. Il ne revendique aucune conformité à un document ANSSI.

Lire d'abord `backup-policy.fr.md` pour ce qui est copié, et `incident-response.fr.md` si la reprise a pour cause une attaque (choisir un point de
restauration antérieur à T0, fermer d'abord la porte, renouveler après avoir restauré).

## 1. Quel sinistre

| Situation | Chemin |
|---|---|
| Un nœud perdu ou qui déraille | `rolling-replace` (`upgrade.fr.md`, « Remplacer un nœud ») : pas cette page |
| Le cluster a disparu, le provider et les buckets vont bien | sections 2 et 3, sur le même provider |
| Le provider a disparu (compte, région, le store primaire) | sections 2 et 3, en partant du réplica chez l'autre provider : `cluster/README.md`, « Cross-provider failover » |
| L'état a perdu ses secrets Talos mais les nœuds vivent | `cluster/README.md`, « Lost the Talos secrets » : pas une reconstruction |
| Seul OpenBao a perdu ses données | section 3 à partir de l'étape 5 |
| Une attaque | `incident-response.fr.md` d'abord |

## 2. Prérequis : ce qui doit déjà être hors du cluster

Si l'un manque, l'étape correspondante ne peut pas être faite ; l'objectif de reprise devient alors « reconstruire sans ces données ».

| Nécessaire | Détenu par | Perdu signifie |
|---|---|---|
| K5 (et K6 si posée) | le coffre de l'opérateur, idéalement à deux endroits | l'état, les artefacts et les snapshots sont illisibles : **pas de reprise de la PKI Talos** ; reconstruire avec une nouvelle PKI |
| Clés de stockage objet du store **survivant** (`<PU>_BACKUP_AWS_*` ou celles du primaire) et identifiants du provider | `.env.sh`, le coffre | en créer de nouvelles chez le provider ; ce ne sont les clés d'aucun secret |
| Les tfvars du cluster (`envs/<role>-<provider>.tfvars`, ignorés par git) | la machine de l'opérateur | les refaire depuis l'`.example` avec le nom du cluster, l'environnement, le `bucket_suffix`, l'endpoint et la région du réplica (`cluster/README.md`) |
| La clé de scellement OpenBao (séquestre, deux dépositaires) | `docs/admin-access.fr.md` section 1 ; apps Day 0 | **tous les secrets OpenBao et tous les snapshots raft sont perdus** |
| Les parts de récupération OpenBao (chiffrées PGP) et les clés privées des porteurs | les opérateurs | pas de break-glass : la restauration demande un jeton root |
| Le mot de passe restic (séquestre) | le coffre | les sauvegardes applicatives sont illisibles |
| Ce dépôt au tag qui a construit le cluster, et OpenAether-apps au `git_ref` qu'il épinglait | GitHub, et le clone de l'opérateur | construire depuis le tag que vous pouvez tirer ; rien ici n'est vendorisé |

## 3. La chaîne

Faire les étapes dans cet ordre. Une étape qui échoue arrête la chaîne : ne pas sauter plus loin pour « avoir quelque chose qui tourne ».

| # | Étape | Comment | Pourquoi à cette place | Palier et objectif (proposé) |
|---|---|---|---|---|
| 1 | Accès à l'identité de l'ancien cluster | `task restore-artifacts PROVIDER=<p> [FROM=replica]` pour le talosconfig et le kubeconfig ; `task restore-state` pour l'état si le provider a changé | Tout le reste demande l'état (il contient la PKI Talos) et, pour une reconstruction chez un autre provider, l'ancien kubeconfig pour vérifier | Les deux mesurés sur de vrais stores (`backup-policy.fr.md`). 30 min |
| 2 | Cluster | `task cluster-up PROVIDER=<p> [ROLE=…]` avec les tfvars ; l'état, puis les nœuds, puis Flux si `deploy_flux = true` | Rien d'autre n'existe sans nœuds | `cluster-up` mesuré : de 545 s à 1661 s sur les trois clouds, les plus longs incluant un build d'image (`status.md`). 1 à 2 h |
| 3 | **Secret de la clé de scellement, avant le démarrage des pods OpenBao** | Créer `foundation-vault` si besoin, puis `openbao-seal-key` depuis le séquestre (`gpg --decrypt openbao-seal-key.gpg`, ou les parts recombinées ; apps `vault/README.md`, « Disaster recovery », étape 1 ; `task escrow -- verify` répète l'ouverture sur un cluster vivant) ; suspendre les Kustomizations qui consomment des secrets | Le snapshot raft est chiffré par cette clé ; `init.sh` refuse d'inventer une clé sur un cluster déjà initialisé, mais sur un **nouveau** cluster il en inventerait une et votre snapshot serait illisible | Écrit, testé sur un vrai OpenBao (« with any other key the data does not come back ») ; **pas exercé sur un cluster**. 15 min |
| 4 | OpenBao démarré et vide | Laisser `foundation-vault` se déployer ; `init.sh` l'initialise | On restaure dans un OpenBao qui tourne et est initialisé | Mesuré à l'installation sur chaque labo. 15 min |
| 5 | **Restauration du snapshot OpenBao** | Sur la machine de l'opérateur : `restic restore latest` du dépôt `<bucket>/<CLUSTER_NAME>/openbao` (la valeur du CronJob ; l'exemple du README apps omet `<CLUSTER_NAME>`) avec le mot de passe restic du séquestre et les clés du store survivant (**pas** celles d'OpenBao : elles vivent dans ce qu'on restaure) ; puis avec un jeton root de secours du cluster neuf (un quorum de porteurs de parts), `bao operator raft snapshot restore -force <fichier>` (apps `backup/README.md` et `vault/README.md`) | La masterkey Zitadel, les mots de passe de bases, les passphrases restic et Longhorn et l'intermédiaire PKI reviennent d'ici. Rien d'autre ne peut démarrer correctement avant | La commande de restauration a été exécutée sur un vrai OpenBao ; l'étape entière **n'est pas exercée avec des standbys** (README apps). 1 h |
| 6 | Parts de récupération remises | Remplacer le `openbao-recovery-shares` neuf par la copie sauvegardée de la source (README apps, DR étape 4) | Les données restaurées sont sous les clés de récupération du cluster source | Comme l'étape 5. 15 min |
| 7 | External Secrets et le reste reprennent | Reprendre les Kustomizations suspendues ; `kubectl get externalsecret -A` tous Ready ; les Secrets restic et `zitadel-masterkey` existent | Les Secrets du cluster sont reconstruits depuis OpenBao, c'est pourquoi l'étape 5 précède la suivante | Observé à l'installation. 15 min |
| 8 | **Bases de données (CNPG)** | **Avant que Zitadel serve**, retenir la Kustomization `identity` (ou mettre Zitadel à 0). Restaurer depuis le dump restic (`pg_restore … --clean --if-exists`) ou par instant dans un nouveau Cluster (apps `backup/README.md`) | La masterkey d'OpenBao (étape 5) doit déjà être en place : une base restaurée sous une autre masterkey est inutilisable | `dr-restore-plan`, étape `dbs` (PITR par un Cluster jetable, ou le dump) ; la récupération elle-même a été faite à la main et est maintenant testée chaque jour ; **le chargement dans un Cluster vivant n'a pas été exécuté sur un cluster**. 1 h |
| 9 | Zitadel et le reste du DAG | Reprendre `identity` ; attendre le DAG (le nombre de Kustomizations bouge avec les briques choisies) | L'identité a besoin de sa base et de sa masterkey | Convergence mesurée à l'installation (35 Kustomizations environ 2 minutes après le seed, Scaleway). 30 min |
| 10 | Ce qui ne vit que dans etcd | Seulement si nécessaire : le snapshot etcd (`talosctl bootstrap --recover-from` ; celui qui est planifié est le dépôt restic `<bucket>/<CLUSTER_NAME>/etcd`, `restic restore latest` avec le mot de passe restic séquestré, et le fichier ne reçoit `--recover-skip-hash-check` que s'il n'a pas de suffixe sha256 ; ceux de l'opérateur, en gpg, sont `backups/etcd/`), qui **remplace** l'etcd courant et tout ce qui a été écrit depuis | Dernier recours : Flux reconstruit le contenu du cluster | Exécuté sur OVH pendant l'exercice de mise à jour (`upgrade.md`). Pas dans la chaîne normale |
| 11 | Vérifier | `task cluster-verify`, `task cluster-security`, `task rbac-review`, une connexion à chaque UI, une sauvegarde, puis re-poser ce qui est hors OpenBao (`seed-openbao.sh`) si le snapshot lui est antérieur | Déclarer terminé sur preuve | Objectifs des commandes, pas de la chaîne. 30 min |
| 12 | Après une attaque seulement | Renouveler (`incident-response.fr.md`, section 7), puis effacer les générations d'état de l'ancien cluster | Une restauration rend les anciens secrets | n/a |

**Objectif de temps proposé pour toute la chaîne : 8 heures de travail, une journée ouvrée (RTO), données au dernier bon backup (RPO ci-dessous).** La somme des objectifs
d'étape ci-dessus fait environ 6,5 heures. Aucun exercice ne l'a chronométrée.

### Une seule commande

`task dr-restore-plan` est le tableau ci-dessus en commande (`scripts/ops/dr-restore-plan.sh` ; elle n'ajoute aucun mécanisme, chaque étape appelle une commande qui existe). C'est un **dry-run par défaut** : elle affiche chaque étape avec les commandes de CE
cluster (ses buckets, dépôts et store), les entrées dont chaque étape a encore besoin et celles qui manquent, et ne lance rien. La lancer avec `--strict` avant le jour où on en a besoin. `--execute --confirm <cluster_name>` lance la
chaîne, un contrôle après chaque étape, et s'arrête au premier échec en disant l'étape où reprendre ; elle écrit un rapport de temps (un TSV, secondes et objectif par étape, l'horloge murale contre les 8 h) pour remplir le tableau de la section 5.

```bash
task dr-restore-plan PROVIDER=scaleway -- --from replica                         # dry-run : étapes ordonnées, commandes de ce cluster, entrées manquantes
task dr-restore-plan PROVIDER=scaleway -- --from replica --strict --seal-key-file F --restic-password-file F \
  --bao-token-file F --recovery-shares-dir D                                     # disponibilité : code 1 s'il manque une entrée
task dr-restore-plan PROVIDER=scaleway -- --from replica --seal-key-file F --restic-password-file F --bao-token-file F \
  --recovery-shares-dir D --execute --confirm <cluster_name>                     # la chaîne ; --from-step <id> reprend, --only <id,id> un sous-ensemble
```

Étapes (scénario reconstruction) : `artifacts` (1), `cluster` (2, avec `deploy_flux = false`), `seedkey` (3), `flux` (4 : `deploy_flux = true`, un second `task cluster-up` ; le tfvars précédent est gardé en `.dr-bak`), `hold` (les Kustomizations hors de la fermeture de dépendances
d'OpenBao sont suspendues), `generation` (la nouvelle génération d'archive CNPG, ci-dessous), `openbao` (5), `shares` (6), `resume` (7 : tout ce qui est retenu sauf identity), `dbs` (8), `identity` (9), `verify` (11 : `cluster-verify`, une sauvegarde de base de chaque nouvelle archive et sa copie vers le store réplica, puis un test de restauration lancé sur le cluster reconstruit). `--db-source pitr` (par défaut) récupère chaque
base CNPG depuis l'ObjectStore du store choisi (avec `--pitr-time` au besoin) dans un Cluster jetable `<nom>-dr`, puis envoie `pg_dump | pg_restore --clean` dans le Cluster vivant vide et contrôle la chaîne canari ; `--db-source dump` restaure
le dump restic à la place (RPO 24 h, sans archive : le chemin quand l'archive de l'autre provider a disparu). `--scenario etcd` est l'étape 10 seule : restauration restic du dernier snapshot etcd, `talosctl bootstrap --recover-from` (avec `--recover-skip-hash-check` quand le
fichier n'a pas de suffixe sha256), et un contrôle que l'API et les nœuds sont revenus. Les secrets sont lus dans des fichiers et passent par l'entrée standard ou en argument fichier, jamais dans argv ni dans la sortie.

### RPO, RTO, ce qui a été mesuré et ce qui ne l'a pas été

| Donnée | RPO (pire cas) | D'où il vient |
|---|---|---|
| OpenBao | 24 h | snapshot quotidien 02:17 UTC, restic sur les deux stores |
| Bases CNPG par l'archive | minutes sur le store primaire ; jusqu'à **15 min plus la copie** sur le store réplica (46 s pour 22 objets, lab 19) | archive WAL et `cnpg-store-replicate` toutes les 15 minutes |
| Bases CNPG par le dump | 24 h | dump quotidien 02:47 UTC, restic sur les deux stores |
| etcd | 24 h | snapshot 04:10 UTC, restic sur les deux stores |
| Volumes Longhorn | par job récurrent (quotidien 03:37 UTC si activé) | un seul store |
| tfstate, artefacts | depuis le dernier apply ou changement | les deux stores |

Objectif de RTO : **8 h** pour toute la chaîne (décision 0.4.0 ; à resserrer après la première exécution chronométrée). Ce qui a été mesuré, morceau par morceau, avec la forme du labo : `cluster-up` 8 min 53 s (Scaleway, 3 + 3 POP2-4C-16G, lab 19) et 545 s à 1661 s sur
les trois clouds (`status.md`) ; tout le DAG Ready 23,5 min (Scaleway) et 29 min (OVH) après le début (validation finale 0.3.0) ; récupération CNPG dans un nouveau Cluster 40 s (lab 15A), 54 s (15c), 72 s avec un point dans le temps depuis le store primaire et 66 s depuis le
**store réplica seul** primaire vidé (lab 19, 150 tables = origine) ; volumes Longhorn RWO, LUKS2 et RWX restaurés dans de nouveaux volumes, 82 s, sha256 identiques (15c) ; un snapshot etcd de 97,7 Mo restauré depuis le store réplica avec le mot de passe séquestré
et ouvert dans un etcd local (lab 19). Tout cela est nominal et séparé. **Non mesuré : la chaîne, nominale ou avec incident.**

**Pas encore prouvé** (chacun est un critère de réussite du prochain labo) : la chaîne dans son ensemble ; la jonction de l'étape 3 (`hold` suspend les Kustomizations avant que foundation-vault soit Ready ; la course n'est pas mesurée) ; la restauration raft d'OpenBao avec standbys, et la forme qu'utilise le script (jeton et snapshot
sur l'entrée standard de `kubectl exec`, `/tmp` inscriptible dans le pod) ; `talosctl bootstrap --recover-from` sur un cluster Talos jetable ; le chargement d'une base récupérée dans le Cluster vivant (propriétaire et rôles) ; un nouveau nom de cluster (le préfixe restic est
l'ancien nom, donc le script, qui lit le nom dans le tfvars, attend le même nom) ; les tests de restauration planifiés ci-dessous n'ont tourné que hors ligne.

**Mesuré au labo 27, séance 3** (2026-10-26, Scaleway seul, 3 CP + 5 W, les têtes 0.4.0 ; un bootstrap OpenBao de DÉVELOPPEMENT ; morceaux chronométrés isolément, PAS comme une seule chaîne) : (1) **restauration raft d'OpenBao** (`bao operator raft snapshot restore -force`) : la commande est revenue en 1 s et trois membres étaient descellés avec un leader 7 s plus tard (8 s au total) ; le témoin écrit avant le snapshot était présent, celui écrit après avait disparu, la connexion Kubernetes-auth du rôle admin fonctionnait toujours, trois votants. Même cluster, même clé de scellement : l'étape « remettre la clé de scellement mise en dépôt » d'une reconstruction n'a PAS été exercée. **Réserve : l'OpenBao du labo est un bootstrap de développement (une part de récupération en clair dans un Secret), c'est pourquoi le jeton racine de secours a pu être produit en un appel (environ 3 s) ; un OpenBao de production exige un quorum de détenteurs de parts chiffrées PGP, et ce chemin de production n'a PAS été exercé.** (2) **Récupération CNPG à un instant donné** : le test planifié `cnpg-pitr-restore-test` a récupéré zitadel-db et grafana-db depuis le store primaire ET le store réplica (quatre récupérations) vers un témoin vieux de 7200 s en 340 s au total, chaque récupération saine en 78, 78, 78 et 84 s, témoin identique à la chaîne vivante (séance 2 : 485 s au total, 111 à 122 s chacune). (3) **Restauration d'un snapshot etcd dans un cluster jetable** (1 plan de contrôle + 1 worker, le snapshot du cluster lui-même, 4,3 Mo) : `talosctl reset` du plan de contrôle avec la partition EPHEMERAL effacée, `talosctl bootstrap --recover-from` dès le retour de l'API Talos (59 s), l'API a répondu 25 s après le bootstrap et les nœuds étaient Ready 85 s après le reset, un membre etcd, le repère écrit avant le snapshot présent et celui écrit après disparu. Le snapshot d'UN AUTRE cluster restauré dans un cluster reconstruit reste non testé (il ne peut pas fonctionner sans les mêmes secrets Talos). (4) Le cluster jetable est l'étape 2 de la chaîne, construit avec `deploy_flux = false` : `cluster-up` s'est terminé en rc 201 à l'étape apps-ref (les CRD de Flux n'y existent pas). Corrigé : quand `deploy_flux` n'est pas vrai, `cluster-up` saute la pré-synchronisation CNPG, la synchronisation de cluster-identity et l'étape apps-ref avec une ligne qui dit pourquoi, et son verify ne les demandait déjà pas ; la convergence de CoreDNS et le verify de ce que Talos et Cilium possèdent tournent toujours (test simulé ; pas rejoué sur un cloud). **Non exécuté pendant cette séance :** la chaîne en UNE seule exécution chronométrée (`task dr-restore-plan --execute`) : le RTO de 8 h n'a donc que les morceaux ci-dessus et la chaîne de 31 min du labo 20 sur un cluster jetable ; le puits d'audit secondaire ; une restauration avec le quorum de parts d'un OpenBao de production.

### La génération d'archive : ce qu'une reconstruction fait à l'archive CNPG (apps #153)

Un cluster reconstruit ne doit pas archiver dans le chemin du cluster mort : barman refuse une archive non vide pour un nouveau cluster (« Expected empty archive »), donc rien n'est archivé et aucune sauvegarde de base n'aboutit (lab 20). Le plugin Barman Cloud écrit sous
`<destinationPath>/<serverName>` et, par défaut, `serverName` est le nom du Cluster : le nouveau `zitadel-db` retrouvait les objets de l'ancien. Désormais un Cluster archive sous `serverName` = `<cluster>` + le **suffixe d'archive** : vide sur toute installation (génération 1,
le chemin historique : rien ne bouge pour un cluster existant ni pour une installation neuve), `-g2`, `-g3`… sur un cluster reconstruit depuis un store.

- **Où c'est consigné** : le ConfigMap `cnpg-archive-generation` dans `flux-system` (`CNPG_ARCHIVE_SUFFIX`, `CNPG_ARCHIVE_PREVIOUS_SUFFIX`, annotation `openaether.io/archive-generation`). Flux possède les Clusters et substitue la valeur (`postBuild.substituteFrom`, **optionnel** : pas de ConfigMap, pas de suffixe) dans le Cluster
  et dans la copie de `cluster-identity` que lisent le vérificateur et les jobs. Il n'est pas dans git et Flux ne l'élague pas ; `task dr-restore-plan` l'écrit. Personne ne modifie le Cluster à la main.
- **L'étape `generation`** (après `hold`) : liste `cnpg/<cluster>/` dans les deux stores (le store survivant doit répondre ; l'autre est compté s'il est lisible), prend la plus haute génération trouvée plus un, écrit le ConfigMap et le suffixe précédent. `--archive-generation N` impose le numéro (sans liste, sans `aws`).
  Un second passage garde la valeur consignée, car le nouveau cluster a pu écrire son propre chemin. L'étape `dbs` attend que Flux ait donné le nouveau nom aux Clusters **avant** de charger les données ; `--db-source pitr` récupère depuis le chemin de la génération PRÉCÉDENTE (celle du cluster mort) ; l'étape `verify` donne à
  chaque nouvelle archive une sauvegarde de base (`Backup dr-base-<cluster>`), force la sortie du segment (`pg_switch_wal`), exige `ContinuousArchiving` True, lance une fois `cnpg-store-replicate` pour que le store réplica contienne le nouveau chemin, puis seulement le test de restauration.
- **Ce qui suit le suffixe** : le vérificateur lit `cnpg/<cluster>/<cluster><suffixe>/` (la génération la plus récente seule) ; les tests de restauration CNPG (quotidien, point dans le temps) récupèrent depuis le serverName sous lequel le Cluster vivant archive maintenant ; `cnpg-store-replicate` copie tout le préfixe `cnpg/<cluster>/`, donc les deux
  générations. L'ancien chemin n'est plus jamais écrit.
- **RPO et chemins après une reconstruction** : un point dans le temps **antérieur** à la reconstruction se récupère depuis l'ANCIEN chemin (`--db-source pitr` le fait ; à la main, une entrée `externalClusters` avec `serverName: <cluster>` ou `<cluster>-g<N-1>`) ; un point postérieur, depuis le nouveau. Il n'y a pas d'historique continu à travers la
  reconstruction : entre le dernier WAL archivé du cluster mort et le premier du nouveau, n'existent que les données chargées par la chaîne. La nouvelle archive commence avec la sauvegarde de base de l'étape `verify` : tant qu'elle n'est pas terminée, la récupération du cluster reconstruit passe par l'ancien chemin et le dump. L'ancien chemin reste dans
  les deux stores jusqu'à ce que quelqu'un le supprime (hors de la rétention de 30 jours du nouveau serverName : à supprimer soi-même une fois la fenêtre de récupération passée ; le job de copie n'élague le réplica que pour les objets qui ont quitté le primaire).

**NON VÉRIFIÉ (tests hors ligne seulement : barreau mocked)** : que CNPG et le plugin acceptent un `serverName` modifié sur un Cluster existant (le pod peut demander un rollout ou l'annotation `cnpg.io/reloadedAt`) et ce que l'instance fait des tentatives d'archivage antérieures au changement ; que le `substituteFrom` optionnel de Flux se comporte comme la substitution
hors ligne (et que les deux briques, `cnpg` et `backup-databases-identity`, appliquent la même valeur en une réconciliation) ; `aws s3api list-objects-v2` avec délimiteur chez les trois providers ; que le `Backup` avec `method: plugin` écrit le nouveau chemin ; que `pg_switch_wal` suffit sur une base occupée ; la durée du travail ajouté à `verify`.

**Critères de réussite du prochain exercice** (tous requis ; aucun n'a été observé) : (1) après `generation`, `kubectl -n flux-system get cm cnpg-archive-generation` montre `-g2` (ou le numéro suivant) et le suffixe précédent ; (2) l'étape `dbs` passe son attente : les deux Clusters montrent `serverName` `<cluster>-g2`, `ContinuousArchiving` True quelques minutes après le chargement, pas de « Expected empty archive » dans le journal du sidecar ;
(3) dans le store primaire `cnpg/<cluster>/<cluster>-g2/base/<id>/backup.info` (status DONE) et `wals/…` existent pour les deux clusters, et les objets sous `cnpg/<cluster>/<cluster>/` sont inchangés (même nombre, même date la plus récente) dans les deux stores ; (4) `Backup` `dr-base-*` terminé, job `dr-replicate` Complete, le store réplica contient `-g2` ;
(5) l'étape `verify` passe avec `PASS` pour les quatre combinaisons (zitadel-db et grafana-db, primaire et réplica) et aucun `SKIP`, retards sous les budgets (1200 s primaire, 3000 s réplica), zitadel-db compris ; (6) le prochain passage de `backup-verify` rapporte `cnpg` primaire et réplica à 1 pour les deux clusters et `BackupVerificationFailed` ne se déclenche pas, le prochain `ScheduledBackup` quotidien aboutit sur `-g2`, les prochains tests de restauration quotidien et hebdomadaire sont PASS en lisant `-g2` ;
(7) un passage `--db-source pitr --pitr-time <avant la reconstruction>` récupère depuis l'ancien chemin ; (8) deux réconciliations de `cnpg` par Flux (suspend, resume) laissent le `serverName` et les pods en l'état ; (9) un `cluster-up` neuf sur des buckets neufs rend `serverName` = le nom du Cluster (pas de ConfigMap, rien n'a bougé).

### Les tests de restauration planifiés (0.4.0)

Depuis 0.4.0 la plateforme restaure ses propres sauvegardes sans personne (apps `backup/databases`, `cnpg` et le composant optionnel `storage-restore-test`) : `cnpg-recovery-restore-test` quotidien récupère zitadel-db et grafana-db depuis le store primaire ET le store réplica dans un Cluster jetable de
`backup-restore-test` et compare une table canari (un compteur et une chaîne de hachages écrits toutes les 5 minutes) avec la base vivante ; `cnpg-pitr-restore-test` hebdomadaire récupère à l'heure d'une ligne canari et doit finir exactement là ; `cnpg-dump-load-restore-test` quotidien charge les dumps restic des
deux dépôts dans un PostgreSQL privé ; `longhorn-restore-test` optionnel restaure chaque semaine un volume canari. Les résultats sont des métriques `oa_restore_test_*` avec `RestoreTestFailed`, `RestoreTestNoRecentPass` et les autres alertes de `vmrule-restore-test.yaml`. Un objet jetable est toujours supprimé, même
en cas d'échec, et un test de restauration ne peut jamais toucher un objet vivant (namespace, noms, RBAC et une politique Kyverno). Le snapshot raft d'OpenBao est contrôlé chaque jour jusqu'à ses sommes ; il n'est restauré dans un OpenBao que par cette chaîne.

**Points où la chaîne a une jonction non réglée** : (a) comment gagner l'étape 3 contre Flux sur un cluster monté avec Flux (suspendre `flux-system` dès que l'API répond, ou monter avec
`deploy_flux = false` et l'activer une fois le Secret posé) : pas essayé, c'est une étape de labo ; (b) si le réplica survivant contient le dépôt restic du **cluster mort** sous le préfixe
que le nouveau cluster attend (le préfixe du dépôt est le nom du cluster ; un nouveau nom de cluster demande l'ancien préfixe dans la commande) ; (c) la chaîne PITR est chez le provider
tombé en cas de perte de provider : seul le dump quotidien survit chez l'autre (RPO 24 h).

## 4. Reconstruire en perdant des données : quand un prérequis manque

| Manque | Ce qu'on peut encore faire |
|---|---|
| La clé de scellement | Un nouvel OpenBao, re-semé : `seed-openbao.sh`, nouvelle masterkey Zitadel (la couche identité repart vide), nouveaux mots de passe de bases (les bases restaurées depuis des dumps ne peuvent pas les utiliser ; restaurer le dump d'abord, puis aligner les mots de passe des rôles), nouveau mot de passe restic et **nouveaux dépôts** ; les anciennes sauvegardes d'OpenBao sont illisibles |
| K5 et K6 | Une nouvelle PKI : un nouveau cluster de zéro ; les anciens nœuds ne peuvent plus être administrés ; seules les sauvegardes applicatives (restic) restent |
| Le mot de passe restic | Les sauvegardes applicatives sont perdues ; nouveaux dépôts |
| Toutes les parts de récupération | Pas de break-glass ; la restauration demande un jeton root : un nouvel OpenBao et la perte de son contenu |
| Le store survivant | Reconstruire depuis les dépôts Git, et rien d'autre |

## 5. Exercice : chaque année, avec un tableau de résultats

Une reprise qu'on n'a pas répétée est une hypothèse (`restore-artifacts.sh` le dit d'un seul script ; cela vaut pour la chaîne). Cadence : **une fois par an, et après tout changement d'une étape ci-dessus**, sur un cluster
jetable de la plus petite forme (1 control plane + 1 worker, `capacity.fr.md`) dans un projet sans donnée de production, depuis une vraie sauvegarde d'un cluster de labo, avec un
chronomètre lancé à la décision et chaque étape notée comme exécutée, sautée ou en échec.

| Date | Cluster, provider | Étapes exécutées | RTO mesuré | RPO mesuré | Ce qui a échoué | Corrections faites |
|---|---|---|---|---|---|---|
| _aucun encore_ | | | | | | |

Le premier exercice est `task dr-restore-plan ... --execute` sur un cluster jetable (`LAB-CHECKLIST.md`, B13 et B17) : il règle les trois jonctions ci-dessus et remplace les objectifs proposés par des chiffres ; son rapport TSV est la source de la ligne.
Qui le mène écrit la ligne, corrige cette page, et énonce dans le CHANGELOG le palier atteint.

## 6. Revue

Relire à chaque changement de l'ordre du DAG, d'un mécanisme de sauvegarde, du seal OpenBao ou du flux cluster-up ; après chaque exercice ; au moins une fois par an.
