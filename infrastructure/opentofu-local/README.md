# OpenAether — Local Talos Test (3 CP + 3 workers, Docker)

Exercises the **production `modules/talos/`** end-to-end on a real **3 control
plane + 3 worker** Talos cluster running in Docker — no cloud credentials. The
dedicated workers stay schedulable (control planes keep their taint), so it also
covers HA and real pod scheduling. Use it to validate config generation, etcd
quorum, bootstrap, kubeconfig retrieval, Cilium, and the Flux GitOps chain
before spending money in the cloud.

> No S3 backend (local state). Reuses the shared `../opentofu/modules/talos/` and
> `../opentofu/modules/providers/local/`.

## What it validates (production `modules/talos/`)

| Resource | Local | Notes |
|---|---|---|
| `talos_machine_secrets` | ✅ | PKI |
| `data.talos_client_configuration` | ✅ | talosconfig |
| `data.talos_machine_configuration` | ✅ | **the real config** (certSANs, CNI=none, proxy off, kubePrism, inlineManifests, hostDNS) |
| `talos_machine_bootstrap` | ✅ | 3-node etcd quorum (control planes only) |
| worker join (`modules/talos` worker config) | ✅ | 3 dedicated workers join via USERDATA |
| `talos_cluster_kubeconfig` | ✅ | kubeconfig (rewritten to 127.0.0.1) |
| `data.talos_cluster_health` | ☁️ cloud-only | stalls behind WSL2 port mappings; verified here via `talosctl health` (skip_health_check=true) |
| `talos_machine_configuration_apply` | ☁️ cloud-only | Docker uses USERDATA delivery (Talos platform docs); maintenance-apply reboot-loops in containers |

Plus, on top of the cluster: Cilium CNI on all 5 nodes, Flux, and the
`ApplicationSet → Application` hub mechanism.

## Host requirement: `CAP_SYS_RESOURCE`

Talos's in-node containerd sets its own OOM score to `-999`, which needs
`CAP_SYS_RESOURCE`. Sandboxes and some CI runners drop that capability from the
BOUNDING set, and `--privileged` cannot get it back: Docker grants capabilities
from its parent's bounding set, so a privileged container inherits the same hole.
Check before spending fifteen minutes on it:

```bash
# The BOUNDING line, and only it: capsh names the capability twice more as a
# NEGATION ("cap_sys_resource-ep", "!cap_sys_resource"), so a bare grep over the
# whole output reports a missing capability as present.
capsh --print | grep '^Bounding set' | grep -q cap_sys_resource ||
  echo "MISSING — this lane cannot run here"
```

Without it the containers come up and look healthy while
`talos_machine_bootstrap` retries to its timeout, and the reason is only in
`docker logs openaether-local-dev-cp-0`: containerd `going to restart forever:
failed to change OOMScoreAdj [...] to -999: permission denied`. No containerd
means no `apid`, so the Talos API port never listens. There is no workaround —
the qemu provisioner wants `/dev/kvm`, which such hosts do not expose either.
Measured 2026-08-27 on a host where bit 24 was the only one of 41 missing.

## Quick start

```bash
# One command — full deploy + verify (etcd quorum, Cilium, Flux, GitOps)
TF_VAR_encryption_passphrase="local-test-passphrase-32chars-minimum" \
  ./scripts/dev/test-talos-local.sh

# Or via task:
task local-render-manifests   # render simplified Cilium (no WireGuard)
task local-up                 # deploy the cluster (3 CP + 3 workers)
task local-status             # etcd members + nodes + Flux
task local-flux             # Flux UI → http://localhost:9090
task local-down               # tear down
```

## How config reaches nodes (cloud vs local)

`modules/talos` supports two delivery modes via `config_delivery`:

| | Cloud (`apply`) | Local Docker (`userdata`) |
|---|---|---|
| Mechanism | `talos_machine_configuration_apply` (gRPC maintenance apply) | config injected at container start via `USERDATA` env |
| Why | VMs boot from a disk image in maintenance mode | maintenance-apply reboot-loops in containers (Talos Docker docs) |
| Config content | identical (same `data.talos_machine_configuration`) | identical |

The generated config is the **same** — local proves it boots a real multi-node cluster.

## Networking (WSL2 + Docker Desktop)

```
WSL2 host (OpenTofu + talosctl + kubectl)
  │  container IPs (10.5.0.x) are NOT routable from the host →
  │  reach the APIs via 127.0.0.1 port mappings:
  ├─ 127.0.0.1:50000 → cp-0:50000      (Talos API)   node identity 10.5.0.10
  ├─ 127.0.0.1:50001 → cp-1:50000      (Talos API)   node identity 10.5.0.11
  ├─ 127.0.0.1:50002 → cp-2:50000      (Talos API)   node identity 10.5.0.12
  ├─ 127.0.0.1:50010 → worker-0:50000  (Talos API)   node identity 10.5.0.20
  ├─ 127.0.0.1:50011 → worker-1:50000  (Talos API)   node identity 10.5.0.21
  ├─ 127.0.0.1:50012 → worker-2:50000  (Talos API)   node identity 10.5.0.22
  └─ 127.0.0.1:6443  → cp-0:6443       (K8s API)

Containers (ghcr.io/siderolabs/talos): --read-only, PLATFORM=container,
  tmpfs /run /system /tmp + volumes /system/state /var /etc/cni /etc/kubernetes
  /usr/libexec/kubernetes /opt ; static IPs on a 10.5.0.0/24 Docker network.
Inter-node (etcd, kube) uses the 10.5.0.x network directly.
```

`modules/talos` is fed `control_plane_ips` (10.5.0.x, node identity) and
`control_plane_endpoints` (127.0.0.1:5000x, host-reachable) — the split keeps the
cloud path unchanged (endpoints default to the node IPs there).

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `control_plane_count` | `3` | 3 for a real quorum, 1 for a quick smoke test |
| `worker_count` | `3` | dedicated schedulable workers (0 falls back to untainting the CPs) |
| `talos_bootstrap` | `false` | `true` builds the full cluster |
| `cilium_manifest` | `null` | set via `TF_VAR_cilium_manifest` from `cilium-local.yaml` |

## Troubleshooting

```bash
# etcd quorum
talosctl --nodes 10.5.0.10 --endpoints 127.0.0.1:50000 etcd members

# a container reboot-loops → check the boot phase
docker logs openaether-local-dev-cp-0 2>&1 | grep -E "phase|boot sequence|failed"

# Docker Desktop port-forward errors ("/forwards/expose 500") when many
#   port-mapped containers start at once: workers are created in a second wave
#   (depends_on the control planes) to cap concurrent --publish registrations,
#   and the provisioners retry the `docker run` (clearing the half-created
#   container first) as a backstop. If it still persists after heavy churn,
#   restart Docker Desktop.

# full reset
task local-down
```
