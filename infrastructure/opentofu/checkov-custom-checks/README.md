# Checkov custom checks

The contract's own rules, expressed as checks instead of prose (#123).
Checkov ships no policy family for Scaleway, Outscale or Proxmox, so
without these three of this repository's four providers pass `.checkov.yaml`'s
hard gate in silence.

- `node_image_drift.py` — `CKV_OA_1`, provider-contract.md § "Node image drift".
- `inbound_default_drop.py` — `CKV_OA_2`, provider-contract.md § "Security groups".
  Covers Scaleway and OpenStack only: Outscale has no default-policy attribute and
  Proxmox declares no security group here.
- `inbound_no_world_open.py` — `CKV_OA_3`, Outscale inbound rules: no LITERAL /0 range
  (ranges coming from variables are not judged; static check, not a proof of the plan).

Loaded via `.checkov.yaml`'s `external-checks-dir`. `__init__.py` is
load-bearing: without it Checkov registers neither check and still exits 0.

Tested against the real tree, mutated and restored, by
`scripts/dev/test-checkov-custom-checks.sh` (`task security`).
