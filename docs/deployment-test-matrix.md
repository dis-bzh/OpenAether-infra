# OpenAether-infra — Deployment Test Matrix

🇫🇷 [Version française](deployment-test-matrix.fr.md)

> Every deployment case this stack can produce, and which have been exercised.
> Derived from `cluster/variables.tf`, the provider modules and
> `provider-contract.md`. Keep the **Status** column current — that is the point
> of the file.
>
> ✅ apply-tested · 🎭 emulated (Feint: real provider, real HTTP, no account) ·
> ⛔ blocked upstream · 🧪 unit-tested only (mocked) · ⬜ untested.
> Reviewed 2026-08-20.
>
> A ✅ is a record of a run on its date, not a claim 0.1.0 makes. What this
> release rests on is the Scaleway and OVH management HA measured 2026-08-19 and
> the Outscale one measured 2026-08-20 — `docs/status.md`. Rows
> dated before those, `CAPI-*` included, predate the re-scope.

## Mental model

One **env file = one cluster = one provider**. `cluster/main.tf` enforces a
single active provider per apply (`check "single_provider_per_cluster"`); the
active provider is whichever `node_distribution.<provider>` key has
`control_planes + workers > 0`. The provider module renders infra (LB / network
/ bastion); the **provider-agnostic** `modules/talos` then renders identical
Talos config regardless of provider. Local Docker is a **separate root**
(`infrastructure/opentofu-local`), not selectable via `node_distribution`.

Two orthogonal layers of knobs:

- **Infra-shaping** (per provider): provider, zones/hosts, `k8s_lb_mode`,
  bastion, worker disks.
- **Talos / operational** (provider-agnostic): `cluster_role`, `talos_bootstrap`
  phase, VIP injection, `secrets_prevent_destroy`, `auto_tunnels`,
  `backup_enabled`, test-only skips.

## A) Dimensions

| Dimension | Variable path | Valid values | Default | Applicability | Notes |
|---|---|---|---|---|---|
| Provider | `node_distribution.<key>` (scaleway/ovh/outscale/proxmox); `local` = separate `opentofu-local` root | one active | `{}` | — | Exactly one active per apply. |
| Cluster role | `cluster_role` | `management`, `workload` | `workload` | all | Only drives the Flux bootstrap manifest. A "management" later gets CAPI + deps via `OpenAether-apps` (no CAPI knob in tofu). `failover-*` = management role on a non-primary provider. |
| Environment | `environment` | `dev`, `prod` | required | all | Naming / bucket suffix only — not a topology axis. |
| CP topology (HA) | `node_distribution.<p>.control_planes`; local `control_plane_count` | 1 = non-HA, 3 = HA | 0 / local 3 | all | etcd quorum needs odd ≥3. Non-HA CP tainted `NoSchedule`. |
| Worker count | `node_distribution.<p>.workers`; local `worker_count` | ≥0 (local `0..3`) | 0 / local 3 | all | 0 workers → workloads on (untainted) CPs. |
| k8s LB mode | `node_distribution.<p>.k8s_lb_mode` | `managed`, `vip` | `managed` | **scw, ovh** only; outscale = managed-only (rejects vip); proxmox = always VIP; local = neither | `vip` (EXPERIMENTAL): no LB, private IPAM addr + Talos Layer2 VIP → **API private-only via bastion tunnel**. |
| apiserver VIP | `local.apiserver_vip` → `module.talos.apiserver_vip`; proxmox `apiserver_vip` (required) + `apiserver_vip_interface` | IP / null | null (cloud); required (proxmox) | proxmox always; scw/ovh in vip mode | Injected as `machine.network.interfaces[].vip` + certSANs. Ignored in container mode. |
| App LB | `deploy_app_lb` | `true`/`false` | `false` | scw/ovh/outscale; proxmox = host DNAT; local = `127.0.0.1` | Its backends are the Gateway's fixed NodePorts, so an infra-only cluster would pay for an LB pointing at nothing. Off ⇒ `app_lb_ip` is null (`N/A` at the root). |
| Zones / AZ | scw `.zone`+`.zones` and ovh `.availability_zones` round-robin with `element(...)`; **outscale reads only `availability_zones[0]`** — one subnet, one subregion, whatever the list says; proxmox `.node_names` (round-robin) | e.g. scw `["fr-par-1","fr-par-2","fr-par-3"]` | per example | cloud + proxmox | Single vs multi-AZ. Proxmox: 1 host = non-HA, 3 hosts = **true** HA; 3 CP on 1 host = fake HA (avoid). |
| Bastion | proxmox `enable_bastion` | `true` (VM) / `false` (host-as-bastion) | `false` | proxmox toggle; scw/ovh/outscale always a dedicated VM; local none | Contract requires `bastion_ip`. |
| Worker storage | `worker_storage.disks[]` + `worker_storage.volumes[]` (LUKS2 `UserVolumeConfig`) | none, or disks+volumes | `{disks=[],volumes=[]}` | scw/ovh/outscale/proxmox; local forced off | `disks` → provider module; `volumes` → `modules/talos`. |
| Bootstrap phase | `talos_bootstrap` | `false` (Phase 1 infra), `true` (Phase 2 config+etcd+Flux) | `true` | all | `task infra-apply` → `task bootstrap-phase2`. |
| auto_tunnels | `auto_tunnels` (+ `ssh_key_path`) | `true`/`false` | `false` | cloud/proxmox | EXPERIMENTAL single-apply; untested on a real host. |
| Tunnel port block | `TALOS_TUNNEL_OFFSET` → `talos_tunnel_port_offset` | non-negative multiple of 200 | `0` | cloud/proxmox | Shifts CPs `50000+off+i` / workers `50100+off+i`, so several clusters can be brought up from one workstation. Set the env var only; `Taskfile.yml` feeds the tofu variable. |
| secrets_prevent_destroy | `secrets_prevent_destroy` | `true`/`false` | `true` | all | `false` only for `tofu test` cleanup. |
| skip_port_ready_wait | `skip_port_ready_wait` | `true`/`false` | `false` | all | `true` only for mocked CI. |
| backup_enabled | `backup_enabled` | `true`/`false` | `true` | root | `false` skips the backup local-exec. |
| Talos / K8s version | `talos_version`, `kubernetes_version` | version strings | per example | all | Drives image name lookup. |
| admin_ip | `admin_ip` (list) | CIDRs | required | all | LB ACL / SG / host nftables allow-list. |

