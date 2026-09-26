> 🇫🇷 [Version française](first-cluster.fr.md)

# Your first cluster

From a bare machine and an empty cloud account to a Talos cluster you can reach,
upgrade and destroy. Scaleway is used throughout; OVH and Outscale differ only
in their credentials and their tfvars file, except in step 4 where their load
balancers are slower — and where Outscale carries one caveat of its own.

**Read the honesty note at the bottom before you spend anything.** It says what
has been measured, on which cloud and when — and what has not.

## What you get, and what you do not

A single Talos Linux cluster: 3 control planes, 2 workers, Cilium as the CNI, an
apiserver load balancer ACL'd to your IP, a bastion, and an OpenTofu state
encrypted on your side before it reaches S3.

No applications, no GitOps, no ingress. Flux exists in the code and is **off**
(`deploy_flux = false`); it returns as a choice in a later release. Cilium does
not need it — Talos delivers Cilium itself, as an inline manifest, before
anything else runs.

## Before you start

- A Scaleway account, and the quota to run **5 instances** of the type in your
  tfvars. A new account may be capped at 1 — Console → Quotas. There is no
  preflight script for Scaleway (`preflight-quotas.py` covers OVH and Outscale
  only), so this check is yours to make.
- An SSH keypair you already have, or `ssh-keygen -t ed25519`.
- Somewhere to keep a passphrase you cannot afford to lose: it encrypts the
  state, the kubeconfig and the talosconfig, and nothing can decrypt them
  without it.

## 1. The machine

```bash
git clone https://github.com/dis-bzh/OpenAether-infra && cd OpenAether-infra
./scripts/setup.sh
```

Installs OpenTofu, talosctl, kubectl, Task, the AWS CLI, gpg and the rest.
Needs root or sudo. Ends on `🚀 Environment ready!`.

Do **not** start with `task setup` — `task` is one of the things this script
installs.

## 2. Credentials

```bash
cp .env.example .env.sh
$EDITOR .env.sh
source .env.sh
```

