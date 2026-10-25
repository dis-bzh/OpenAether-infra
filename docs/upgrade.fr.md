# Mettre à niveau un cluster vivant — Kubernetes et Talos

🇬🇧 [English version](upgrade.md)

> Construire un cluster et en garder un sont deux affirmations différentes. Voici
> la seconde. Mesurée à la main sur **Scaleway, OVH et Outscale** — les deux
> premiers le 2026-08-19, Outscale le 2026-08-20 — en topologie HA, chaque nœud
> mis à niveau **sur place** plutôt que remplacé et l'API Talos de chaque nœud
> interrogée sur ce qu'il exécute. Le 2026-10-03, les trois sont montés à Talos 1.14.2
> et Kubernetes 1.37.1 par `task cluster-upgrade` (`docs/status.md` a les chiffres).
> Les runs antérieurs sur Outscale et sur OVH revenaient en arrière au redémarrage
> suivant, et les issues ouvertes disent pourquoi.
>
> La version scriptée de cette même procédure est `task cluster-upgrade`
> ([`scripts/dev/cluster-upgrade.sh`](../scripts/dev/cluster-upgrade.sh)). Elle
> se lance à la main, sous surveillance : aucune voie de CI ne déploie quoi que
> ce soit toute seule. Cette page est ce qui a réellement tourné.

## Les deux faits dont découle tout le reste

**L'image de boot d'un nœud n'est que le médium depuis lequel il a été installé.**
Après un `talosctl upgrade`, l'instance rapporte toujours l'ancien id d'image,
par construction. Les ressources de nœud portent donc `ignore_changes` dessus —
voir
[`provider-contract.md` § Node image drift](../infrastructure/opentofu/modules/providers/provider-contract.md).
Sans cela, bumper `talos_version` ferait remplacer les trois control planes en
même temps par un apply de routine, et etcd perdrait son quorum.

**Talos ne supporte qu'une fenêtre de versions Kubernetes.**
`cluster/versions-guard.tf` refuse une paire non supportée dès le plan, et refuse
aussi une mineure Talos que personne n'a saisie dans sa table plutôt que de la
laisser passer en silence. La paire de départ, celle d'arrivée **et** l'état
intermédiaire doivent tenir dans la fenêtre, puisque les deux bougent l'une après
l'autre.

## Mesurer l'interruption

À lancer avant tout le reste, contre l'endpoint du kubeconfig — jamais contre un
tunnel vers un nœud, puisque c'est ce nœud-là qu'on s'apprête à retirer.

```bash
while :; do kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 \
  && echo ok || echo FAIL; sleep 1; done | tee probe.log
```

Une exécution propre perd quelques secondes le temps qu'un apiserver redémarre.
Les deux upgrades de bout en bout : **5 s** sur Scaleway (16 échantillons en
échec sur 575) et **7 s** sur OVH (9-10 sur ~540) le 2026-08-19, puis **8 s** sur
Outscale le 2026-08-20. Les trois sont pires que les meilleurs chiffres jamais
relevés par ce projet (3 s, 1 s et 1 s) — citer ceux-là, pas ceux-ci.

La cause de cette régression n'est pas établie. Le roulement prend désormais le
leader etcd en dernier et lui fait céder le leadership avec `talosctl etcd
forfeit-leadership` au lieu de laisser sa disparition forcer une élection
(2026-08-20).

La première exécution sous cet ordre, Scaleway le 2026-08-20, a mesuré **2 s** —
13 échantillons en échec sur 577. **Cela n'établit pas le correctif** : cette
exécution ne déplaçait que Talos (v1.13.8 → v1.13.9, Kubernetes inchangé en
v1.36.3), là où l'exécution à 5 s déplaçait aussi Kubernetes, ce qui redémarre à
soi seul un apiserver par control plane. Deux charges différentes, donc deux
chiffres non comparables. Ce que les horodatages montrent en revanche, c'est une
*forme* différente : sur les 13 échecs, deux paires adjacentes seulement étaient
consécutives, le reste étant isolé à 5-6 s d'intervalle — un échec isolé signifie
que d'autres backends servaient encore, donc deux vraies fenêtres de 2 s plutôt
qu'une longue. L'expérience qui trancherait est le même upgrade Talos-seul avec
l'ordre leader-en-dernier désactivé : une exécution, une variable.

