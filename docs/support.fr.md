# Politique de support — quelles versions, quels providers, ce qu'un seul mainteneur peut promettre

🇬🇧 [English version](support.md)

> Écrite pour la 0.6.0 (décisions du propriétaire du 2026-11-20). Pour chaque affirmation, le barreau atteint (mocké, émulé, Docker local, cloud
> réel). Il y a un seul mainteneur, et une limite écrite ici est une limite, pas une feuille de route. Chiffres et dates : [`status.md`](status.md), pas ici.

## 0. Par défaut : aucune garantie, aucun support

OpenAether est un projet open source. **Par défaut le mainteneur ne garantit rien et ne fournit aucun support** : pas de délai de réponse, pas
d'engagement de correction, pas de rétroportage. Issues et pull requests sont bienvenues et lues quand le temps le permet. Les sections 1 et 2 sont la politique
qui **ne s'applique que si un client ou utilisateur payant existe** ; d'ici là elles décrivent ce que le projet fait et mesure, pas ce qu'il doit à quiconque.
La licence ([`LICENSE`](../LICENSE)) dit le reste.

## 1. Versions : N et N-1 seulement (politique conditionnelle)

Si un client ou utilisateur payant apparaît, le support se limite à N et N-1. Avant la 1.0.0, une « version » est un tag de release, pas un mineur. N est le dernier tag, N-1 le précédent (la 0.5.1 sortie, N-1 est la 0.5.0).

| | Ce qu'on peut attendre |
|---|---|
| **N** | Les bugs reproductibles sont corrigés sur `main` et partent dans le tag suivant. Un correctif de sécurité d'un composant épinglé suit le délai de [`patching.md`](patching.md) (30 jours, 7 si exploité ou joignable depuis Internet). |
| **N-1** | Supportée comme **point de départ d'une mise à jour** : la section « From N-1 to N » de [`upgrade.md`](upgrade.md) est le chemin. Aucune branche de rétroportage : un correctif atteint une installation N-1 en passant à N. Un rétroportage est un choix du mainteneur, jamais une promesse. |
| **Plus ancienne** | Non supportée. Aucun chemin construit ni documenté : passer par chaque release à tour de rôle, ou reconstruire. Quand N+1 sort, N-1 cesse d'être supportée le jour même. |

- **Appairage.** Infra N s'appaire avec OpenAether-apps N (défaut de `git_ref` et exemples). Les paires mixtes ne sont pas supportées.
- **Kubernetes et Talos** évoluent dans la fenêtre que `cluster/versions-guard.tf` accepte ; une paire non supportée est refusée au plan. Barreau : mocké.
- **Revue à la 1.0.0.** D'ici là la politique peut se durcir, jamais se relâcher en silence.
- **Barreau des chemins.** Chaque section « From x to y » de `upgrade.md` dit le sien. Le dernier, 0.5.0 vers 0.5.1, a été lu sur un cluster construit sur `main`
  puis amené sur la branche de correctif, **pas** sur une installation 0.5.0 amenée aux tags (`CHANGELOG.md` `[0.5.1]`). Cloud réel, n=1.

## 2. Providers : niveaux (ce qui a été mesuré ; une promesse seulement sous la condition de la section 0)

- **Supporté** : construit depuis un compte vide sur du matériel réel, `cluster-verify` vert, un roll ou une mise à jour lus. Sous la condition de la section 0, un bug reproductible est corrigé.
- **Contraint** : il tourne, avec une limite écrite qui l'empêche de porter la plateforme complète. Les tickets sont lus ; aucune promesse sur la plateforme complète.
- **Non supporté** : le code existe, rien de réel n'a tourné. Les signalements sont bienvenus, sans correction planifiée.

