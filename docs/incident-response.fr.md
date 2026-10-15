# Réponse à incident — reconnaître, préserver, contenir, renouveler, restaurer, consigner

🇬🇧 [English version](incident-response.md)

> Écrit pour répondre à la mesure 40 du guide d'hygiène ANSSI et aux règles de recouvrement après compromission de PG-078 (ids d'audit LOG-17,
> F-BKP-10, DP-07, ADM/F11). C'est une **procédure écrite d'après le code et la documentation des outils ; aucune étape n'a été
> exercée face à un incident ou lors d'un exercice**, et aucun délai n'est mesuré. Elle ne revendique aucune conformité à un document ANSSI.
> Signaler une vulnérabilité *dans ce projet* est autre chose : `SECURITY.md`.

La plateforme a **un seul opérateur aujourd'hui** (`admin-access.fr.md`). Il n'y a donc personne d'autre à appeler, pas de permanence 24/7 et pas
de séparation des tâches dans ce qui suit : c'est l'ordre des étapes qui protège, et le registre (section 10) qui rend la réponse d'une seule
personne relisible après coup. Si vous n'êtes pas seul, répartissez les rôles de la section 2 et gardez l'ordre.

## 1. Sources de détection

Aucune ne réveille personne seule si aucune route d'alerte n'est posée (Alertmanager vers Slack, `seed-openbao.sh` ; le dead-man's switch est le seul
signal qui survit à la mort du cluster). Les lire aussi selon un calendrier (`release-checklist.md`, « Quarterly security review »).

