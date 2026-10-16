# Hardening baseline — what Talos gives by design, what this repository adds, and what is a written deviation

🇫🇷 [Version française](hardening.fr.md)

> Written to answer ANSSI recommendations on system configuration and on OpenSSH usage (the GNU/Linux configuration guide BP-028 and the OpenSSH note DAT-NT-007), and on
> vulnerability watch (audit id OSN/F18; DP-17 for the one residual risk). It is a mapping table and a register of deviations: **a row saying "by design" is what
> the upstream documentation of Talos says, not something measured on this platform**, and no row is a claim of compliance with any ANSSI document. Requirement numbers are the ones the audit recorded; read the guide for what each asks.
> Not here, written elsewhere: patching deadline and signals (`patching.md`), the pins and the supply chain (`supply-chain.md`), upgrades (`upgrade.md`), the network (`network.md`).

Two kinds of host are hardened differently. **Talos nodes** have no shell, no SSH, no package manager and are managed only through an authenticated API: most of a Linux guide does not
apply to them, and what applies is mostly a matter of what Talos ships. The **bastion** is an ordinary Ubuntu VM and is where the Linux guide applies in the usual sense.

## 1. Talos nodes: mapping

Legend: **Design** = true of Talos by construction (upstream); **Control** = something this repository sets; **Deviation** = a written difference from the recommendation.

