# Jour 1 — initialisation admin après `task cluster-up` (management)

🇬🇧 [English version](admin-access.md)

Les opérations manuelles post-déploiement d'un cluster portant la **plateforme
applicative**, dans l'ordre : tout cluster construit avec `deploy_flux = true`. Un
cluster construit avec `deploy_flux = false` (le défaut) n'en exécute rien, et rien
de ce qui suit ne s'applique. Sur un cluster `deploy_flux = true`, `task cluster-up`
se termine quand même en rouge, par construction (le vérificateur affirme que Flux
est absent), et Flux reste à 29 Kustomizations sur 35 tant que le § 3 n'a pas
tourné : c'est attendu, et le § 3 est le remède.
Convention : `KC=infrastructure/opentofu/cluster/kubeconfig`.

OpenBao ne garde **ni root token ni clé de descellement dans un log ou un Secret
lisible** : il se descelle seul avec une clé statique, et ce que détiennent les
opérateurs, ce sont des parts de *recovery* (en production : chiffrées à leurs clés
PGP, via `openbao_recovery_pgp_keys`). Conception et runbooks :
`OpenAether-apps/apps/base/foundation/vault/README.md`. Cette page demande apps
0.2.0 ou plus ; un cluster encore sur apps 0.1.0 garde l'ancien bootstrap et les
anciennes instructions de l'infra 0.2.0.

Pour les commandes ci-dessous, le helper qui échange un token de ServiceAccount
contre un token OpenBao *dans le pod* (aucun token OpenBao ne traverse ton terminal) :

```bash
bao_admin() {
  kubectl --kubeconfig $KC -n foundation-vault create token openaether-admin --duration=15m \
  | kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c \
      'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=openaether-admin jwt="$(cat)")" exec bao "$@"' sh "$@"
}
```

## 1. Escrow (IMMÉDIAT)

Quatre choses hors du cluster, dans ton gestionnaire de mots de passe ou ton vault,
puis effacées des sorties locales. **Perdre la clé de seal fait perdre tous les secrets
d'OpenBao** : c'est la clé maîtresse de ses données.

