# Réseau — zones, CIDR, les deux couches d'application, et la matrice de flux

🇬🇧 [English version](network.md)

> Écrit pour répondre aux règles ANSSI sur une architecture réseau documentée, une matrice de flux, des zones de confiance et une politique de filtrage
> gérée et revue (ids d'audit NET/F07, NET/F09, OSN/F13 étape 0). Tout ici a été lu dans le code de ce dépôt ; **aucun flux n'a été sondé pour ce
> document** (`task cluster-netcheck` et `task cluster-exposure` sondent un cluster vivant). Les tableaux d'entrée des nœuds sont
> **générés depuis les fichiers Terraform** par `scripts/dev/gen-flow-matrix.sh` et comparés à cette page par `scripts/dev/test-flow-matrix.sh`, si bien
> qu'ils ne peuvent pas s'écarter du code sans qu'un test passe au rouge. Il ne revendique aucune conformité à un document ANSSI.

## 1. Zones de confiance

| Zone | Ce qu'elle contient | Atteint | Atteinte depuis |
|---|---|---|---|
| Z0 Internet | tout le reste | les load balancers publics, et le port 22 du bastion si l'adresse est autorisée | n/a |
| Z1 Poste de l'opérateur | `.env.sh`, tfvars, clés, `kubectl`, `talosctl`, `tofu` | le bastion (SSH) et le load balancer de l'API Kubernetes (6443), tous deux limités à `admin_ip` ; les stores objet | l'opérateur seul |
| Z2 Bastion | une VM par cluster, adresse publique, sshd ; baseline optionnelle, opérateurs nominatifs, sortie Internet fermée | le sous-réseau du cluster sur 6443 et 50000 (avec la sortie fermée), Internet sur 80/443 sinon | Z1, depuis `admin_ip` sur le port 22 |
| Z3 Bord public | le load balancer de l'API Kubernetes (6443) et, si `deploy_app_lb`, le load balancer applicatif (80/443) | les adresses privées des nœuds | Internet (LB applicatif : **aucun filtre de source par défaut**, `app_lb_allowed_cidrs` en ajoute un, voir section 6) ; `admin_ip` (LB de l'API) |
| Z4 Réseau privé du cluster | control planes et workers, sans adresse publique ; un sous-réseau plat par provider | entre eux, les stores objet et les registres (sortant) | Z2, Z3, et les membres du même sous-réseau |
| Z5 Charges de travail | namespaces, pods, le maillage ambient Istio pour une partie, les namespaces de fondation hors maillage (OpenBao, cert-manager...) | selon les politiques Cilium | selon les politiques Cilium |
| Z6 Stores objet | les buckets primaire et réplica, chez les providers | n/a | Z1 (clés S3), Z4 (sauvegardes, Loki, CNPG ; politique de sortie par FQDN) |

**Le plan d'administration est logique, pas physique.** Une interface réseau par nœud, un sous-réseau pour les control planes, les workers, le côté privé du bastion et les
load balancers ; l'administration est séparée des charges de travail par qui détient les identifiants (mTLS sur l'API Talos et le kube-apiserver, un tunnel SSH par
le bastion, une liste d'autorisation `admin_ip`), pas par un réseau dédié. C'est un écart consigné (section 7).

## 2. Les deux couches d'application

