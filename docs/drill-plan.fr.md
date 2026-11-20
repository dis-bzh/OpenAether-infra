# Plan de drills — le premier drill de reprise après sinistre et le premier drill d'incident

🇬🇧 [English version](drill-plan.md)

> Plan pour le lab Scaleway de la 0.6.0. **Rien de tout cela n'a tourné.** Les résultats vont dans le tableau de [`disaster-recovery.fr.md`](disaster-recovery.fr.md) section 5, une
> ligne de [`audit-register.fr.md`](audit-register.fr.md) section 2, et le statut de sa section 3 (F-BKP-16, LOG-17). Exécution sous les garde-fous du skill `lab-cloud` (GO/NO-GO,
> watchdog, teardown, vérification finale qu'il ne reste rien).

## Ce qui est déjà prouvé, et ce qu'un drill ajoute

La chaîne de reprise a tourné quatre fois (lab 20, lab 28B et les deux labs de preuve 0.4.1) et ses étapes ont des chiffres. Ces runs utilisaient un **OpenBao de développement**, un magasin
réplica chez le **même** fournisseur dans un cas, des entrées laissées sur l'hôte du lab, et aucun critère écrit d'avance. [`disaster-recovery.fr.md`](disaster-recovery.fr.md) liste ce qu'ils n'ont pas
montré : la restauration d'un OpenBao de production (le quorum des parts de récupération), la connexion de bout en bout à Grafana via Zitadel, un réplica chez **un autre** fournisseur. La page
d'incident n'a jamais été jouée. Un **drill** signifie ici : des critères écrits d'avance, des entrées issues seulement de ce qu'un étranger à l'hôte du lab aurait (le séquestre), un chronomètre depuis
la décision, et une ligne à la fin, réussie ou non.

## Ordre dans le lab

Installation (3 control planes + 3 workers, Flux, puits d'audit activé, OVH comme puits et comme magasin réplica) → **drill d'incident I1** → **drill de reprise D1** → teardown.
I1 d'abord : il fait tourner des clés, donc D1 prouve ensuite que le séquestre suit une rotation. D1 en dernier : il détruit le cluster.

## I1 — drill d'incident (S1 simulé : une clé de magasin fuitée et un cluster-admin à l'œuvre)

**Scénario.** Le signalement : « la paire de clés du magasin de sauvegarde primaire a été vue dans un paste ». Le lab joue alors l'attaquant avec une clé propre au lab : depuis l'extérieur du cluster
il liste et supprime un objet témoin du seau de sauvegarde du lab (jamais de vraies données), et depuis l'intérieur il supprime le fichier d'audit du cluster et les règles `AuditSink*`. L'opérateur suit
[`incident-response.fr.md`](incident-response.fr.md) depuis le début, chronomètre en marche, en écrivant la ligne du registre au fil de l'eau.

| # | Critère | Réussite |
|---|---|---|
| 1 | Entrée de registre ouverte (champs de la section 10) | dans les 5 min de T0 |
| 2 | Sauvegardes protégées d'abord (section 5) : la paire fuitée remplacée par `task rotate-secret`, le magasin vérifié après | dans les 30 min ; chaque commande marche telle qu'écrite, ou la page est corrigée |
| 3 | Preuves conservées (section 4) avant de remplacer un nœud | les fichiers listés existent, avec leurs empreintes |
| 4 | Les actions de l'attaquant reconstituées **depuis le puits d'audit seul**, l'audit du cluster ayant disparu (`audit-sink-check.sh`, [`audit-sink.fr.md`](audit-sink.fr.md) 11.5 point 4) | l'objet supprimé et la suppression des règles apparaissent dans les lignes d'audit restaurées |
| 5 | Le guetteur hors cluster a sonné sur la coupure du puits et sur le marqueur de suppression | en moins de 15 min, sans règle dans le cluster |
| 6 | Table de rotation (section 7) jouée pour les clés concernées ; `cluster-verify` et `cluster-security` verts après | rc 0, et 31 sur 36 ou mieux |
| 7 | Point de restauration choisi et écrit avec sa raison ; cause et changement qui la ferme | dans la ligne |

Les échecs sont des constats : chacun devient une correction de la page ou une issue. La ligne dit quel critère a échoué.

## D1 — drill de reprise (la chaîne, depuis le séquestre, depuis un autre fournisseur)

**Entrées, depuis le séquestre seul :** la clé de scellement, le mot de passe restic et les parts de récupération, déchiffrés avec les clés OpenPGP des dépositaires (deux clés jetables au
lab : il n'y a pas encore de vrai second dépositaire, `key-management.fr.md` section 3, et la ligne le dit). `task escrow` verify doit être vert avant.

| # | Critère | Réussite |
|---|---|---|
| 1 | `task dr-restore-plan ... --strict` avant la destruction | rc 0 |
| 2 | `task backup-final` avant ; une ligne témoin écrite ensuite | reçu COMPLETE |
| 3 | Cluster détruit (`cluster-down`, seaux conservés), puis la chaîne `--from replica` (magasin OVH), chronomètre depuis la décision | chaque étape rc 0, ou l'étape manuelle nommée ; RTO sous la cible de 8 h (labs 0.4.1 : environ 31 min d'étapes) |
| 4 | **OpenBao de production** : un jeton de secours créé depuis un quorum de parts de récupération, pas la part de développement | fait et chronométré |
| 5 | RPO : les lignes témoins perdues | au plus 15 min plus la copie (le pire cas annoncé) |
| 6 | `iam-admin` reconstruit comme documenté, puis **une connexion à Grafana via Zitadel** montrée par une requête | la connexion réussit |
| 7 | `cluster-verify` et `cluster-security` | rc 0, 31 sur 36 ou mieux |
| 8 | Un second run court : `--scenario etcd` sur le nouveau cluster | API et 6 nœuds revenus, `cluster-verify` vert |

Une étape en échec arrête la chaîne et se reprend à l'étape que l'outil nomme, comme aux labs ; la ligne liste chaque étape manuelle.

## Coût et risque

Environ 3 heures de cluster pour les deux drills (I1 environ 1,5 h, chaîne D1 environ 1 h plus l'installation de la reconstruction). Le puits et le magasin réplica demandent une clé OVH et un projet OVH dédié
au puits. Le lab ne joue la coupure du puits et la rotation de clés que sur son cluster ; les seaux OVH utilisés portent le suffixe du lab et sont purgés par le teardown standard. Non drillé : un vrai second
dépositaire, la perte d'un compte fournisseur (le magasin réplica est chez un autre fournisseur, mais le compte est celui du même opérateur), une compromission antérieure à la fenêtre d'expédition.

## Après le lab

Remplir les deux lignes (DR section 5, registre d'audit section 2), passer les deux actions de la section 3 du registre à fait **avec le barreau et les critères qui ont échoué**, corriger les pages que le drill a
prouvées fausses, et ouvrir une issue par défaut trouvé (pas un lot).
