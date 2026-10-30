> 🇬🇧 [English version](capacity.md) — la version anglaise fait foi.

# Capacité par provider

Ce qu'un cluster consomme, par provider, avant de le déployer. Les modules sous
`infrastructure/opentofu/modules/providers/` font autorité ; cette page est leur
arithmétique appliquée aux `envs/*.tfvars.example` livrés.

Chaque chiffre est **déduit** de ce code sauf s'il est marqué **mesuré**, avec
l'endroit où le dépôt consigne la mesure. vCPU/RAM par type viennent du nommage
ou du catalogue du provider (Outscale `tinavX.cNrM` = N vCPU, M Go), pas d'un
run.

## Plancher de dimensionnement

| Règle | Preuve |
|---|---|
| Les workers doivent laisser libre l'équivalent d'un nœud en requests CPU, sinon aucun drain n'aboutit et `rolling-replace --upgrade` bloque. | **Mesuré** le 2026-08-15, plateforme applicative en place : 3× Scaleway `DEV1-L` (4 vCPU / 8 Go) à 72/47/27 %, tous les drains sont passés ; 3× OVH `b3-8` (2 vCPU / 8 Go) à 78/99/100 %, aucun. [`upgrade.fr.md`](upgrade.fr.md) |
| Workers ≥ 8 Go de RAM. | Énoncé dans `modules/providers/proxmox/variables.tf` (un OOM sur `DEV1-M`) ; le run correspondant n'est pas consigné. |
| HA = 3 control planes (quorum etcd) ; non-HA = 1 + 1, control plane taché `NoSchedule`. | Code. |

Le plancher d'un cluster qui portera la plateforme est donc **des workers d'au
moins 4 vCPU / 8 Go, assez nombreux pour en perdre un**. Chaque module cloud
prend un seul type d'instance pour control planes et workers : le plancher vaut
pour les deux. Un cluster nu (Cilium seul, le périmètre de la 0.2.0) demande
moins : un 3+3 nu sur le `tinav5.c2r4p1` d'Outscale (2 vCPU / 4 Go) a été déployé et vérifié le 2026-10-03, seul point mesuré.

## Ce que crée chaque provider

Par défaut : `k8s_lb_mode = "managed"`, `deploy_app_lb = false`. CP / W =
control planes / workers, D = entrées de `worker_storage.disks`.

| | Scaleway | OVH | Outscale | Proxmox |
|---|---|---|---|---|
| Instances | CP+W + bastion `DEV1-S` (2 vCPU / 2 Go) | CP+W + bastion `b3-8` (2 vCPU / 8 Go) | CP+W + bastion `tinav5.c2r2p2` (2 vCPU / 2 Go) | CP+W ; + bastion (1 vCPU / 1 Gio / 10 Gio) seulement avec `enable_bastion` |
| Disque système | 50 Go `sbs_volume` chacun (`scw_root_volume_size_gb` ; 40 au moins avec `deploy_flux`, imposé) | celui du flavour (50 Go au moins ; un `check` avertit sous 40) | celui de l'OMI (~11-12 Gio) : `outscale_root_volume_size_gb = 50` (un `check` avertit) ; type `io1` 1500 IOPS par défaut (`outscale_root_volume_type`, `outscale_root_volume_iops`) | `root_disk_gb` (50 Gio) chacun (un `check` avertit sous 40) |
| Volumes de données | W × D | W × D | W × D | W × D, sur `datastore_id` |
| IP publiques | 3 : bastion, public gateway, LB de l'API | 2 flottantes : bastion, LB de l'API | 2 : bastion, NAT | aucune — `host_public_ip` est la tienne |
| Load balancers | 1 | 1 (Octavia) | 1 (LBU) | aucun — VIP Talos |
| Security groups | 1 par entrée de `zones` + 1 bastion | 2 | 2 | aucun |
| Réseau | 1 réseau privé, 1 public gateway | 1 réseau, subnet, routeur | 1 Net, 2 subnets, internet + NAT service | ton bridge ; CP+W + 1 VIP en IP statiques dans `network_cidr` |

