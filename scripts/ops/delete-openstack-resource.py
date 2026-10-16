#!/usr/bin/env python3
"""Delete ONE OpenStack/OVH resource by its exact ID — the scoped alternative
to purge-orphans/ovh.py (whole account, no filtering) for when a SPECIFIC
leftover is already identified (e.g. via verify-provider-clean.py) and other
resources on the account must NOT be touched (a live redeploy in progress).

Usage:
    source .env.sh
    python3 scripts/ops/delete-openstack-resource.py loadbalancer <id>
    python3 scripts/ops/delete-openstack-resource.py router|network|security-group|port|floatingip <id>
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

RESOURCE_PATHS = {
    "loadbalancer": ("load-balancer", "/v2.0/lbaas/loadbalancers/{id}?cascade=true"),
    "router": ("network", "/v2.0/routers/{id}"),
    "network": ("network", "/v2.0/networks/{id}"),
    "security-group": ("network", "/v2.0/security-groups/{id}"),
    "port": ("network", "/v2.0/ports/{id}"),
    "floatingip": ("network", "/v2.0/floatingips/{id}"),
}


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
    if len(sys.argv) != 3 or sys.argv[1] not in RESOURCE_PATHS:
        print(f"usage: delete-openstack-resource.py {{{'|'.join(RESOURCE_PATHS)}}} <id>", file=sys.stderr)
        return 2
    kind, rid = sys.argv[1], sys.argv[2]
    service_type, path_tpl = RESOURCE_PATHS[kind]

    token, catalog = keystone_token()
    region = os.environ["OS_REGION_NAME"].lower()
    endpoint = next(
        e["url"]
        for s in catalog
        if s["type"] == service_type
        for e in s["endpoints"]
        if e["interface"] == "public" and e["region"].lower() == region
    ).rstrip("/")

    req = urllib.request.Request(
        endpoint + path_tpl.format(id=rid),
        headers={"X-Auth-Token": token},
        method="DELETE",
    )
    try:
        urllib.request.urlopen(req, timeout=90)
    except urllib.error.HTTPError as e:
        print(f"✗ delete failed: {e.code} {e.read().decode()[:200]}", file=sys.stderr)
        return 1
    print(f"✓ deleted {kind} {rid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