| Theme (audit ids) | Design | Control here | Status |
|---|---|---|---|
| Minimal system, no unneeded software (BP-028 minimization) | No package manager, no shell, no SSH daemon, read-only root | none needed | Design |
| Administration channel (NT-007 does not apply: no sshd on nodes) | Talos API over mTLS with roles (`os:admin`, `os:reader`) | Access only through the bastion tunnel; `task talosconfig-new` for short-lived read-only files | Design + control; the shared admin file is a deviation (`security-architecture.md`) |
| Disk encryption (BP-028 storage themes) | LUKS2 support | STATE and EPHEMERAL (and user volumes) encrypted, key K4 in the machine config | Control. Limit stated in the module: it does not protect against a runtime compromise |
| Secrets at rest in Kubernetes | secretbox or aescbc only | secretbox (K3) | **Deviation**: XSalsa20-Poly1305 is not among the AEAD modes PA-079 R12 lists; Talos offers nothing else AEAD-like (`upgrade.md`) |
| Boot integrity: Secure Boot, signed UKI verification (R2, R3, R6) | Talos images are UKI-capable, verification needs Secure Boot enrolment | **Not enabled** on any provider; no check reads the secure-boot state | **Deviation / not done**: needs an image variant, a schematic change and OVMF on Proxmox, validated on a real host; Scaleway, OVH and Outscale custom images do not expose it as far as this repository knows. Provider limitation, not a decision |
| Kernel command line, SELinux (R8, R37, R46) | Talos kernel is KSPP-aligned (`slab_nomerge`, `pti=on` per the audit); SELinux runs permissive | no extra kernel arguments (`machine.install.extraKernelArgs` unset) | **Deviation**: mitigation arguments such as `spectre_v2`, `mds`, `init_on_alloc` are not set; completed with the node baseline work (audit batch B23) |
| sysctl values (R9, R10, R12, R13) | Talos sets a KSPP-oriented default set | no `machine.sysctls` set | **Open**: the values to set and the justified exceptions are decided with the node baseline (B23). Written exceptions already known: `net.ipv4.ip_forward=1` (Kubernetes and Cilium need routing), `kernel.pid_max=262144` (above the guide's value, Kubernetes pod density), module loading after boot |
| Kernel modules (`modules_disabled`) | Talos enforces **signed** modules instead of freezing module loading | none | **Deviation, by design**: Cilium (tunnels, WireGuard) and Longhorn (iSCSI) load modules after boot, so `kernel.modules_disabled=1` is not used; signature enforcement is the compensation (upstream, not verified here) |
| Audit and logs (R71, R73, R76) | Service and kernel logs on the node; a kube-apiserver audit log on control planes | Bastion logs are pulled and uploaded. Opt-in, off by default: `node_log_forwarding` sends Talos service and kernel logs over plain TCP to a receiver on the host network, and `cilium_hubble_drop_log` writes network-policy drops to the cilium-agent log. The API audit file is collected by the apps repository's opt-in control-plane collector | **Open until switched on and run on a cluster** (mocked/static only so far, `LAB-CHECKLIST` B22); with the switches off, the node logs still vanish with the node and `incident-response.md` section 4 says to copy them first. The transport is plaintext TCP: private network only |
| Updates (R61) | Immutable image replaced by upgrade, not patched in place | Procedure `upgrade.md`; deadline `patching.md`; Renovate and Cléa | Control; no automatic application, by design |
| Pod security (R64, R65) | n/a | Pod Security Admission baseline on managed namespaces; Kyverno policies, mostly in Audit | **Open**: Enforce is a later decision (apps) |
| Machine secrets delivered to a new node (DP-17) | Maintenance-mode apply with an unverifiable certificate | private network, SSH tunnel, bastion-only 50000 (OVH, Outscale) | **Residual risk**: `first-cluster.md`, "Residual risk: the maintenance-mode apply" |

## 2. Bastion: mapping

All opt-in and **off by default**: with the defaults the cloud-init is byte for byte what 0.1.0 shipped (`admin-access.md` for the how, `CHANGELOG.md` for the rung). Requirement numbers are those named in the CHANGELOG entries.

| Theme | Without the options | With the options | Status |
|---|---|---|---|
| sysctl, kernel hardening (R9, R11, R12, R14) | Ubuntu defaults | `bastion_baseline` sysctl file, without `modules_disabled` and without the ARP options | Control (opt-in). Deviation: modules stay loadable (the Ubuntu kernel loads drivers on demand) |
| Audit (R73), journald | Ubuntu defaults | auditd with execve/`/etc`/mount/module/ptrace rules and no `-e 2` (immutable) so a rule can be fixed without a reboot; journald persistent, 200 MB, 90 days | Control (opt-in). Deviation: no immutable audit rules |
| Mounts, umask, sudo, packages (R28, R29, R36, R38, R58) | Ubuntu defaults | `/var/tmp` noexec, `/boot` 700, umask 0077, sudo restricted, no tcpdump/netcat on new VMs | Control (opt-in) |
| sshd directives (NT-007 R14, R15, R23, R24, R26) | key-only, no root, `AllowGroups bastion-admins`, modern ciphers, `MaxAuthTries 3`, `LoginGraceTime 30`, keep-alives | `LogLevel VERBOSE`, `StrictModes`, `PermitUserEnvironment no`, `AllowStreamLocalForwarding no`, `GatewayPorts no`, `RevokedKeys`, `AcceptEnv` commented out | Control (the base is always on) |
| Host key (NT-007 R6) | Trusted at first use | `OA_BASTION_PIN_HOSTKEY` keeps and checks it | Control (opt-in); a host certificate is not done |
| Identity and revocation (NT-007 R30, PA-022 R21) | One shared account | `bastion_admins`, SSH CA, `revoked_keys`, optional hardware-key check | Control (opt-in) |
| Egress (PA-022 R10) | 80/443 to anywhere | `bastion_internet_egress = closed` | Control (opt-in): the bastion is patched by replacement |
| Key exchange: post-quantum hybrid (TLS-19) | `KexAlgorithms` is an explicit classical list | not available on Ubuntu 22.04's OpenSSH 8.9 | **Deviation**: the hybrid `sntrup761x25519` comes with a bastion image on 24.04, which replaces the bastion; `key-management.md` section 5 |

**Tunnelling (NT-007 R5, as the audit reads it).** The recommendation is to avoid SSH forwarding unless needed. The bastion exists to forward: the nodes have no public address, and a TCP
forward is the only path from an operator's machine to the Talos API (50000) and the Kubernetes API (6443). Compensations: `AllowTcpForwarding yes` is paired with **`PermitOpen` limited to ports 6443 and 50000** (and 8200 only
on the legacy egress; the closed mode drops it), `X11Forwarding no`, key-only login restricted to the `bastion-admins` group, the `admin_ip` allowlist in front of port 22, and the optional named accounts and certificates.
Not compensated: `PermitOpen` names ports and not hosts (`*:6443`), so a forward to any reachable address on those ports is allowed; the destination restriction is the security group and the closed egress.

## 3. Written deviations (the register)

