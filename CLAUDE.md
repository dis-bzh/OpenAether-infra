# CLAUDE.md — OpenAether-infra

Provisioning bare-metal / cloud + Talos (OpenTofu). Les manifests communs et le
wiring Flux vivent dans `OpenAether-apps` ; les manifests **métier** dans chaque
repo applicatif.

## Dépôt public — aucune donnée réelle

Ce dépôt est **public**. N'y committer que du code et des exemples — jamais une
IP, un ID de compte cloud, ou toute autre donnée propre à un environnement ou un
test réels. Pattern déjà en place : `envs/*.tfvars` (réel) est gitignore, seul
`*.tfvars.example` (placeholders `YOUR_IP`, etc.) est public. Incident du
2026-07-31 : des IP réelles (FIP OVH, egress management, IP admin) avaient fui
dans `OpenAether-apps` et ont nécessité une purge d'historique (`git
filter-repo`, `--replace-text` ET `--replace-message` — les messages de commit
ne sont PAS couverts par le premier seul).

**Le gitignore ne suffit pas : les FIXTURES DE TEST fuient aussi.** Incident du
2026-08-20, trouvé pendant le §9 de la 0.1.0 : une IP admin réelle servait de cas
`CATCH` dans `check-gitleaks-rules.sh`, publique depuis le 2026-08-13. Elle avait
été choisie *parce que* la règle exige une adresse routable — une plage RFC 5737
serait allowlistée et le test ne prouverait rien. Le bon choix est la plage
RFC 1112 « réservée usage futur », allouée à personne : routable aux yeux de la
règle, à personne dans les faits. Ne pas écrire l'adresse ici — cette page est
scannée, la fixture ne l'est pas (`.gitleaks-envdata.toml` l'exempte par chemin),
et l'écrire a fait rougir la CI de la PR qui documentait l'incident.

**Et une purge d'historique ne referme pas tout.** Mesuré le jour même, après un
`filter-repo` vérifié sur 1885 blobs : les refs sont propres depuis un clone neuf,
mais GitHub sert encore le diff de la PR d'origine et l'ancien blob par son SHA
(`/contents/<path>?ref=<vieux-sha>`). Seul le support GitHub peut les faire
disparaître. Une donnée publiée est publiée ; la purge limite la suite, elle
n'annule pas le passé.

## Objectif produit — socle Talos modulaire, management CAPI optionnel

OpenAether déploie **un cluster Talos** sur **n'importe quel provider** (Proxmox ou
cloud Scaleway/OVH/Outscale) avec pour **seul socle figé : CNI (Cilium) + Flux**.
Par-dessus, on **pioche modulairement** dans les manifests communs d'`OpenAether-apps`
selon les dépendances voulues (mesh ou non, Zitadel sans OpenBao, observability sans mesh,
etc.). Les manifests **applicatifs métier** restent dans chaque repo d'app (ex.
`seestar-fits`) et dépassent ce projet.

Un cluster ne devient un **cluster de management** que lorsqu'on y installe/configure
**CAPI + ses dépendances** pour piloter des clusters clients. Le multi-cluster reste
un objectif — mais devient une **surcouche optionnelle**, plus le point d'entrée
(ce n'est ni le plus simple ni le plus cheap). Ce recentrage **élargit** l'usage
d'OpenAether : du single-cluster autonome jusqu'au hub multi-cluster.

**Topologie paramétrable** : HA (3 CP + n workers) ou non-HA (1 CP + 1 worker), via
`control_plane_count` / `worker_count`. En non-HA, CP taché `NoSchedule` (workloads
sur le worker sans nodeSelector).

### Ajout provider Proxmox (on-premise)

Cible d'hébergement des apps DIS (seestar-fits, prospection, multisport…) : serveurs
dédiés sous **Proxmox** (ZFS), VMs Talos. Single-host ou multi-host PVE cluster.

- **Nouveau provider `proxmox`** sous `modules/providers/proxmox/`, respectant
  `modules/providers/provider-contract.md` — mêmes variables/outputs que `scw`/`ovh`/
  `outscale` (`control_plane_count`, `worker_count`, IPs privées CP/worker, LB
  k8s/app, bastion). Le reste du stack (module `talos`, `cluster/`) est
  provider-agnostique et **ne doit pas changer**.
- **`node_names` (list)** : VMs round-robinées via `element()` (même pattern que
  les zones Scaleway). `["pve1"]` = non-HA, `["pve1","pve2","pve3"]` = vrai HA
  (1 CP par hôte physique, etcd distribué).
- **VIP apiserver posé dès le 1 CP** : endpoint k8s sur une VIP Talos (pas l'IP nue
  du CP) pour que le passage futur à 3 CP ne re-adresse pas l'apiserver.
- HA réelle du CP on-premise = **multi-hôtes** (3 CP sur 3 dédiés dans un cluster
  PVE) ; 3 CP sur une seule box Proxmox n'est pas de la vraie HA.
- `k3s-cluster` = **archive / inspiration seule**, jamais fusionnée ; refaire de 0 si
  plus propre.

## Langue

**L'anglais est la langue par défaut du dépôt** : commentaires de code, noms,
messages de commit et documentation. Le français est une **traduction**, jamais
la source.

- Docs et README : `<nom>.md` = anglais (canonique), `<nom>.fr.md` = français.
  Chaque fichier ouvre sur un lien vers l'autre langue.
- Code (`.tf`, `.yaml`, `.py`, `.sh`) : commentaires en anglais.
- Échange avec l'utilisateur : en français.

⚠️ Toute régression est un défaut : écrire directement en anglais. La bascule
du 2026-07-28 s'est faite par lots et en a laissé passer — le 2026-07-29 il
restait ~50 lignes dans les deux dépôts, dont des blocs à moitié traduits où une
phrase française coupait une phrase anglaise. Ne pas se fier à « c'est déjà
fait » : passer le détecteur.

**Piège vécu lors de cette bascule** : `pick.py` identifiait ses profils générés
par la chaîne littérale française de leur en-tête. La traduire a rendu `--check`
aveugle **en silence** (il annonçait « 0 profil » au lieu de 1). Avant de
traduire une chaîne, vérifier qu'aucun code ne la compare.

## Contribution assistée par IA

Règles reprises de `CONTRIBUTING.md` (lui-même adapté du CONTRIBUTING de Feint) —
deux qui changent l'écriture des commits :

- **Trailer `Assisted-by: Claude Code (<modèle>)`**, jamais `Co-Authored-By` ni
  `Signed-off-by` pour un outil : ces deux-là revendiquent la paternité ou
  certifient l'origine, ce qu'un modèle ne peut pas faire. Refusé par le hook
  `commit-msg` et par la CI.
- **Apporter la preuve, pas l'intention** : une modif de module provider n'est
  pas finie tant que quelque chose de réel ne l'a pas exercée. Quatre barreaux
  (`task test` mocké → `task feint-*` émulé → `task local-up` Docker local →
  cloud réel, voir `CONTRIBUTING.md`) ; dire lequel on a atteint et lequel on a
  sauté. « Ça devrait passer » n'est pas un barreau.

## Concision et refacto

Le projet ne doit pas grossir en lignes plus vite qu'en fonctionnalités.

- **Commentaire = le pourquoi, en 1 à 3 lignes.** Pas le récit de l'incident ni
  la date : juste ce qui évite de refaire l'erreur. Le détail va dans le runbook.
- **Doc courte qui POINTE** vers le fichier faisant autorité, au lieu de
  recopier son contenu (la recopie dérive, et il faut la maintenir deux fois).
- **Backlog = ouvert seulement.** Une entrée faite appartient à git.
- **Refactorer au fil de l'eau** : factoriser les répétitions, supprimer le code
  mort, fusionner les fichiers redondants. Un fichier qui gonfle est un signal.

Avant d'écrire un pavé : que perd-on à le réduire à deux lignes ? Le plus
souvent, rien.

## Suivi du travail — issues GitHub

Toute amélioration identifiée (« mieux que l'existant ») ouvre une **issue
GitHub**, comme dans Feint. Une issue nomme ce qui cloche, **ce qui la ferme**
(l'observation qui prouve que c'est réglé) et le **barreau** visé, l'un des
quatre de `CONTRIBUTING.md`.

Un constat sans changement à proposer est une **issue**, pas une PR. Une PR
propose un changement ; c'est ce qui distingue les deux.

**Un audit n'est pas une PR.** Une session qui balaie le dépôt à la recherche
de défauts (revue de pipeline, de gates, etc.) doit soit corriger ce qu'elle
trouve dans la même session (une PR par lot cohérent, comme la routine
quotidienne), soit s'arrêter à 2 issues comme toute autre session — jamais
ouvrir un lot au-delà sans un budget de fermeture en face. Le 2026-08-28, une
session d'audit a ouvert 15 issues (#111–#125) en 9 minutes et laissé un
commit correctif de 51 fichiers sur une branche jamais transformée en PR :
aucune de ces issues n'a été refermée par ce travail. Le déséquilibre
entrée/sortie est le signal à surveiller, pas le nombre d'issues en lui-même.

Il y a eu `docs/backlog.md`, un tracker tenu à la main jusqu'à 696 lignes, et
illisible bien avant. Il est supprimé, et son contenu réparti selon sa nature :

- les **tâches** sont des issues — applicatives dans `OpenAether-apps`, les
  autres ici ;
- **« Où on en est »** est devenu `docs/status.md` : ce qui tourne, ce qui est
  mesuré sur compte réel et depuis quand. **C'est le premier fichier à ouvrir en
  début de session** — il dit par où reprendre, pas ce qui reste à faire ;
- les **pièges** sont allés dans les skills qui s'en servent (`teardown`,
  `cluster-upgrade`, `provider-module`, `change-process`), et ceux de la couche
  applicative dans `OpenAether-apps`.

Parcours post-déploiement : `docs/admin-access.md`.

Avant de toucher au DAG Flux d'`OpenAether-apps` : `task apps-validate`
(intégrité du DAG + profils `pick.py` à jour).

## Repère structure

- `infrastructure/opentofu/modules/providers/` : un dossier par provider + `_shared`
  + `provider-contract.md` (le contrat à implémenter).
- `infrastructure/opentofu/cluster/` : composition (Talos, bootstrap-manifests, envs).
- `infrastructure/opentofu/talos-image/` : build de l'image Talos (schematic).
