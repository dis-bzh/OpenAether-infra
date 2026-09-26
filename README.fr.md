# OpenAether-infra

> **Store Anywhere, Run Anywhere.**
> Un cluster Talos idempotent sur n'importe quel environnement — local (Docker),
> on-prem (Proxmox) ou cloud (Scaleway/OVH/Outscale) — avec un seul socle figé :
> **Cilium**. Les applications sont un choix distinct, dans `OpenAether-apps`.

🇬🇧 [English version](README.md)

## Par où commencer

Deux profils différents arrivent ici, et ils ne cherchent pas la même page.

**Vous voulez un cluster.** Commencez par celui qui ne demande ni compte ni
credentials — `task local-up` monte un cluster Talos de six nœuds dans Docker.
Puis [Démarrage rapide](#démarrage-rapide) pour un cloud, ou
[`docs/first-cluster.fr.md`](docs/first-cluster.fr.md) pour la version pas à pas,
de la machine nue à un cluster qu'on rejoint, met à jour et détruit.

**Vous voulez contribuer.** [`CONTRIBUTING.md`](CONTRIBUTING.md) porte les règles
qui ne se devinent pas — ce qui compte comme preuve, les trois barreaux qu'un
changement doit gravir, et comment se signe un commit écrit avec une IA. Le
travail ouvert est dans [les issues](https://github.com/dis-bzh/OpenAether-infra/issues), et chacune
nomme le barreau qu'elle exige : `task test` et `mocked` sont celles qu'on peut
fermer sans compte cloud.

## Version

**0.1.0** — publiée le 2026-08-20 en pré-version. Infrastructure seule. Cinq
choses et rien d'autre :
déployer, un cluster HA sain (Talos + Cilium), l'idempotence, les upgrades
Kubernetes et Talos, et un état OpenTofu chiffré côté client dans S3 avec un
réplica optionnel chez un second provider. kubeconfig et talosconfig sont
traités pareil.

Flux est présent dans le code et **désactivé** (`deploy_flux = false`) ; il
redevient un choix utilisateur dans une version ultérieure. Tous les tags et
toutes les releases 1.x ont été supprimés et aucun n'a jamais tourné — **la
0.1.0 est la première version qui livre quelque chose de prouvé**.

**Statut honnête**, mesuré sur des comptes réels — trois clouds, les mêmes cinq
piliers sur chacun. Scaleway depuis un compte vide le 2026-08-19 : déploiement
en 8 min 50 pour 72 ressources, `cluster-verify` 11/11, idempotence 3/3,
Kubernetes v1.36.2 → v1.36.3 puis Talos v1.13.7 → v1.13.8, confirmés sur 6/6
nœuds par l'API Talos de chaque nœud. OVH le même jour, Outscale le 2026-08-20.
Un upgrade n'est pas transparent : coupure d'apiserver la plus longue 5 s sur
Scaleway, 7 s sur OVH, 8 s sur Outscale — toutes trois pires que les meilleurs
chiffres jamais relevés par ce projet, pour une raison qui n'est pas établie.
Proxmox n'a **jamais été appliqué sur matériel réel**. Points ouverts :
[les issues ouvertes](https://github.com/dis-bzh/OpenAether-infra/issues).

## Architecture

```
Un cluster Talos autonome (socle figé : Cilium)
  └── PLUS TARD, une pioche modulaire dans OpenAether-apps (scripts/pick.py) :
      OpenBao, ESO, cert-manager/PKI, Istio ambient, gateway, CNPG,
      Longhorn, observabilité, Zitadel, Kyverno, backups restic…

Surcouche OPTIONNELLE — cluster de management (CAPI pioché) :
  Management (hub) ──CAPI+Talos──▶ clusters clients (kubeception)
                    ──Flux kubeConfig──▶ Cilium+Flux injectés à distance,
                    puis chaque enfant réconcilie SON profil git (gitception)
```

**Principe de conception** : le cluster de management n'est **pas** sur le
chemin de données des clients. S'il devient indisponible, les workloads
continuent de tourner — chaque enfant a son propre Flux.

## Deux façons d'amorcer le premier cluster

| Voie | Quand | Ce qu'elle crée |
|---|---|---|
| **OpenTofu** (défaut) | Tous les cas courants | Tout le substrat : réseau, routeur, security groups, LB, bastion, volumes, buckets S3 — puis Talos |
| **CAPI** (optionnel) | On veut un management décrit comme les autres clusters, et l'outillage day-2 de CAPI | Un cluster jetable crée le management, qui devient ensuite autogéré (`clusterctl move`) |

La voie CAPI **ne remplace pas** OpenTofu : sur OVH, OpenTofu crée ~44
ressources dont 3 seulement sont des instances. C'est une surcouche optionnelle
et **la 0.1.0 ne déploie aucun CAPI** — la procédure est conservée pour la
version qui le fera : **[docs/capi-bootstrap.fr.md](docs/capi-bootstrap.fr.md)**.

## Statut des couches

| Couche | Technologie | Statut |
|--------|-------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.13.x (immuable) | ✅ |
| **CNI** | Cilium 1.20.2 (WireGuard) | ✅ livré, manifeste inline — toute la plateforme de la 0.1.0 |
| **GitOps** | Flux v2.9.3 | ⬜ code présent, `deploy_flux = false` — redeviendra un choix dans une version ultérieure |

Tout le reste — secrets, PKI, mesh, base de données, stockage, identité,
observabilité, policy, Cluster API — vit dans
[`OpenAether-apps`](https://github.com/dis-bzh/OpenAether-apps) et n'est **pas
déployé par cette version**. Les versions que ce tableau listait étaient celles
de cet autre dépôt, et aucune chaîne de caractères ici ne pouvait les confirmer.

## Providers

Même contrat pour tous (`modules/providers/provider-contract.md`) — le stack
Talos/cluster est provider-agnostique. Détail : `docs/deployment-test-matrix.fr.md`.

| Provider | Statut | Région / cible | Notes |
|----------|--------|----------------|-------|
| **Scaleway** | ✅ cinq piliers mesurés le 2026-08-19 | fr-par (3 AZ) | Implémentation de référence ; déploiement, vérification, idempotence et les deux upgrades |
| **OVH** | ✅ les mêmes cinq, le même jour | EU-WEST-PAR (OpenStack) | LB Octavia, floating IPs, routeur SNAT, réseau privé |
| **Outscale / Numspot** | ✅ les mêmes cinq, mesurés le 2026-08-20 | eu-west-2 | Redéployé sur un **Net neuf** après un timeout interne du service LBU en amont, qui en avait laissé un coincé en `provisioning` (demande 399530, close). Deux cicatrices : un Net créé avant ce correctif refuse toujours la suppression et seul le provider peut le lever, et son object store ignore `If-None-Match`, donc le verrou d'état `use_lockfile` est délibérément désactivé ici |
| **Proxmox (on-prem)** | 🧪 code-complet, testé unitairement — **jamais appliqué en réel** | PVE mono/multi-hôte | VIP Talos (pas de LB managé), NAT/DNAT nftables, prérequis manuels |
| **Local (Docker)** | ✅ validé (`task local-up`) | WSL2 / Docker | 3 CP + 3 workers, quorum etcd, Cilium — preuve sans credentials de `modules/talos` |

## Structure du dépôt

```
infrastructure/opentofu/
  cluster/        # racine cluster (management + workload) ; envs/ = un tfvars par cluster
  talos-image/    # constructeur d'image, state à part
  opentofu-local/ # racine Docker locale, réutilise modules/talos
  modules/talos/  # secrets, config, bootstrap — provider-agnostique
  modules/providers/{scw,ovh,outscale,proxmox,local}/   # provider-contract.md = le contrat
scripts/
  bootstrap/  # cycle de vie (rare)
  ops/        # exploitation : fleet-down, edge-down, rolling-replace, etcd-snapshot,
              # preflight-quotas, check-cilium-parity, purge-orphans…
  internal/   # appelés par le Taskfile
```

Les manifests Kubernetes vivent dans
[dis-bzh/OpenAether-apps](https://github.com/dis-bzh/OpenAether-apps).

## Démarrage rapide

> **Première fois ?** Lis plutôt **[docs/first-cluster.fr.md](docs/first-cluster.fr.md)** :
> le même chemin, pas à pas, avec chaque valeur à fournir, ce que crée chaque
> commande, ce qui te dit qu'elle a marché, et la liste honnête de ce qui n'est
> pas encore prouvé. Ce qui suit est la forme courte, pour qui l'a déjà fait.

### Prérequis

```bash
./scripts/setup.sh          # tofu, talosctl, kubectl, task, helm, yamllint…

# Pour le CLOUD uniquement — le test local n'a besoin d'aucun credential.
cp .env.example .env.sh     # puis l'éditer
source .env.sh              # git-ignoré ; contient aussi TF_VAR_encryption_passphrase
```

⚠️ **Toujours `source .env.sh` avant un `task` qui touche au cloud.** Sans lui,
`tofu` réclame `var.encryption_passphrase` en interactif et la commande échoue —
y compris un teardown, qui peut alors sembler réussi sans rien détruire.

### Cluster local (Docker — sans cloud ni credentials)

Monte un vrai cluster Talos **3 control planes + 3 workers** dans Docker, sur le
**même `modules/talos/` qu'en production**. C'est le meilleur premier pas.

```bash
task local-up        # déploiement complet
task local-status    # membres etcd + nœuds + Flux
task local-down      # destruction (conteneurs + volumes + state)
```

⚠️ **Sous Windows/WSL2** : Hyper-V réserve des blocs de ports au-dessus de
49152, et ces blocs bougent au redémarrage. La base des ports hôte est donc
paramétrable (`talos_api_port_base`, défaut 45000). Diagnostiquer avec
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

### Cluster de management (cloud)

```bash
source .env.sh

cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \
   infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
```

Six champs n'ont pas de valeur par défaut et le déploiement ne démarrera pas sans
eux. Tout le reste de l'exemple a déjà une valeur qui fonctionne.

| champ | quoi mettre dedans |
|---|---|
| `environment` | `dev` ou `prod` — rien d'autre n'est accepté. Il nomme les buckets et les ressources, et `prod` exige en plus que `s3_replica_endpoint` soit sur un **autre** provider : `task cluster-up` refuse avant de dépenser s'il est sur l'endpoint ou le cloud du primaire, sauf si le nom du cluster a déjà un objet d'état (il avertit alors seulement) |
| `admin_ip` | ton IP publique en CIDR. C'est la liste d'autorisation SSH **et** l'ACL du LB apiserver |
| `s3_primary_endpoint` / `s3_primary_region` | le S3 du tfstate chiffré, chez le **même** provider que le cluster (ex. `https://s3.fr-par.scw.cloud` / `fr-par`) |
| `s3_replica_endpoint` / `s3_replica_region` | le S3 de la **copie de sauvegarde**. En production, chez un **autre provider** — un état qu'on ne peut lire que depuis le cloud qui vient de tomber n'est pas une sauvegarde. Il s'ouvre avec les clés `<PU>_AWS_*` de CE cloud-là : un réplica Outscale lit `OUTSCALE_AWS_*` |

Et `bastion_ssh_keys` : la moitié **publique** de la clé que tu passeras en `KEY=`.
Les deux forment une paire, et `task cluster-up` refuse de démarrer si elles ne
correspondent pas — avant toute dépense. Ainsi que `git_repo_url` + `git_ref` si
tu utilises ton propre fork d'OpenAether-apps ; les défauts pointent sur le
nôtre, et son `apps/clusters` n'est pas le tien.

```bash
# Quotas : OVH et Outscale uniquement — le script ne couvre pas Scaleway.
# Sur Scaleway, vérifie la console : 3 control planes + 2 workers demandent
# 5 instances du type de ton tfvars, et un compte neuf peut être plafonné à 1.
task preflight-quotas PROVIDER=ovh

task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
task cluster-verify PROVIDER=scaleway               # demander au cluster, pas à l'outil
```

`task cluster-up` est la commande unique, et elle est idempotente : elle construit
l'image Talos si le compte ne l'a pas, rend les manifests de bootstrap, applique
l'infrastructure, ouvre les tunnels et amorce Talos. Relance-la après avoir
corrigé une erreur, elle reprend. C'est aussi la commande que joue la CI, donc
le chemin qui est réellement validé. Les étapes séparées (`task image-build`,
`task infra-apply`, `task bootstrap-phase2`) restent disponibles pour n'en piloter
qu'une.

**Après le déploiement** : `task cluster-verify` est tout le parcours jour-1
d'un cluster d'infrastructure seule. Celui de la plateforme applicative — escrow,
signature offline de la PKI, accès aux UIs — est
[docs/admin-access.fr.md](docs/admin-access.fr.md), et il appartient à la version
qui déploie des applications.

### Teardown

Deux commandes, toujours, et aucun drapeau ne les réduit à une.

```bash
source .env.sh
task cluster-down PROVIDER=ovh                                    # calcule, ne détruit rien
task cluster-down PROVIDER=ovh PLAN=destroy-management-ovh.tfplan APPROVE=auto
python3 scripts/ops/purge-orphans/ovh.py    # dry-run : vérifier qu'il ne reste rien
```

Même vocabulaire que `cluster-up`. `fleet-down` écarte toujours les enfants CAPI
d'abord, mais il lit désormais pourquoi la requête a échoué : des CRDs absents
signifient qu'il n'y en a aucun par définition, et il le dit. `--force-no-edges`
reste une porte de sortie pour un cluster qu'il n'arrive pas du tout à joindre.

⚠️ Les floating IPs pré-allouées hors OpenTofu ne partent pas seules.

### Cloud émulé (Feint — sans compte cloud, sans credentials)

Pointe les **vrais** providers Scaleway et Outscale vers un émulateur local de
leurs APIs. Un cran au-dessus du `tofu test` mocké : vrai HTTP, vrai décodage,
aucune facture.

```bash
task feint-up                        # démarre l'émulateur (binaire épinglé, checksum vérifié)
task feint-plan   PROVIDER=scaleway  # plan du VRAI root cluster, zéro credential
task feint-apply  PROVIDER=outscale  # cycle apply/destroy sur la fixture réduite
task feint-record PROVIDER=scaleway  # classe les opérations qu'on appelle et qu'aucun pack ne sert
task feint-down
```

⚠️ Ça ne prouve **pas** qu'un déploiement réel fonctionne — l'émulateur n'a ni
inventaire, ni load balancer, ni quotas. Cf.
[docs/emulated-cloud.fr.md](docs/emulated-cloud.fr.md).

### Contrôles statiques (sans cloud ni Docker)

```bash
task validate            # tofu fmt/validate/test
task apps-validate       # intégrité du DAG Flux + profils pick.py à jour
task security            # contrôles de durcissement
```

## Documentation

| Fichier | Contenu |
|---|---|
| [docs/first-cluster.fr.md](docs/first-cluster.fr.md) | **Commence ici.** De la machine nue à un cluster joignable, upgradable et destructible — et ce qui n'est pas prouvé |
| [docs/admin-access.fr.md](docs/admin-access.fr.md) | Parcours jour-1 de la plateforme applicative : escrow, PKI offline, accès UIs, tests navigateur. **Inutile pour un cluster d'infrastructure seule** |
| [docs/capi-bootstrap.fr.md](docs/capi-bootstrap.fr.md) | Amorcer un management par CAPI et le rendre autogéré |
| [docs/deployment-test-matrix.fr.md](docs/deployment-test-matrix.fr.md) | Ce qui est validé, où, et comment |
| [docs/emulated-cloud.fr.md](docs/emulated-cloud.fr.md) | Tester Scaleway/Outscale contre un émulateur local — et les limites de l'exercice |
| [docs/upgrade.fr.md](docs/upgrade.fr.md) | Faire bouger Kubernetes et Talos sur un cluster qui doit rester debout |
| [docs/release-checklist.md](docs/release-checklist.md) | Ce qu'il faut lancer avant de taguer, dans l'ordre qui échoue le moins cher |
| [docs/status.md](docs/status.md) | **Source de vérité** : état courant, dette, améliorations (anglais seulement) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | **À lire avant une première pull request** : ce qui compte comme preuve, les trois barreaux, les trailers de commit, les contributions assistées par IA |

## Sécurité

| Contrôle | Mise en œuvre |
|----------|---------------|
| Aucune IP publique sur les nœuds | VPC seul, tunnel SSH via bastion |
| SSH bastion | Utilisateur dédié non privilégié, clé uniquement (root et mots de passe désactivés) |
| Chiffrement du state | AES-GCM + PBKDF2 côté client (`encryption{}`) avant S3 |
| Chiffrement des artefacts | gpg AES-256 authentifié côté client, + SSE S3 par-dessus |
| Réplication / DR | State et artefacts miroités vers un store `-backup` (prod : autre provider, credentials séparés) |
| Accès API Kubernetes | ACL du LB restreinte à `admin_ip` |
| Accès API Talos | Tunnel SSH uniquement (port 50000, jamais sur le LB) |
| Chiffrement inter-nœuds | Cilium WireGuard |

## Roadmap

| Version | Livrable | Statut |
|---------|----------|--------|
| **0.1.0** | Un cluster Talos + Cilium sur Scaleway, OVH ou Outscale, état et artefacts chiffrés, upgrades en place | ⏳ première version |
| suivante | Flux redevenu un choix utilisateur, puis la pioche modulaire dans `OpenAether-apps` | ⏳ prévu |
| plus tard | Surcouche CAPI : un cluster de management pilotant des enfants | ⏳ prévu |
| ouvert | Proxmox sur matériel réel, le failover cross-provider complet, le Net Outscale que seul le provider peut supprimer | ⏳ |

## Licence

**OpenAether** est distribué sous [licence Apache 2.0](LICENSE). Le projet était
sous AGPLv3 plus tôt dans son histoire ; le changement est un assouplissement, donc
ce que vous déteniez déjà sous AGPLv3 le reste.

Source : **https://github.com/dis-bzh/OpenAether-infra**
