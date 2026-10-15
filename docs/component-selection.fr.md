# Choix des composants et registre VEX — pourquoi chaque pièce est là, comment elle est suivie, et ce qu'on dit d'une vulnérabilité qui ne s'applique pas

🇬🇧 [English version](component-selection.md)

> Écrit pour répondre aux règles ANSSI sur le choix des composants avec leurs critères de maintenance et de contact sécurité, et sur la consignation de l'exploitabilité des vulnérabilités connues (id d'audit SCC/F11, les parties
> choix des composants et VEX). Les choix ci-dessous sont ceux que ce dépôt **a déjà faits** ; la colonne « pourquoi » est ce que disent les documents du projet, pas une évaluation neuve.
> « Aucune revue tierce consignée » veut dire exactement cela : personne n'en a écrit dans ce dépôt, ce qui n'est pas la même chose que l'absence de toute revue. Ne revendique aucune conformité à un document ANSSI.

## 1. Critères

Un composant est admis quand il a (1) un moyen d'être épinglé à une version ou un digest exact, (2) un amont avec des releases dans l'année écoulée, (3) un **canal publié d'avis de sécurité**, (4) une raison d'être là que rien d'autre déjà présent ne satisfait. Il est revu quand il a deux mineures de retard (Cléa le signale), quand un avis le touche, et à chaque revue trimestrielle. Un composant qui échoue à (2) ou (3) demande une exception écrite en section 4.

## 2. Composants détenus par ce dépôt

