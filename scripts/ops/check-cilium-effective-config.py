#!/usr/bin/env python3
"""Asserts the EFFECTIVE settings in the rendered Cilium ConfigMap — the values
the cluster actually runs — rather than the `--set` flags that produced them.

Why this check exists
----------------------
A `--set` flag with a typo passes `helm template` silently: rc 0, empty
stderr, because an unknown key just becomes another entry in the chart's
`.Values` that nothing reads. `task render-check` only diffs the rendered
artifact against itself, so regenerating after a typo is green. And
`check-cilium-parity.py` compares the `--set` flags to the CAPI children's
`values:` — a key it cannot resolve in either side is silently skipped, not
flagged. Neither reads what actually lands in `cilium-config`'s `data:`
block, which is the file the agent boots from.

Usage: python3 scripts/ops/check-cilium-effective-config.py [manifest-file]
  Defaults to the committed production cilium.yaml.
"""
from __future__ import annotations

import pathlib
import sys

import yaml

INFRA = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = (
    INFRA / "infrastructure" / "opentofu" / "cluster" / "bootstrap-manifests" / "cilium.yaml"
)

# Effective ConfigMap key -> required value. Short and curated on purpose,
# same spirit as check-cilium-parity.py's CHECKED list: settings where a
# silent chart default breaks the datapath or the Istio ambient mesh, not
# every key the chart writes.
REQUIRED: dict[str, str] = {
    "ipam": "kubernetes",
    "kube-proxy-replacement": "true",
    "bpf-lb-sock": "true",
    "bpf-lb-sock-hostns-only": "true",
    "cni-exclusive": "false",
    "enable-bpf-masquerade": "true",
    "enable-host-legacy-routing": "false",
    "enable-wireguard": "true",
    "enable-node-selector-labels": "true",
}


# With Hubble on (the opt-in dropped-flow variant, cilium-hubble-drops.yaml) the export must stay the narrow one:
# only DROPPED/ERROR flows, a field mask (no payload), stdout (collected as a pod log) and no TCP listener on the host.
HUBBLE_REQUIRED: dict[str, str] = {
    "hubble-export-file-path": "stdout",
    "hubble-listen-address": "",
    "hubble-disable-tls": "true",
}


def hubble_problems(data: dict) -> list[str]:
    if data.get("enable-hubble") != "true":
        return []
    out = []
    for key, want in HUBBLE_REQUIRED.items():
        got = data.get(key)
        if got != want:
            out.append(f'  `{key}` = {got!r} with Hubble on — expected "{want}"')
    allow = data.get("hubble-export-allowlist", "")
    if "DROPPED" not in allow or "FORWARDED" in allow or "TRACED" in allow:
        out.append(f"  `hubble-export-allowlist` = {allow!r} — expected only DROPPED/ERROR verdicts")
    if not data.get("hubble-export-fieldmask", "").strip():
        out.append("  `hubble-export-fieldmask` is empty — the export would carry whole flows")
    return out


def load_configmap(path: pathlib.Path) -> dict:
    for doc in yaml.safe_load_all(path.read_text()):
        if not isinstance(doc, dict):
            continue
        meta = doc.get("metadata", {}) or {}
        if doc.get("kind") == "ConfigMap" and meta.get("name") == "cilium-config":
            return doc.get("data", {}) or {}
    sys.exit(f"❌ no cilium-config ConfigMap found in {path}")


def main() -> int:
    manifest = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_MANIFEST
    if not manifest.is_file():
        sys.exit(f"❌ {manifest} does not exist")
    data = load_configmap(manifest)

    problems: list[str] = []
    for key, want in REQUIRED.items():
        got = data.get(key)
        if got is None:
            problems.append(f'  `{key}` ABSENT from cilium-config — expected "{want}"')
        elif got != want:
            problems.append(f'  `{key}` = "{got}" — expected "{want}"')

    problems += hubble_problems(data)
    if problems:
        print("❌ cilium-config's effective settings do not match what the cluster must run:")
        print("\n".join(problems))
        print(
            f"\nChecked against {manifest}. A --set typo in "
            "render-bootstrap-manifests.sh reaches this file silently (helm template "
            "exits 0 on an unknown key) — compare this against the production block."
        )
        return 1

    print(f"OK — cilium-config carries all {len(REQUIRED)} required effective settings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
