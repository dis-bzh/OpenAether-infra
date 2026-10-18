# Gestion des clés — chaque clé, sa durée de vie, ce que coûte sa perte ou sa fuite, comment la remplacer

🇬🇧 [English version](key-management.md)

> Écrit pour répondre aux règles ANSSI sur l'impact, la durée de vie cryptographique, la fin d'utilisation, l'effacement et le
> recouvrement des clés (ids d'audit DP-06, DP-07, TLS-20, et les entrées de risque résiduel de TLS-12 et TLS-19). C'est un
> **document, pas un contrôle** : rien ici n'est imposé par du code sauf mention contraire, et **aucune procédure ci-dessous n'a
> été exécutée sur un cluster** sauf mention contraire. Il ne revendique aucune conformité à un document ANSSI. Les périodes
> marquées « proposé » sont à confirmer par le mainteneur : les règles demandent une période énoncée, pas celle-ci.

Cette page couvre les clés de la plateforme sous-jacente (Talos, l'état, les buckets, le bastion) et liste les clés de la couche
applicative en une ligne chacune. L'inventaire propre à la couche applicative, avec les mêmes colonnes et les commandes de
remplacement pour OpenBao, restic, Zitadel et Longhorn, est `OpenAether-apps/docs/key-inventory.md` (il livre avec la moitié
apps du même travail ANSSI ; apps 0.2.0 ne l'a pas ; apps 0.3.0 l'a).

## 1. Inventaire : ce qu'est chaque clé

« Où » désigne l'endroit à protéger. « Palier » dit comment l'affirmation a été établie : **lu** = dans le code de ce dépôt,
**amont** = d'après la valeur par défaut documentée de l'outil, non mesurée sur cette plateforme.

| # | Clé | Rôle | Générée par, et où elle vit | Algorithme | Période cryptographique |
|---|---|---|---|---|---|
| K1 | Secrets machine Talos (la PKI : CA de l'API Talos, CA Kubernetes, CA etcd, CA d'agrégation, clé de service-account, bootstrap token) | Racine de confiance des nœuds et de l'API Kubernetes | `talos_machine_secrets` (`modules/talos/main.tf`, `prevent_destroy`) : tfstate (chiffré côté client), la configuration machine de chaque nœud, le réplica de l'état et ses générations | choisi par la bibliothèque Talos (amont, non lu) | CA : 10 ans à la création (défaut amont, non mesuré) ; aucun renouvellement planifié |
| K2 | `talosconfig` et `kubeconfig` admin | Accès opérateur (`os:admin`, `system:masters`) | Émis depuis K1 par le provider Talos ; `./talosconfig`, `./kubeconfig`, et des copies chiffrées gpg dans les deux buckets d'artefacts | certificats clients X.509 | talosconfig : environ 1 an (en-tête de `talosconfig-new.sh` : « valid one year ») ; kubeconfig : la durée que `talosctl kubeconfig` donne à son certificat client (défaut amont, non mesuré ici) ; le fichier `os:reader` de `task talosconfig-new` vaut 8 h par défaut |
| K3 | Clé de chiffrement des Secrets etcd | Chiffre les Secrets Kubernetes au repos dans etcd | `random_bytes.etcd_encryption_secret`, 32 octets : tfstate, configurations machine des control planes | secretbox (XSalsa20-Poly1305) ; écart consigné dans `upgrade.md` | aucune ; **non rotatable en place** (section 3) |
| K4 | Passphrase de chiffrement des disques | LUKS2 sur STATE et EPHEMERAL (et volumes utilisateur) | `random_password.disk_encryption_secret`, 32 caractères alphanumériques : tfstate, configuration machine de chaque nœud | LUKS2 avec un slot passphrase statique (le nœud la détient pour déverrouiller au démarrage ; elle ne protège pas d'une compromission à l'exécution, comme le dit le commentaire du module) | aucune ; non rotatable en place (section 3) |
| K5 | Passphrase d'état `TF_VAR_encryption_passphrase` | Chiffrement côté client du tfstate et des plans (et des artefacts et snapshots si K6 n'est pas posée) | `scripts/ops/gen-passphrase.sh` (48 octets aléatoires, base64) ; le coffre de l'opérateur et `.env.sh` ; le secret CI `sandbox` a la sienne | PBKDF2-SHA512, 600000 itérations, puis AES-GCM (`encryption{}` d'OpenTofu, `cluster/backend.tf`) | aucune imposée ; proposé : annuelle et à toute exposition |
| K6 | Passphrase d'artefacts `TF_VAR_artifact_passphrase` (optionnelle) | Chiffrement gpg de talosconfig, kubeconfig et des snapshots etcd | même générateur ; environnement uniquement (le script de snapshot ne lit pas les tfvars) | gpg AES-256 (OpenPGP CFB avec MDC SHA-1 : détecte l'altération, pas un mode AEAD), S2K SHA-512 | comme K5 |
| K7 | Clés de stockage objet du cloud qui détient chaque bucket (`<PU>_AWS_*`, `<PU>_BACKUP_AWS_*`, `OA_LOKI_S3_*`, `OA_BACKUP_S3_*` et `OA_BACKUP_REPLICA_S3_*` optionnelles) | Écrire et lire les buckets d'état, d'artefacts, de snapshots et de journaux | La console du provider ; `.env.sh` sur la machine de l'opérateur ; par défaut valables pour tout le compte | clés d'API du provider | définie par le provider ; proposé : annuelle, et à chaque changement de personnel (celles de la CI : 90 jours au plus, `supply-chain.md`) |
| K8 | Identifiants d'API du provider (`SCW_*`, `OS_*`, `OSC_*`, jeton Proxmox) | Créer et détruire l'infrastructure | La console du provider ; `.env.sh` ; l'environnement CI `sandbox` | clés d'API du provider | comme K7 |
| K9 | Clés SSH du bastion : `bastion_ssh_keys` (compte partagé), `bastion_admins` (nominatifs), la CA SSH (`bastion_ssh_ca_public_key`) et ses certificats | Chemin d'administration vers chaque nœud (tunnels SSH vers 6443 et 50000) | Les machines ou jetons des opérateurs ; la clé privée de la CA **hors ligne ou dans OpenBao, hors de ce dépôt** ; la clé d'hôte du bastion naît sur la VM | ed25519 ou `sk-` recommandés ; RSA refusé sous 2048 bits (`bastion_ssh_rsa_min_bits`) | clés : aucune imposée, proposé annuelle ; certificats : 8 h dans la commande de signature documentée |
| K10 | Clés PGP des porteurs de parts de récupération (`openbao_recovery_pgp_keys`) | Chaque part de récupération OpenBao est chiffrée pour un opérateur | Les clés GnuPG des opérateurs ; moitiés publiques dans les tfvars | au choix des opérateurs ; `check-openbao-keys.sh` vérifie la présence d'une sous-clé de chiffrement utilisable | celle des opérateurs |
| K11 | Clé de scellement OpenBao | Enveloppe la clé de barrière d'OpenBao ; déchiffre chaque snapshot raft | apps : Secret `openbao-seal-key` dans le cluster, séquestre hors cluster avec deux dépositaires | enveloppe AES-256-GCM par le seal statique amont | aucune imposée ; proposé : annuelle |
| K12 | CA racine hors ligne, intermédiaire OpenBao, CA d'écoute `openbao-ca`, CA Istio | Chaîne de certificats de la passerelle et du maillage | apps : runbook `pki-root-offline-runbook.md` ; PKI OpenBao ; cert-manager ; istiod | ECDSA P-384 ou RSA 4096 pour la racine (apps), P-256 pour la CA d'écoute | racine 10 ans, intermédiaire 730 jours, CA d'écoute 10 ans, certificat de passerelle 90 jours (apps) |
| K13 | Mot de passe restic, clés S3 backup/Loki/CNPG, masterkey Zitadel, mots de passe de bases, passphrase LUKS Longhorn, mots de passe admin Grafana/MinIO | Sauvegardes et données applicatives | apps : générés dans OpenBao par le Job configure (ou posés par `seed-openbao.sh` pour les paires S3) | voir l'inventaire apps | aucune imposée ; voir l'inventaire apps |

