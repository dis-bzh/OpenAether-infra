# purge-orphans — safety net for orphaned cloud resources

**Last resort**, for when a cluster's resources outlive their controller: a
management destroyed before its CAPI children, a failed `edge-down`, a lost
OpenTofu state. Every other case goes through `task cluster-down` / `task
edge-down` / `task infra-down`, which delete cleanly **and** update the state.

These scripts talk to the provider API directly: they ignore the OpenTofu state
and do not update it. They target the WHOLE project, not one cluster — only run
them on an account whose expected contents you know. If another cluster is
live on the same provider, or you already know the exact resource(s) to
remove (e.g. from `verify-provider-clean.py`'s output), use the scoped
`../delete-openstack-resource.py <kind> <id>` instead — it touches nothing else.

```bash
source .env.sh
python3 scripts/ops/purge-orphans/scaleway.py           # dry-run: prints the target project, then lists targets
python3 scripts/ops/purge-orphans/scaleway.py --apply --project-id=<the id it printed>   # deletes
python3 scripts/ops/purge-orphans/ovh.py --apply --project-id=<the id it printed>
python3 scripts/ops/purge-orphans/outscale.py --apply --project-id=<the id it printed>
```

Every run starts with `Target: …`, the project the credentials in your environment
reach (`SCW_DEFAULT_PROJECT_ID`, `OS_PROJECT_ID`; Outscale has no project, so it is the
access key id). `--apply` without `--project-id=<that id>` is refused with exit 2 before any
API call, and so is an id that does not match, in a dry run too. Read the id before you repeat
it: a wrong `.env.sh` is the mistake this catches (infra #342). `task purge-orphans` takes
`PROJECT_ID=<id>` next to `APPLY=1`.

Deletion order is dictated by dependencies (already encoded): servers → load
balancers → public IPs → volumes → routers/route tables → internet gateway →
security groups → subnets → network.

409 / `ResourceConflict` on the first pass is normal (ports or NICs not released
yet): **re-run** until nothing more is deleted. A stubborn network usually keeps
residual DHCP ports; delete those first (the OVH script does).

⚠️ **Check volumes, not just servers.** A terminated VM can leave its root volume
behind. Scaleway looked clean on servers/LB/IPs while 7 block volumes had been
billing for three days. Talos images and their snapshots are deliberately kept
and never touched by these scripts.
