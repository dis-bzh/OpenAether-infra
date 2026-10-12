# Amorcer un cluster de management par CAPI (pivot depuis le local)

🇬🇧 [English version](capi-bootstrap.md)

Validé de bout en bout sur Scaleway le 2026-07-28 — avant le recentrage, et **la
0.2.0 ne déploie aucun CAPI** : ceci est conservé pour la version qui le fera.
Chemin **optionnel**, à côté
d'OpenTofu — pas un remplacement : CAPI crée les machines, OpenTofu garde le
substrat (sur OVH, ~44 ressources dont 3 instances).

```
local (Talos/Docker) ──CAPI──▶ mgmt-capi ──CAPI/GitOps──▶ edge-capi
        └── clusterctl move ──▶ mgmt-capi s'autogère, le local est détruit
```

## Prérequis

Moteur Docker joignable · `clusterctl` à la version du CoreProvider (v1.13.2) ·
image Talos publiée chez le provider (les images Scaleway sont par zone) ·
credentials dans `.env.sh`.

## 1. Cluster jetable + CAPI

```bash
task local-up
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig

# Vérifier l'egress d'abord — sans lui le contrôleur du provider ne crée rien.
kubectl run egress-test --image=curlimages/curl:8.11.1 --restart=Never --command -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://api.scaleway.com/instance/v1/zones

clusterctl init --core cluster-api:v1.13.2 --bootstrap talos:v0.6.12 \
                --control-plane talos:v0.5.13 --infrastructure scaleway:v0.2.1
kubectl create namespace capi-clusters
kubectl -n capi-clusters create secret generic scaleway-capi-credentials \
  --from-literal=SCW_ACCESS_KEY="$SCW_ACCESS_KEY" \
  --from-literal=SCW_SECRET_KEY="$SCW_SECRET_KEY"
```

`clusterctl init`, pas nos briques : l'opérateur exige une HelmRelease, l'egress
du cluster et cert-manager — trop lourd pour un cluster qu'on jette.
⚠️ Les versions doivent être identiques aux nôtres, sinon `clusterctl move`
refuse la cible.

## 2. Créer et équiper le management

Même template qu'un enfant. Hors Flux, le rendre avec `flux envsubst` (il gère
les défauts `${VAR:=…}`, contrairement à `envsubst`).

```bash
export CLUSTER_NAME=mgmt-capi CP_REPLICAS=1 WORKER_REPLICAS=1 \
       K8S_VERSION=v1.35.3 TALOS_VERSION=v1.13 SCW_ZONE=fr-par-1 \
       SCW_IMAGE_NAME=talos-scaleway-amd64-v1.13.4 SCW_REGION=fr-par \
       SCW_INSTANCE_TYPE=DEV1-L SCW_PROJECT_ID="$SCW_DEFAULT_PROJECT_ID"
kubectl kustomize ../OpenAether-apps/apps/base/cluster-api-clusters/templates/cluster-talos-scaleway \
  | flux envsubst | kubectl apply -f -

# une fois Provisioned :
kubectl -n capi-clusters get secret mgmt-capi-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > mgmt-capi.kubeconfig
```