## 2. Inventaire : impact, remplacement, révocation, effacement

« Perdue » : la clé disparaît sans copie ; « fuitée » : un attaquant la détient. **L'impact est énoncé pour le système, pas pour la clé** :
chaque règle demande ce qui cesse de fonctionner, ou ce qui est exposé, et pour combien de temps.

| # | Si perdue | Si fuitée | Remplacement | Révocation | Effacement et archive |
|---|---|---|---|---|---|
| K1 | Le cluster reste debout (les nœuds gardent leurs copies) mais plus rien de nouveau ne peut s'authentifier : les générations du réplica sont le chemin de retour (`cluster/README.md`, « Lost the Talos secrets ») ; sans copie nulle part, la décision est de reconstruire | Contrôle total de l'API Talos et de l'API Kubernetes, tant que la CA est de confiance (10 ans par défaut) | section 3, « PKI Talos » ; le chemin testé est un **nouveau cluster** ; `talosctl rotate-ca` est la voie amont en place, non exécutée ici | Seulement en remplaçant la CA : il n'y a pas de liste de révocation pour ces certificats | Les anciennes générations d'état contiennent la PKI : les supprimer après une rotation (section 4) |
| K2 | Les retrouver : `task kubeconfig`, `task restore-artifacts` | `system:masters` jusqu'à l'expiration du certificat : Kubernetes ne sait pas révoquer un certificat client (`admin-access.md`) | En émettre un nouveau ; l'ancien reste valable jusqu'à expiration | Rotation de la CA seulement (K1) | Les copies chiffrées des deux buckets vieillissent avec leurs objets ; une ancienne s'ouvre avec l'ancienne passphrase |
| K3 | Les Secrets d'un snapshot etcd deviennent illisibles ; le cluster vivant n'est pas touché (l'apiserver tient la clé) | Avec un snapshot ou un disque etcd : chaque Secret en clair. La surface de fuite côté cluster est l'état, les configurations machine et les snapshots | Reconstruire (section 3) | Non révocable | Supprimer les anciens snapshots et générations d'état |
| K4 | Un nœud qui redémarre ne peut plus déverrouiller ses disques ; reconstruire le nœud (`rolling-replace`) | Avec un disque volé : son contenu. Sans le disque : rien | Reconstruire les nœuds sous une nouvelle valeur (section 3) | Non révocable | Comme K3 |
| K5 | L'état et tout ce qui est sous K5 est perdu : « no second key and no reset » (`first-cluster.md`). Le réplica porte le même chiffré | Qui lit aussi un objet de bucket ouvre l'état, donc K1, K3, K4 et chaque sortie | Section 3, « Passphrase d'état » | Changer la passphrase n'efface pas ce que l'ancienne ouvre : supprimer les anciens objets et générations (section 4) | Archive : l'ancienne passphrase ne se détruit qu'une fois le dernier objet sous elle supprimé |
| K6 | Les snapshots et artefacts écrits sous elle sont illisibles (l'état n'est pas touché) | Ouvre les artefacts et snapshots, pas l'état | En poser une nouvelle ; l'apply suivant réimporte les artefacts ; prendre un nouveau snapshot | Comme K5 | Comme K5 |
| K7 | Les sauvegardes et l'état ne sont plus inscriptibles ; les données sont intactes | Lire, écraser ou supprimer l'état, les artefacts et les snapshots (tous chiffrés côté client, donc pas de lecture du contenu, mais la suppression est réelle : **aucun verrou d'objet n'est configuré**) | Créer une nouvelle clé chez le provider, mettre à jour `.env.sh`, lancer une commande qui touche le bucket, puis révoquer l'ancienne | Chez le provider | n/a |
| K8 | Plus de changement d'infrastructure possible | Détruire ou créer des ressources sur le compte | Nouvelle clé, puis révoquer | Chez le provider | n/a |
| K9 | L'accès SSH de secours est perdu ; la console du provider et un bastion de remplacement sont le chemin de retour | Accès au chemin d'administration (la liste `admin_ip` et le mTLS des nœuds restent devant les nœuds) | Ajouter la nouvelle clé, remplacer le bastion (`admin-access.md`, départ d'un opérateur) | `revoked_keys` (avec la baseline) ou une CA qui cesse de signer | Retirer la clé des tfvars ET remplacer le bastion : `user_data` n'est lu qu'au premier démarrage |
| K10 | Une part de récupération ne peut plus être déchiffrée par son porteur : sous le quorum, plus de break-glass | Une part seule est inutile (chiffrée PGP) ; le quorum de clés privées des porteurs ensemble vaut root | `bao operator rekey` des clés de récupération (inventaire apps) | Une part ne se révoque pas, elle se remplace | n/a |
| K11 à K13 | Voir `OpenAether-apps/docs/key-inventory.md` (colonnes « If lost », « If leaked », « Archive / erasure ») | idem | idem | idem | idem |

Deux faits sur lesquels le tableau repose, parce qu'ils décident de la gravité de K5 : le tfstate contient K1, K3 et K4 (chiffré côté
client, et répliqué dans le bucket d'un second provider avec jusqu'à cinq générations datées), donc **K5 est la clé des clés**. Séparer K6 de K5 ne
sépare les artefacts et snapshots que si les deux sont gardées à des endroits différents.

## 3. Procédures de remplacement

Toutes sont **écrites, non exécutées**. Quand une commande vient d'un document amont, c'est dit, et la version du client que vous
tenez (`talosctl` est installé à la `talos_version` du cluster, `scripts/internal/install-talosctl.sh`) décide des options : lire d'abord `--help`.

**Ordre d'une rotation après un incident** : contenir (`incident-response.fr.md`, sections 3 à 6), puis remplacer dans l'ordre du tableau
de cette page (section 7), puis effacer (section 4 ci-dessous). L'objectif après une compromission est d'environ une journée de travail
(ANSSI PG-078 R26) ; aucune partie n'a été chronométrée.

### PKI Talos (K1) et identifiants admin (K2)

- **Le chemin testé est un nouveau cluster.** `cluster/README.md` consigne la décision : une nouvelle PKI est un nouveau cluster. Construire
  le remplaçant à côté ou après l'ancien, y restaurer OpenBao (`disaster-recovery.fr.md`), re-poser ce qui est hors OpenBao
  (`seed-openbao.sh`), basculer, puis détruire l'ancien et effacer ses générations d'état.
- **En place, la voie amont** : `talosctl rotate-ca` fait tourner la CA de l'API Talos et la CA Kubernetes d'un cluster en marche
  (l'amont documente un mode à blanc : lire `--help` pour la valeur par défaut de la version que vous tenez). Non exécuté sur cette plateforme.
  Deux choses que ce dépôt sait et que la page amont ne dit pas : (1) la nouvelle PKI n'existe que sur les nœuds et dans le nouveau
  `talosconfig`, **pas dans le tfstate**, dont `talos_machine_secrets` porte encore l'ancienne, si bien que le prochain `tofu apply` pousserait
  des configurations machine avec l'ancienne CA ; il n'y a pas ici de procédure pour porter la nouvelle PKI dans l'état, donc ne lancer aucun
  apply sur ce cluster ensuite tant que cela n'est pas résolu (la première rotation est une tâche de labo : `LAB-CHECKLIST.md`, B13) ; (2) chaque kubeconfig,
  talosconfig et artefact gpg doit être réémis ensuite (`task kubeconfig`).
- **Un kubeconfig ou un talosconfig fuité** est le problème de K1 : le fichier reste valable jusqu'à expiration. Un accès en lecture de courte
  durée existe (`task talosconfig-new`, `os:reader`, 8 h par défaut) pour porter moins souvent le fichier de longue durée.

### Clé des Secrets etcd (K3) et passphrase des disques (K4)

La configuration machine ne prend qu'une valeur pour chacune (`cluster.secretboxEncryptionSecret`, le slot de clé `luks2`). Remplacer la valeur
en place laisse les données existantes sous une clé que le nœud ne détient plus : Secrets illisibles par l'apiserver (K3), disques qui ne
se déverrouillent plus au prochain démarrage (K4). `upgrade.fr.md` (« La clé de chiffrement des Secrets (etcd) — non rotatable sur place ») dit la
même chose pour K3 ; savoir si Talos accepte une seconde clé n'a **pas été vérifié**. Donc, pour une fuite suspectée de l'une ou l'autre :

1. Considérer chaque Secret présent dans etcd comme fuité si la clé fuitée était K3 et que l'attaquant avait aussi un snapshot, un disque ou l'état ; K4
   et une image de disque exposent le contenu des disques. Faire tourner ce que les Secrets contiennent, pas seulement la clé (`incident-response.fr.md`, tableau de rotation).
2. Construire un nouveau cluster (nouveaux `random_bytes` et `random_password`, nouvelle PKI Talos), y restaurer OpenBao, basculer, détruire l'ancien.
3. Effacer les anciennes générations d'état, snapshots et artefacts (section 4).

### Passphrase d'état (K5) et passphrase d'artefacts (K6)

Le bloc `encryption{}` d'OpenTofu permet un changement de clé avec une méthode `fallback` : la nouvelle clé devient la méthode d'écriture, l'ancienne
reste en repli pour lire, un apply réécrit l'état chiffré, puis le repli est retiré. **Le bloc de `backend.tf` a une méthode et pas de repli aujourd'hui ; le
changement est une édition de ce fichier sur la machine de l'opérateur, et n'a pas été exécuté.** Ordre :

1. `gen-passphrase.sh` pour la nouvelle valeur ; garder l'ancienne jusqu'à l'étape 6.
2. Ajouter le nouveau key provider et la nouvelle méthode, en faire la méthode de `state` et de `plan`, mettre l'ancienne en `fallback`.
3. `tofu apply` (un plan lit l'ancien état via le repli, l'apply l'écrit sous la nouvelle clé).
4. `task backup-state PROVIDER=<p>` : le réplica porte alors le nouveau chiffré comme objet courant. Les générations datées
   (les cinq dernières, et toute copie `STATE_LABEL` comme `pre-upgrade`) **restent sous l'ancienne passphrase**.
5. Si K6 n'est pas posée, les artefacts et snapshots étaient sous K5. Le déclencheur d'envoi de `backup.tf` n'inclut **pas** K5 (seulement une K6
   distincte), donc une K5 changée ne réimporte rien d'elle-même : relancer l'envoi avec `-replace=terraform_data.backup[0]` dans le même apply, prendre
   un nouveau snapshot etcd (`task etcd-snapshot`), puis confirmer avec `task restore-artifacts`. Si K6 est posée, la faire tourner de la même façon : poser une nouvelle K6 réimporte bien les artefacts.
6. Supprimer les anciennes générations, anciens snapshots et anciennes versions d'artefacts (section 4), retirer le repli, mettre à jour le secret CI.
   Détruire l'ancienne passphrase seulement alors : tant que le dernier objet sous elle existe, elle l'ouvre encore.

### Clés du bastion (K9)

Départ d'un opérateur, certificats, `revoked_keys` et épinglage de la clé d'hôte sont dans `admin-access.fr.md` (« Identité, clé d'hôte et sortie Internet du bastion »). Le séquestre de la clé privée de la CA SSH est celui de l'opérateur : support hors ligne ou moteur SSH d'OpenBao avec la même durée
maximale de 8 h ; ce dépôt n'exploite ni l'un ni l'autre.

### Séquestre : combien de dépositaires

Aujourd'hui `docs/admin-access.fr.md` indique qu'OpenAether a **un opérateur**. Un seul dépositaire est un point unique de perte, et de fuite. Pour tout ce
qui compte : le séquestre de la clé de scellement a deux dépositaires au minimum et est prouvé par un hachage et attesté dans le cluster (`task escrow`, `admin-access.fr.md` section 1 ; apps `vault/README.md`, Day 0, étapes
1 et 5) ; les parts de récupération sont une par opérateur ; K5 et K6 vont dans deux coffres différents, chacun avec une seconde personne capable de l'ouvrir. Là où il
n'y a qu'une personne, l'écrire dans le registre d'incidents plutôt que de le laisser implicite.

## 4. Fin d'utilisation, effacement et archive

- **Rien n'est effacé selon un calendrier.** Aucun bucket de ce dépôt n'a de versionnement, de règle de cycle de vie ni de verrou d'objet, et la page
  supply-chain dit que les politiques de bucket pour l'état et les artefacts « are not handled here ». Un ancien chiffré d'état reste donc dans son bucket jusqu'à ce que quelqu'un le supprime.
- **Pour effacer une ancienne génération de clé** : lister (`task backup-state PROVIDER=<p> -- --list`, et `aws s3 ls` sur les deux stores avec
  l'endpoint), supprimer chaque génération datée et copie `STATE_LABEL`, chaque ancien `etcd-*.snap.gpg` et artefact, **chaque version d'objet et marqueur
  de suppression si le bucket est versionné** (une suppression simple les laisse), sur les DEUX stores. Puis relister.
- **`shred` n'est pas un effacement sur SSD** ni sur un système de fichiers journalisé ou copy-on-write : le contrôleur remappe les blocs. Garder le matériel de clé
  sur un volume chiffré ou en RAM (`mount -t tmpfs`), et considérer la destruction du support, ou de la clé de chiffrement du volume, comme l'effacement.
- **Archive** : une clé n'est archivée que tant qu'un objet sous elle existe et peut devoir être lu (un snapshot conservé, une génération d'état). L'archive de K5
  dure donc autant que la plus longue rétention d'une génération ou d'un snapshot (`backup-policy.fr.md`).
- **Mise hors service d'un cluster** : `cluster-down` laisse les buckets exprès (supprimer le bucket d'état supprime toute possibilité de restaurer).
  Quand le cluster est fini pour de bon, vider les buckets (versions comprises) après la dernière restauration dont vous pourriez avoir besoin, les supprimer, révoquer K7 et K8,
  et détruire K5 et K6. `backup-policy.fr.md`, « Destruction, expiration et mise hors service ».

## 5. Écarts consignés et risques résiduels

| Point | Ce que la règle demande | Ce qui est là | Pourquoi, et ce qui le fermerait |
|---|---|---|---|
| TLS-12 : garde de la CA | Clé racine hors ligne, idéalement en HSM ; intermédiaire en dispositif de classe HSM | La clé de la racine hors ligne est gardée par l'opérateur (le runbook apps propose un jeton matériel ou un support hors ligne ; un gestionnaire de mots de passe est l'écart consigné) ; la clé de l'intermédiaire vit dans les données raft d'OpenBao, enveloppée par la clé de scellement, une clé logicielle dans un Secret sur les mêmes nœuds (K11) | Autonome, redémarrage sans main. Pour fermer : un seal transit ou PKCS#11 vers un OpenBao séparé ou un HSM hors du cluster. La migration est **non testée** et circulaire si le seal externe est dans le cluster qu'il descelle |
| TLS-12 : enveloppe AES-GCM (PA-079 R13 demande un mode d'enveloppe de clé) | AES-KW ou SIV | Le seal statique amont enveloppe en AES-256-GCM | Propriété de l'amont ; à revoir si OpenBao offre un mode d'enveloppe de clé |
| TLS-12 : trois CA | Une seule hiérarchie | La PKI OpenBao (racine hors ligne), la CA d'écoute `openbao-ca` (auto-signée, cert-manager) et la CA Istio (istiod) | La CA d'écoute doit exister avant le démarrage d'OpenBao (elle signe son propre certificat), donc elle ne peut pas vivre dans sa PKI ; la CA Istio est le défaut amont. Voir l'inventaire apps |
| TLS-19 : pas d'hybride post-quantique | Établissement de clé hybride là où le trafic enregistré garde de la valeur des années | `KexAlgorithms` SSH du bastion est classique (curve25519, DH groupe 16/18) sur Ubuntu 22.04, dont OpenSSH 8.9 ne connaît pas `sntrup761x25519` ; WireGuard de Cilium est classique et ne peut pas être changé ; le TLS de la passerelle et du maillage suit les défauts amont | Le trafic d'administration qui compte voyage dans du TLS et du mTLS (API Talos, kube-apiserver, OpenBao) à travers le tunnel SSH, dont la poignée de main est aussi une couche interne : le double enrobage réduit l'exposition, ne la supprime pas. Pour fermer : l'image du bastion sous Ubuntu 24.04 avec le KEX hybride en premier (`bastion_image_id`, remplace le bastion), et les builds Envoy, ztunnel et Go qui livrent des groupes hybrides. Savoir si le build Go d'OpenBao en négocie déjà un est **non vérifié** ici. Signatures de certificats : SHA-384 pour la racine et l'intermédiaire hors ligne sont dans le runbook apps ; les certificats existants restent tels que signés |
| DP-17 : les secrets machine atteignent les nouveaux nœuds par l'API de maintenance non authentifiée | Livraison authentifiée des clés à l'équipement | `first-cluster.fr.md`, « Risque résiduel : l'application en mode maintenance » | Conception amont ; compensé par le réseau privé, le tunnel SSH, la liste d'autorisation du bastion et (OVH, Outscale) le groupe de sécurité qui n'admet 50000 que depuis le bastion |
| Compte SSH partagé de secours | Imputabilité individuelle | `bastion_ssh_keys` reste à côté de `bastion_admins` | Automatisation et accès de secours ; `bastion_require_hardware_key` ne le couvre pas |
| Un seul opérateur | Deux dépositaires par séquestre | Une personne | Dit dans `admin-access.fr.md` ; l'attestation du séquestre de la clé de scellement exige deux porteurs et le dit quand ce n'est pas le cas |

## 6. Revue

Relire cette page à chaque changement qui ajoute une clé générée, une variable secrète, un bucket ou un identifiant de bastion ; à chaque
rotation ; après chaque incident ; et au moins une fois par an (`release-checklist.md`, « Quarterly security review », fait la passe trimestrielle et
l'annuelle). Une ligne sans période, sans impact ou sans remplacement est un défaut.
