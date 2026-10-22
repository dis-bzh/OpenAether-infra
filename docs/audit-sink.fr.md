# Puits d'audit — une seconde copie des journaux d'audit et de sécurité, hors du cluster

🇬🇧 [English version](audit-sink.md)

> Conception pour infra #318. **Statut : conçu et testé hors ligne (mocked/static). Aucun cloud, aucun cluster, aucun fournisseur ne l'a exécuté.**
> Les critères de réussite du laboratoire sont à la section 9. Aucune conformité à un document de l'ANSSI n'est revendiquée.

## 1. Pourquoi, et la classe des données

Le journal d'audit Kubernetes, les journaux des nœuds et les journaux de flux réseau vivent dans le cluster qu'ils décrivent : un
attaquant cluster-admin (ou un cluster perdu) les emporte avec lui. La décision du mainteneur du 2026-10-22 place les **journaux
d'audit et de sécurité en classe A : zéro perte**. Les métriques et journaux ordinaires restent en **classe B** (perte bornée,
inchangée : Loki et VictoriaMetrics comme avant).

Classe A signifie ici : le flux est copié, **avant que quoi que ce soit soit supprimé à la source**, vers du stockage objet **hors du
cluster**, avec un verrou d'objet et un chiffrement côté client, et une vérification dit quand la copie cesse d'arriver. C'est
optionnel : avec `audit_sink_placement = "off"` (le défaut), rien ne change dans ce dépôt ni dans les apps.

Périmètre aujourd'hui : le **journal d'audit de l'API Kubernetes** des control planes (le composant optionnel `audit-log-sink` des
apps, à côté de `audit-log-collector`). Les journaux des nœuds (services Talos et noyau) et les journaux de flux Cilium **ne sont pas
encore expédiés par ce composant** ; la section 8 dit pourquoi et ce qui manque. Les journaux du bastion vont déjà vers les deux
magasins de sauvegarde (`bastion-logs-pull.sh`).

## 2. Où vit le puits : un choix, avec ses garanties

`audit_sink_placement` dans le tfvars. La **proposition** par défaut quand on active le puits est `other_provider`.

| Choix | Le puits est | Survit à | Ne survit pas à | Coût et effort |
|---|---|---|---|---|
| `other_provider` (proposé) | chez un autre cloud que le cluster (cluster Scaleway : OVH ; même appariement que le magasin réplique des sauvegardes) | perte d'un site ou d'une région, panne d'un fournisseur, **un événement sur le compte du cloud du cluster** (suspension, identifiants volés, incident du plan de contrôle) | un événement sur le compte du puits lui-même ; une paire de clés du puits volée peut ajouter des objets (pas retirer les verrouillés) | un second compte cloud et ses clés ; sortie vers un autre fournisseur |
| `same_provider_other_region` | chez le même fournisseur, dans une autre région | perte d'un site ou d'une région | **un événement au niveau du compte atteint les deux copies**, sauf si le verrou est `COMPLIANCE`, que même le propriétaire du compte ne peut pas lever avant son terme | moins cher, un seul compte à protéger, rien de nouveau à apprendre |
| `both` | sur les deux ci-dessus, deux copies indépendantes | l'union | la perte simultanée des deux comptes | deux expéditeurs, stockage doublé |

Règles appliquées par l'outillage (`scripts/lib/audit-sink.sh`, lu par `ensure-buckets.sh`, `seed-openbao.sh` et
`backup-key-recipe.sh`, et par un bloc `check` de la racine du cluster) :

- `other_provider` : le point d'accès du puits ne doit pas être chez le fournisseur du cluster ; refusé avant toute création de bucket.
- `same_provider_other_region` : le point d'accès doit être chez le fournisseur du cluster et la région doit différer de `s3_primary_region`.
- `both` : `audit_sink_endpoint` est l'autre fournisseur, `audit_sink_secondary_endpoint` le même fournisseur dans une autre région.
- `COMPLIANCE` est refusé sans `audit_sink_compliance_ack = true` : un verrou compliance ne peut être défait par personne avant la fin de
  la rétention, et le bucket ne peut être vidé ni supprimé jusque-là.
- `GOVERNANCE` est le défaut. Une clé qui détient le droit de contournement peut encore retirer une version ; la paire du puits ne l'a jamais.
- Outscale n'est accepté comme puits **qu'après infra #377** (les paires dédiées ont été refusées par le magasin au lab 15B) ; d'ici là
  seules les clés de l'opérateur y fonctionneraient, ce qui annule la paire dédiée.
