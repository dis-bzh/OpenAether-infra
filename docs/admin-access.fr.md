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
0.1.1 ou plus ; un cluster encore sur apps 0.1.0 garde l'ancien bootstrap et les
anciennes instructions de l'infra 0.2.0.

Pour les commandes ci-dessous, le helper qui échange un token de ServiceAccount
contre un token OpenBao *dans le pod* (aucun token OpenBao ne traverse ton terminal) :

```bash
bao_admin() {
  kubectl --kubeconfig $KC -n foundation-vault create token openaether-admin --duration=15m \
  | kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c \
      'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=openaether-admin jwt=-)" exec bao "$@"' sh "$@"
}
```

## 1. Escrow (IMMÉDIAT)

Quatre choses hors du cluster, dans ton gestionnaire de mots de passe ou ton vault,
puis effacées des sorties locales. **Perdre la clé de seal fait perdre tous les secrets
d'OpenBao** : c'est la clé maîtresse de ses données.

| Quoi | Comment | Pourquoi |
|---|---|---|
| Clé de seal | `kubectl -n foundation-vault get secret openbao-seal-key -o jsonpath='{.data.key}' \| base64 -d \| gpg --encrypt -r <toi> -o openbao-seal-key.gpg` | DR d'OpenBao : un snapshot raft est chiffré par elle |
| Parts de recovery | `for i in 1 2 3; do kubectl -n foundation-vault get secret openbao-recovery-shares -o jsonpath="{.data.share-$i}" \| base64 -d > openbao-share-$i.b64; done` (chiffrées PGP : peuvent être rangées n'importe où) | root token de bris de glace et DR ; le Secret meurt avec le cluster |
| Password restic | `bao_admin kv get -mount=secret -field=password backup/restic` | sans lui, backups indéchiffrables le jour où OpenBao est perdu |
| `TF_VAR_encryption_passphrase` | déjà dans ton vault | tfstate (+ artefacts gpg + snapshots etcd, sauf si `TF_VAR_artifact_passphrase` est défini) |

Un cluster sans `openbao_recovery_pgp_keys` est un bootstrap de **développement** : une
part en clair dans `openbao-recovery-dev`, étiquetée comme telle, qui ne peut pas devenir un bootstrap de production (réinitialiser).
N'y mets rien qui compte. `task cluster-up` vérifie, avant de facturer, que chaque clé a une sous-clé de chiffrement utilisable et affiche
son empreinte : compare-la à la tienne (`scripts/internal/check-openbao-keys.sh <fichier env>` lance la même vérification seule).

## 2. Signer l'intermediate PKI (débloque le HTTPS)

Le premier passage d'`openbao-vault-bootstrap` range le CSR (donnée publique) dans KV, car le Job et son log sont supprimés
une heure après sa fin et la signature hors ligne prend plus longtemps. Le lire avec l'assistant admin ci-dessus :
`bao_admin kv get -field=csr secret/pki/intermediate-csr > intermediate.csr`.
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
Avec `backup_immutability` dans le tfvars, `ensure-buckets.sh` crée aussi cette paire (et versionne ou verrouille les buckets : `backup-policy.fr.md`, section 3).

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
secret/observability/loki-s3                  endpoint bucket accessKey secretKey     (son propre bucket, `s3-<projet>-<fournisseur>-logs-<env>`, créé par `ensure-buckets.sh` ; ses propres clés si tu les donnes, voir ci-dessous)
secret/observability/alertmanager-slack       webhook-url   (sans lui Alertmanager ne démarre pas ; sur un cluster jetable, n'importe quelle valeur convient)
secret/observability/alertmanager-deadmansswitch   url      (le seul signal qui survit à la mort du cluster ; Slack seul ? retirer la route Watchdog de vm-customresources/vmalert.yaml, délibérément)
```

**Loki a son propre bucket (#302).** Le seed pointe `observability/loki-s3` sur `s3-<projet>-<fournisseur>-logs-<env>`, que
`ensure-buckets.sh` crée à côté du bucket des artefacts (un cluster existant le crée à la main). Loki reçoit les clés du store
primaire, sauf si tu exportes **les deux** `OA_LOKI_S3_ACCESS_KEY_ID` et `OA_LOKI_S3_SECRET_ACCESS_KEY` : une paire qui atteint ce
bucket et rien d'autre, créée avec les outils de ton fournisseur (ses clés S3 sont par défaut valables pour tout le compte). Avec les
clés partagées, le bucket séparé protège les sauvegardes d'une erreur de Loki, **pas** d'un Loki compromis, et le script le dit.
Un cluster semé avant ce changement garde une entrée Loki qui pointe sur le bucket des sauvegardes (create-only).

**Les sauvegardes peuvent aussi avoir leurs propres paires.** Exporter **les deux** `OA_BACKUP_S3_ACCESS_KEY_ID` / `OA_BACKUP_S3_SECRET_ACCESS_KEY` (pour `backup/s3-primary`) et, pour le
jumeau `-backup` sur le store du réplica, `OA_BACKUP_REPLICA_S3_ACCESS_KEY_ID` / `OA_BACKUP_REPLICA_S3_SECRET_ACCESS_KEY`, chacune limitée à son bucket (la forme : `backup-policy.fr.md`,
section 4). Sans elles, le cluster détient les clés de l'opérateur, qui ouvrent aussi les buckets d'état, d'artefacts et de journaux, et le script le dit. `scripts/ops/s3-isolation-check.sh <tfvars>`,
avec les mêmes variables exportées, montre qui ouvre quoi. Pour changer une entrée qui existe, la poser par `bao_admin kv put`, puis relancer l'ExternalSecret.

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

Le chemin d'administration atteint la gateway sur une **IP privée du VPC**, par le bastion (son groupe de sécurité est limité à
`admin_ip`). Routes : `vault|grafana|zitadel.openaether.local`, et `longhorn.openaether.local` seulement là où la route Longhorn a été ajoutée à la main (elle n'a
pas d'authentification et n'est pas dans la kustomization par défaut).

⚠️ **Ce chemin privé n'est pas toute l'exposition.** Avec `deploy_app_lb = true`, le load balancer applicatif transmet les ports publics 80/443 vers les NodePorts de la même
Gateway, sans filtre de source : chaque route répond alors à quiconque pose son en-tête Host, et la connexion propre à la route est sa seule protection
(le registre est `OpenAether-apps/docs/public-exposure.md` ; le tableau du filtrage est [`network.fr.md`](network.fr.md), section 6). Désactivé par défaut.

**Filtre de source optionnel, `app_lb_allowed_cidrs`** (une liste de CIDR IPv4, vide = pas de filtre = ce que faisait un cluster avant son existence). Renseignez-la dans les tfvars et lancez le `tofu plan` habituel :
le plan doit montrer une **mise à jour en place** des frontaux Scaleway / listeners OVH (ou de nouvelles règles Outscale) et aucun `must be replaced` : un load balancer remplacé change l'IP publique.
La liste doit contenir tous les clients publics à conserver (un bureau, un runner CI, une sonde de disponibilité) ; l'adresse de sortie du cluster est ajoutée pour vous, car les pods joignent
`https://zitadel.openaether.local` par le load balancer. Déployez par étapes : vide, puis `["0.0.0.0/0"]` (mécanisme actif, encore ouvert : le plan montre la mise à jour en place),
puis vos CIDR sur UN provider, vérification, puis les autres. Le retour arrière est la liste vide. Non exécuté sur un cloud : les contrôles sont dans la checklist de laboratoire ; il filtre des adresses et n'authentifie rien.

```bash
# HTTPS (après l'étape 2)
ssh -i <clé bastion> -L 8443:<IP gateway>:443 bastion@<IP bastion> -N
# /etc/hosts : 127.0.0.1 grafana.openaether.local zitadel… vault…
```

Importer la root CA dans le navigateur. Sans TLS, pour dépanner :
`./scripts/ops/local-admin-portforward.sh`.

**Il n'y a pas de root token OpenBao à utiliser au quotidien** : il est révoqué à l'amorçage, et un jeton de secours demande un quorum de porteurs de parts de
récupération (apps `vault/README.md`). Une personne nommée travaille par une identité de ServiceAccount, échangée dans le pod contre un jeton qui dure quelques heures : `bao_admin`
ci-dessus est `openaether-admin` ; l'identité en lecture seule est le même assistant avec le ServiceAccount et le rôle `openaether-reader` :

```bash
bao_reader() {
  kubectl --kubeconfig $KC -n foundation-vault create token openaether-reader --duration=15m \
  | kubectl --kubeconfig $KC -n foundation-vault exec -i openbao-0 -- sh -c \
      'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=openaether-reader jwt=-)" exec bao "$@"' sh "$@"
}
```

`openaether-admin` couvre l'exploitation courante mais refuse explicitement sceller, rekey, rotation de clé, émission de jetons et écriture de politiques, de montages ou de rôles — cela reste au
quorum des parts de récupération (ou à git, pour la configuration), délibéré et rare. Les chemins d'administration et qui les détient : [`security-architecture.fr.md`](security-architecture.fr.md).

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
ou un service à état dont la restauration a été jouée. (Des options pour plusieurs opérateurs, une AC SSH que le bastion
approuve et une sortie Internet fermée sont venues après ; aucune n'opère une AC ni ne rend le bastion éphémère.)

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

**Revue à chaque changement de personnel.** Quand quelqu'un arrive ou part, lancer `task rbac-review` (un `kubectl` en
lecture seule, `KUBECONFIG` posé) : il liste chaque binding et ses sujets dans `rbac-review/rbac-review-<date>.tsv` et signale
un User/Group nommé, un binding anonyme et un `cluster-admin` hors liste d'autorisation (celle de `cluster-security-tests.sh`
3.7). Aujourd'hui la réponse attendue est « rien de signalé » : l'accès humain est le certificat partagé ci-dessus, donc une
ligne signalée est une décision à consigner ou un binding à supprimer. Révoquer une personne reste faire tourner la CA ; la
revue ne fait que trouver ce qui d'autre lui donne accès.
Côté réseau, `task cluster-exposure PROVIDER=…` sonde les adresses publiques (à lancer une fois depuis une adresse absente de
`admin_ip` avec `FROM=denied` : 22 et 6443 doivent alors être fermés) et `task cluster-netcheck PROVIDER=…` envoie du trafic que
les politiques doivent rejeter. `task cluster-security` accepte `ENVIRONMENT=prod` pour échouer sur un Secret `openbao-recovery-dev`.

### Socle OS du bastion (optionnel, `bastion_baseline`)

Désactivé par défaut : le cloud-init est identique à l'octet à celui de 0.1.0. Pour l'activer, dans le tfvars :

```hcl
bastion_baseline = { enabled = true }   # + audit_logging (défaut true), restrict_ssh_source, time_servers, revoked_keys
```

⚠️ **Cela change le `user_data` du bastion, ce qui remplace la VM sur OVH et Outscale** (nouvelle IP publique, nouvelle clé
d'hôte, les tunnels Talos tombent avec) et sur Scaleway et Proxmox le plan tranche (cloud-init ne tourne qu'au premier démarrage : une VM en marche garde l'ancien jusqu'à
sa recréation) : le lire. L'appliquer sur un cluster neuf ou
dans une fenêtre prévue, jamais pendant un bootstrap ou une montée de version, avec une seconde session ou la console du
provider ouverte. Lire le plan : le bastion doit être la seule chose remplacée.

Ce qu'il ajoute, chaque point nommé par l'exigence ANSSI qu'il adresse (BP-028 est le guide GNU/Linux, NT-007 celui de SSH,
NT-006 celui du filtrage ; rien ici ne revendique la conformité) : sysctl (R9, R11, R12 sans les options ARP, R14), auditd avec
des règles execve, `/etc`, mount, modules et ptrace et sans `-e 2` (R73), un journald persistant plafonné à 200 Mo / 90 jours,
`LogLevel VERBOSE` et un second fichier sshd avec les directives que demandent NT-007 R14/R15/R23, `authorized_keys.d`
appartenant à root (R50), `/var/tmp` noexec (R28), `/boot` en 700 (R29), umask 0077 (R36), sudo réservé à son groupe et l'utilisateur du bastion hors de ce groupe (R38), ni
tcpdump ni netcat (R58, nouvelles VM seulement), et dans le nftables de la VM : les rejets journalisés et l'ICMP limité à
echo-request et fragmentation-needed (NT-006 R3/R6). `restrict_ssh_source = true` limite aussi le port 22 à `admin_ip` dans la VM
(Proxmox n'a pas de security group), mais `admin_ip` entre alors dans le user_data : le changer remplace le bastion, et un
bastion en marche garde l'ancienne liste - à laisser désactivé là où ce n'est pas acceptable. Le port 22 reste 22 : le security
group du cloud est la vraie liste d'autorisation, et les tunnels (`talos-tunnels.sh`) comme ce guide l'utilisent ; la clé,
l'utilisateur et les redirections `PermitOpen` ne bougent pas.

`time_servers` remplace le service de temps de l'image par chrony sur ces serveurs. `revoked_keys` est **la procédure de
départ** : retirer la clé de `bastion_ssh_keys` ET la lister ici, pour qu'elle soit refusée même sur un bastion non reconstruit.
Changer l'un ou l'autre remplace le bastion, comme ci-dessus. Associer chaque clé à une personne dans un fichier tenu à côté du
tfvars (`ssh-keygen -lf <clé>.pub` donne l'empreinte que porte la ligne de connexion `Accepted publickey ... SHA256:<empreinte>`).

Les journaux meurent avec la VM : `scripts/ops/bastion-logs-pull.sh <ip> bastion <clé>` copie le journal (ssh, sudo, rejets nft ;
incrémental) et le journal d'audit hors de la VM, chiffrés si `OA_LOGS_PASSPHRASE` est posée, et avec `OA_LOGS_UPLOAD=1` déposés dans le bucket d'artefacts des deux stockages objet
(section suivante). Les pistes d'audit côté cloud et le syslog d'un hôte Proxmox sont à part et rien ici ne les exporte.

Vérifier un bastion déployé avec `BASTION_BASELINE=1 scripts/ops/bastion-harden-check.sh <ip> bastion <clé> [<ip nœud>]`. Avant
de dépenser quoi que ce soit, `task bastion-baseline-check` exécute les fichiers rendus sur Ubuntu 22.04 et 24.04 dans Docker
(une vraie connexion sshd, les tunnels via `PermitOpen`, les clés révoquées, les règles de pare-feu chargées, les noms sysctl,
la syntaxe des règles d'audit).

### Identité, clé d'hôte et sortie Internet du bastion (optionnel)

Quatre options indépendantes, toutes désactivées par défaut : un cluster qui n'en règle aucune garde le cloud-init identique à
l'octet (empreinte épinglée dans `test-cluster-checks.sh`). Barreau atteint : mocké (`task test`, les harnais à stubs) et Docker
local (`task bastion-identity-check` : un vrai sshd et un vrai nftables sur Ubuntu 22.04 et 24.04). **Rien de tout cela n'a encore
tourné sur une image cloud.** Comme le socle, chaque option qui change `user_data` remplace le bastion sur OVH et Outscale
(nouvelle clé d'hôte) et est ignorée par une instance en marche ailleurs : appliquer dans une fenêtre prévue, jamais pendant un
bootstrap ou une montée de version. Sur Proxmox elles ne touchent que la VM bastion (`enable_bastion = true`) ; le chemin par défaut
(l'hôte sert de bastion) n'est pas touché.

**Opérateurs nommés (`bastion_admins`).** `bastion_ssh_keys` et le compte partagé `bastion` restent : c'est le chemin
d'automatisation et de secours (CI, `auto_tunnels`, la clé de `bootstrap-phase2`). Chaque entrée ci-dessous est un compte unix de
plus dans `bastion-admins` (pas de sudo, pas de mot de passe, son propre `/etc/ssh/authorized_keys.d/<nom>`), si bien que la ligne de
connexion de sshd nomme une personne :

```hcl
bastion_admins = {
  alice = { ssh_keys = ["sk-ssh-ed25519@openssh.com AAAA… alice-token"] }
  dave  = { ssh_keys = [] }          # uniquement par certificat : demande bastion_ssh_ca_public_key
}
bastion_require_hardware_key = true  # toute clé de bastion_admins doit être sk-* ; bastion_ssh_keys n'est PAS vérifiée
```

Se connecter en tant que personne : `SSH_USER=alice task tunnels-up PROVIDER=… KEY=…` (`talos-tunnels.sh` lit `SSH_USER` ; le
`bastion_user` de l'état reste le compte partagé, que les tunnels du single-apply gardent aussi). `bastion_require_hardware_key`
est une vérification au plan seulement : elle ne peut pas rendre le compte partagé adossé à un matériel (une clé de CI ne touche
pas un jeton), donc restreindre qui détient cette clé. Pour un PIN à chaque usage, générer la clé avec
`ssh-keygen -O verify-required` et mettre l'option `verify-required` devant la ligne de clé (la validation accepte un préfixe
d'options) ; aucun jeton FIDO n'était disponible pour le tester. `scripts/ops/bastion-fingerprints.sh` affiche
`compte / empreinte / type / commentaire` pour chaque clé de l'état (`tofu output bastion_access_keys`) : `--find SHA256:…` répond à
« à qui est la clé de cette connexion ». Principals SSH-CA : un certificat d'opérateur nommé doit porter **le nom du compte** comme
seul principal, donc il ne sert pas à se faire passer pour une autre personne (prouvé sur un vrai sshd).

**Départ d'une personne.** `user_data` n'est lu qu'au premier démarrage : retirer quelqu'un du tfvars ne change rien sur un bastion
en marche. Par ordre de préférence :

1. **Certificats de courte durée.** Poser `bastion_ssh_ca_public_key` (le `.pub` de l'AC, une ligne) et ne donner aucune clé aux
   opérateurs (`ssh_keys = []`). Signer pour une journée de travail :
   `ssh-keygen -s <ca> -I alice-$(date +%F) -n alice -V +8h -O permit-port-forwarding alice.pub` (garder `permit-port-forwarding` :
   sans lui la connexion marche et tout tunnel `-L` est refusé). Le départ, c'est *ne plus signer* ; l'accès s'arrête en 8 heures
   au plus et aucun bastion ne change. La clé privée de l'AC devient le joyau : la garder hors ligne ou dans le moteur SSH
   d'OpenBao avec le même TTL maximal de 8 h. Rien ici n'opère l'AC.
2. **Remplacer le bastion** (`tofu apply -replace=<adresse>`, voir le paragraphe sur les correctifs) avec la personne retirée de
   la table et, avec `bastion_baseline`, sa clé listée dans `revoked_keys`. Mesuré : une clé de `revoked_keys` est refusée ET tout
   certificat émis pour cette clé l'est aussi ; révoquer une personne laisse les autres entrer.
3. Une clé d'opérateur compromise, c'est le cas 2 plus un regard sur la sortie de `bastion-logs-pull.sh` pour savoir ce qu'elle a fait.

L'exercice joué hors ligne (`task bastion-identity-check`) : une clé de `revoked_keys` est refusée pendant que les autres opérateurs
entrent encore, et un certificat de 8 h expiré (`-V -2h:-1h`) est refusé. Sur un vrai bastion il n'a pas été joué.

**Clé d'hôte du bastion (`OA_BASTION_PIN_HOSTKEY`).** La clé d'hôte naît sur la VM : on ne peut pas la connaître avant le premier
contact. Les clés d'hôte privées ne sont volontairement **pas** injectées par cloud-init (elles se retrouveraient dans l'état et le
user_data). Ce que les scripts peuvent faire : garder la clé une fois vue et refuser toute autre :

```bash
OA_BASTION_PIN_HOSTKEY=1      task tunnels-up PROVIDER=… KEY=…   # premier contact accepté UNE fois, empreinte affichée ; ensuite strict
OA_BASTION_PIN_HOSTKEY=verify OA_BASTION_HOSTKEY_FP=SHA256:… task tunnels-up …       # un premier contact est refusé si cette empreinte ne correspond pas
```

Lire l'empreinte hors bande : cloud-init affiche les clés d'hôte de la nouvelle VM (un bloc
`-----BEGIN SSH HOST KEY FINGERPRINTS-----`) sur la console de l'instance, que le provider montre comme journal de console ou série
quand il en a un (savoir si chacun des quatre le fait, et à quel moment du démarrage, est une vérification de labo). La clé est gardée
dans `.talos-bastion-known-hosts` (ignoré par git), une entrée par adresse de bastion, écrite seulement après une connexion
réussie, donc une fois cloud-init terminé. Un bastion remplacé qui **réutilise son adresse publique** (le cas courant : l'IP est
sa propre ressource) présente une nouvelle clé et est **refusé** ; une fois la nouvelle empreinte vérifiée,
`OA_BASTION_FORGET=1 OA_BASTION_HOSTKEY_FP=SHA256:… task tunnels-up …` l'épingle de nouveau. Sans la variable rien ne change : le
fichier est vidé à chaque lancement et la première clé acceptée, comme avant. `bastion-harden-check.sh` et `bastion-logs-pull.sh`
ne prennent plus une clé à l'aveugle non plus (le contrôle utilisait `StrictHostKeyChecking=no`) : ils utilisent le fichier épinglé
quand il contient le bastion, sinon affichent l'empreinte, et `OA_BASTION_HOSTKEY_FP` fait échouer le contrôle sur une différence.
Un *certificat* d'hôte de l'AC SSH supprimerait l'étape du premier contact ; il n'est pas fait.

**Fermer la sortie Internet (`bastion_internet_egress`).** Le nftables et le security group du bastion laissent passer 80/443
vers n'importe quelle adresse (`unattended-upgrades` en avait besoin). Pour l'activer :

```hcl
bastion_internet_egress = {
  mode        = "closed"
  dns_servers = ["<IP du résolveur du provider>"]   # optionnel : DNS vers elles seules ; vide = DNS ouvert vers toute adresse
  ntp_servers = ["<IP du serveur NTP>"]             # optionnel, adresses seulement : une source chrony par NOM donne des adresses que ceci ne peut pas lister
}
```

Fermé veut dire : plus de 80/443 dans le pare-feu de la VM ni dans le security group (Scaleway, OVH, Outscale), la règle vers le
cluster se réduit à TCP 6443 et 50000 sur le vrai sous-réseau du cluster (Scaleway : le sous-réseau réellement utilisé par le
réseau privé, pas tout le 172.16.0.0/12 ; OVH : le CIDR de la ressource sous-réseau, pas un littéral ; Outscale : le Net), l'ICMP
seulement dans ce sous-réseau, **8200 disparaît** du pare-feu et de `PermitOpen` (rien dans ce dépôt ni dans OpenAether-apps ne
redirige 8200 par le bastion ; OpenBao s'atteint avec `bao_admin` et des port-forward), les adresses du service de métadonnées
restent joignables sur le port 80 (cloud-init et les agents du provider en ont besoin), et `curl`, `netcat`, `tcpdump`,
`unattended-upgrades` ne sont ni installés ni activés. Le premier démarrage n'est pas touché : les paquets sont installés avant
l'activation du pare-feu. Le bastion Proxmox n'a pas de security group : seules les règles dans la VM s'y appliquent.

**C'est le compromis : un bastion fermé ne se met pas à jour sur place.** On le corrige en le remplaçant, à échéance ou sur avis de
sécurité : fermer les tunnels (`scripts/bootstrap/talos-tunnels.sh close`), puis `tofu apply -replace=<adresse>` avec l'adresse de la
ressource d'instance `…bastion` du module provider (`module.scw[0].scaleway_instance_server.bastion`,
`module.ovh[0].openstack_compute_instance_v2.bastion`, `module.outscale[0].outscale_vm.bastion`,
`module.proxmox[0].proxmox_virtual_environment_vm.bastion[0]`), jamais pendant un bootstrap ou une montée de version (les tunnels
tombent avec). L'IP publique est sa propre ressource et survit ; la clé d'hôte non (voir plus haut). Une chaîne d'image préparée puis
remplacée ou un hôte de rebond éphémère ne sont pas construits. Pour rouvrir la sortie le temps d'une fenêtre, remettre le mode à
`legacy` et remplacer le bastion. `BASTION_EGRESS=closed scripts/ops/bastion-harden-check.sh …` vérifie le résultat (80, 443, une
autre adresse publique et 8200 refusés, outils absents, minuteurs de mise à jour éteints) ; sans la variable le contrôle attend l'état
legacy, où 80/443 sont ouverts par construction (il attendait le port 80 bloqué, ce que les règles livrées n'ont jamais fait).

**Journaux hors de la VM et qui se cache derrière une connexion.** `scripts/ops/bastion-logs-pull.sh <ip> <utilisateur> <clé>` tire le
journal (ssh, sudo, rejets nft) et le journal d'audit, chiffrés avec `OA_LOGS_PASSPHRASE`. Avec `OA_LOGS_UPLOAD=1` il les dépose aussi
dans le bucket d'artefacts des deux stockages objet sous `backups/bastion-logs/`, le curseur du journal servant de filigrane gardé
là aussi (un tirage depuis une autre machine reprend où le dernier s'est arrêté ; un stockage en panne est ré-essayé, pas sauté).
Le lancer par cron ou CI, chaque jour ; entre deux tirages les journaux vivent sur la VM et ne sont pas inviolables. Relire un
fichier : `gpg -d journal-<ts>.export.gpg | systemd-journal-remote -o r.journal -` puis `journalctl --file r.journal` (vérifié sur un
export fabriqué à la main ; le premier vrai est une étape de labo). Garder la sortie de `scripts/ops/bastion-fingerprints.sh` avec les
journaux : la ligne de connexion porte l'empreinte de la clé, la table dit à qui elle est. Les pistes d'audit côté cloud (Scaleway
Audit Trail, OVH Activity logs, journaux d'API d'Outscale) et le syslog d'un hôte Proxmox ne sont exportés par rien ici : tant que
personne n'en est responsable, les exporter à la main pour la durée de conservation voulue et les ranger chiffrés à côté des journaux
du bastion ; qui peut modifier l'IAM et les security groups fait partie de la même question.

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