| Quoi | Comment | Pourquoi |
|---|---|---|
| Clé de seal | `kubectl -n foundation-vault get secret openbao-seal-key -o jsonpath='{.data.key}' \| base64 -d \| gpg --encrypt -r <toi> -o openbao-seal-key.gpg` | DR d'OpenBao : un snapshot raft est chiffré par elle |
| Parts de recovery | `kubectl -n foundation-vault get secret openbao-recovery-shares -o yaml > openbao-recovery-shares.yaml` (chiffrées PGP : peuvent être rangées n'importe où) | root token de bris de glace et DR ; le Secret meurt avec le cluster |
| Password restic | `bao_admin kv get -mount=secret -field=password backup/restic` | sans lui, backups indéchiffrables le jour où OpenBao est perdu |
| `TF_VAR_encryption_passphrase` | déjà dans ton vault | tfstate + artefacts gpg + snapshots etcd |

Un cluster sans `openbao_recovery_pgp_keys` est un bootstrap de **développement** : une
part en clair dans `openbao-recovery-dev`, étiquetée comme telle. N'y mets rien qui compte.

## 2. Signer l'intermediate PKI (débloque le HTTPS)

Le premier passage d'`openbao-vault-bootstrap` affiche le CSR (donnée publique) :
`kubectl --kubeconfig $KC -n foundation-vault logs job/openbao-vault-bootstrap | sed -n '/BEGIN CERTIFICATE REQUEST/,/END CERTIFICATE REQUEST/p'`.
Le signer **hors ligne** avec la root CA, puis :

```bash
kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c 'cat > /tmp/int.crt' < intermediate-signed.pem
bao_admin write pki/intermediate/set-signed certificate=@/tmp/int.crt
```

`openaether-tls` passe Ready seul et le listener 443 se programme.
Runbook : `OpenAether-apps/apps/base/foundation/vault/pki-root-offline-runbook.md`.

## 3. Semer les destinations de backup

**`source .env.sh && scripts/ops/seed-openbao.sh <provider>` fait tout ceci.** Il lui faut
les clés S3 du store primaire et, quand le réplica est chez un autre cloud, celles de ce
cloud (`<CLOUD>_BACKUP_AWS_*` : le réplica s'ouvre avec les clés de celui qui le détient),
et il lit `OA_SLACK_WEBHOOK_URL` / `OA_DEADMANSSWITCH_URL` (des placeholders sont semés,
avec un avertissement, s'ils manquent). Les buckets doivent **préexister** (restic ne les
crée pas), sur des providers différents en production : le bucket des backups applicatifs
`s3-<projet>-<provider>-backups-<env>` et son jumeau `-backup` ; le script annonce le premier.

Il est **create-only** : chaque secret est écrit avec `cas=0`, donc un re-run ne peut en
écraser aucun (une valeur changée n'échoue pas, elle casse ce qui tient l'ancienne). Son
identité est le ServiceAccount `openbao-seeder` : Kubernetes délivre un token de 10 minutes,
OpenBao l'échange dans le pod contre un token dont la policy `secret-seeder` peut **créer** les
cinq chemins ci-dessous et lire leurs métadonnées, rien d'autre. Ni le token ni une valeur
n'apparaît sur une ligne de commande ; le script affiche des chemins, jamais des valeurs. Le
password restic, les mots de passe des bases et la passphrase Longhorn ne sont **pas** semés
ici : `openbao-vault-bootstrap` les génère dans OpenBao et n'en affiche aucun.

Ce n'est pas du confort : sans `backup/s3-primary` seul, six Kustomizations restent
not-Ready et le DAG ne converge jamais (mesuré sur Scaleway : 29 sur 35 tant que ce n'est
pas semé, les 35 en environ deux minutes après). Un déploiement n'est pas terminé tant que
ceci n'a pas tourné.

```text
secret/backup/s3-primary                      endpoint bucket access_key secret_key
secret/backup/s3-replica                      endpoint bucket access_key secret_key   (les clés du cloud du réplica)
secret/observability/loki-s3                  endpoint bucket accessKey secretKey     (sa propre entrée, pour pouvoir le pointer ailleurs ; le seed lui donne aujourd'hui le bucket et les clés des sauvegardes : #302)
secret/observability/alertmanager-slack       webhook-url   (sans lui Alertmanager ne démarre pas ; sur un cluster jetable, n'importe quelle valeur convient)
secret/observability/alertmanager-deadmansswitch   url      (le seul signal qui survit à la mort du cluster ; Slack seul ? retirer la route Watchdog de vm-customresources/vmalert.yaml, délibérément)
```

Les clusters semés avant ce changement gardent ce qu'ils ont (create-only) : si
`backup/s3-replica` porte les clés du primaire pour un réplica chez un autre cloud (#296),
le corriger à la main avec `bao_admin kv put -mount=secret backup/s3-replica …`.

`s3-primary` alimente trois mécanismes d'un coup : restic, PITR CNPG et backups de volumes
Longhorn. Tant que ce n'est pas semé, les ExternalSecrets restent NotReady, les CronJobs à
l'arrêt et Loki ne s'installe pas — c'est voulu. Test :
`kubectl create job --from=cronjob/openbao-snapshot test -n foundation-vault`.

## 4. Pré-vol des quotas — avant de déployer

```bash
source .env.sh
task preflight-quotas PROVIDER=outscale -- --add-vms 7 --add-cores 14 --add-ram-gb 44
```

Sort en erreur si la topologie dépasse. Ça compte : Outscale plafonne à 40 Go de
RAM alors qu'un management HA en demande 44, et le dépassement est toléré à la
création avant que toute VM suivante ne soit refusée en silence. OVH plafonne à
10 instances — le management (7) plus un seul enfant (2). Cf. `docs/status.md` ;
les options pour chaque exemple livré sont dans [`capacity.fr.md`](capacity.fr.md).

## 5. Planifier le snapshot etcd

Un raccourci de RTO, pas la sauvegarde de référence : Flux reconstruit le contenu
du cluster, ceci couvre ce qui ne vit que dans etcd.

```bash
40 3 * * * <repo>/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/<clé> >> <log> 2>&1
```

Utiliser le wrapper, pas la task directement — les raisons sont dans son en-tête.
Il tourne sur la machine qui détient le dépôt ET les credentials.

## 6. Accès admin aux UIs

La gateway est sur une **IP privée du VPC**, avec le SG du bastion limité à
`admin_ip` — rien de public. Routes :
`vault|grafana|zitadel|longhorn.openaether.local`.

```bash
# HTTPS (après l'étape 2)
ssh -i <clé bastion> -L 8443:<IP gateway>:443 bastion@<IP bastion> -N
# /etc/hosts : 127.0.0.1 grafana.openaether.local zitadel… vault… longhorn…
```

Importer la root CA dans le navigateur. Sans TLS, pour dépanner :
`./scripts/ops/local-admin-portforward.sh`.

**Ne pas utiliser le root token OpenBao au quotidien** — il n'expire pas et
n'apparaît dans aucun audit sous un nom d'humain. Deux policies nominatives
existent :

```bash
bao token create -policy=openaether-admin  -ttl=8h -display-name=<prénom>
bao token create -policy=openaether-reader -ttl=8h -display-name=<prénom>
```

`openaether-admin` couvre l'exploitation courante mais refuse explicitement
sceller, rekey et rotation — ces gestes restent au root token hors ligne,
délibérés et rares.

⚠️ Si ton IP publique change, le bastion ne te laisse plus entrer, et un simple `task infra-apply` s'arrête
à son contrôle des tunnels : ils ne peuvent pas être reconstruits avant que l'apply passe. Mettre la nouvelle
adresse dans `admin_ip` et le lancer sans le contrôle et sans la lecture de santé :
`OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true task infra-apply PROVIDER=… APPROVE=auto`. Mesuré sur
Scaleway, le 2026-10-04 : le groupe de sécurité du bastion et l'ACL du load balancer ont été mis à jour, l'apply
a pris moins de quatre minutes, SSH vers le bastion remarchait et `cluster-verify` a passé 13/13. `admin_ip`
refuse désormais une liste vide, une adresse sans préfixe et un `/0` — c'est la liste d'autorisation devant sshd
du bastion ET devant 6443.

**Le bastion reste, durci sur place (décision, #82, 2026-10-03).** Un émetteur OIDC
pour l'apiserver, une CA SSH ou un plan de contrôle WireGuard demanderaient chacun un
hôte toujours allumé hors de tout cluster. OpenAether n'a aujourd'hui qu'un opérateur,
et aucune restauration éprouvée de bout en bout sur un cloud réel (#57) : cet hôte
serait une chose de plus à garder en vie pour rien. Les quatre `bastion.tf` et
`admin_ip` restent dans le contrat provider. À rouvrir avec deux opérateurs ou plus,
ou un service à état dont la restauration a été jouée.

⚠️ **Le kubeconfig n'est pas révocable.** `talosctl kubeconfig` émet un
certificat client pour `O=system:masters`, qui court-circuite RBAC, et
Kubernetes ne sait pas révoquer un certificat client : un kubeconfig qui fuite
reste valable jusqu'à son expiration, et le seul remède est de faire tourner la
CA du cluster. Traiter ce fichier comme le secret qu'il est — il est aussi dans
le tfstate et dans les deux stores d'artefacts. Pour le travail en lecture
seule, porter moins : `task talosconfig-new PROVIDER=…` émet un talosconfig
`os:reader` qui expire en heures et ne peut pas s'en forger un d'admin (prouvé
par `task local-rbac`). Aussi joué à travers les tunnels sur un vrai cluster OVH
(2026-10-03) : `TALOSCONFIG=<ce fichier> task cluster-verify PROVIDER=…` passe 13/13
avec lui, alors que `talosctl get machineconfig` est refusé. En émettre un et le
réutiliser jusqu'à son expiration plutôt qu'un par exécution : émettre est une
écriture sur l'API Talos, et une lecture ne devrait pas en demander.

## 7. SSO Grafana via Zitadel (OIDC)

Une fois par cluster, côté Zitadel : une application **Web**, méthode **Code** +
PKCE, redirect `https://grafana.openaether.local/login/generic_oauth`, un rôle
projet `grafana-admin`, et « User Info inside ID Token » activé. Puis :

```bash
bao kv put secret/grafana/oidc client-id=… client-secret=…
```

⚠️ Le scope de rôles `urn:zitadel:iam:org:projects:roles` est **indispensable** —
sans lui Zitadel n'émet aucun claim de rôles et tout le monde retombe sur
`Viewer`. Mesuré, et déjà posé dans `apps/base/observability/grafana.yaml`.

Grafana démarre même non semé (les variables OIDC sont `optional`) : seul le
bouton Zitadel est inopérant. Le formulaire local reste actif comme filet — ne le
désactiver qu'une fois le SSO éprouvé.

## 8. Tests navigateur

Tout le reste se vérifie en ligne de commande. Ces trois points non : ils
reposent sur des redirections et des cookies. **Prérequis bloquant : l'étape 2** —
tant que l'intermediate n'est pas signé, le listener HTTPS reste
`Programmed=False`. Vérifier avec :

```bash
kubectl get gateway -n services-gateway openaether-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
```

1. **SSO Grafana** — le seul point vraiment ouvert. Le bouton doit apparaître, la
   connexion aboutir, et un compte porteur de `grafana-admin` ressortir en
   **Admin**. Si tout le monde reste `Viewer`, Zitadel émet la forme préfixée par
   l'ID de projet : décoder le token
   (`curl -H "Authorization: Bearer <token>" …/oidc/v1/userinfo | jq 'keys'`) et
   reporter cet ID dans `role_attribute_path`. La *structure* du claim, elle, est
   confirmée.
2. **UI OpenBao** derrière la gateway — valide `credentialName`, donc que la
   gateway parle en TLS **vérifié** à OpenBao. Un 503 avec `client sent an HTTP
   request to an HTTPS server` signifie que le DestinationRule n'est pas pris en
   compte.
3. **Ingress public hors tunnel** — `curl -kv --resolve
   grafana.openaether.local:443:<IP app-LB> https://grafana.openaether.local/login`,
   qui confirme le chemin LB → nodePorts 30080/30443 de bout en bout.

## 9. Enfants CAPI (si la surcouche est piochée)

Avant d'activer un fichier dans `apps/clusters/`, poser les secrets **hors git** :

```bash
kubectl create secret generic scaleway-capi-credentials -n capi-clusters \
  --from-literal=SCW_ACCESS_KEY=… --from-literal=SCW_SECRET_KEY=…
kubectl create secret generic <enfant>-substitutes -n flux-system \
  --from-literal=SCW_PROJECT_ID=…
# kubeconfig de l'enfant, généré par CAPI :
kubectl get secret <enfant>-kubeconfig -n capi-clusters \
  -o jsonpath='{.data.value}' | base64 -d > <enfant>.kubeconfig
```

⚠️ **Ne jamais modifier les values Cilium d'un enfant vivant.** L'upgrade Helm
fait rouler le CNI sur un cluster à 2 nœuds sans marge ; le 2026-07-26 les deux
edges en sont sortis dégradés. Recréer l'enfant (`task edge-down`, puis
réactiver son fichier) est plus rapide et plus sûr. Les bonnes valeurs sont déjà
dans `apps/clusters/*.yaml` et `task apps-validate` contrôle cet alignement.

Un enfant sain sur le profil `workload` affiche **19/19 Kustomizations**. Ce
compte bouge à chaque brique ajoutée au DAG — le vérifier avec
`python3 scripts/pick.py vault eso certs gateway`, ne pas lire un changement
comme une régression.

## Checklist

- [ ] Clé de seal OpenBao + parts de recovery escrowées
- [ ] Password restic escrowé
- [ ] Intermediate signé (HTTPS opérationnel)
- [ ] Buckets créés + destinations semées
- [ ] Premier snapshot testé sur les 2 destinations
- [ ] Root CA importée, tunnel testé
- [ ] (CAPI) secrets enfants posés, kubeconfig extrait
