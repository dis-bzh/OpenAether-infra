# Security architecture — assets, administration paths, how each is authenticated and why, privileged accounts, accepted deviations

🇫🇷 [Version française](security-architecture.fr.md)

> Written to answer ANSSI rules on a documented security architecture, a risk analysis of the administration system, a justified choice of authentication means and an
> inventory of privileged accounts (audit ids ADM/F13, ADM/F11, and the architecture parts of NET/F07). It describes the platform **as the code and the documents
> of this repository have it**; it is not a measurement and not an assessment by a third party. Nothing in it claims compliance with any ANSSI document.
> The network side is `network.md`; keys are `key-management.md`; the CI/CD side is `threat-model.md`.

## 1. What is being protected

| Asset | Where it lives | Worst case if it is lost or exposed | Principal protections |
|---|---|---|---|
| The cluster's trust root (Talos PKI, K1) and the admin credentials (K2) | tfstate, machine configs, the operator's disk, both artifact buckets | Full control of every node and the Kubernetes API | client-side encryption of state and artifacts (K5, K6); private network; bastion; mTLS |
| Kubernetes Secrets and the data on node disks | etcd (secretbox, K3), LUKS volumes (K4) | Disclosure of every secret value | encryption at rest; keys held in the state and the machine configs |
| OpenBao (every application secret, the PKI intermediate) | 3 raft replicas on node volumes, snapshots in restic | Disclosure or forgery of every platform credential and certificate | seal key (K11) in escrow, recovery shares per operator, Kubernetes-auth roles with short TTLs, an audit log |
| Application data (Zitadel and Grafana databases, Longhorn volumes) | CNPG on local-path volumes, backups | Loss or disclosure of identities and dashboards | restic client-side encryption, CNPG WAL archive (server-side only), LUKS on Longhorn |
| The backups and the state replica | buckets at two providers | The loss of the way back | two providers, client-side encryption, key custody (`backup-policy.md`) |
| Logs and audit trails | Loki, bastion journal, provider audit trails | Loss of the means to investigate | `incident-response.md`; bastion logs pulled off the VM; provider trails exported by hand |
| The source, the pins and the pipeline | GitHub repositories, Actions, Renovate, the `sandbox` environment | A hostile change reaching a cluster | `threat-model.md` |

## 2. Administration paths

Every way a human or an automation can change the platform, and what stands in front of it. **Anything not listed is not meant to exist**; finding one is an incident.

