# Jour 1 — initialisation admin après `task cluster-up` (management)

🇬🇧 [English version](admin-access.md)

Les opérations manuelles post-déploiement d'un cluster portant la **plateforme
applicative**, dans l'ordre. **La 0.1.0 n'en déploie rien** — sur un cluster
d'infrastructure seule, `task cluster-verify` est tout le parcours jour-1 et rien
de ce qui suit ne s'applique. Validé sur Scaleway le 2026-07-25.
Convention : `KC=infrastructure/opentofu/cluster/kubeconfig`.

## 1. Escrow (IMMÉDIAT)

Trois secrets dans Bitwarden EU, puis effacés des sorties locales :

| Quoi | Où | Pourquoi |
|---|---|---|
| Parts Shamir (5/3) + root token | `kubectl logs -n foundation-vault job/openbao-init` (aussi Secret `openbao-recovery`) | unseal/DR OpenBao — la vérité doit être hors ligne |
| Password restic | `kubectl logs -n foundation-vault job/openbao-vault-bootstrap` (affiché UNE fois) | sans lui, backups indéchiffrables le jour où OpenBao est perdu |
| `TF_VAR_encryption_passphrase` | déjà dans ton vault | tfstate + artefacts gpg + snapshots etcd |

## 2. Signer l'intermediate PKI (débloque le HTTPS)

Le Job bootstrap affiche le CSR. Le signer **hors ligne** avec la root CA, puis :

```bash
# https, et skip-verify : le listener porte la paire auto-signée du cluster.
# Ceci indiquait `http://` jusqu'au 2026-08-14 et répondait « Client sent an HTTP
# request to an HTTPS server » — la commande telle qu'écrite ne pouvait pas
# fonctionner.
kubectl --kubeconfig $KC exec -i openbao-0 -n foundation-vault -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN=<root_token> \
  bao write pki/intermediate/set-signed certificate=@- < intermediate-signed.pem
```

`openaether-tls` passe Ready seul et le listener 443 se programme.
Runbook : `OpenAether-apps/apps/base/foundation/vault/pki-root-offline-runbook.md`.

## 3. Semer les destinations de backup

**`scripts/ops/seed-openbao.sh <provider>` fait tout ceci**, en write-if-absent :
un re-run ne peut donc pas faire tourner `backup/restic` et rendre indéchiffrable
chaque backup existant. Utilisez-le ; les commandes ci-dessous sont ce qu'il
exécute, et pourquoi.

Ce n'est pas du confort : sans `backup/s3-primary` seul, six Kustomizations
restent not-Ready et le DAG ne converge jamais — mesuré sur Scaleway le
2026-08-14, où les 35 sont passées Ready dans les deux minutes suivant le
seeding. Un déploiement n'est pas terminé tant que ceci n'a pas tourné.

Les buckets doivent **préexister** (restic ne les crée pas), sur des providers
différents en production.

```bash
bao kv put secret/backup/s3-primary endpoint=… bucket=… access_key=… secret_key=…
bao kv put secret/backup/s3-replica endpoint=… bucket=… access_key=… secret_key=…
bao kv put secret/observability/loki-s3 endpoint=… bucket=… accessKey=… secretKey=…
# Webhook entrant Slack — sans lui Alertmanager ne démarre pas, délibérément
bao kv put secret/observability/alertmanager-slack webhook-url=https://hooks.slack.com/services/…
# Sur un cluster jetable, N'IMPORTE quelle valeur convient : Alertmanager démarre, seul l'envoi échoue.
# Dead man's switch — le SEUL signal qui survit à la mort du cluster.
# Sans lui Alertmanager ne démarre pas non plus. Slack seul ? Retirer la route
# Watchdog de vm-customresources/vmalert.yaml, délibérément.
bao kv put secret/observability/alertmanager-deadmansswitch url=https://hc-ping.com/<uuid>
# Également requis (oublié au premier passage, trouvé en production le
# 2026-07-30) : les mots de passe des bases applicatives CNPG et la passphrase
# de chiffrement des volumes Longhorn. Sans eux, le Cluster grafana-db/zitadel-db
# devient quand même Ready (le bootstrap génère SON PROPRE placeholder si le
# secret est absent au moment de l'initdb) mais l'application ne peut pas s'y
# connecter — l'authentification échoue en silence jusqu'à ce que ceci soit
# semé ET que le rôle Postgres soit réaligné (ALTER ROLE ... WITH PASSWORD, une
# fois, si l'initdb a déjà tourné avec un autre placeholder).
bao kv put secret/grafana/db password=$(openssl rand -base64 24 | tr -d '=+/')
bao kv put secret/zitadel/db username=zitadel password=$(openssl rand -base64 24 | tr -d '=+/')
bao kv put secret/backup/restic password=$(openssl rand -base64 36 | tr -d '=+/')
bao kv put secret/longhorn/encryption passphrase=$(openssl rand -base64 48 | tr -d '=+/')
```

`s3-primary` alimente trois mécanismes d'un coup : restic, PITR CNPG et backups
de volumes Longhorn. **Loki a sa propre destination**, pour ne jamais avoir
d'accès en écriture au bucket des sauvegardes.

Tant que ce n'est pas semé, les ExternalSecrets restent NotReady, les CronJobs à
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

⚠️ Si ton IP publique change : mettre à jour `admin_ip` puis `task infra-apply`, sinon
le bastion devient injoignable. `admin_ip` refuse désormais une liste vide, une
adresse sans préfixe et un `/0` — c'est la liste d'autorisation devant sshd du
bastion ET devant 6443.

⚠️ **Le kubeconfig n'est pas révocable.** `talosctl kubeconfig` émet un
certificat client pour `O=system:masters`, qui court-circuite RBAC, et
Kubernetes ne sait pas révoquer un certificat client : un kubeconfig qui fuite
reste valable jusqu'à son expiration, et le seul remède est de faire tourner la
CA du cluster. Traiter ce fichier comme le secret qu'il est — il est aussi dans
le tfstate et dans les deux stores d'artefacts. Pour le travail en lecture
seule, porter moins : `task talosconfig-new PROVIDER=…` émet un talosconfig
`os:reader` qui expire en heures et ne peut pas s'en forger un d'admin (prouvé
par `task local-rbac`).

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

- [ ] Parts Shamir + root token escrowés
- [ ] Password restic escrowé
- [ ] Intermediate signé (HTTPS opérationnel)
- [ ] Buckets créés + destinations semées
- [ ] Premier snapshot testé sur les 2 destinations
- [ ] Root CA importée, tunnel testé
- [ ] (CAPI) secrets enfants posés, kubeconfig extrait
