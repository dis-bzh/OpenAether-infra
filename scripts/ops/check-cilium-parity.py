#!/usr/bin/env python3
"""Checks that the CHILD (CAPI) clusters' Cilium stays aligned with the foundation.

Why this check exists
---------------------------
The parent foundation configures Cilium through `helm template --set …` in
`scripts/bootstrap/render-bootstrap-manifests.sh`; the CAPI children configure
it through the `values:` block of a HelmRelease in
`OpenAether-apps/apps/clusters/*.yaml`. Two formats, two repositories, no
mechanical link: the drift is silent and only shows up in production.

It cost dearly on 2026-07-26: the children had lost `ipam.mode=kubernetes`.
The chart default (`cluster-pool`) ignores the `clusterNetwork.pods` declared
by CAPI and carves pod CIDRs out of 10.0.0.0/8 — the very /8 where the node
subnets live (10.20.0.0/24 on OpenStack, 10.0.0.0/24 for OVH, Outscale and
Proxmox). The parent sets it explicitly, for exactly
that reason.

What the check does
-----------------------
It compares, key by key, a restricted set of "structural" settings between the
render script's production block and each child's `*-cilium` HelmRelease.
INTENDED differences are declared in EXCEPTIONS with their rationale: an
undeclared divergence fails the check.

Usage: python3 scripts/ops/check-cilium-parity.py   (exit 1 on drift)
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

INFRA = pathlib.Path(__file__).resolve().parents[2]
RENDER_SH = INFRA / "scripts" / "bootstrap" / "render-bootstrap-manifests.sh"
CLUSTERS = INFRA.parent / "OpenAether-apps" / "apps" / "clusters"

# Settings where a parent/child mismatch breaks the datapath or the mesh.
# Deliberately short: we do NOT compare what legitimately depends on the cluster
# (replicas, k8sServiceHost…), only what must be identical everywhere.
CHECKED = [
    "ipam.mode",
    "kubeProxyReplacement",
    "socketLB.enabled",
    "socketLB.hostNamespaceOnly",
    "cni.exclusive",
    "bpf.masquerade",
    "bpf.hostLegacyRouting",
    "encryption.enabled",
    "encryption.type",
    "nodeSelectorLabels",
    "cgroup.autoMount.enabled",
    "cgroup.hostRoot",
    "k8sServiceHost",
    "k8sServicePort",
    # Not datapath, but the same class of silent failure: a child without these
    # serves no CNI metrics at all while the parent is monitored, and nothing
    # says so.
    "prometheus.enabled",
    "operator.prometheus.enabled",
]

# Accepted mismatches: key -> reason. Any other mismatch is a regression.
EXCEPTIONS: dict[str, str] = {}


def parse_parent() -> dict[str, str]:
    """Extract the --set flags from the script's PRODUCTION block, not the local one."""
    text = RENDER_SH.read_text()
    # The prod block is the one following the `else` of the LOCAL_MODE test.
    marker = "# Production mode"
    if marker not in text:
        sys.exit(f"❌ production block not found in {RENDER_SH}")
    prod = text.split(marker, 1)[1]
    values: dict[str, str] = {}
    for key, val in re.findall(r"--set\s+([\w.]+)=(\S+)", prod):
        values[key] = val.strip("\\").strip('"')
    return values


def flatten(node, prefix: str = "") -> dict[str, str]:
    out: dict[str, str] = {}
    if isinstance(node, dict):
        for key, val in node.items():
            out.update(flatten(val, f"{prefix}{key}."))
    else:
        out[prefix.rstrip(".")] = str(node).lower() if isinstance(node, bool) else str(node)
    return out


def parse_children() -> dict[str, dict[str, str]]:
    children: dict[str, dict[str, str]] = {}
    for path in sorted(CLUSTERS.glob("*.yaml")):
        if path.name == "kustomization.yaml":
            continue
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
                continue
            if doc.get("spec", {}).get("chart", {}).get("spec", {}).get("chart") != "cilium":
                continue
            children[path.name] = flatten(doc["spec"].get("values", {}))
    return children


def missing_parent_keys(parent: dict[str, str]) -> list[str]:
    """CHECKED keys the production block does not set at all.

    Always a defect, never a legitimate omission: every CHECKED key is
    expected in the production --set list, so its absence here means either
    the flag was removed, or misspelled — which makes parse_parent() capture
    it under a different name than CHECKED expects, e.g.
    `socketLB.hostNamespaceOnl` instead of `socketLB.hostNamespaceOnly`. The
    per-child loop below cannot tell that apart from "this cloud legitimately
    doesn't set it", so it has to be caught here, once, before any child is
    compared.
    """
    return [key for key in CHECKED if key not in parent]


def main() -> int:
    parent = parse_parent()
    missing = missing_parent_keys(parent)
    if missing:
        print(
            f"❌ the foundation's production block does not set {len(missing)} "
            "CHECKED key(s) — a --set typo, or the flag was removed:"
        )
        for key in missing:
            print(f"  {key}")
        return 1

    children = parse_children()
    if not children:
        sys.exit(f"❌ no Cilium HelmRelease found in {CLUSTERS}")

    drift: list[str] = []
    for name, values in children.items():
        for key in CHECKED:
            want, got = parent.get(key), values.get(key)
            if want is None:
                continue  # the parent does not set the key: nothing to enforce
            if got == want or key in EXCEPTIONS:
                continue
            if got is None:
                drift.append(
                    f"  {name} : `{key}` ABSENT — the base sets {key}={want}. "
                    "A missing key takes the CHART DEFAULT, which differs."
                )
            else:
                drift.append(f"  {name}: `{key}`={got} — the foundation sets {want}.")

    if drift:
        print("❌ children's Cilium drifted from the foundation:\n" + "\n".join(drift))
        print(
            "\nAlign apps/clusters/*.yaml with the production block of\n"
            f"{RENDER_SH.relative_to(INFRA)}, or declare the difference in this\n"
            "script's EXCEPTIONS with its rationale."
        )
        return 1

    print(
        f"OK — {len(children)} child(ren) aligned with the foundation "
        f"({len(CHECKED)} settings checked)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