| # | Path | Who | Authentication | Authorization | Where it is recorded | Notes |
|---|---|---|---|---|---|---|
| P1 | Operator workstation to the bastion, SSH 22 | operators; CI (`CI_BASTION_SSH_PRIVATE_KEY`) | SSH key, or an 8 h certificate from the CA; hardware `sk-` keys checkable at plan time for named operators | the `admin_ip` allowlist (security group), a shared account or one unix account per operator | sshd login line with the key fingerprint; the journal pulled by `bastion-logs-pull.sh` | `bastion_ssh_keys` is the automation and break-glass path and is not hardware-checked |
| P2 | Bastion tunnel to the Talos API, 50000 | operators; the Talos provider during `tofu apply` | Talos client certificate (mTLS) | role in the certificate: `os:admin` (one year) or `os:reader` (hours) | Talos logs on the node | the one admin `talosconfig` is shared by every task and person |
| P3 | Bastion tunnel, or the API load balancer limited to `admin_ip`, to the Kubernetes API, 6443 | operators; Flux (in cluster) | client certificate `O=system:masters` (**bypasses RBAC and cannot be revoked**), or other RBAC subjects | RBAC (`task rbac-review` lists the bindings) | API audit log on the control plane, not collected off the node | named, short-lived identities are planned work, not done |
| P4 | `bao_admin` to OpenBao, through `kubectl exec` | operators holding `kubectl` admin | a ServiceAccount token is exchanged for an OpenBao token inside the pod: no OpenBao token crosses the terminal | policy `openaether-admin` (cannot mint tokens, write policies or mounts, seal, rekey or touch raw storage); `openaether-reader` is read-only | OpenBao audit log (into Loki, no rule reads it) | whoever can create a token for the ServiceAccount `openaether-admin` is an OpenBao admin: Kubernetes admin implies it |
| P5 | Break-glass root token for OpenBao | the quorum of recovery-share holders | k of n PGP-decrypted recovery shares, through the `openbao-breakglass` role (10 to 15 minutes) | root, then revoked | OpenBao audit log | measured: 2 of 3 shares produced a token on a real cluster |
| P6 | The UIs (Grafana, Zitadel, OpenBao UI) through the Gateway, over the bastion tunnel | operators | Grafana: Zitadel OIDC (MFA forced by the apps policy on a new instance) or the local admin login; Zitadel: its own login; OpenBao UI: an OpenBao token | per application; Grafana roles from the `grafana-admin` project role | application logs | **Every route on the Gateway also answers over the application load balancer when `deploy_app_lb` is true**: the route's own login is its only protection (`network.md`, section 6) |
| P7 | The provider console and API | the account owner(s) | the provider's own login, and the API keys K8 | the provider's IAM (not managed here) | the provider's audit trail, **not exported by anything here** | outside this repository; who can change IAM and security groups is part of the incident question |
| P8 | The object stores | the operator, the clusters | S3 key pairs K7 (account-wide by default) | the provider's bucket policy (none set here) | the provider's logs | a stolen pair can delete the backups: no object lock |
| P9 | GitHub: pull requests, releases, Actions, the `sandbox` environment | the maintainer; Renovate; Cléa | the maintainer's account; the App's tokens | rulesets as code (`.github/rulesets`): pull request required, no force-push; zero required approvals while there is one maintainer | GitHub audit | `threat-model.md` |
| P10 | The Image Factory and registries (pull only) | nodes, CI | none (public) | n/a | n/a | pinned by digest where the lint can check it (`supply-chain.md`) |

**Authentication means, and why these.** Talos and Kubernetes use client certificates because that is what they offer without an extra always-on service; the cost is that
a certificate cannot be revoked, only its CA replaced, which is why `os:reader` short-lived files exist for read-only work and why K1 rotation is documented. SSH to the bastion
uses keys, with certificates and hardware keys as opt-ins, because a bastion is the one host that must be reachable when everything else is down. OpenBao uses Kubernetes-auth
roles with short TTLs because a long-lived OpenBao token in a laptop is the risk it was designed away from. Humans on application UIs use Zitadel OIDC with MFA forced, because that is the identity
provider the platform runs. **What was not chosen**: an OIDC issuer for the apiserver, an SSH CA operated as a service, or a WireGuard control plane, each of which needs an always-on host outside every cluster;
decision #82 (2026-10-03) keeps the bastion, hardened in place, until there are two or more operators or a stateful service whose restore has been run.

## 3. Privileged accounts

The inventory is **a table of roles, kept current by hand**; the names of the people holding each live in a private copy beside the tfvars (this repository is public). Review at every staff change and each quarter (`release-checklist.md`, "Quarterly security review").

