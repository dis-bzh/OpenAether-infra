# Registre d'audit — audits, revues, et les actions correctives qu'ils ont ouvertes

🇬🇧 [English version](audit-register.md)

> Écrit pour répondre aux règles ANSSI sur un audit périodique des mesures de sécurité et le suivi de ses actions correctives (id d'audit SCC/F11, la partie registre d'audit). C'est un **journal tenu à la main** :
> une ligne est ajoutée quand quelque chose est audité ou revu, une action quand elle est décidée, et les deux sont closes en disant ce qui a été fait et à quel palier (simulé, Docker local, vrai cloud). Il consigne
> ce qui s'est passé ; il n'est pas lui-même un contrôle. Il ne revendique aucune conformité à un document ANSSI.

## 1. Cadence

| Quoi | Quand | Qui | Production |
|---|---|---|---|
| Revue de sécurité trimestrielle | chaque trimestre, et à chaque release | le mainteneur | la check-list de `release-checklist.md` (« Quarterly security review ») ; une ligne en section 2 |
| Audit annuel | une fois par an, et après un changement de périmètre (un nouveau provider, un second mainteneur, un utilisateur réglementé) | le mainteneur, de préférence avec un lecteur qui n'a pas écrit le code | l'audit et ses constats ; des lignes en sections 2 et 3 |
| Après un incident | chaque incident clos dans `incident-response.fr.md` | le responsable d'incident | une ligne en section 2 ; des actions correctives en section 3 |
| Exercice de reprise après sinistre | chaque année (`disaster-recovery.fr.md`, section 5) | le mainteneur | son tableau de résultats ; une ligne en section 2 |

Une revue ou un audit qui ne trouve rien est quand même une ligne.

## 2. Audits et revues

| Date | Nature | Périmètre | Par | Résultat | Actions ouvertes |
|---|---|---|---|---|---|
| 2026-10 | Auto-audit face à des documents ANSSI : le guide de configuration GNU/Linux (BP-028), la note OpenSSH (NT-007), les recommandations réseau et cloud (PA-022), cryptographie et secrets (PA-079, PG-078, les annexes du RGS), le guide d'hygiène, les guides de chaîne d'approvisionnement logicielle | Les deux dépôts, neuf domaines (cryptographie et TLS, données et secrets, journalisation et détection, sauvegarde et résilience, administration et identité, réseau et cloud, système d'exploitation et bastion, chaîne d'approvisionnement et CI, plateforme) | Une revue automatisée, assistée par IA, du code et des documents avec une seconde passe cherchant à réfuter chaque constat ; commandée par le mainteneur. **Pas un audit par un tiers ni une évaluation de conformité** | Environ 130 constats confirmés (lacune, partiel, ou documentation) après réfutation ; d'autres réfutés ou laissés non vérifiés. Les preuves sont des `fichier:ligne` dans les dépôts | Le travail de durcissement listé en section 3, lot par lot ; dans la section `[Unreleased]` du `CHANGELOG.md` des deux dépôts |
| _prochaine_ | Revue de sécurité trimestrielle | | | | |

## 3. Actions correctives

Une ligne par action **décidée**, avec l'id d'audit auquel elle répond quand il y en a un. Le CHANGELOG énonce le palier de chacune ; ce tableau dit si elle est faite. Rien ci-dessous n'est publié au moment de l'écriture.

| Action | Ids d'audit | Statut | Palier atteint | Où |
|---|---|---|---|---|
| Socle OS du bastion (optionnel) | OSN/F04, F05, F07, F09, F03, TLS-15, LOG-08 | fait, désactivé par défaut | simulé + Docker local | CHANGELOG, `admin-access.fr.md` |
| Identité du bastion : opérateurs nominatifs, CA SSH, contrôle de clé matérielle, épinglage de clé d'hôte | ADM/F05, TLS-13, TLS-16, OSN/F10, NET/F16 | fait, désactivé par défaut | simulé + Docker local | CHANGELOG, `admin-access.fr.md` |
| Sortie Internet du bastion fermée (optionnel) | ADM/F06, OSN/F14, SCC/F18, NET/F04 | fait, désactivé par défaut | simulé + Docker local | CHANGELOG, `admin-access.fr.md` |
| Journaux du bastion hors de la VM | LOG-08 | fait (cron manuel) | simulé | CHANGELOG, `admin-access.fr.md` |
| Outillage de vérification (chiffrement au repos, scan d'exposition, netcheck, revue RBAC) | HYG M37/M38 | fait | simulé + une lecture de cluster | CHANGELOG, `admin-access.fr.md` |
| Chaîne d'approvisionnement : verrous de providers, voie de sommes de contrôle des images, SBOM, environnement sandbox, rulesets en code | SSDLC CICD-AIP, PROV-REC03, SCM-REC06/-07 | fait | simulé/statique | `supply-chain.fr.md` |
| Politique de correctifs et signaux | HYG-M34 | fait (un objectif, une personne) | statique | `patching.fr.md`, `hardening.fr.md` section 4 |
| Hygiène des passphrases pour l'état, les artefacts, les snapshots | PG-083, PA-079 | fait | simulé | `first-cluster.fr.md` |
| Jeu documentaire de sécurité : clés, incidents, sauvegarde, reprise, réseau, architecture, durcissement, modèle de menaces, composants, ce registre | DP-06/07/17, TLS-12/19/20, F-BKP-07/10/16, LOG-17, ADM/F11/F13, NET/F07/F09, OSN/F13 (étape 0)/F18, SCC/F11 | **fait (documents)** : rien n'y a été exécuté sur un cluster | lu face au code ; tableaux de flux vérifiés par un test | ce jeu |
| Un premier exercice de reprise et un premier exercice d'incident | F-BKP-16, LOG-17 | **ouvert** | n/a | `LAB-CHECKLIST` du travail de durcissement (B13) |
| Verrou d'objet ou versionnement sur les buckets d'état, d'artefacts, de snapshots, de sauvegardes et de journaux ; un bucket et une paire de clés propres à chaque store | F-BKP-10, F-BKP-01, F-BKP-04, LOG-07, F05, DP-05 | **en partie, optionnel** : `backup_immutability` et les paires `OA_*_S3_*` existent ; aucun provider vérifié, aucune politique de clés fournie, aucune copie verrouillée côté opérateur | mocké/statique | `backup-policy.fr.md` sections 3 et 4 |
| Identités Kubernetes nommées et de courte durée à la place du kubeconfig partagé `system:masters` | OSN/F20 | **ouvert** | n/a | `security-architecture.fr.md` |
| Filtrage réseau des nœuds : listes inter-nœuds explicites, puis pare-feu d'hôte optionnel | OSN/F13 | **ouvert** (l'étape 0 est `network.fr.md`) | n/a | `network.fr.md` section 6 |
| Socle des nœuds Talos : sysctl, arguments noyau, SELinux, secure boot | OSN/F01, F02, F03 | **ouvert** | n/a | `hardening.fr.md` section 3 |
| Combler la lacune de séquestre des clés et de second dépositaire (une seconde personne) | DP-06, TLS-20 | **ouvert**, dépend d'un second opérateur | n/a | `key-management.fr.md` section 3 |

Quand une action est faite, changer son statut et nommer le palier ; quand elle est abandonnée, dire pourquoi. Une action ouverte depuis plus d'un an sans raison dans la ligne est un constat du prochain audit.

## 4. Revue

Ajouter une ligne à chaque audit, revue, exercice et incident clos ; retrier les actions ouvertes chaque trimestre.
