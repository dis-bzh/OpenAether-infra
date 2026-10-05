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
`talos_version` à l'ancienne version pour que le cluster replanifie. Les anciennes
images restent jusqu'à `PRUNE=1`, voir
[`talos-image/README.md`](../infrastructure/opentofu/talos-image/README.md). Les
montées du 2026-10-03 ont suivi cet ordre sur les trois clouds, sur la voie à
image unique que ceci remplace.

`talos_version` est le Talos du nœud, pas le contrat de configuration machine : le module génère
sous un contrat plafonné (`config_contract` dans `modules/talos/main.tf`, qui dit pourquoi). Un
bump vers 1.14 change l'image d'installation dans la configuration ; les rendus hors ligne sous
le provider 0.12.0 ne montrent rien d'autre, mais aucun `cluster-upgrade` n'a encore tourné sous lui.

**Après avoir tiré le pin du provider 0.12.0**, lancer `tofu init -backend=false -upgrade` dans
`infrastructure/opentofu/cluster` (ou `task validate`, qui partage le lock). Le fichier de lock est
local et ignoré par git : toutes les tâches `infra-*` s'arrêtent à l'init tant que ce n'est pas fait.
`-upgrade` déplace chaque provider dans sa contrainte : lire le plan suivant. Pour ne déplacer que
talos, supprimer son bloc de `.terraform.lock.hcl` et lancer un `tofu init` simple.

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
