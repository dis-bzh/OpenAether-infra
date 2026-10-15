# Audit register — audits, reviews, and the corrective actions they opened

🇫🇷 [Version française](audit-register.fr.md)

> Written to answer ANSSI rules on a periodic audit of the security measures and the follow-up of its corrective actions (audit id SCC/F11, the audit-register part). It is a **log kept by hand**:
> a row is added when something is audited or reviewed, an action when it is decided, and both are closed by saying what was done and at what rung (mocked, local Docker, real cloud). It records
> what happened; it is not itself a control. It claims no compliance with any ANSSI document.

## 1. Cadence

| What | When | Who | Output |
|---|---|---|---|
| Quarterly security review | every quarter, and at each release | the maintainer | the checklist in `release-checklist.md` ("Quarterly security review"); a row in section 2 |
| Yearly audit | once a year, and after a change of scope (a new provider, a second maintainer, a regulated user) | the maintainer, preferably with a reader who did not write the code | the audit and its findings; rows in sections 2 and 3 |
| After an incident | every incident closed in `incident-response.md` | the incident lead | a row in section 2; corrective actions in section 3 |
| Disaster-recovery drill | yearly (`disaster-recovery.md`, section 5) | the maintainer | its result table; a row in section 2 |

A review or audit that finds nothing is still a row.

## 2. Audits and reviews

| Date | Kind | Scope | By | Result | Actions opened |
|---|---|---|---|---|---|
| 2026-10 | Self-audit against ANSSI documents: the GNU/Linux configuration guide (BP-028), the OpenSSH note (NT-007), the network and cloud recommendations (PA-022), cryptography and secrets (PA-079, PG-078, the RGS annexes), the hygiene guide, the software supply-chain guides | Both repositories, nine domains (cryptography and TLS, data and secrets, logging and detection, backup and resilience, administration and identity, network and cloud, operating system and bastion, supply chain and CI, platform) | An automated, AI-assisted review of the code and documents with a second pass trying to refute each finding; commissioned by the maintainer. **Not a third-party audit and not a compliance assessment** | About 130 findings confirmed (gap, partial, or documentation) after refutation; others refuted or left unverified. Evidence is `file:line` in the repositories | The hardening work listed in section 3, batch by batch; in the `[Unreleased]` section of `CHANGELOG.md` of both repositories |
| _next_ | Quarterly security review | | | | |

## 3. Corrective actions

One row per action that is **decided**, with the audit id it answers when there is one. The CHANGELOG states the rung of each; this table says whether it is done. Nothing below is released at the time of writing.

| Action | Audit ids | Status | Rung reached | Where |
|---|---|---|---|---|
| Bastion OS baseline (opt-in) | OSN/F04, F05, F07, F09, F03, TLS-15, LOG-08 | done, off by default | mocked + local Docker | CHANGELOG, `admin-access.md` |
| Bastion identity: named operators, SSH CA, hardware-key check, host-key pin | ADM/F05, TLS-13, TLS-16, OSN/F10, NET/F16 | done, off by default | mocked + local Docker | CHANGELOG, `admin-access.md` |
| Bastion Internet egress closed (opt-in) | ADM/F06, OSN/F14, SCC/F18, NET/F04 | done, off by default | mocked + local Docker | CHANGELOG, `admin-access.md` |
| Bastion logs off the VM | LOG-08 | done (manual cron) | mocked | CHANGELOG, `admin-access.md` |
| Ops verification tooling (encryption at rest, exposure scan, netcheck, RBAC review) | HYG M37/M38 | done | mocked + one cluster read | CHANGELOG, `admin-access.md` |
| Supply chain: provider locks, image checksum lane, SBOM, sandbox environment, rulesets as code | SSDLC CICD-AIP, PROV-REC03, SCM-REC06/-07 | done | mocked/static | `supply-chain.md` |
| Patch policy and signals | HYG-M34 | done (a target, one person) | static | `patching.md`, `hardening.md` section 4 |
| Passphrase hygiene for state, artifacts, snapshots | PG-083, PA-079 | done | mocked | `first-cluster.md` |
| Security documentation set: keys, incidents, backup, recovery, network, architecture, hardening, threat model, components, this register | DP-06/07/17, TLS-12/19/20, F-BKP-07/10/16, LOG-17, ADM/F11/F13, NET/F07/F09, OSN/F13 (stage 0)/F18, SCC/F11 | **done (documents)**: nothing in them was run on a cluster | read against the code; flow tables checked by a test | this set |
| A first disaster-recovery drill and a first incident drill | F-BKP-16, LOG-17 | **open** | n/a | `LAB-CHECKLIST` of the hardening work (B13) |
| Object lock or versioning on the state, artifact, snapshot, backup and log buckets; a bucket and a key pair of their own for each store | F-BKP-10, F-BKP-01, F-BKP-04, LOG-07, F05, DP-05 | **partly done, opt-in**: `backup_immutability` and the `OA_*_S3_*` pairs exist; no provider verified, no key policy shipped, no operator-side locked copy | mocked/static | `backup-policy.md` sections 3 and 4 |
| Named, short-lived Kubernetes identities in place of the shared `system:masters` kubeconfig | OSN/F20 | **open** | n/a | `security-architecture.md` |
| Node network filtering: explicit inter-node lists, then an opt-in host firewall | OSN/F13 | **open** (stage 0 is `network.md`) | n/a | `network.md` section 6 |
| Talos node baseline: sysctls, kernel arguments, SELinux, secure boot | OSN/F01, F02, F03 | **open** | n/a | `hardening.md` section 3 |
| Fill the key-escrow and second-custodian gap (a second person) | DP-06, TLS-20 | **open**, depends on a second operator | n/a | `key-management.md` section 3 |

When an action is done, change its status and name the rung; when it is dropped, say why. An action open for more than a year without a reason in the row is a finding of the next audit.

## 4. Review

Add a row at every audit, review, drill and closed incident; re-sort the open actions each quarter.