Fill in, for Scaleway: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`,
`SCW_DEFAULT_PROJECT_ID`, `SCW_DEFAULT_ORGANIZATION_ID`, the region and zone,
and `SCW_AWS_ACCESS_KEY_ID` / `SCW_AWS_SECRET_ACCESS_KEY` for S3.

There is no second pair to invent. **Credentials are named after the cloud that
holds the bucket.** Two files divide the job: the `.tfvars` says WHERE each store
is, `.env.sh` says with WHICH keys it is opened. Point the replica at Outscale
and the `-backup` store is opened with `OUTSCALE_AWS_*` — the very keys an
Outscale cluster would use. `<PROV>_BACKUP_AWS_*` remains available to give one
store its own separate pair, and is needed by nobody who does not want that.

A worked example — cluster on Scaleway, backups on Outscale:

```bash
# .env.sh — the primary store is Scaleway's, the -backup store is Outscale's
export SCW_AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export SCW_AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export OUTSCALE_AWS_ACCESS_KEY_ID="$OUTSCALE_ACCESS_KEY_ID"
export OUTSCALE_AWS_SECRET_ACCESS_KEY="$OUTSCALE_SECRET_KEY"
```

```hcl
# envs/management-scaleway.tfvars — and this is what makes it a real backup
s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
s3_primary_region   = "fr-par"
s3_replica_endpoint = "https://oos.eu-west-2.outscale.com"
s3_replica_region   = "eu-west-2"
```

`task cluster-up` opens both stores before it builds anything. If the replica
cannot be written it refuses in seconds — and names the variable whose key was
rejected, rather than leaving you with a provider error and six pairs to guess
between.

And the one that matters most:

```bash
TF_VAR_encryption_passphrase="$(openssl rand -base64 48)"
```

Minimum 32 characters. `task cluster-up` refuses outright if it is unset, and refuses
again if it still contains `change-me` — the shipped placeholder is published in
this repository, and that check is the only thing between you and deploying
under a public secret. Losing this passphrase means losing the state and both
access artifacts.

Do not export `AWS_*` yourself: the flow derives them per provider from the
namespaced variables above.

`task cluster-up` checks this file before it spends anything: the SSH key exists and is
the private half of `bastion_ssh_keys`, the tfvars file exists, BOTH S3
credential pairs resolve, and the passphrase is set and is not the placeholder.
All of it runs before the first bucket.

## 3. The cluster file

```bash
cd infrastructure/opentofu/cluster/envs
cp management-scaleway.tfvars.example management-scaleway.tfvars
$EDITOR management-scaleway.tfvars
```

| field | what to put in it |
|---|---|
| `cluster_name` | yours. **It has a default, so no checker will tell you to change it** — and its first segment names all four cluster buckets |
| `bucket_suffix` | **set it unless you are the original author.** S3 bucket names are unique across a whole provider, not per account — Scaleway documents them unique "in our whole platform", OVH "within OVHcloud". Without one you will collide with names somebody already took. `task bucket-suffix` prints one; pick it once, changing it later orphans every bucket you have |
| `environment` | `dev` or `prod`, nothing else. Pick it once: it names the state bucket. `prod` needs the replica on another provider: `task cluster-up` refuses before spending when `s3_replica_endpoint` is the primary's endpoint or the same cloud (an S3 it cannot name only has to be another endpoint). A cluster name that already has a state object is only warned, and `task cluster-verify` calls it red; that includes one torn down by `task cluster-down`, which keeps the state bucket. `dev` may share the primary's store |
| `admin_ip` | `curl -s ifconfig.me` as a `/32`. It is both the SSH allow-list and the apiserver LB ACL |
| `s3_primary_endpoint` / `_region` | S3 on the same provider as the cluster |
| `s3_replica_endpoint` / `_region` | S3 for the backup copy. In production, **a different provider** — a state you can only read from the cloud that just failed is not a backup. That store is opened with ITS OWN cloud's keys (`OUTSCALE_AWS_*` for an Outscale replica) — see step 2. `task cluster-up` refuses before it builds anything if the `-backup` buckets cannot be created there |
| `bastion_ssh_keys` | the **public** half of the key you will pass as `KEY=`. `task cluster-up` refuses to start if they do not match, before spending anything |
| `control_planes` | 3 — **inside `node_distribution.<provider>`**, not a top-level field, and `bastion_ssh_keys` is a map keyed by provider the same way. Nothing validates the count; `2` silently builds a two-member etcd |

`git_repo_url`, `git_ref`, `flux_namespace` and `apps_profile` are inert while
Flux is off. Leave them.

Before you spend anything: `task preflight`. Lint, render, validate, unit tests
and script tests — everything provable without a cloud account, in about four
minutes. It is free and it is the cheapest bug you will ever find.

## 4. Bring it up

```bash
cd ../../../..
task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

Needs a terminal: the apply asks for approval twice, and it applies the plan it
just showed you — do not reach for `-auto-approve`, which applies a *different*
plan computed at that moment. (For an unattended run, save one first:
`task infra-plan ROLE=management PROVIDER=scaleway OUT=tfplan`, read it, then
`task infra-apply PROVIDER=scaleway PLAN=tfplan`. PROVIDER is required on both —
it used to default to Scaleway, which is the wrong cloud to guess.)

In order it builds the Talos image and uploads it — **measured at 52 s on
Scaleway, 2026-08-17**, for two buckets, one snapshot and one image per zone —
creates four more buckets, applies the infrastructure, opens one SSH tunnel per
node, then applies the machine configs and bootstraps Talos.

**The apiserver load balancer is the slowest thing in this step, and the only
one that can strand you.** On Scaleway it is quick. On OVH and Outscale it is a
managed service that builds asynchronously: measured at **over 30 minutes still
"PENDING_CREATE" on OVH, 2026-08-18**, and it was an Outscale one timing out at
10 minutes that first exposed this on 2026-08-16. The apply shows nothing but
`Still creating...`; the provider's own API is where the real state lives.

If it does time out, **do not just re-run.** OpenTofu marks the resource
`tainted`, so the next apply DESTROYS the load balancer the provider was still
building and starts the wait over. `task infra-apply` now prints the tainted addresses
and the `tofu untaint` command when it fails — ask the provider first, and keep
the resource if the provider says it is fine.

And if it is genuinely stuck, that is not something you can fix: a managed load
balancer reserves a port inside your own subnet before its backend exists, so a
wedged one cannot be deleted and it pins the subnet, the network, and your whole
teardown behind it. `task cluster-down` recognises this and says so rather than telling
you to retry. It is a support ticket.