| Provider | Niveau | Pourquoi, et ce qui reste ouvert | Barreau |
|---|---|---|---|
| Scaleway | **Supporté** | Install depuis vide (lab 0.5.1 L1, 2026-11-15, 715 s), mise à jour 1.36→1.37 et Talos 1.13→1.14 (2026-10-03), épinglage du commit apps (lab 0.5.2, 2026-11-18). Un roll de control plane coupe l'API environ 55 s (#42) ; un primaire de base en zone perdue prend environ 2 min (#390). | cloud réel, n=1 par chiffre |
| OVH | **Supporté** | Install depuis vide (lab 0.5.1 L2, 2026-11-16, 706 s), mise à jour (2026-10-03), remplacement de worker avec 0 sonde API échouée sur 1632. Un nœud peut rester `ACTIVE` alors qu'il est mort jusqu'à un reset hyperviseur, cause côté OVH (#49). Le soak Kyverno de 24 h (#183, #83) n'a pas tourné. | cloud réel, n=1 par chiffre |
| Outscale | **Contraint** | Le quota du compte est de 20 vCPU. L'install rend rc 0 (lab 0.5.1 L3, 2026-11-16) mais sous la plateforme complète un worker est devenu inutilisable et le premier seed a expiré (#376, ouvert) ; aucun chiffre d'install nominal. Un Net qui ne se supprime pas est chez le support Outscale (#43). | cloud réel, une fois, dégradé |
| Proxmox | **Non supporté** | Jamais appliqué sur du matériel réel (#48, #201). Tests mockés ; Feint n'émule pas Proxmox. | mocké seulement |

Hors de tout niveau : le rôle `workload` sur n'importe quel cloud, `deploy_flux = true` au-delà des labs ci-dessus, et la surcouche de management CAPI. La surcouche
est optionnelle et le cycle de vie des clusters enfants n'a jamais tourné (apps #222). Non prouvé : un passage sans surveillance d'une quelconque voie.

## 3. Séquestre : un seul détenteur, pour l'instant

Aucun client n'est servi aujourd'hui : c'est une limite du projet, pas la rupture d'un engagement.

- **Accès de secours** (kubeconfig `system:masters`, talosconfig, phrase de passe des artefacts, K6) : un détenteur, le propriétaire. Décision du 2026-11-17 (#331), consignée dans [`admin-access.md`](admin-access.md).
- **Le séquestre de la clé de scellement** (`task escrow`) est conçu pour deux dépositaires et le dit quand il n'en a qu'un ([`key-management.md`](key-management.md), « Escrow: how many custodians »).
- **Un second détenteur sera nommé plus tard par le propriétaire.** D'ici là : la perte ou l'indisponibilité de cette seule personne est la perte du séquestre, et les notes de release le disent.
- Barreau : documenté. `task escrow` est testé en mocké ; aucune reprise depuis le séquestre n'a été jouée sur un cluster.

## 4. Ce qu'une release publie, et comment le vérifier

Chaque release porte, dans ses notes, le **SHA complet du commit de release** (le squash-merge sur `main` que le tag désigne) et le **SHA complet du tag
OpenAether-apps** que `git_ref` épingle. Un tag peut être remplacé de force en amont ; un SHA, non. `check-release-tag.sh --apps-sha` refuse des notes qui en manquent et
`release-tag.yml` répète le contrôle ; les notes de la 0.5.1 nomment les deux. Pour vérifier :

```bash
git verify-tag <tag>                  # clé : docs/signers/release-vps.asc, empreinte comparée à signers.txt
git rev-parse <tag>^{commit}          # doit égaler le SHA des notes
```

Pour épingler par SHA, renseigner `git_commit` (40 hex) à côté de `git_ref` ([`supply-chain.md`](supply-chain.md)). Barreau : le contrôle est mocké
(`test-check-release-tag.sh`) ; l'épinglage a été lu une fois sur un vrai cluster (Scaleway, 2026-11-18, n=1). **Non couvert :** amener un cluster en marche sur un commit
(`cluster-apps-ref` l'ignore), et une signature du SBOM ou des images (aucune vérification cosign nulle part).

## 5. Processus CVE et VEX

1. **Repérer.** Alertes de vulnérabilité Renovate, rapport quotidien de Cléa, workflow `SBOM` hebdomadaire et par tag (Trivy : un CRITICAL avec correctif fait échouer le job de scan). Voir [`patching.md`](patching.md).
2. **Délai.** 30 jours pour fusionner ou écarter par écrit, 7 si exploité (CISA KEV) ou joignable depuis Internet.
3. **Décider, un constat à la fois**, et écrire quoi : (a) **corriger** : épingler le digest corrigé ; (b) **écarter** par une déclaration VEX ; (c) **retenir** la release. Un
   écart exige une lecture de l'image et de son exposition avec ses limites dites, pas une supposition.
4. **Consigner un écart** dans `.vex/openaether-infra.openvex.json` : borné au digest de l'image, `not_affected` avec une justification, un
   `action_statement` disant ce qui le retire, `Expires:` à 90 jours au plus, et une issue qui le suit. Le propriétaire l'accepte ; le mainteneur n'accepte pas le sien.
5. **Release.** Un scan rouge n'empêche pas le SBOM d'être attaché : les notes listent chaque scan rouge et chaque écart vivant avec son échéance.
6. **Renouveler ou retirer.** Passée son échéance, un écart est un délai manqué. Relire l'image et prolonger, ou le retirer quand un digest corrigé est épinglé.

Barreau : écrit, exercé une fois (CVE-2026-123158 sur l'image kustomize-controller de Flux, repérée le 2026-11-10, écart consigné le 2026-11-15, expire le 2027-01-09, #455).
**Aucun contrôle ne fait respecter `Expires:` pour l'instant** : une personne le lit à chaque release.
