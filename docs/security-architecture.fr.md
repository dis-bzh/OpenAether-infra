# Architecture de sécurité — actifs, chemins d'administration, comment chacun est authentifié et pourquoi, comptes privilégiés, écarts acceptés

🇬🇧 [English version](security-architecture.md)

> Écrit pour répondre aux règles ANSSI sur une architecture de sécurité documentée, une analyse de risque du système d'administration, un choix justifié des moyens d'authentification et un
> inventaire des comptes privilégiés (ids d'audit ADM/F13, ADM/F11, et les parties architecture de NET/F07). Il décrit la plateforme **telle que le code et les documents
> de ce dépôt la présentent** ; ce n'est ni une mesure ni une évaluation par un tiers. Rien ici ne revendique la conformité à un document ANSSI.
> Le côté réseau est `network.fr.md` ; les clés sont `key-management.fr.md` ; le côté CI/CD est `threat-model.fr.md`.

## 1. Ce qui est protégé

| Actif | Où il vit | Pire cas s'il est perdu ou exposé | Protections principales |
|---|---|---|---|
| La racine de confiance du cluster (PKI Talos, K1) et les identifiants admin (K2) | tfstate, configurations machine, le disque de l'opérateur, les deux buckets d'artefacts | Contrôle total de chaque nœud et de l'API Kubernetes | chiffrement côté client de l'état et des artefacts (K5, K6) ; réseau privé ; bastion ; mTLS |
| Secrets Kubernetes et données des disques des nœuds | etcd (secretbox, K3), volumes LUKS (K4) | Divulgation de chaque valeur de secret | chiffrement au repos ; clés détenues dans l'état et les configurations machine |
| OpenBao (tous les secrets applicatifs, l'intermédiaire PKI) | 3 réplicas raft sur des volumes de nœuds, snapshots dans restic | Divulgation ou falsification de chaque identifiant et certificat de la plateforme | clé de scellement (K11) en séquestre, parts de récupération par opérateur, rôles Kubernetes-auth à TTL courts, un journal d'audit |
| Données applicatives (bases Zitadel et Grafana, volumes Longhorn) | CNPG sur volumes local-path, sauvegardes | Perte ou divulgation des identités et des tableaux de bord | chiffrement côté client de restic, archive WAL CNPG (côté serveur seulement), LUKS sur Longhorn |
| Les sauvegardes et le réplica de l'état | buckets chez deux providers | La perte du chemin de retour | deux providers, chiffrement côté client, garde des clés (`backup-policy.fr.md`) |
| Journaux et pistes d'audit | Loki, journal du bastion, pistes d'audit des providers | La perte des moyens d'enquêter | `incident-response.fr.md` ; journaux du bastion extraits de la VM ; pistes des providers exportées à la main |
| Les sources, les pins et la chaîne | dépôts GitHub, Actions, Renovate, l'environnement `sandbox` | Un changement hostile qui atteint un cluster | `threat-model.fr.md` |

## 2. Chemins d'administration

Toute façon dont un humain ou une automatisation peut changer la plateforme, et ce qui se tient devant. **Ce qui n'est pas listé n'est pas censé exister** ; en trouver un est un incident.

| # | Chemin | Qui | Authentification | Autorisation | Où c'est consigné | Notes |
|---|---|---|---|---|---|---|
| P1 | Poste de l'opérateur vers le bastion, SSH 22 | opérateurs ; la CI (`CI_BASTION_SSH_PRIVATE_KEY`) | clé SSH, ou certificat de 8 h de la CA ; clés matérielles `sk-` vérifiables au plan pour les opérateurs nominatifs | la liste d'autorisation `admin_ip` (groupe de sécurité), un compte partagé ou un compte unix par opérateur | ligne de connexion sshd avec l'empreinte de la clé ; le journal extrait par `bastion-logs-pull.sh` | `bastion_ssh_keys` est le chemin d'automatisation et de secours et n'est pas contrôlé côté matériel |
| P2 | Tunnel du bastion vers l'API Talos, 50000 | opérateurs ; le provider Talos pendant `tofu apply` | certificat client Talos (mTLS) | rôle du certificat : `os:admin` (un an) ou `os:reader` (heures) | journaux Talos sur le nœud | l'unique `talosconfig` admin est partagé par chaque tâche et chaque personne |
| P3 | Tunnel du bastion, ou LB de l'API limité à `admin_ip`, vers l'API Kubernetes, 6443 | opérateurs ; Flux (dans le cluster) | certificat client `O=system:masters` (**contourne RBAC et ne peut pas être révoqué**), ou d'autres sujets RBAC | RBAC (`task rbac-review` liste les bindings) | journal d'audit de l'API sur le control plane, non collecté hors du nœud | des identités nommées à courte durée sont un travail prévu, pas fait |
| P4 | `bao_admin` vers OpenBao, par `kubectl exec` | opérateurs détenant `kubectl` admin | un jeton de ServiceAccount est échangé contre un jeton OpenBao dans le pod : aucun jeton OpenBao ne passe par le terminal | politique `openaether-admin` (ne peut ni émettre de jetons, ni écrire politiques ou montages, ni sceller, rekey, ni toucher le stockage brut) ; `openaether-reader` est en lecture seule | journal d'audit OpenBao (dans Loki, aucune règle ne le lit) | qui peut créer un jeton pour le ServiceAccount `openaether-admin` est admin OpenBao : admin Kubernetes l'implique |
| P5 | Jeton root de secours d'OpenBao | le quorum de porteurs de parts de récupération | k parts de récupération sur n déchiffrées PGP, par le rôle `openbao-breakglass` (10 à 15 minutes) | root, puis révoqué | journal d'audit OpenBao | mesuré : 2 parts sur 3 ont produit un jeton sur un vrai cluster |
| P6 | Les UI (Grafana, Zitadel, UI OpenBao) par la Gateway, via le tunnel du bastion | opérateurs | Grafana : OIDC Zitadel (MFA forcé par la politique apps sur une nouvelle instance) ou la connexion admin locale ; Zitadel : sa propre connexion ; UI OpenBao : un jeton OpenBao | par application ; rôles Grafana issus du rôle de projet `grafana-admin` | journaux de l'application | **Chaque route de la Gateway répond aussi par le load balancer applicatif quand `deploy_app_lb` est vrai** : la connexion propre à la route est sa seule protection (`network.fr.md`, section 6) |
| P7 | La console et l'API du provider | le(s) propriétaire(s) du compte | la connexion propre au provider, et les clés d'API K8 | l'IAM du provider (non géré ici) | la piste d'audit du provider, **exportée par rien ici** | hors de ce dépôt ; qui peut changer l'IAM et les groupes de sécurité fait partie de la question d'incident |
| P8 | Les stores objet | l'opérateur, les clusters | paires de clés S3 K7 (valables pour tout le compte par défaut) | la politique de bucket du provider (aucune posée ici) | les journaux du provider | une paire volée peut supprimer les sauvegardes : pas de verrou d'objet |
| P9 | GitHub : pull requests, releases, Actions, l'environnement `sandbox` | le mainteneur ; Renovate ; Cléa | le compte du mainteneur ; les jetons des Apps | rulesets en code (`.github/rulesets`) : pull request obligatoire, pas de force-push ; zéro approbation exigée tant qu'il y a un seul mainteneur | audit GitHub | `threat-model.fr.md` |
| P10 | L'Image Factory et les registres (lecture seule) | nœuds, CI | aucune (publics) | n/a | n/a | épinglés par digest là où le lint peut le vérifier (`supply-chain.fr.md`) |

**Moyens d'authentification, et pourquoi ceux-là.** Talos et Kubernetes utilisent des certificats clients parce que c'est ce qu'ils offrent sans service supplémentaire toujours allumé ; le prix est
qu'un certificat ne se révoque pas, seule sa CA se remplace, d'où les fichiers `os:reader` de courte durée pour le travail en lecture seule et la rotation de K1 documentée. SSH vers le bastion
utilise des clés, avec certificats et clés matérielles en option, car un bastion est le seul hôte qui doit rester joignable quand tout le reste est tombé. OpenBao utilise des rôles Kubernetes-auth
à TTL courts, car un jeton OpenBao de longue durée sur un portable est le risque dont il a été conçu pour s'affranchir. Les humains sur les UI applicatives utilisent l'OIDC Zitadel avec MFA forcé, car c'est le fournisseur
d'identité que la plateforme fait tourner. **Ce qui n'a pas été choisi** : un émetteur OIDC pour l'apiserver, une CA SSH exploitée comme un service, ou un plan de contrôle WireGuard, qui demandent chacun un hôte toujours
allumé hors de tout cluster ; la décision #82 (2026-10-03) garde le bastion, durci sur place, jusqu'à ce qu'il y ait deux opérateurs ou plus ou un service à état dont la restauration a été exécutée.

## 3. Comptes privilégiés

L'inventaire est **un tableau de rôles, tenu à jour à la main** ; les noms des personnes qui détiennent chacun vivent dans une copie privée à côté des tfvars (ce dépôt est public). Revoir à chaque changement de personnel et chaque trimestre (`release-checklist.md`, « Quarterly security review »).

| Compte ou identifiant | Donne | Détenu par | Créé par | Retiré ou révoqué par |
|---|---|---|---|---|
| Compte partagé du bastion `bastion`, clés de `bastion_ssh_keys` | SSH vers le bastion, donc les tunnels | le ou les opérateurs et la CI | tfvars | retirer des tfvars ET remplacer le bastion, ou `revoked_keys` (`admin-access.fr.md`) |
| Comptes nominatifs du bastion (`bastion_admins`), certificats de la CA SSH | la même chose, imputable à une personne | un par personne | tfvars ; la CA | cesser de signer ; retirer et remplacer le bastion |
| `talosconfig` admin (`os:admin`) | toute l'API Talos | le ou les opérateurs | le provider Talos | seulement en remplaçant la CA Talos (`key-management.fr.md`, K1) |
| `kubeconfig` admin (`system:masters`) | tout dans Kubernetes, en contournant RBAC | le ou les opérateurs | le provider Talos | seulement en remplaçant la CA ; `rbac-review` trouve les *autres* bindings |
| talosconfig `os:reader` | lecture seule sur l'API Talos | quiconque en a reçu un | `task talosconfig-new` | expire (8 h par défaut) |
| ServiceAccounts `openaether-admin`, `openaether-reader` et les rôles OpenBao du même nom | admin OpenBao ou lecture seule (jetons de 1 à 8 h) | qui peut créer des jetons pour eux : les admins Kubernetes | la couche apps | désactiver le rôle, ou retirer l'admin Kubernetes |
| Rôle `openbao-breakglass` et les parts de récupération | un jeton root avec un quorum | les porteurs des clés PGP de `openbao_recovery_pgp_keys` | `sys/init` | remplacer par `bao operator rekey` ; une part ne se révoque pas |
| Premier admin Zitadel (`zitadel/admin`) et les humains dans Zitadel | propriétaire IAM ; admin Grafana par les rôles | le premier administrateur, puis des utilisateurs nommés | la couche apps (mot de passe initial dans OpenBao, changement forcé) | désactiver l'utilisateur dans la console |
| Admin local Grafana, root MinIO (clusters locaux) | connexions admin locales | opérateurs | la couche apps | renouveler (inventaire apps) |
| Clés de stockage objet K7, clés du provider K8 | les buckets, l'infrastructure | le ou les opérateurs, CI `sandbox` | le provider | révoquer chez le provider |
| Comptes de console du provider | tout chez le provider | le ou les propriétaires du compte | le provider | le provider |
| Mainteneurs GitHub, relecteurs de l'environnement `sandbox`, jetons Renovate et Cléa | fusionner, publier, lancer le workflow cloud | le mainteneur | GitHub | réglages GitHub ; `supply-chain.fr.md` liste les jetons |

Non couvert : aucun compte n'a d'expiration planifiée sauf les courts cités ci-dessus ; une politique d'expiration d'un an pour les administrateurs Zitadel est un réglage applicatif, non posé ici. Une personne qui part est traitée par `incident-response.fr.md`, section 7, dernières lignes.

## 4. Corrections apportées à `admin-access.fr.md`

L'audit a trouvé deux affirmations que le code contredit ; les deux sont corrigées dans le même changement que cette page.

1. La section 6 disait la gateway sur une adresse privée avec « rien de public ». Avec `deploy_app_lb = true`, le load balancer applicatif transmet les ports publics 80/443 vers les NodePorts de la Gateway, si bien que chaque route répond à quiconque pose son en-tête Host (`network.fr.md`, section 6 ; `OpenAether-apps/docs/public-exposure.md`). L'adresse privée est le chemin d'*administration*.
2. Le paragraphe « policies nominatives » montrait des commandes `bao token create` nues, qui demandent un jeton que cette plateforme ne distribue pas : la page dit elle-même qu'aucun root token n'existe, et `openaether-admin` ne peut explicitement pas émettre de jetons. La section dit maintenant comment un opérateur obtient une identité admin ou en lecture seule (`bao_admin`, avec le ServiceAccount du même nom).

## 5. Écarts acceptés

| Écart | Pourquoi accepté | Où consigné |
|---|---|---|
| `kubeconfig` `system:masters` partagé, non révocable | Kubernetes n'offre pas de révocation de certificat client ; les identités nommées à courte durée ne sont pas construites | `admin-access.fr.md`, `key-management.fr.md` |
| Un seul `talosconfig` d'administration pour chaque tâche et chaque personne | Les rôles Talos existent ; aucune tâche n'émet de certificats par personne | `admin-access.fr.md` |
| Bastion SSH plus mTLS au lieu d'IPsec ou d'un plan de contrôle OIDC | Décision #82 : un hôte toujours allumé hors de tout cluster serait une chose de plus à garder en vie pour un opérateur | `network.fr.md`, section 7 |
| Opérateur unique : pas de séparation des tâches, pas de second dépositaire | Le projet a un mainteneur | `key-management.fr.md`, section 3 |
| Secrets machine livrés par l'API de maintenance de Talos | Conception amont | `first-cluster.fr.md`, « Risque résiduel » |
| Compte SSH de secours partagé à côté des nominatifs | Automatisation et secours | `key-management.fr.md` |
| Verrou d'objet et versionnement des buckets optionnels (`backup_immutability`), non vérifiés chez aucun provider ; les clés S3 du cluster sont celles de l'opérateur sauf si des paires dédiées sont données | Le support des providers et la politique de clés ne sont pas décidés | `backup-policy.fr.md`, sections 3 et 4 |

## 6. Revue

Relire à chaque nouveau chemin d'administration, moyen d'authentification, compte privilégié, provider ou écart ; après chaque incident ; chaque trimestre avec la check-list ; au moins une fois par an avec le registre d'audit (`audit-register.fr.md`). Un chemin sans ligne en section 2 est un défaut, qu'il soit documenté ailleurs ou non.