| Account or credential | Grants | Held by | Created by | Removed or revoked by |
|---|---|---|---|---|
| Shared bastion account `bastion`, keys of `bastion_ssh_keys` | SSH to the bastion, hence the tunnels | the operator(s) and CI | tfvars | remove from the tfvars AND replace the bastion, or `revoked_keys` (`admin-access.md`) |
| Named bastion accounts (`bastion_admins`), SSH CA certificates | the same, attributable to a person | one per person | tfvars; the CA | stop signing; remove and replace the bastion |
| Admin `talosconfig` (`os:admin`) | every Talos API | the operator(s) | the Talos provider | only by replacing the Talos CA (`key-management.md`, K1) |
| Admin `kubeconfig` (`system:masters`) | everything in Kubernetes, bypassing RBAC | the operator(s) | the Talos provider | only by replacing the CA; `rbac-review` finds *other* bindings |
| `os:reader` talosconfig | read-only on the Talos API | anyone issued one | `task talosconfig-new` | expires (8 h default) |
| ServiceAccounts `openaether-admin`, `openaether-reader` and the OpenBao roles of the same names | OpenBao admin or read-only (tokens 1 to 8 h) | whoever can create tokens for them: Kubernetes admins | the apps layer | disable the role, or remove the Kubernetes admin |
| `openbao-breakglass` role and the recovery shares | a root token with a quorum | the holders of the PGP keys in `openbao_recovery_pgp_keys` | `sys/init` | supersede with `bao operator rekey`; a share cannot be revoked |
| Zitadel first admin (`zitadel/admin`) and the humans in Zitadel | IAM owner; Grafana admin through roles | the first administrator, then named users | the apps layer (initial password in OpenBao, forced change) | disable the user in the console |
| Grafana local admin, MinIO root (local clusters) | local admin logins | operators | the apps layer | rotate (apps inventory) |
| Object-store keys K7, provider keys K8 | the buckets, the infrastructure | operator(s), CI `sandbox` | the provider | revoke at the provider |
| Provider console accounts | everything at the provider | the account owner(s) | the provider | the provider |
| GitHub maintainers, the `sandbox` environment's reviewers, the Renovate and Cléa tokens | merge, release, run the cloud workflow | the maintainer | GitHub | GitHub settings; `supply-chain.md` lists the tokens |

Not covered: no account has a scheduled expiry except the short-lived ones named above; a 1-year expiry policy for Zitadel administrators is an application setting, not set here. A departing person is handled by `incident-response.md`, section 7, last rows.

## 4. Corrections made to `admin-access.md`

The audit found two statements that the code contradicts; both are fixed in the same change as this page.

1. Section 6 said the gateway sits on a private address with "nothing public". With `deploy_app_lb = true` the application load balancer forwards public 80/443 to the Gateway's NodePorts, so every route answers anyone who sets its Host header (`network.md`, section 6; `OpenAether-apps/docs/public-exposure.md`). The private address is the *administration* path.
2. The "named policies" paragraph showed bare `bao token create` commands, which need a token this platform does not hand out: the page itself says no root token exists, and `openaether-admin` explicitly cannot mint tokens. The section now says how an operator gets an admin or read-only identity (`bao_admin`, with the ServiceAccount of the same name).

## 5. Accepted deviations

| Deviation | Why accepted | Where recorded |
|---|---|---|
| Shared `system:masters` kubeconfig, not revocable | Kubernetes offers no client-certificate revocation; named short-lived identities are not built | `admin-access.md`, `key-management.md` |
| One administration `talosconfig` for every task and person | Talos roles exist; per-person certificates are not issued by any task | `admin-access.md` |
| SSH bastion plus mTLS instead of IPsec or an OIDC control plane | Decision #82: an always-on host outside every cluster would be one more thing to keep alive for one operator | `network.md`, section 7 |
| Single operator: no separation of duties, no second custodian | The project has one maintainer | `key-management.md`, section 3 |
| Machine secrets delivered over the Talos maintenance API | Upstream design | `first-cluster.md`, "Residual risk" |
| Shared break-glass SSH account beside named ones | Automation and break-glass | `key-management.md` |
| Object lock and versioning on the buckets are opt-in (`backup_immutability`), unverified on any provider; the in-cluster S3 keys are the operator's unless dedicated pairs are given | Provider support and the key policy are not decided | `backup-policy.md`, sections 3 and 4 |

## 6. Review

Re-read with every new administration path, authentication means, privileged account, provider or deviation; after each incident; each quarter with the checklist; at least yearly with the audit register (`audit-register.md`). A path with no row in section 2 is a defect, whether it is documented elsewhere or not.