- COMPLIANCE a été prouvé appliqué chez Scaleway, OVH et Outscale (lab 22, partie B : suppression d'une version et deux changements de
  rétention refusés). Qu'un bucket verrouillé puisse être vidé une fois la rétention écoulée n'a pas été prouvé.

## 3. Le chemin des données

```
kube-apiserver --écrit--> /var/log/audit/kube/kube-apiserver.log (+ fichiers tournés)   (politique Talos par défaut, niveau Metadata)
        |  hostPath en lecture seule, décalages en octets, jamais dans le chemin d'écriture de l'apiserver
        v
audit-sink-shipper (DaemonSet, control planes seulement)  --restic backup --stdin-->  s3:<endpoint>/<bucket>/<prefix>/<node>/<AAAA-MM-JJ>
        |                                                                               (un dépôt restic par nœud et par jour)
        v
audit-sink-check (Deployment) liste le préfixe toutes les 5 minutes --> oa_audit_sink_ok, oa_audit_sink_last_object_age_seconds
```

- **Quels journaux, quel format.** Le fichier d'audit tel que l'apiserver l'a écrit (lignes JSON, lignes entières seulement). Aucune
  analyse, aucun filtrage, aucune réécriture : ce que contient le puits est ce que l'apiserver a dit.
- **Regroupement.** Toutes les `SHIP_INTERVAL` secondes (300 par défaut) l'expéditeur lit ce qui a été ajouté depuis son dernier décalage
  acquitté, coupé au dernier saut de ligne, au plus `SHIP_MAX_BYTES` (16 MiB par défaut) par morceau. Un morceau est un snapshot restic,
  marqué `oa-pos=<inode>:<début>:<fin>[:eof]` et du nom du nœud. `eof` marque le dernier morceau d'un fichier que l'apiserver a tourné.
- **Compression et chiffrement.** restic : compression (format de dépôt 2) et chiffrement côté client (AES-256 avec Poly1305-AES, clé
  dérivée par scrypt). Le chiffrement côté serveur du fournisseur s'y ajoute et n'est pas un contrôle que nous évaluons.
- **Clés d'objets.** Un dépôt par nœud et par jour UTC, `<prefix>/<node>/<AAAA-MM-JJ>/`. restic nomme ses objets par leur contenu
  (`data/`, `index/`, `snapshots/`, `keys/`, `config`) : la *date* est dans le préfixe, la *séquence* dans les étiquettes de snapshot
  (chiffrées mais listables par restic), pas dans les noms d'objets. Un lecteur trouve un jour par un listage de préfixe.
- **Acquittement avant d'avancer la position.** `restic backup` ne rend 0 qu'une fois l'objet snapshot stocké. L'expéditeur ne garde ni
  copie locale ni curseur local qui survive au pod : au démarrage il relit le dernier `oa-pos` depuis le puits (jusqu'à 8 jours de
  dépôts), donc **le puits est le curseur**. Un morceau n'est jamais sauté parce qu'un pod a redémarré, et renvoyé au plus une fois (un
  snapshot écrit dont l'acquittement s'est perdu est une plage en double, que le vérificateur accepte et compte).
- **Pas de fichier de verrou.** `--no-lock` à chaque écriture : sinon restic écrit puis supprime des objets de verrou et la paire aurait
  besoin de `DeleteObject`. Avec lui, la paire n'a aucun droit de suppression.
- **Verrou d'objet et rétention.** Le bucket est créé avec le verrou d'objet et une rétention par défaut (`audit_sink_lock_mode`,
  `audit_sink_retention_days`, 365 jours par défaut), versionnement actif, relu depuis le magasin par `oa_protect_bucket`. Un refus du
  fournisseur est une erreur dure pour ce bucket, pas un avertissement : classe A.

## 4. Clés et dépôt de garde

- **Mot de passe du dépôt.** Un mot de passe dédié de 48 caractères, généré par `seed-openbao.sh` la première fois (création seule,
  jamais renouvelé par une relance), écrit en `secret/audit/sink` avec le point d'accès, le bucket, la région et la paire S3. Ce **n'est pas**
  le mot de passe des dépôts de sauvegarde (`secret/backup/restic`) : un expéditeur compromis ne doit pas ouvrir les sauvegardes.
