# Bootstrapping a management cluster with CAPI (pivot from local)

🇫🇷 [Version française](capi-bootstrap.fr.md)

Validated end to end on Scaleway, 2026-07-28 — before the re-scope, and **0.2.0
deploys no CAPI**: this is kept for the release that does. An **optional path**, alongside
OpenTofu — not a replacement: CAPI creates the machines, OpenTofu still creates
the substrate (on OVH, ~44 resources of which 3 are instances).

```
local (Talos/Docker) ──CAPI──▶ mgmt-capi ──CAPI/GitOps──▶ edge-capi
        └── clusterctl move ──▶ mgmt-capi manages itself, local destroyed
```

## Prerequisites

Docker engine reachable · `clusterctl` at the CoreProvider's version (v1.13.2) ·
the Talos image published for the provider (Scaleway images are per zone) ·
credentials in `.env.sh`.

## 1. Throwaway cluster + CAPI

```bash
task local-up
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig

# Check egress first — without it the provider controller creates nothing.
kubectl run egress-test --image=curlimages/curl:8.11.1 --restart=Never --command -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://api.scaleway.com/instance/v1/zones

clusterctl init --core cluster-api:v1.13.2 --bootstrap talos:v0.6.12 \
                --control-plane talos:v0.5.13 --infrastructure scaleway:v0.2.1
kubectl create namespace capi-clusters
kubectl -n capi-clusters create secret generic scaleway-capi-credentials \
  --from-literal=SCW_ACCESS_KEY="$SCW_ACCESS_KEY" \
  --from-literal=SCW_SECRET_KEY="$SCW_SECRET_KEY"
```

`clusterctl init`, not our bricks: the operator needs a HelmRelease, cluster
egress and cert-manager — too heavy for a cluster you throw away.
⚠️ Versions must match our bricks exactly, or `clusterctl move` rejects the
target.

## 2. Create and equip the management

Same template as a child. Outside Flux, render it with `flux envsubst` (it
handles `${VAR:=default}`, plain `envsubst` does not).

```bash
export CLUSTER_NAME=mgmt-capi CP_REPLICAS=1 WORKER_REPLICAS=1 \
       K8S_VERSION=v1.35.3 TALOS_VERSION=v1.13 SCW_ZONE=fr-par-1 \
       SCW_IMAGE_NAME=talos-scaleway-amd64-v1.13.4 SCW_REGION=fr-par \
       SCW_INSTANCE_TYPE=DEV1-L SCW_PROJECT_ID="$SCW_DEFAULT_PROJECT_ID"
kubectl kustomize ../OpenAether-apps/apps/base/cluster-api-clusters/templates/cluster-talos-scaleway \
  | flux envsubst | kubectl apply -f -

# once Provisioned:
kubectl -n capi-clusters get secret mgmt-capi-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > mgmt-capi.kubeconfig
```

Then do for it what a parent does for a child, but from your workstation:
Cilium (helm, child values), `flux-gotk/gotk-components.yaml`
(`--server-side`), and `child-gitops` rendered with `CHILD_PROFILE`,
`CHILD_NAME`, `CHILD_BRANCH`. Seed its operator secrets and it deploys its own
children.

⚠️ **Two managements must never read the same `apps/clusters`** — they would
fight over the same CAPI CRs. Isolate by branch or by path.

## 3. Pivot

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
clusterctl move --to-kubeconfig=mgmt-capi.kubeconfig -n capi-clusters
task local-down
KUBECONFIG=mgmt-capi.kubeconfig clusterctl describe cluster mgmt-capi -n capi-clusters
```

## Pitfalls, all hit for real

**`clusterctl move` rejects a target equipped by our operator, and this is not
fixed.** The operator and clusterctl keep different inventories; the operator
populates none of clusterctl's. A `clusterctl-inventory` brick used to claim that
fix and never delivered it: it writes `Provider` objects
(`clusterctl.cluster.x-k8s.io/v1alpha3`), a CRD `cluster-api-operator` does not
install, so the brick sat permanently `ReconciliationFailed` — one red
Kustomization in every management deployment, fixing nothing. Removed 2026-08-14
rather than left as a fix that was not one. Pivoting a management cluster onto
itself needs that inventory installed some other way first.
⚠️ `--dry-run` does not run that check — it passes, only the real move fails.

**Machines never bind to their nodes** (`still provisioning the node`) —
**fixed 2026-07-28**. Talos sets no `spec.providerID`, so CAPI could not pair
Machine and Node and `MachineHealthCheck` was inert. The cluster templates now
put the kubelet in `cloud-provider=external` and the children run the Talos CCM
(`apps/clusters/*.yaml`), which fills the field in CAPS's own format — no
transformation needed. Verified on Scaleway: Machines `Running`, `nodeRef`
resolved, MHC 3/3. ⚠️ The two halves ship together: that kubelet flag without
the CCM leaves every node tainted `uninitialized`.

**Host ports on Windows.** Hyper-V reserves moving blocks above 49152, so
Docker refuses to publish and the cluster dies 90 s later on "Talos API not
ready". Fixed: `talos_api_port_base` defaults to 41000. Inspect with
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

**`clusterctl init` alone leaves CAPO dead (OpenStack/OVH).** CAPO v0.14 needs
the ORC CRDs (`Image.openstack.k-orc.cloud`); without them its manager loses
leader election and exits, so the cluster controller still builds the network,
router, LB and floating IPs while **no server is ever created** — machines sit
in `Provisioning` with no error on the CR. Our operator brick installs ORC, a
bare `clusterctl init` does not:
`kubectl apply --server-side -f https://github.com/k-orc/openstack-resource-controller/releases/download/v2.5.0/install.yaml`,
then restart `capo-controller-manager`.

**Outscale: `region` is not a subregion.** CAPOSC derives its API host from the
secret's `region` key, so `eu-west-2a` yields `api.eu-west-2a.outscale.com`,
which does not resolve — the Net never reconciles. Use `eu-west-2`; the
subregion belongs in `OSC_SUBREGION`.

**An OpenStack (CAPO) child's floating IP must exist BEFORE it boots.** The
IMDS never exposes it (Neutron-side NAT), so it has to be in the Talos
`certSANs` up front, which means in git before `flux reconcile`, not
something CAPO can allocate for you mid-provision. `scripts/ops/ensure-capo-fip.py
<cluster> [--network Ext-Net] [--count N]` finds-or-allocates it by a
`openaether:<cluster>` description tag (idempotent — re-running never bills a
duplicate) and prints the address to copy into the child's `OS_CP_FLOATING_IPS`.
It is also the only CAPO child resource created outside both OpenTofu and CAPI,
so it is the only one a teardown leaves behind, still billing.

## Teardown

Children first (the management owns their CRs), then the management.
⚠️ A self-managed cluster **cannot finish deleting itself**: it destroys its
control plane and the controller dies with it, leaving provider resources
behind. Either pivot back to a throwaway cluster, or delete the instances
provider-side and purge the CRs. Delete any test branch **after** the teardown.