| Source | Ce qu'elle montre | Comment la lire |
|---|---|---|
| Alertes de la plateforme applicative (VMAlert) | Objets Flux non Ready ou suspendus, violations Kyverno, OpenBao scellé ou sans nœud actif, séquestre non attesté, jobs de sauvegarde en échec ou absents, horloge et disque des nœuds, rafales de refus de politique | Alertmanager ; la liste et ce qui n'est *pas* couvert : `OpenAether-apps/docs/detection.md` (travail ANSSI apps ; apps 0.2.0 a les règles mais pas cette page) |
| `task cluster-security PROVIDER=…` | La posture de sécurité relue dans le cluster (politiques, mTLS, chiffrement au repos, l'annotation de séquestre) | À lancer après tout soupçon et chaque trimestre ; `ENVIRONMENT=prod` échoue sur un OpenBao de développement |
| `task rbac-review` | Chaque binding RBAC avec ses sujets ; signale un User/Group nominatif, un binding anonyme, un `cluster-admin` inattendu | Lecture seule ; comparer au précédent `rbac-review/rbac-review-<date>.tsv` |
| `task cluster-exposure PROVIDER=…` et `task cluster-netcheck PROVIDER=…` | Quelles adresses publiques répondent, et quels flux les politiques rejettent | Depuis une adresse absente de `admin_ip` (`FROM=denied`) |
| Journaux du bastion | Lignes `Accepted publickey … SHA256:<empreinte>`, sudo, rejets nftables | `scripts/ops/bastion-logs-pull.sh` (quotidien, `OA_LOGS_UPLOAD=1`), puis `scripts/ops/bastion-fingerprints.sh --find SHA256:…` pour nommer le propriétaire de la clé. Sur la VM ils meurent avec elle et ne sont pas infalsifiables |
| Pistes d'audit du cloud | Qui a changé l'IAM, les groupes de sécurité, les buckets, les instances | Scaleway Audit Trail, OVH Activity logs, Outscale API logs, syslog Proxmox : **rien ici ne les exporte** ; exporter à la main |
| Journal d'audit OpenBao | Connexions, usage de jetons, lectures de secrets | Il arrive dans Loki ; aucune règle ne le lit. Chercher dans Loki à la main ; l'alerte d'état scellé est la seule automatique |
| Audit de l'API Kubernetes | `kubectl exec`, nouveaux bindings, qui a lu un Secret | Talos écrit le journal d'audit du kube-apiserver sur le nœud control plane (emplacement amont par défaut `/var/log/audit/kube/kube-apiserver.log` ; vérifier qu'il existe sur votre version) ; **il n'est pas collecté hors du nœud**, il faut donc le lire avant de remplacer le nœud |
| GitHub | Alertes Dependabot et de détection de secrets, workflow quotidien `repo-settings` (dérive des rulesets), rapport Cléa | Onglet sécurité du dépôt et Actions |
| Avis du provider et de l'amont | Avis de compte, avis Talos/Kubernetes/Cilium | `patching.fr.md`, `hardening.fr.md` (la routine de veille) |

**Signes qui appellent cette procédure** : une ligne de connexion dont personne ne reconnaît l'empreinte ; une connexion hors de vos horaires ; une ligne
`rbac-review` que vous n'avez pas créée ; une lecture de Secret, un `exec` ou un nouveau `ClusterRoleBinding` dans l'audit de l'API sans changement correspondant ;
un objet Flux suspendu ou une politique Kyverno passée en Audit sans que ce soit vous ; des objets ou clés que vous n'avez pas créés chez le provider ; un objet de bucket supprimé ;
un portable, un jeton ou un `.env.sh` perdu ; un secret publié (le job gitleaks, ou n'importe quel lieu public).

## 2. Rôles et contacts

| Rôle | Qui | Contact |
|---|---|---|
| Responsable d'incident (décide, tient le registre) | le mainteneur | `<placeholder : canal privé>` |
| Exécutant (lance les commandes) | le mainteneur, ou un second opérateur s'il existe | `<placeholder>` |
| Contact sécurité pour les signalements | signalement privé de vulnérabilité GitHub | le lien de `SECURITY.md` |
| Support du provider, par cloud | `<placeholder : URL du support et référence du compte>` | à garder dans la copie privée |
| CERT national, si le projet héberge un service réglementé | `<placeholder : CERT-FR ou le CERT du secteur>` | à garder dans la copie privée |

Les contacts vivent dans une **copie privée** de ce tableau à côté des tfvars, jamais dans ce dépôt (il est public). Si des données personnelles
peuvent être concernées, évaluer tout de suite l'obligation de notification (une violation de données personnelles est à notifier à l'autorité de contrôle
sous 72 heures après en avoir pris connaissance, RGPD art. 33) ; ce compte à rebours n'est pas géré par cette page.

**Gravité** (une proposition ; la décider dans les premières minutes et la réviser) :

| Niveau | Sens | Exemples | Objectif (proposé, non mesuré) |
|---|---|---|---|
| S1 | Le contrôle du cluster, de l'état ou des sauvegardes est, ou peut être, en des mains hostiles | kubeconfig `system:masters` fuité, K5 ou K7 fuitée, bastion compromis, clé de la CA racine exposée | début du confinement sous 1 heure ; secrets remplacés en environ une journée (PG-078 R26) |
| S2 | Un identifiant à portée limitée a fuité, ou un accès inexpliqué | une paire S3, un opérateur parti, un pod suspect, une connexion inexpliquée | sous un jour ouvré |
| S3 | Une faiblesse, sans signe d'usage | un pin vulnérable, une alerte manquante, un identifiant non secret publié | le délai de correctifs (`patching.fr.md`) |

## 3. La première heure, dans cet ordre

1. **Ouvrir une entrée de registre** (section 10) : heure, qui a remarqué, quoi, gravité. Écrire au fil de l'eau, pas après.
2. **Ne pas aggraver, et ne pas reconstruire encore.** Ne pas lancer `cluster-down`, `rolling-replace`, `tofu apply`, `task teardown-all` ni redémarrer des nœuds
   « pour voir » : un nœud remplacé emporte son disque, sa mémoire, son journal d'audit et les preuves.
3. **Protéger d'abord les sauvegardes** (section 5). Un attaquant qui détient une clé S3 peut supprimer l'état et les snapshots, et aucun verrou d'objet ne l'en empêche.
4. **Préserver les preuves** (section 4) des nœuds concernés.
5. **Contenir** (section 6), **renouveler** (section 7), **trouver et corriger la cause**, et seulement alors **restaurer** (section 8).

## 4. Préserver les preuves avant de remplacer un nœud

Ouvrir les tunnels (`task tunnels-up PROVIDER=…`). `dmesg`, `logs`, `list`, `processes`, `service` fonctionnent avec un fichier `os:reader` de courte durée
(`task talosconfig-new`) ; `read` d'un fichier est refusé à `os:reader` (mesuré, en-tête de `talosconfig-new.sh`) et le snapshot etcd est un appel admin, donc
ces deux-là demandent le `talosconfig` admin, qui est peut-être le fichier volé : les faire tôt, et s'attendre à ce que l'attaquant vous voie. Par nœud concerné,
dans un répertoire hors du dépôt sur un volume chiffré :

```bash
N=<ip du nœud>; D=evidence/$(date -u +%FT%H%MZ)-$N; mkdir -p "$D"
talosctl -n "$N" dmesg                       > "$D/dmesg.txt"
talosctl -n "$N" logs machined               > "$D/machined.log"       # de même apid, kubelet, containerd, etcd sur un control plane
talosctl -n "$N" list /var/log               > "$D/var-log.txt"
talosctl -n "$N" read /var/log/audit/kube/kube-apiserver.log > "$D/kube-apiserver-audit.log"   # control planes
talosctl -n "$N" processes                   > "$D/processes.txt"
talosctl -n "$N" netstat --all --programs    > "$D/netstat.txt"        # vérifier les options avec `talosctl netstat --help`
talosctl -n "$N" service                     > "$D/services.txt"
# une fois, depuis un control plane : le registre de ce que le cluster croyait
talosctl -n <ip d'un control plane> etcd snapshot "evidence/etcd-$(date -u +%F).snap"
kubectl get events -A -o json > evidence/events.json; kubectl get clusterrolebindings,rolebindings -A -o json > evidence/bindings.json
( cd evidence && find . -type f -exec sha256sum {} + > SHA256SUMS )     # puis garder SHA256SUMS à part des fichiers
gpg --symmetric --cipher-algo AES256 -o evidence.tar.gpg <(tar c evidence)    # sous la passphrase d'artefacts (K6), pas dans le dépôt
```

Toutes ces commandes sont en lecture seule sur le nœud. Le snapshot etcd contient chaque Secret **chiffré sous K3, dont la clé est dans la configuration machine** :
il est aussi sensible que le cluster, donc le chiffrer et traiter K3 comme partie de l'incident. Ce qui disparaît quand un nœud est remplacé : la mémoire
(processus, connexions réseau), `/var` (EPHEMERAL, volumes local-path, journal d'audit) et sa clé LUKS. Prendre des images chez le provider (un snapshot du volume de l'instance)
quand il le propose et que le nœud n'est pas encore détruit. Les événements Kubernetes et les journaux Alloy/Loki vivent dans le cluster : en copier d'abord ce dont vous avez besoin.

## 5. Protéger d'abord les sauvegardes

Une copie illisible après l'incident n'est pas une sauvegarde ; une copie que l'attaquant peut supprimer n'en est pas une non plus.

1. Vérifier, depuis une machine **non** impliquée, que le dernier bon jeu existe sur les **deux** stores : `task backup-state PROVIDER=<p> -- --list`,
   `aws s3 ls` sur les buckets d'artefacts (endpoint et identifiants du détenteur), `restic snapshots` sur les deux dépôts. Noter les dates.
2. **Copier le réplica ailleurs** (le bucket de l'autre provider, lu avec sa propre clé) sur un support que vous maîtrisez, avant de rien changer.
3. **Remplacer les clés de stockage objet** (K7) : créer une nouvelle paire chez le provider, la mettre dans `.env.sh` et dans OpenBao (`secret/backup/s3-primary`, `s3-replica`), confirmer qu'une sauvegarde passe,
   **puis** révoquer l'ancienne paire. L'ordre compte : révoquer en dernier, sinon les sauvegardes s'arrêtent. Les paires dédiées aussi (`OA_BACKUP_S3_*`, `OA_BACKUP_REPLICA_S3_*`, `OA_LOKI_S3_*`), de la même façon : nouvelle paire, `bao_admin kv put` sur l'entrée, rafraîchissement de l'ExternalSecret, puis révocation.
4. Si ce qui a fuité est le **mot de passe restic**, une copie du bucket a déjà les données ; voir le tableau de rotation (nouveau dépôt).
5. Le verrou d'objet et le versionnement sont éteints sauf si `backup_immutability` a été positionné (`backup-policy.fr.md`, section 3). Sinon, une clé que l'attaquant détenait pouvait supprimer les copies ; l'activer avant le prochain incident, et **relire les buckets** : `scripts/ops/s3-isolation-check.sh <tfvars>`. L'activer pendant un incident ne protège pas ce qui est déjà supprimé.

## 6. Contenir

- **Ne pas éteindre les nœuds.** Isoler plutôt : resserrer le groupe de sécurité du provider ou la liste d'autorisation du bastion (`admin_ip`) à votre propre adresse, ou retirer le groupe du nœud
  suspect ; sur Scaleway le groupe ne filtre que le trafic public (`network.fr.md`), donc isoler un nœud sur son réseau privé demande l'hôte ou le CNI, pas le groupe.
  `kubectl cordon` du nœud ; suspendre la Kustomization Flux qui applique le changement suspect (`flux suspend kustomization <nom>`) pour que rien ne défasse vos preuves.
- **Un pod suspect** : l'étiqueter et cordonner, le garder (ne pas le supprimer), copier ses journaux et les métadonnées de son système de fichiers, puis l'isoler par une politique Cilium ; le défaut est le refus en entrée à l'échelle du cluster, **la sortie n'est pas refusée à l'échelle du cluster** (`network.fr.md`).
- **Le bastion** : s'il est le suspect, le remplacer (`admin-access.fr.md`, « Fermer la sortie Internet », les adresses `-replace`) après avoir pris ses journaux avec `bastion-logs-pull.sh` ; les tunnels meurent avec lui.
- **Un opérateur parti** (un événement planifié traité comme un S2) : section 7, dernières lignes.

## 7. Tableau de rotation

Ordre : d'abord ce qui laisse l'attaquant revenir, ensuite ce qui protège le reste. Les commandes vivent là où la page de la clé les met ; « qui décide » est le responsable d'incident.
Toutes les procédures sont écrites, **non exécutées** ; les objectifs de temps ne sont pas mesurés.

| Secret (id de clé) | Quand | Comment | Ensuite |
|---|---|---|---|
| Clés de stockage objet (K7), clés du provider (K8) | tout soupçon sur la machine qui détient `.env.sh` | section 5 étape 3 ; chez le provider pour K8 | chercher dans la piste d'audit du cloud ce que l'ancienne clé a fait |
| Clé SSH d'une personne sur le bastion (K9) | opérateur parti ou compromis | `admin-access.fr.md`, départ d'un opérateur : cesser de signer, ou remplacer le bastion avec la clé dans `revoked_keys` | lire la sortie de `bastion-logs-pull.sh` pour ce que la clé a fait |
| Clé privée de la CA SSH (K9) | CA exposée | générer une nouvelle CA, poser `bastion_ssh_ca_public_key`, remplacer le bastion | re-signer pour tout le monde |
| `kubeconfig` / `talosconfig` admin (K2), PKI Talos (K1) | fichier fuité, ou nœud sous contrôle d'un attaquant | `key-management.fr.md` section 3 : nouveau cluster (chemin testé) ou `talosctl rotate-ca` (voie amont, non exécutée) | réémettre chaque fichier, effacer les anciennes générations d'état |
| Passphrase d'état / d'artefacts (K5, K6) | fuitée, ou coffre qui la détient perdu | `key-management.fr.md` section 3 | supprimer les objets sous l'ancienne |
| Clé des Secrets etcd (K3), passphrase des disques (K4) | fuitée avec un snapshot, un disque ou l'état | `key-management.fr.md` section 3 (reconstruction) | considérer chaque Secret comme fuité : renouveler ce qu'ils contiennent |
| Clé de scellement OpenBao (K11) | fuitée avec un snapshot raft ou le PVC | apps `vault/README.md`, « Seal key rotation » (exécuté deux fois sur un cluster) | refaire le séquestre et son attestation |
| Parts de récupération (K10) | un opérateur part, ou perd une clé | `OpenAether-apps/docs/key-inventory.md`, « Replacing a key » : générer un jeton root avec un quorum, `bao operator rekey` vers le nouvel ensemble PGP, révoquer le jeton | mettre à jour `openbao_recovery_pgp_keys` pour les futurs clusters |
| Mot de passe restic | fuité, avec le bucket lisible | `restic key add` / `remove` ; ou un **nouveau dépôt** si l'ancien était lisible par l'attaquant | vider et supprimer l'ancien chemin (`backup-policy.fr.md`) |
| Masterkey Zitadel, mots de passe de bases, passphrase Longhorn, mots de passe Grafana/MinIO | selon l'inventaire apps | `OpenAether-apps/docs/key-inventory.md`, « Replacing a key » | redémarrer les consommateurs ; noter que la masterkey n'a pas de rotation prise en charge et que celle de Longhorn ne doit pas changer sous des volumes chiffrés |
| Secrets CI : `CI_BASTION_SSH_PRIVATE_KEY`, clés provider du sandbox, `CLEA_WORKFLOW_TOKEN`, le compte GitHub | le dépôt ou un compte est suspect | révoquer et réémettre chez l'émetteur ; `supply-chain.fr.md` les liste | revoir les exécutions de workflows et les rulesets (workflow `repo-settings`) |
| Tout ce qui a été publié (un jeton ou une adresse dans un commit) | gitleaks, ou vous l'avez remarqué | révoquer d'abord ; une purge d'historique limite la suite mais « une donnée publiée est publiée » (`CLAUDE.md`) | renouveler tout ce que le fichier fuité listait |
| Comptes humains Zitadel | un compte est suspect | désactiver l'utilisateur dans la console ; le MFA est forcé par la politique apps sur une nouvelle instance | vérifier les rôles Grafana |

`seed-openbao.sh` ne fait que créer (`cas=0`) : une valeur renouvelée est écrite par l'opérateur comme nouvelle version du chemin (inventaire apps), pas en relançant le script.
Une tâche rotate-secret et un mode de remplacement relèvent de l'outillage, hors du périmètre de cette page.

## 8. Restaurer : choisir le point, corriger d'abord la cause

1. **Ne pas restaurer par-dessus la cause.** Savoir comment ils sont entrés et fermer cette porte avant que les données ne reviennent, sinon on restaure la vulnérabilité avec.
2. **Trouver T0**, la plus ancienne trace d'activité hostile. Choisir des points de restauration **antérieurs à T0** : `restic snapshots` (OpenBao, bases), un instant CNPG, une génération d'état ou une copie `pre-upgrade`
   (`task backup-state … -- --list`), un snapshot etcd (`etcd-*.snap.gpg`).
3. Une restauration ramène les secrets de son jour, y compris les fuités. **Renouveler après avoir restauré** (section 7), et traiter un
   OpenBao restauré comme un coffre dont chaque valeur peut être connue de l'attaquant si T0 précède le snapshot.
4. Suivre `disaster-recovery.fr.md` pour l'ordre. Un cluster reconstruit a une nouvelle PKI ; c'est la réponse la plus propre à une PKI Talos compromise.
5. Vérifier avant de déclarer terminé : `task cluster-security`, `task rbac-review` face au fichier d'avant l'incident, `task cluster-exposure`, une connexion à chaque UI.

## 9. Quand l'accès habituel est tombé

- **Zitadel tombé** : seul le SSO de Grafana en dépend ; la connexion locale de Grafana reste active. L'accès au cluster passe par les certificats clients Talos et Kubernetes, et OpenBao s'atteint
  par un jeton de ServiceAccount dans le pod (`bao_admin`). Aucun ne passe par Zitadel.
- **L'API du cluster tombée, le bastion debout** : les tunnels et `talosctl` atteignent encore les nœuds (API Talos sur 50000) : `dmesg`, `logs`, `service`, `etcd status`.
- **Le bastion tombé** : la console du provider, puis un bastion de remplacement (`tofu apply -replace=…`). Aucun état ni `talosconfig` n'est sur le bastion.
- **`kubeconfig` / `talosconfig` perdus** : `task restore-artifacts PROVIDER=… [FROM=replica]` (demande K5 ou K6 et la clé du store).
- **OpenBao scellé ou perdu** : le jeton root de secours demande un quorum de porteurs de parts de récupération (apps `vault/README.md`) ; une restauration demande la clé de scellement séquestrée.
- **Tout perdu sauf les buckets et les passphrases** : `disaster-recovery.fr.md`.

## 10. Registre d'incidents

Une ligne par incident, dans un fichier privé à côté des tfvars (il contient des noms et des heures). Un incident clos sans « cause corrigée » ni « leçons » n'est pas clos.

| Champ | Contenu |
|---|---|
| ID, gravité, ouvert (UTC), clos (UTC) | `IR-2026-001`, S1/S2/S3 |
| Détecté par, et comment | source de la section 1 |
| T0 (plus ancienne trace) et périmètre | quelles clés, nœuds, données |
| Preuves conservées | fichier, SHA-256, où stockées |
| Actions de confinement, avec heures | quoi, qui |
| Secrets renouvelés (liste d'ids de clés), avec heures | numéros K de `key-management.fr.md` |
| Point de restauration choisi et pourquoi | id de snapshot ou de génération |
| Cause, et le changement qui la ferme | issue ou PR |
| Notifications faites ou écartées | qui, quand, pourquoi |
| Leçons, et ce qui change dans les documents | |

Après chaque incident, corriger cette page, `key-management.fr.md` et les alertes qui l'ont manqué, et inscrire l'incident dans `audit-register.fr.md`.
Un exercice de toute la page (un S1 simulé sur un cluster de labo, chronométré) n'a **pas** été mené ; le premier est une tâche de labo (`LAB-CHECKLIST.md`, B13).
