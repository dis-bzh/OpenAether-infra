🇬🇧 [English version](resilience.md)

# Perdre un nœud, un plan de contrôle ou une zone : ce qui survit, ce que vous lancez, comment c'est prouvé

Version 0.4.0, jalon M4. Niveau de preuve de tout ce qui suit : **simulé/statique** (tests avec doublures, manifestes rendus, tests unitaires des règles d'alerte). Rien
n'a encore été éprouvé sur un cloud : les exercices qui le prouveront sont à la fin, avec leurs critères de réussite, et la liste de ce qui n'est PAS VÉRIFIÉ suit le
premier tableau. Pas une déclaration de conformité.

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
| Disponibilité | 99,9 % | idem |

## Pourquoi un pod d'un nœud mort n'est pas replanifié tout de suite

Kubernetes n'évince les pods d'un nœud qui ne répond plus qu'après la tolérance de 5 minutes (non prêt / injoignable) qu'il ajoute à chaque pod. Une charge à deux
réplicas sur deux workers continue de servir entre-temps ; une charge à un seul réplica est arrêtée pendant ces 5 minutes plus la replanification. L'audit des briques de la
plateforme (OpenAether-apps, `scripts/check-ha.py`, en CI) exige donc, pour chaque Deployment et StatefulSet : deux réplicas, une répartition par hôte, exactement un
PodDisruptionBudget qui autorise exactement une perturbation, rien qui puisse bloquer un pod sur trois workers ; et une **liste motivée**
(`scripts/ha-allowlist.yaml`) de ceux qui restent seuls, avec ce que leur perte signifie. Supprimer l'objet Node d'une machine disparue libère ses pods immédiatement au
lieu de 5 minutes : `task cluster-replace-node` le fait.

La perte d'un worker ou d'une zone demande de la marge : les requêtes CPU des workers doivent tenir sur les workers qui restent. Les exemples livrés 3 x 4 vCPU
passaient `cluster-roll` avec environ 0,8 vCPU de reste (`capacity.md`, dérivé du labo 16) ; le travail HA du M4 ajoute environ 345 m de requêtes CPU (dérivé des
manifestes : admission Kyverno, opérateur CNPG, contrôleur et webhook ESO, metrics-server, la page de connexion Zitadel, le second Alertmanager), ce qui laisse environ 0,45 vCPU.
La barrière de `task cluster-roll` le dit avant de toucher à quoi que ce soit ; `ClusterCannotLoseWorker` le dit pendant que le cluster tourne.

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

L'état est sauvegardé ensuite, comme le fait `cluster-roll`. Cela efface le disque système du nœud et les données local-path qu'il portait (membre raft OpenBao, une
instance CNPG, un réplica de stockage VictoriaMetrics), que les pairs reconstruisent. Une instance CNPG dont le volume était sur le disque mort peut rester Pending :
supprimez son pod et son PVC et laissez CNPG la cloner (PAS VÉRIFIÉ en exercice ; le script affiche l'indication).

Jamais : `tofu destroy` ou `tofu apply -replace` à la main sur plus d'un nœud ; supprimer l'objet Node d'un plan de contrôle avant que son membre etcd soit parti ;
`task cluster-roll` pendant qu'un nœud est tombé (ses barrières refusent) ; supprimer le PVC d'un pod dont le nœud est seulement injoignable.

## Déploiement des plans de contrôle : le battement de l'API (#42)

Déploiement avec transfert du leadership avant le dernier plan de contrôle (existant) et désormais une **barrière apiserver** : après le redémarrage d'un plan de contrôle,
le déploiement attend que son pod statique kube-apiserver soit Ready et que `/readyz` réponde, trois relevés de suite, avant de le remettre en rotation, et refuse
d'arrêter un plan de contrôle si tous les apiservers ne servent pas. etcd 3/3 et un nœud Ready ne le disaient pas, et la sonde TCP du répartiteur de charge garde un
apiserver non prêt en rotation jusqu'à 75 s (5 sondes x 15 s). La barrière est prouvée hors ligne avec un kubectl factice ; savoir si elle supprime le battement de 5 à 8 s demande le
déploiement réel ci-dessous.

**Décision du propriétaire nécessaire, non prise ici** (elle change ce qui est exposé) : faire sonder `/readyz` en HTTPS par les répartiteurs au lieu de TCP 6443, et donner à
kube-apiserver `--shutdown-delay-duration` pour qu'il devienne non prêt avant de s'arrêter. La première exige que `/readyz` réponde sans identifiants, donc un accès anonyme aux
points de santé (`anonymous-auth` ou une configuration d'authentification structurée limitée à `/livez`, `/readyz`, `/healthz`), que les clusters n'activent pas aujourd'hui et qu'il faut
d'abord vérifier sur un nœud Talos (#42 le dit aussi). La seconde est un changement de configuration machine Talos sur chaque plan de contrôle. Aucune n'est utile sans l'autre.
Tant que ce n'est pas décidé, les sondes TCP et la barrière sont ce qui existe.

## Perte de zone

Hypothèses de placement : les plans de contrôle sont répartis sur trois domaines de défaillance (vérifié par `cluster-verify`, #38) et les workers aussi (`worker_zones`, nouveau : où le
fournisseur a placé chaque worker). Chaque nœud porte désormais l'étiquette `topology.kubernetes.io/zone` posée depuis ce placement (Talos `machine.nodeLabels`, appliquée au prochain
`infra-apply` sans redémarrage). Avec 3 plans de contrôle et 3 workers sur 3 domaines, perdre un domaine laisse 2 plans de contrôle (quorum etcd), 2 workers, 2 membres OpenBao sur 3, une
instance de chaque base et un réplica de chaque volume.

`task failure-domain-check PROVIDER=…` calcule cela pour chaque domaine à partir de l'état et du cluster et sort en code 1 quand une perte arrêterait quelque chose. Un pod Gateway unique, une base
dont les instances partagent un domaine, des workers dont les requêtes ne tiennent pas sur ceux qui restent, sont nommés. C'est aussi la première chose à lancer quand `FailureDomainLost` se déclenche.

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
| Alertes | pendant les exercices ci-dessus | chaque alerte s'est déclenchée dans sa fenêtre `for`, son texte nomme la commande, `alertmanager_cluster_members` valait 2 avant et 1 pendant la perte du nœud portant un Alertmanager |

## PAS VÉRIFIÉ

- Deux réplicas de l'opérateur CNPG, du contrôleur ESO (option d'élection de leader) et de l'admission Kyverno sur un cluster ; `kube_node_role`, l'étiquette de zone de
  `kube_node_labels` et `alertmanager_cluster_members` comme séries ; le bavardage (gossip) d'Alertmanager à travers la politique réseau.
- Qu'un nœud Talos accepte `topology.kubernetes.io/zone` par `machine.nodeLabels`, et que le placement Outscale soit connu au plan.
- Les appels Scaleway et Outscale de `node-provider.py` (écrits d'après la documentation des API ; OVH suit le script de purge existant).
- Que les volumes local-path d'un nœud reconstruit se rattachent proprement (OpenBao) et ce dont une instance CNPG sur un disque perdu a besoin.
- Le comportement de Longhorn avec l'attente de réplication par défaut (10 minutes) après une perte de nœud ; l'alerte « moins de deux réplicas sains » est
  `LonghornVolumeDegraded` (Longhorn n'exporte pas de nombre de réplicas).
- Abaisser la tolérance de 5 minutes (kube-apiserver `--default-not-ready-toleration-seconds` et `--default-unreachable-toleration-seconds`) accélérerait la
  replanification des pods à un seul réplica : non fait, car cela change l'éviction de tous les pods et n'a pas été mesuré.