## B) Meaningful test cases

### Excluded / invalid / redundant — do **not** test

| Combo | Why |
|---|---|
| ≥2 providers with count>0 in one apply | Blocked by `check "single_provider_per_cluster"`. |
| `outscale` + `k8s_lb_mode="vip"` | Provider validation rejects it (DNS-name LB). |
| `proxmox` + any `k8s_lb_mode` | Ignored — proxmox always uses the Talos VIP. |
| `local-docker` + LB / storage / bootstrap-manifest Flux | No LB (cp0 IP); volumes forced off; Flux installed post-boot. |
| `apiserver_vip` with cloud `k8s_lb_mode="managed"` | Resolves to null. |
| 3 CP on a single Proxmox host | Fake HA — real HA is multi-host. |
| local CP ∉ {1,3} or workers >3 | Validation error. |
| `dev` vs `prod` as a topology | Naming only — fold into any case. |

### local-docker (`opentofu-local` root)

| ID | CP/W | Uniquely exercises | Status |
|---|---|---|---|
| `L-ha` | 3+3 | Real 3-node etcd quorum, dedicated schedulable workers, Cilium, `userdata` delivery — primary credential-free proof of `modules/talos`. | ✅ (`task local-up`, re-run 2026-08-20: manifest rendered when absent, Cilium 6/6, etcd 3 members, `local-test` green) |
| `L-smoke` | 1+0 | Fast single-node smoke; untainted-CP scheduling fallback. | ⬜ |

### Scaleway (reference provider)