Puis faire pour lui ce qu'un parent fait pour un enfant, mais depuis le poste :
Cilium (helm, values d'enfant), `flux-gotk/gotk-components.yaml`
(`--server-side`), et `child-gitops` rendu avec `CHILD_PROFILE`, `CHILD_NAME`,
`CHILD_BRANCH`. Semer ses secrets opérateur et il déploie ses propres enfants.

⚠️ **Deux managements ne doivent jamais lire le même `apps/clusters`** — ils se
disputeraient les mêmes CR CAPI. Isoler par branche ou par chemin.

## 3. Pivot

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
clusterctl move --to-kubeconfig=mgmt-capi.kubeconfig -n capi-clusters
task local-down
KUBECONFIG=mgmt-capi.kubeconfig clusterctl describe cluster mgmt-capi -n capi-clusters
```

## Pièges, tous rencontrés en réel

**`clusterctl move` refuse une cible équipée par notre opérateur, et ce n'est pas
corrigé.** L'opérateur et clusterctl tiennent des inventaires différents, et
l'opérateur ne remplit pas celui de clusterctl. Une brique `clusterctl-inventory`
revendiquait ce correctif sans jamais le livrer : elle écrit des objets
`Provider` (`clusterctl.cluster.x-k8s.io/v1alpha3`), un CRD que
`cluster-api-operator` n'installe pas — la brique restait donc en
`ReconciliationFailed` permanent, une Kustomization rouge dans chaque
déploiement management, pour rien. Retirée le 2026-08-14 plutôt que laissée comme
un correctif qui n'en était pas un. Pivoter un management sur lui-même exige
d'installer cet inventaire autrement d'abord.
⚠️ `--dry-run` ne fait pas ce contrôle : il passe, seul le move réel échoue.

**Les Machines ne se relient jamais à leurs nœuds** (`still provisioning the
node`) — **corrigé le 2026-07-28**. Talos ne pose pas de `spec.providerID`, donc
CAPI ne pouvait pas apparier Machine et Node et `MachineHealthCheck` restait
inerte. Les templates mettent désormais le kubelet en `cloud-provider=external`
et les enfants embarquent le CCM Talos (`apps/clusters/*.yaml`), qui renseigne le
champ au format même de CAPS — sans transformation. Vérifié sur Scaleway :
Machines `Running`, `nodeRef` résolu, MHC 3/3. ⚠️ Les deux moitiés vont
ensemble : ce flag kubelet sans le CCM laisse tous les nœuds taintés
`uninitialized`.

**Ports hôte sous Windows.** Hyper-V réserve des blocs mouvants au-dessus de
49152 : Docker refuse de publier et le cluster meurt 90 s plus tard sur « Talos
API not ready ». Corrigé : `talos_api_port_base` par défaut à 41000. Diagnostic
avec `netsh.exe int ipv4 show excludedportrange protocol=tcp`.

**`clusterctl init` seul laisse CAPO mort (OpenStack/OVH).** CAPO v0.14 exige
les CRD ORC (`Image.openstack.k-orc.cloud`) ; sans elles son manager perd le
leader election et s'arrête, si bien que le contrôleur de cluster crée quand
même réseau, routeur, LB et IP flottantes alors qu'**aucune instance n'est
créée** — les machines restent en `Provisioning` sans erreur sur la CR. Notre
brique opérateur installe ORC, un `clusterctl init` nu non :
`kubectl apply --server-side -f https://github.com/k-orc/openstack-resource-controller/releases/download/v2.5.0/install.yaml`,
puis redémarrer `capo-controller-manager`.

**Outscale : `region` n'est pas une subregion.** CAPOSC construit son host d'API
à partir de la clé `region` du secret : `eu-west-2a` donne
`api.eu-west-2a.outscale.com`, qui ne résout pas — le Net ne réconcilie jamais.
Mettre `eu-west-2` ; la subregion va dans `OSC_SUBREGION`.

**L'IP flottante d'un enfant OpenStack (CAPO) doit exister AVANT son
démarrage.** L'IMDS ne l'expose jamais (NAT côté Neutron) : elle doit être
dans les `certSANs` Talos en amont, donc dans git avant `flux reconcile`, pas
quelque chose que CAPO peut allouer en cours de provisioning.
`scripts/ops/ensure-capo-fip.py <cluster> [--network Ext-Net] [--count N]` la
trouve ou l'alloue via un tag de description `openaether:<cluster>`
(idempotent — un re-run ne facture jamais de doublon) et affiche l'adresse à
copier dans `OS_CP_FLOATING_IPS` de l'enfant. C'est aussi la seule ressource
CAPO créée hors OpenTofu et CAPI — donc la seule qu'un teardown laisse
derrière lui, toujours facturée.

## Teardown

Les enfants d'abord (le management détient leurs CR), puis le management.
⚠️ Un cluster autogéré **ne peut pas terminer sa propre suppression** : il
détruit son control plane et le contrôleur meurt avec, laissant des ressources
chez le provider. Soit pivoter vers un cluster jetable, soit supprimer les
instances côté provider puis purger les CR. Supprimer une branche de test
**après** le teardown.
