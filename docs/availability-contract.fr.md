# Contrat de disponibilité — ce qui est promis, ce qui a été mesuré, combien de fois

🇬🇧 [English version](availability-contract.md)

> 0.6.0 (« enterprise »). Barreau : **cloud réel, lu dans des résultats existants** ([`resilience.md`](resilience.md), [`status.md`](status.md), les résultats des labs
> 0.5.1 et 0.5.2). Rien n'a été relancé pour cette page. Ce n'est ni un SLA ni une revendication de conformité.

## Comment le lire

- **Promesse** = la cible de [`resilience.md`](resilience.md) (décisions du propriétaire). Elle vaut pour la forme HA seulement : 3 control planes et au moins
  3 workers sur trois domaines de panne. Un cluster 1 control plane + 1 worker ne promet rien ici.
- **n** = combien de fois ce drill exact a tourné chez ce provider avec les réglages livrés (grâce nœud 30 s, toleration base de données 30 s). Les runs d'un
  code antérieur sont écartés. Un chiffre vu une fois est une observation, pas un SLO.
- **Verdict** (règle de cette page, pas une statistique : trois runs ne donnent pas de percentile) : **tenu** = n ≥ 3 et tous les runs dans la cible ; **vu** =
  n de 1 ou 2, dans la cible ; **manqué** = au moins un run hors cible, avec ce qui a changé depuis ; **non mesuré**.
- Un incident fournisseur dans un run (rupture de stock, instance ACTIVE mais muette) n'est pas un chiffre de la plateforme : la section source le nomme.

## Le contrat, par provider

| Promesse (cible) | Scaleway | OVH | Outscale |
|---|---|---|---|
| Trou d'écriture base de données, nœud perdu (≤ 75 s) | **vu** : 67,1 s extinction, 68,6 s partition (n=1 chacun) | **tenu** : n=11, 49,3–74,7 s (reboot dur 4 runs 49,3–57,0 ; partition 6 runs 63,2–70,7 ; un run à 74,7, dans la cible de 0,3 s) | **manqué** : 71,6 s (n=1), mais 204,3 s avec les deux pods du plugin sur le nœud (n=1) ; leur répartition est corrigée hors ligne, non rejouée |
| Trou d'écriture base de données, zone perdue (≤ 150 s) | **vu** : 62,8–79,0 s (la source ne donne pas le nombre de runs) | **tenu** : n=3, 48,9–77,5 s | non mesuré |
| Trou d'écriture, primaire tué ou OOM (≤ 30 s) | **vu** : 9,8 s, 10,3 s (n=1 chacun) | **vu** : 10,8 s, 5,5 s (n=1 chacun) | non mesuré |
| Commits acquittés perdus (zéro) | **tenu** : 0 sur 9 runs (lab 23) | **tenu** : 0 dans chaque drill des labs 27B et 28 (environ 15 runs, non recomptés) | **vu** : 0 (n=1) |
| HTTP via le LB applicatif (plus longue série d'échecs ≤ 15 s, échecs ≤ 10 %) | **manqué** au lab 27 : partition 12,5 % / 14 s, zone 9,2 % / 11 s ; le health check a changé depuis, **non re-mesuré** | **tenu** au lab 28 : n=10, au plus 7,4 % / 7 s (poste du lab) ; une série de 13 s depuis l'intérieur du cluster est l'exception acceptée. Lab 27B, avant le changement : 3 sur 6 manqués | **vu** : 5,9 % / 3 s (n=1) |
| Trou d'API, control plane perdu (`/readyz` ≤ 15 s au total) | **manqué** pour un roll : 20 échecs sur 1054, plus longue série environ 55 s (lab 0.5.2, n=1, l'issue infra #42 reste ouverte) ; partition du leader etcd 8 sur 311, série max 2 s (n=1) | **tenu** : 9 s, 9 s, puis 11 échecs sur 310 (n=3) | **manqué** : 19 échecs en 64 s (n=1) ; le check du LB a été raccourci, **non re-mesuré** |
| Trou d'écriture RWX (accepté jusqu'à environ 100 s) | **manqué** : 89–171 s (lab 27, avant la décision du 2026-10-30) | **tenu** : 68, 75, 87, 97 s (n=4) | non mesuré |
| Remplacer un worker mort, délai jusqu'à Ready (**pas de cible**) | 378 s et 792 s (n=2) | 781 s dont 331 s d'incident fournisseur, environ 450 s sans (n=1) | non mesuré |
| Panne grise, nœud lent et avec pertes (**pas de promesse** : limite connue) | trou d'écriture 88–134 s (n=1) | 103,7–299,3 s (n=2) | non mesuré |

Lire le tableau par sa pire case : seule la colonne **OVH** a des cases à n ≥ 3, et seulement pour la base, la zone, l'API et le trou RWX. Scaleway n'a qu'une
séance sur la plupart des lignes, et **Outscale n'a qu'un lab sur un quota de 20 vCPU** (`capacity.md`) : ni l'un ni l'autre ne porte de promesse au-delà de la case.

## Ce qu'il ne couvre pas

- Une application à réplique unique : sa disponibilité est le temps de la replanifier et de rattacher son volume (ci-dessous), pas une promesse.
- Proxmox (aucun lab cloud), une topologie non HA (1 control plane), une panne grise, et les incidents du fournisseur (ruptures de stock, snapshots qui mettent
  17 minutes à devenir disponibles, instance ACTIVE qui ne répond jamais) : [`resilience.md`](resilience.md) consigne chacun tel qu'il s'est produit.

## Applications clientes avec un volume RWO

**Recommandation, pas un réglage de la plateforme :** donner à un pod qui doit quitter un nœud perdu les deux tolerations que la plateforme donne déjà à ses bases.

```yaml
tolerations:
  - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30}
  - {key: node.kubernetes.io/not-ready,   operator: Exists, effect: NoExecute, tolerationSeconds: 30}
```

Sans elles, Kubernetes ajoute 300 s : la forge a été absente 471,8 s après une coupure de zone (Scaleway, n=1). Ce que ça rapporte, mesuré sur la forge (un pod, un volume RWO) :

| Réglage | Forge absente | n |
|---|---|---|
| défaut 300 s | 471,8 s | 1 (Scaleway) |
| 30 s, politique Longhorn `do-nothing` | 341–372 s | 2 (Scaleway) |
| 30 s, politique Longhorn livrée | 85–197 s | environ 11 (OVH 9 : 85–197 s, Scaleway 2 : 174, 178 s) |

Donc : **compter en minutes, pas en secondes**, car le rattachement du volume attend le détachement de l'ancien nœud ; la toleration ne fait que ramener le début de cette attente de 300 s à 30 s.
Ne pas descendre sous 30 s : la grâce du nœud est de 30 s, une valeur plus basse évince un nœud qui a seulement raté un battement (30 minutes à 30 s : 0 battement perdu, une seule soak, OVH).
Deux réplicas sur une base ou une application sans état rendent la perte d'un nœud invisible ; un volume RWO, non.

## La garder vraie

Une case ne change qu'à partir d'un résultat de lab, avec la date et la section d'origine ; un nouveau run augmente n ou change le verdict. Les cases à bouger en premier
au lab Scaleway de la 0.6.0 : perte de nœud et de zone deux fois de plus (pour atteindre n=3), la sonde HTTP après le changement de health check, et le trou d'API d'un roll avec la sonde du lab 21.
