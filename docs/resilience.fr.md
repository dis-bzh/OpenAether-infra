🇬🇧 [English version](resilience.md)

# Perdre un nœud, un plan de contrôle ou une zone : ce qui survit, ce que vous lancez, comment c'est prouvé

Version 0.4.0, jalon M4. Niveau de preuve : **simulé/statique** (tests avec doublures, manifestes rendus, tests unitaires des règles d'alerte), puis **éprouvé une fois sur un vrai cloud** : le labo 21
(Scaleway, 3 plans de contrôle et 4 workers sur trois zones, 2026-10-21) a joué les exercices de la fin de cette page. Ses chiffres, les critères tenus et ceux qui ne l'ont pas été sont dans le tableau
« Mesuré au labo 21 » juste après les exercices ; ce qui reste PAS VÉRIFIÉ est la dernière section. Pas une déclaration de conformité.

## Ce que cela promet, et ce que cela ne promet pas

Le cluster de gestion est construit par OpenTofu. **Rien dans le cluster ne remplace seul un nœud mort**, et rien ne fait varier le nombre de nœuds : ce que Cluster
API gère reste à Cluster API (modules optionnels pour les clusters enfants), ce qu'OpenTofu gère reste à OpenTofu. Pour le cluster de gestion, la 0.4.0 signifie :

1. **Survivre** à la perte d'un worker, d'un plan de contrôle et (avec des nœuds répartis sur trois domaines de défaillance) d'une zone, sans interruption client au-delà
   d'un battement, grâce aux réplicas, à la répartition et aux budgets de perturbation. Cibles : disponibilité 99,9 %, un battement d'au plus 5 s, une interruption
   d'écriture en base d'au plus 30 s.
2. **Le dire fort**, avec une alerte dont le texte nomme la commande à lancer.
3. **Reconstruire** le nœud mort avec des commandes d'opérateur documentées et testées.

| Cible | Valeur | Origine |
|---|---|---|
| Battement HTTP côté client | au plus 5 s d'affilée | décision du propriétaire, 2026-10-19 |
| Interruption d'écriture en base | au plus 30 s | idem ; mesuré 24 s (primaire tué), 12 s (bascule) au labo 15c |
| Commits acquittés perdus en base | **zéro** | règle du propriétaire, 2026-10-22 : réplication synchrone par quorum (`dataDurability: required`) sur les deux bases ; critères dans OpenAether-apps `docs/resilience.md`, « Zero-loss proof » ; PAS encore exécuté sur un cluster |
| Disponibilité | 99,9 % | idem |

L'interruption d'écriture est **bornée, pas nulle** : PostgreSQL n'a qu'un écrivain, les écritures s'arrêtent le temps de promouvoir un réplica (un client qui réessaie la masque, le guide OpenAether-apps « Surviving a database failover from your own application »). Ce qui est nul, c'est la perte de commits acquittés. Un chemin d'écriture réellement à 0 s demande une base distribuée et n'est pas prévu. Les écritures **se bloquent** (rien n'est perdu) quand aucun réplica n'est disponible : l'alerte `CnpgSyncReplicaMissing` le dit.

## Pourquoi un pod d'un nœud mort n'est pas replanifié tout de suite

Kubernetes n'évince les pods d'un nœud qui ne répond plus qu'après la tolérance de 5 minutes (non prêt / injoignable) qu'il ajoute à chaque pod. Une charge à deux
réplicas sur deux workers continue de servir entre-temps ; une charge à un seul réplica est arrêtée pendant ces 5 minutes plus la replanification. L'audit des briques de la
plateforme (OpenAether-apps, `scripts/check-ha.py`, en CI) exige donc, pour chaque Deployment et StatefulSet : deux réplicas, une répartition par hôte, exactement un
PodDisruptionBudget qui autorise exactement une perturbation, rien qui puisse bloquer un pod sur trois workers ; et une **liste motivée**
(`scripts/ha-allowlist.yaml`) de ceux qui restent seuls, avec ce que leur perte signifie. Supprimer l'objet Node d'une machine disparue libère ses pods immédiatement au
lieu de 5 minutes : `task cluster-replace-node` le fait.

La perte d'un worker ou d'une zone demande de la marge : les requêtes CPU des workers doivent tenir sur les workers qui restent. Les exemples 3 x 4 vCPU
passaient `cluster-roll` avec environ 0,8 vCPU de reste (`capacity.md`, dérivé du labo 16) ; le travail HA du M4 ajoute environ 345 m de requêtes CPU (dérivé des
manifestes : admission Kyverno, opérateur CNPG, contrôleur et webhook ESO, metrics-server, la page de connexion Zitadel, le second Alertmanager), ce qui laisse environ 0,45 vCPU. Mesurée au labo 21, la plateforme demande environ 9 vCPU (223-228 % d'un worker de 4 vCPU), pas les 7,85 dérivés : les exemples Scaleway et OVH livrent 4 workers de 4 vCPU (décision du
propriétaire, 2026-10-21 ; 3 seraient refusés par la barrière), qui passent à 74-76 % de sa limite ; pour la perte de la zone qui porte deux des quatre workers, 200 % restent pour 224 %
(`capacity.md` : des pods restent Pending jusqu'au retour de la zone ; 5 workers tiendraient sur le papier). La barrière de `task cluster-roll` le dit avant de toucher à quoi que ce soit ; `ClusterCannotLoseWorker` le dit pendant que le cluster tourne.

## Ce que vous lancez

Les alertes sont dans OpenAether-apps (`docs/runbooks.md`, « Loss of capacity ») ; chacune nomme les mêmes quelques commandes, lancées depuis ce dépôt avec les identifiants du cluster.

| Alerte | Se déclenche après | Vous lancez |
|---|---|---|
| `NodeUnreachable` (kubelet muet) | 3 min (un redémarrage dure 85-115 s) | `task cluster-node-state`, puis `cluster-node-recover` ou `cluster-replace-node` |
| `NodeNotReady` | 5 min | idem |
| `ControlPlaneMemberMissing` | 3 min | idem, et ne pas déployer ni toucher un autre plan de contrôle |
| `FailureDomainLost` | 2 min | `task failure-domain-check` ; attendre le fournisseur s'il déclare la zone en panne |
| `WorkloadReplicasBelowDesired` | 15 min | trouver le pod Pending ; nœud mort : le remplacer |
| `ClusterCannotLoseWorker` | 30 min | ajouter un worker ou baisser les requêtes |
| `OpenBaoReplicasMissing`, `LonghornVolumeDegraded`, `CnpgInstanceMissing` | 5-30 min | nœud mort : le remplacer ; ils se resynchronisent seuls |
| `EtcdQuorumLost` (deux plans de contrôle sur trois perdus pour de bon) | 2 min | `task dr-restore-plan`, dernier recours |

### `task cluster-node-state PROVIDER=… NODE=<nœud>` (lecture seule)

Demande à l'API du fournisseur ce que fait la machine (`running`, `stopped`, `error`, `absent`, `transition`, ou `unknown` quand le fournisseur ne répond pas), lit le
kubelet et le port Talos, et affiche un `VERDICT=` : `healthy`, `recover`, `replace`, `wait` ou `unknown`, avec la commande suivante. Il ne décide jamais à partir d'un
fournisseur qui n'a pas répondu.

### `task cluster-node-recover PROVIDER=… NODE=<nœud>`

Pour une machine qui **tourne chez le fournisseur mais reste muette** : OVH affiche l'instance `ACTIVE` alors qu'elle est morte (#49, #371 ; revu au labo 17), et rien dans
OpenTofu ni dans la console ne le dit. Il refuse si le fournisseur ne dit pas `running`, et il refuse quand **aucun autre nœud ne répond non plus par les tunnels Talos**
(le tunnel ou le bastion sont alors la cause probable, et un nœud sain ne doit pas être redémarré de force pour cela). Il envoie un **redémarrage forcé** du fournisseur
(OVH : Nova HARD ; Outscale : ForceStop puis Start, parce qu'un redémarrage invité est justement ce qui ne répond pas ; Scaleway : l'action `reboot`), attend un temps borné le port
Talos et un nœud Ready, sinon finit en nommant le remplacement. Il ne détruit rien. Un redémarrage forcé efface la trace de la console série : lisez la console d'abord si
vous voulez la cause (c'est le seul moyen de savoir pourquoi #371 arrive).

Note Outscale : une VM arrêtée garde ses volumes BSU, et un changement de `vm_type` demande le même arrêt/démarrage ; ne combinez pas les deux à la main pendant qu'un nœud est mort.

### `task cluster-replace-node PROVIDER=… NODE=<nœud>`

Pour une machine arrêtée, en erreur ou disparue, ou qui n'est pas revenue après `recover`. Il refuse un nœud Ready (utilisez `task cluster-roll`) et une machine que le
fournisseur dit en marche (utilisez d'abord `recover` ; `-- --even-if-running` après son échec). Il lance `rolling-replace.sh --dead --node=…` : les mêmes deux applications de
plan enregistré et les mêmes barrières que `cluster-roll`, avec ces différences, car le nœud ne peut pas être vidé :

1. un **examen des survivants** : tous les autres nœuds sont Ready (un nœud à la fois ; plusieurs, c'est une perte de zone), et pour un plan de contrôle un quorum de
   membres etcd sains sans lui (sinon c'est le cas de la reprise après sinistre et la commande dit `task dr-restore-plan`) ;
2. le nœud est isolé (cordon) ; pour un plan de contrôle son **membre etcd est retiré d'abord**, puis l'objet Node est supprimé (jamais l'inverse), ce qui libère ses pods
   tout de suite ; l'instance puis sa configuration Talos sont appliquées ;
3. puis Ready, uncordon, etcd revenu à tous ses membres et kube-apiserver en service (plan de contrôle), et la barrière Longhorn.

L'état est sauvegardé ensuite, comme le fait `cluster-roll`. Il liste alors les volumes que l'ancien disque a laissés et affiche les commandes qui les suppriment (`-- --clean` les exécute, pour les cas sûrs connus : section « DNS et délai d'éviction après le labo 21 »). Cela efface le disque système du nœud et les données local-path qu'il portait (membre raft OpenBao, une
instance CNPG, un réplica de stockage VictoriaMetrics), que les pairs reconstruisent. Un membre OpenBao sur un worker remplacé NE se rattache PAS tout seul (labo 21 : `open /bao/data/node-id: permission denied`, le répertoire du volume conservé est recréé en root sur le nouveau disque) :
les deux autres membres descellés, supprimez son pod, sa PVC et le PV conservé, local-path provisionne un nouveau volume ; le membre s'est rattaché et descellé en environ 2 minutes ; `loki-0` et `vmselect` (classe `local-path`) ont planté de la même façon et sont revenus après suppression de leur pod et PVC (le script affiche l'indication). Une instance CNPG dont le volume était sur le disque mort peut rester Pending :
supprimez son pod et son PVC et laissez CNPG la cloner (vérifié au labo 21 : boucle de plantage sur le répertoire de données vide, clone en moins d'une minute ; seulement tant que le cluster a un primaire sain ailleurs ; le script affiche l'indication).

Jamais : `tofu destroy` ou `tofu apply -replace` à la main sur plus d'un nœud ; supprimer l'objet Node d'un plan de contrôle avant que son membre etcd soit parti ;
`task cluster-roll` pendant qu'un nœud est tombé (ses barrières refusent) ; supprimer le PVC d'un pod dont le nœud est seulement injoignable.

## Déploiement des plans de contrôle : le battement de l'API (#42)

Déploiement avec transfert du leadership avant le dernier plan de contrôle (existant) et désormais une **barrière apiserver** : après le redémarrage d'un plan de contrôle,
le déploiement attend que son pod statique kube-apiserver soit Ready et que `/readyz` réponde, trois relevés de suite, avant de le remettre en rotation, et refuse
d'arrêter un plan de contrôle si tous les apiservers ne servent pas. etcd 3/3 et un nœud Ready ne le disaient pas, et la sonde TCP du répartiteur de charge garde un
apiserver non prêt en rotation jusqu'à 75 s (5 sondes x 15 s). La barrière est prouvée hors ligne avec un kubectl factice ; savoir si elle supprime le battement de 5 à 8 s demande le
déploiement réel ci-dessous.

**Décision du propriétaire prise le 2026-10-21 : aucune des deux n'est activée** (elle changerait ce qui est exposé) ; la barrière du roll de l'apiserver est ce qui existe. Les options, pour mémoire : faire sonder `/readyz` en HTTPS par les répartiteurs au lieu de TCP 6443, et donner à
kube-apiserver `--shutdown-delay-duration` pour qu'il devienne non prêt avant de s'arrêter. La première exige que `/readyz` réponde sans identifiants, donc un accès anonyme aux
points de santé (`anonymous-auth` ou une configuration d'authentification structurée limitée à `/livez`, `/readyz`, `/healthz`), que les clusters n'activent pas aujourd'hui et qu'il faut
d'abord vérifier sur un nœud Talos (#42 le dit aussi). La seconde est un changement de configuration machine Talos sur chaque plan de contrôle. Aucune n'est utile sans l'autre.
Les sondes TCP et la barrière sont ce qui existe.

## Perte de zone

Hypothèses de placement : les plans de contrôle sont répartis sur trois domaines de défaillance (vérifié par `cluster-verify`, #38) et les workers aussi (`worker_zones`, nouveau : où le
fournisseur a placé chaque worker). Chaque nœud porte désormais l'étiquette `topology.kubernetes.io/zone` posée depuis ce placement (Talos `machine.nodeLabels`, appliquée au prochain
`infra-apply` sans redémarrage). Avec 3 plans de contrôle et 3 ou 4 workers sur 3 domaines, perdre un domaine laisse 2 plans de contrôle (quorum etcd), 2 ou 3 workers, 2 membres OpenBao sur 3, une
instance de chaque base et un réplica de chaque volume.

`task failure-domain-check PROVIDER=…` calcule cela pour chaque domaine à partir de l'état et du cluster et sort en code 1 quand une perte arrêterait quelque chose. Un pod Gateway unique, une base
dont les instances partagent un domaine, des workers dont les requêtes ne tiennent pas sur ceux qui restent, sont nommés. C'est aussi la première chose à lancer quand `FailureDomainLost` se déclenche.

## DNS et délai d'éviction après le labo 21 (infra #388, apps #154)

Échelon : **simulé/statique** (`tofu test`, le manifeste rendu, un faux `kubectl`). Rien de ceci n'a été éprouvé sur un cluster. Pas une déclaration de conformité.

**CoreDNS (#388).** Labo 21 : les deux réplicas Talos étaient sur un même worker, sa perte a donc coûté 4 min 46 s sans DNS ; avec les réplicas sur deux plans de contrôle, la perte d'un plan de
contrôle coûtait encore un trou d'écriture de 46 s. Le levier : `cluster.coreDNS` de Talos n'a que deux clés, `disabled` et `image`, ni réplicas, ni placement, ni budget, et un correctif venu de
l'extérieur (Flux, Kyverno, un post-renderer) sur un objet que Talos applique aussi se battrait avec la synchronisation de Talos (quel côté gagne est PAS VÉRIFIÉ). Choisi, `coredns_ha` (vrai par
défaut, module `talos`) : `cluster.coreDNS.disabled = true` plus un manifeste inline `coredns` (`modules/talos/coredns.yaml.tftpl`) aux mêmes noms, étiquettes et ClusterIP (`10.96.0.10`, plage de
services par défaut `10.96.0.0/12`), `min(3, nœuds)` réplicas, une **répartition stricte par nœud avec `minDomains` = réplicas** (un réplica créé avant l'enregistrement des autres nœuds attend un
autre nœud au lieu d'en partager un, ce qui s'est produit), une préférence de zone, un budget qui admet une perturbation, des tolérances not-ready/unreachable de 30 s, des requêtes 50m/70Mi (trois
réplicas 150 m, contre 2 x 100 m). C'est un manifeste inline et non un objet Flux parce que Flux a lui-même besoin du DNS pour tout récupérer. L'image est désormais la vôtre : `coredns_image_tag`,
suivie par Renovate. Non retenus : un correctif Flux ou Kyverno de l'objet Talos (ci-dessus) ; le cache NodeLocal DNS (un DaemonSet par nœud, environ 0,1 vCPU chacun pour une marge de 0,15 vCPU dans
la zone à deux workers, et il ne répond périmé que pour les noms déjà demandés : il masque une panne, il ne la supprime pas) ; changer les tolérances par défaut de l'apiserver (tous les pods). Reste
vrai ensuite : tant que le Service n'a pas retiré le réplica d'un nœud perdu (environ 40 s après le passage en NotReady, 80 s vus au labo 21), une résolution sur trois lui est adressée ; les résolveurs
réessaient après 5 s, un écrivain à 1 Hz avec un court délai de connexion peut encore échouer pendant ce temps.

**Mises à jour de Talos.** Avec `coreDNS.disabled`, Talos ne crée ni ne met à jour `kube-system/coredns` : les mises à jour de Talos et de Kubernetes n'y touchent pas, un changement de version de CoreDNS est un
changement de `coredns_image_tag` et un `tofu apply` (la configuration est renvoyée aux plans de contrôle, qui réappliquent leurs manifestes inline ; pas de redémarrage). **L'activer sur un cluster qui
tourne ne l'y fait PAS arriver** (lab 26, K2, PROUVÉ sur un cluster 0.3.2 passé en 0.4.0) : Talos n'applique les objets d'un manifeste inline que s'ils sont absents, donc le Deployment `kube-system/coredns` créé par Talos reste tel quel
(même uid, 2 réplicas, aucune répartition) et seul le nouveau budget apparaît. `cluster-verify` le dit maintenant (« CoreDNS runs the declared replica count and spread », BAD dans les deux sens, avec la commande). L'étape unique
pour un cluster construit par une version plus ancienne est un patch de ce Deployment : `kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json`
(3 réplicas, la répartition stricte par nœud avec `minDomains` 3, la préférence de zone, les tolérances de 30 s : un test garde le fichier égal au manifeste ; pour moins de 3 nœuds, éditer `replicas` et `minDomains`).
Il redémarre les pods CoreDNS un par un. Il n'apporte PAS le reste du manifeste : le Corefile, l'étiquette d'image, les requests/limits, la stratégie de mise à jour et la classe de priorité d'un cluster mis à niveau restent ceux de Talos,
et un changement ultérieur de `coredns_image_tag` n'y arrive pas non plus (`kubectl set image`, plus bas). Reconstruire le Deployment depuis le manifeste (le supprimer et laisser Talos réappliquer le manifeste inline) n'est pas documenté,
car on n'a pas observé si ni quand Talos réapplique un objet absent après un changement de configuration. Le désactiver laisse celui d'OpenAether en place jusqu'à ce que Talos réapplique le sien, donc supprimez d'abord
`kube-system/coredns`. PAS VÉRIFIÉ : le patch sur un cluster réel (les secondes de DNS pendant le déploiement), que la synchronisation des manifestes inline mette à jour un Deployment en place quand seule l'étiquette change
(observé : non, plus bas), et ce que dit `talosctl upgrade-k8s` de CoreDNS quand il est désactivé.

**Bascule de la base (#154, OpenAether-apps `docs/resilience.md`).** Le primaire CNPG d'un nœud perdu bascule quand son pod est évincé ; les Clusters tolèrent maintenant `unreachable` et `not-ready`
30 s au lieu de 300 s. Trou d'écriture attendu pour une coupure de courant d'un nœud : environ 60 s (deux mesures de 328 et 333 s moins les 300 s), pas 30 s : détection et promotion font déjà 28-33 s.
Un primaire tué (24 s) et une bascule planifiée (12-14 s) tiennent 30 s. Le propriétaire décide si 30 s s'applique à une coupure de courant.

**Après un remplacement (point 4 du suivi du labo 21).** `cluster-replace-node` finit maintenant par `scripts/ops/replaced-node-cleanup.py` : il prend les PV rattachés par nom d'hôte au nœud remplacé et créés
AVANT son nouvel objet Node (les données étaient sur l'ancien disque), trouve les pods bloqués dessus et affiche les commandes `kubectl` exactes. Par défaut rien n'est supprimé. `-- --clean` les exécute,
seulement pour : un réplica CNPG dont le Cluster a un primaire Ready ailleurs (jamais le primaire d'enregistrement), un membre OpenBao tant qu'une majorité raft des autres est Ready (Ready veut dire descellé),
Loki, vmstorage et vmselect tant qu'un autre réplica est Ready ; le PV conservé est supprimé avec la claim. Un membre par charge de travail et par exécution, un pod Ready est laissé, tout le reste est refusé
et la commande sort en 1. Les réplicas Longhorn sont signalés (un volume en défaut est nommé), jamais supprimés : Longhorn les reconstruit. `task cluster-replaced-node-cleanup NODE=<nœud> [-- --clean]` la
lance seule (pour un membre différé, ou plus tard). L'association d'un PV au nouveau Node par date de création a été vue sur un cluster réel au lab 25 (nœud mort : 7 volumes nettoyés en 6 s). PAS VÉRIFIÉ : le re-clonage par CNPG dans tous les cas que le script laisse passer.

**Un remplacement avec drain garde l'objet Node (lab 26, C1).** `task cluster-roll -- --node=<nœud>` draine, puis remplace la VM et son disque, mais l'objet Node reste : aucun volume n'est « plus ancien que le Node », si bien que l'outil
ci-dessus répondait « nothing to clean » pendant qu'un réplica CNPG, Loki et vmselect bouclaient (`mkdir ... permission denied` sur le répertoire conservé, vide et propriété de root). L'outil ne voit pas le disque. Il liste maintenant les
pods non Ready posés sur des volumes rattachés au nœud que la règle par défaut a écartés, refuse de dire « nothing to clean », sort en 1 et affiche `task cluster-replaced-node-cleanup NODE=<nœud> -- --disk-replaced` (ajouter `--clean` pour l'exécuter).
`--disk-replaced` est la personne qui dit que le disque a été remplacé : tout volume rattaché au nœud compte comme celui de l'ancien disque, un pod Ready reste laissé et toutes les règles ci-dessus s'appliquent. `cluster-roll` affiche cette commande après
le remplacement d'un worker. Si le disque n'a PAS été remplacé, ces pods ont une autre cause : ne pas supprimer leurs volumes. Tests avec doublures seulement ; la recette affichée est celle faite à la main au lab 26 (tout sain environ une minute après).

**Critères de réussite en labo de ces changements.**

| Exercice | Réussite |
|---|---|
| Installation neuve, `coredns_ha` actif | trois pods `k8s-app=kube-dns` sur trois nœuds différents (`-o wide`), aucun Pending durable ; `kubectl get pdb -n kube-system coredns` admet 1 ; `cluster-verify` vert |
| Cluster mis à niveau depuis la 0.3.x, avant le patch unique | `cluster-verify` BAD « CoreDNS has 2 replica(s) ... declares 3 » ; après le patch trois pods sur trois nœuds, la ligne verte, recherches à 1 Hz depuis un troisième nœud pendant le déploiement : aucune n'échoue plus de 5 s |
| Worker (ou plan de contrôle) portant un réplica CoreDNS éteint 5 min, résolution à 1 Hz d'un nom de Service depuis un pod d'un troisième nœud plus l'écrivain de base | aucune résolution n'échoue pour de bon, et le plus long trou d'écriture qui n'est pas une bascule est d'au plus 30 s (287 s / 46 s avant) ; trois réplicas de retour dans les 15 minutes suivant le rallumage |
| Worker portant le primaire zitadel-db éteint et laissé éteint | le plus long trou d'écriture est d'au plus 75 s (environ 60 s attendu), un réplica promu dans les 45 s après le passage du nœud en Unknown, données identiques ; 30 s n'est pas revendiqué |
| Écrivain « zéro perte » (OpenAether-apps `docs/resilience.md`, « Zero-loss proof ») : 100 commits par seconde, une connexion neuve chacun, journal côté client des identifiants acquittés ; pod primaire tué, son worker éteint, son worker redémarré de force (`talosctl reboot --mode force`), sa zone éteinte ; puis une fois avec la réplication synchrone suspendue en témoin | après chaque passe avec réplication synchrone, **zéro identifiant acquitté absent** des lignes survivantes ; le trou d'écriture est relevé ; le témoin montre ce que la réplication asynchrone perd (ou qu'elle n'a pas reproduit de perte) |
| `cluster-replace-node` d'un worker mort portant une instance CNPG, un membre OpenBao, loki et vmselect | le nettoyage liste exactement les volumes de ce nœud créés avant le nouveau ; sans `--clean` rien n'est supprimé ; avec `--clean` chaque réplica est complet dans les 15 minutes suivant la commande sans `kubectl` manuel ; le primaire d'enregistrement et les volumes de tout autre nœud sont intacts (`kubectl get pv` avant et après) |

## Les exercices qui le prouvent (cloud, sondes à 1 Hz)

Sondes, comme au labo 15c : une requête HTTP par seconde depuis l'extérieur par le répartiteur public, la Gateway et une route servie par 3 pods ; un écrivain en base qui insère et relit chaque
seconde par une connexion neuve avec un identifiant d'exécution unique à chaque démarrage (une clé réutilisée a invalidé la première exécution du labo 15c) ; un écrivain RWX ; `/readyz` de l'API chaque
seconde par le répartiteur. Noter la plus longue série d'échecs consécutifs et le total. Objets jetables dans leur propre espace de noms. Noter la forme du cluster avec chaque mesure.

| Exercice | Faire | Réussite |
|---|---|---|
| Perte d'un worker | Extinction d'un worker par l'API du fournisseur pendant 5 minutes, puis rallumage | plus longue série d'échecs HTTP d'au plus 5 s et au plus 5 échecs au total (le labo 15c a mesuré 22 pour une perte de nœud, 9 pour un redémarrage brutal : si cela échoue, le répartiteur est le suspect suivant, #375), interruption d'écriture en base d'au plus 30 s, écrivain RWX revenu en 120 s, aucune différence de données (sommes de contrôle, nombres de lignes), `NodeUnreachable` se déclenche avec la commande nommée, tous les réplicas au complet dans les 15 minutes du rallumage |
| Perte d'un plan de contrôle | Extinction d'un plan de contrôle par l'API du fournisseur pendant 5 minutes | échecs HTTP 0, `/readyz` indisponible au plus 10 s au total, `ControlPlaneMemberMissing` se déclenche, etcd 3/3 et 3 apiservers après le rallumage |
| Perte de zone | Extinction de tous les nœuds d'UN domaine de défaillance (par l'API du fournisseur, tous ensemble) pendant 10 minutes, puis rallumage | `task failure-domain-check` était vert avant ; `FailureDomainLost` se déclenche en 3 minutes ; plus longue série d'échecs HTTP d'au plus 5 s ; `/readyz` au plus 10 s au total ; interruption en base d'au plus 30 s ; OpenBao 2 sur 3 descellés pendant et 3 sur 3 après ; aucune différence de données ; réplicas au complet dans les 15 minutes du rallumage |
| Remplacer un worker mort | Arrêt d'un worker chez le fournisseur, le laisser ; `cluster-node-state` dit `replace` ; `cluster-replace-node` | nœud Ready dans les 15 minutes de la commande, ses pods replanifiés, l'objet Node supprimé avant l'application (pods libérés tout de suite), CNPG et OpenBao au complet, aucune sonde client pire que l'exercice de perte d'un worker |
| Remplacer un plan de contrôle mort | Idem sur un plan de contrôle | l'examen passe avec un quorum, le membre etcd retiré avant l'objet Node, etcd 3/3 et 3 apiservers, `/readyz` indisponible au plus 10 s au total |
| Récupérer | `cluster-node-recover` sur un worker rendu muet avec `talosctl`, ou sur le prochain vrai #371 | un redémarrage forcé, Ready dans l'attente bornée ; tunnels fermés exprès, rien n'est redémarré |
| Barrière de déploiement | `task cluster-roll … -- --cp-only` avec la sonde `/readyz` | le journal montre la barrière apiserver entre chaque redémarrage de plan de contrôle ; plus longue série d'échecs `/readyz` d'au plus 5 s (#42 mesurait 5 à 8 s avant) |
| Alertes | pendant les exercices ci-dessus | chaque alerte s'est déclenchée dans sa fenêtre `for`, son texte nomme la commande, `AlertmanagerClusterDegraded` se déclenche pendant la perte du nœud portant un Alertmanager (`alertmanager_cluster_members` NE baisse PAS : il est resté à 2 sur le survivant au labo 21) |

## Mesuré au labo 21 (Scaleway, 3 plans de contrôle + 4 workers POP2-4C-16G, 2026-10-21, sondes à 1 Hz)

Plus longue série d'échantillons consécutifs en échec, et total, par exercice. Cibles : à-coup HTTP d'au plus 5 s, trou d'écriture base d'au plus 30 s.

| Exercice | HTTP (plus longue série / échecs) | `/readyz` en échec | Trou base | Verdict face aux critères |
|---|---|---|---|---|
| Worker éteint 5 min (3 fois, trois workers) | 1 s / 8-16 isolés | 0 | 0 s ; 287 s quand les deux réplicas coredns étaient sur le worker ; 328-333 s quand il portait le primaire | série <= 5 s tenue ; total <= 5 NON tenu (8-16) ; trou base NON tenu si le primaire ou le DNS est perdu ; réplicas au complet 113-122 s après le rallumage ; aucune différence de données |
| Worker redémarré sans drain | 1 s / 8 | 0 | 59 s (primaire sur ce worker) | idem |
| Plan de contrôle éteint 5 min / redémarré sans drain | 0 / 0 | 2 / 3 isolés | 46 s (un coredns dessus) / 0 | HTTP 0 et `/readyz` <= 10 s tenus ; trou base NON tenu quand le DNS perd la moitié de ses réplicas |
| `cluster-roll -- --cp-only` (17 min 34 s) | 0 / 0 | 66 isolés, série max 1 s | 0 | barrière apiserver visible entre les trois plans de contrôle ; série `/readyz` max 1 s (tenu ; #42 mesurait 5-8 s) ; la sonde TCP de 75 s du répartiteur coûte encore environ 22 échecs isolés par plan de contrôle |
| Zone éteinte 10 min, fr-par-3 | 1 s / 4 | 3 | 0 | tout tenu sauf `FailureDomainLost` à 3 min 11 s (`for: 1m` ; corrigé à 1 min 51 s) |
| Zone éteinte 10 min, fr-par-1 (deux workers, un plan de contrôle, grafana-db entièrement dedans) | 3 s / 15 | 2 | 36 s | `FailureDomainLost` 2 min 2 s ; OpenBao 2 sur 3 puis 3 sur 3 ; trou base NON tenu (DNS) ; pods Pending (CPU de la zone à deux workers) |
| Même zone après la répartition par zone des clusters CNPG et de l'opérateur | 2 s / 31 | 4 | 0 | tout tenu ; grafana-db a basculé en fr-par-2 |
| Remplacer un worker mort (`cluster-replace-node`, 260 s) | 1 s / 12 | 0 | 328 s (primaire dessus) | objet Node supprimé avant l'apply, Ready en 4 min 20 s ; deux instances CNPG en boucle de plantage sur le disque vide jusqu'à la suppression de leur PVC et pod (documenté, désormais VÉRIFIÉ) ; réplicas au complet 665 s après la commande |
| Remplacer un plan de contrôle mort (335 s) | 0 / 0 | 1 | 0 | état des lieux avec quorum, membre etcd retiré AVANT l'objet Node, etcd 3/3, 3 apiservers : tout tenu |
| `cluster-node-recover` | 1 s / 2 | 0 | 0 | un seul redémarrage forcé, Ready après 104 s ; tunnels fermés exprès, rien n'est redémarré (silence du kubelet simulé : aucune API Talos ne l'arrête) |

Ce que les exercices ont changé dans cette version : `NodeScrapeDown` et `FailureDomainLost` lisent la collecte du kubelet (kube-state-metrics était alors un seul pod, aveugle quand il était sur le nœud perdu, et la
condition Ready arrive 80 s après la perte ; il a deux réplicas maintenant, OpenAether-apps #156), `AlertmanagerClusterDegraded` compte les pods qui répondent, une préférence de zone sur les clusters CNPG et l'opérateur. Ce qu'ils n'ont pas changé : CoreDNS
(fourni par Talos, les deux réplicas sur un worker après l'installation), l'attente de 5 minutes avant de basculer un primaire de base sur un nœud perdu, la capacité de la zone à deux workers (`capacity.md`).
Chacun a un ticket ; les deux premiers ont des changements hors ligne, voir la section « DNS et délai d'éviction après le labo 21 » (non éprouvés).

## Mesuré au labo 22 (Scaleway, 3 plans de contrôle + 5 workers POP2-4C-16G, zones 2 + 2 + 1, 2026-10-22, sondes à 1 Hz)

Têtes : infra 4e84806 plus les correctifs ci-dessous, apps 71f2496 plus les siens. Échelon : **observé sur un cluster**, Scaleway seulement. Pas une déclaration de conformité.

| Exercice | Résultat | Contre le critère |
|---|---|---|
| Installation neuve, 5 workers | `cluster-verify` 15/15, Flux Ready, CoreDNS 3 pods sur 3 nœuds avec un budget de 1, kube-state-metrics 2 pods, `count(kube_node_info)` = 8, label de zone sur tous les nœuds ; `failure-domain-check` sortie 0 : `3 of 5 stay, requests 246% fit in 300%` (fr-par-1, fr-par-2), `4 of 5 stay, 246% in 400%` (fr-par-3) | tenu |
| Worker portant le primaire zitadel-db éteint 5 min (deux fois) | trou d'écriture 43,6 s (switchover, 41 s après l'appel) et 64 s (failover, `Failing over` 35 s après le passage NotReady) ; promotion 34 s et 15 s AVANT le passage Unknown (le kubelet publie NotReady à +1 s : l'extinction par le fournisseur est un arrêt propre de l'OS) ; données identiques | tenu (<= 75 s, attendu environ 60 s) |
| Idem, redémarrage non drainé | trou 57 s, HTTP 8 échecs isolés de 1 s (total au-dessus de 5, comme aux labos 15c / 21) | trou tenu, total HTTP NON tenu |
| Worker portant un réplica CoreDNS éteint 5 min, primaire ailleurs | plus long trou d'écriture 6 s (était 287 s) ; résolution à 1 Hz depuis un troisième nœud : 4 échecs, au plus 6 s ; un réplica de remplacement Ready 36 s après l'appel, trois réplicas tout du long | tenu |
| Pod kube-state-metrics tué, puis éteinte du worker portant l'autre | `NodeUnreachable` part (+300 s) ; `NodeScrapeDown` +240 s ; `NodeNotReady` (`for: 5m`) seulement pending, le nœud était revenu | tenu |
| Zone à deux workers (fr-par-1 puis fr-par-2) éteinte 10 min | aucun pod en attente faute de CPU (0 événement `Insufficient` ; les pods en attente étaient les DaemonSets des nœuds perdus et ceux dont le volume local-path s'y trouve) ; HTTP au plus 2 s / 1 s, `/readyz` 1-2 s, OpenBao 2 sur 3 puis 3 sur 3, données identiques, tous les réplicas pleins 177 s après le rallumage ; trou d'écriture BD **11 s quand le primaire était hors de la zone, 122 s quand il y était** | HTTP, `/readyz`, OpenBao, CPU tenus ; trou BD de 30 s NON tenu avec le primaire dans la zone |
| Remplacement d'un worker mort portant un réplica CNPG, OpenBao, loki et vmselect | `cluster-replace-node` 460 s ; la liste nomme exactement les quatre volumes de l'ancien disque, ne supprime rien sans `--clean` ; **`--clean` ne faisait rien au premier essai (défaut, corrigé ci-dessous)** ; avec le correctif tous les réplicas pleins 61 s après la commande, seuls les quatre volumes ont changé | tenu après correctif |
| Latences des alertes après l'extinction (grain d'évaluation 1 min) | `FailureDomainLost` 64 s, `NodeScrapeDown` 244 s, `ControlPlaneMemberMissing` 244 s, `NodeUnreachable` 304 s, `NodeNotReady` / `EtcdMemberDown` 364 s | |

Pourquoi la perte de zone avec le primaire dedans prend 122 s : le leader du kube-controller-manager était sur le plan de contrôle perdu. Le nouveau leader a démarré ses contrôleurs de cycle de vie des nœuds et d'éviction 37 s après la perte (bail de 15 s), la tolérance de 30 s a couru ensuite, CNPG a basculé à +89 s et promu à +120 s. Avec le leader vivant, la même éviction venait à +30 s. Leviers (non appliqués, une issue les porte) : des délais `leader-elect-*` plus courts pour le controller manager via Talos (risque : bascules de leader sous latence de l'API), ou rien et une limite annoncée d'environ 2 minutes pour un primaire de base de données dans une zone perdue.

Défauts trouvés et corrigés sur la branche : `scripts/ops/replaced-node-cleanup.py` affichait et lançait `kubectl delete pod NOM pvc CLAIM` (trois noms de pod : rien supprimé ; corrigé en `pod/NOM pvc/CLAIM`) et `kubectl delete pv` restait bloqué sur un volume encore lié (maintenant `--wait=false`) ; `oa_protect_bucket` déclarait « NOT fully protected » un bucket Outscale entièrement verrouillé parce que le fournisseur refuse de réactiver le versioning sur un bucket créé avec le verrouillage d'objet.

CoreDNS et Talos (observé) : un `coredns_image_tag` modifié est envoyé aux nœuds par `tofu apply` (8 nœuds, sans redémarrage, les sondes n'ont rien vu) mais le Deployment en cours **n'est pas** mis à jour par cela (6 minutes après : toujours l'ancien tag). `talosctl upgrade-k8s --dry-run` avec `coreDNS.disabled = true` liste Service, PDB, ConfigMap et RBAC `unchanged` et le Deployment `configured` avec un diff d'une ligne (l'image) : le nouveau tag est déployé par le prochain `upgrade-k8s`, qui ne recrée pas un CoreDNS de Talos et n'ignore pas le nôtre. À la main avant cela : `kubectl -n kube-system set image deployment/coredns coredns=registry.k8s.io/coredns/coredns:<tag>`. `tofu plan` après tous les exercices : aucun changement.

## Mesuré au labo 23 (Scaleway, 3 plans de contrôle + 5 workers POP2-4C-16G, 2026-10-22) : réplication synchrone, preuve de zéro perte

Têtes : infra 100c862 plus les correctifs du labo, apps 11c1096 plus les siens. Échelon : **observé sur un cluster**, Scaleway (cluster) et OVH (magasin de réplique et puits d'audit, seaux uniquement). Pas une revendication de conformité. Le tableau complet et la méthode sont dans OpenAether-apps `docs/resilience.md` (« Zero-loss proof »).

| Panne (deux écrivains sur `zitadel-db` et un Cluster du profil `ha`, plus un par le pooler ; identifiants acquittés après le COMMIT) | identifiants acquittés manquants | plus long trou d'écriture |
|---|---|---|
| suppression forcée des deux pods primaires | **0** sur 9519 / 7679 / 7624 | 32-36 s |
| extinction fournisseur du worker des primaires, 300 s | **0** sur 19048 / 15936 / 16482 | 40-60 s |
| `talosctl reboot --mode force` de ce worker | **0** sur 13724 / 10912 / 10851 | 61-63 s |
| extinction de la zone qui porte les deux primaires, 300 s (deux fois) | **0** (19698 / 15087 / 9825, puis 21773 / 15262 / 15388) | 112-120 s puis 50-80 s en direct ; **314,5 s une fois par le pooler PgBouncer** |
| les deux réplicas arrêtés 122 s, 330 s, 480 s | **0** | écrivains bloqués pendant toute la panne (aucun acquittement) ; `CnpgSyncReplicaMissing` en alerte à +274 s sur 480 s |
| un primaire et un réplica perdus ensemble, 300 s | **0** sur 18675 / 14126 / 14600 | pas de promotion (FailoverQuorum) : 353-375 s, jusqu'au retour des nœuds |

Témoin, réplication asynchrone : 0 manquant après une mort de pod (même sous un pgbench à 32 clients) et après un redémarrage forcé ; **817 sur 15916 et 1409 sur 16432 identifiants acquittés PERDUS** quand les deux réplicas étaient arrêtés puis que le nœud du primaire a été éteint, c'est la double panne que le réglage synchrone bloque. La réplication synchrone a coûté environ 25 % du débit d'écriture et 2,2 ms par validation entre zones (le guide OpenAether-apps « Profils de base de données »).

Ce que cela veut dire pour ce dépôt : la barre de 75 s pour une perte de nœud est tenue (40-63 s), celle de 30 s pour une perte de zone ne l'est pas (50-120 s, infra #390 reste), et une extinction de zone avec le chemin par le pooler a pris une fois 314,5 s (non expliqué : OpenAether-apps #158). Les résultats du puits (infra #318) du même labo sont dans `docs/audit-sink.fr.md`, section 10.

## PAS VÉRIFIÉ

Vérifié au labo 21 (Scaleway) : deux opérateurs CNPG dont un tient le bail, l'élection de leader du contrôleur ESO, deux contrôleurs d'admission Kyverno, `kube_node_role`, l'étiquette de zone de
`kube_node_labels` et `alertmanager_cluster_members` comme séries, le gossip d'Alertmanager à travers la politique réseau (2 membres), `machine.nodeLabels` appliqué à un nœud en marche sans
redémarrage (l'étiquette de zone est sur chaque nœud dès le premier démarrage), les appels Scaleway `state` et `hard-reboot` de `node-provider.py`, et ce dont une instance CNPG sur un disque
remplacé a besoin (sa PVC et son pod supprimés, puis un clone en moins d'une minute).

Reste PAS VÉRIFIÉ :

- Les appels OVH et Outscale de `node-provider.py` (OVH suit le script de purge existant), et que le placement Outscale soit connu au plan.
- Qu'un membre OpenBao dont le volume local-path était sur un disque remplacé rejoigne ses pairs raft (les exercices ont perdu des zones, qui rendent leurs disques).
- Une vraie machine « qui tourne mais ne répond plus » (OVH #371) : simulée ici en forçant la condition Ready.
- Le comportement de Longhorn avec l'attente de réplication par défaut (10 minutes) après une perte de nœud ; l'alerte « moins de deux réplicas sains » est
  `LonghornVolumeDegraded` (Longhorn n'exporte pas de nombre de réplicas).
- Abaisser la tolérance de 5 minutes pour tous les pods (kube-apiserver `--default-not-ready-toleration-seconds` et `--default-unreachable-toleration-seconds`) : non fait, cela touche l'éviction de tous les pods.
  Seuls les deux Clusters CNPG et CoreDNS portent une tolérance de 30 s (voir la section sur le DNS ci-dessus) ; le `node-monitor-grace-period` de `kube-controller-manager` n'est pas touché.
- Les changements hors ligne après le labo 21 (manifeste inline de CoreDNS, la tolérance CNPG de 30 s, le nettoyage après remplacement, kube-state-metrics à deux réplicas, la préférence de zone) : rien n'a tourné sur un cluster.
- Tout sur OVH et Outscale : rien de ceci n'y a tourné.