`deploy_app_lb = true` ajoute un LB et une IP publique sur chaque cloud.
`k8s_lb_mode = "vip"` (OVH ; expérimental sur Scaleway) remplace le LB de l'API
et son IP par une adresse privée.

**Limite connue (Scaleway) : deux clusters ne peuvent pas coexister dans un même projet.** Le sous-réseau du cluster est fixé dans le module (`scw_cluster_subnet = "172.16.0.0/22"`, `modules/providers/scw/network.tf`, pour que la règle de maillage de `security.tf` ne puisse pas s'en écarter, #79) et n'est pas une variable. Les deux réseaux privés tombent dans le VPC par défaut du projet, et un second cluster échoue à son réseau avec `subnet_overlaps_in_vpc` (labo 27 séance 3, en construisant un cluster jetable pour la restauration etcd à côté du principal ; le cluster jetable a dû être construit après la destruction du principal). Utiliser un projet Scaleway par cluster, ou détruire le premier ; l'adressage n'a pas été modifié. Faire du CIDR une variable oblige aussi le pare-feu des nœuds, les plages des ACL et les tests qui portent `172.16.0.0/22` à le suivre : c'est un changement à part, pas fait ici. OVH (`10.0.0.0/24`) et Outscale fixent leurs adresses de la même façon ; la coexistence de deux clusters chez eux dépend du réseau que chacun crée et n'a pas été testée.

## Les exemples livrés

Totaux bastion compris. `preflight-quotas` vérifie instances, vCPU et RAM, sur
OVH et Outscale seulement — la dernière colonne est ce qu'on lui passe. Aucun
script ne vérifie IP, LB ni security groups.

| Exemple | Nœuds × type (vCPU / RAM) | Inst. | vCPU | RAM | Au plancher ? | `task preflight-quotas PROVIDER=… --` |
|---|---|---|---|---|---|---|
| `management-`, `failover-scaleway` | 3+4 × `POP2-4C-16G` (4 / 16 Go) | 8 | 30 | 114 Go | Oui ; déroulable, voir le calcul plus bas | pas de backend Scaleway |
| `workload-scaleway` | 3+4 × `POP2-4C-16G` | 8 | 30 | 114 Go | Oui | pas de backend Scaleway |
| `management-`, `failover-ovh` | 3+4 × `c3-8` (4 / 8 Go) | 8 | 30 | 64 Go | Oui ; déroulable, voir le calcul plus bas | `--add-vms 8 --add-cores 30 --add-ram-gb 64` |
| `workload-ovh` | 3+4 × `c3-8` | 8 | 30 | 64 Go | Oui | `--add-vms 8 --add-cores 30 --add-ram-gb 64` |
| `management-`, `failover-outscale` | 3+2 × `tinav5.c2r4p1` (2 / 4 Go) | 6 | 12 | 22 Go | **Non, volontairement** — voir plus bas | `--add-vms 6 --add-cores 12 --add-ram-gb 22` |
| `workload-outscale` | 3+3 × `tinav5.c2r4p1` | 7 | 14 | 26 Go | **Non, volontairement** | `--add-vms 7 --add-cores 14 --add-ram-gb 26` |
| `*-proxmox` | 1+1 × 4 vCPU / 8 Gio, disque 20 Gio | 2 | 8 | 16 Gio | Type oui ; un seul worker ne se draine pas sans coupure | capacité de l'hôte, pas un quota |

À noter aussi sur les exemples :

- **Pourquoi les exemples Outscale restent sous le plancher.** Le quota par défaut du compte est de
  20 vCPU / 40 Go. Le module prend un seul type pour tous les nœuds : le plancher (4 vCPU / 8 Go) sur
  5 nœuds plus le bastion fait 22 vCPU, ce qui ne tient pas. Un cluster nu (Talos + Cilium) a été
  déployé et vérifié en `tinav5.c2r4p1` à 3+3 le 2026-10-03 ; porter la plateforme là demande
  d'abord un quota plus haut.
- L'ancien exemple `workload` de Scaleway utilisait `DEV1-M`, un type à SSD local, alors que le
  module demande toujours une racine `sbs_volume`, et ses `zones` incluent
  `fr-par-3`, où le commentaire de l'exemple management dit que `DEV1-M` n'est
  pas proposé. Aucun run n'est consigné.
- **Mesuré** sur Outscale : 3+3 en `tinav5.c2r7p2` ne tient pas dans le quota
  de RAM du compte de test et `preflight-quotas` le refuse ; le 3+1 qui tient se
  déploie mais n'a qu'un worker schedulable
  ([`deployment-test-matrix.fr.md`](deployment-test-matrix.fr.md), `OSC-mgmt-ha` ;
  issue #72). Un chemin vers le plancher dans ce quota n'est pas testé, et
  Outscale change `vm_type` par un stop/start — un nœud à la fois.
- Les runs sur cloud réel de [`status.md`](status.md) ne consignent le type d'instance
  que pour Outscale (`tinav5.c2r4p1`) : ceux de Scaleway et d'OVH n'établissent aucun plancher.

## Le cluster peut-il perdre un worker, et être déroulé ? (infra #378)

`cluster-roll` refuse de démarrer quand les requêtes CPU (et, depuis le labo 27 partie B, F-SHRINKMEM, les requêtes mémoire : `worker_memory_requests`, la même borne ; `cluster-shrink-plan` aussi) de tous les workers, chacune en pourcentage de son propre nœud, dépassent
(workers - 1) x 100 % : la charge demandée d'un nœud doit tenir sur les autres (`worker_cpu_requests` / `preflight_roll`,
`scripts/lib/roll-gates.sh`). **Mesuré** au lab 16, pile applicative complète, cluster de management, requêtes en % du CPU allouable d'un worker :

| Profil (tel que livré avant) | Workers | Demandé | Limite | Verdict |
|---|---|---|---|---|
| Scaleway 3+2 `POP2-4C-16G` | 82 % + 90 % | 172 % | 100 % | refusé |
| OVH 3+2 `c3-8` | 81 % + 91 % | 172 % | 100 % | refusé |
| Outscale 3+3 `tinav5.c3r6p2` (3 vCPU) | 239 % au total | 239 % | 200 % | refusé |

Calcul (dérivé de ces chiffres, en prenant l'allouable d'un worker à peu près égal à son nombre de vCPU) : sur 4 vCPU, 172 % font environ
6,9 vCPU au total ; sur 3 vCPU, 239 % font environ 7,2 vCPU. Les requêtes valent donc à peu près 6,3 vCPU de déploiements fixes plus 0,3 vCPU
de DaemonSets par worker (estimation à partir de deux points, pas une mesure de chacun). Avec n workers de 4 vCPU, la porte exige
6,3 + 0,3n <= 4(n - 1) : n = 3 donne 7,2 contre 8 (environ 90 % de la limite, 180 % contre 200 %) ; n = 4 donne 7,5 contre 12. Les exemples
Scaleway et OVH livraient donc 3 workers jusqu'à la 0.4.0 (ils en livrent **4** maintenant, voir plus bas : la charge mesurée de la plateforme complète l'exige). La marge à 3 est mince : une pile plus lourde peut la rompre, et la porte le dit avant de toucher quoi que ce soit.
Ce n'est que la porte CPU : les réplicas à répartition obligatoire (les trois pods OpenBao, par exemple) restent incomplets pendant qu'un worker est
absent, et le comportement de la perte d'un nœud sous charge relève de la 0.4.0 (résilience), pas de ce tableau.

