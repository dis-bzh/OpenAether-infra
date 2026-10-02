# Cléa — ce que ce dépôt épingle, et si la version suivante y survit

🇬🇧 [English version](clea.md)

> L'outil lui-même est documenté là où il vit :
> [`scripts/clea/README.md`](../scripts/clea/README.md). Cette page ne parle que
> de l'usage qu'en fait ce dépôt — ce qui tourne, quand, et ce qu'un rapport vert
> a le droit d'affirmer.

## Pourquoi il existe

Renovate propose les montées de version ici, et n'en fusionne jamais aucune
automatiquement. Deux choses qu'il ne fait pas, et que rien d'autre ne couvrait :

- **Il ne peut pas dire ce qu'il ne surveille pas.** Neuf des vingt et une ancres
  de version de ce dépôt étaient inertes quand Cléa a été écrit : le commentaire
  était là, le bot ne le lisait pas, et rien ne le signalait. `task lint` échoue
  désormais là-dessus.
- **Il n'installe rien.** Une montée de version fusionnée est une montée de
  version que personne n'a vue s'installer. `scripts/dev/feint.sh` en porte la
  preuve : le pin est passé à 0.10.0 et toutes les machines ayant déjà exécuté la
  lane sont restées en 0.9.0, parce que la présence était vérifiée et la version
  non.

Cléa répond aux deux, et rapporte tous les jours. Renovate garde la main sur les
propositions — `.github/dependabot.yml` garde la trace de ce qui arrive quand
deux bots se disputent une même dépendance.

## Ce qui tourne, et quand

| lane | quand | ce qu'elle exerce |
|---|---|---|
| scan + couverture | tous les jours, 04:17 UTC | chaque ancre lue, résolue en amont, et comparée à `renovate.json5` |
| sondes outils | tous les jours | installation à froid et mise à jour sur place de chaque outil qui a bougé, dans un `ubuntu:24.04` nu, puis les gates propres au dépôt (`[lane] repo` dans `clea.toml`) sur l'arbre modifié |
| cluster local | toutes les semaines, dimanche 03:41 UTC | `task local-up` sur le couple Talos / Kubernetes publié en amont, puis `task local-verify`, en 1 plan de contrôle + 1 worker |
| cloud réel | jamais | à la main, par quelqu'un qui regarde — voir [`CONTRIBUTING.md`](../CONTRIBUTING.md) |

Le scan demande aussi quand `renovate[bot]` a proposé quelque chose pour la
dernière fois. **Ce nombre seul ne veut rien dire** — un bot qui n'a rien à
proposer se tait, et il a raison. Il ne devient un signal que croisé avec ce que
Cléa a trouvé : une dépendance en retard *et* visible par l'inventaire du bot,
sans proposition depuis des jours, signifie que le bot ne tourne pas. Ce
croisement n'a pas été fait ici pendant trois semaines : helm 4.2.4 est sorti le
2026-08-13, la fenêtre planifiée du 2026-08-17 est passée, et personne ne l'a vu
avant l'écriture de Cléa. `[report] watch_bot` et `silent_after_days` dans
`clea.toml` sont toute la configuration.

`.github/workflows/clea.yml` est tout le câblage. Il ne porte aucune
identification de provider et doit échouer plutôt que d'en acquérir une.

## Où est le rapport

Une issue GitHub, étiquetée `clea`, **réécrite sur place** à chaque exécution —
jamais une nouvelle. Son corps porte aussi l'état de l'exécution précédente, dans
un commentaire HTML en fin de page : c'est ainsi qu'« ceci a bougé depuis hier »
se calcule sans stockage d'artefacts.

Une sonde pousse sa branche `clea/probe/<dépendance>` qu'elle soit verte **ou**
rouge : une branche rouge est la reproduction, et la supprimer laisserait un
rapport décrivant quelque chose que personne ne peut rejouer. `clea prune`
supprime une branche dès que sa montée de version a atterri sur `main`.

## Ce qu'un rapport vert ne dit pas

- **Rien ici n'a jamais touché un cloud réel.** Un déploiement sur Scaleway, OVH
  ou Outscale coûte de l'argent et se lance à la main.
- **Une sonde verte signifie que l'outil s'installe et se met à jour, et que les
  vérifications du dépôt passent toujours.** Elle ne dit pas que la nouvelle
  version se comporte pareil sur un cluster vivant. Pour Talos et Kubernetes,
  c'est le rôle de [`upgrade.fr.md`](upgrade.fr.md).
- **La lane hebdomadaire prouve qu'un couple démarre sur Docker en 1 + 1**, Cilium
  levé. Ce n'est ni un test de haute disponibilité ni une mise à jour tournante.

## Deux choses qui rougiront exprès

- **Une montée de Cilium ou de Flux** déplace un pin dont la *sortie* est
  committée. La lane re-génère avant de lancer les vérifications, pour que la
  branche de sonde porte les deux moitiés — mais si la génération échoue,
  `task render-check` est ce qui le dit.
- **Un outil que ce dépôt n'épingle pas** n'a aucune version à laquelle se
  comparer : sa lane de mise à jour ne peut que rapporter ce qu'elle a trouvé.
  `talosctl`, `kubectl`, l'AWS CLI, shellcheck, yamllint, checkov et pre-commit
  sont dans cet état, et les épingler est une décision à part — ouvrir une issue
  pour qui la prend.
- **`commitizen`, `opentofu/opentofu` et `siderolabs/talos`** — ancrés (aussi)
  dans `.github/workflows/ci.yml` — font échouer leur sonde avec « refusing to
  allow a GitHub App to create or update workflow… without `workflows`
  permission ». Mesuré au premier vrai passage de ce workflow, le 2026-08-24.
  `GITHUB_TOKEN` ne peut pousser ce changement dans aucun dépôt, et aucune
  permission `permissions:` ne le corrige. Un secret `CLEA_WORKFLOW_TOKEN` (PAT
  classique, scope `workflow`) referme le trou une fois posé ; sans lui, le
  rapport nomme quand même les trois plutôt que de les faire disparaître — voir
  « Probes that could not record a verdict » dans sa propre section.
  Un jeton que GitHub rejette (un PAT expiré) ne réduit pas non plus la voie au
  silence : `scripts/clea/push-probes.sh` se rabat sur `GITHUB_TOKEN`, continue
  de pousser les autres branches, et le rapport s'ouvre sur un avertissement qui
  nomme ce qu'il n'a pas pu enregistrer. Un PAT classique expire : donne-lui une
  échéance que tu verras venir.

## Le lancer à la main

    task clea-scan                         # nécessite GITHUB_TOKEN
    python3 scripts/clea/clea.py coverage  # hors-ligne, et inclus dans task lint

`task lint` lance `coverage` ; `task test-scripts` lance les assertions de Cléa.

⚠️ GitHub désactive un workflow planifié après 60 jours sans activité sur le
dépôt. Un Cléa silencieux est précisément le défaut dont parle cette page :
vérifier la date de l'issue de rapport avant de lui faire confiance.
