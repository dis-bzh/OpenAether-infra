# OpenAether-infra — Matrice de test des déploiements

🇬🇧 [English version](deployment-test-matrix.md)

> Tous les cas de déploiement que ce stack peut produire, et ceux réellement
> exercés. Dérivée de `cluster/variables.tf`, des modules provider et de
> `provider-contract.md`. Tenir la colonne **Statut** à jour — c'est l'intérêt
> du fichier.
>
> ✅ testé par apply réel · 🎭 émulé (Feint : vrai provider, vrai HTTP, sans
> compte) · ⛔ bloqué en amont · 🧪 testé unitairement (mocké) · ⬜ non testé.
> Revue 2026-10-03.
>
> Un ✅ est le compte rendu d'un run à sa date, pas une revendication de la
> 0.1.0. Ce sur quoi cette version repose, c'est le management HA Scaleway et OVH
> mesuré le 2026-08-19 et celui d'Outscale mesuré le 2026-08-20 — `docs/status.md`
> § « Where we stand ». Les lignes datées d'avant, `CAPI-*` comprises, précèdent
> le recentrage.

## Modèle mental

Un **fichier d'env = un cluster = un provider**. `cluster/main.tf` impose un
seul provider actif par apply (`check "single_provider_per_cluster"`) ; le
provider actif est celui dont la clé `node_distribution.<provider>` a
`control_planes + workers > 0`. Le module provider rend l'infra (LB / réseau /
bastion) ; puis `modules/talos`, **provider-agnostique**, rend une config Talos
identique quel que soit le provider. Le Docker local est une **racine séparée**
(`infrastructure/opentofu-local`), non sélectionnable via `node_distribution`.

Deux couches de réglages orthogonales :

- **Forme de l'infra** (par provider) : provider, zones/hôtes, `k8s_lb_mode`,
  bastion, disques workers.
- **Talos / exploitation** (agnostique) : `cluster_role`, phase
  `talos_bootstrap`, injection de VIP, `secrets_prevent_destroy`,
  `auto_tunnels`, `backup_enabled`, raccourcis réservés aux tests.

## A) Dimensions

