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
Sous le refus d'ingress par défaut de la plateforme, le proxy ne peut pas atteindre le
pod de la sonde sans une politique qui le laisse entrer (le labo 25 a affiché « 394 FAIL,
2 BLIND sur 396 échantillons » : une politique, pas une panne ; infra #403). Le namespace
de la sonde reçoit donc une `CiliumNetworkPolicy` pour le plan de contrôle (les entités
`host`, `remote-node` et `kube-apiserver`, port 8080 seulement : laquelle correspond au
trafic du proxy n'est pas établi, donc les trois), et avant le début de la mise à niveau
on demande le pod au proxy (jusqu'à 15 essais, 2 s d'écart). S'il ne répond jamais alors
que l'apiserver répond, l'exécution affiche `NOT MEASURING` et ne fait aucune affirmation
sur le service, et la mise à niveau continue (toujours rapporté, pas bloquant). Un cluster
sans le CRD de Cilium ne reçoit aucune politique. Niveau de preuve : simulé
(`test-cluster-checks.sh`) ; la politique sur un vrai Cilium, et si les trois entités
suffisent, est NON VÉRIFIÉ sur un cluster.

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

Écrit depuis la branche avant le tag 0.4.0, d'après le lab 25 (un cluster construit par infra 0.3.2 et apps 0.3.2, amené sur les branches 0.4.0) et le code ; le passage 0.3.2 vers 0.4.0 a ensuite été rejoué sur Scaleway au lab 28B (un seul `task cluster-up`, 39 min 13 s, voir « Déplacement et opérations sur les nœuds » dans `docs/resilience.fr.md`). **Échelon : les commandes
ci-dessous sont testées avec des doublures, hors ligne ; ce que les labs ont fait est dit comme tel. Toute étape marquée UNVERIFIED n'a pas été jouée sur un cluster par ces labs (la 0.4.0 n'a pas rejoué le passage sur OVH ni sur Outscale).** Pas une affirmation de conformité.

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
contrôle du VÉRIFICATEUR (`cluster-verify`), pas une décision de sauter le bootstrap. Au lab 25, `cluster-verify` ne regardait ni le ConfigMap ni les Kustomizations, d'où un `cluster-up` terminé à 0 avec `cnpg` NotReady. Depuis la 0.4.1 il lit le ConfigMap (le tableau ci-dessous) ; il ne lit toujours pas les Kustomizations.

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
   seuls le nouveau budget et les étiquettes de zone des nœuds apparaissent. `cluster-verify` le signale (« CoreDNS runs the declared replica count and spread », BAD) et, au lab 27, il a fait finir `cluster-up` en rc 201 parce que le patch unique était documenté APRÈS `cluster-up` (FB). Le patch est désormais une étape de convergence DANS `cluster-up`, avant son verify : `task cluster-coredns-ha PROVIDER=… ROLE=…` est un essai à blanc (lit le Deployment et le nombre de nœuds, n'écrit rien, exit 3 sur une différence), `… APPLY=1` applique `scripts/ops/coredns-ha-patch.json` (réplicas et `minDomains` à `min(3, nœuds)`, répartition stricte par nœud, répartition par zone (obligatoire à partir de trois zones quand chaque nœud a son étiquette de zone, sinon une préférence ; labo 28, I2), tolérances de 30 s ; un redémarrage progressif des pods DNS), attend le rollout et relit. Idempotent ; `cluster-up` l'applique avec `APPROVE=auto` ou un « yes » tapé, sinon ÉCHOUE en nommant la commande ; `coredns_ha = false` l'ignore. À la main : `kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json` (forme à 3 nœuds). Le lab 27 a passé ce patch à la main (rollout 6 s, 3 réplicas sur 3 workers, 31 résolutions à 1 Hz, 0 échec) ; l'étape dans `cluster-up` n'est testée que hors ligne (UNVERIFIED sur un cluster). Le Corefile, l'étiquette d'image et les requests de ce Deployment restent ceux de Talos (`docs/resilience.md`).
   Tout le reste que les manifestes inline de la 0.4.0 définissent de nouveau est créé ou couvert : le budget CoreDNS et les étiquettes `topology.kubernetes.io/zone` des nœuds (les deux sont apparus, lab 26), le CRD ServiceAccount Talos
   (intégré à Talos, apparu), les nouvelles clés de `cluster-identity` (étape 6) et la ref des apps (étape 5). Le manifeste Flux n'a pas changé entre la 0.3.2 et la 0.4.0 ; celui de Cilium a changé en UN endroit, l'opérateur (**2 réplicas, un budget d'une interruption et une préférence de zone ; il tournait en 1**, audit du chemin critique du 2026-10-28). L'image Cilium est la même, et le manifeste suit la règle de CoreDNS : Talos crée le nouveau budget mais ne réécrit jamais le Deployment `kube-system/cilium-operator` existant, donc `cluster-verify` dit BAD (« the Cilium operator has 1 replica(s), the manifest declares 2 ») tant qu'il n'est pas corrigé. La correction est la même étape de convergence que CoreDNS, dans `cluster-up` avant sa vérification : `task cluster-coredns-ha PROVIDER=… ROLE=…` (essai à blanc) / `… APPLY=1` met aussi l'opérateur à min(2, nœuds) réplicas avec `scripts/ops/cilium-operator-ha-patch.json` (les pods de l'opérateur redémarrent un par un ; le chemin des données n'en dépend pas). Les agents ne sont pas touchés, aucun nœud ne redémarre. PAS VÉRIFIÉ sur un cluster : le déploiement du second pod de l'opérateur et l'apparition du budget.
   **Un nouveau défaut dans ce passage : `node_monitor_grace_period_seconds` vaut 30 (il valait 0, les 50 s de Kubernetes).** Un cluster existant le rencontre à son prochain `cluster-up`, dans la même exécution, comme partie du passage et non comme étape séparée : le plan montre les configurations machine des plans de contrôle ET des workers « à changer » (`--node-monitor-grace-period=30s` du controller manager sur les plans de contrôle ; sur chaque nœud `nodeLeaseDurationSeconds: 30` et `nodeStatusUpdateFrequency: 7s` du kubelet). C'est une application de configuration machine, sans redémarrage ; le lab 27 a observé environ 7,5 minutes par application (les kubelets redémarrent, le controller manager des plans de contrôle redémarre un pod à la fois). Pour garder les 50 s de Kubernetes, mettre `node_monitor_grace_period_seconds = 0` dans le tfvars AVANT ce `cluster-up`. Pourquoi 30, et la preuve (UN fournisseur, Scaleway, lab 27) : `docs/resilience.md`, « Pourquoi le défaut est 30 s ». **NON VÉRIFIÉ :** la même application chez OVH et Outscale, et une soak à 30 s pendant un roll.
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

   **Le redémarrage du primaire (lab 27, FI) : 206 s, pas 17-22 s.** Le lab réduit n'avait pas de pool de clients. Sur la plateforme, pool Zitadel connecté, l'opérateur a redémarré le primaire de zitadel-db sur place pour le sidecar du plugin (`primaryUpdateMethod: switchover` ne s'applique pas à ce redémarrage) ; le gestionnaire d'instance a demandé un arrêt « smart » avec `smartShutdownTimeout` 180 et PostgreSQL y est resté 180 s (sessions ouvertes), puis arrêt rapide : écritures indisponibles **206,4 s**. Sémantique CloudNativePG (https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/docs/src/instance_manager.md) : CHECKPOINT puis arrêt smart « jusqu'à `.spec.smartShutdownTimeout` secondes » (180 par défaut), puis arrêt rapide dans `.spec.stopDelay` (1800) ; 0 va droit à l'arrêt rapide. La valeur est lue dans l'objet Cluster en cache du gestionnaire d'instance à l'arrêt, pas dans la spec du pod : la changer ne demande aucun redémarrage. **Changement :** chaque Cluster de la plateforme déclare `smartShutdownTimeout: 5` depuis un composant Kustomize partagé du dépôt apps, et `cnpg-presync` pose la même valeur AVANT le déplacement. **Mesuré (lab 27, séance 2, 2026-10-26, Scaleway, pool Zitadel connecté : 2 pods zitadel et 2 pods login) : 33,6 s, pas 12-25 s** (dernière écriture acquittée 09:42:48, suivante 09:43:22 ; première mesure du redémarrage borné, une exécution). Décomposition d'après les événements : le pod est tué à 09:42:47 et le nouveau est planifié 12 s plus tard (arrêt smart plafonné à 5 s plus le checkpoint), l'image du sidecar Barman est tirée à froid sur ce nœud en 6 s (une fois par nœud : un redémarrage ultérieur sur le même nœud ne la paie pas), PostgreSQL démarre à 09:43:09 et la première validation passe à 09:43:22. Compter **environ 35 s avec un pool connecté, dont 6 s de premier tirage d'image** : c'est un redémarrage planifié du primaire sur place, pas une bascule, et il dépasse de 3,6 s la classe des 30 s d'une bascule planifiée (17-22 s dans le lab sans clients, 20-22 s pour les bascules planifiées d'un drain de worker dans la même séance) ; ne citez plus 12-25 s. **Séance 3 (2026-10-26, même Cluster et même pool, une exécution, dans l'unique `cluster-up` du passage) : 26,3 s** (séance 1 : 206,4 s, séance 2 : 33,6 s) ; **lab 28B (2026-10-30, Scaleway, une exécution, dans le passage) : 31,4 s.** **La cible pour ce redémarrage est de 35 s** (décision du propriétaire, 2026-10-31 ; elle était de 30 s), les chiffres ci-dessus étant 26,3, 31,4 et 33,6 s avec `smartShutdownTimeout` déjà à 5 s ; les 30 s restent l'objectif de conception. Pré-tirer l'image du sidecar sur chaque worker économiserait ces 6 s (non fait, non mesuré). Coût : un redémarrage ou arrêt planifié du primaire déconnecte les clients après 5 s au lieu de les attendre jusqu'à 180 s ; une transaction en cours est annulée (le travail validé n'est pas perdu).
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

**Mesuré, labo 27 séance 3 (2026-10-26, Scaleway seul, 3 CP + 5 W, Talos v1.14.2 vers v1.14.4, têtes infra et apps des branches 0.4.0 ; une exécution, NON VÉRIFIÉ chez OVH et Outscale).** Le passage depuis les tags 0.3.2 s'est fait en **UNE seule invocation**, `task cluster-up PROVIDER=scaleway ROLE=management APPROVE=auto`, avec seulement `talos_version` et `git_ref` changés dans les tfvars : **rc 0 en 39 min 13 s, rien à la main, pas de seconde invocation** (la séance 2 en demandait deux, 31 min + 17 min ; la séance 1 s'était terminée en rc 201). Le roulement des 8 nœuds a pris environ 35 minutes ; la pré-synchronisation a été appliquée et la référence apps modifiée **71 s plus tard** (séance 2 : 80 s), Flux n'a pas annulé (lu toutes les 3 s), les clés d'identité ont été écrites, « CoreDNS converged : 3 replica(s), hard spread » s'est exécuté dans la commande, et son `cluster-verify` a réussi (une exécution séparée ensuite : 26 réussis, 0 échec, 0 non contrôlable). Les 40 Kustomizations étaient Ready **6 min 43 s** après le changement de référence (séance 2 : 11 min 7 s ; séance 1 : 13 min 25 s). La période de grâce par défaut de 30 s a été portée (option sur 3 contrôleurs sur 3, Leases à 30 s, fréquence d'état du kubelet 7 s). **Zéro commit acquitté perdu : 113 975 acquittés par l'écrivain zitadel-db pendant le roulement, 0 manquant**, l'archive WAL continue dans les deux stores (MISSING 0). Le redémarrage du primaire pour le sidecar, avec le pool Zitadel connecté, a donné un trou d'écriture de **26,3 s** (séance 2 : 33,6 s ; séance 1 : 206,4 s avant la borne). Pendant les 35 min du roulement, sondes depuis l'hôte du labo : HTTP 23 échecs sur 2102 (plus longue série 1 s), API 12 échecs (plus longue 3 s). Sur une installation neuve, le premier `cluster-up` s'est terminé en rc 201 sur l'erreur connue du fournisseur Scaleway sur l'ACL du load balancer (« inconsistent final plan », expliquée par le script) et la même commande relancée a fini en rc 0. Les opérations sur les nœuds de la même séance sont dans [`resilience.fr.md`](resilience.fr.md) : ajout de 4 à 5 en 10 min 51 s et 10 min 16 s, réduction de 5 à 4 en 6 min 56 s à 8 min 15 s (la garde a refusé tant que les volumes locaux au nœud n'étaient pas évacués, voir « Retirer des nœuds »), remplacement d'un worker mort 378 s ; `--even-if-running` demande `--ip=` pour un worker aussi.