**Outscale asks for more patience here, and it has one trap worth knowing before
you meet it.** Registering the image alone is minutes to an hour — the snapshot
is imported from an 11 GiB object through a provider-side queue: 8 min on
2026-08-18, over 60 min stuck at `in-queue 0%` on 2026-07-25. Then, on
2026-08-19, a load balancer sat in `provisioning` for over an hour and the Net,
its subnet and its internet service refused deletion afterwards on an account
holding nothing.

Outscale support diagnosed that one, and it is theirs: their load balancer
service stops waiting after 10 seconds for an internal machine that takes about
10.7. The workflow fails, the machine and network resources it had already
created stay, and the load balancer never leaves `provisioning`. Their
instruction is to build no further load balancer in that Net and to use a new
one — a redeploy on a fresh Net succeeded on 2026-08-20, with the new load
balancer `active` and 3 backends. The support request covering it is closed. One
Net from before the fix still refuses deletion on a dependency no read returns;
only the provider can clear that, and a second request is open for it.

Six buckets exist afterwards: state and artifacts, each with a `-backup` twin,
plus the image and its staging area.

Re-running resumes — **except when your edit adds a node**, which is a known
open defect (see the issues), not something you did wrong.

## 5. Talk to it

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu/cluster/kubeconfig
kubectl get nodes
```

The file is already there, written by the bootstrap. If it is not, or you are in
a fresh shell: `task kubeconfig PROVIDER=scaleway`.

The apiserver is the public load balancer, ACL'd to your `admin_ip`, so plain
`kubectl` works with no tunnel.

For Talos itself, every command needs an explicit node — the talosconfig carries
endpoints but no default node:

```bash
cd infrastructure/opentofu/cluster
talosctl --talosconfig talosconfig -n "$(tofu output -json control_plane_private_ips | jq -r '.[0]')" etcd members
```

Those endpoints are **local tunnels**. `task tunnels-down` makes the talosconfig
unusable until you reopen them.

## 6. Ask the cluster whether it worked

```bash
task cluster-verify PROVIDER=scaleway
```

Asks the cluster, not the tool: the apiserver answers, every node is Ready, the
number of control planes matches what you asked for, Cilium runs on each of
them, CoreDNS serves, there is no `flux-system`, no application load balancer, a
state replica exists in the backup store — and the first 4 KB of that object is
opened and must be an OpenTofu `encrypted_data` envelope rather than readable
state. Outside `dev`, the replica must also be off the primary's cloud (for an
S3 it cannot name, another endpoint).

Four outcomes, not two. `✓` passed. `✗` failed, and the run is red. `~` is a
warning — a fact you must read that does not certify anything and does not turn
the run red: a control plane that is not HA, or a `dev` replica on the
primary's cloud. And `?` means the verifier could not perform the check at
all, which IS fatal — nothing is certified on a question nobody could ask, and
that is usually missing S3 credentials.

## 7. Upgrade

```bash
task cluster-upgrade ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

`docs/upgrade.md` is the procedure behind it — Kubernetes first, then Talos, one
node at a time, in place. It refuses if the cluster already runs both targets:
an upgrade can only be proven from one patch below, and it reads the CLUSTER,
not your tfvars. Start the probe before you begin: the claim this project makes
is not "no interruption", it is **the longest run of consecutive failed
`/readyz` samples, one second apart, stays under 15 seconds**. Measure it.

Measured across both upgrades: **16 failed samples out of 575, longest outage
5 s** on Scaleway and 9-10 out of ~540 for **7 s** on OVH, both on 2026-08-19,
then **8 s** on Outscale on 2026-08-20. All three are worse than the best this
project ever recorded (3 s, 1 s and 1 s), and all three are the honest figure.
The two numbers are different claims — scattered blips over a control-plane roll
are an HA cluster working; consecutive ones are the API being down.

## 8. Tear it down

```bash
task cluster-down PROVIDER=scaleway                                         # destroys nothing
task cluster-down PROVIDER=scaleway PLAN=destroy-management-scaleway.tfplan APPROVE=auto
python3 scripts/ops/purge-orphans/scaleway.py
```

