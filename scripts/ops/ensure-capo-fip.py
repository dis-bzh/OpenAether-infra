#!/usr/bin/env python3
"""Allocates (or reuses) a CAPO control plane's floating IP — idempotent.

An OpenStack child needs its floating IP BEFORE boot: the IMDS does not expose
it (Neutron-side NAT), so it must appear in the Talos `certSANs`, hence in git.
It is the only child resource created outside both OpenTofu and CAPI — and so
the only one to recreate by hand after a teardown, and the only one a teardown
leaves behind and billing.

Finding the FIP by its description (`openaether:<cluster>`) makes the step
idempotent: re-running never creates a billed duplicate.

Usage:
    source .env.sh
    python3 scripts/ops/ensure-capo-fip.py edge-2 [--network Ext-Net]

Then copy the printed IP into `OS_CP_FLOATING_IPS` of the child's file.
One FIP per control-plane replica: pass --count N.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

DESC_PREFIX = "openaether:"


def keystone_token() -> tuple[str, list]:
    base = os.environ["OS_AUTH_URL"].rstrip("/")
    if not base.startswith("https://"):   # the password goes in this request
        print("✗ OS_AUTH_URL must be https:// — the password would travel in clear. Nothing was sent.", file=sys.stderr)
        sys.exit(2)
    url = base + ("/auth/tokens" if base.endswith("/v3") else "/v3/auth/tokens")
    auth = {
        "auth": {
            "identity": {
                "methods": ["password"],
                "password": {
                    "user": {
                        "name": os.environ["OS_USERNAME"],
                        "password": os.environ["OS_PASSWORD"],
                        "domain": {"name": os.environ.get("OS_USER_DOMAIN_NAME", "Default")},
                    }
                },
            },
            "scope": {"project": {"id": os.environ["OS_PROJECT_ID"]}},
        }
    }
    req = urllib.request.Request(
        url, data=json.dumps(auth).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.headers["X-Subject-Token"], json.load(resp)["token"]["catalog"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cluster", help="child cluster name (e.g. edge-2)")
    parser.add_argument("--network", default="Ext-Net", help="external network (default: Ext-Net)")
    parser.add_argument("--count", type=int, default=1, help="nombre de FIP (1 par CP)")
    args = parser.parse_args()

    missing = [v for v in ("OS_AUTH_URL", "OS_USERNAME", "OS_PASSWORD", "OS_PROJECT_ID",
                           "OS_REGION_NAME") if not os.environ.get(v)]
    if missing:
        sys.exit(f"❌ variables OpenStack manquantes : {', '.join(missing)} (source .env.sh)")

    token, catalog = keystone_token()
    region = os.environ["OS_REGION_NAME"].lower()
    neutron = next(
        e["url"]
        for s in catalog
        if s["type"] == "network"
        for e in s["endpoints"]
        if e["interface"] == "public" and e["region"].lower() == region
    ).rstrip("/")
    headers = {"X-Auth-Token": token, "Content-Type": "application/json"}

    def get(path):
        req = urllib.request.Request(neutron + path, headers=headers)
        return json.load(urllib.request.urlopen(req, timeout=60))

    description = DESC_PREFIX + args.cluster
    existing = [
        f for f in get("/v2.0/floatingips")["floatingips"] if f.get("description") == description
    ]

    net = get(f"/v2.0/networks?name={args.network}")["networks"]
    if not net:
        sys.exit(f"❌ external network '{args.network}' not found")
    net_id = net[0]["id"]

    while len(existing) < args.count:
        body = json.dumps(
            {"floatingip": {"floating_network_id": net_id, "description": description}}
        ).encode()
        req = urllib.request.Request(
            neutron + "/v2.0/floatingips", data=body, headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            fip = json.load(resp)["floatingip"]
        print(f"  + allocated: {fip['floating_ip_address']}", file=sys.stderr)
        existing.append(fip)

    if len(existing) > args.count:
        print(
            f"  ⚠ {len(existing)} FIPs carry the description '{description}' for "
            f"--count {args.count} — the extras are billed, purge them.",
            file=sys.stderr,
        )

    addresses = [f["floating_ip_address"] for f in existing[: args.count]]
    for f in existing[: args.count]:
        state = "associated" if f.get("port_id") else "free"
        print(f"  ✓ {f['floating_ip_address']} ({state})", file=sys.stderr)
    print(
        f"\n→ copy into OS_CP_FLOATING_IPS of apps/clusters/{args.cluster}.yaml:",
        file=sys.stderr,
    )
    print(",".join(addresses))
    return 0


if __name__ == "__main__":
    sys.exit(main())
