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
| Disque système | 50 Go `sbs_volume` chacun (`scw_root_volume_size_gb` ; 40 au moins avec `deploy_flux`, imposé) | celui du flavour (50 Go au moins ; un `check` avertit sous 40) | celui de l'OMI (~11-12 Gio) : `outscale_root_volume_size_gb = 50` (un `check` avertit) | `root_disk_gb` (50 Gio) chacun (un `check` avertit sous 40) |
| Volumes de données | W × D | W × D | W × D | W × D, sur `datastore_id` |
| IP publiques | 3 : bastion, public gateway, LB de l'API | 2 flottantes : bastion, LB de l'API | 2 : bastion, NAT | aucune — `host_public_ip` est la tienne |
| Load balancers | 1 | 1 (Octavia) | 1 (LBU) | aucun — VIP Talos |
| Security groups | 1 par entrée de `zones` + 1 bastion | 2 | 2 | aucun |
| Réseau | 1 réseau privé, 1 public gateway | 1 réseau, subnet, routeur | 1 Net, 2 subnets, internet + NAT service | ton bridge ; CP+W + 1 VIP en IP statiques dans `network_cidr` |

`deploy_app_lb = true` ajoute un LB et une IP publique sur chaque cloud.
`k8s_lb_mode = "vip"` (OVH ; expérimental sur Scaleway) remplace le LB de l'API
et son IP par une adresse privée.

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

`cluster-roll` refuse de démarrer quand les requêtes CPU de tous les workers, chacune en pourcentage de son propre nœud, dépassent
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
perdue : la perte la plus défavorable retire deux workers et en laisse trois (300 %). La charge croît d'environ un DaemonSet par worker ajouté (environ 0,3 vCPU) : cinq
workers demandent environ 230 % d'un worker (dérivé : 224 % plus la part d'un DaemonSet ; aucune perte de zone à cinq workers n'est consignée dans ce dépôt), largement sous 300 %.

`task failure-domain-check PROVIDER=<scaleway|ovh>` (lecture seule, demande l'état déployé) donne le verdict attendu :

| Workers | Zones | `If <zone> is lost` | Verdict |
|---|---|---|---|
| 4 (livré) | 2 + 1 + 1 | la zone à deux : `workers: 2 stay, but the workers request 224% of a node and 2 hold 200%` | sortie 1 pour cette zone ; les deux autres passent |
| 5 | 2 + 2 + 1 | `workers: 3 of 5 stay, requests 230% fit in 300%` pour les zones à deux workers ; 4 sur 5 pour l'autre | sortie 0, toute perte est supportable |

Le test `scripts/dev/test-failure-domain-check.sh` exécute les deux formes contre des `tofu` et `kubectl` factices. Il prouve l'arithmétique du contrôle, pas un
cluster : aucune perte de zone sur la forme à 5 workers n'est consignée ici. Coût : une instance de plus et 4 vCPU (et le quota correspondant) par cloud. Outscale n'est
pas couvert (ses exemples sont sous le plancher, voir plus haut).

Outscale (les exemples sont inchangés et restent dans le quota de 20 vCPU) : aucune forme ne tient dans le quota par défaut de 20 vCPU et passe la porte. 3 workers de 3 vCPU échouent (ci-dessus), et 4 workers de
3 vCPU demandent 3 + 4 nœuds x 3 + 2 (bastion) = 23 vCPU. La plus petite forme qui passe sur le papier est 3+3 `tinav5.c4r8p2` (4 vCPU / 8 Go) : 26 vCPU
avec le bastion (mince, voir le paragraphe 0.4.0 ci-dessus), et la forme 3 + 4 des autres clouds fait 30 vCPU, donc une hausse de quota d'abord. Aucune n'a été exécutée sur Outscale. Les nœuds de 6 Go du lab 16 sont aussi tombés dans une cascade
d'E/S et de mémoire après une sauvegarde-restauration et un redémarrage drainé (#376) ; le volume racine est gp2 (type non configurable ici), et un passage
manuel en `io1 3000` ne l'a pas arrêtée. L'exemple fixe maintenant `outscale_root_volume_size_gb = 50` au lieu de le laisser en commentaire.

## Disque système et pile applicative complète (tous les providers)

Talos garde sa partition EPHEMERAL (kubelet, images containerd, journaux) sur le volume système, environ 4 Go de moins que sa taille. Avec toute la
pile applicative à ses versions actuelles, un worker portait environ 11 Go d'images (lab 12, Scaleway), pour environ 15,6 Go d'espace éphémère sur un
volume de 20 Go : DiskPressure, pods évincés (25 pods Zitadel dans les premières minutes) et délais de création de conteneurs.

**Minimum : 40 Go par nœud avec la pile applicative ; le défaut est 50 Go** (environ 46 Go utilisables) : les ~11 Go d'images, le second jeu qu'une mise
à jour de chart tire avant le ramasse-miettes de l'ancien (le kubelet lance le GC des images à 85 %), les journaux et de la marge. Par provider :
Scaleway `scw_root_volume_size_gb` (50 ; une validation refuse moins de 40 avec `deploy_flux = true`) ; OVH le flavour (`b3-8` : 50 Go ; un `check`
avertit sous 40 Go) ; Outscale `outscale_root_volume_size_gb` (null = la taille de l'OMI, l'image Talos brute, ~11-12 Gio, **insuffisant** ; un `check`
avertit avec `deploy_flux`, ne vaut que pour les nœuds créés ensuite) ; Proxmox `root_disk_gb` (50 Gio ; un `check` avertit sous 40).

Augmenter la valeur Scaleway sur un cluster existant redimensionne le `sbs_volume` sur place (lab 12 : plan « 10 to change », aucun nœud remplacé) ;
Talos agrandit EPHEMERAL au redémarrage suivant du nœud : drainer et redémarrer les workers un par un ensuite (15,6 Go vers 35,6 Go ; voir l'avertissement RWX
de [`upgrade.fr.md`](upgrade.fr.md)). Un cluster construit à 20 sans l'épingler dans son tfvars verra ce redimensionnement au prochain plan ; épingler
`scw_root_volume_size_gb = 20` garde l'ancienne taille (la pile complète n'y tient pas). Chez Outscale et Proxmox ce code ne redimensionne pas le disque
racine sur place : remplacer les nœuds un par un (`task cluster-roll`). Non mesuré : l'espace utile d'Outscale et d'OVH avec la pile complète.
