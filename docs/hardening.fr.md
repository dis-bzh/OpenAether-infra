# Socle de durcissement — ce que Talos apporte par conception, ce que ce dépôt ajoute, et ce qui est un écart écrit

🇬🇧 [English version](hardening.md)

> Écrit pour répondre aux recommandations ANSSI sur la configuration système et l'usage d'OpenSSH (le guide de configuration GNU/Linux BP-028 et la note OpenSSH DAT-NT-007), et sur
> la veille de vulnérabilités (id d'audit OSN/F18 ; DP-17 pour l'unique risque résiduel). C'est un tableau de correspondance et un registre d'écarts : **une ligne « par conception » est ce que dit la
> documentation amont de Talos, pas quelque chose de mesuré sur cette plateforme**, et aucune ligne n'est une revendication de conformité à un document ANSSI. Les numéros d'exigences sont ceux que l'audit a consignés ; lire le guide pour ce que chacun demande.
> Écrit ailleurs : le délai de correctifs et les signaux (`patching.fr.md`), les pins et la chaîne d'approvisionnement (`supply-chain.fr.md`), les mises à jour (`upgrade.fr.md`), le réseau (`network.fr.md`).

Deux sortes d'hôtes sont durcies différemment. Les **nœuds Talos** n'ont ni shell, ni SSH, ni gestionnaire de paquets et ne se pilotent que par une API authentifiée : l'essentiel d'un guide Linux ne
s'y applique pas, et ce qui s'y applique tient surtout à ce que Talos livre. Le **bastion** est une VM Ubuntu ordinaire et c'est là que le guide Linux s'applique au sens habituel.

## 1. Nœuds Talos : correspondance

Légende : **Conception** = vrai de Talos par construction (amont) ; **Contrôle** = quelque chose que ce dépôt pose ; **Écart** = une différence écrite avec la recommandation.

| Thème (ids d'audit) | Conception | Contrôle ici | Statut |
|---|---|---|---|
| Système minimal, pas de logiciel inutile (BP-028 minimisation) | Pas de gestionnaire de paquets, pas de shell, pas de démon SSH, racine en lecture seule | aucun nécessaire | Conception |
| Canal d'administration (NT-007 ne s'applique pas : pas de sshd sur les nœuds) | API Talos en mTLS avec des rôles (`os:admin`, `os:reader`) | Accès seulement par le tunnel du bastion ; `task talosconfig-new` pour des fichiers en lecture seule de courte durée | Conception + contrôle ; le fichier admin partagé est un écart (`security-architecture.fr.md`) |
| Chiffrement des disques (thèmes stockage de BP-028) | Prise en charge de LUKS2 | STATE et EPHEMERAL (et volumes utilisateur) chiffrés, clé K4 dans la configuration machine | Contrôle. Limite dite dans le module : il ne protège pas d'une compromission à l'exécution |
| Secrets au repos dans Kubernetes | secretbox ou aescbc seulement | secretbox (K3) | **Écart** : XSalsa20-Poly1305 n'est pas parmi les modes AEAD que liste PA-079 R12 ; Talos n'offre rien d'autre d'approchant (`upgrade.fr.md`) |
| Intégrité du démarrage : Secure Boot, vérification de l'UKI signée (R2, R3, R6) | Les images Talos savent être des UKI, la vérification demande l'enrôlement Secure Boot | **Non activé** chez aucun provider ; aucun contrôle ne lit l'état du secure boot | **Écart / non fait** : demande une variante d'image, un changement de schematic et OVMF sur Proxmox, validés sur un vrai hôte ; les images personnalisées de Scaleway, OVH et Outscale ne l'exposent pas, pour autant que ce dépôt le sache. Limite du provider, pas une décision |
| Ligne de commande du noyau, SELinux (R8, R37, R46) | Le noyau Talos suit KSPP (`slab_nomerge`, `pti=on` d'après l'audit) ; SELinux tourne en permissif | pas d'arguments noyau supplémentaires (`machine.install.extraKernelArgs` non posé) | **Écart** : des arguments de mitigation comme `spectre_v2`, `mds`, `init_on_alloc` ne sont pas posés ; à compléter avec le travail de socle des nœuds (lot d'audit B23) |
| Valeurs sysctl (R9, R10, R12, R13) | Talos pose un jeu par défaut orienté KSPP | pas de `machine.sysctls` posé | **Ouvert** : les valeurs à poser et les exceptions justifiées se décident avec le socle des nœuds (B23). Exceptions écrites déjà connues : `net.ipv4.ip_forward=1` (Kubernetes et Cilium ont besoin du routage), `kernel.pid_max=262144` (au-dessus de la valeur du guide, densité de pods Kubernetes), chargement de modules après le démarrage |
| Modules noyau (`modules_disabled`) | Talos impose des modules **signés** plutôt que de figer le chargement | aucun | **Écart, par conception** : Cilium (tunnels, WireGuard) et Longhorn (iSCSI) chargent des modules après le démarrage, donc `kernel.modules_disabled=1` n'est pas utilisé ; l'imposition de signature est la compensation (amont, non vérifiée ici) |
| Audit et journaux (R71, R73, R76) | Journaux de services et du noyau sur le nœud ; un journal d'audit du kube-apiserver sur les control planes | Les journaux du bastion sont extraits et envoyés ; les journaux des nœuds Talos et l'audit de l'API **ne sont pas expédiés hors du nœud** | **Ouvert** : ils disparaissent avec le nœud. `incident-response.fr.md` section 4 dit de les copier d'abord |
| Mises à jour (R61) | Image immuable remplacée par mise à niveau, pas corrigée sur place | Procédure `upgrade.fr.md` ; délai `patching.fr.md` ; Renovate et Cléa | Contrôle ; pas d'application automatique, par conception |
| Sécurité des pods (R64, R65) | n/a | Pod Security Admission baseline sur les namespaces gérés ; politiques Kyverno, surtout en Audit | **Ouvert** : Enforce est une décision ultérieure (apps) |
| Secrets machine livrés à un nouveau nœud (DP-17) | Application en mode maintenance avec un certificat invérifiable | réseau privé, tunnel SSH, 50000 depuis le bastion seulement (OVH, Outscale) | **Risque résiduel** : `first-cluster.fr.md`, « Risque résiduel : l'application en mode maintenance » |