**Ces chiffres sont ceux du control plane, pas d'un service.** `task
cluster-upgrade` lance aussi une seconde sonde pendant tout le roulement : une
charge à 2 réplicas derrière un Service (avec un PDB quand deux nœuds peuvent
l'accueillir), interrogée via le proxy de l'apiserver, rapportée en nombre de
FAIL et plus longue coupure, puis supprimée. Les échantillons pris pendant que
l'apiserver est lui-même tombé sont comptés à part, en BLIND. Elle est rapportée,
pas bloquante, et les chiffres réels du 2026-10-03 sont 0 échec sur Scaleway, 40 échecs et 20 aveugles
sur 1490 sur Outscale (`docs/status.md`).
Fonctionnement : [`cluster-upgrade.sh` § The service probe](../scripts/dev/cluster-upgrade.sh).

## De la 0.2.x à la 0.3.0 (la plateforme, pas Talos ni Kubernetes)

La 0.3.0 ne change ni Talos (1.14.2) ni Kubernetes (1.37.1). Ce qu'elle change sur un cluster en marche, dans cet ordre :

1. **Lire le plan** (`task cluster-up` s'arrête dessus). À tfvars inchangés, la seule modification attendue est le passage des volumes système Scaleway de 20 à 50 Go
   **sur place** (`scw_root_volume_size_gb`, défaut 50 ; aucun nœud n'est remplacé) et un changement de la machine config Talos. N'épingler `scw_root_volume_size_gb = 20` que pour garder
   l'ancienne taille, qui ne contient pas la pile applicative. Sur Outscale, le disque racine d'une VM en marche n'est pas redimensionné sur place : définir `outscale_root_volume_size_gb`
   (et relever les IOPS racine, infra #376) puis remplacer les workers un à un avec `task cluster-roll`. OVH et Proxmox : le disque du gabarit et `root_disk_gb` (50).
2. **Redémarrer les workers Scaleway un par un, drainés**, pour que Talos agrandisse EPHEMERAL. Utiliser `task cluster-roll` ; un `talosctl reboot` tapé à la main ne draine pas, et un
   worker qui porte une instance CNPG ne doit jamais être redémarré sans drain (voir plus bas).
3. **Agrandir les disques avant les montées de version des applications.** Les images de la 0.3.0 sont plus grosses ; un nœud de 20 Go a atteint DiskPressure après des heures de montées (lab 15c).
4. **Puis la partie apps**, une version mineure à la fois là où c'est dit : Longhorn 1.9 -> 1.10 -> 1.11 -> 1.12 (avec l'étape préalable sur la conversion des CRD), cert-manager, l'opérateur CNPG,
   Kyverno et la procédure du chart Loki sont dans `docs/patching.md` d'OpenAether-apps. Prendre d'abord une sauvegarde CNPG et une sauvegarde Longhorn ; les migrations de Zitadel et Grafana sont sans retour.
5. **Les options de durcissement sont désactivées par défaut.** Les activer une à une (`docs/hardening.md`, `docs/security-architecture.md`) ; chaque plan est lu avant d'être appliqué.
   Les options qui changent la machine config Talos (filtrage des nœuds, base de référence, transfert de journaux) passent par le plan ; si un changement exige un redémarrage, passer par `task cluster-roll`.

Non répété sur place : l'étape Loki 6.55 -> 18, Grafana, Alloy, les CRD Gateway API, Flux sur les enfants. Une installation neuve de chaque version a tourné sur les trois clouds.

## De la 0.3.x à la 0.4.0 (un cluster existant)

Écrit depuis la branche avant le tag 0.4.0, d'après le lab 25 (un cluster construit par infra 0.3.2 et apps 0.3.2, amené sur les branches 0.4.0) et le code. **Échelon : les commandes
ci-dessous sont testées avec des doublures, hors ligne ; ce que le lab 25 a fait est dit comme tel. Toute étape marquée UNVERIFIED n'a pas été jouée sur un cluster.** Le lab rejouera
0.3.2 vers 0.4.0 et corrigera cette section. Pas une affirmation de conformité.

**Chemin de mise à niveau supporté (décision du propriétaire, 2026-10-24).** Avant la 1.0.0, la mise à niveau supportée va du mineur PRÉCÉDENT au mineur courant seulement : n-1.x.x vers n.x.x, ici 0.3.x
vers 0.4.0. Aucun chemin depuis une version plus ancienne n'est construit ni documenté ; depuis la 0.2.x ou avant, passer par la 0.3.x d'abord, ou reconstruire.

**Pourquoi un simple `task cluster-up` ne suffit pas (établi par le code, un point par l'amont).** Le ConfigMap `cluster-identity`, le GitRepository `openaether` et la Kustomization
`openaether-platform` (avec son `GIT_REF`) sont des objets du manifeste inline Talos `flux-bootstrap` (`bootstrap-manifests/flux-bootstrap.yaml.tftpl`, `modules/talos`). Changer ce manifeste
change la configuration machine des control planes : c'est le « 3 to change » du plan, et `tofu apply` envoie la nouvelle config. Ce que le nœud fait ensuite du manifeste relève du contrôleur
d'application de manifestes de Talos. Sa source (Talos `release-1.14`, `manifest_apply.go`, lue le 2026-10-23 par une récupération résumée, pas clonée) teste chaque objet par un `Get` et ne
l'applique **que s'il est introuvable** ; un objet qui existe est noté et ignoré, jamais mis à jour, patché ni fusionné. Le même comportement a été vu au lab 22 pour le Deployment CoreDNS
(`docs/resilience.md`) et concorde avec le lab 25 : le ConfigMap a gardé ses quatre clés. **Un objet de manifeste inline qui existe déjà sur le cluster n'est donc jamais réécrit par un
`cluster-up` ultérieur.** Non montré : une lecture `talosctl get manifests` sur un nœud, et le même essai sur le GitRepository et la Kustomization (par la règle ci-dessus, `git_ref` ne déplace pas
non plus un cluster en marche ; le lab 25 a patché le `GIT_REF` de la Kustomization à la main). Aussi : la ligne « flux-system exists and every Flux controller is Available » lue au lab 25 est le
contrôle du VÉRIFICATEUR (`cluster-verify`), pas une décision de sauter le bootstrap. `cluster-verify` ne regarde ni le ConfigMap ni les Kustomizations, d'où un `cluster-up` terminé à 0 avec `cnpg` NotReady.

La conception ne dépend pas de ce point : la synchronisation ci-dessous lit le cluster et les valeurs rendues, et écrit ce qui diffère, quoi que fasse Talos.

Étapes, dans l'ordre (prendre d'abord un Backup CNPG, une sauvegarde Longhorn et `task etcd-snapshot` ; une personne l'exécute, plan lu) :

1. **Choisir le chemin.** Le contenu apps 0.4.0 fait passer les CRD Gateway API de 1.2.1 à **1.6.0** et Istio de 1.24.2 à **1.31.3**, change le dépôt de charts d'Istio et la classe du waypoint, et
   bascule les archives CNPG vers le plugin Barman Cloud. Sur un cluster EXISTANT, la **reconstruction à côté** reste une option : un nouveau cluster sur de nouveaux buckets depuis le tag 0.4.0,
   puis les données déplacées (`docs/disaster-recovery.fr.md` ; une reconstruction sur l'ancien bucket de sauvegarde rencontre l'ancienne archive WAL et CNPG refuse d'y archiver). Le passage sur place depuis le
   contenu 0.3.x n'a été observé qu'une fois, au lab 25 (Istio en 5 minutes, sans trafic client jugé, voir ci-dessous) ; le chemin supporté et testé est celui que nomment les notes de version 0.4.0. **Le lab 25 a observé :** la ref de la Kustomization patchée à la main, Istio 1.24.2 vers 1.31.3 sur place en
   5 minutes (istio-base, istiod, istio-cni, ztunnel Ready dans cet ordre ; cni et ztunnel Unknown/False pendant le remplacement des anciens pods), les CRD en v1.6.0, les GatewayClasses `istio`,
   `istio-remote`, `istio-waypoint` Accepted, le Gateway et le waypoint Programmed, et une route d'essai par le répartiteur de charge et le Gateway répondant 200 ; un roll Talos 1.14.2 vers 1.14.4 avant
   (API : 8 sondes en échec sur 2311, isolées de 1 s). **Le lab 25 n'a pas observé :** la convergence de toute la couche apps (le saut s'est terminé avec 9 Kustomizations NotReady, constat D9,
   corrigé ci-dessous, pas rejoué), le chemin de reconstruction à côté, le saut Loki 6.55 vers 18 (la 0.3.2 porte déjà Loki 18), le trafic de vrais clients pendant le saut Istio au-delà des sondes
   à 1 Hz, ni aucun retour arrière des CRD (elles ne reviennent pas en arrière ; la politique d'admission `safe-upgrades` des CRD 1.6 refuse un retour sous 1.5).
2. **Talos d'abord** (patch dans le mineur 1.14 : 1.14.2 vers 1.14.4) : éditer `talos_version` dans le tfvars, `task cluster-upgrade` ou `task cluster-roll` comme dans les sections suivantes. Le lab 25 l'a fait en premier.
3. **Déplacer les outils et la config.** Extraire le tag 0.4.0 de ce dépôt, puis `task cluster-up PROVIDER=… ROLE=…` en lisant le plan. S'attendre à des configs machine de control plane « to change »
   (le texte du manifeste et le pin 1.14.4) et aux nouvelles variables à leur défaut (`CHANGELOG.md`, `variables.tf`). `cluster-up` regarde maintenant lui-même les Clusters CNPG (étape 4), la ref des apps (étape 5), le ConfigMap d'identité (étape 6) et CoreDNS (ci-dessous) ; ordre : roll, presync CNPG + ref des apps (une seule étape quand le presync a du travail), identité, CoreDNS, verify.
   **CoreDNS (lab 26, K2).** La HA de CoreDNS de la 0.4.0 est un manifeste inline et n'atteint PAS un cluster construit par une version plus ancienne : Talos laisse tranquille le Deployment `kube-system/coredns` existant (2 réplicas, aucune répartition) ;
   seuls le nouveau budget et les étiquettes de zone des nœuds apparaissent. `cluster-verify` le signale (« CoreDNS runs the declared replica count and spread », BAD) et, au lab 27, il a fait finir `cluster-up` en rc 201 parce que le patch unique était documenté APRÈS `cluster-up` (FB). Le patch est désormais une étape de convergence DANS `cluster-up`, avant son verify : `task cluster-coredns-ha PROVIDER=… ROLE=…` est un essai à blanc (lit le Deployment et le nombre de nœuds, n'écrit rien, exit 3 sur une différence), `… APPLY=1` applique `scripts/ops/coredns-ha-patch.json` (réplicas et `minDomains` à `min(3, nœuds)`, répartition stricte par nœud, préférence de zone, tolérances de 30 s ; un redémarrage progressif des pods DNS), attend le rollout et relit. Idempotent ; `cluster-up` l'applique avec `APPROVE=auto` ou un « yes » tapé, sinon ÉCHOUE en nommant la commande ; `coredns_ha = false` l'ignore. À la main : `kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json` (forme à 3 nœuds). Le lab 27 a passé ce patch à la main (rollout 6 s, 3 réplicas sur 3 workers, 31 résolutions à 1 Hz, 0 échec) ; l'étape dans `cluster-up` n'est testée que hors ligne (UNVERIFIED sur un cluster). Le Corefile, l'étiquette d'image et les requests de ce Deployment restent ceux de Talos (`docs/resilience.md`).
   Tout le reste que les manifestes inline de la 0.4.0 définissent de nouveau est créé ou couvert : le budget CoreDNS et les étiquettes `topology.kubernetes.io/zone` des nœuds (les deux sont apparus, lab 26), le CRD ServiceAccount Talos
   (intégré à Talos, apparu), les nouvelles clés de `cluster-identity` (étape 6) et la ref des apps (étape 5). Les manifestes Cilium et Flux n'ont pas changé entre la 0.3.2 et la 0.4.0.
4. **Activer la réplication synchrone sur les Clusters CNPG en marche, AVANT que la ref des apps ne bouge** (étude LAB-B2, 2026-10-24). Le contenu apps 0.4.0 change la spec des pods d'un Cluster (sidecar du plugin Barman Cloud, archive par ObjectStore) ET sa
   configuration PostgreSQL (`synchronous`) en UN seul apply Flux. Sur le lab réduit ci-dessous, cette combinaison a laissé un Cluster bloqué pour de bon dans certaines exécutions : CloudNativePG attend, sans délai maximal, que tous les pods annoncent le même
   hash de configuration, et un rechargement de configuration perdu (cloudnative-pg#11627, https://github.com/cloudnative-pg/cloudnative-pg/issues/11627) empêche un pod d'y arriver ; le Cluster n'a alors aucune réplication synchrone et son archive échoue. Activer `synchronous`
   D'ABORD, comme étape à part qui ne demande qu'un rechargement, ne l'a pas fait. `task cnpg-presync PROVIDER=… ROLE=…` est un essai à blanc : il liste chaque Cluster `postgresql.cnpg.io` qui porte l'étiquette `openaether.io/managed` dans les espaces de noms de la plateforme
   (`foundation-databases`, ou `OA_CNPG_NAMESPACES` ; les Clusters d'un profil de base et les copies de test de restauration `rt-*` sont exclus ; aucun Cluster n'est nommé dans le script) et dont `spec.postgresql.synchronous` n'est pas le bloc 0.4.0, et sort en 3 s'il y a une
   différence ; sans Cluster CNPG (un cluster neuf) il sort en 0 sans rien afficher. `… APPLY=1` patche UNIQUEMENT `spec.postgresql.synchronous` (méthode `any`, nombre 1, dataDurability `required`, failoverQuorum `true`), puis attend chaque Cluster :
   phase saine, `readyInstances` égal à `spec.instances`, `show synchronous_standby_names` non vide sur le primaire, chaque réplica `quorum` ou `sync` dans `pg_stat_replication`. Pas convergé après 120 s : il lance `select pg_reload_conf()` sur chaque instance
   (déblocage R1, étape 7) et attend de nouveau ; pas convergé à 300 s : il échoue et AFFICHE les étapes de déblocage (R2). Il ne supprime jamais un pod et ne force rien ; aucun secret n'est lu ni affiché. **Il refuse (sortie 2), sans rien écrire,** quand un Cluster n'est pas
   sain, quand aucun Backup terminé d'un Cluster à changer n'a moins de 24 h (en prendre un : `kubectl cnpg backup <nom> -n <ns> --method barmanObjectStore`, puis `task backup-verify`), quand un roll Talos ou Kubernetes est en attente ou en cours (la barrière de
   `cluster-bootstrap-sync`), quand un pod précède le sidecar du plugin alors qu'un plugin est activé dans la spec du Cluster, et quand un Cluster a moins de 3 instances. **Décision sur les instances :** avec `dataDurability: required` et ANY 1, perdre l'unique réplica d'un
   Cluster à 2 instances bloquerait toute écriture, et le contenu 0.4.0 en déclare 3 (grafana-db en a 2 en 0.3.x). À la main, le script ne dimensionne pas au jugé : il s'arrête et nomme `task cnpg-presync PROVIDER=… ROLE=… APPLY=1 SCALE=1`, qui met `instances: 3` dans le MÊME
   patch que l'étude (mesuré par l'étude et le lab 27 : grafana-db à 3 instances, sain avec les noms synchrones après 36 s, étape entière 2 min 22 s, zéro perte ; l'ordre « agrandir, attendre, puis synchronous » n'a jamais été joué). **Décision (0.4.0) :** avec `APPROVE=auto`, et après le « yes » tapé, `cluster-up` passe lui-même `SCALE=1` : la tête déclare 3 instances et les labs 26 et 27 ont montré que s'arrêter est pire que d'agrandir. `SCALE=1` ne touche qu'un Cluster sous 3 ; tout autre refus échoue toujours. **Le presync et le déplacement de la ref des apps sont UNE étape de `cluster-up`** (lab 27, FA) : le presync ne vit sur le cluster qu'une fois la ref déplacée, car Flux, encore sur l'ANCIENNE ref, ré-applique le contenu `cnpg` 0.3.x à sa réconciliation de 10 minutes et l'a annulé (grafana-db revenu à 2 instances, `synchronous` retiré), donc l'arrêt puis relance documenté refusait de nouveau. `cluster-up` applique le presync, le relit, puis déplace la ref aussitôt (`task cluster-apps-ref … APPLY=1`) ; si Flux l'a annulé entre-temps, il est ré-appliqué (deux fois au plus), et s'il ne tient pas le run échoue sans toucher à la ref. Suspendre la Kustomization Flux a été envisagé et écarté : Flux a re-démarré une Kustomization `cnpg` suspendue en une minute environ (son parent l'applique), et suspendre la racine gèlerait la réconciliation dont le déplacement a besoin. Une seule question pour l'étape combinée (« yes » tapé), sinon ÉCHEC avec les deux commandes à passer à la suite (`task cnpg-presync … APPLY=1 SCALE=1` puis `task cluster-apps-ref … APPLY=1`). Testé hors ligne ; UNVERIFIED sur un cluster jusqu'au prochain lab. `cluster-verify` contrôle ensuite chaque Cluster de ce type (bloc dans la spec, ContinuousArchiving True, `synchronous_standby_names` renseigné, réplicas dans le quorum, objet FailoverQuorum).
   **Mesuré sur un lab RÉDUIT** (Scaleway, 2026-10-24 : UN nœud k3s par VM, donc les trois instances partagent un nœud ; ni Flux, ni Talos, ni Cilium, ni zones ; les vraies specs de Cluster 0.3.2 et 0.4.0, CNPG 1.30.1, plugin 0.15.1 ; 20 à 35 commits acquittés/s par
   base, pas 100 ; la recette a été jouée DEUX fois depuis un état propre) : cette étape a pris 54-57 s sans interruption d'écriture ; puis l'apply unique du contenu 0.4.0 : les deux Clusters sains 95-100 s plus tard, le primaire redémarré sur place (pas de bascule), une interruption d'écriture de
   17-22 s par base (17,7-21,8 s), **zéro commit acquitté perdu** (6899-7290 et 5322-5573 identifiants acquittés par exécution), archive WAL contiguë (**MISSING 0** sur chaque timeline), `synchronous_standby_names` renseigné avec les deux réplicas en `quorum`.
   Le même contenu 0.4.0 appliqué d'un coup a bloqué zitadel-db dans 2 exécutions sur 2 et grafana-db dans 1 sur 2 : une course, pas une certitude. **Mesuré sur la plateforme (lab 27, Scaleway, 3 CP + 5 W, 2026-10-25), presync passé en `task cnpg-presync … APPLY=1 SCALE=1` :** 2 min 22 s, rc 0 ; zitadel-db non convergé à 120 s, le rechargement R1 du script l'a convergé à 128 s (cloudnative-pg#11627 reproduit sur la vraie plateforme, 1 Cluster sur 2) ; zéro commit acquitté perdu, archive WAL contiguë (MISSING 0 dans les deux stores), réplicas dans le quorum ; le saut des apps a convergé en 13 min 25 s sans geste manuel. **Encore UNVERIFIED :** Outscale et OVH, les autres versions majeures de PostgreSQL, des données de taille réelle, l'ordre en une étape de `cluster-up`.

   **Le redémarrage du primaire (lab 27, FI) : 206 s, pas 17-22 s.** Le lab réduit n'avait pas de pool de clients. Sur la plateforme, pool Zitadel connecté, l'opérateur a redémarré le primaire de zitadel-db sur place pour le sidecar du plugin (`primaryUpdateMethod: switchover` ne s'applique pas à ce redémarrage) ; le gestionnaire d'instance a demandé un arrêt « smart » avec `smartShutdownTimeout` 180 et PostgreSQL y est resté 180 s (sessions ouvertes), puis arrêt rapide : écritures indisponibles **206,4 s**. Sémantique CloudNativePG (https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/docs/src/instance_manager.md) : CHECKPOINT puis arrêt smart « jusqu'à `.spec.smartShutdownTimeout` secondes » (180 par défaut), puis arrêt rapide dans `.spec.stopDelay` (1800) ; 0 va droit à l'arrêt rapide. La valeur est lue dans l'objet Cluster en cache du gestionnaire d'instance à l'arrêt, pas dans la spec du pod : la changer ne demande aucun redémarrage. **Changement :** chaque Cluster de la plateforme déclare `smartShutdownTimeout: 5` depuis un composant Kustomize partagé du dépôt apps, et `cnpg-presync` pose la même valeur AVANT le déplacement. Écart attendu : environ 12-25 s, **UNVERIFIED jusqu'au prochain lab**. Coût : un redémarrage ou arrêt planifié du primaire déconnecte les clients après 5 s au lieu de les attendre jusqu'à 180 s ; une transaction en cours est annulée (le travail validé n'est pas perdu).
5. **Pointer Flux vers la nouvelle ref des apps, sur le cluster.** Changer `git_ref` dans le tfvars fixe le nouveau manifeste inline, que Talos n'applique pas par-dessus les objets existants
   (ci-dessus) : les objets vivants ont donc besoin de la ref. `task cluster-apps-ref PROVIDER=… ROLE=…` (essai à blanc) affiche la valeur du tfvars, la ref que suit le GitRepository `openaether` et le
   `GIT_REF` de la Kustomization `openaether-platform`, et sort en 3 s'il y a une différence. `task cluster-apps-ref PROVIDER=… ROLE=… REF=refs/tags/<tag apps> APPLY=1` réécrit `git_ref` dans le tfvars
   (le diff est montré, l'ancien fichier reste en `<tfvars>.apps-ref-bak`), patche `spec.ref.name` du GitRepository et `GIT_REF` de la Kustomization (ces deux champs seulement ; `spec.verify` et tout
   autre champ ne sont jamais écrits), demande à Flux de réconcilier les deux et attend (300 s par défaut) que le GitRepository annonce la révision de cette ref. La ref doit être `refs/tags/…` ou
   `refs/heads/…` comme dans `variables.tf` ; une branche est une ref mobile, signalée bruyamment et refusée en `REF=` sauf `ALLOW_BRANCH=1`. `cluster-up` lance l'essai à blanc après le roll des nœuds et le presync CNPG (étape 4) et
   déplace la ref (`APPROVE=auto`, ou un « yes » tapé) ou échoue en nommant la commande ; `cluster-verify` échoue à toute différence, dans les deux sens. Le lab 26 (Scaleway) a lancé l'essai à blanc (un `task` nu affiche 201 pour le 3 du
   script, voir l'étape 6), `APPLY=1` (19 s : les deux objets patchés et relus ; Flux annonce la révision `<ref>@sha1:<commit>`, que l'attente accepte) et la seconde exécution (« in sync ») ; la règle de Talos
   a été lue avec `talosctl get manifests` (l'ensemble des manifestes est mis à jour, les objets existants non). Non exécuté : `REF=refs/tags/…` avec la réécriture du tfvars.
6. **Écrire les valeurs d'identité.** `task cluster-identity-sync PROVIDER=… ROLE=…` est un essai à blanc : il lit `tofu output cluster_identity` (la table que le gabarit de bootstrap rend lui-même :
   noms de buckets, endpoints, URL et noms d'hôtes du puits d'audit, aucun secret) et le ConfigMap vivant `flux-system/cluster-identity`, et affiche chaque clé à ajouter (`+`) ou changer (`~`) ; le code 3
   signale une différence. `… APPLY=1` fusionne SEULEMENT les clés rendues dans `data` (rien d'autre du ConfigMap, aucun autre objet), les relit, et demande à Flux de réconcilier ses Kustomizations ;
   une seconde exécution ne change rien. Une clé que le ConfigMap vivant a et que la table n'a pas est signalée et conservée. `cluster-up` lance l'essai à blanc après le roll des nœuds et écrit avec
   `APPROVE=auto` ou sur un « yes » tapé dans un terminal ; sinon il **échoue** et affiche la commande. Exécuté sur un cluster au lab 26 (Scaleway) : l'essai à blanc a listé les deux clés manquantes, `APPLY=1` les a écrites en 18 s, la seconde exécution a dit « in sync ».
   **`cluster-up` appelle les tâches, pas les scripts** (lab 26 F1 : appelé directement, le pas d'identité lançait `tofu output` hors de l'environnement de la tâche et s'arrêtait sur « Backend initialization required »,
   deux fois, après un roll de 41 minutes ; corrigé, `test-cluster-up.sh` lance le pas sans `TF_DATA_DIR` ni variable S3). **Codes de sortie que vous verrez :** les scripts sortent 3 sur une différence et 4 quand l'objet
   n'existe pas encore, mais un `task cluster-identity-sync` / `task cluster-apps-ref` / `task cluster-bootstrap-sync` nu rapporte **201** (`task: Failed to run task ... exit status 3`) ; `task -x …` (`--exit-code`)
   rend le code du script. Dans `cluster-up` c'est géré pour vous, et chaque échec nomme la commande exacte avec `PROVIDER` et `ROLE` remplis.
   Filet de sécurité côté apps : le bucket et l'endpoint de réplica valent maintenant `replica-not-set` et `https://replica-not-set.invalid` quand la clé manque ou est vide, de sorte qu'un cluster en
   retard sur cette étape a des ObjectStores de réplica inactifs et non une couche base de données NotReady. Cause du `endpointURL ... "null"` du lab : kustomize affiche le champ sans guillemets et Flux
   transforme une substitution vide en null YAML (reproduit avec `flux build` 2.9.3).