| Couche | Ce que c'est | Ce qu'elle fait | Ce qu'elle ne fait pas |
|---|---|---|---|
| 1. Provider | Groupes de sécurité (OVH, Outscale ; le groupe de Scaleway ne filtre que le trafic **public** et les nœuds n'ont pas d'adresse publique), ACL de load balancer et listes d'autorisation de listener, le groupe de sécurité du bastion et ses propres nftables | Rejet par défaut en entrée sur OVH et Outscale ; l'API Kubernetes seulement depuis `admin_ip` et le LB ; l'API Talos seulement depuis le bastion (OVH, Outscale) | Scaleway : à l'intérieur du réseau privé il déclare le périmètre sans l'appliquer (en-tête de `scw/security.tf`). OVH et Outscale : tout trafic entre membres du groupe du cluster est admis (`inter_node`). La sortie des nœuds est ouverte |
| 2. Cluster | Politiques réseau Cilium posées par la couche apps (refus par défaut en **entrée** à l'échelle du cluster, autorisations DNS et API kube en sortie, une politique par composant), mTLS Istio ambient `STRICT` et autorisation par défaut-refus par namespace ambient, WireGuard de Cilium entre nœuds | Filtrage pod à pod, identité de charge de travail, chiffrement nœud à nœud du trafic des pods | **Pas de refus de sortie à l'échelle du cluster** (il casserait le DNS avec l'intersection des politiques Cilium ; le fichier apps le dit). **Pas de pare-feu d'hôte** : `enable-host-firewall` est faux et les règles réseau de Talos ne sont pas utilisées, donc les ports des nœuds eux-mêmes (50000, 50001, 2379-2381, 10250) ne sont filtrés que par la couche 1, et par le mTLS ou l'authentification propres à chaque service |

Les deux couches sont relues sur un cluster vivant par `task cluster-security` (politiques, mTLS, WireGuard) et `task cluster-netcheck` (flux que les politiques doivent rejeter).
Les règles de sortie par composant, y compris les listes de FQDN S3 par provider, sont dans `OpenAether-apps` (`apps/base/*/networkpolicy.yaml`, vérifiées par `OpenAether-apps/scripts/dev/test-s3-egress-fqdns.py`).

## 3. Plan d'adressage

| Provider | Réseau des nœuds | Autre | Source |
|---|---|---|---|
| Scaleway | `172.16.0.0/22`, épinglé sur un nouveau réseau privé ; un réseau créé avant l'épinglage garde le sous-réseau reçu (`scw_subnet_in_use` le suit) | la VIP de l'apiserver (`k8s_vip`, une réservation IPAM) est une adresse de ce sous-réseau | `scw/network.tf` |
| OVH | `10.0.0.0/24`, un sous-réseau pour tous les rôles | routeur vers Ext-Net pour le SNAT sortant ; le LB de l'API Kubernetes prend une adresse flottante | `ovh/network.tf` |
| Outscale | Net `10.0.0.0/16` ; un sous-réseau privé par zone de disponibilité (`10.0.0.0/24`, puis `10.0.2.0/24`, `10.0.3.0/24`...) | sous-réseau public `10.0.1.0/24` (bastion, service NAT, load balancers) | `outscale/network.tf` |
| Proxmox | `network_cidr` (défaut `10.0.0.0/24`), adresses statiques par décalage | pas de groupe de sécurité : les règles dans la VM et le pare-feu de l'hôte Proxmox sont ceux de l'opérateur | `proxmox/network.tf` |

Les CIDR des pods et des services ne sont pas fixés par ce dépôt : les défauts de Talos s'appliquent (non relus sur un cluster vivant pour cette page). Les CIDR ci-dessus sont ceux du code ; un cluster
qui a adopté un réseau existant peut différer, c'est pourquoi les règles suivent `scw_subnet_in_use` et non la constante.

## 4. Schéma par provider

```text
                 Internet
                    |
     (admin_ip only)|                       (no filter unless app_lb_allowed_cidrs)
        +-----------+------------+                     |
        |                        |                     |
   [bastion :22]        [k8s API LB :6443]       [app LB :80/:443]
        |  SSH tunnels            |                     |
        |  to 6443 / 50000        |                     |
 ------ + ---------- node subnet (flat, one NIC per node, no public address) ------
        |                         |                     |
   control planes  <----> workers   (etcd 2379-2381, kubelet 10250, Cilium 8472/51871/4240)
        |                  |
        +-- outbound: image registries, Image Factory, object stores (S3 FQDNs), NTP, DNS
```

La même forme sur les quatre providers ; ce qui diffère est la couche qui l'applique. Scaleway : un réseau privé `/22`, un groupe qui ne le filtre pas. OVH : un `/24`,
un groupe en rejet par défaut avec une règle tous protocoles entre membres. Outscale : un sous-réseau privé par zone derrière un service NAT, les LB sur le sous-réseau public et portant le groupe du cluster.
Proxmox : un bridge, pas de groupe ; le défaut hôte-comme-bastion n'a pas de VM bastion séparée.

## 5. Matrice de flux

### 5.1 Flux d'administration et de gestion (écrits à la main)

| De | Vers | Port | Pourquoi | Contrôle |
|---|---|---|---|---|
| Poste de l'opérateur | Bastion | TCP 22 | le seul chemin vers les API des nœuds | `admin_ip` dans le groupe du bastion (et optionnellement dans les nftables de la VM, `restrict_ssh_source`) ; clés ou certificats de courte durée |
| Opérateur, par le tunnel du bastion | Control planes et VIP | TCP 6443 | `kubectl`, état de Flux | `PermitOpen` du tunnel ; certificats clients du kube-apiserver |
| Opérateur, par le tunnel du bastion | Chaque nœud | TCP 50000 | `talosctl`, l'apply du provider Talos | OVH, Outscale : le groupe des nœuds n'admet 50000 que depuis le groupe du bastion ; Scaleway : depuis tout le sous-réseau des nœuds ; certificats clients Talos (mTLS) |
| Poste de l'opérateur | LB de l'API Kubernetes | TCP 6443 | accès direct à l'API | `admin_ip` (ACL du LB Scaleway, `allowed_cidrs` du listener OVH, règle de groupe Outscale) |
| Poste de l'opérateur | Stores objet | TCP 443 | état, artefacts, snapshots, journaux du bastion | clés S3 K7 ; chiffrement côté client (`key-management.fr.md`) |
| Nœuds | Image Factory, registres | TCP 443 | images de boot, images de conteneurs | sortie ouverte ; les listes par FQDN sont côté cluster |
| Charges de travail du cluster | Stores objet | TCP 443 | restic, WAL CNPG, Loki, Longhorn | sortie Cilium par FQDN (apps) |
| Cluster vers Internet, autre | | | | non filtré à la couche 1 ; couche 2 par composant, **sans refus de sortie à l'échelle du cluster** |

### 5.2 Entrée des nœuds, générée depuis le code

Chaque bloc est la sortie de `scripts/dev/gen-flow-matrix.sh --fr <provider>` : modifier le Terraform, lancer le script, coller la sortie entre les marqueurs ; `scripts/dev/test-flow-matrix.sh` (dans `task test-scripts`) échoue à la moindre différence.
« Source » est telle qu'écrite dans le code : `scw_subnet_in_use` est le sous-réseau des nœuds en service, « membres du SG du cluster » chaque nœud du groupe, « SG du bastion » le groupe du bastion.

**Scaleway**

<!-- flow-matrix:scw:begin -->
| Règle | Protocole | Ports | Source | Présente quand |
|---|---|---|---|---|
| `kube-apiserver` | TCP | 6443 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `talos-apid` | TCP | 50000 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `talos-trustd` | TCP | 50001 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `etcd` | TCP | 2379-2381 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `kubelet` | TCP | 10250 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `cilium-vxlan` | UDP | 8472 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `cilium-wireguard` | UDP | 51871 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `cilium-health` | TCP | 4240 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `cilium-icmp` | ICMP | - | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `cilium-metrics` | TCP | 9962-9964 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `node-exporter` | TCP | 9100 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `dhcp` | UDP | 68 | sous-réseau des nœuds (`scw_subnet_in_use`) | toujours |
| `gateway-<name>` | TCP | `var.app_lb_node_ports` | sous-réseau des nœuds (`scw_subnet_in_use`) | `deploy_app_lb` |
| `carrier-<name>` | TCP | le port de l'API k8s quand `k8s_lb_mode = "managed"`, et les ports de la passerelle | `100.64.0.0/10` | le load balancer correspondant existe |
<!-- flow-matrix:scw:end -->

**OVH**

<!-- flow-matrix:ovh:begin -->
| Règle | Protocole | Ports | Source | Présente quand |
|---|---|---|---|---|
| `k8s_api` | tcp | 6443 | `10.0.0.0/24` | toujours |
| `talos_api` | tcp | 50000 | SG du bastion | toujours |
| `http` | tcp | `var.app_lb_node_ports.http` | `10.0.0.0/24` | `deploy_app_lb` |
| `https` | tcp | `var.app_lb_node_ports.https` | `10.0.0.0/24` | `deploy_app_lb` |
| `wireguard` | udp | 51820 | membres du SG du cluster | toujours |
| `inter_node` | tous | tous | membres du SG du cluster | toujours |
<!-- flow-matrix:ovh:end -->

**Outscale**

<!-- flow-matrix:outscale:begin -->
| Règle | Protocole | Ports | Source | Présente quand |
|---|---|---|---|---|
| `k8s_api_private` | tcp | 6443 | sous-réseau public (LB) | toujours |
| `k8s_api_admin` | tcp | 6443 | `admin_ip` | toujours |
| `talos_api` | tcp | 50000 | SG du bastion | toujours |
| `http` | tcp | `var.app_lb_node_ports.http` | sous-réseau public (LB) | `deploy_app_lb` |
| `https` | tcp | `var.app_lb_node_ports.https` | sous-réseau public (LB) | `deploy_app_lb` |
| `app_lb_http` | tcp | 80 | `app_lb_allowed_cidrs`, sortie du cluster | `deploy_app_lb` et `app_lb_allowed_cidrs` |
| `app_lb_https` | tcp | 443 | `app_lb_allowed_cidrs`, sortie du cluster | `deploy_app_lb` et `app_lb_allowed_cidrs` |
| `wireguard` | udp | 51820 | membres du SG du cluster | toujours |
| `inter_node` | tous | tous | membres du SG du cluster | toujours |
<!-- flow-matrix:outscale:end -->

Proxmox n'a pas de groupe de sécurité ; ses ports sont les mêmes services, filtrés par ce que l'opérateur fait tourner sur l'hôte ou le bridge.

### 5.3 Pourquoi chaque règle existe, et ce qu'elle compense

Le test exige que chaque nom de règle ci-dessus ait une ligne ici, dans les deux langues.

| Règle | Justification | Mesure compensatoire |
|---|---|---|
| `kube-apiserver`, `k8s_api`, `k8s_api_private`, `k8s_api_admin` | les kubelets, le tunnel du bastion, la VIP et le load balancer de l'API atteignent l'apiserver | authentification par certificat client ; le LB de l'API limité à `admin_ip` |
| `talos-apid`, `talos_api` | l'apply du provider Talos, `talosctl`, le relais apid entre nœuds | mTLS Talos ; OVH, Outscale : groupe du bastion seulement. **Scaleway admet tout le sous-réseau** (le groupe n'y est de toute façon pas appliqué) |
| `talos-trustd` | les workers récupèrent leurs certificats auprès des control planes | mTLS |
| `etcd` | ports client, pair et métriques entre control planes | mTLS de la CA etcd |
| `kubelet` | apiserver vers kubelet | authentification et autorisation du kubelet |
| `cilium-vxlan`, `cilium-wireguard`, `cilium-health`, `cilium-icmp`, `cilium-metrics`, `wireguard` | réseau des pods, son chiffrement, sondes de santé et découverte du MTU de chemin, métriques de l'agent. Sur OVH et Outscale la règle `wireguard` nomme 51820 alors que le WireGuard de Cilium écoute sur 51871 : sans effet aujourd'hui seulement parce que `inter_node` admet tout entre membres | WireGuard chiffre le trafic des pods entre nœuds |
| `node-exporter` | collecte de métriques, couche apps, hostNetwork (non vérifié ici) | rien au-delà du sous-réseau |
| `dhcp` | baux d'adresses du réseau privé (non vérifié) | aucune |
| `gateway-<name>`, `http`, `https` | les backends du load balancer applicatif sur les NodePorts fixes de la Gateway | n'existe qu'avec `deploy_app_lb` ; les routes de la Gateway s'authentifient elles-mêmes (`OpenAether-apps/docs/public-exposure.md`) |
| `app_lb_http`, `app_lb_https` | Outscale seulement : le groupe du load balancer est le groupe du cluster, les clients publics admis sur 80/443 sont donc des règles dans ce groupe | seulement avec `app_lb_allowed_cidrs` ; non exécuté sur un cloud, savoir si le groupe filtre le load balancer est le premier contrôle en laboratoire |
| `carrier-<name>` | trafic de backend de load balancer qui arrive de la plage carrier ; l'origine n'est pas confirmée | gardée jusqu'à ce qu'un vrai déploiement montre qu'elle est inutilisée |
| `inter_node` | tout le trafic entre nœuds (etcd, kubelet, Cilium) | **n'importe quel port et protocole entre membres** : plus large que ce dont la matrice a besoin ; le resserrer est un travail prévu, pas fait |

### 5.4 Bastion

Entrant : TCP 22 depuis `admin_ip`. Sortant (défaut `legacy`) : le sous-réseau du cluster, DNS, NTP, et 80/443 vers n'importe où pour les mises à jour. Avec `bastion_internet_egress = { mode = "closed" }` :
seulement TCP 6443 et 50000 vers le sous-réseau du cluster, ICMP dans le sous-réseau, les adresses de métadonnées sur 80, et DNS/NTP vers les serveurs épinglés (`admin-access.fr.md`).

## 6. Lacunes connues du filtrage

Listées pour qu'un lecteur ne prenne pas la matrice pour plus qu'elle n'est. Aucune n'est changée par cette page.

1. **Le groupe de Scaleway ne filtre pas le réseau privé.** Les règles sont exactes pour qu'un pare-feu d'hôte puisse les appliquer plus tard.
2. **Pas de pare-feu d'hôte.** Les nœuds admettent 50000, 50001, 2379-2381 et 10250 depuis tout le sous-réseau (Scaleway) ou le groupe (OVH, Outscale), y compris depuis un nœud compromis ou un pod hostNetwork. Le mTLS ou l'authentification propres à chaque service est la seule barrière.
   Un plan par étapes existe dans l'audit (des listes de ports explicites à la place d'`inter_node`, puis un pare-feu d'hôte Talos ou Cilium optionnel en mode audit, puis l'application) ; l'étape 0 est cette page.