## 2. Bastion : correspondance

Tout est optionnel et **désactivé par défaut** : avec les valeurs par défaut le cloud-init est octet pour octet ce que 0.1.0 livrait (`admin-access.fr.md` pour le comment, `CHANGELOG.md` pour le palier). Les numéros d'exigences sont ceux nommés dans les entrées du CHANGELOG.

| Thème | Sans les options | Avec les options | Statut |
|---|---|---|---|
| sysctl, durcissement du noyau (R9, R11, R12, R14) | Défauts Ubuntu | fichier sysctl `bastion_baseline`, sans `modules_disabled` et sans les options ARP | Contrôle (optionnel). Écart : les modules restent chargeables (le noyau Ubuntu charge des pilotes à la demande) |
| Audit (R73), journald | Défauts Ubuntu | auditd avec règles execve/`/etc`/mount/module/ptrace et sans `-e 2` (immuable) pour qu'une règle puisse être corrigée sans redémarrage ; journald persistant, 200 Mo, 90 jours | Contrôle (optionnel). Écart : pas de règles d'audit immuables |
| Montages, umask, sudo, paquets (R28, R29, R36, R38, R58) | Défauts Ubuntu | `/var/tmp` noexec, `/boot` 700, umask 0077, sudo restreint, pas de tcpdump/netcat sur les nouvelles VM | Contrôle (optionnel) |
| Directives sshd (NT-007 R14, R15, R23, R24, R26) | clé seule, pas de root, `AllowGroups bastion-admins`, chiffrements modernes, `MaxAuthTries 3`, `LoginGraceTime 30`, keep-alives | `LogLevel VERBOSE`, `StrictModes`, `PermitUserEnvironment no`, `AllowStreamLocalForwarding no`, `GatewayPorts no`, `RevokedKeys`, `AcceptEnv` commenté | Contrôle (la base est toujours active) |
| Clé d'hôte (NT-007 R6) | Acceptée à la première utilisation | `OA_BASTION_PIN_HOSTKEY` la garde et la vérifie | Contrôle (optionnel) ; un certificat d'hôte n'est pas fait |
| Identité et révocation (NT-007 R30, PA-022 R21) | Un compte partagé | `bastion_admins`, CA SSH, `revoked_keys`, contrôle optionnel de clé matérielle | Contrôle (optionnel) |
| Sortie (PA-022 R10) | 80/443 vers n'importe où | `bastion_internet_egress = closed` | Contrôle (optionnel) : le bastion se met à jour par remplacement |
| Échange de clés : hybride post-quantique (TLS-19) | `KexAlgorithms` est une liste classique explicite | indisponible dans OpenSSH 8.9 d'Ubuntu 22.04 | **Écart** : l'hybride `sntrup761x25519` vient avec une image de bastion sous 24.04, qui remplace le bastion ; `key-management.fr.md` section 5 |