7. **Laisser la couche apps converger**, en surveillant `kubectl get kustomizations,helmreleases -A`. Ordre vu par le lab pour le maillage : base, istiod, cni, ztunnel. Le plugin Barman Cloud arrive avec la
   couche CNPG (deux réplicas en 0.4.0, CNPG 1.30.x) : les Clusters quittent `barmanObjectStore` pour l'ObjectStore du plugin. **Mesuré sur le lab réduit (étape 4), après le presync :** l'archive a basculé sur place, l'archive WAL contiguë (MISSING 0), CloudNativePG a recréé
   le primaire sur place (correctif amont de l'impasse de bascule, cloudnative-pg#10981 et plugin-barman-cloud#901, dans la 1.30.1) et tous les pods portaient le sidecar du plugin 95-100 s après l'apply. **UNVERIFIED sur la plateforme** (Flux, Talos, zones, charge : étape 4) ; prendre le
   Backup CNPG du préambule et lancer ensuite `task cluster-verify` et `task backup-verify`. **Ne jamais promouvoir ni basculer (`kubectl cnpg promote`, une bascule, `primaryUpdateStrategy: supervised`) tant qu'UN SEUL pod d'un Cluster précède le sidecar du plugin.**
   Dès qu'une entrée de plugin est dans la spec, le gestionnaire d'instance de chaque pod la charge en premier et s'arrête sur `Unknown plugin: barman-cloud.cloudnative-pg.io` quand le sidecar manque : ce pod ne peut plus rafraîchir sa configuration, la recharger, se rétrograder ni agir sur une
   bascule. Sur le lab réduit, toute reprise par bascule s'est bloquée et l'une a coupé la base plus de 9 minutes (le Service a perdu son endpoint). **Déblocage d'un Cluster bloqué plus de 5 minutes** (l'opérateur, démarré avec
   `--log-level=debug`, journalise `Waiting for all Pods to have the same PostgreSQL configuration` ; `show cnpg.config_sha256` diffère entre instances) : **R1**, le fichier est neuf et le hash en marche ancien : `kubectl -n <ns> exec <pod> -c postgres -- psql -U postgres -Atc "select pg_reload_conf()"`
   sur CHAQUE instance du Cluster (cela a rétabli les Clusters bloqués de l'étude, hashes égaux en moins de 10 s, sain en 70 s). **R2**, R1 ne suffit pas (un ancien pod dont les fichiers sont périmés et qui ne peut les rafraîchir sans le sidecar) : supprimer les ANCIENS pods réplicas UN À LA FOIS (l'opérateur recrée
   chacun depuis la nouvelle spec, environ 50 s), puis supprimer proprement l'ancien pod primaire, une seule fois (il est revenu primaire après 21 s ; une suppression propre peut rester suspendue quand l'archiveur est bloqué, 199 s au lab 26). Jamais `--force` sur le primaire d'un Cluster pas encore synchrone : c'est un failover avec perte possible.
   Rien n'automatise R2 ni un forçage. Ouvrir ensuite un ticket amont avec `kubectl cnpg status`, cette ligne de journal et le `show cnpg.config_sha256` de chaque instance.
   Après les clés manuelles du lab 25, la Kustomization `cnpg` était encore « Reconciliation in progress » 10 minutes plus tard : l'étude a reproduit un mécanisme qui explique un tel état (la barrière d'uniformité de configuration ci-dessus), mais il n'a pas été montré qu'il était la cause au lab 25 (UNVERIFIED). Si cela se reproduit, lire `kubectl -n flux-system describe kustomization cnpg` et les pods du plugin et de l'opérateur avant d'attendre.