**Destroying takes two commands and cannot be collapsed into one** — that is the
point, not an inconvenience. The first computes the destruction and destroys
nothing; the second lands exactly what you read. Neither `--yes` nor
`TF_CLI_ARGS_destroy` nor `APPROVE=auto` gets past the first.

`fleet-down` still refuses to destroy a cluster until it has ruled out CAPI
children, but it now reads WHY the query failed. Absent CRDs mean a management
with no CAPI, which has no children by definition: it says so and continues. A
cluster it cannot reach at all still stops it — unless the state proves nothing
was ever bootstrapped there.

The buckets and the Talos image survive on purpose — deleting the state bucket
also deletes any possibility of restoring. `fleet-down` lists them by name.

Nothing should be billing afterwards. The purge script asks the provider rather
than the state file; that is the only answer that counts.

## 9. If you lose access

The kubeconfig and the talosconfig are encrypted on your machine and copied to
both stores every time the cluster changes. To get them back:

```bash
task restore-artifacts PROVIDER=scaleway                 # from the primary store
task restore-artifacts PROVIDER=scaleway FROM=replica    # when that provider is the problem
```

`FROM=replica` reads the second store with its own credentials — in production a
different provider, which is the whole point: a copy you can only read from the
cloud that just failed is not a backup.

It will not overwrite a file that is already there unless you pass `FORCE=1`;
without it, the recovered copy lands beside the existing one as
`kubeconfig.restored`.

Nothing recovers these without `TF_VAR_encryption_passphrase`. There is no
second key and no reset.

## What is not proven

Honest as of 0.1.0 — the first release of this project that ships anything
proven, and the reason this document exists.

What **is** measured, with dates (`docs/status.md`):

- `task cluster-verify` scores **11/11 on Scaleway, on OVH and on Outscale** —
  the first two on 2026-08-19, Outscale on 2026-08-20.
- **Idempotency is three assertions**, and all three held 3/3 on all three
  clouds: an empty plan, the *same* nodes (name and `creationTimestamp`), and a
  kubeconfig that still reaches the apiserver. Two of the three can pass while
  the cluster was silently rebuilt.
- **The stored state has been opened.** An `encrypted_data` envelope under
  SSE-AES256, fetched back out of the `-backup` bucket at ANOTHER provider's
  endpoint using that provider's credentials, 2026-08-19. Not declared —
  downloaded and inspected.
- **Both upgrades landed on all three clouds**: Kubernetes v1.36.2 → v1.36.3
  and Talos v1.13.7 → v1.13.8 on 6/6 nodes, read back from the kubelets and from
  each node's own Talos API rather than from the tool that performed them.

What is still open:

- **Proxmox has never touched real hardware.** The module is in the repository;
  this release does not claim it. On Outscale, one Net created before the load
  balancer fix still refuses deletion and only the provider can clear it — see
  step 4.
- **The Scaleway path was walked end to end on 2026-08-17**, but from a machine
  that already had the toolchain — step 1 on a bare host is unwalked. OVH was
  driven by its operator, not by following this page.
- **The full failover.** Provider A treated as gone, state and artifacts fetched
  from B alone, cluster rebuilt on B. `envs/failover-*.tfvars.example` exists for
  exactly that and has never been run. The transport underneath it is proven; the
  failover is not.
- **The kubeconfig and the talosconfig have never been fetched back out of a
  real bucket.** The round trip is proven offline, `enc()` against `dec()` byte
  for byte (`scripts/dev/test-restore.sh`), and the tfstate's transport is proven
  — but `task restore-artifacts` itself has only ever run against local files.
- **Nobody has deployed with a non-empty `bucket_suffix`.** Six derivations agree
  in unit tests; the day someone sets one is the first day the backend, the image
  build and the verifier must agree on it for real.
- **A control plane used to revert after an upgrade on OVH.** The cause was ours
  — `siderolabs/qemu-guest-agent` in the schematic never starts on an image with
  no `hw_qemu_guest_agent`, so Talos never reached `Running` and never disarmed
  the upgrade fallback. It is gone, and the 2026-08-19 run shows `stage=running`
  with the fallback dropped on all six nodes. One clean run, not yet a habit.
- Every bucket name derives from `cluster_name` (its first segment, plus
  `bucket_suffix`) except the Talos image ones, which are hardcoded. In another
  account they may collide.

Found something this document gets wrong? That is the most useful bug report
this project can receive.