| # | Deviation | Guide | Reason | Compensation | Owner decision |
|---|---|---|---|---|---|
| H1 | No Secure Boot / signed UKI verification | BP-028 R2, R3, R6 | Image variant, schematic and OVMF work; not exposed by three providers | Image checksum lock (`supply-chain.md`) for what is downloaded; encrypted disks | Open until a provider qualification |
| H2 | secretbox instead of an AEAD mode for etcd Secrets | PA-079 R12 | Talos offers only secretbox and aescbc | Strong key, never leaves the state and machine configs; a KMS would be circular inside the cluster | Revisit with a KMS outside the cluster |
| H3 | `modules_disabled` not set on nodes | BP-028 sysctl and module rules (audit F03) | Cilium and Longhorn load modules after boot | Talos signed-module enforcement (upstream) | Permanent unless the CNI changes |
| H4 | `ip_forward=1`, `pid_max=262144`, other sysctls at Talos defaults | BP-028 R9, R12, R13 | Kubernetes and Cilium need routing and a high pid ceiling; the rest is not decided yet | none beyond Talos defaults | Closed by the node baseline batch (B23) |
| H5 | SELinux permissive, mitigation kernel arguments absent | BP-028 R8, R37, R46 | Talos defaults | none | Closed by B23 if decided |
| H6 | SSH forwarding enabled on the bastion | NT-007 R5 | It is the admin path | `PermitOpen` ports, group, allowlist | Permanent while the bastion is the design (#82) |
| H7 | Classical KEX on the bastion, no post-quantum hybrid | TLS-19 | OpenSSH 8.9 on Ubuntu 22.04 | inner TLS and mTLS of the tunnelled protocols | Bastion image move |
| H8 | Machine secrets sent over the unauthenticated maintenance API | DP-17 | Talos bootstrap | private network, tunnel, bastion-only 50000 | Permanent (upstream) |
| H9 | Node and API audit logs are not shipped by default | BP-028 R71 | The shipping is opt-in (`node_log_forwarding`, `cilium_hubble_drop_log`, the apps audit collector) and has not run on a cluster; Talos log transport is plaintext TCP | copy by hand before replacement; the receiver lives in the cluster it protects (a second sink is not built) | Open until the lab has run it |

## 4. Vulnerability watch and patch routine

The deadline and the signals are `patching.md`; this section is the routine that makes them happen. **It is a calendar for one person, not a service.**

| When | What | Where the result goes |
|---|---|---|
| Daily, automatic | Renovate PRs (7-day release age, never auto-merged; `vulnerabilityAlerts` bypass the age); Cléa's report with advisories on the pins (OSV) and pins more than two minors behind | The PRs and the Cléa issue/report |
| Weekly, automatic | `image-digests.yml` (Flux tags moved), the SBOM job with Trivy on bootstrap images | Workflow results |
| Every week, by hand (15 minutes) | Read the **CERT-FR** alert and advisory feed for the products below; the **GitHub Security Advisories** of Talos, Kubernetes, Cilium, Flux, OpenTofu and the providers; the Talos and Kubernetes release notes | An issue per relevant advisory, naming the component, the advisory, and the decision (patch / waive until `<date>` / not affected) |
| Within 30 days of a fix (7 days if exploited in the wild or reachable from the Internet) | Merge the bump through the rung it needs (`CONTRIBUTING.md`), or waive it in writing with an expiry | The PR / the waiver issue; a VEX statement when a scanner finding does not apply (`component-selection.md`) |
| Each quarter | The end-of-support calendar check and the register review (`release-checklist.md`, "Quarterly security review") | `audit-register.md` |

Products to watch: Talos Linux, Kubernetes, Cilium, Flux, OpenTofu and its providers, Ubuntu (the bastion image), OpenSSH, and, in `OpenAether-apps`, Istio/Envoy, cert-manager, CNPG/PostgreSQL, OpenBao, Kyverno, Longhorn, Zitadel. A new product on the platform gets a row in `component-selection.md` and a name on this list.
A notice found outside the routine (CERT-FR, a provider, a mailing list) is handled the same way and opens an incident entry if the platform is exposed (`incident-response.md`).

## 5. Review

Re-read with each Talos or Kubernetes minor, each change of the bastion baseline, each audit, and at least yearly. The rows marked Open are closed or re-justified when the node baseline batch lands; until then they stay here.