**0.4.0 (M4) : dérivé d'abord, puis mesuré (labo 21).** Le travail de haute disponibilité ajoute environ 345 m de requêtes CPU à la plateforme (un second contrôleur d'admission Kyverno,
l'opérateur CNPG, le contrôleur et le webhook ESO, metrics-server et la page de connexion Zitadel, et un second Alertmanager). La dérivation (6,3 vCPU fixes + 0,345 + 0,3 par worker) donnait
7,55 vCPU sur 3 workers (marge 0,45 sur 8) et 7,85 sur 4. **Le labo 21 a mesuré** (Scaleway, 4 x `POP2-4C-16G`, la plateforme complète et trois petites sondes) : 9095 m = 228 % d'un worker juste
après la convergence de Flux, 223-224 % ensuite (53/43/70/57 % par worker), et l'état des lieux de `cluster-roll` a affiché `223% requested, 300% available without one worker`. La dérivation
sous-estimait d'environ 1,2 vCPU. Conséquences : sur 3 workers la charge mesurée (environ 9 vCPU) dépasse les 8 vCPU que la barrière laisse, donc **3 workers seraient refusés** ; la décision du
propriétaire du 2026-10-21 de livrer **4 workers de 4 vCPU** sur Scaleway et OVH est le minimum pour la plateforme complète, pas une marge. 4 workers passent à 74-76 % de la limite de la barrière
(environ 2,9 vCPU de reste). Les Deployments et StatefulSets que le dépôt applicatif rend demandent 3005 m (`python3 scripts/check-ha.py`, budget 3300 m) ; le reste est les DaemonSets, les
opérateurs et les Jobs, qu'aucun rendu ne montre. `task failure-domain-check` applique la même arithmétique à la perte d'une zone entière, et là quatre workers n'aident pas le pire cas : ils se
répartissent 2 + 1 + 1 sur trois zones, donc perdre la zone qui en porte deux laisse deux workers (200 %) pour 224 % de requêtes, environ 1 vCPU de moins ; le contrôle le dit, et le labo 21 a perdu
cette zone 10 minutes (deux fois) : rien ne s'est arrêté, mais des pods sont restés Pending jusqu'au retour de la zone. Cinq workers (2 + 2 + 1 : en perdre deux laisse 300 %) ou six tiendraient sur
le papier (voir les résultats du labo 21 pour ce que le cinquième a donné), comme environ 12 % de requêtes en moins. Ce que les exemples livrent a été décidé le 2026-10-21 (ci-dessous).