**Tunnels (NT-007 R5, tel que l'audit le lit).** La recommandation est d'éviter le transfert SSH sauf nécessité. Le bastion existe pour transférer : les nœuds n'ont pas d'adresse publique, et un transfert
TCP est le seul chemin depuis la machine d'un opérateur vers l'API Talos (50000) et l'API Kubernetes (6443). Compensations : `AllowTcpForwarding yes` est associé à **`PermitOpen` limité aux ports 6443 et 50000** (et 8200 seulement
avec la sortie `legacy` ; le mode fermé l'enlève), `X11Forwarding no`, connexion par clé seule limitée au groupe `bastion-admins`, la liste `admin_ip` devant le port 22, et les comptes nominatifs et certificats optionnels.
Non compensé : `PermitOpen` nomme des ports et pas des hôtes (`*:6443`), donc un transfert vers n'importe quelle adresse joignable sur ces ports est permis ; la restriction de destination est le groupe de sécurité et la sortie fermée.

## 3. Écarts écrits (le registre)

| # | Écart | Guide | Raison | Compensation | Décision du propriétaire |
|---|---|---|---|---|---|
| H1 | Pas de Secure Boot / vérification d'UKI signée | BP-028 R2, R3, R6 | Travail d'image, de schematic et d'OVMF ; non exposé par trois providers | Verrou de sommes de contrôle des images (`supply-chain.fr.md`) pour ce qui est téléchargé ; disques chiffrés | Ouvert jusqu'à une qualification de provider |
| H2 | secretbox au lieu d'un mode AEAD pour les Secrets etcd | PA-079 R12 | Talos n'offre que secretbox et aescbc | Clé forte, ne quitte jamais l'état ni les configurations machine ; un KMS serait circulaire dans le cluster | À revoir avec un KMS hors du cluster |
| H3 | `modules_disabled` non posé sur les nœuds | règles BP-028 sysctl et modules (F03 de l'audit) | Cilium et Longhorn chargent des modules après le démarrage | Imposition de modules signés par Talos (amont) | Permanent sauf changement de CNI |
| H4 | `ip_forward=1`, `pid_max=262144`, autres sysctl aux défauts Talos | BP-028 R9, R12, R13 | Kubernetes et Cilium ont besoin du routage et d'un plafond de pid élevé ; le reste n'est pas encore décidé | rien au-delà des défauts Talos | Clos par le lot de socle des nœuds (B23) |
| H5 | SELinux permissif, arguments de mitigation noyau absents | BP-028 R8, R37, R46 | Défauts Talos | aucune | Clos par B23 si décidé |
| H6 | Transfert SSH activé sur le bastion | NT-007 R5 | C'est le chemin d'administration | ports `PermitOpen`, groupe, liste d'autorisation | Permanent tant que le bastion est la conception (#82) |
| H7 | KEX classique sur le bastion, pas d'hybride post-quantique | TLS-19 | OpenSSH 8.9 sur Ubuntu 22.04 | TLS et mTLS internes des protocoles tunnelés | Changement d'image du bastion |
| H8 | Secrets machine envoyés par l'API de maintenance non authentifiée | DP-17 | Amorçage de Talos | réseau privé, tunnel, 50000 depuis le bastion seulement | Permanent (amont) |
| H9 | Les journaux d'audit des nœuds et de l'API ne sont pas expédiés | BP-028 R71 | Non construit | copie à la main avant remplacement | Ouvert |

## 4. Veille de vulnérabilités et routine de correctifs

Le délai et les signaux sont dans `patching.fr.md` ; cette section est la routine qui les fait arriver. **C'est un calendrier pour une personne, pas un service.**

| Quand | Quoi | Où va le résultat |
|---|---|---|
| Chaque jour, automatique | PRs Renovate (âge de release 7 jours, jamais fusionnées automatiquement ; `vulnerabilityAlerts` contournent l'âge) ; rapport de Cléa avec les avis sur les pins (OSV) et les pins en retard de plus de deux mineures | Les PRs et l'issue/le rapport de Cléa |
| Chaque semaine, automatique | `image-digests.yml` (tags Flux déplacés), le job SBOM avec Trivy sur les images de bootstrap | Résultats des workflows |
| Chaque semaine, à la main (15 minutes) | Lire le flux d'alertes et d'avis du **CERT-FR** pour les produits ci-dessous ; les **GitHub Security Advisories** de Talos, Kubernetes, Cilium, Flux, OpenTofu et des providers ; les notes de version de Talos et Kubernetes | Une issue par avis pertinent, nommant le composant, l'avis, et la décision (corriger / reporter jusqu'au `<date>` / non concerné) |
| Sous 30 jours après un correctif (7 jours si exploité dans la nature ou joignable depuis Internet) | Fusionner la mise à jour par le palier qu'elle exige (`CONTRIBUTING.md`), ou la reporter par écrit avec une échéance | La PR / l'issue de report ; une déclaration VEX quand un résultat de scanner ne s'applique pas (`component-selection.fr.md`) |
| Chaque trimestre | Le contrôle du calendrier de fin de support et la revue du registre (`release-checklist.md`, « Quarterly security review ») | `audit-register.fr.md` |

Produits à surveiller : Talos Linux, Kubernetes, Cilium, Flux, OpenTofu et ses providers, Ubuntu (l'image du bastion), OpenSSH, et, dans `OpenAether-apps`, Istio/Envoy, cert-manager, CNPG/PostgreSQL, OpenBao, Kyverno, Longhorn, Zitadel. Un nouveau produit sur la plateforme reçoit une ligne dans `component-selection.fr.md` et un nom sur cette liste.
Un avis trouvé hors routine (CERT-FR, un provider, une liste de diffusion) est traité de la même façon et ouvre une entrée d'incident si la plateforme est exposée (`incident-response.fr.md`).

## 5. Revue

Relire à chaque mineure de Talos ou Kubernetes, chaque changement du socle du bastion, chaque audit, et au moins une fois par an. Les lignes marquées Ouvert sont closes ou re-justifiées quand le lot de socle des nœuds arrive ; d'ici là elles restent ici.
