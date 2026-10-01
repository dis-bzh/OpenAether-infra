# Bootstrap Manifests

Static Kubernetes manifests injected at cluster creation via **Talos `inlineManifests`**.

## Files

| File | Source | Injected when |
|------|--------|---------------|
| `cilium.yaml` | `helm template cilium/cilium` | Always (CNI is required) |
| `cilium-local.yaml` | `helm template cilium/cilium --local` | Local Docker testing only |
| `flux-install.yaml` | Flux2 official `install.yaml` | `deploy_flux=true` (default false) |
| `flux-bootstrap.yaml.tftpl` | OpenTofu template | `deploy_flux=true` (default false) |

## Regenerating Manifests

Run whenever upgrading Cilium or Flux:

```bash
# Default versions (from script)
./scripts/bootstrap/render-bootstrap-manifests.sh

# Override versions
CILIUM_VERSION=1.20.0 FLUX_VERSION=v2.5.0 ./scripts/bootstrap/render-bootstrap-manifests.sh

# Local Docker testing only (regenerate cilium-local.yaml)
./scripts/bootstrap/render-bootstrap-manifests.sh --local
```

Then commit the updated files. OpenTofu reads them at apply time.

## Current Versions

The pins are `CILIUM_VERSION` and `FLUX_VERSION` in
`scripts/bootstrap/render-bootstrap-manifests.sh`.

## Bootstrap Flow

```
tofu apply -var talos_bootstrap=true
  └─► Talos control plane config
        └─► inlineManifests:
              ├── cilium.yaml          # CNI — nodes can communicate
              ├── flux-install.yaml    # Flux controllers + CRDs
              └── flux-bootstrap.yaml  # GitRepository + Kustomization → git_repo_url
                    └─► Flux syncs GitOps overlay from OpenAether-apps.git
                          ├── apps/flux/management/  (management cluster)
                          └── apps/flux/workload/    (spoke clusters)
```

## Flux Bootstrap Template Variables

The `flux-bootstrap.yaml.tftpl` template receives:
- `git_repo_url` — Apps repository URL (e.g. `https://github.com/dis-bzh/OpenAether-apps.git`)
- `git_branch` — Branch to track (default: `main`)
- `cluster_role` — `management` or `workload` (routes to correct Flux overlay)
- `flux_deploy_key_public` — SSH deploy key for private repo access

## Important Notes

- **Never commit real credentials** — these files contain no secrets
- **Cilium is always injected** — required for node networking before kubelet starts
- **Flux is only injected with `deploy_flux=true`, on initial bootstrap** — on upgrades/DRP, Flux already runs
  and manages itself via GitOps. Re-injecting would cause conflicts.
- **Upgrade path**: Update versions in `render-bootstrap-manifests.sh`, regenerate,
  then `tofu apply` with the new manifests
