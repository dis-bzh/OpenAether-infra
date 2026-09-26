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
pour les deux. Un cluster nu (Cilium seul, le périmètre de la 0.1.0) demande
moins ; aucun run n'a mesuré combien.

## Ce que crée chaque provider

Par défaut : `k8s_lb_mode = "managed"`, `deploy_app_lb = false`. CP / W =
control planes / workers, D = entrées de `worker_storage.disks`.

| | Scaleway | OVH | Outscale | Proxmox |
|---|---|---|---|---|
| Instances | CP+W + bastion `DEV1-S` (2 vCPU / 2 Go) | CP+W + bastion `b3-8` (2 vCPU / 8 Go) | CP+W + bastion `tinav5.c2r2p2` (2 vCPU / 2 Go) | CP+W ; + bastion (1 vCPU / 1 Gio / 10 Gio) seulement avec `enable_bastion` |
| Disque système | 20 Go `sbs_volume` chacun | celui du flavour | celui de l'OMI | `root_disk_gb` (20 Gio) chacun |
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
| `management-`, `failover-scaleway` | 3+2 × `POP2-2C-8G` (2 / 8 Go) | 6 | 12 | 42 Go | **Non** — 2 vCPU | pas de backend Scaleway |
| `workload-scaleway` | 3+3 × `DEV1-M` (3 / 4 Go) | 7 | 20 | 26 Go | **Non** — 4 Go | pas de backend Scaleway |
| `management-`, `failover-ovh` | 3+2 × `c3-8` (4 / 8 Go) | 6 | 22 | 48 Go | Type oui ; marge sur 2 workers non mesurée | `--add-vms 6 --add-cores 22 --add-ram-gb 48` |
| `workload-ovh` | 3+3 × `c3-8` | 7 | 26 | 56 Go | Oui | `--add-vms 7 --add-cores 26 --add-ram-gb 56` |
| `management-`, `failover-outscale` | 3+2 × `tinav5.c2r4p1` (2 / 4 Go) | 6 | 12 | 22 Go | **Non** | `--add-vms 6 --add-cores 12 --add-ram-gb 22` |
| `workload-outscale` | 3+3 × `tinav5.c2r4p1` | 7 | 14 | 26 Go | **Non** | `--add-vms 7 --add-cores 14 --add-ram-gb 26` |
| `*-proxmox` | 1+1 × 4 vCPU / 8 Gio, disque 20 Gio | 2 | 8 | 16 Gio | Type oui ; un seul worker ne se draine pas sans coupure | capacité de l'hôte, pas un quota |

À noter aussi sur les exemples :

- Le `DEV1-M` de `workload-scaleway` est un type à SSD local, alors que le
  module demande toujours une racine `sbs_volume`, et ses `zones` incluent
  `fr-par-3`, où le commentaire de l'exemple management dit que `DEV1-M` n'est
  pas proposé. Aucun run n'est consigné.
- **Mesuré** sur Outscale : 3+3 en `tinav5.c2r7p2` ne tient pas dans le quota
  de RAM du compte de test et `preflight-quotas` le refuse ; le 3+1 qui tient se
  déploie mais n'a qu'un worker schedulable
  ([`deployment-test-matrix.fr.md`](deployment-test-matrix.fr.md), `OSC-mgmt-ha` ;
  issue #72). Un chemin vers le plancher dans ce quota n'est pas testé, et
  Outscale change `vm_type` par un stop/start — un nœud à la fois.
- Les runs sur cloud réel de [`status.md`](status.md) ne consignent pas les
  types d'instance utilisés : ils n'établissent aucun plancher.