| Dimension | Chemin de la variable | Valeurs | Défaut | Applicabilité | Notes |
|---|---|---|---|---|---|
| Provider | `node_distribution.<clé>` (scaleway/ovh/outscale/proxmox) ; `local` = racine `opentofu-local` séparée | un seul actif | `{}` | — | Exactement un actif par apply. |
| Rôle du cluster | `cluster_role` | `management`, `workload` | `workload` | tous | Ne pilote que le manifeste d'amorçage Flux. Un « management » reçoit ensuite CAPI et ses dépendances via `OpenAether-apps` (aucun réglage CAPI côté tofu). `failover-*` = rôle management sur un provider non primaire. |
| Environnement | `environment` | `dev`, `prod` | requis | tous | Nommage / suffixe de bucket seulement — pas un axe de topologie. |
| Topologie CP (HA) | `node_distribution.<p>.control_planes` ; local `control_plane_count` | 1 = non-HA, 3 = HA | 0 / local 3 | tous | Le quorum etcd exige un nombre impair ≥ 3. CP non-HA taché `NoSchedule`. |
| Nombre de workers | `node_distribution.<p>.workers` ; local `worker_count` | ≥ 0 (local `0..3`) | 0 / local 3 | tous | 0 worker → workloads sur les CP (non tachés). |
| Mode LB k8s | `node_distribution.<p>.k8s_lb_mode` | `managed`, `vip` | `managed` | **scw, ovh** seulement ; outscale = managed seul (rejette vip) ; proxmox = toujours VIP ; local = ni l'un ni l'autre | `vip` (EXPÉRIMENTAL) : pas de LB, adresse IPAM privée + VIP Talos Layer2 → **API privée uniquement, via tunnel bastion**. |
| VIP apiserver | `local.apiserver_vip` → `module.talos.apiserver_vip` ; proxmox `apiserver_vip` (requis) + `apiserver_vip_interface` | IP / null | null (cloud) ; requis (proxmox) | proxmox toujours ; scw/ovh en mode vip | Injecté en `machine.network.interfaces[].vip` + certSANs. Ignoré en mode conteneur. |
| LB applicatif | `deploy_app_lb` | `true`/`false` | `false` | scw/ovh/outscale ; proxmox = DNAT hôte ; local = `127.0.0.1` | Ses backends sont les NodePorts fixes de la Gateway : un cluster infra seule paierait un LB qui ne pointe sur rien. Désactivé ⇒ `app_lb_ip` vaut null (`N/A` à la racine). |
| Zones / AZ | scw `.zone`+`.zones` et ovh `.availability_zones` en round-robin via `element(...)` ; outscale crée un sous-réseau privé et un public par entrée de `.availability_zones` et place les nœuds par index, comme les autres (#58) ; proxmox `.node_names` (round-robin) | ex. scw `["fr-par-1","fr-par-2","fr-par-3"]` | selon exemple | cloud + proxmox | Mono vs multi-AZ. Proxmox : 1 hôte = non-HA, 3 hôtes = **vraie** HA ; 3 CP sur 1 hôte = fausse HA (à éviter). |
| Bastion | proxmox `enable_bastion` | `true` (VM) / `false` (hôte-bastion) | `false` | bascule proxmox ; scw/ovh/outscale = toujours une VM dédiée ; local = aucun | Le contrat exige `bastion_ip`. |
| Stockage workers | `worker_storage.disks[]` + `worker_storage.volumes[]` (LUKS2 `UserVolumeConfig`) | aucun, ou disques+volumes | `{disks=[],volumes=[]}` | scw/ovh/outscale/proxmox ; local forcé à off | `disks` → module provider ; `volumes` → `modules/talos`. |
| DNS des nœuds | `node_nameservers[]` (`address`, `protocol` Do53/DoT/DoH, `tls_server_name`), `node_dns_boot_timeout` | vide, tous chiffrés, ou tous en clair | `[]`, `90s` | tous ; DoT/DoH demandent Talos ≥ 1.14 | `ResolverConfig` (+ `TimeSyncConfig` avec un serveur chiffré) ajouté par `modules/talos` ; une liste mêlant chiffré et en clair est refusée. Vide = config identique à l'octet. |
| Phase d'amorçage | `talos_bootstrap` | `false` (phase 1 infra), `true` (phase 2 config+etcd+Flux) | `true` | tous | `task infra-apply` → `task bootstrap-phase2`. |
| auto_tunnels | `auto_tunnels` (+ `ssh_key_path`) | `true`/`false` | `false` | cloud/proxmox | EXPÉRIMENTAL, apply unique ; jamais testé sur machine réelle. |
| Bloc de ports des tunnels | `TALOS_TUNNEL_OFFSET` → `talos_tunnel_port_offset` | multiple de 200, positif ou nul | `0` | cloud/proxmox | Décale les CP en `50000+off+i` et les workers en `50100+off+i`, pour monter plusieurs clusters depuis un même poste. Ne poser que la variable d'environnement ; `Taskfile.yml` alimente la variable tofu. |
| secrets_prevent_destroy | `secrets_prevent_destroy` | `true`/`false` | `true` | tous | `false` réservé au nettoyage de `tofu test`. |
| skip_port_ready_wait | `skip_port_ready_wait` | `true`/`false` | `false` | tous | `true` réservé à la CI mockée. |
| backup_enabled | `backup_enabled` | `true`/`false` | `true` | racine | `false` saute le local-exec de backup. |
| Versions Talos / K8s | `talos_version`, `kubernetes_version` | chaînes | selon exemple | tous | Pilote la résolution du nom d'image. |
| admin_ip | `admin_ip` (liste) | CIDR | requis | tous | Liste d'autorisation ACL LB / SG / nftables hôte. |

## B) Cas de test pertinents

### Exclus / invalides / redondants — à **ne pas** tester

| Combinaison | Pourquoi |
|---|---|
| ≥ 2 providers avec un compte > 0 dans un même apply | Bloqué par `check "single_provider_per_cluster"`. |
| `outscale` + `k8s_lb_mode="vip"` | La validation du provider le rejette (LB à nom DNS). |
| `proxmox` + n'importe quel `k8s_lb_mode` | Ignoré — proxmox utilise toujours la VIP Talos. |
| `local-docker` + LB / stockage / Flux par manifeste d'amorçage | Pas de LB (IP du cp0) ; volumes forcés off ; Flux installé après boot. |
| `apiserver_vip` avec `k8s_lb_mode="managed"` en cloud | Résout à null. |
| 3 CP sur un seul hôte Proxmox | Fausse HA — la vraie HA est multi-hôtes. |
| local CP ∉ {1,3} ou workers > 3 | Erreur de validation. |
| `dev` vs `prod` comme topologie | Nommage seulement — à replier dans n'importe quel cas. |

### local-docker (racine `opentofu-local`)

| ID | CP/W | Ce qu'il exerce en propre | Statut |
|---|---|---|---|
| `L-ha` | 3+3 | Vrai quorum etcd à 3 nœuds, workers dédiés ordonnançables, Cilium, livraison par `userdata` — preuve principale de `modules/talos` sans credentials. | ✅ (`task local-up`, rejoué le 2026-08-20 : manifeste rendu quand absent, Cilium 6/6, 3 membres etcd, `local-test` vert) |
| `L-smoke` | 1+0 | Smoke test mono-nœud ; repli d'ordonnancement sur CP non taché. | ⬜ |

### Scaleway (provider de référence)

| ID | Rôle | CP/W | k8s_lb_mode | Zones | Stockage | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|---|---|
| `SCW-mgmt-nonha` | mgmt | 1+1 | managed | mono | aucun | Chemin cloud le moins cher ; taint CP non-HA ; ACL du LB managé. | ✅ |
| `SCW-mgmt-ha` | mgmt | 3+2 | managed | 3 AZ | aucun | etcd sur 3 zones ; distribution multi-AZ. | ⬜ — voir la ligne suivante : ce qui tourne est sur **2 zones**, la troisième n'ayant aucun type d'instance utilisé par ce projet |
| `SCW-mgmt-ha-2az` | mgmt | 3+3 | managed | 2 AZ | **disques+volumes** | Ce sur quoi repose réellement la 0.1.0. etcd sur 2 zones, en round-robin. | ✅ 2026-08-19, puis 2026-08-20 — 3 control planes sur 2 zones font un 2+1, dont `cluster-verify` (#38) avertit désormais |
| `SCW-vip` | mgmt | 3+1 | **vip** | multi-AZ | aucun | Supprime le LB ; VIP Talos Layer2 ; API privée via tunnel ; anti-spoofing. | ✅ *(2026-07-15)* |
| `SCW-work-ha` | workload | 3+3 | managed | 3 AZ | aucun | Chemin d'amorçage Flux du rôle workload. | ⬜ |
| `SCW-storage` | workload | 3+3 | managed | 3 AZ | **disques+volumes** | Volumes blocs SBS + `UserVolumeConfig` chiffré (LUKS2). | ⬜ sur le rôle *workload*. Les volumes blocs et les patchs UserVolumeConfig ONT bien été appliqués sur `SCW-mgmt-ha-2az` — 3 × `scaleway_block_volume.worker_data` dans l'état — et depuis le 2026-10-03 `cluster-verify` relit le volume de données de chaque worker depuis le nœud (`ready luks2`), 13/13 sur Scaleway, OVH et Outscale |

### OVH (OpenStack)

| ID | Rôle | CP/W | k8s_lb_mode | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|
| `OVH-mgmt-ha` | mgmt | 3+3 | managed | LB Octavia + floating IP ; ports OpenStack ; bastion Ubuntu ; egress routeur SNAT. | ✅ *(2026-07-27/28, plusieurs cycles)* — avant le contrôle des domaines de panne (#38) ; ✅ 2026-10-03 : 3+3 sur `eu-west-par-a/b/c` avec des disques de données workers chiffrés, `cluster-verify` 13/13. Une zone unique échoue le contrôle |
| `OVH-vip` | mgmt | 3+2 | **vip** | `allowed_address_pairs` sur les ports CP pour l'anti-spoof Neutron (mécanisme distinct de Scaleway). | 🧪 |
| `OVH-work-ha` | workload | 3+3 | managed | Rôle workload sur OVH. | ⬜ |
| `OVH-storage` | workload | 3+3 | managed | Attachement de volumes Cinder. | ⬜ |

### Outscale (managed seul, LB à nom DNS)

| ID | Rôle | CP/W | k8s_lb_mode | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|
| `OSC-mgmt-ha` | mgmt | 3+1 | managed | Le LB renvoie un **nom DNS**, pas une IP ; utilisateur SSH outscale. 3+3 ne tient pas dans le quota de 40 Go de RAM, donc HA ici ne concerne que le control plane — les trois control planes sont dans trois subregions (`availability_zones`, #58). | ✅ *(2026-10-03 : trois control planes en `eu-west-2a/b/c` plus deux workers, obtenus depuis un seul control plane par un `cluster-up` ; `cluster-verify` 13/13, le load balancer `UP` sur les trois. Le ✅ du 2026-08-20 était l'ancienne disposition à une seule subregion, sur un Net **neuf** — LB `active` avec 3 backends. Le blocage venait d'un timeout interne au service LBU d'Outscale, demande 399530 close ; le Net antérieur au correctif refuse toujours d'être supprimé. Le ✅ du 2026-08-13 ne tient pas : son upgrade Talos est revenu en arrière au redémarrage suivant, cf. les issues ouvertes)* |
| `OSC-work-ha` | workload | 3+3 | managed | Rôle workload ; volumes BSU si couplé au stockage. | ⬜ |
| `OSC-vip-reject` | — | tout | vip | Test négatif : la validation doit rejeter `vip`. | 🧪 |

### Proxmox (bare-metal, toujours VIP, hôte-bastion)

| ID | Rôle | CP/W | node_names | Bastion | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|---|
| `PMX-nonha-host` | mgmt | 1+1 | `["pve1"]` | hôte | Mono-hôte non-HA ; VIP Talos ; IP statiques `cidrhost()` ; ni LB ni NAT ni SG. | ⬜ |
| `PMX-work-nonha` | workload | 1+1 | `["pve1"]` | hôte | Rôle workload on-prem. | ⬜ |
| `PMX-ha-multihost` | mgmt | 3+n | `["pve1","pve2","pve3"]` | hôte | Vraie HA on-prem : 1 CP par hôte, VIP qui flotte ; bridge L2. | ⬜ |
| `PMX-vm-bastion` | mgmt | 1+1 | `["pve1"]` | **VM** | Chemin bastion en VM dédiée. | ⬜ |
| `PMX-storage` | workload | 1+1 | `["pve1"]` | hôte | Disque de données Proxmox + volume chiffré. | ⬜ |

### Surcouche CAPI — clusters enfants et management amorcé par CAPI

| ID | Amorcé par | Provider | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|
| `CAPI-edge-scw` | management | Scaleway | Enfant CAPS ; Cilium+Flux injectés à distance ; profil git propre. | ✅ *(edge-1, 2026-07-28)* |
| `CAPI-edge-ovh` | management | OVH (CAPO) | Enfant CAPO ; réseau/LB/SG créés par CAPO ; FIP pré-allouée pour les certSANs. | ✅ *(edge-2, 2026-07-28)* |
| `CAPI-cross-provider` | management OVH | Scaleway | Gitception **cross-provider dans les deux sens**. | ✅ *(2026-07-28)* |
| `CAPI-mgmt-pivot` | cluster jetable local | Scaleway | Management **né de CAPI**, qui déploie son propre enfant, puis `clusterctl move` vers lui-même. | ✅ *(mgmt-capi, 2026-07-28 — cf. `capi-bootstrap.fr.md`)* |
| `CAPI-edge-osc` | management | Outscale | Enfant CAPOSC. | ⬜ *(quota RAM du compte)* |
| `CAPI-providerid` | local jetable | Scaleway | CCM Talos → `providerID`, `nodeRef` résolu, MachineHealthCheck 3/3. | ✅ *(edge-pid, 2026-07-28)* |

### Cloud émulé (Feint — sans compte, sans credentials)

Les vrais binaires providers contre un émulateur local des APIs
Scaleway/Outscale. Entre 🧪 et ✅ : vrai HTTP, vrai décodage, mais pas
d'inventaire, pas de LB, pas de quotas. Ce que ça prouve et ce que ça ne prouve
pas : `emulated-cloud.fr.md`.

| ID | Voie | Ce qu'il exerce en propre | Statut |
|---|---|---|---|
| `FEINT-scw-plan` | `task feint-plan PROVIDER=scaleway` | Le **vrai** root cluster planifié sans le moindre credential à portée. | 🎭 (CI) |
| `FEINT-osc-plan` | `task feint-plan PROVIDER=outscale` | Idem Outscale, et il résout son image via `data.outscale_images` plutôt qu'un id épinglé — la forme `images[0]` que le module portait comme hypothèse non vérifiée. | 🎭 (CI) |
| `FEINT-scw-crud` | `task feint-apply PROVIDER=scaleway` | Vrai create/read/update/delete : jeu de règles du security group, adressage du NIC privé, cycle de vie serveur + volume, re-plan vide, destroy vérifié contre l'API. | 🎭 (CI) |
| `FEINT-osc-crud` | `task feint-apply PROVIDER=outscale` | Idem sur Outscale, et depuis Feint 0.6.0 presque tout le module : le plan d'egress à deux sous-réseaux (internet service, NAT, les deux route tables), security groups et règles, lien d'IP publique, lien de volume, keypair, trois VMs — 27 ressources. Le fixture laisse les load balancers de côté volontairement ; `feint-apply-root` les couvre. | 🎭 (CI) |
| `FEINT-record` | `task feint-record PROVIDER=…` | Enregistre le vrai module à travers `feint proxy` et classe les opérations qu'aucun pack ne sert. Mesure l'écart au lieu de l'affirmer ; l'apply derrière va jusqu'au bout depuis Feint 0.12.0. | 🎭 |
| `FEINT-guard` | endpoint non loopback | Test négatif : la voie doit refuser de piloter autre chose qu'un émulateur local. | 🎭 |

Ce que cette voie ne sait pas encore porter : voir « Manques connus » dans
[`emulated-cloud.fr.md`](emulated-cloud.fr.md).

### Scénarios d'exploitation transverses

| ID | Variables clés | Ce qu'il exerce en propre | Statut |
|---|---|---|---|
| `OP-twophase` | `talos_bootstrap=false` puis `true` | Découpage documenté `task infra-apply` → `task bootstrap-phase2`. | ✅ |
| `OP-autotunnels` | `auto_tunnels=true` | EXPÉRIMENTAL, apply unique. | ⬜ |
| `OP-failover` | `failover-<p>.tfvars`, `task restore-state` puis `task cluster-up` | Reconstruire chez B depuis le réplica laissé par A dans le magasin de B : la PKI est reprise, rien d'autre. Harnais hors ligne seulement ; aucun compte réel ne l'a joué (#57). | ⬜ |
| `OP-destroy` | `task cluster-down` / `task infra-down` | Chemin de destruction ordonné (enfants puis management). | ✅ |
| `OP-tftest` | mocké | Suite de tests unitaires (sans credentials). | ✅ (CI) |
| `OP-backup` | `backup_enabled=true`, réplica cross-provider (`<MAGASIN>_AWS_*`) | DR : tfstate + kube/talosconfig vers primaire et réplica ; restic chiffré client. | ✅ *(local + cloud réel SCW+OVH)* |
| `OP-rolling-replace` | `task cluster-roll` | Un nœud à la fois (evict etcd, cordon/drain). Pas « sans coupure » : l'API était injoignable 5 à 8 s en août, et 1 à 2 s (étape Talos) puis 9 à 10 s (étape Kubernetes) le 2026-10-03, cf. les issues ouvertes. | ✅ *(Scaleway et OVH le 2026-08-19, Outscale le 2026-08-20 — il porte l'upgrade Talos)* |
| `OP-grow-nodes` | `task cluster-up` avec un compte relevé | D'abord les machines, puis les tunnels, puis la configuration des seuls nouveaux nœuds (#59). | ✅ *(2026-10-03 : workers 3→6 et control planes 1→3 sur Scaleway ; control planes 1→3 sur OVH et Outscale)* |
| `OP-refuse-node-delete` | un compte abaissé via `cluster-up` / `infra-apply` | Refusé avant tout apply : retirer un nœud détruit ses volumes de données sans drain ni sortie d'etcd. | ✅ *(plan seul, 2026-10-03 : deux vrais plans de réduction Scaleway, workers 2→1 et control planes 3→2, refusés)* |
| `OP-shrink` | `task cluster-shrink-plan` puis `task cluster-shrink` | Drain, sortie d'etcd, extinction, suppression du Node, destruction du seul lot de ce nœud, convergence du reste. | ✅ *(2026-10-04 : un worker et un control plane, de 3 à 2, sur Scaleway, OVH et Outscale ; Longhorn n'a tourné que sur Scaleway, où son évacuation a été mesurée : un réplica unique est passé ailleurs, données intactes ; CNPG aussi sur Scaleway seulement : un réplica est passé avec son volume, données intactes ; un primaire CNPG sur le nœud qui part aussi : il a basculé, 2 insertions sur 368 ont échoué, aucune acquittée perdue)* |
| `OP-node-dns` | `node_nameservers`, `node_dns_boot_timeout` | Le résolveur propre des nœuds en DoT/DoH : document rendu et ajouté à chaque nœud, un changement remplaçant les ressources d'apply. Réel sur OVH le 2026-10-05 (1+1, Talos 1.14.2) : pas de redémarrage pour appliquer, les pods résolvent, DoT sur le fil, et une liste qu'aucun nœud n'atteint laisse un nœud redémarré sans API. Pas lancé sur Outscale. | ✅ OVH *(2026-10-05)* |

## C) Priorités (plus forte valeur, non testé, apply réel)

1. **Apply réel Proxmox** (`PMX-*`) — jamais exécuté sur un hôte réel.
2. **HA multi-AZ en cloud** (`SCW-mgmt-ha`) — etcd 3 CP réparti sur plusieurs
   zones jamais appliqué sous cette forme exacte. `OSC-mgmt-ha` a tourné avec sa
   disposition répartie le 2026-10-03.
3. **`OVH-vip`** — le mode vip n'a jamais été appliqué sur OVH (mécanisme
   Neutron `allowed_address_pairs`, distinct de Scaleway).
4. **Apply réel du rôle workload** (`*-work-*`) — seul le management est exercé.
5. **`worker_storage` sur le rôle workload** (`*-work-*`) — LUKS2 `UserVolumeConfig` et
   attachement de volumes ont été appliqués et relus sur le rôle management des trois
   clouds le 2026-10-03, pas sur un rôle workload.
6. **`OP-failover`** — chemin DR non prouvé.

## D) Constats — apply réel `SCW-vip` (2026-07-15)

3 CP (fr-par-1 + fr-par-2) + 1 worker, `k8s_lb_mode=vip`.

- ✅ La VIP Layer2 fonctionne cross-zone : le réseau privé régional relaie son
  ARP — c'était la principale inconnue. La VIP est dans les SANs de l'apiserver.
- ⚠️ L'accès opérateur devient privé uniquement (`kubectl` via le tunnel
  bastion), et `data.talos_cluster_health` peut bloquer l'apply : il est lu
  depuis le poste opérateur, qui ne joint pas une VIP privée. etcd et la config
  sont appliqués avant, donc le state reste complet.
