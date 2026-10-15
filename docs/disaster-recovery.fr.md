# Reprise après sinistre — une chaîne ordonnée, de rien à une plateforme qui fonctionne

🇬🇧 [English version](disaster-recovery.md)

> Écrit pour répondre aux règles ANSSI sur un plan de reprise documenté, des objectifs de temps et un test de reprise (id d'audit F-BKP-16). Il relie les
> éléments existants dans l'ordre qui marche ; **il n'ajoute aucun mécanisme, et la chaîne dans son ensemble n'a jamais été exécutée** : chaque morceau a
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
| 3 | **Secret de la clé de scellement, avant le démarrage des pods OpenBao** | Créer `foundation-vault` si besoin, puis `openbao-seal-key` depuis le séquestre (apps `vault/README.md`, « Disaster recovery », étape 1) ; suspendre les Kustomizations qui consomment des secrets | Le snapshot raft est chiffré par cette clé ; `init.sh` refuse d'inventer une clé sur un cluster déjà initialisé, mais sur un **nouveau** cluster il en inventerait une et votre snapshot serait illisible | Écrit, testé sur un vrai OpenBao (« with any other key the data does not come back ») ; **pas exercé sur un cluster**. 15 min |
| 4 | OpenBao démarré et vide | Laisser `foundation-vault` se déployer ; `init.sh` l'initialise | On restaure dans un OpenBao qui tourne et est initialisé | Mesuré à l'installation sur chaque labo. 15 min |
| 5 | **Restauration du snapshot OpenBao** | Sur la machine de l'opérateur : `restic restore latest` du dépôt `<bucket>/<CLUSTER_NAME>/openbao` (la valeur du CronJob ; l'exemple du README apps omet `<CLUSTER_NAME>`) avec le mot de passe restic du séquestre et les clés du store survivant (**pas** celles d'OpenBao : elles vivent dans ce qu'on restaure) ; puis avec un jeton root de secours du cluster neuf (un quorum de porteurs de parts), `bao operator raft snapshot restore -force <fichier>` (apps `backup/README.md` et `vault/README.md`) | La masterkey Zitadel, les mots de passe de bases, les passphrases restic et Longhorn et l'intermédiaire PKI reviennent d'ici. Rien d'autre ne peut démarrer correctement avant | La commande de restauration a été exécutée sur un vrai OpenBao ; l'étape entière **n'est pas exercée avec des standbys** (README apps). 1 h |
| 6 | Parts de récupération remises | Remplacer le `openbao-recovery-shares` neuf par la copie sauvegardée de la source (README apps, DR étape 4) | Les données restaurées sont sous les clés de récupération du cluster source | Comme l'étape 5. 15 min |
| 7 | External Secrets et le reste reprennent | Reprendre les Kustomizations suspendues ; `kubectl get externalsecret -A` tous Ready ; les Secrets restic et `zitadel-masterkey` existent | Les Secrets du cluster sont reconstruits depuis OpenBao, c'est pourquoi l'étape 5 précède la suivante | Observé à l'installation. 15 min |
| 8 | **Bases de données (CNPG)** | **Avant que Zitadel serve**, retenir la Kustomization `identity` (ou mettre Zitadel à 0). Restaurer depuis le dump restic (`pg_restore … --clean --if-exists`) ou par instant dans un nouveau Cluster (apps `backup/README.md`) | La masterkey d'OpenBao (étape 5) doit déjà être en place : une base restaurée sous une autre masterkey est inutilisable | Le chemin par dump est écrit ; `pg_restore --list` testé chaque mois ; **le PITR et la restauration du dump dans une base vivante n'ont pas été exécutés**. 1 h |
| 9 | Zitadel et le reste du DAG | Reprendre `identity` ; attendre le DAG (le nombre de Kustomizations bouge avec les briques choisies) | L'identité a besoin de sa base et de sa masterkey | Convergence mesurée à l'installation (35 Kustomizations environ 2 minutes après le seed, Scaleway). 30 min |
| 10 | Ce qui ne vit que dans etcd | Seulement si nécessaire : le snapshot etcd (`talosctl bootstrap --recover-from`), qui **remplace** l'etcd courant et tout ce qui a été écrit depuis | Dernier recours : Flux reconstruit le contenu du cluster | Exécuté sur OVH pendant l'exercice de mise à jour (`upgrade.md`). Pas dans la chaîne normale |
| 11 | Vérifier | `task cluster-verify`, `task cluster-security`, `task rbac-review`, une connexion à chaque UI, une sauvegarde, puis re-poser ce qui est hors OpenBao (`seed-openbao.sh`) si le snapshot lui est antérieur | Déclarer terminé sur preuve | Objectifs des commandes, pas de la chaîne. 30 min |
| 12 | Après une attaque seulement | Renouveler (`incident-response.fr.md`, section 7), puis effacer les générations d'état de l'ancien cluster | Une restauration rend les anciens secrets | n/a |

**Objectif de temps proposé pour toute la chaîne : 8 heures de travail, une journée ouvrée (RTO), données au dernier bon backup (RPO 24 h).** La somme des objectifs
d'étape ci-dessus fait environ 6,5 heures. Aucun exercice ne l'a chronométrée.

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

Le premier exercice est la répétition à blanc de cette chaîne (`LAB-CHECKLIST.md`, B13 et B17) : il règle les trois jonctions ci-dessus et remplace les objectifs proposés par des chiffres.
Qui le mène écrit la ligne, corrige cette page, et énonce dans le CHANGELOG le palier atteint.

## 6. Revue

Relire à chaque changement de l'ordre du DAG, d'un mécanisme de sauvegarde, du seal OpenBao ou du flux cluster-up ; après chaque exercice ; au moins une fois par an.