- **Séquestre.** `escrow-openbao.sh export` le chiffre aussi vers les clés OpenPGP des dépositaires (`audit-sink-password.gpg`, empreinte
  dans le reçu) quand `secret/audit/sink` existe, et `verify` le compare au mot de passe en service. Même garde que le mot de passe restic
  et mêmes détenteurs hors ligne. Sans le séquestre, un OpenBao perdu rend le puits illisible : le puits n'est lisible que comme cette copie.
- **Paire de clés S3.** Une paire distincte pour le puits (`OA_AUDIT_SINK_S3_ACCESS_KEY_ID` / `..._SECRET_ACCESS_KEY` ; pour le second
  puits `OA_AUDIT_SINK_SECONDARY_S3_*`), créée par l'opérateur d'après la recette (`scripts/ops/backup-key-recipe.sh <tfvars> audit-sink`).
  Droits : lister, lire, écrire, envoi multipart seulement. **Retirés :** toute suppression, `DeleteObjectVersion`, versionnement, cycle de
  vie, changements de verrou et de rétention, suppression du bucket, tout autre bucket. Sans paire dédiée, le seed retombe sur les clés de
  l'opérateur et le dit clairement.
- **OVH n'a pas de politique de bucket par son API S3** : la paire d'un utilisateur OVH ne peut pas être limitée à un bucket, donc chez OVH
  la paire « dédiée » atteint encore les autres buckets de ce projet OVH. Isolez-la en donnant au puits son propre projet/utilisateur OVH,
  et lisez les droits dans l'API OVH (non vérifié). La recette l'imprime.

## 5. Comportement en panne

- **Le chemin d'audit n'est jamais bloqué.** L'expéditeur ne fait que lire des fichiers. L'apiserver continue d'écrire dans son fichier
  local quoi que fasse le puits : aucun backend d'audit webhook n'est configuré, et il ne doit pas l'être (un webhook bloquant peut
  ralentir l'apiserver).
- **Puits injoignable.** L'expéditeur réessaie à chaque intervalle, ne garde rien de plus sur disque (son cache restic est un `emptyDir`
  plafonné à 256 MiB) et continue de lire depuis le décalage acquitté. **Le tampon, ce sont les fichiers tournés de l'apiserver sur le
  nœud**, bornés par sa rotation, pas par nous. Tant que le puits est en panne, le retard croît.