8. **Vérifier.** `task cluster-verify`, puis les contrôles par section ci-dessous. `cluster-verify` ne lit pas les Kustomizations : lancer aussi `kubectl get kustomizations,helmreleases -A` et attendre que tout soit Ready.
   La réplication synchrone, la règle de sortie de Grafana et les autres changements 0.4.0 sont dans `CHANGELOG.md` ; la réplication synchrone n'a été rejouée que sur un lab réduit (étape 4), aucun des autres sur un ancien cluster.

## Quelle version vit où, et comment elle atteint un cluster en marche

Le modèle (infra #408, adopté le 2026-10-24) : pour chaque chose épinglée, **un pin déclaré, une commande qui y converge un cluster en marche, et un contrôle de vérification qui échoue à toute différence, dans
les deux sens** (en retard comme en avance est une différence ; une valeur illisible est UNKNOWN, jamais un succès). Échelon de tout ce qui est marqué UNVERIFIED : testé avec doublures, hors ligne, pas sur un cluster.

| Chose | Déclarée dans | Convergée par | Contrôlée par (`task cluster-verify`) | Statut |
|---|---|---|---|---|
| Talos | `talos_version` (tfvars, sinon `variables.tf`) | `task cluster-up` (`converge-versions.sh` : un nœud à la fois, refuse un retour en arrière), `task cluster-upgrade` | « every node runs the pinned Talos » (flotte MIXED nommée à part) | PROVEN sur clouds pour des versions antérieures (1.14.2 vers 1.14.4 au lab 25) ; le pin 0.4.0 UNVERIFIED |
| Kubernetes | `kubernetes_version` | idem, par la config machine (sans roll) | « every node runs the pinned Kubernetes » | PROVEN sur clouds (montées du 2026-10-03) |
| Spec de base (CNPG `synchronous`) | `spec.postgresql.synchronous` du contenu apps 0.4.0 (`any` / 1 / `required` / `failoverQuorum`), lu en direct sur chaque Cluster de la plateforme | `task cnpg-presync` (pose aussi `smartShutdownTimeout` 5 ; `cluster-up` enchaîne la ref des apps dans la même étape et passe `SCALE=1` avec `APPROVE=auto` ; `APPLY=1`, AVANT la ref des apps ; `SCALE=1` sous 3 instances) ; `cluster-up` lance son essai à blanc | par Cluster : le bloc, ContinuousArchiving, `synchronous_standby_names`, réplicas `quorum`/`sync`, objet FailoverQuorum | UNVERIFIED sur la plateforme (doublures hors ligne ; mesuré sur un lab réduit, étape 4) |
| Forme de CoreDNS | `coredns_ha` et le nombre de nœuds (`min(3, nœuds)`, répartition stricte) | `task cluster-coredns-ha` (`APPLY=1`) ; `cluster-up` le lance avant son verify | « CoreDNS runs the declared replica count and spread » | patch PROUVÉ à la main (lab 27) ; l'étape dans `cluster-up` UNVERIFIED |
| Brique Forgejo (chemin ROLE de la Kustomization racine) | `path: ./apps/flux/${cluster_role}` du manifeste inline `flux-bootstrap` ; l'overlay est `./apps/flux/management-forge` | NON convergé : `kubectl patch` en direct seulement (ci-dessous) ; `cluster-up` ne le pose ni ne le défait | NON vérifié | LACUNE, non construite (pas de tfvar ; issue FF du lab 27) |
| Ref des apps | `git_ref` | `task cluster-apps-ref` (`REF=… APPLY=1`) ; `cluster-up` lance son essai à blanc | « the GitRepository and GIT_REF both follow the declared git_ref » (seulement avec `deploy_flux = true`) | UNVERIFIED (doublures) |
| Clés `cluster-identity` | table rendue (`local.cluster_identity`, sortie `cluster_identity`) | `task cluster-identity-sync` ; `cluster-up` lance son essai à blanc | aucun dans `cluster-verify` (lacune : seul l'essai à blanc de `cluster-up` regarde) | UNVERIFIED (doublures) |
| Cilium | `CILIUM_VERSION` dans `render-bootstrap-manifests.sh`, rendu dans `cilium.yaml`, empreinte dans `upstream-artifacts.lock` | pas de commande sur place : **reconstruction à côté** (ci-dessous) | « Cilium run the pinned version » (tags d'image de l'agent et de l'opérateur) | contrôle UNVERIFIED (doublures) ; aucune mise à niveau sur place |
| Contrôleurs Flux | `FLUX_VERSION`, `flux-install.yaml` vendorisé, même lock | `task cluster-bootstrap-sync` (`APPLY=1`) | « Flux controllers run the pinned version » (les sept Deployments ; seulement avec `deploy_flux = true`) | UNVERIFIED (doublures) |
| Clusters enfants CAPI | `K8S_VERSION`, `TALOS_VERSION` dans `apps/clusters/*.yaml` (OpenAether-apps) | Flux applique le fichier ; Cluster API remplace les machines | aucun : `check-child-clusters.py` est statique ; rien ne compare les versions en marche d'un enfant | LACUNE, non construite |

`git_ref` est convergé par `task cluster-apps-ref` : l'éditer et lancer `cluster-up` seul ne déplace pas un cluster en marche. Un canal de versions (un intervalle semver sur des tags signés que Flux suit) est une
option 1.0, non construite ; aujourd'hui la version des apps est une ref exacte convergée par l'outillage.

`cluster-up` se termine en disant ce qu'il n'a PAS changé : les contrôleurs Cilium et Flux d'un cluster en marche, le contenu des apps au-delà de la ref, les enfants CAPI, et tout autre objet que Talos a créé
plus tôt depuis un manifeste inline.

## Activer la brique Forgejo (optionnelle) sur un cluster en marche (lab 27, FF)

Le forge est DÉSACTIVÉ dans les profils par défaut. Le chemin suivi par la Kustomization Flux racine vient du manifeste inline Talos (`path: ./apps/flux/${cluster_role}`), objet que `cluster-up` ne réécrit jamais, et il n'existe **aucun tfvar**. La voie supportée sur un cluster en marche est un patch en direct :

```
kubectl -n flux-system patch kustomizations.kustomize.toolkit.fluxcd.io openaether-platform --type merge \
  -p '{"spec":{"path":"./apps/flux/management-forge"}}'
```

Retour : le même patch avec `./apps/flux/management`. Le lab 27 l'a passé : `forgejo-db` et `forgejo` Ready 2 min 30 s après. **`cluster-up` ne le pose ni ne le défait, `cluster-verify` ne le regarde pas** : c'est une lacune, pas un choix ; l'issue reste ouverte. Contrôle à la main : `kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io openaether-platform -o jsonpath='{.spec.path}'`.

## Cilium et Flux sur un cluster en marche

`cilium.yaml` et `flux-install.yaml` sont des manifestes inline Talos, donc la règle ci-dessus s'applique : un pin relevé n'atteint qu'un NOUVEAU cluster. `cluster-verify` échoue maintenant quand la version en marche
diffère du pin ; voici comment chacun se referme. Écrit hors ligne ; rien n'a été joué sur un cluster.

**Contrôleurs Flux : `task cluster-bootstrap-sync PROVIDER=… ROLE=…`** (essai à blanc, code 3 s'il y a une différence ; `APPLY=1` écrit). Il vérifie `flux-install.yaml` contre `upstream-artifacts.lock`, lit le tag
d'image des sept Deployments de contrôleurs et, avec `APPLY=1`, lance `kubectl apply --server-side --force-conflicts --field-manager=openaether-bootstrap` de ce fichier, attend chaque déploiement
(`OA_ROLLOUT_TIMEOUT`, 300 s) et relit les versions. Il refuse, avant toute écriture : un retour en arrière d'un contrôleur ; un contrôleur à plus d'un mineur d'avance sur celui qui tourne (plus strict que
l'amont, qui dit que toute v2.x peut passer à toute autre v2.x : passer par les versions intermédiaires) ; un contrôleur en marche que l'artefact n'a plus (l'apply serveur ne supprime pas) ; et tout moment où un roll
Talos ou Kubernetes peut être en cours (nœud non Ready ou cordonné, versions différentes entre nœuds ou du pin). Appui : le guide de mise à niveau de Flux donne `kubectl apply --server-side -f install.yaml` pour un
cluster installé avec kubectl (https://fluxcd.io/flux/installation/upgrade/). Les CRD de Flux sont remplacées par le même apply et ne reviennent pas en arrière.

**Cilium : contrôle plus reconstruction à côté, pas de commande sur place.** Le contrôle (« Cilium run the pinned version ») et l'essai à blanc de `cluster-bootstrap-sync` signalent la différence ; `APPLY=1` sur
Cilium est refusé (code 5, ou 2 avec `COMPONENT=cilium`). Pourquoi pas d'apply serveur de `cilium.yaml`, alors que le guide Cilium décrit `helm template` puis `kubectl apply`
(https://docs.cilium.io/en/stable/operations/upgrade/) : (1) les DaemonSets de `cilium.yaml` se remplacent avec `maxUnavailable: 2`, donc deux nœuds perdent leur agent CNI en même temps, et `docs/admin-access.fr.md`
note un enfant à 2 nœuds sorti dégradé d'un changement Cilium (la page concerne les enfants CAPI, mais c'est le même remplacement progressif qui serait déclenché) ; (2) le guide exige son pré-vol (pré-tirage des
images, validation des politiques) et dit que le seul chemin testé va entre versions mineures consécutives ; rien ici ne lance le pré-vol ; (3) l'apply ne supprime pas les objets qu'un rendu plus récent retire ;
(4) le ConfigMap est écrasé en bloc, et l'agent et l'opérateur ne sont pas ordonnés. Qui accepte ces risques suit le guide amont avec les mêmes valeurs épinglées ; ce dépôt ne construit ni ne teste ce chemin.
**La reconstruction à côté** est la voie documentée : un nouveau cluster depuis le nouveau tag, les données déplacées (`docs/disaster-recovery.fr.md`), l'ancien retiré.

## Kubernetes d'abord

Elle ne redémarre rien, ce qui isole le roulement du control plane de celui des
nœuds.

```bash
# modifier kubernetes_version dans envs/<role>-<provider>.tfvars, puis
task infra-plan  ROLE=management PROVIDER=<p> OUT=tfplan
task infra-apply ROLE=management PROVIDER=<p> PLAN=tfplan
```

Talos réconcilie les static pods et les kubelets ; attendre que chaque nœud
rapporte la nouvelle version avant de continuer. Ce chemin contourne `talosctl upgrade-k8s`
volontairement. Mesuré sur un vrai cluster OVH (2026-10-03, 1.36.3 vers 1.37.1),
`upgrade-k8s` a laissé l'apiserver injoignable jusqu'à 10 s et le service de sonde
6 s ; cette étape a mesuré 2 s sur Scaleway et 9 s sur Outscale pour le même
passage. Il n'est pas plus doux, demande un `talosctl` aligné sur la flotte (un
client 1.13 refuse 1.36 vers 1.37), et il faut ensuite bumper et appliquer le pin.

## Puis Talos, sur place

Bumper `talos_version`, construire l'image de la nouvelle version (les ressources
de nœud ignorent l'image, mais la *data source*, elle, doit résoudre), appliquer,
puis dérouler.

```bash
# modifier talos_version dans le tfvars D'ABORD, puis
task image-build PROVIDER=<p> VERSION=<new> ENSURE=1
task infra-plan  ROLE=management PROVIDER=<p> OUT=tfplan
task infra-apply ROLE=management PROVIDER=<p> PLAN=tfplan
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<clé> -- --cp-only --upgrade
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<clé> -- --workers-only --upgrade
```

Le pin bouge avant le build (`talos-image.sh` ne compare un `image_id` pinné qu'à
l'image de la version qu'il construit). Chaque version a son propre état d'image : un
build ne remplace jamais une autre image ; s'il échoue, relancer, ou remettre
`talos_version` à l'ancienne version pour que le cluster replanifie. Une fois la
montée vérifiée, `RETAIN=1` garde la version du cluster et celle d'en dessous et
détruit les autres images (`cluster-up` le lance, `cluster-upgrade` non) ; ses règles,
`LIST=1` et `PRUNE=1` sont dans
[`talos-image/README.md`](../infrastructure/opentofu/talos-image/README.md). Les
montées du 2026-10-03 ont suivi cet ordre sur les trois clouds, sur la voie à
image unique que ceci remplace.

`talos_version` est le Talos du nœud, pas le contrat de configuration machine : le module génère
sous un contrat plafonné (`config_contract` dans `modules/talos/main.tf`, qui dit pourquoi). Un
bump vers 1.14 change l'image d'installation dans la configuration ; les rendus hors ligne sous
le provider 0.12.0 ne montrent rien d'autre, mais aucun `cluster-upgrade` n'a encore tourné sous lui.

**Après avoir tiré un pin de provider**, le `.terraform.lock.hcl` versionné de `cluster/` et `talos-image/` nomme
déjà la version (docs/supply-chain.fr.md) : un `tofu init` simple dans `infrastructure/opentofu/cluster` suffit, et
un init qui dit que le lock ne correspond pas à la contrainte signale une PR qui a oublié `task lock-providers`.
Cette tâche déplace chaque provider dans sa contrainte : lire le plan suivant. Un clone qui garde un ancien lock
local (d'avant son versionnement) se corrige en supprimant ce fichier puis en lançant `tofu init`.

**Sur Outscale, la construction de l'image domine tout l'upgrade.** L'image est
enregistrée depuis un snapshot importé via une file côté provider : 8 min le
2026-08-18, plus de 60 min le 2026-07-25. Elle bloque avant qu'un seul nœud soit
touché, et aucun nœud n'en démarre jamais — le roulement installe depuis l'Image
Factory (`installer_image`). Elle n'est requise que parce que `image_id` n'est pas
pinné : la source de données résout l'OMI par un nom qui porte la version.
`ReadSnapshots` dit où en est réellement l'import ; le « Still creating... » de
l'apply, non.


`--upgrade` appelle `talosctl upgrade`, qui conserve le disque, l'identité et
l'appartenance etcd du nœud, le drain lui-même, et refuse une mise à niveau de
control plane qui coûterait son quorum à etcd. Un nœud à la fois, avec une porte
de santé entre chacun, et rejouable : un nœud déjà sur la version cible est
sauté. Les control planes d'abord — un worker a besoin d'un control plane sain
pour se drainer.

### Le cluster doit pouvoir perdre un nœud

À vérifier avant de dérouler, pas après qu'un drain a épuisé son délai :

```bash
kubectl describe nodes -l '!node-role.kubernetes.io/control-plane' | grep -E '^Name:|^  cpu '
```

Les demandes doivent laisser l'équivalent d'un nœud libre. Mesuré le
2026-08-15 : les trois workers `DEV1-L` de Scaleway étaient à 72/47/27 % et tous
les drains sont passés ; les trois `b3-8` d'OVH à 78/99/100 %, et le premier
drain a épuisé ses 900 s sans la moindre erreur d'éviction — les pods évincés
n'avaient nulle part où aller, donc les budgets dont ils relèvent ne se sont
jamais rétablis. Ajouter un worker ou un gabarit plus gros avant de dérouler :
c'est un prérequis, pas un symptôme.

### Ce qui bloque vraiment un drain, et les deux portes qui le débloquent

**Un primaire CNPG est inévinçable tant qu'il est primaire.** L'opérateur publie
une budget `<cluster>-primary` à `disruptionsAllowed=0 / currentHealthy=1 /
expectedPods=1`, et `nodeMaintenanceWindow` ne la relâche pas — mesuré sur
Scaleway le 2026-08-15 : fenêtre activée, CNPG supprime la budget des *réplicas*
et conserve celle du primaire. C'est tout le drain de 900 s.

Le roll pose donc **`spec.enablePDB: false`** sur chaque cluster CNPG pendant
qu'il déroule, et le remet à `true` en sortie. Les deux budgets disparaissent,
primaire compris ; le webhook de l'opérateur recommande lui-même ce réglage
plutôt que la fenêtre de maintenance. Le primaire est alors évincé comme
n'importe quel pod et CNPG bascule sur un réplica — un failover non planifié,
c'est-à-dire exactement ce que le redémarrage du nœud allait provoquer quelques
secondes plus tard. La fenêtre de maintenance reste posée à côté : c'est elle qui
dit à l'opérateur de réutiliser le PVC au lieu de reprovisionner une instance
que le stockage local ne pourrait pas déplacer. En sortie, le roll vérifie la
restauration : il attend environ deux minutes (3,5 mesurées apiserver coupé) le
budget `<cluster>-primary` de chaque cluster et chaque Kustomization
propriétaire, puis sort en erreur en nommant ce qui reste. Ctrl+C interrompt
l'attente (« restore NOT verified », code 130) ; un roll arrêté entre deux nœuds
le dit au lieu de « complete ». Le verdict tombe après le dernier nœud remplacé :
ne pas relancer le mode remplacement pour l'effacer, il remplacerait tous les
nœuds à nouveau. Corriger à la main ce qui est nommé et lancer
`scripts/ops/backup-state.sh`, que `task cluster-roll` saute après une sortie non
nulle. `task cluster-upgrade` s'arrête au premier roll qui finit ainsi :
si c'est celui des control planes, les workers ne sont pas roulés.

**Tout ce qui a une forme de quorum bloque aussi.** Trois exécutions le
2026-08-14 se sont arrêtées sur trois pods différents — réplicas CNPG,
`kube-state-metrics`, puis `openbao-1` sur une budget raft voulant 2 sur 3 —
sans aucun primaire CNPG dans le dernier cas. Toujours la même forme : le roll
arrivait au nœud suivant pendant que les charges à quorum du précédent
rejoignaient encore. Avant de cordonner, il attend donc que **chaque budget
couvrant un pod de ce nœud rapporte `disruptionsAllowed >= 1`**.

Il n'attend que les budgets qui peuvent encore se rétablir
(`currentHealthy < expectedPods`). Certaines sont à zéro par construction —
`<cluster>-primary`, les `instance-manager-*` de Longhorn, un
`kube-state-metrics` à un seul réplica — et les attendre, c'est attendre
indéfiniment.

Si un drain dépasse quand même son délai, le roll **refuse** et nomme les pods,
au lieu de redémarrer le nœud sous eux. Ne pas passer en force : la version que
ceci remplace avertissait puis redémarrait quand même, ce qui a laissé
`zitadel-db` bloqué en switchover et `grafana-db` sans instance active. Relancer
la même commande une fois le pod sain — les nœuds déjà à la version cible sont
sautés.

```bash
# ce qui refuse, sur le nœud que le roll a nommé
kubectl get pdb -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
ALLOWED:.status.disruptionsAllowed,HEALTHY:.status.currentHealthy,EXPECTED:.status.expectedPods

# état CNPG — le nom qualifié est obligatoire : sur un cluster portant CAPI,
# `kubectl get cluster` désigne clusters.cluster.x-k8s.io, pas celui-ci.
kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,\
NAME:.metadata.name,PRIMARY:.status.currentPrimary,READY:.status.readyInstances

# et, pour une base en détail (plugin installé par `task setup`)
kubectl cnpg status <cluster> -n <ns>
```

### Ne jamais redémarrer un nœud qui héberge encore un volume Longhorn RWX

Un worker qui héberge à la fois le pod share-manager d'un volume RWX et un pod qui le monte n'a pas fini un `talosctl reboot` propre au lab 12
(Scaleway, Longhorn 1.12.1, Talos 1.14, apps #124) : Talos est resté dans `unmountPodMounts` (`nfs: server ... not responding`) plus de
12 minutes, deux fois, et seul un reset matériel par le fournisseur y a mis fin. **Ne jamais redémarrer, éteindre ni faire `talosctl upgrade`
d'un tel nœud sans drain.** `cordon_drain` (utilisé par `cluster-roll`, `cluster-upgrade`, `cluster-shrink`) attend désormais, après le drain,
qu'il ne reste sur le nœud ni pod share-manager ni pod montant une claim Longhorn RWX (`RWX_CLEAR_TIMEOUT`, 300 s par défaut) ; s'il en reste,
il dé-cordonne le nœud, liste les pods et refuse de continuer. À la main : drainer, puis
`kubectl -n longhorn-system get pods -o wide | grep share-manager` doit montrer un autre nœud. Test hors ligne : `scripts/dev/test-rwx-drain-gate.sh`.
Pas encore prouvé sur un cluster : qu'un nœud drainé redémarre ensuite en 1,5 minute environ (le dépôt apps raccourcit aussi les délais NFS RWX).

### Ne jamais redémarrer sans drain un worker qui porte une instance CNPG

Un redémarrage de nœud SANS drain laisse les pods d'instance CNPG de ce nœud en phase `Succeeded` (l'arrêt propre du kubelet arrête postgres avec le code 0) et
CNPG 1.23.1 ne les redémarre jamais : les deux bases sont à l'arrêt, Zitadel et la Gateway répondent 503 (lab 11, plus de 30 minutes ; la page des pièges du dépôt OpenAether-apps). `cluster-roll`,
`cluster-upgrade` et `cluster-shrink` drainent d'abord, donc sans risque ; un `talosctl reboot` ou `shutdown` tapé à la main non. Après un redémarrage sans drain :
`kubectl get pods -A --field-selector=status.phase==Succeeded`, puis supprimer les pods CNPG listés (jamais leur PVC). Les opérateurs CNPG plus récents (le pin des apps a dépassé la 1.23) ne sont
pas connus pour ce défaut ; l'habitude ne coûte rien. L'outillage de roll ne garde pas un redémarrage qu'il ne lance pas (infra #358) : cette page est le garde-fou.

### Une base restée en « Failing over » après le roll

Le roll se termine, l'API n'a pas bronché, et quelques minutes plus tard un
cluster CNPG reste en `Failing over` ou `Switchover in progress` sans bouger. Vu
deux fois le 2026-08-15, deux fois la même forme : l'ancien primaire rétrogradé
attend la fin du switchover pendant que le réplica *cible* attend un WAL que
seul un primaire en marche produirait. Une troisième instance peut être
parfaitement saine pendant tout ce temps.

Redémarrer l'opérateur ne change rien. Supprimer le pod de la **cible** résout
en une minute environ : il redémarre, termine sa récupération, et le cluster
élit :

```bash
kubectl get clusters.postgresql.cnpg.io -n <ns> <cluster> \
  -o jsonpath='{.status.currentPrimary} -> {.status.targetPrimary}{"\n"}'
kubectl delete pod <targetPrimary> -n <ns>
```

`kubectl cnpg promote` n'est pas la réponse ici : avec le plugin que ce dépôt
épingle, il sort 0, affiche « will be promoted » et laisse `targetPrimary`
inchangé. Ouvert en issue.

Le premier apply après un bump de `talos_version` échouait une fois sur OVH et
Outscale avec « Provider produced inconsistent final plan » (issue amont
`siderolabs/terraform-provider-talos` #352, corrigée dans la 0.12.0, qui est
épinglée). Le module remplace chaque application de machine config lors d'un
changement de version (`replace_triggered_by`), donc le bump passe en un seul apply :
les montées du 2026-10-03 sont passées par `cluster-upgrade`, qui n'a aucun retry,
sur les trois clouds. Le contournement reste tant qu'un run sans lui n'a pas passé (#83).

## Ce qu'il faut vérifier, au-delà de « c'est revenu »

Après chaque nœud, puis à la fin :

- **son nom n'a pas changé** — une entrée `talos-xxxxx` signifie que le hostname
  n'a pas tenu, et le prochain reboot orphelinera un autre objet node
- le nombre de nœuds n'a pas augmenté, et etcd rapporte toujours tous ses membres
- le compteur de FAIL de la sonde n'a presque pas bougé
- **`tofu plan` est vide.** S'il veut remplacer des nœuds, l'image de boot et la
  version qui tourne ont divergé — ce plan-là coucherait le cluster. S'arrêter et
  lire § Node image drift avant de lancer quoi que ce soit d'autre.

```bash
task infra-plan ROLE=management PROVIDER=<p> STRICT=1   # sortie 2 = non convergé
```

## Itérer sur le roll lui-même, sans reconstruire le cluster

Corriger ce script voulait dire redéployer un cluster de 85 minutes pour en
exercer les vingt dernières. Ce n'est pas une fatalité : les deux gestes
ci-dessous ont servi sur un cluster vivant le 2026-08-15, et
[`scripts/dev/roll-lab.sh`](../scripts/dev/roll-lab.sh) les rend reproductibles.
Il refuse de tourner si le tfvars ne nomme pas un environnement jetable **et** si
le kubeconfig n'atteint pas le cluster que cet état décrit, et il annonce ce
qu'il va changer avant de le changer.

```bash
scripts/dev/roll-lab.sh status <provider> --offset <n>   # ce qu'un resume sauterait
scripts/dev/roll-lab.sh resume <provider> --offset <n>   # relancer le roll, en minutes
scripts/dev/roll-lab.sh inject-cnpg-deadlock <provider> --offset <n>
scripts/dev/roll-lab.sh cleanup <provider> --offset <n>  # décordonner ce qui est resté
```

**Resume.** Un nœud déjà sur la version cible est sauté : un roll corrigé se
rejoue donc sur place. `resume` lance `rolling-replace.sh <p> --upgrade
--workers-only --yes` après avoir vérifié les prérequis que le roll, lui,
découvre trop tard — un cluster vivant, et un tunnel Talos par nœud.

**Inject.** Le blocage décrit au § Une base restée en « Failing over » a coûté
quatre rolls cloud à caractériser et se reproduit en deux minutes environ :
cordonner le nœud qui porte le primaire d'un cluster et supprimer ce pod. Son PVC
`local-path-retain` l'épingle au nœud cordonné, il ne peut donc pas revenir, et
CNPG se fige. La commande vérifie avec le détecteur **du roll lui-même** et sort
en erreur si le blocage n'est pas apparu — elle ne peut pas annoncer un succès en
silence. `cleanup` défait tout ; CNPG se répare dès que le pod peut être
replanifié.

Moins cher encore, et c'est là qu'une correction de garde commence :
[`scripts/dev/test-rolling-replace.sh`](../scripts/dev/test-rolling-replace.sh)
exerce la même logique contre un kubectl bouchon, en quelques secondes et sans
cluster.

## Remplacer un nœud plutôt que le mettre à niveau

`--upgrade` ne peut pas porter un changement de disque ou de zone : ceux-là
exigent une nouvelle VM. Même script, sans `--upgrade` : il draine, applique un
`-replace` ciblé et attend, un nœud à la fois. Ce chemin-là, lui, exige que la
nouvelle image cloud existe.

Un nouveau **schematic**, en revanche, `--upgrade` le porte depuis le
2026-08-19. Ce n'était pas le cas avant : toutes les portes comparaient le tag de
version, si bien qu'un nœud sur l'ancien schematic à la version cible s'entendait
répondre « already runs v1.13.8 — skipping », et qu'un changement d'extensions
système n'était livrable par aucun chemin. Le roulement lit désormais le
schematic sur le nœud (`talosctl get extensions` le publie) et fait rouler un
nœud dont la version correspond mais pas l'image.

### Changer la taille d'un nœud est une mise à jour en place, chez tous les providers

⚠️ `instance_type` (Scaleway, Outscale), `flavor_name` (OVH) et
`cpu_cores`/`memory_mb` (Proxmox) ne provoquent pas de remplacement : le
provider arrête, redimensionne ou redémarre l'instance et garde son disque.
`task infra-apply` planifie donc N mises à jour et 0 destruction, et les
applique à **tous les nœuds en même temps**. Mesuré sur OVH seulement, le
2026-08-15 : six nœuds passés ensemble en `VERIFY_RESIZE` et l'apiserver
injoignable plusieurs minutes. Pour les trois autres, le verdict vient du source
des providers aux versions résolues le 2026-09-26 et d'un plan hors ligne avec
les vrais binaires provider, pas d'un changement de taille en réel (#51). La garde « un nœud à la fois » de
`rolling-replace` ne l'attrapait pas : elle comptait ce qu'un plan DÉTRUIRAIT, et
un redimensionnement ne détruit rien. Elle refuse désormais aussi un plan qui
change un autre nœud (ci-dessous).

**Ne pas le faire passer par le roulement.** Mesuré sur Scaleway, le
2026-10-02 : `instance_type` augmenté, `task cluster-roll -- --workers-only` a
remplacé le worker 0 puis, dans son étape de configuration, redimensionné les
trois control planes en place en 25 s ; l'apiserver derrière le load balancer a
été injoignable 56 s. `-target` entraîne ses dépendances, et le compte des
destructions ne voit pas un redimensionnement. Le roulement planifie désormais
ses deux étapes avant de cordonner quoi que ce soit et refuse un plan qui change
un autre nœud (`foreign_changes`) : sur ce cluster, avec un changement de taille
en attente sur les six nœuds, il s'est arrêté au worker 0 avant le cordon, en
nommant les trois control planes et les deux autres workers. Reste non mesuré : si l'étape de configuration ciblée d'OVH, d'Outscale et
de Proxmox entraîne les autres nœuds ; le même refus les couvre si c'est le cas.

**Procéder nœud par nœud, en place.** `kubectl drain` du nœud, `tofu plan
-target=<ce serveur>` en vérifiant que c'est exactement une mise à jour,
appliquer ce fichier, attendre Ready, `kubectl uncordon`, nœud suivant. Mesuré
sur Scaleway le même jour, trois control planes puis les workers : etcd 3/3
après chacun, 5 sondes d'une seconde en échec sur 241 et aucune au-delà de 1 s,
environ une minute par nœud. Aucune garde de budget ni d'etcd en dehors de ce
qui est vérifié à la main.

Deux cas transformeraient un changement de taille en remplacement : le
`replace_on_type_change` de Scaleway et, sur OpenStack, un nœud dont le gabarit
enregistré est vide (par exemple parce que le gabarit a été supprimé). Ce serait
pire, puisque tous les nœuds seraient détruits en même temps.
[`tests/node-size-change.tftest.hcl`](../infrastructure/opentofu/cluster/tests/node-size-change.tftest.hcl)
vérifie que le drapeau de Scaleway reste désactivé.

## Un nœud déjà mort

`task cluster-roll` exige que tous les nœuds soient Ready et vide chacun avant de le toucher ; un nœud mort ne peut ni l'un ni l'autre. Utilisez `task cluster-node-state PROVIDER=… NODE=…`
(lecture seule, nomme la commande suivante), puis `task cluster-node-recover` quand le fournisseur dit que la machine tourne, ou `task cluster-replace-node` quand elle est arrêtée, en
erreur ou disparue. La seconde fait le même remplacement que le déploiement pour ce seul nœud (`rolling-replace.sh --dead --node=…`), après un examen des survivants et
avec le membre etcd retiré avant l'objet Node. Le déploiement attend aussi maintenant que le kube-apiserver de chaque plan de contrôle redémarré serve avant de continuer
(#42). La procédure, les exercices et ce qui n'est PAS VÉRIFIÉ sont dans [`resilience.fr.md`](resilience.fr.md).

## Retirer des nœuds

Baisser `control_planes` ou `workers` dans les tfvars faisait détruire à OpenTofu la machine d'indice le plus
haut et ses volumes de données, sans drain, sans sortie d'etcd et sans suppression du Node. `cluster-up`,
`infra-apply` et `grow-nodes.sh` refusent désormais un tel plan, et le retrait a ses deux commandes, comme la
destruction :

```bash
# baisser le compte dans envs/<role>-<provider>.tfvars, puis
task cluster-shrink-plan PROVIDER=scaleway     # lecture seule : ce qui part, et le cluster peut-il le perdre
task cluster-shrink PROVIDER=scaleway PLAN=shrink-management-scaleway.json
```

Le périmètre vient du plan qu'OpenTofu fait lui-même, jamais des tfvars ; `cluster-shrink` le recalcule et refuse
s'il a bougé. Seuls les indices les plus hauts peuvent partir, un run de workers peut en prendre plusieurs (un à la
fois, le plus haut d'abord), un run de control plane en prend un, et sous trois control planes il faut
`-- --allow-below-ha` sur les deux commandes. Il reste au moins un worker et un control plane.

| | worker | control plane |
|---|---|---|
| réversible | éviction Longhorn, drain | snapshot etcd, leadership etcd passé, drain |
| point de non-retour du membre | | `etcd leave` |
| la machine | `talosctl shutdown`, puis suppression du Node | idem |
| irréversible | destruction ciblée des seules ressources de ce nœud, volumes de données compris | idem, et son appartenance au load balancer |
| après | rafraîchir les sorties et les tunnels, appliquer la config des nœuds restants un à un, plan vide, `cluster-verify` | idem |

Il refuse avant de toucher à quoi que ce soit quand : le plan change plus que le retrait (une autre édition en
attente, un nombre de disques modifié alors que la machine reste, une suppression de nœud que tofu n'attribue pas
à un compte abaissé) ; un volume est épinglé au nœud (données CNPG ou local-path : les déplacer d'abord) ;
Longhorn aurait moins de nœuds qu'un volume n'a de réplicas ; les workers qui restent ne portent pas les requêtes
CPU ; un nœud n'est pas Ready ; etcd n'a pas les membres qu'il devrait. « Éteint » n'est jamais lu sur le tunnel
du nœud lui-même : Talos doit accepter l'arrêt, un control plane qui n'est pas celui qui part doit cesser deux fois
d'atteindre la machine, et son Node doit être NotReady. Un run interrompu en route se termine en relançant
`cluster-shrink-plan` puis `cluster-shrink` ; un nœud déjà sorti de Kubernetes et éteint, un membre etcd déjà parti,
sont sautés.

**Mesuré sur un vrai cloud, le 2026-10-04**, sur un cluster à 3 control planes en Talos 1.14.2 avec Cilium, sans
Longhorn ni CNPG : un worker, puis un control plane (3 à 2), sur chacun de Scaleway, OVH et Outscale. Chaque run
s'est terminé par un `cluster-verify` vert (13/13 après un worker, 12/12 après le control plane, qui affiche
`~ NOT HA` à deux), un etcd aux membres restants exactement, et l'API du provider listant exactement les machines
restantes (aucun volume, port, adresse ni NIC du nœud retiré). La destruction ciblée était exactement le lot lu :
un worker fait 5 ou 6 ressources, un control plane de 3 (Outscale) à 5, plus l'appartenance au load balancer mise à
jour dans le même apply. Un `/readyz` authentifié à travers le load balancer chaque seconde, pendant le retrait du
control plane : Scaleway 12 échecs sur 350 (huit délais d'attente isolés sur 40 s, puis quatre échecs instantanés de
suite environ 20 s avant la fin du run : attribués, sans l'avoir isolé, à la sonde qui lisait le kubeconfig pendant
que `task kubeconfig` le réécrivait, comme pour le worker d'OVH ci-dessous), OVH 13 sur 374 (isolés, sur 76 s),
Outscale 13 sur 220 (plus longue série 3 sondes, sur 57 s). Les échecs isolés, c'est le load balancer qui envoie
encore une requête sur trois à un control plane sorti d'etcd ; un client qui réessaie ne les voit pas. La durée
d'OVH correspond à sa sonde de santé (5 × 15 s) ; celle de Scaleway est plus courte (40 s contre 75 s) et la mise à
jour du membre dans le même apply n'a pas été horodatée : ce qui a arrêté les échecs n'y est pas séparé. Sortir le
membre du load balancer d'abord n'est pas construit ; son effet n'a pas été mesuré. Les retraits de workers :
Outscale 1 sonde en échec sur 215, OVH aucune (hors l'instant où `cluster-verify` a réécrit le kubeconfig que la
sonde lisait) ; celui de Scaleway n'a pas été sondé. La sonde lisait le kubeconfig vivant jusqu'au run worker d'OVH,
une copie privée ensuite.

Sur Scaleway, le cluster a ensuite été reconstitué à 3 + 2 par un seul `cluster-up` : `cluster-verify` 13/13, et
`cluster-idempotency` a passé (plan vide, les cinq nœuds inchangés).

Une limite : l'étape de clôture applique toute mise à jour de machine config en attente, un nœud à la fois, pas
seulement celle que causent les comptes ; une édition de machine config faite dans les mêmes tfvars part donc avec le
retrait. La faire séparément.

**Longhorn, Scaleway, 2026-10-04** (Longhorn 1.13.0 sur les volumes utilisateur chiffrés) : un volume dont l'unique
réplica était sur le worker qui part, avec un blob à somme de contrôle écrit depuis un pod sur l'autre worker. Un
second volume voulant deux réplicas a été refusé (`wants 2 replicas, 1 node(s) would remain`). Sans lui, le retrait a
demandé à Longhorn d'évacuer le nœud, le réplica est passé sur le worker qui reste avant le début du drain, le volume
est resté sain et attaché, la somme de contrôle du blob a tenu, et l'entrée de nœud Longhorn est partie avec le nœud.
Le webhook de Longhorn refuse une modification de nœud pendant qu'il synchronise ses disques (« please retry
later ») : la demande d'évacuation est donc rejouée.

**CNPG, Scaleway, 2026-10-04** (CloudNativePG 1.30.1 sur un cluster d'un control plane et de deux workers, deux
instances sur une classe Longhorn à un réplica, 1000 lignes écrites) : le réplica était sur le worker qui part. Le
retrait a ouvert la fenêtre de maintenance de CNPG et retiré ses budgets avant le drain, l'instance est revenue sur
le worker qui reste avec son volume, les deux instances avaient les 1000 lignes, le cluster était sain à deux
instances, et le budget et la fenêtre ont été remis à la fin. Ce cluster est aussi la forme non-HA (un control
plane), et le retrait y a tourné sans changement.

Un second run a mis le **primaire** sur le worker qui part (même forme de cluster, un pod écrivain sur le worker qui
reste insérant une ligne par seconde à travers le service en lecture-écriture). Le drain l'a expulsé, CNPG a basculé
sur le réplica de l'autre worker et recréé l'ancien primaire là comme réplica avec son volume ; le cluster était sain
à deux instances, les deux avaient les 1000 lignes, et sur 368 insertions 2 ont échoué (une série de 2 s) et toutes
celles qui ont été acquittées étaient sur le nouveau primaire. Le budget et la fenêtre ont été remis à la fin.

Non mesuré : Proxmox, et un retrait interrompu en route sur un vrai cloud.

## La clé de chiffrement des Secrets (etcd) — non rotatable sur place

Les Secrets Kubernetes sont chiffrés dans etcd avec le fournisseur `secretbox` (XSalsa20-Poly1305), posé par
`cluster.secretboxEncryptionSecret`. C'est le fournisseur local recommandé par Kubernetes, mais XSalsa20-Poly1305
ne figure pas parmi les modes AEAD que liste ANSSI PA-079 R12 (GCM, CCM, EAX, ChaCha20-Poly1305). **Dérogation
documentée :** Talos n'offre ici que `secretbox` et `aescbc`, et `aescbc` n'est pas un AEAD. Un fournisseur KMS v2 le
remplacerait, mais seulement avec un KMS hors du cluster ; OpenBao dans le cluster serait circulaire.

La clé est un `random_bytes` (32 octets) dans le tfstate, chiffré côté client, et dans la machine config de chaque
control plane. La perdre rend illisibles tous les Secrets d'un snapshot etcd.

**Il n'y a pas de procédure de rotation ici, volontairement.** La machine config ne prend qu'une clé : remplacer la
valeur (ou faire un `taint` de `random_bytes.etcd_encryption_secret`) laisse les Secrets existants chiffrés avec une
clé que l'apiserver n'a plus. Une rotation à deux clés (ajouter la nouvelle, réécrire tous les Secrets avec
`kubectl get secrets -A -o json | kubectl replace -f -`, retirer l'ancienne) est la séquence Kubernetes habituelle, mais
on n'a ni vérifié ni exécuté que Talos accepte la seconde clé. D'ici là, le seul chemin connu sûr après une fuite
soupçonnée de la clé est un nouveau cluster, réamorcé depuis OpenBao. Ne pas répéter la séquence ci-dessus sur un
cluster dont on a besoin.