| ID | Role | CP/W | k8s_lb_mode | Zones | Storage | Uniquely exercises | Status |
|---|---|---|---|---|---|---|---|
| `SCW-mgmt-nonha` | mgmt | 1+1 | managed | single | none | Cheapest cloud path; non-HA CP taint; managed LB ACL. | ✅ |
| `SCW-mgmt-ha` | mgmt | 3+2 | managed | 3-AZ | none | etcd across 3 zones; multi-AZ distribution. | ⬜ — see the row below: what runs is **2 zones**, because the third has no instance type this project uses |
| `SCW-mgmt-ha-2az` | mgmt | 3+3 | managed | 2-AZ | **disks+volumes** | What 0.1.0 actually rests on. etcd across 2 zones, round-robinned. | ✅ 2026-08-19, again 2026-08-20 — before the failure-domain check (#38): 3 control planes over 2 zones is a 2+1 split, which `cluster-verify` now fails |
| `SCW-vip` | mgmt | 3+1 | **vip** | multi-AZ | none | Drops the LB; Talos Layer2 VIP; private API via tunnel; anti-spoofing. | ✅ *(2026-07-15)* |
| `SCW-work-ha` | workload | 3+3 | managed | 3-AZ | none | Workload-role Flux bootstrap path. | ⬜ |
| `SCW-storage` | workload | 3+3 | managed | 3-AZ | **disks+volumes** | SBS block volumes + encrypted `UserVolumeConfig` (LUKS2). | ⬜ on the *workload* role. The block volumes and the UserVolumeConfig patches DID apply on `SCW-mgmt-ha-2az` — 3 × `scaleway_block_volume.worker_data` in state — but **nothing read back that they were formatted LUKS2 and mounted**: `cluster-verify` asks about no volume at all |

### OVH (OpenStack)

| ID | Role | CP/W | k8s_lb_mode | Uniquely exercises | Status |
|---|---|---|---|---|---|
| `OVH-mgmt-ha` | mgmt | 3+3 | managed | Octavia LB + floating IP; OpenStack ports; Ubuntu bastion; SNAT router egress. | ✅ *(2026-07-27/28, several cycles)* — before the failure-domain check (#38): on the default `nova` `cluster-verify` now fails it, green needs distinct `availability_zones` |
| `OVH-vip` | mgmt | 3+2 | **vip** | `allowed_address_pairs` on CP ports for Neutron anti-spoof (distinct from Scaleway). | 🧪 |
| `OVH-work-ha` | workload | 3+3 | managed | Workload role on OVH. | ⬜ |
| `OVH-storage` | workload | 3+3 | managed | Cinder volume attach. | ⬜ |

### Outscale (managed-only, DNS-name LB)

| ID | Role | CP/W | k8s_lb_mode | Uniquely exercises | Status |
|---|---|---|---|---|---|
| `OSC-mgmt-ha` | mgmt | 3+1 | managed | LB returns a **DNS name**, not an IP; outscale SSH user. 3+3 does not fit the 40 GB RAM quota, so HA here means the control plane only — and **every node is in eu-west-2a**, because the module never reads past the first subregion. Three control planes, one failure domain. | ✅ *(2026-08-20, on a **fresh** Net — LB `active` with 3 backends. The hang that blocked it was a timeout inside Outscale's own LBU service, request 399530 closed; the Net that predates the fix still refuses deletion. The 2026-08-13 ✅ does not stand: its Talos upgrade reverted on the next reboot, see the open issues)* — before the failure-domain check (#38): `cluster-verify` now fails it, and nothing clears that until #58 |
| `OSC-work-ha` | workload | 3+3 | managed | Workload role; BSU volumes if paired with storage. | ⬜ |
| `OSC-vip-reject` | — | any | vip | Negative test: validation must reject `vip`. | 🧪 |

### Proxmox (bare-metal, always-VIP, host-as-bastion)

| ID | Role | CP/W | node_names | Bastion | Uniquely exercises | Status |
|---|---|---|---|---|---|---|
| `PMX-nonha-host` | mgmt | 1+1 | `["pve1"]` | host | Single-host non-HA; Talos VIP; static `cidrhost()` IPs; no LB/NAT/SG. | ⬜ |
| `PMX-work-nonha` | workload | 1+1 | `["pve1"]` | host | Workload role on-prem. | ⬜ |
| `PMX-ha-multihost` | mgmt | 3+n | `["pve1","pve2","pve3"]` | host | True on-prem HA: 1 CP/host, VIP floats; L2 bridge. | ⬜ |
| `PMX-vm-bastion` | mgmt | 1+1 | `["pve1"]` | **VM** | Dedicated bastion VM path. | ⬜ |
| `PMX-storage` | workload | 1+1 | `["pve1"]` | host | Extra Proxmox data disk + encrypted volume. | ⬜ |

### CAPI layer — child clusters and CAPI-bootstrapped management

| ID | Bootstrapped by | Provider | Uniquely exercises | Status |
|---|---|---|---|---|
| `CAPI-edge-scw` | management | Scaleway | CAPS child; Cilium+Flux injected remotely; own git profile. | ✅ *(edge-1, 2026-07-28)* |
| `CAPI-edge-ovh` | management | OVH (CAPO) | CAPO child; network/LB/SG created by CAPO; pre-allocated FIP for certSANs. | ✅ *(edge-2, 2026-07-28)* |
| `CAPI-cross-provider` | OVH management | Scaleway | Gitception **cross-provider in both directions**. | ✅ *(2026-07-28)* |
| `CAPI-mgmt-pivot` | local throwaway cluster | Scaleway | Management **born from CAPI**, deploying its own child, then `clusterctl move` onto itself. | ✅ *(mgmt-capi, 2026-07-28 — see `capi-bootstrap.md`)* |
| `CAPI-edge-osc` | management | Outscale | CAPOSC child. | ⬜ *(account RAM quota)* |
| `CAPI-providerid` | local throwaway | Scaleway | Talos CCM → `providerID`, `nodeRef` resolved, MachineHealthCheck 3/3. | ✅ *(edge-pid, 2026-07-28)* |

### Emulated cloud (Feint — no account, no credentials)

The real provider binaries against a local emulator of the Scaleway/Outscale
APIs. Between 🧪 and ✅: real HTTP, real decode, but no inventory, no LB, no
quotas. What it proves and what it does not: `emulated-cloud.md`.

| ID | Lane | Uniquely exercises | Status |
|---|---|---|---|
| `FEINT-scw-plan` | `task feint-plan PROVIDER=scaleway` | The **real** cluster root planned with zero credentials in scope. | 🎭 (CI) |
| `FEINT-osc-plan` | `task feint-plan PROVIDER=outscale` | Same for Outscale, and it resolves its image through `data.outscale_images` rather than a pinned id — the `images[0]` shape the module carried as an unverified assumption. | 🎭 (CI) |
| `FEINT-scw-crud` | `task feint-apply PROVIDER=scaleway` | Real create/read/update/delete: security-group rule set, private NIC addressing, server + volume lifecycle, empty re-plan, destroy verified against the API. | 🎭 (CI) |
| `FEINT-osc-crud` | `task feint-apply PROVIDER=outscale` | Same on Outscale, and since Feint 0.6.0 nearly the whole module: the two-subnet egress plan (internet service, NAT, both route tables), security groups and rules, public IP link, volume link, keypair, three VMs — 27 resources. Only the load balancers are out of reach. | 🎭 (CI) |
| `FEINT-record` | `task feint-record PROVIDER=…` | Records the real module through `feint proxy` and ranks the operations no pack serves. Measures the gap rather than asserting; the apply behind it is expected to fail on the first unserved call. | 🎭 |
| `FEINT-guard` | non-loopback endpoint | Negative test: the lane must refuse to drive anything but a local emulator. | 🎭 |

Not reachable in this lane, and why: Scaleway root volume type, Outscale
`volume_link`, `data.outscale_images` (segfaults the provider). See
the open issues.

### Cross-cutting operational scenarios

| ID | Key vars | Uniquely exercises | Status |
|---|---|---|---|
| `OP-twophase` | `talos_bootstrap=false` then `true` | Documented `task infra-apply` → `task bootstrap-phase2` split. | ✅ |
| `OP-autotunnels` | `auto_tunnels=true` | EXPERIMENTAL single-apply. | ⬜ |
| `OP-failover` | `failover-<p>.tfvars`, no command yet | Rebuild on provider B from B's replica. The replica is verified; the rebuild is undesigned. | ⬜ |
| `OP-destroy` | `task cluster-down` / `task infra-down` | Ordered teardown (children then management). | ✅ |
| `OP-tftest` | mocked | The unit-test suite (no credentials). | ✅ (CI) |
| `OP-backup` | `backup_enabled=true`, cross-provider replica (`<STORE>_AWS_*`) | DR: tfstate + kube/talosconfig to primary + replica; client-encrypted restic. | ✅ *(local + real cloud SCW+OVH)* |
| `OP-rolling-replace` | `task cluster-roll` | One node at a time (etcd evict, cordon/drain). Not zero-downtime: the API is unreachable for 5-8 s, see the open issues. | ✅ *(Scaleway and OVH 2026-08-19, Outscale 2026-08-20 — it carries the Talos upgrade)* |

## C) Priority (highest-value untested, real apply)

1. **Proxmox real apply** (`PMX-*`) — never run on a real host.
2. **Cloud HA multi-AZ** (`SCW-mgmt-ha`) — 3-CP etcd across zones never applied
   at this exact shape. `OSC-mgmt-ha` cannot be one: one subregion.
3. **`OVH-vip`** — vip mode never applied on OVH (distinct Neutron
   `allowed_address_pairs` mechanism).
4. **Workload role real apply** (`*-work-*`) — only management exercised.
5. **`worker_storage` real apply** (`*-storage`) — LUKS2 `UserVolumeConfig` and
   block-volume attach never applied.
6. **`OP-failover`** — DR path unproven.

## D) Findings — `SCW-vip` real apply (2026-07-15)

3 CP (fr-par-1 + fr-par-2) + 1 worker, `k8s_lb_mode=vip`.

- ✅ Layer2 VIP works cross-zone: the regional private network relays its ARP —
  the main open question going in. VIP is in the apiserver cert SANs.
- ⚠️ Operator access becomes private-only (`kubectl` needs the bastion tunnel),
  and `data.talos_cluster_health` can hang the apply — it is read from the
  operator's machine, which cannot reach a private VIP. etcd/config land first,
  so the state stays complete.