**Si `cluster-up` s'arrête aux tunnels Talos sur « Address already in use », l'apply infra est déjà fait : relancer la MÊME commande (labo 28B, 2026-10-30, Scaleway, 3 CP + 5 W ; UNE occurrence, donc le passage depuis la 0.3.2 a pris DEUX invocations).** *Ce qu'on voit :* quelques minutes après le début, après l'apply infra, le journal dit `7/8 tunnels up` et `bind [127.0.0.1]:52100: Address already in use` (le port change avec `TALOS_TUNNEL_OFFSET`), et l'exécution se termine en rc 201. *Ce qui est déjà fait :* l'apply infra est TERMINÉ (« Apply complete! 10 added, 5 changed, 10 destroyed » : les configurations machine appliquées sur place, les étiquettes de zone sur les nœuds) ; aucun nœud n'a été roulé, la pré-synchronisation CNPG n'a pas tourné, la référence apps n'a pas bougé. *Quoi faire :* relancer la même commande `task cluster-up`, sans rien changer. La relancer est sans danger et elle reprend : l'étape de convergence saute les nœuds déjà à la version cible (« nodes already on the target version are skipped ») et l'exécution continue avec le roulement, la pré-synchronisation, le changement de référence, les clés d'identité, la convergence de CoreDNS et son propre `cluster-verify`. *Mesuré (3 CP + 5 W) :* la première invocation s'est terminée en rc 201 après **3 min 13 s** ; la même commande relancée s'est terminée **en rc 0 en 37 min 41 s** (41 min 56 s depuis le premier lancement), rien à la main, avec `cluster-verify` à l'intérieur à 27 réussis, 0 échec, 0 non contrôlable, et 97 072 commits acquittés de zitadel-db, 0 manquant. Le labo a étiqueté l'ensemble du passage INCIDENT pour la collision de tunnel, et le reste NOMINAL. *Cause :* les ports locaux des tunnels Talos (un bloc à partir de 50000, décalé par `TALOS_TUNNEL_OFFSET`) sont dans la plage que Linux donne aux connexions sortantes (32768 à 60999 par défaut) : un poste chargé peut en occuper un au moment où le tunnel s'ouvre ; au labo, c'était le port source des propres sondes à 1 Hz de l'hôte du labo, rien n'écoutait dessus, et le cluster n'était pas en cause. **Corrigé en 0.4.1 (infra #422), NON VÉRIFIÉ sur un cluster :** `talos-tunnels.sh` relance maintenant, seul, un tunnel dont le ssh est mort sur exactement « Address already in use » sans rien qui écoute (jusqu'à 3 fois, 4 s d'écart : `OA_TUNNEL_BIND_RETRIES`, `OA_TUNNEL_BIND_PAUSE`), donc le passage devrait se terminer en rc 0 en une seule invocation ; tout autre échec est rapporté tout de suite, comme avant. Prouvé en simulé seulement, avec un processus qui tient le port comme port source de sa propre connexion (`test-talos-tunnels.sh`), pas encore face aux vraies sondes d'un poste chargé. Si le port reste occupé après les essais, le script le dit et nomme la sortie : réserver le bloc des tunnels (lire d'abord `/proc/sys/net/ipv4/ip_local_reserved_ports` et mettre le bloc après ce qui y figure, car `sudo sysctl -w net.ipv4.ip_local_reserved_ports=...` REMPLACE toute la liste ; le script affiche la commande avec la liste actuelle devant, ou, s'il ne peut pas lire cette liste, le dit et n'affiche que les étapes lire puis ajouter, jamais une commande qui remplacerait la liste par le seul bloc ; le réglage est perdu au redémarrage, donc pour le garder écrire la même valeur dans `/etc/sysctl.d/`, dans le fichier qui règle déjà `ip_local_reserved_ports` s'il y en a un (`grep -rs ip_local_reserved_ports /etc/sysctl.conf /etc/sysctl.d`), car quand deux fichiers le règlent, celui lu en dernier l'emporte au démarrage et fait perdre le bloc), ou utiliser un autre `TALOS_TUNNEL_OFFSET`. Sur une copie 0.4.0, la note ci-dessus s'applique inchangée. Décision du propriétaire du 2026-10-31 (option A) : le passage 0.3.2 vers la tête prouvé en DEUX invocations est accepté pour la 0.4.0 ; la preuve en UNE invocation reste celle du labo 27 séance 3 ci-dessus. Cette note ne couvre que la collision de tunnel : pour tout autre arrêt de `cluster-up`, lire son message avant de le relancer. Pas une déclaration de conformité.

## De la 0.4.0 à la 0.4.1 (un cluster existant)

Palier : **DEUX passages sur Scaleway** (labos de preuve, 3 plans de contrôle + 6 workers, NOMINAL sauf un port de tunnel tenu exprès), chacun depuis les tags 0.4.0 en UN seul `task cluster-up` : le premier vers infra 255e08f et apps 75b546d, le second, **aux têtes du troisième labo de preuve, vers infra 67be1e8 et apps d028aed** (la version est ces têtes plus des commits de documentation seule, avec les exceptions listées dans la ligne « The proof covers » de `CHANGELOG.md`). Dans les deux, Flux suivait la BRANCHE apps, pas le tag 0.4.1 : **le passage depuis `refs/tags/0.4.1`, celui que vous exécuterez, n'a pas été montré** (le tag n'existe pas avant la version ; infra l'épingle alors). Le second passage a appliqué ce que le premier ne pouvait pas montrer : la politique Istio DENY de la Gateway partagée pour `/metrics` et `/debug/metrics` et le test de restauration dump-load modifié ont tous deux été lus sur le cluster mis à niveau (ci-dessous). Toujours pas vus sur un cluster mis à niveau : la nouvelle alerte `CnpgWalNeverArchived` (rien ne l'a provoquée) et le nouveau message de `backup-verify` (il ne s'affiche que lorsqu'un contrôle échoue, et aucun n'a échoué). Non exécuté sur OVH ni Outscale. Pas une revendication de conformité.

**Chemin supporté (décision du propriétaire, 2026-10-24) : la mineure précédente seulement.** De 0.4.0 à 0.4.1 ; depuis 0.3.x, passer d'abord par 0.4.0 (« De la 0.3.x à la 0.4.0 », plus haut).

1. Extraire le tag 0.4.1 de ce dépôt. Dans le tfvars, mettre `git_ref = "refs/tags/0.4.1"` (les exemples le portent ; un tfvars qui laisse `git_ref` non défini hérite du nouveau défaut). OpenAether-apps `refs/tags/0.4.1` doit exister. Laisser en l'état les pins Talos et Kubernetes : leurs défauts sont les mêmes en 0.4.0 et 0.4.1 (v1.14.4 et v1.37.1), donc le passage ne redémarre aucun nœud.
2. `task cluster-up PROVIDER=… ROLE=…`, plan lu. S'attendre à `0 to add, 3 to change, 0 to destroy` : les configurations machine des trois plans de contrôle, en place, parce que le manifeste `flux-bootstrap` porte `git_ref`. L'exécution déplace elle-même la référence apps (le GitRepository et la Kustomization sont relus, comme à l'étape 5 de « De la 0.3.x à la 0.4.0 ») et se termine par son propre `cluster-verify`. Si elle s'arrête aux tunnels Talos sur un port occupé, elle le retente maintenant trois fois, à 4 s d'intervalle (`OA_TUNNEL_BIND_RETRIES`, `OA_TUNNEL_BIND_PAUSE`) ; si elle s'arrête quand même, relancer la même commande.
3. `task cluster-verify` de nouveau une fois Flux convergé : il a plus de lignes qu'en 0.4.0 (un Cluster CNPG de profil dont `ContinuousArchiving` n'est pas True est rouge à partir de 300 s d'âge ; le ConfigMap `cluster-identity` est comparé à la carte rendue), et `kubectl get kustomizations -A` doit tout montrer Ready.

**Mesuré aux têtes éprouvées au labo (un troisième labo de preuve : infra 67be1e8, apps d028aed, Scaleway, 3 plans de contrôle + 6 workers, une exécution ; NOMINAL sauf que le port local du premier tunnel Talos a été tenu par un autre processus pendant 7,2 s exprès).** Un `PLAN_ONLY=1` est passé d'abord : rc 0 en 1 min 41 s, `0 to add, 3 to change, 0 to destroy`, les 10 serveurs, 9 images, 12 instantanés et les buckets d'état identiques avant et après, sauf 3 objets Loki écrits par le cluster en marche. Puis `cluster-up` s'est terminé en rc 0 en 6 min 41 s en UNE invocation : `:52000 could not be bound … retry 1/3 in 4s`, puis 9 tunnels sur 9 ouverts (la même collision en 0.4.0 finissait en rc 201 et demandait une seconde exécution). Il a appliqué `0 to add, 3 to change, 0 to destroy` (les configurations machine des trois plans de contrôle, en place). Aucun nœud redémarré (les identifiants de démarrage des 9 nœuds et le total des redémarrages, 10, sont identiques avant et après). 41 Kustomizations sur 41 étaient Ready sur la nouvelle révision 4 min 10 s après le changement de référence, 2 min 43 s après le rc 0. Sondes à 1 Hz depuis quatre points de vue pendant le passage : HTTP et API depuis l'hôte du labo 0 échec sur 560 chacune, dans le cluster 0 sur 1 102 chacune. Quatre écrivains (la base de la plateforme, une base `ha` en direct et par son pooler, une base `light`) : 109 173 commits acquittés, leurs identifiants enregistrés hors du cluster, 0 manquant. `cluster-verify`, dans l'exécution puis de nouveau après : 31 réussis, 0 échec.

**Le premier passage, pour comparaison (infra 255e08f et apps 75b546d, même forme, NOMINAL).** 7 min 6 s ; 41 sur 41 Ready 3 min 49 s après le changement de référence et 2 min 17 s après le rc 0 ; sondes 0 échec sur 559, 559, 1 092 et 1 093 ; 37 177 commits acquittés, 0 manquant ; `cluster-verify` 31 réussis, 0 échec. **Selon la règle de `CHANGELOG.md` (PIRE : au moins 10 s et au moins 10 % plus lent ; un chiffre à moins de 6 s environ d'une limite est « à la limite » ; un échantillon chacun) :** le passage, 6 min 41 s contre 7 min 6 s, est IDENTIQUE (−25 s, −6 %) ; 41 sur 41 Ready après le changement de référence, 4 min 10 s contre 3 min 49 s (+21 s, +9 %), est à la limite, résolution d'environ 6 s (2 s sous la limite du PIRE), sans étiquette ferme ; **41 sur 41 Ready après le rc 0, 2 min 43 s contre 2 min 17 s, est PIRE (+26 s, +19 %)**, cause non isolée : ce passage porte plus de changements (apps 42 commits et 35 fichiers contre 7 et 11, infra 74 commits et 78 fichiers contre 51 et 52) et l'on n'a pas mesuré quelles Kustomizations ont pris le temps en plus ; **`PLAN_ONLY=1`, 1 min 41 s contre 1 min 31 s (+10 s, +11 %), est à la limite, résolution d'environ 6 s**, sans étiquette ferme (PIRE si l'on prend les chiffres tels que mesurés), et le plan précédent n'était pas comparable (son étape d'ajout aurait créé des machines). Les sondes (0 échec dans les deux) et les écrivains (0 manquant dans les deux) sont IDENTIQUES.

**Ce que le cluster mis à niveau a montré (même exécution et même forme, durées NOMINAL).**

- La Gateway partagée refuse `/metrics` et `/debug/metrics` : 216 sondes (27 graphies, 4 hôtes, HTTPS et port 80) ont donné 112 × 403 et 0 corps Prometheus, contre 10 corps sur le cluster 0.4.0 (`/metrics` de Grafana 7, `/debug/metrics` de Zitadel 3, sans connexion), tous lus depuis l'hôte du labo à travers un load balancer applicatif dont l'ACL n'admettait que cet hôte. Les corps ont duré jusqu'à ce que Flux applique la politique : 2 min 38 s après le changement de référence, 71 s après la fin de `cluster-up`. Les chemins normaux ont répondu les mêmes codes, et vmagent collectait toujours Grafana et Zitadel (`up` valait 1 sur 4 séries, lu avant, juste après le passage et à la fin).
- La politique s'est appliquée sans erreur et avec un avertissement d'admission Istio : `will deny all traffic to TCP ports under its scope due to the use of only HTTP attributes in a DENY rule`. Sans conséquence aujourd'hui : la Gateway du dépôt apps ne déclare que les écouteurs HTTP 80 et HTTPS 443 (lu dans le fichier ; les écouteurs en service n'ont pas été archivés). Le DENY ne nomme aucun port : un écouteur TCP ou TLS ajouté plus tard à cette Gateway serait refusé sans message.
- Le test de restauration dump-load a ÉCHOUÉ quatre fois sur le cluster 0.4.0 avant son premier dump (`repository does not exist`), et `RestoreTestFailed` est passée en attente sur quatre séries (pas encore active : elle le devient après son `for: 10m`, et on l'a vue active pour la première fois 17 s après le rc 0 du passage, une borne haute puisque l'alerte était interrogée, non surveillée). Après le passage il a SAUTÉ quatre fois (18 s) avant le premier dump, et `RestoreTestFailed` s'est éteinte 5 min 20 s à 5 min 35 s après cette première exécution (vmalert évalue toutes les 5 minutes). Après un `cnpg-dump` (18 s) le test a RÉUSSI quatre fois (19 s) et `backup-verify` a réussi deux fois. Au labo le Job du test a été lancé à la main depuis son CronJob ; un cluster mis à niveau qui portait l'échec devrait garder l'alerte jusqu'à la prochaine exécution du test (non exécuté ainsi).
- `cluster-security` : 31 sur 36 avec le test 1.6 en échec à la première exécution, 32 sur 36 à la seconde (comme dans les labos précédents). L'échec était le test instable corrigé dans cette version, pas le cluster (`CHANGELOG.md`, Fixed).
- L'ExternalSecret `grafana-oidc` est resté en `SecretSyncedError` pendant tout le labo, avant et après le passage (le cas connu : il lit `grafana/oidc`, que seule une étape de console met dans OpenBao), et la redirection de connexion de Grafana portait un `client_id` vide. La connexion de bout en bout n'a pas été exécutée.