3. **`inter_node` d'OVH et Outscale admet tous protocoles et ports entre membres.**
4. **La sortie des nœuds est ouverte** (Scaleway `outbound_default_policy = accept`, OVH des règles de sortie totale explicites, Outscale n'en déclare aucune). Un nœud compromis peut tout joindre ; une liste d'autorisation de sortie risque les téléchargements d'images, les sauvegardes S3 et le premier démarrage, et demande une conception.
5. **Le load balancer applicatif n'a pas de filtre de source par défaut** quand `deploy_app_lb` est vrai : chaque route de la Gateway répond à quiconque pose son en-tête Host, et la connexion propre à la route est sa seule protection
   (`OpenAether-apps/docs/public-exposure.md`, qui liste les routes et la façon dont chacune s'authentifie). `admin_ip` ne garde que le frontal de l'API Kubernetes et le bastion. `admin-access.fr.md` disait la passerelle « rien de public » : corrigé.
   **`app_lb_allowed_cidrs` (vide par défaut, donc rien ne change tant qu'elle n'est pas renseignée) ajoute le filtre chez le provider** : ACL allow puis deny sur les deux frontaux Scaleway, `allowed_cidrs` sur les deux
   listeners OVH, règles de groupe de sécurité Outscale ; Proxmox et local n'ont pas de load balancer cloud. La liste doit contenir tous les clients publics, l'adresse de sortie du cluster est ajoutée automatiquement.
   Vérifié par des assertions de plan seulement (mocké) : qu'un cloud l'applique, que les pods joignent encore Zitadel par le load balancer et que la mise à jour se fait en place sont des contrôles de laboratoire
   (`admin-access.fr.md`, section 6). Elle n'authentifie rien : une adresse listée atteint toujours la connexion de chaque route.
6. **Pas de refus de sortie à l'échelle du cluster** (section 2).

## 7. Écarts consignés

| Écart | Intention de la règle | Ce qui est là à la place | À revoir |
|---|---|---|---|
| Réseau plat, pas de réseau d'administration dédié (PA-022 R15) | Le plan d'administration séparé des charges de travail | Un sous-réseau par provider ; administration par un bastion SSH plus mTLS, avec une liste `admin_ip` devant le bastion et 6443 | Un cloud public n'offre pas de réseau d'administration physique dédié ; à revoir quand un provider offre un VLAN d'admin privé, ou pour Proxmox où l'opérateur maîtrise les bridges |
| Bastion SSH plus mTLS au lieu d'un plan de contrôle IPsec ou WireGuard (décision #82, `admin-access.fr.md`) | Flux d'administration protégés par un tunnel chiffré | Le bastion reste, durci sur place ; le tunnel est SSH, les protocoles internes (API Talos, kube-apiserver) sont en mTLS | Deux opérateurs ou plus, ou un service à état dont la restauration a été exécutée : un émetteur OIDC, une CA SSH ou un plan de contrôle WireGuard demandent chacun un hôte toujours allumé |
| Un sous-réseau pour control planes, workers et bastion | Cloisonnement entre rôles | Non découpé ; Outscale sépare public et privé pour des raisons de sortie, pas d'administration | Sous-réseaux par rôle optionnels sur Scaleway et OVH |
| Trafic pod à pod chiffré par WireGuard de Cilium, pas IPsec | Liens nœud à nœud chiffrés | WireGuard, vu activé par `task cluster-security` | n/a |

## 8. Cadence de revue

Relire cette page, régénérer les tableaux (`scripts/dev/gen-flow-matrix.sh`), et passer les contrôles de `release-checklist.md` (« Quarterly security review ») :

- au moins chaque trimestre, et à chaque release ;
- chaque fois que `security.tf`, un `lb.tf`, une règle du bastion, `admin_ip` ou une politique Cilium de la couche apps change : un changement d'un fichier de groupe de sécurité change aussi les tableaux générés, et le test le dit ;
- après tout incident qui a touché le réseau (`incident-response.fr.md`).

La revue demande : chaque port ouvert de la matrice est-il encore utilisé ; une règle est-elle plus large que sa ligne ne le dit ; un provider a-t-il changé ce que son groupe applique ; une lacune de la section 6 est-elle fermée ou pire ?