| Composant | Rôle | Pourquoi celui-ci (d'après les documents du projet) | Canal d'avis | Épinglé dans | Revue tierce |
|---|---|---|---|---|---|
| Talos Linux | OS des nœuds | Immuable, API seule, pas de shell ni de SSH (`hardening.fr.md`) ; LUKS2 et secretbox intégrés ; une image pour tous les providers | GitHub Security Advisories de Talos et notes de version | `talos_version` (`cluster/variables.tf`), verrou sha256 des images | aucune consignée |
| Kubernetes | Orchestrateur | La plateforme de charges de travail ; la version se couple à Talos (`version-pair.tftest.hcl`) | Annonces de sécurité de Kubernetes et avis GitHub | défaut `kubernetes_version` | aucune consignée |
| Cilium | CNI (une base figée) | Politiques réseau, chiffrement WireGuard entre nœuds, remplace kube-proxy (les deux bases figées sont Cilium et Flux, `CLAUDE.md`) | GitHub Security Advisories de Cilium | `bootstrap-manifests/` (rendu), ancre Renovate | aucune consignée |
| Flux | Contrôleur GitOps (une base figée) | Applique `OpenAether-apps` à `git_ref` ; la seconde base figée | GitHub Security Advisories de Flux | `bootstrap-manifests/`, `flux-image-digests.lock` | aucune consignée |
| OpenTofu | Provisionnement | **Chiffrement de l'état** côté client (`encryption{}`) sur lequel repose la protection de l'état ; gouvernance ouverte | GitHub Security Advisories d'OpenTofu | pin du CLI (ancre Renovate) | aucune consignée |
| Providers `siderolabs/talos`, `scaleway/scaleway`, `terraform-provider-openstack/openstack`, `outscale/outscale`, `bpg/proxmox` | Talos, les clouds, Proxmox | Un module par provider derrière un contrat (`provider-contract.md`) | avis GitHub de chaque projet ; le registre | `.terraform.lock.hcl` (empreintes) | aucune consignée |
| Ubuntu + OpenSSH + nftables + auditd | Le bastion | Un hôte conventionnel pour le seul endroit qui doit rester joignable ; cloud-init existe chez chaque provider | Ubuntu Security Notices (USN), notes de version d'OpenSSH | l'id d'image du bastion ; mises à jour par `unattended-upgrades` ou remplacement | aucune consignée |
| gpg, CLI `aws`, `restic`... sur la machine de l'opérateur | Chiffrement côté client et accès S3 | Déjà sur chaque poste d'opérateur ; `setup.sh` les vérifie | chaque projet | `scripts/internal/install-*.sh` pour ce qui est installé | aucune consignée |
| Renovate, Cléa, gitleaks, Trivy, actionlint, shellcheck, yamllint, tflint, checkov | Mises à jour de dépendances et contrôles | Voir `clea.fr.md`, `supply-chain.fr.md`, `CONTRIBUTING.md` | chaque projet | workflows, `.pre-commit-config.yaml`, lint des pins d'outils | aucune consignée |

Les composants d'`OpenAether-apps` (Istio, cert-manager, CNPG/PostgreSQL, OpenBao, External Secrets, Kyverno, Longhorn, Zitadel, VictoriaMetrics, Loki, Alloy, Grafana, restic) y sont choisis et épinglés ;
leurs dates de fin de support sont dans `OpenAether-apps/docs/eol-calendar.md` (travail ANSSI apps). Cette page ne les répète pas. Une brique ajoutée à la plateforme demande une ligne dans les documents du dépôt apps et un nom sur la liste de veille de `hardening.fr.md`, section 4.

**Les dates de fin de support des pins d'infrastructure** (Talos, Kubernetes, Cilium, Flux, OpenTofu) ne sont pas consignées dans ce dépôt : les lire sur les pages de support amont à chaque revue trimestrielle et noter dans `audit-register.fr.md` tout pin à moins de six mois de sa fin. Un tableau des versions supportées tenu ici vieillirait plus vite qu'il ne serait lu.

## 3. Le registre VEX

Quand un scanner (Trivy sur les images de bootstrap, le job SBOM) signale une vulnérabilité qui **ne s'applique pas** ici, on le dit dans une déclaration lisible par machine plutôt que d'ignorer le résultat ou de baisser le scanner.

- **Fichier** : `.vex/openaether-infra.openvex.json` (OpenVEX 0.2.0). Il ne contient aujourd'hui **aucune déclaration** (version 1, écrit le 2026-10-13) : rien n'en a encore demandé. Le scan hebdomadaire ne le lit que lorsqu'il a une déclaration
  (`.github/trivy-image-vex.yaml` est ce qu'on donne à Trivy), car un fichier vide rend le travail du scan plus difficile, pas plus facile.
- **Une déclaration** nomme le produit (un package URL), l'id de vulnérabilité, un statut (`not_affected`, `fixed`, `affected`, `under_investigation`), et pour `not_affected` l'une des justifications d'OpenVEX
  (`component_not_present`, `vulnerable_code_not_present`, `vulnerable_code_not_in_execute_path`, `vulnerable_code_cannot_be_controlled_by_adversary`, `inline_mitigations_already_exist`) avec un énoncé d'impact qu'un lecteur peut vérifier.
- **Règle** : pas de déclaration sans la preuve dans la pull request (le chemin de code, le drapeau, la configuration qui la rend inapplicable) ; elle est relue comme du code ; elle expire avec le pin : quand le composant est mis à jour, ses déclarations sont relues.
  Un résultat qui s'applique n'est **pas** une affaire VEX : c'est un correctif ou un report écrit avec une échéance (`patching.fr.md`).

**Registre de tri** (une ligne par résultat de scanner qui a demandé une décision ; la déclaration elle-même vit dans le JSON, le raisonnement ici ou dans la pull request) :

| Date | Composant | Vulnérabilité | S'applique ? | Décision | Preuve | Expire / relu |
|---|---|---|---|---|---|---|
| _aucun encore_ | | | | | | |

## 4. Exceptions aux critères

Aucune consignée. Un composant sans canal d'avis ou sans release depuis un an va ici avec la raison, la mesure compensatoire et une date de revue.

## 5. Revue

Chaque trimestre avec la check-list (`release-checklist.md`) ; quand un composant est ajouté, remplacé ou en retard de deux mineures ; après un avis qui touche une ligne.