**Non montré :** le passage depuis le tag ; un exercice de bascule ou de perte de zone pendant un passage (donc « pas de split brain » est vrai là, puisqu'aucune bascule n'a eu lieu, et non testé) ; la connexion Grafana vers Zitadel ; la règle `/metrics` sur la forge (non déployée) ; OVH et Outscale ; un temps d'installation NOMINAL en 0.4.0 dans le troisième labo. Une exécution par chiffre, un amorçage OpenBao de développement, un fournisseur, une forme.

**Ce qu'un opérateur rencontre de nouveau en 0.4.1** (chaque entrée de `CHANGELOG.md` `[0.4.1]` a son palier) : `cluster-roll` et `cluster-replace-node` refusent de remplacer l'unique copie d'une base à instance unique sans `--accept-sole-copy=<namespace>/<name>`, et une exécution non interactive s'arrête tant qu'il n'est pas donné ; un pod nu est refusé avant le drain ; le drain de `cluster-roll`, `cluster-upgrade` et `cluster-shrink` est surveillé et refusé après 120 s sans progrès derrière un budget qui n'admet rien (`DRAIN_STALL_AFTER`, `DRAIN_STALL_POLL` ; 0 rétablit le drain simple) ; `cluster-replace-node` lit chaque membre etcd survivant jusqu'à trois fois (`ETCD_READ_TRIES`, `ETCD_READ_PAUSE`) ; `task cluster-up … PLAN_ONLY=1` lit le plan sans rien créer ; et la chaîne de reprise après sinistre a de nouveaux réglages : `OA_DR_STABLE_ROUNDS` (5), `OA_DR_STABLE_TRIES` (60), `OA_DR_STANDBY_TRIES` (18) et `OA_DR_ES_OPTIONAL` (voir « Où la chaîne de reprise peut s'arrêter » dans `disaster-recovery.fr.md`) ; son étape `openbao` dure maintenant environ cinq minutes, et non vingt secondes. **À partir d'OpenAether-apps 0.4.1 (appliqué par le passage ci-dessus, au changement de référence) :** une route à vous qui sert `/metrics` ou `/debug/metrics` reçoit maintenant un 403 de la Gateway partagée et aucune politique ALLOW ne le contourne ; la servir sous un autre chemin, ou retirer la politique par un patch Flux. Le CHANGELOG d'apps (`[0.4.1]`, Security) et `OpenAether-apps/docs/public-exposure.md` portent la note, la sortie et ses limites.

## De la 0.4.1 à la 0.4.2 (un cluster existant)

Palier : **par lecture, plus le retest cloud écrit dans `CHANGELOG.md` `[0.4.2]`**, l'unique endroit de ses chiffres et de leurs étiquettes NOMINAL ou INCIDENT (cette section n'en porte aucun : le lire là avant de se fier à celle-ci). La 0.4.2 est la 0.4.1 plus un correctif de CI, et OpenAether-apps 0.4.2 ne diffère d'apps 0.4.1 que par la CI, la documentation et un fichier de données VEX (`.vex/openaether-apps.openvex.json`, que Trivy et le contrôle de la CI lisent et qu'aucun cluster ne lit). **Le passage depuis `refs/tags/0.4.2` lui-même, celui que vous lancerez, n'est pas montré** : le tag n'existe pas avant la release (infra l'épingle alors), et le retest prévu dans `CHANGELOG.md` fait passer un cluster 0.4.1 aux têtes 0.4.2, donc il suit les branches, comme celui de la 0.4.1, et non le tag. Pas une revendication de conformité.

**Chemin supporté (décision du propriétaire, 2026-10-24) : la version précédente seulement.** De 0.4.1 à 0.4.2 ; depuis 0.4.0, passer d'abord par 0.4.1 (« De la 0.4.0 à la 0.4.1 », plus haut).

**Seule la référence apps bouge, et rien ne se lance à la main au-delà de `task cluster-up`, qui déplace lui-même la référence apps (l'étape que `task cluster-apps-ref` lance seule)** : « De la 0.4.0 à la 0.4.1 » a la mécanique (ses étapes 1 à 3 : le plan à lire, la nouvelle tentative des tunnels, les contrôles), avec les numéros décalés d'un cran. En bref : extraire le tag 0.4.2 ; mettre `git_ref = "refs/tags/0.4.2"` dans le tfvars (les exemples le portent ; un tfvars qui laisse `git_ref` non défini hérite du nouveau défaut, le seul comportement qui a changé), OpenAether-apps `refs/tags/0.4.2` existant ; `task cluster-up PROVIDER=… ROLE=…` plan lu, puis `task cluster-verify`. Les pins Talos et Kubernetes sont les mêmes en 0.4.1 et 0.4.2, donc aucun nœud ne redémarre ; le plan devrait montrer le même genre de changement qu'en 0.4.1 (les configurations machine des plans de contrôle, en place, parce que le manifeste `flux-bootstrap` porte `git_ref`, et rien à ajouter ni à détruire), par lecture, non mesuré pour ce passage.

## De la 0.4.2 à la 0.4.3 (un cluster existant)

Palier : **par lecture et tests mockés, NON VÉRIFIÉ sur un cluster jusqu'au labo de preuve de la 0.4.3** ; ses chiffres et leurs étiquettes NOMINAL ou INCIDENT vont dans `CHANGELOG.md` `[0.4.3]`, l'unique endroit pour eux. **Ce passage demande deux commandes, pas une** : la 0.4.3 est la première version, depuis que `cluster-bootstrap-sync` existe (0.4.0), dont les contrôleurs Flux diffèrent de ceux de la précédente (les 0.2.0 à 0.4.2 épinglent toutes Flux 2.9.6 ; la 0.4.3 épingle la 2.10.0, parce que l'image `kustomize-controller` de la 2.9.6 porte `brotli-libs` 1.2.0, faille critique CVE-2026-111497, et que le correctif n'existe que dans la 2.10, pas dans un correctif 2.9), et `cluster-up` ne touche jamais aux contrôleurs Flux d'un cluster en marche (« Cilium et Flux sur un cluster en marche », plus bas). **Le premier passage réel de `cluster-bootstrap-sync` est ce passage-ci.** Le passage depuis `refs/tags/0.4.3` lui-même n'est pas montré : le tag n'existe pas avant la release. Pas une revendication de conformité.

**Chemin supporté : la version précédente seulement.** De 0.4.2 à 0.4.3 ; depuis 0.4.1, passer d'abord par 0.4.2.

1. Extraire le tag 0.4.3 de ce dépôt. Mettre `git_ref = "refs/tags/0.4.3"` dans le tfvars (comme « De la 0.4.0 à la 0.4.1 », étape 1 ; OpenAether-apps `refs/tags/0.4.3` doit exister). Les pins Talos et Kubernetes sont les mêmes qu'en 0.4.2 (v1.14.4, v1.37.1) : aucun nœud ne redémarre.
2. **Flux d'abord, seul :** `task cluster-bootstrap-sync PROVIDER=… ROLE=…` (essai à blanc, code 3 : sept contrôleurs en retard d'un mineur, chaque ligne « pinned … running … »), puis la même commande avec `APPLY=1`. De la 2.9 à la 2.10 est un seul mineur, que le script accepte ; il refuse tant qu'un nœud n'est pas Ready. Il attend les sept déploiements et relit les tags. Ensuite `task cluster-verify` doit afficher « Flux controllers run the pinned version ». Le faire avant `cluster-up` garde chaque changement lisible seul, et `cluster-up` se termine par son propre `cluster-verify`, rouge sur cette ligne tant que les contrôleurs tournent encore en 2.9.6.
3. `task cluster-up PROVIDER=… ROLE=…`, plan lu, comme en 0.4.2 (les configurations machine des plans de contrôle, en place, `0 to add, 3 to change, 0 to destroy` ; les configurations portent maintenant aussi le nouveau manifeste inline `flux-install.yaml` ; Talos ne met pas à jour un objet qui existe, donc il ne devrait changer aucun objet Flux ni redémarrer aucun nœud, par lecture, non mesuré), puis `task cluster-verify` une fois Flux convergé.

**Si `task cluster-bootstrap-sync … APPLY=1` s'arrête en route** (lu dans `scripts/ops/cluster-bootstrap-sync.sh`, non joué : c'est son premier usage réel). Le code 2 est un refus avant toute écriture : rien n'a changé, et la ligne nomme la raison (un nœud pas Ready, un retour en arrière, plus d'un mineur). Le code 1 avec « apply refused » signifie que l'application côté serveur s'est arrêtée sur un objet. Ce n'est pas une transaction : ce qui a été appliqué avant reste appliqué, **les CRD Flux comprises (remplacées, non annulées : « Cilium et Flux sur un cluster en marche », plus bas)**. Le code 1 qui nomme un Deployment signifie que l'application est passée et que ce Deployment n'a pas fini son déploiement dans `OA_ROLLOUT_TIMEOUT` (300 s). Dans les deux cas, lire d'abord : `kubectl -n flux-system get deployments,pods`, `kubectl -n flux-system describe deployment <nom>` avec les événements de son pod et le journal du contrôleur, et `kubectl get crd | grep fluxcd`. Relancer la même commande est sans danger (l'application côté serveur est idempotente), avec un piège : **elle compare les tags d'image des spécifications des Deployments, pas les pods ; après un dépassement de délai de déploiement, la relance trouve donc les tags épinglés, affiche « run exactly the pinned versions » et sort en 0 sans attendre aucun déploiement.** Lancer soi-même `kubectl -n flux-system rollout status deployment/<nom>`, puis `task cluster-verify`. Il n'y a pas de retour arrière sur place : le script refuse un retour en arrière de version et rien ici ne remet les CRD. La sortie que ce dépôt documente pour un état que l'on ne sait pas réparer est la reconstruction à côté (« Cilium et Flux sur un cluster en marche », plus bas) ; un retour arrière de Flux n'a aucun test. Des contrôleurs à l'arrêt suspendent la réconciliation, pas les charges qu'ils ont déjà appliquées (par lecture, non exercé).

**Flux 2.10 face à cette plateforme (les notes de version et les journaux de changements des contrôleurs, lus ; les deux dépôts parcourus pour chaque point, non joué) :**

- *L'identité d'objet est toujours active, et le RBAC par défaut n'accorde plus `create` sur `serviceaccounts/token`.* Rien ici ne s'en sert : aucun objet Flux d'OpenAether-infra ni d'OpenAether-apps 0.4.2 ne définit `spec.serviceAccountName` ni `kubeConfig.configMapRef` (les objets `edge-*` utilisent `kubeConfig.secretRef`, un kubeconfig statique, que ceci ne touche pas), et aucune porte `ObjectLevelWorkloadIdentity` n'est posée. **Si votre propre surcouche authentifie un objet Flux avec un jeton de ServiceAccount, liez le ClusterRole de https://github.com/fluxcd/flux2/pull/6139 au contrôleur avant la synchronisation.**
- *`Alert` et `Provider` passent en `v1` (la version de stockage) ; `v1beta3` reste servie et dépréciée.* Le `Provider` `alertmanager` et l'`Alert` `flux-errors` de la plateforme (apps `base/flux/notification-alertmanager.yaml`) sont en `v1beta3`, n'utilisent aucun champ que `v1` retire, et sont valides contre le schéma 2.10 dans les deux versions ; attendre un avertissement de dépréciation, pas une erreur. Une `Alert` à vous avec `spec.summary`, ou un `Provider` avec `spec.interval`, un jeton statique Azure Event Hub ou des réglages TLS ou proxy dans `spec.secretRef`, les perd à la conversion (utiliser `eventMetadata.summary`, `proxySecretRef`, `certSecretRef`). Les deux objets de la plateforme restent en `v1beta3`, dépréciée, dans la 0.4.3 : les passer en `v1` est un changement d'OpenAether-apps pour une version ultérieure, parce qu'OpenAether-apps 0.4.3 doit encore s'appliquer sur un cluster en 2.9.6 jusqu'à la synchronisation, où `v1` n'existe pas.
- *Les tags d'`ImageRepository` passent au stockage Flux.* Aucun `ImageRepository`, `ImagePolicy` ni `ImageUpdateAutomation` n'existe sur cette plateforme (les deux contrôleurs d'images tournent sans rien à faire), donc le nouveau balayage que mentionnent les notes n'a rien à balayer.
- *Kubernetes :* la 2.10 demande 1.37.0 ou plus sur la ligne 1.37 ; le pin est v1.37.1.
- *Les autres changements d'`install.yaml`*, lus dans la différence avec la 2.9.6 : les sept images, la sonde de disponibilité de `source-controller` et `source-watcher` (`/readyz` sur le port `healthz` existant), un port `https` 443 sur quatre Services (aucun nouveau port de conteneur, donc aucune politique à changer), et la permission SubjectAccessReview à la place de celle des jetons. Le mTLS SPIFFE entre contrôleurs est éteint tant qu'il n'est pas configuré.
- *Lu et non prouvé, 1 : la vérification de signature Git.* `source-controller` 1.10.0 relance la vérification de signature d'un `GitRepository` quand les clés de confiance changent (son journal de changements), et la CRD gagne `status.sourceVerificationFingerprint`, l'empreinte des clés qui ont vérifié l'artefact courant. Cela touche l'option `flux_git_verify` (`spec.verify` avec `mode: HEAD` sur le GitRepository `openaether`, `docs/signed-commits.fr.md`), éteinte par défaut et éteinte dans les labos : rien ici ne l'a jouée. Si vous la tenez allumée, attendez-vous à ce que le HEAD courant soit vérifié de nouveau à la première réconciliation après le démarrage du nouveau contrôleur (déduit de la description du champ), et lisez `SourceVerified` sur le GitRepository après la synchronisation.
- *Lu et non prouvé, 2 : HelmRelease.* `helm-controller` 1.7.0 fait passer la bibliothèque Helm de 4.2.4 à 4.3.1, et la 1.7.1 change la comparaison d'un changement de `.spec.postRenderers` : les empreintes sont comparées à chaque réconciliation et la mise à niveau est retentée, là où une mise à niveau échouée était annoncée Ready. Les HelmReleases MinIO, Zitadel et Forgejo d'OpenAether-apps utilisent `postRenderers`. Une release qui se mettrait à niveau au premier démarrage du nouveau contrôleur sans changement propre redémarrerait ses pods : non attendu, non montré. Pour le voir, lisez `status.history` et `status.lastReleaseRevision` de chaque HelmRelease avant et après la synchronisation.
- *Exposition ouverte, non couverte : la copie de Flux pour les enfants CAPI.* Les contrôleurs Flux qu'OpenAether-apps pousse vers les enfants CAPI (`cluster-api-clusters/flux-gotk`) sont une installation vendorisée à part, encore en Flux 2.9.6 à l'écriture (OpenAether-apps 0.4.2 et les têtes 0.4.3) avec la même image `kustomize-controller` v1.9.6, donc la même constatation `brotli-libs`. Ce passage n'y touche pas : un enfant qui porte cette copie garde la constatation jusqu'à ce qu'elle bouge (OpenAether-apps #103, qui nomme les contrôleurs Flux poussés vers les enfants).

## Quelle version vit où, et comment elle atteint un cluster en marche

Le modèle (infra #408, adopté le 2026-10-24) : pour chaque chose épinglée, **un pin déclaré, une commande qui y converge un cluster en marche, et un contrôle de vérification qui échoue à toute différence, dans
les deux sens** (en retard comme en avance est une différence ; une valeur illisible est UNKNOWN, jamais un succès). Échelon de tout ce qui est marqué UNVERIFIED : testé avec doublures, hors ligne, pas sur un cluster.

| Chose | Déclarée dans | Convergée par | Contrôlée par (`task cluster-verify`) | Statut |
|---|---|---|---|---|
| Talos | `talos_version` (tfvars, sinon `variables.tf`) | `task cluster-up` (`converge-versions.sh` : un nœud à la fois, refuse un retour en arrière), `task cluster-upgrade` | « every node runs the pinned Talos » (flotte MIXED nommée à part) | PROVEN sur clouds pour des versions antérieures (1.14.2 vers 1.14.4 au lab 25) ; le pin 0.4.0 UNVERIFIED |
| Kubernetes | `kubernetes_version` | idem, par la config machine (sans roll) | « every node runs the pinned Kubernetes » | PROVEN sur clouds (montées du 2026-10-03) |
| Spec de base (CNPG `synchronous`) | `spec.postgresql.synchronous` du contenu apps 0.4.0 (`any` / 1 / `required` / `failoverQuorum`), lu en direct sur chaque Cluster de la plateforme | `task cnpg-presync` (pose aussi `smartShutdownTimeout` 5 ; `cluster-up` enchaîne la ref des apps dans la même étape et passe `SCALE=1` avec `APPROVE=auto` ; `APPLY=1`, AVANT la ref des apps ; `SCALE=1` sous 3 instances) ; `cluster-up` lance son essai à blanc | par Cluster : le bloc, ContinuousArchiving, `synchronous_standby_names`, réplicas `quorum`/`sync`, objet FailoverQuorum | UNVERIFIED sur la plateforme (doublures hors ligne ; mesuré sur un lab réduit, étape 4) |
| Forme de CoreDNS | `coredns_ha`, le nombre de nœuds (`min(3, nœuds)`, répartition stricte) et les étiquettes de zone (répartition par zone, obligatoire à partir de 3) | `task cluster-coredns-ha` (`APPLY=1`) ; `cluster-up` le lance avant son verify ; seul, un patch se termine en nommant `task cluster-rebalance … APPLY=1` (les zones ont fini 2, 3, 2 au labo 28B, et le rééquilibrage l'a corrigé en 20 s) | « CoreDNS runs the declared replica count and spread » | patch PROUVÉ à la main (lab 27) ; l'étape dans `cluster-up` UNVERIFIED |
| Brique Forgejo (chemin ROLE de la Kustomization racine) | `path: ./apps/flux/${cluster_role}` du manifeste inline `flux-bootstrap` ; l'overlay est `./apps/flux/management-forge` | NON convergé : `kubectl patch` en direct seulement (ci-dessous) ; `cluster-up` ne le pose ni ne le défait | NON vérifié | LACUNE, non construite (pas de tfvar ; issue FF du lab 27) |
| Archive WAL des Clusters de profil de base (profils OpenAether-apps) | un profil avec un archiveur WAL (plugin barman-cloud, `isWALArchiver`) ; l'étiquette `openaether.io/db-profile` | aucune commande ne le converge : un Cluster créé sur un chemin d'archive qui contient encore le WAL d'un autre Cluster reste à False jusqu'au nettoyage du chemin ou à un nouveau `serverName` (`OpenAether-apps/docs/traps.md`) | « The profile CNPG Clusters: WAL archiving » (infra #430) : chaque Cluster de ce type dans TOUS les espaces de noms (pas seulement `OA_CNPG_NAMESPACES` ; copies `rt-*` exclues) dont `ContinuousArchiving` n'est pas True est BAD dès qu'il a 5 minutes, avec son âge et le message de la condition ; en dessous de 5 minutes c'est un avertissement avec le même message, car un Cluster neuf n'archive pas à la seconde 0. **Un Cluster de profil pollué de moins de 5 minutes est donc JAUNE (la commande sort à 0), et seul un contrôle lancé à partir de 5 minutes d'âge le passe au rouge : un contrôle lancé juste après la création du Cluster ne peut pas échouer dessus, relancez-le.** Une date de création illisible, ou en avance de plus de 60 s sur l'horloge de la machine qui lance le contrôle (l'horloge est inconnue, et la ligne le dit), ne donne aucun délai de grâce ; jusqu'à 60 s d'avance, c'est un écart d'horloge ordinaire, compté comme un âge de 0 et dit sur la ligne. Condition absente sur un Cluster qui déclare un archiveur : avertissement sous 5 minutes d'âge, UNKNOWN après ; un Cluster `light` (sans archiveur) n'a pas de ligne. L'alerte `CnpgWalArchiveFailing` reste à 25 minutes, par conception. Ce contrôle ne lit aucune alerte et n'en a pas besoin ; là où la version d'OpenAether-apps utilisée porte l'alerte `CnpgWalNeverArchived` (`for: 5m`, elle lit les compteurs de l'archiveur, pas la condition), elle peut partir plus tôt | UNVERIFIED (doublures ; la règle d'alerte, là où elle existe, aussi hors ligne) ; l'état du lab 28C (un Cluster sur un chemin pollué) n'a pas été relu avec ce contrôle, et on ne sait pas si un Cluster neuf sain montre False avant True |
| Ref des apps | `git_ref` | `task cluster-apps-ref` (`REF=… APPLY=1`) ; `cluster-up` lance son essai à blanc | « the GitRepository and GIT_REF both follow the declared git_ref » (seulement avec `deploy_flux = true`) | UNVERIFIED (doublures) |
| Clés `cluster-identity` | table rendue (`local.cluster_identity`, sortie `cluster_identity`) | `task cluster-identity-sync` ; `cluster-up` lance son essai à blanc | « The cluster-identity ConfigMap holds the values the config renders » (seulement avec `deploy_flux = true` ; infra #409) : une clé rendue absente ou à une autre valeur est BAD, avec les noms des clés (jamais les valeurs) et la commande de synchronisation ; une clé que la config ne rend pas n'est pas jugée, car la synchronisation la laisse en place | UNVERIFIED (doublures) |
| Cilium | `CILIUM_VERSION` dans `render-bootstrap-manifests.sh`, rendu dans `cilium.yaml`, empreinte dans `upstream-artifacts.lock` | pas de commande sur place : **reconstruction à côté** (ci-dessous) | « Cilium run the pinned version » (tags d'image de l'agent et de l'opérateur) | contrôle UNVERIFIED (doublures) ; aucune mise à niveau sur place |
| Contrôleurs Flux | `FLUX_VERSION`, `flux-install.yaml` vendorisé, même lock | `task cluster-bootstrap-sync` (`APPLY=1`) ; le passage 0.4.2 vers 0.4.3 (2.9.6 vers 2.10.0) est son premier usage réel | « Flux controllers run the pinned version » (les sept Deployments ; seulement avec `deploy_flux = true`) | UNVERIFIED (doublures ; pas encore joué sur un cluster) |
| Clusters enfants CAPI | `K8S_VERSION`, `TALOS_VERSION` dans `apps/clusters/*.yaml` (OpenAether-apps) | Flux applique le fichier ; Cluster API remplace les machines | aucun : `check-child-clusters.py` est statique ; rien ne compare les versions en marche d'un enfant | LACUNE, non construite |

`git_ref` est convergé par `task cluster-apps-ref` : l'éditer et lancer `cluster-up` seul ne déplace pas un cluster en marche. Un canal de versions (un intervalle semver sur des tags signés que Flux suit) est une
option 1.0, non construite ; aujourd'hui la version des apps est une ref exacte convergée par l'outillage.

`cluster-up` se termine en disant ce qu'il n'a PAS changé : les contrôleurs Cilium et Flux d'un cluster en marche (le nombre de réplicas de l'opérateur Cilium est la seule exception, ci-dessus), le contenu des apps au-delà de la ref, les enfants CAPI, et tout autre objet que Talos a créé
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

### Un worker qui porte un share-manager RWX attaché ne se vide pas (labo 28, I3)

Échelon : observé sur UN cluster (OVH, labo 28, 3 plans de contrôle + 6 workers, 2026-10-29 : trois essais sur le même worker, dont un par le chemin du produit) ; la cause est lue dans ce labo, la procédure ci-dessous n'a PAS été exécutée sur un cluster. Le code de la 0.4.1 (la surveillance du drain décrite à la fin de cette section) est testé hors ligne avec des simulations et a été exécuté une fois sur Scaleway avec un blocage de substitution : le blocage d'origine n'a PAS été reproduit. Pas une déclaration de conformité.

**Symptôme.** `task cluster-roll PROVIDER=… -- --node=<worker>` (et un simple `kubectl drain`) sur un worker qui porte le share-manager Longhorn d'un volume RWX attaché (dans le labo, ce worker portait aussi l'unique instance d'un cluster CNPG à instance unique, le profil `light` ; en 0.4.0 le roll ne s'arrêtait pas pour une telle instance ; depuis la 0.4.1 il demande d'abord, voir « Un remplacement de nœud détruit les données d'une base à instance unique » plus bas) : le survey est propre, puis « Cordon + drain » attend ses 900 s (`error when evicting pods/instance-manager-... in longhorn-system ... global timeout reached`) et le roll REFUSE (« could not be drained (timeout 900s) - refusing to reboot it under workloads that would not move »), **rc 201 après 1 026 s (17 minutes, INCIDENT)**. Aucun dégât : les budgets et les Kustomizations Flux sont rétablis, le nœud est ré-ouvert et non redémarré, aucun autre nœud n'a quitté Ready, 0 écrivain de base sur 6 a perdu un commit acquitté, HTTP 0 échantillon en échec sur 1 065. Le même roll sur un worker SANS ces éléments : rc 0 en 789 s (13 min 09 s, NOMINAL). `cluster-upgrade` et `cluster-shrink` utilisent le même drain ; ils n'ont pas été essayés sur un tel worker.

**Cause (telle que lue au labo).** Deux budgets qui n'admettent aucune interruption. (1) Le budget `instance-manager-*` de Longhorn pour le nœud, maintenu tant que le nœud porte un volume attaché (node-drain-policy `block-if-contains-last-replica` ; listé plus haut comme nul par construction) : le share-manager d'un volume RWX en garde un attaché, et le roll ne peut pas évincer l'instance manager. (2) Une base à instance unique a un budget de primaire `minAvailable: 1` avec 0 interruption admise, et aucun réplica vers lequel basculer : un simple `kubectl drain` l'attend indéfiniment. Le roll coupe les budgets des Clusters CNPG qu'il connaît, donc dans le labo c'est le budget de Longhorn qui a retenu le roll, mais l'instance unique n'a de toute façon nulle part où aller (son volume est local au nœud) : sa base est arrêtée tant que le nœud est hors service (913 s au labo). Le contrôle RWX de `cordon_drain` (« holds no Longhorn RWX share-manager or client ») s'exécute APRÈS le retour du drain : jusqu'à la 0.4.0, un drain qui ne revenait jamais ne l'atteignait pas ; depuis la 0.4.1 le drain est surveillé (fin de cette section).

**Avant de rouler un tel worker** (non exécuté sur un cluster ; les étapes 1, 2 et 4 sont de simples lectures et le roll déjà prouvé) :

1. Voir ce que le nœud porte :
   ```bash
   NODE=<worker>
   kubectl -n longhorn-system get pods -o wide | grep -E "share-manager|instance-manager" | grep "$NODE"
   kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,INSTANCES:.spec.instances,PRIMARY:.status.currentPrimary
   kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,NODE:.status.currentNodeID
   ```
2. Rouler d'abord les workers qui n'en portent aucun : 789 s chacun au labo, aucun commit acquitté perdu.
3. Pour le worker qui en porte un : avec un volume RWX, arrêter les charges qui montent la claim (les mettre à 0), attendre que le volume soit `detached` et qu'aucun pod `share-manager` ne soit sur le nœud, rouler, puis les remettre : leurs écrivains sont arrêtés pendant ce temps (l'interruption RWX acceptée est d'environ 100 s lors d'une panne, ici c'est un arrêt planifié). Avec une base à instance unique, annoncer son arrêt pendant le roll (913 s mesurées) ou lui donner d'abord une seconde instance (le profil `standard`).
4. Ne pas forcer : ne pas supprimer un budget ni le pod à la main pour passer l'attente (le labo l'a fait une fois, dans un exercice, et cela a coupé l'instance unique). Un roll refusé a tout rétabli : corriger la cause et relancer la même commande, les nœuds déjà faits sont ignorés.

**Depuis la 0.4.1 (infra #417 ; testé hors ligne avec des simulations, puis exécuté sur Scaleway avec un blocage de substitution, voir la fin de ce paragraphe).** Rien ne prédit quel nœud ne se videra pas : le contrôle RWX existe parce que le drain est le remède sur un nœud qui porte un share-manager et qui fonctionne, donc un refus « le nœud porte un share-manager » arrêterait des rolls qui passent aujourd'hui. Le drain est SURVEILLÉ à la place. `cordon_drain` (donc `cluster-roll`, `cluster-upgrade` et `cluster-shrink`) lance `kubectl drain` en arrière-plan et lit les pods du nœud toutes les 10 s (`DRAIN_STALL_POLL`) ; il arrête le drain, laisse jouer le chemin de refus habituel (nœud ré-ouvert, budgets et Flux rétablis, `rc 201` tel que l'affiche un simple `task`) et nomme ce qu'il a vu quand, pendant 120 s (`DRAIN_STALL_AFTER`), **les mêmes pods restent sur le nœud, aucun n'est en cours de terminaison, et un PodDisruptionBudget qui admet 0 interruption (et qui ne manque d'aucun pod) en couvre un**. Le message liste ces pods et ces budgets, ainsi que les share-managers Longhorn et les clients RWX encore sur le nœud (les volumes) : le refus est prévu après 2 à 3 minutes environ (la fenêtre de 120 s plus le démarrage du drain : un chiffre de conception, pas une mesure) au lieu de 900 s (1 026 s au labo : INCIDENT, OVH, 3 plans de contrôle + 6 workers). Un drain qui évince des pods, dont les pods se terminent (délai de grâce long), ou qui n'attend rien qu'un budget interdise, est laissé à `kubectl` et à son propre délai comme avant ; sur un nœud qui se vide, rien ne change, sinon que la fin du drain est constatée à 0,2 s près. Un signal (Ctrl+C, SIGTERM, SIGHUP) reçu pendant le drain le tue, quel que soit le script qui le lance (un `kubectl` en arrière-plan ignorerait Ctrl+C et survivrait au script ; un signal que l'appelant ignore, SIGHUP sous `nohup`, reste ignoré, comme pour un drain au premier plan), et suit le même chemin de refus : le nœud est ré-ouvert et, sans interaction, le roll s'arrête avec les budgets et Flux rétablis ; un SIGTERM envoyé au seul `cluster-roll` laissait autrefois le drain finir et l'interrompt maintenant. Un arrêt demandé avant le début du drain ne l'interrompt pas. **Exécuté sur Scaleway (un labo de preuve, 3 plans de contrôle + 6 workers, écrivains et sondes en marche).** Un worker qui portait un pod derrière un budget admettant 0 interruption (une substitution : un réplica, `minAvailable: 1`, aucun volume) a été refusé 2 min 24 s après le début du drain, rc 201, le message nommant le pod et le budget ; le nœud a été ré-ouvert au refus et les budgets et Flux rétablis 8 s plus tard, la commande entière a duré 4 min 34 s (un refus est le résultat prévu). Ctrl+C et un SIGTERM envoyé au seul script, 20 s après le début d'un drain : le nœud a été rendu, aucun `kubectl drain` n'est resté en marche, 11 s entre le signal et le tout rétabli, rc 201, le nœud jamais redémarré. Le roll d'un worker propre sous écrivains a duré 452 s, NOMINAL (790 s au labo 28B, 789 s sur OVH ; cet écart n'est pas expliqué par un changement de la 0.4.1 : le cluster avait moins de volumes, plus petits), avec 2 échantillons HTTP échoués sur 449 (deux de 1 s), 0 pour l'API, et aucun commit acquitté perdu. **Ce qui n'est PAS montré :** le blocage du labo 28 en tant que tel : avec trois réplicas Longhorn sur six workers, le share-manager et l'instance-manager ont été évincés en moins de 10 s, le drain a duré 18 s et le nœud a été remplacé (7 min 17 s, NOMINAL), donc la surveillance n'a pas été déclenchée par sa cause d'origine ; les listes de clients RWX et de volumes dans le message (aucun n'est resté) ; SIGHUP sur un vrai apiserver (simulé seulement) ; et qu'il n'existe aucun drain qui serait passé après plus de 120 s d'immobilité derrière un tel budget. Si un labo en rencontre un, relever `DRAIN_STALL_AFTER` ; `DRAIN_STALL_AFTER=0` rétablit le drain simple au premier plan. Un simple `kubectl drain` du nœud d'une base `light` reste bloqué par son budget (ci-dessus), mais `cluster-roll` coupe ce budget et ne s'arrête pas dessus : quand le roll passe, une base `light` est perdue et non bloquée, et depuis la 0.4.1 le roll demande d'abord (voir « Un remplacement de nœud détruit les données d'une base à instance unique » plus bas).

### Un pod sans contrôleur est refusé en quelques secondes, pas après le délai du drain (labo 25, D6)

Échelon : observé sur UN cluster (Scaleway, labo 25, 3 plans de contrôle + 5 workers, lors d'un roll `--cp-only`) ; le code de la 0.4.1 est testé hors ligne avec des simulations et a été exécuté une fois sur Scaleway (3 plans de contrôle + 6 workers). Pas une déclaration de conformité.

Des pods d'écriture nus (sans contrôleur) se trouvaient sur un plan de contrôle du labo 25 : `kubectl drain` a affiché « cannot delete Pods that declare no controller » aussitôt, et pourtant le roll est resté bloqué 900 s (INCIDENT, 3 plans de contrôle + 5 workers) avant de finir sur « could not be drained ». Pourquoi le roll a attendu n'est PAS établi (le refus de `kubectl` est immédiat ; les attentes qui précèdent le drain, sur les clusters CNPG et sur les budgets, sont les candidates, et le message affiche le délai du drain quoi qu'il ait vraiment expiré). La réponse ne dépend donc plus de cela : depuis la 0.4.1 `cordon_drain` lit d'ABORD les pods du nœud, avant les attentes CNPG, l'attente des budgets, le cordon et le drain, liste ceux que `kubectl drain` refuserait (la règle de kubectl : aucune référence de propriétaire avec `controller: true` ; les pods de DaemonSet, les pods statiques et les pods terminés ne comptent pas) et **refuse aussitôt, en les nommant, sans avoir touché au nœud** quand le roll est non interactif (`--yes`, `APPROVE=auto`) ; en mode interactif il demande « Drain … anyway? » et, si oui, continue comme avant (le drain les refuse alors, et l'ancienne question suit). Une liste de pods illisible ne fait qu'avertir : `kubectl drain` reste le juge. Supprimer les pods (ou les placer sous un Deployment) puis relancer la même commande.

**Exécuté sur Scaleway (un labo de preuve, 3 plans de contrôle + 6 workers) :** le roll d'un worker qui portait un pod nu et un pod client égaré a été refusé en nommant les deux (« Nothing was changed »), budgets et Flux rétablis, rc 201. **Le refus vient après deux plans par nœud : il n'est donc pas « en quelques secondes » depuis la commande.** Le `cluster-roll` d'un nœud lance deux contrôles `tofu plan` (41 s et 55 s là) AVANT `cordon_drain`, dont la lecture des pods répond en moins d'une seconde : le refus est venu 96 s après que le nœud a été nommé et 2 min 41 s après le début de la commande (147 s la première fois). « Refusé en quelques secondes » vaut depuis le début de l'étape de drain ; compté depuis la commande, un refus en moins de 60 s n'a PAS été obtenu. Faire le même refus depuis le survey avant le premier nœud, comme le fait la question de la copie unique ci-dessous (33 s là), répondrait en 25 s environ avec les mêmes chiffres (une estimation, non faite).

### Un remplacement de nœud détruit les données d'une base à instance unique (profil `light` ; labo 28B, I17)

Échelon : observé sur UN cluster (Scaleway, labo 28B, 3 plans de contrôle + 6 workers, 2026-10-30) ; la question dans le roll est codée en 0.4.1 : testée hors ligne avec des simulations, puis exécutée une fois sur Scaleway (3 plans de contrôle + 6 workers). Pas une déclaration de conformité.

Une base `light` (profil d'OpenAether-apps : 1 instance, volume `local-path-retain` local au nœud, aucune sauvegarde) a son unique copie sur le disque de son nœud. `task cluster-roll -- --node=<worker>` et `task cluster-replace-node` détruisent l'ancienne machine et en créent une nouvelle avec un nouveau disque : **les données d'un cluster `light` présent sur ce nœud sont détruites**. Labo 28B : le roll d'un worker qui portait `lab27-light` s'est terminé (rc 0 en 790 s, NOMINAL, drain terminé), 42 583 commits acquittés de l'écrivain de test ont disparu, et le nettoyage qui suit le remplacement a REFUSÉ le volume (« primary of record: its data was on the replaced disk »), trop tard pour y changer quoi que ce soit ; le labo 27B avait rencontré le même refus. L'instance unique n'a pas retenu le roll à cette occasion (aucun share-manager RWX sur ce nœud, contrairement au cas ci-dessus), et la 0.4.0 ne s'arrêtait pas devant une base `light` ; depuis la 0.4.1 il demande d'abord (fin de cette section).

C'est hors de la règle de zéro perte acquittée, par décision du propriétaire du 2026-10-30 : `light` est documenté comme « stockage local au nœud ... perdu avec son disque, aucune sauvegarde, données que l'on peut perdre » (la page des profils de base de données d'OpenAether-apps), et la règle couvre `ha`, `standard`, les bases de la plateforme et la forge.

**Avant de rouler ou de remplacer un nœud** (simples lectures) :

```bash
NODE=<worker>
kubectl get pods -A -l cnpg.io/cluster --field-selector spec.nodeName="$NODE" -o wide
kubectl get clusters.postgresql.cnpg.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,INSTANCES:.spec.instances
```

Un pod d'un Cluster à `INSTANCES` 1 sur ce nœud est une base `light` dont les données partent avec le nœud. Passer d'abord son application en `standard` ou `ha` (une autre copie existe alors), ou accepter la perte.

**Depuis la 0.4.1 (infra #425 ; testé hors ligne avec des simulations, puis exécuté sur Scaleway : voir la fin de ce paragraphe).** Avant de toucher au premier nœud, le survey de `cluster-roll` et de `cluster-replace-node` nomme chaque Cluster CNPG qui déclare UNE instance et dont le volume est rattaché, par sa propre affinité de nœud, à un nœud que ce lancement remplace (un volume répliqué, comme Longhorn, n'est pas rattaché et ses données survivent au nœud : un tel Cluster n'est pas nommé), et demande `Replace anyway and DESTROY the data listed above? [y/N]`. **`--yes` / `APPROVE=auto` n'y répond pas** : sans interaction, le roll refuse, ne change rien et imprime l'option exacte pour chaque Cluster ; la perte s'accepte par son nom, `--accept-sole-copy=<namespace>/<name>` (répétable), après le `--` de la tâche : `task cluster-roll PROVIDER=… -- --accept-sole-copy=<namespace>/<name>`, et de même pour `task cluster-replace-node`. Une lecture qui échoue refuse (une question sans réponse n'est pas « aucune base »), de même qu'un nœud du lancement dont le nom Kubernetes ne se lit pas à partir de son adresse : le roll nomme l'adresse et ne change rien, il ne pose pas la question pour moins de nœuds qu'il n'en remplace. `--dry-run` ne lit pas les bases : le plan qu'il affiche ne mentionne pas cette perte. La question n'est pas posée pour `--upgrade` (le disque est conservé) ni pour `cluster-shrink` (qui refuse déjà tout volume local au nœud). **À quoi s'attendre :** un roll non interactif d'un cluster qui porte une base `light` s'arrête désormais tant que cette option n'est pas donnée ; c'est le but. Il avertit et demande ; il ne déplace ni ne protège la donnée (une seconde instance le fait). **Exécuté sur Scaleway (un labo de preuve) :** le roll non interactif du worker qui portait une instance `light` a été refusé 33 s après le début de la commande, rc 201, en nommant le Cluster, son nœud épinglé et l'option exacte, sans aucune ligne `Destroying` ni d'apply dans le journal ; en interactif, répondre oui au roll et non à la question a fini en « aborted by operator », le nœud inchangé ; avec `--accept-sole-copy=<namespace>/<name>` le roll est passé (7 min 17 s, NOMINAL) et l'instance a été détruite comme acceptée, avec les 9 078 commits acquittés de son écrivain : demandé par son nom, hors de la règle de zéro perte par la décision du propriétaire ci-dessus.

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

### Un plan de contrôle vivant est d'abord arrêté proprement (0.4.0)

Quand le chemin de remplacement (sans `--upgrade`) remplace un plan de contrôle vivant, le roll le draine, l'arrête avec `talosctl shutdown` et attend (jusqu'à 300 s) qu'il cesse de répondre, puis seulement retire son membre etcd et détruit la VM. Pourquoi : à chaque remplacement de plan de contrôle de l'ancien chemin, 4 ou 5 des 5 workers cessaient de renouveler leur Lease pendant 46-97 s et des workers sains passaient NotReady ; avec l'arrêt propre d'abord, les blocages étaient de 8-9 s et aucun worker sain n'a fait de va-et-vient, sur 2 remplacements d'UN lab chez UN fournisseur (les chiffres, les bras et ce qui n'est pas prouvé : [`resilience.fr.md`](resilience.fr.md), « Des workers sains passent NotReady ... F-CPFLAP »). **Coût : environ 4 minutes de plus par plan de contrôle** (le roll complet de 3 plans de contrôle : environ 12 minutes de plus). `--dry-run` affiche l'étape. Elle est sautée, avec un avertissement et sans autre changement, quand le cluster a moins de 3 plans de contrôle ou qu'un plan de contrôle ne rapporte pas un etcd sain ; un arrêt refusé ou un nœud qui ne s'arrête pas à temps n'arrête pas non plus l'exécution (le nœud a été cordonné par le drain et le reste jusqu'au uncordon du roll, comme dans un remplacement sans l'arrêt). Non concernés : `cluster-replace-node` (un nœud mort ne peut pas répondre ; son chemin est inchangé) et le `--upgrade` sur place. L'étape livrée n'a pas encore tourné sur un cloud.

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

## Un remplacement qui s'arrête après la destruction de l'ancienne VM (rupture de stock du fournisseur)

`task cluster-roll -- --node=<n>` et `task cluster-replace-node` détruisent l'ancienne VM puis créent la nouvelle. Si la création échoue, le cluster reste avec un nœud en moins. Observé au lab 27 (Scaleway, 2026-10-26, trois fois dans la journée, 5 à 10 minutes chaque fois) : `resource POP2-4C-16G is out of stock` pour le type d'instance du plan de contrôle dans une zone, après la destruction. État laissé : 2 plans de contrôle sur 3 (quorum etcd 2), le nœud cordonné, son objet Node et son membre etcd disparus, le serveur **tainted** dans l'état OpenTofu et, la restauration n'ayant pas pu joindre l'API à temps, les Kustomizations Flux `cnpg`, `forgejo-db` et `openaether-platform` encore suspendues et tous les PodDisruptionBudgets CNPG supprimés. La reprise a pris 71 minutes, surtout en détours.

**Ce qui a changé après le lab (UNVERIFIED sur un cloud, couvert par des tests hors ligne seulement) :** la restauration à la sortie du roll est désormais répétée (`RESTORE_TRIES`, 6 par défaut, toutes les `RESTORE_RETRY_WAIT`, 15 s par défaut) jusqu'à ce que l'API la confirme : un roll qui meurt sur une API brièvement injoignable ne laisse plus Flux suspendu et les budgets supprimés ; et une relance n'est plus refusée à cause du serveur tainted. Lisez quand même la fin de la sortie du roll : elle nomme ce qui reste suspendu ou manquant.

**La séquence qui a marché au lab** (observée ; l'ordre compte) :

1. Constater les dégâts, en lecture seule : `kubectl get nodes` (le plan de contrôle est absent), `kubectl get kustomizations -A` (les suspendues), `kubectl get pdb -A -l cnpg.io/cluster` (aucun), etcd sur un plan de contrôle survivant (`talosctl etcd members` : 2 membres, sains).
2. Attendre que le fournisseur ait de nouveau du stock. Réessayer ne coûte rien : l'étape suivante le fait. Au lab, le fournisseur a répondu de nouveau après environ 10 minutes la première fois, après environ 70 la dernière. Rien ne se dégrade tant que deux plans de contrôle et tous les workers tournent, mais ne lancez pas une autre opération sur un nœud avant le retour de celui-ci.
3. Lancer **`task cluster-replace-node PROVIDER=<p> NODE=<nom du nœud> APPROVE=auto -- --even-if-running --ip=<adresse privée de ce nœud>`**. `--ip` est nécessaire car l'objet Node a disparu, **pour un worker comme pour un plan de contrôle** (`tofu output control_plane_private_ips` et `worker_private_ips` donnent les adresses ; sans lui l'exécution s'arrête en nommant la commande exacte, labo 27 séance 3) ; `--even-if-running` car le fournisseur peut encore lister le serveur à moitié créé comme démarré ou arrêté. Elle détruit le serveur tainted et en crée un nouveau. Si le fournisseur est encore en rupture, elle échoue de la même façon et restaure Flux et les budgets à la sortie ; attendre et la relancer. Au lab, la même commande a restauré les budgets et les suspensions à chaque exécution. Aux têtes du lab (avant le changement ci-dessus) elle demandait d'abord `tofu untaint '<adresse du serveur>'` (le plan détruisait 2 ressources, 1 au plus attendue) ; ce n'est plus demandé, et si vous rencontrez encore ce refus, `tofu untaint` du serveur nommé est la sortie manuelle.
4. S'attendre à un nœud Ready et à etcd 3/3 quelques minutes après la création (11:37:33 au lab, une création après la dernière rupture). Puis vérifier que `kubectl get kustomizations -A` et les budgets CNPG sont revenus (`task cluster-verify PROVIDER=<p>`).

**Ce qui n'a pas marché au lab, donc n'y commencez pas :**

- `task cluster-node-state` dit `recover`, et `task cluster-node-recover` est un redémarrage brutal qui refuse sans un « yes » tapé et ne fait rien pour une VM jamais configurée.
- Un simple `task cluster-up` : son plan attend 15 minutes la source de données `talos_cluster_health` pour un nœud qui n'a pas encore de configuration Talos, puis échoue.
- Allumer la VM à la main : une VM dont la carte réseau privée n'était pas encore attachée n'est jamais devenue joignable. Laissez le remplacement la recréer.
- Un `tofu apply` ciblé de la configuration machine : il a attendu 15 minutes la garde de port ; le tuer a laissé un verrou d'état (`tofu force-unlock <id>`, seulement après avoir vérifié qu'aucun processus `tofu` à vous ne tourne encore).

**Pourquoi le remplacement ne peut pas créer d'abord (conception, non implémentée).** Le nouveau nœud doit porter l'ancien nom, l'ancienne adresse privée (IPAM) et, pour un plan de contrôle, un nouveau membre etcd après le retrait de l'ancien : les deux VM ne peuvent pas coexister sans une autre identité ; créer avant de détruire reviendrait à un nouveau nœud (autre nom et adresse) puis un retrait, c'est-à-dire l'ajout suivi du retrait, pas ce chemin. Un contrôle préalable est possible là où le fournisseur expose la disponibilité : l'API Instance de Scaleway liste, par zone, l'état de stock de chaque type commercial (available, scarce, shortage) sous son point d'accès products/servers/availability ; un contrôle avant la destruction refuserait de démarrer quand le type est en shortage dans la zone. Il est propre au fournisseur (OVH, Outscale et Proxmox n'ont pas d'équivalent listé ici), sujet à une course (le stock peut partir entre le contrôle et la création) et n'a pas été vérifié sur l'API réelle : il reste une issue, pas du code.

**La même réponse du fournisseur à une installation (`task cluster-up` ; un troisième labo de preuve, Scaleway, 3 plans de contrôle + 6 workers, UNE occurrence, INCIDENT).** `cluster-up` crée aussi des machines (installation, ajout), et une création peut être refusée de la même façon ; seule l'installation a été vue. À une installation neuve aux tags 0.4.0, la première exécution s'est terminée en rc 201 après 5 min 33 s sur deux erreurs : l'erreur connue de l'ACL du load balancer, et un worker que le fournisseur a créé `stopped` (`expected state running but found stopped`, en fr-par-3). La même commande, relancée, s'est terminée en rc 201 trois fois de suite (après 1 min 26 s, 1 min 29 s et 1 min 28 s) sur `resource POP2-4C-16G is out of stock` pour ce worker, et la cinquième exécution l'a créé et s'est terminée en rc 0. Du début de l'installation au rc 0 : 20 min 25 s (les deux installations précédentes ont pris 10 min 13 s et 10 min 54 s, aussi INCIDENT : l'erreur d'ACL, et dans la seconde une construction d'image en plus ; la première exécution de cette installation a aussi construit l'image). Rien n'a été abîmé dans le cluster : rien n'était encore configuré, les serveurs déjà créés ont continué à tourner (et à être facturés) pendant l'attente de la commande, et le serveur arrêté a été marqué tainted, détruit puis recréé par l'exécution suivante. **Que faire :** relancer la même commande, inchangée, jusqu'à ce que la création réussisse ; ne pas changer la forme (une zone, un nombre de nœuds) pour contourner, sauf si c'est voulu. L'API de disponibilité du fournisseur n'a pas été un guide dans cette occurrence : elle indiquait `shortage` pour cette zone et `scarce` pour les deux autres, et indiquait encore `shortage` après qu'une création eut réussi. `cluster-up` n'a pas de nouvelle tentative automatique. On n'a pas étudié si un autre fournisseur, une autre zone ou un autre type répond ainsi.

## Un nœud déjà mort

`task cluster-roll` exige que tous les nœuds soient Ready et vide chacun avant de le toucher ; un nœud mort ne peut ni l'un ni l'autre. Utilisez `task cluster-node-state PROVIDER=… NODE=…`
(lecture seule, nomme la commande suivante), puis `task cluster-node-recover` quand le fournisseur dit que la machine tourne, ou `task cluster-replace-node` quand elle est arrêtée, en
erreur ou disparue. La seconde fait le même remplacement que le déploiement pour ce seul nœud (`rolling-replace.sh --dead --node=…`), après un examen des survivants (l'etcd de chaque plan de contrôle survivant est lu jusqu'à trois fois, `ETCD_READ_TRIES`, donc une seule lecture en échec ne refuse plus le remplacement : infra #401, testé hors ligne ; un membre muet à chaque essai est toujours refusé et nommé) et
avec le membre etcd retiré avant l'objet Node. Le disque du nœud mort est effacé comme tout autre, donc le survey interroge aussi sur une base à instance unique dont l'unique copie s'y trouve (section « Un remplacement de nœud détruit les données d'une base à instance unique »). Le déploiement attend aussi maintenant que le kube-apiserver de chaque plan de contrôle redémarré serve avant de continuer
(#42). La procédure, les exercices et ce qui n'est PAS VÉRIFIÉ sont dans [`resilience.fr.md`](resilience.fr.md).

## Ajouter des nœuds : `cluster-up` crée la machine AVANT de poser la question (conception 0.3.x, inchangée)

Augmenter `workers` ou `control_planes` dans les tfvars puis lancer `task cluster-up` **sans `APPROVE=auto` crée et configure déjà la nouvelle machine avant que la première question ne soit posée.** Établi au labo 27 (séance 3, un ajout de 4 à 5 lancé par un simple `task cluster-up` : « machines created » et « configured worker:4 » ont été affichés avant le plan, qui annonçait ensuite 0 à ajouter) et par le code : ce n'est pas une régression de 0.4.0. `_grow-nodes` précédait déjà le plan dans `cluster-up` au tag 0.3.2, par conception (infra #59) : un nœud ajouté à un cluster déjà amorcé ne peut pas être construit et configuré par l'apply du plan, car son port Talos n'est joignable que par un tunnel qui s'ouvre après l'existence de la machine ; `scripts/bootstrap/grow-nodes.sh` crée donc les machines (un plan du seul module fournisseur, refusé s'il supprime ou redimensionne quoi que ce soit), ouvre les tunnels et ne configure que les nouveaux nœuds, et le plan habituel ne trouve alors plus rien à ajouter. **Ce qui s'exécute avant la première question de `cluster-up`, dans cet ordre :** les contrôles de la clé, du fichier d'environnement, des identifiants S3, de la phrase secrète et des buckets (`ensure-buckets.sh --preflight`) ; la construction de l'image (`image-build ENSURE=1` : il planifie et n'applique que si l'image Talos doit être construite ou importée, ce qui crée sans demander les objets du bucket d'image et l'image chez le fournisseur) ; le rendu des manifestes de bootstrap ; `converge-versions --check` (lit, n'écrit rien) ; puis `grow-nodes.sh` (crée et configure les machines que l'état ne contient pas ; sans effet sur un cluster neuf ou quand aucun compte n'a augmenté) ; seulement ensuite le plan de la phase 1, la garde contre la suppression de nœud et la question. Donc **un lancement de `cluster-up` que vous pensiez être un plan n'est pas gratuit quand un compte a augmenté, ni quand l'image manque** : il dépense de l'argent. La question protège l'apply du plan (et le roulement qui suit), pas la croissance. **Pour seulement lire le plan, ajouter `PLAN_ONLY=1`** (`task cluster-up PROVIDER=… ROLE=… PLAN_ONLY=1`, infra #412 ; désactivé par défaut, donc `APPROVE=auto` et tous les autres lancements sont inchangés) : les contrôles et les buckets s'exécutent comme toujours, la construction de l'image est planifiée et, si elle serait construite, signalée (« it WOULD be built ») et non construite, les manifestes sont rendus, `converge-versions --check` s'exécute, `grow-nodes.sh --plan-only` liste les machines qu'il créerait et les nœuds qu'il configurerait sans rien créer, appliquer, rafraîchir ni ouvrir, puis le plan de la phase 1 est fait et affiché avec la garde contre la suppression de nœud, et l'exécution se termine en rc 0 avec « plan only: nothing was created ». Quand l'étape de croissance agirait, le plan de la phase 1 n'est pas pris (il peut attendre jusqu'à 15 minutes la santé de nœuds qui n'ont pas encore de configuration) et l'exécution le dit. Il assure toujours les buckets d'état (le backend en a besoin), rend les manifestes en local, lance `tofu init` et, sur un cluster déjà amorcé, ouvre les tunnels Talos locaux comme le fait `task plan`, et il n'enregistre aucun reçu de palier. La copie unique d'un ancien état d'image unique (avant #69) vers sa propre clé (un push puis un renommage dans le bucket d'état) est une écriture : un run en plan seul la laisse à un vrai run et planifie contre cet état tel qu'il est. Niveau de preuve : simulé (`test-cluster-up.sh`, `test-grow-nodes.sh`, `test-talos-image.sh`), puis exécuté deux fois sur Scaleway (3 plans de contrôle + 6 workers). (1) L'exercice, sur un cluster amorcé avec `workers` augmenté de un dans le tfvars (NOMINAL) : rc 0 en 1 min 31 s ; les serveurs (10), les images d'instance (9), les snapshots de bloc (12) et les listings d'objets des buckets d'état étaient identiques avant et après, et les quatre ressources machine du nouveau worker étaient listées « WOULD be created ». Le plan de la phase 1 lui-même n'a pas été atteint là (l'étape de croissance agirait), donc qu'un plan sur un cluster amorcé ouvre les tunnels Talos locaux reste NON VÉRIFIÉ sur un cluster. (2) **Avec l'image Talos absente (un compte neuf) l'exécution ne peut pas s'arrêter à un plan qu'elle sait lire :** elle a dit que l'image « WOULD be built (and was NOT) », puis le plan de la phase 1 a échoué par neuf `no image found` (3 plans de contrôle + 6 workers) et l'exécution s'est terminée en rc 201, sans rien créer. Scaleway, OVH et Outscale lisent l'image par son nom dans ce plan : un run en plan seul demande donc que l'image existe ; seul Scaleway a été vu, OVH et Outscale se lisent dans les modules. La bannière et la description de la tâche le disent depuis la 0.4.1. L'ordre par défaut n'est pas modifié : placer la croissance derrière la question impose une seconde question et un nouvel ordre dans un chemin éprouvé sur trois clouds, décision du propriétaire.

**Le plan après un ajout peut montrer les workers existants comme modifiés (infra #420).** Labo 28 (OVH, un ajout, NOMINAL) : une fois la machine créée par l'étape de croissance, le plan annonçait « 0 to add, 5 to change » : `talos_machine_configuration_apply.worker[0..4]` avec un nouveau `machine_configuration_hash`, appliqué sur place, sans redémarrage observé. La configuration machine de chaque worker existant est donc réappliquée quand on en ajoute un ; un remplacement apparaîtrait comme un remplacement, ce n'est pas le cas. Pourquoi le hash change n'est pas établi (lecture du code seulement) ; vu sur OVH (ce labo) et de nouveau sur Scaleway (un labo de preuve, 3 plans de contrôle + 6 workers, une croissance de 6 à 7, NOMINAL : « 0 to add, 6 to change », appliqué en place, sans redémarrage), NON VÉRIFIÉ sur Outscale ; savoir si on peut l'éviter est renvoyé à la 0.5.0.

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

**Évacuer un nœud avant une réduction (la garde refuse tant que des volumes locaux au nœud subsistent ; elle n'est pas affaiblie).** `cluster-shrink-plan` refuse en nommant les volumes et, depuis ce passage, imprime pour eux les commandes ci-dessous. **Observé, pas scripté** (labo 27 séance 3, Scaleway, le worker portant forgejo-db-1, openbao-1, grafana-db-2, loki-1 et un volume de cache vmselect ; environ 3 minutes à la main ; les commandes sont la forme générique, le labo n'a pas consigné ses lignes exactes) : (1) `kubectl cordon <nœud>`. (2) Pour un primaire CNPG présent sur le nœud, faire d'abord un switchover (`kubectl cnpg promote <cluster> <instance réplica> -n <namespace>` ; le switchover contrôlé de forgejo-db au labo a eu un trou d'écriture de 35,5 s). (3) Pour chaque instance CNPG et chaque pod de StatefulSet présent sur le nœud : supprimer son PVC, puis son pod, pour que CNPG ou le StatefulSet le recrée sur un autre nœud (`kubectl -n <namespace> delete pvc <claim>` ; `kubectl -n <namespace> delete pod <pod>`). Un membre OpenBao quitte d'abord le raft (`bao operator raft remove-peer <id>`) et le rejoint au retour de son pod (le membre du labo était revenu en 29 s). (4) **Supprimer aussi les PersistentVolumes conservés** (`kubectl delete pv <nom>`) : un volume `Retain` reste `Released`, toujours épinglé au nœud par son affinité, et le plan continue de refuser tant qu'il existe. (5) Relancer `task cluster-shrink-plan PROVIDER=…` : il doit maintenant planifier la seule suppression ; puis `task cluster-shrink PROVIDER=… PLAN=<fichier>` (7 min 10 s au labo pour un worker, 6 min 56 s et 8 min 15 s sur un cluster neuf). Supprimer un PVC supprime les données de cette instance : prendre d'abord la sauvegarde du préambule, et n'évacuer qu'une instance dont le Cluster en a une autre saine. La garde elle-même (`pinned_pvs`) est inchangée.

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