**0.4.0 (règle du propriétaire du 2026-10-22, aucun commit acquitté perdu) : une instance de base de plus.** Les deux bases CNPG se répliquent désormais de façon synchrone (OpenAether-apps `docs/resilience.md`, « Data classes »), et `grafana-db` passe de 2 à 3 instances pour que la perte d'un réplica ne bloque pas les écritures.
Le pod ajouté demande 100 m de CPU (50 m l'instance + 50 m le sidecar Barman Cloud), 384 Mi de mémoire et 5 Gi de stockage `local-path`. L'audit du dépôt applicatif (`python3 scripts/check-ha.py`) ne comptait pas les pods CNPG (ce ne sont pas des Deployments) : il les affiche maintenant, 600 m pour six instances (500 m avant), à côté des 3015 m inchangés des Deployments et StatefulSets.
Dérivé de la mesure du labo 21 (9095 m = 228 % d'un worker, donc un worker fait environ 3990 m) : +100 m font environ +2,5 points, donc les exemples à 4 workers demandent environ 226-231 % (labo 21/22 : 224-228 %) pour 300 %, soit **75-77 % de la limite du garde-fou, toujours accepté** (74-76 % avant) ; le profil à 5 workers environ 246-250 % pour 400 %. Le budget de l'audit applicatif ne bouge pas (3300 m pour les Deployments et StatefulSets), les pods CNPG ont le leur (600 m). La zone à deux workers n'est **pas** aidée : 200 % pour environ 228-231 % laisse environ 1,1-1,2 vCPU de requêtes non plaçables (environ 1,0 avant), même verdict que ci-dessous. 3 workers restent refusés. Rien n'a été mesuré après le changement ; le prochain labo lit le chiffre réel avec le relevé de `cluster-roll`.

### Ce que les 4 workers livrés supportent, et ce qu'ils ne supportent pas (décision du 2026-10-21, infra #389)

Les exemples Scaleway et OVH livrent **4 workers**, placés en tourniquet sur trois zones, donc 2 + 1 + 1. Dit sans détour :

| Perte | Supportée ? | Pourquoi (charge mesurée : 223-228 % d'un worker, environ 9 vCPU, labo 21) |
|---|---|---|
| Un worker (drain, redémarrage, panne) | **Oui** | 3 workers = 300 % pour 224 % demandés ; `cluster-roll` passe à 74-76 % de sa limite |
| Une zone qui porte un seul worker (l'une ou l'autre) | **Oui** | 3 workers restent, 300 % pour 224 % |
| **La zone qui porte deux workers** | **Non** | 2 workers restent = 200 % pour 224 % : environ 1 vCPU de requêtes ne peut pas être placé et des pods restent Pending jusqu'au retour de la zone (le labo 21 a perdu cette zone 10 minutes, deux fois : rien ne s'est arrêté, des pods sont restés Pending). `task failure-domain-check` la signale comme une perte refusée |

Les control planes ne sont pas concernés : trois dans trois zones gardent un quorum etcd à la perte de n'importe quelle zone.

### Profil « 5 workers zone-HA » (2 + 2 + 1)

Mettre `workers = 5` dans l'exemple management de Scaleway ou d'OVH (un bloc commenté de chaque `envs/management-*.tfvars.example` le dit) ; rien d'autre ne change.
Les modules placent les workers en tourniquet sur la liste de zones (`element(zones, index)`) : cinq tombent en 2 + 2 + 1 et **n'importe quelle zone** peut être
perdue : la perte la plus défavorable retire deux workers et en laisse trois (300 %). La charge croît d'environ 0,7 vCPU par worker ajouté (DaemonSets ; le labo 21 avait dérivé 0,3) : cinq
workers demandent 243 à 247 % d'un worker (mesuré au labo 22 avec toute la plateforme et les sondes du labo ; quatre workers : 224-228 %), largement sous 300 %.

`task failure-domain-check PROVIDER=<scaleway|ovh>` (lecture seule, demande l'état déployé) donne le verdict attendu :

| Workers | Zones | `If <zone> is lost` | Verdict |
|---|---|---|---|
| 4 (livré) | 2 + 1 + 1 | la zone à deux : `workers: 2 stay, but the workers request 224% of a node and 2 hold 200%` | sortie 1 pour cette zone ; les deux autres passent |
| 5 | 2 + 2 + 1 | `workers: 3 of 5 stay, requests 246% fit in 300%` pour les zones à deux workers ; 4 sur 5 pour l'autre | sortie 0, toute perte est supportable |

Labo 23 (grafana-db à 3 instances, le puits d'audit et les récepteurs sur la même forme à 5 workers) : `requests 249% fit in 300%` pour les zones à deux workers (labo 22 : 246 %) ; avec les trois profils de base de données du labo ajoutés (un `ha`, un `standard` et un `light` : 1,1 + 0,6 + 0,1 vCPU de requêtes) **294 %**, encore sous la barre. Le contrôle nomme aussi une base client qui perdrait ses données : il a signalé le profil `light` à une seule instance pour la perte de sa zone.

**Labo 27 (Scaleway, 5 workers 2 + 2 + 1) : le forge optionnel et trois exemples de base de données ne tiennent pas une perte de zone.** Avec la brique Forgejo activée et les trois exemples de profil (`ha`, `standard`, `light`), `task failure-domain-check` a affiché `workers: 3 stay, but the workers request 313% of a node and 3 hold 300%: pods stay Pending` pour fr-par-1 et fr-par-2, les deux zones à deux workers. Soit **313 % demandés pour les 300 % que tiennent trois workers** (13 points : environ un demi-vCPU de requêtes qui ne peut pas être placé, pods en Pending jusqu'au retour de la zone, comme le cas à 4 workers ci-dessus). Le forge est dérivé à +400 m de CPU demandé (environ +10 points d'un worker, docs/forgejo du dépôt apps), au-dessus des 294 % du labo 23 avec les trois profils ; les 313 % sont ce que le contrôle a lu sur le cluster, la part du forge n'est pas mesurée. Sans le forge (294 %) chaque zone passe l'arithmétique, avec lui les deux zones à deux workers échouent. Choix, aucun livré par défaut : éteindre le forge, retirer un exemple de profil, ou six workers (2 + 2 + 2 : une perte de zone laisse 400 %). La brique est optionnelle à cause de ce genre de coût ; l'installation par défaut ne change pas.

Le test `scripts/dev/test-failure-domain-check.sh` exécute les deux formes contre des `tofu` et `kubectl` factices. Il prouve l'arithmétique du contrôle ; la forme elle-même a été éprouvée au labo 22 (Scaleway) : chacune des deux zones à deux workers a été éteinte
10 minutes avec son plan de contrôle, aucun pod n'est resté en attente faute de CPU (les pods en attente étaient les DaemonSets des nœuds perdus et ceux ayant un volume local sur place),
HTTP et `/readyz` ont tenu ; un primaire de base de données dans la zone perdue coûte environ 2 minutes d'écriture (`resilience.fr.md`). Coût : une instance de plus et 4 vCPU (et le quota correspondant) par cloud. Outscale n'est
pas couvert (ses exemples sont sous le plancher, voir plus haut).

Outscale (les exemples sont inchangés et restent dans le quota de 20 vCPU) : aucune forme ne tient dans le quota par défaut de 20 vCPU et passe la porte. 3 workers de 3 vCPU échouent (ci-dessus), et 4 workers de
3 vCPU demandent 3 + 4 nœuds x 3 + 2 (bastion) = 23 vCPU. La plus petite forme qui passe sur le papier est 3+3 `tinav5.c4r8p2` (4 vCPU / 8 Go) : 26 vCPU
avec le bastion (mince, voir le paragraphe 0.4.0 ci-dessus), et la forme 3 + 4 des autres clouds fait 30 vCPU, donc une hausse de quota d'abord. Aucune n'a été exécutée sur Outscale. Les nœuds de 6 Go du lab 16 sont aussi tombés dans une cascade
d'E/S et de mémoire après une sauvegarde-restauration et un redémarrage drainé (#376) ; le volume racine était gp2 (type non configurable alors), et un passage
manuel en `io1 3000` ne l'a pas arrêtée. L'exemple fixe maintenant `outscale_root_volume_size_gb = 50` au lieu de le laisser en commentaire. Le type est une variable depuis le labo 27 partie C (ci-dessous).

## Forme minimale supportée par provider, et le quota Outscale (labo 27 partie C, E3)

La plateforme (le dépôt apps à son défaut) demande environ **9 vCPU de requests** (8,7 mesurés au labo 27 partie C sur 3 CP + 3 W de 3 vCPU : les workers étaient à 97-99 % de leur CPU allouable). Un drain, un `cluster-roll` ou une perte de nœud exige que les workers MOINS UN les tiennent, sinon des pods restent Pending (12 l'ont été, dont un pod Gateway et la place qu'un failover de base demande). La forme supportée, sur tous les clouds, est donc :

| Provider | Forme supportée avec la plateforme | vCPU avec le bastion | Note |
|---|---|---|---|
| Scaleway | 3 CP + 4 W de `POP2-4C-16G` (les exemples) | 30 | déroulable, voir l'arithmétique ci-dessus |
| OVH | 3 CP + 4 W de `c3-8` (4 vCPU / 8 Go) (les exemples) | 30 | déroulable, voir l'arithmétique ci-dessus |
| Outscale | 3 CP + 4 W de `tinav5.c4r8p2` (4 vCPU / 8 Go) | 30 | **demande d'abord une hausse de quota** (30 vCPU / 64 Go, 8 VM) |
| Proxmox | 3 CP + 4 W, 4 vCPU / 8 Go au moins | à vous | |

**Ce que permet le quota Outscale par défaut (mesuré, labo 27 partie C : 20 vCPU, 10 VM, 20 IP publiques, 100 volumes, 20 load balancers).** Un cluster nu (Cilium seul) tient. 3 CP + 3 W de `tinav5.c3r8p2` (3 vCPU / 8 Go) plus le bastion (2 vCPU) font exactement 20 vCPU, 7 VM : il s'installe, `cluster-verify` passe, 41 Kustomizations étaient Ready 20 min après `cluster-up`, et une perte brutale de nœud a gardé chaque commit acquitté, mais ce n'est PAS une forme supportée : aucun drain ne finit sans pods Pending, `cluster-roll` refuse (sa règle des 200 % ne passe pas), rien ne peut être remplacé (un nœud de rechange ne tient pas dans le quota), aucun second cluster ne tient (ni restauration d'essai, ni répétition d'un roll Talos), et une perte de nœud a mis 924 s à redonner un cluster entier (OVH : 155 s). Rien dans le code ne le cache : un `check` (`outscale_platform_shape`) avertit au plan quand `deploy_flux` est actif et que les workers moins un tiennent moins de 9 vCPU, et les exemples le disent dans leurs commentaires. Demandez le quota d'abord ; ne lancez pas la plateforme sur le quota par défaut en espérant que les exercices de panne passent.

**Type du volume racine Outscale (E3).** `gp2` donne 3 IOPS par Gio : la racine de 50 Go faisait **150 IOPS**, et containerd, le kubelet et les reconstructions Longhorn étaient affamés (`CRI DeadlineExceeded`, un worker NotReady deux fois dans une séance). `outscale_root_volume_type` est maintenant une variable, défaut **`io1`** avec `outscale_root_volume_iops = 1500` (dix fois plus ; l'API autorise 300 IOPS par Gio au plus et 13000 en tout, un `check` avertit sur le couple). `gp2` garde l'ancien comportement (l'épingler dans le tfvars) ; `standard` est magnétique et déconseillé. Effets, aucun mesuré : io1 est facturé pour le volume ET les IOPS provisionnées, chaque nœud coûte donc plus qu'avant (lire la grille de prix Outscale de votre région : 7 à 10 nœuds à 1500 IOPS est le calcul à faire) ; le quota de volumes ne change pas (un volume racine par nœud) ; le changement ne touche que les NOUVEAUX nœuds (une VM en marche garde son volume : `ignore_changes`), un cluster existant demande donc `task cluster-roll` pour en profiter. **NON PROUVÉ sur un cluster** : que l'API accepte une racine io1 pour l'OMI Talos telle que mappée ici, et que 1500 IOPS supprime l'affamement (un `io1 3000` manuel au labo 16 sur des nœuds de 6 Go n'a pas arrêté cette cascade, qui avait aussi une cause mémoire). Le prochain labo Outscale doit prouver les deux avant de faire confiance au défaut.

## Disque système et pile applicative complète (tous les providers)

Talos garde sa partition EPHEMERAL (kubelet, images containerd, journaux) sur le volume système, environ 4 Go de moins que sa taille. Avec toute la
pile applicative à ses versions actuelles, un worker portait environ 11 Go d'images (lab 12, Scaleway), pour environ 15,6 Go d'espace éphémère sur un
volume de 20 Go : DiskPressure, pods évincés (25 pods Zitadel dans les premières minutes) et délais de création de conteneurs.

**Minimum : 40 Go par nœud avec la pile applicative ; le défaut est 50 Go** (environ 46 Go utilisables) : les ~11 Go d'images, le second jeu qu'une mise
à jour de chart tire avant le ramasse-miettes de l'ancien (le kubelet lance le GC des images à 85 %), les journaux et de la marge. Par provider :
Scaleway `scw_root_volume_size_gb` (50 ; une validation refuse moins de 40 avec `deploy_flux = true`) ; OVH le flavour (`b3-8` : 50 Go ; un `check`
avertit sous 40 Go) ; Outscale `outscale_root_volume_size_gb` (type : `outscale_root_volume_type`, défaut io1 / 1500 IOPS ; null = la taille de l'OMI, l'image Talos brute, ~11-12 Gio, **insuffisant** ; un `check`
avertit avec `deploy_flux`, ne vaut que pour les nœuds créés ensuite) ; Proxmox `root_disk_gb` (50 Gio ; un `check` avertit sous 40).

Augmenter la valeur Scaleway sur un cluster existant redimensionne le `sbs_volume` sur place (lab 12 : plan « 10 to change », aucun nœud remplacé) ;
Talos agrandit EPHEMERAL au redémarrage suivant du nœud : drainer et redémarrer les workers un par un ensuite (15,6 Go vers 35,6 Go ; voir l'avertissement RWX
de [`upgrade.fr.md`](upgrade.fr.md)). Un cluster construit à 20 sans l'épingler dans son tfvars verra ce redimensionnement au prochain plan ; épingler
`scw_root_volume_size_gb = 20` garde l'ancienne taille (la pile complète n'y tient pas). Chez Outscale et Proxmox ce code ne redimensionne pas le disque
racine sur place : remplacer les nœuds un par un (`task cluster-roll`). Non mesuré : l'espace utile d'Outscale et d'OVH avec la pile complète.
