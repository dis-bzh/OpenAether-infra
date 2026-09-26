# Mettre à niveau un cluster vivant — Kubernetes et Talos

🇬🇧 [English version](upgrade.md)

> Construire un cluster et en garder un sont deux affirmations différentes. Voici
> la seconde. Mesurée à la main sur **Scaleway, OVH et Outscale** — les deux
> premiers le 2026-08-19, Outscale le 2026-08-20 — en topologie HA, chaque nœud
> mis à niveau **sur place** plutôt que remplacé et l'API Talos de chaque nœud
> interrogée sur ce qu'il exécute. Les runs antérieurs sur Outscale et sur OVH
> revenaient en arrière au redémarrage suivant, et les issues ouvertes disent pourquoi.
>
> La version scriptée de cette même procédure est `task cluster-upgrade`
> ([`scripts/dev/cluster-upgrade.sh`](../scripts/dev/cluster-upgrade.sh)). Elle
> se lance à la main, sous surveillance : aucune voie de CI ne déploie quoi que
> ce soit. Cette page est ce qui a réellement tourné.

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

## Kubernetes d'abord

Elle ne redémarre rien, ce qui isole le roulement du control plane de celui des
nœuds.

```bash
# modifier kubernetes_version dans envs/<role>-<provider>.tfvars, puis
task infra-apply ROLE=management PROVIDER=<p>
```

Talos réconcilie les static pods et les kubelets ; attendre que chaque nœud
rapporte la nouvelle version avant de continuer. À noter : ce chemin contourne
`talosctl upgrade-k8s`, qui séquence ces composants derrière des health checks —
voir les issues ouvertes.

## Puis Talos, sur place

Bumper `talos_version`, construire l'image de la nouvelle version (les ressources
de nœud ignorent l'image, mais la *data source*, elle, doit résoudre), appliquer,
puis dérouler.

```bash
task image-build PROVIDER=<p> VERSION=<new> ENSURE=1
# modifier talos_version dans le tfvars, puis
task infra-apply ROLE=management PROVIDER=<p>
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<clé> -- --cp-only --upgrade
task cluster-roll PROVIDER=<p> KEY=~/.ssh/<clé> -- --workers-only --upgrade
```

**Sur Outscale, la première ligne domine tout l'upgrade.** L'image est
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
que le stockage local ne pourrait pas déplacer.

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

⚠️ **Le premier apply après un bump de `talos_version` a échoué** avec
« Provider produced inconsistent final plan », une fois par machine config
(siderolabs/terraform-provider-talos#352). Rien n'est laissé à moitié
appliqué ; relancer une fois, et ne jamais ajouter de retry. Reste à savoir
s'il échoue encore : `modules/talos/main.tf` porte un contournement
`replace_triggered_by` depuis la 0.1.0, et les traces consignées depuis se
contredisent. L'une montre un bump de Talos passé en un seul apply sur Scaleway
et OVH (commit 1afa629 de la PR #26) ; la
[checklist de release](release-checklist.md) 0.1.0, §7, coche qu'il se
reproduit sur OVH. Rien ne couvre Outscale avec le contournement, ni le
provider 0.12.0, première version stable portant le correctif amont, que les
racines sélectionnent désormais. Le run cloud réel de #83 le mesure.

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

⚠️ **Le gabarit n'en fait pas partie sur OpenStack, et c'est pire.** OVH
redimensionne l'instance en place : `task infra-apply` le planifie donc comme une mise
à jour et non un remplacement, et l'applique à **tous les nœuds en même temps** —
mesuré le 2026-08-15, six nœuds passés ensemble en `VERIFY_RESIZE` et l'apiserver
injoignable plusieurs minutes. La garde « un nœud à la fois » de
`rolling-replace` ne l'attrape pas non plus : elle compte ce qu'un plan
DÉTRUIRAIT, et un redimensionnement ne détruit rien. Changer `flavor_name` un
nœud à la fois avec `-target`, ou accepter la coupure en connaissance de cause.
