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
| `management-`, `failover-scaleway` | 3+2 × `POP2-4C-16G` (4 / 16 Go) | 6 | 22 | 82 Go | Type oui ; marge sur 2 workers non mesurée | pas de backend Scaleway |
| `workload-scaleway` | 3+3 × `POP2-4C-16G` | 7 | 26 | 98 Go | Oui | pas de backend Scaleway |
| `management-`, `failover-ovh` | 3+2 × `c3-8` (4 / 8 Go) | 6 | 22 | 48 Go | Type oui ; marge sur 2 workers non mesurée | `--add-vms 6 --add-cores 22 --add-ram-gb 48` |
| `workload-ovh` | 3+3 × `c3-8` | 7 | 26 | 56 Go | Oui | `--add-vms 7 --add-cores 26 --add-ram-gb 56` |
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