- **Alertes** (apps `vmrule-audit-sink.yaml`) : `AuditSinkDown` (la vérification ne peut pas lister le puits pendant 10 minutes),
  `AuditSinkStale` (l'objet le plus récent d'un nœud a plus de 20 minutes), `AuditSinkShipperUnavailable` (un control plane n'a pas
  d'expéditeur actif), `AuditSinkCheckAbsent`. Un cluster dont tous les control planes sont à l'arrêt ne peut pas alerter : seul le
  heartbeat le couvre.
- **Rien de perdu après reprise** tient tant que la panne est plus courte que la fenêtre de rotation du fichier de l'apiserver. Après une
  panne plus longue, le plus ancien fichier tourné a disparu : l'expéditeur écrit un snapshot de trou explicite (`oa-gap=<inode>`), le
  vérificateur le signale, et l'alerte a sonné depuis longtemps.
- **Premier démarrage.** L'expéditeur envoie ce qu'il trouve (fichiers tournés d'abord, du plus ancien au plus récent), pas seulement les
  nouvelles lignes : un puits mis en service commence avec l'historique encore présent sur le nœud.

## 6. Vérification de la livraison

Deux niveaux. Dans le cluster, `audit-sink-check` liste le préfixe du puits avec la paire du puits et exporte `oa_audit_sink_ok` et, par
nœud, `oa_audit_sink_last_object_age_seconds` (d'après le `LastModified` du plus récent objet snapshot, sans déchiffrer). Cela prouve la
livraison, pas l'intégrité. Hors du cluster, `scripts/ops/audit-sink-check.sh` (opérateur, avec le mot de passe séquestré) liste une fenêtre
de temps, lit les étiquettes de snapshot, vérifie **l'absence de trou dans la suite des plages par nœud et par inode**, déchiffre et
analyse un échantillon, et relit le mode de verrou et la rétention. À lancer au moins chaque semaine, et après toute panne.

## 7. Limites assumées

- Le mot de passe et la paire S3 sont **dans le cluster** (l'expéditeur en a besoin pour écrire). Un cluster-admin qui les atteint peut
  **lire** le puits et **ajouter** des objets, y compris de faux snapshots. Il ne peut ni supprimer ni raccourcir une version verrouillée.
  Une conception à clé publique (cryptographie en écriture seule, par ex. age) fermerait le côté lecture ; elle demande une image avec cet
  outil et le client S3, ce que les images épinglées n'ont pas. Non fait.
- Le puits est une copie de ce que l'apiserver a écrit. Si les control planes sont compromis **avant** l'expédition de la ligne, elle peut
  être modifiée d'abord. La fenêtre est l'intervalle d'expédition (300 s par défaut).
- Un fichier tourné compressé (`.gz`) n'est pas expédié ; Talos ne compresse pas la rotation de l'audit par défaut. Le lab lit les options.
- Coût : stockage = rétention × volume (le journal d'audit d'un petit cluster est de l'ordre de quelques dizaines de MiB par nœud et par jour :
  NON VÉRIFIÉ, à mesurer au lab) plus le prix des requêtes, environ 3 snapshots × 288 intervalles × nœuds par jour.
- Temps : le `LastModified` d'un objet est l'horloge du fournisseur ; la métrique d'âge se fie à elle et à l'horloge du cluster pour `time()`.
- Pas une revendication de conformité ANSSI. Le verrou prouve la rétention côté stockage, pas l'intégrité de ce qui a été écrit.

## 8. Pas encore couvert

- **Journaux des nœuds.** `node_log_forwarding` envoie les journaux des services Talos et du noyau en TCP clair vers un récepteur : il n'y a pas
  de fichier à décalage stable à acquitter, donc la même garantie d'acquittement avant suppression demande un récepteur qui écrit des fichiers,
  exploité par l'opérateur. Non construit.
- **Journaux de flux.** L'export Hubble de Cilium est un fichier tournant par nœud ; l'expéditeur pourrait le lire avec un autre
  `SOURCE_GLOB`, mais sa rotation et son volume ne sont pas mesurés. Non construit.
- **Un second expéditeur pour le puits secondaire** est le composant `audit-log-sink-secondary` (apps), identique et indépendant.

## 9. Critères de réussite du laboratoire

1. **Livraison en moins de 10 minutes** après activation : chaque nœud control plane a un dépôt du jour et un snapshot de moins de
   `SHIP_INTERVAL` + 2 minutes ; `oa_audit_sink_ok` vaut 1 et l'âge est sous 600 s pour chaque nœud.
2. **Aucun trou sur une fenêtre** : `audit-sink-check.sh` sur 24 heures rapporte 0 trou et 0 plage manquante par nœud et par inode, y compris
   à travers au moins une rotation du fichier de l'apiserver (en forcer une sur un cluster jetable en baissant la taille de rotation) et un
   redémarrage du pod expéditeur.
3. **Verrou relu** : le mode et les jours lus depuis le magasin égalent le tfvars, sur chaque puits ; la suppression d'une version et le
   raccourcissement de la rétention avec la paire du puits sont refusés.
4. **Droits** : avec la paire du puits, une suppression, `put-bucket-versioning` et `put-object-lock-configuration` sont refusés ; un envoi fonctionne.
5. **Déchiffrement** : avec le seul mot de passe séquestré (pas la copie d'OpenBao), le script restaure un snapshot et les lignes s'analysent
   comme des événements d'audit.
6. **Exercice de panne du puits** (bloquer le FQDN du puits par une politique jetable pendant 40 minutes) : `AuditSinkDown` sonne en moins de
   15 minutes et `AuditSinkStale` en moins de 25 ; `kubectl` continue de fonctionner (le chemin de l'apiserver n'est pas bloqué ; son fichier
   d'audit continue de grossir) ; l'usage disque de l'expéditeur reste sous son plafond ; après déblocage, le retard est expédié et le script
   ne rapporte aucun trou sur la fenêtre de la panne.
7. **Fenêtre de rotation** : lire les options d'audit de l'apiserver sur un control plane Talos et noter la panne maximale que le nœud absorbe.
8. **Réseau** : une connexion de l'expéditeur vers tout autre hôte que le puits est refusée ; la politique refuse un autre hôte de bucket.
9. **Both** : avec `both`, arrêter un seul puits : son alerte sonne, l'autre continue de recevoir.
