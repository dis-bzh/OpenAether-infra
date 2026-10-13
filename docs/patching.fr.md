# Politique de correctifs — ce qui est épinglé, comment un correctif est repéré, combien de temps il peut attendre

🇬🇧 [English version](patching.md)

> Écrite pour répondre à la mesure 34 du guide d'hygiène ANSSI (id d'audit HYG-M34) :
> une politique de mise à jour définie, correctifs de sécurité appliqués sous un mois.
> Elle fixe un objectif et les signaux qui l'alimentent. Ce n'est pas une mesure : rien
> de tout cela n'a été exercé sur un cluster.

## La règle

Un correctif de sécurité publié pour un composant épinglé par ce dépôt est **fusionné,
ou écarté par écrit, sous 30 jours après sa publication.** Plus vite (objectif : 7 jours)
quand l'avis est exploité dans la nature ou touche un chemin joignable depuis Internet
(API Talos, API Kubernetes, load balancers, sshd du bastion).

Une dérogation est une issue GitHub qui nomme le composant, l'avis, la raison pour
laquelle le correctif ne peut pas passer et une **date d'expiration** ; au-delà, c'est
un délai manqué.

## Ce que ce dépôt épingle

| Épingle | Où | Mise à jour par | Appliquée à un cluster par |
|---|---|---|---|
| Providers OpenTofu | `versions.tf` | Renovate | `tofu plan` / `apply`, à la main |
| Talos, Kubernetes | valeurs par défaut de `variables.tf` | Renovate (label `cluster-version`) | `task cluster-upgrade`, [`upgrade.fr.md`](upgrade.fr.md) |
| Manifestes Cilium, Flux | `bootstrap-manifests/` | Renovate change l'épingle, `task render-manifests` régénère (`needs-regen`) | rendus au prochain bootstrap ; un cluster en marche suit `OpenAether-apps` |
| Actions CI, hooks pre-commit, versions d'outils | workflows, `.pre-commit-config.yaml`, `scripts/` | Renovate | PR fusionnée |

Les composants qui tournent sur le cluster (Istio, cert-manager, Kyverno, CNPG, Longhorn...)
sont épinglés dans `OpenAether-apps`, qui a ses propres épingles et sa relecture ; cette
page ne les couvre pas.

## Comment un correctif est repéré

1. **`vulnerabilityAlerts` et `osvVulnerabilityAlerts` de Renovate** ouvrent une PR pour
   une épingle visée par un avis publié, hors planning et sans l'âge de 7 jours (défaut
   de Renovate pour ce bloc). Elles demandent les alertes Dependabot de GitHub (actives)
   et l'autorisation de les lire pour l'App Renovate.
2. **Le rapport quotidien de Cléa** liste les avis sur les épingles en vigueur (OSV) et,
   depuis `max_minors_behind` dans `clea.toml`, toute épingle en retard de plus de deux
   versions mineures. Une épingle aussi loin est hors de ce que l'amont corrige d'ordinaire.
3. **`image-digests.yml`, chaque semaine**, passe au rouge quand un tag de contrôleur Flux bouge.
4. **`task lint`** échoue sur une `image:` épinglée par tag sans digest enregistré.

## Ce que cela ne fait pas

- Rien n'est appliqué automatiquement : chaque mise à jour est une PR relue, et Talos,
  Kubernetes et les providers passent toujours par le barreau qu'il leur faut
  ([`CONTRIBUTING.md`](../CONTRIBUTING.md)).
- Une seule personne relit et fusionne : le délai est un engagement, pas un contrôle
  avec une seconde personne derrière.
- Cléa et Renovate voient ce qui porte une ancre `# renovate:` ou un manager qu'ils
  connaissent. Un composant arrivé autrement leur est invisible.
