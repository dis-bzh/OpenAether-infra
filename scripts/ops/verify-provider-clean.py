#!/usr/bin/env python3
"""Read-only check: does the provider still have resources for a CAPI child
cluster after edge-down.sh's Kubernetes-level cascade reports the Cluster and
its Machines gone?

That Kubernetes-level signal is NOT sufficient — found live 2026-07-30 on a
real `task fleet-down`: after edge-down reported edge-2 fully deleted, OVH
still had the cluster's network/subnet/router/security-groups, and Outscale
had left one billed, unassociated Elastic IP from edge-3. CAPO/CAPOSC's own
controller does not always finish its provider-side cleanup within the
Kubernetes object's finalizer window. This script re-checks the provider
directly instead of trusting that silence means clean.

Never deletes anything — see scripts/ops/purge-orphans/ for that (whole
account, deliberately manual, not safe to call unattended from here).

Exit codes: 0 clean, 1 leftovers found (printed to stdout), 2 could not verify
(missing credentials / unsupported provider — printed to stderr).

Usage:
    source .env.sh
    python3 scripts/ops/verify-provider-clean.py <cluster> openstack|outscale|scaleway
"""
from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import os
import re
import sys
import urllib.error
import urllib.request


def openstack_leftovers(cluster: str) -> list[str]:
    base = os.environ["OS_AUTH_URL"].rstrip("/")
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
        token, catalog = resp.headers["X-Subject-Token"], json.load(resp)["token"]["catalog"]
    region = os.environ["OS_REGION_NAME"].lower()
    headers = {"X-Auth-Token": token}

    def ep(service_type: str) -> str:
        return next(
            e["url"]
            for s in catalog
            if s["type"] == service_type
            for e in s["endpoints"]
            if e["interface"] == "public" and e["region"].lower() == region
        ).rstrip("/")

    def get(path: str):
        return json.load(urllib.request.urlopen(urllib.request.Request(path, headers=headers), timeout=60))

    net, comp = ep("network"), ep("compute")
    leftovers = []
    for s in get(comp + "/servers")["servers"]:
        if cluster in s["name"]:
            leftovers.append(f"server {s['name']}")
    # Found live 2026-07-31: an Octavia LB from a PRIOR teardown survived, its
    # apiserver kubeapi LB referencing a since-deleted network's VIP port. CAPO
    # reuses an existing LB by NAME on the next deploy rather than recreating
    # it, so the leak isn't just cruft — it silently breaks the next redeploy
    # (FIP-to-port association 404s forever, no CAPO error surfaced to Flux).
    try:
        lb_ep = ep("load-balancer")
        for lb in get(lb_ep + "/v2.0/lbaas/loadbalancers")["loadbalancers"]:
            if cluster in lb["name"]:
                leftovers.append(f"load-balancer {lb['name']}")
    except StopIteration:
        pass
    for n in get(net + "/v2.0/networks")["networks"]:
        if cluster in n["name"]:
            leftovers.append(f"network {n['name']}")
    for r in get(net + "/v2.0/routers")["routers"]:
        if cluster in r["name"]:
            leftovers.append(f"router {r['name']}")
    for g in get(net + "/v2.0/security-groups")["security_groups"]:
        if cluster in g["name"]:
            leftovers.append(f"security-group {g['name']}")
    return leftovers


def outscale_leftovers(cluster: str) -> list[str]:
    ak, sk = os.environ["OUTSCALE_ACCESS_KEY_ID"], os.environ["OUTSCALE_SECRET_KEY"]
    region = os.environ.get("OSC_REGION", os.environ.get("OUTSCALE_REGION", "eu-west-2"))
    host = f"api.{region}.outscale.com"

    def call(action: str, payload: dict | None = None) -> dict:
        body = json.dumps(payload or {})
        t = datetime.datetime.now(datetime.timezone.utc)
        amzdate, datestamp = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
        canonical = (
            f"POST\n/api/v1/{action}\n\ncontent-type:application/json\nhost:{host}\n"
            f"x-amz-date:{amzdate}\n\ncontent-type;host;x-amz-date\n"
            + hashlib.sha256(body.encode()).hexdigest()
        )
        scope = f"{datestamp}/{region}/api/aws4_request"
        to_sign = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n" + hashlib.sha256(canonical.encode()).hexdigest()
        k = f"AWS4{sk}".encode()
        for part in (datestamp, region, "api", "aws4_request"):
            k = hmac.new(k, part.encode(), hashlib.sha256).digest()
        sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
        req = urllib.request.Request(
            f"https://{host}/api/v1/{action}",
            data=body.encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-Amz-Date": amzdate,
                "Authorization": (
                    f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
                    "SignedHeaders=content-type;host;x-amz-date, "
                    f"Signature={sig}"
                ),
            },
        )
        return json.load(urllib.request.urlopen(req, timeout=60))

    leftovers = []
    for vm in call("ReadVms").get("Vms", []):
        if vm.get("State") != "terminated":
            name = next((t["Value"] for t in vm.get("Tags", []) if t["Key"] == "Name"), "")
            leftovers.append(f"vm {vm.get('VmId')} ({name or 'untagged'}, {vm.get('State')})")
    # No reliable cluster-name tag survives on a leaked EIP (that's how one leaked
    # live on 2026-07-30) — this account carries a single Outscale cluster, so ANY
    # unassociated EIP is a leftover. Revisit this check if a second Outscale
    # cluster is ever added (would need per-cluster tagging upstream first).
    for ip in call("ReadPublicIps").get("PublicIps", []):
        if not ip.get("VmId") and not ip.get("LinkPublicIpId"):
            leftovers.append(f"unassociated EIP {ip.get('PublicIp')}")
    return leftovers


def scaleway_leftovers(cluster: str) -> list[str]:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "purge-orphans"))
    import scaleway  # the purge's own listing: one definition of a clean project

    refused: list[str] = []
    leftovers = []
    # The name between separators: a bare substring made edge-1 own edge-10's servers.
    mine = re.compile(rf"(?<![A-Za-z0-9]){re.escape(cluster)}(?![A-Za-z0-9])")
    for kind, where, item, _ in scaleway.leftovers(*scaleway.settings(), refused):
        # A detached IP or volume carries no reliable cluster name, and bills
        # whoever left it; the rest is this cluster's when named or tagged so.
        names = [item.get("name") or "", *(item.get("tags") or [])]
        detached = kind in ("flexible IP", "LB IP", "gateway IP", "volume", "instance volume")
        if detached or any(mine.search(n) for n in names):
            leftovers.append(f"{kind} {scaleway.describe(kind, item)} in {where}")
    for r in refused:
        print(f"  ⚠ unreachable: {r}", file=sys.stderr)
    if refused and not leftovers:
        raise urllib.error.URLError(f"{len(refused)} endpoint(s) refused, e.g. {refused[0]}")
    return leftovers


CHECKS = {
    "openstack": openstack_leftovers,
    "outscale": outscale_leftovers,
    "scaleway": scaleway_leftovers,
}

# What each check actually enumerates, and what it does not. Printed on success
# because a teardown proof that says NOTHING when the account is clean looks
# exactly like one that did not run — that shape has bitten twice already:
# once for a purge script, and once for "an empty server list is not an empty
# account", where seven block volumes billed for three days behind a clean
# instance list.
SCOPE = {
    "openstack": "servers, load balancers",
    "outscale": "VMs, unassociated public IPs",
    "scaleway": "servers, LBs, public gateways, security groups and private networks "
                "named or tagged after the cluster; every detached flexible IP, LB IP, "
                "gateway IP and volume (block or instance API) in the project",
}
UNCHECKED = dict.fromkeys(SCOPE, "volumes, snapshots, images and buckets")
UNCHECKED["scaleway"] = "snapshots, images and buckets"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify-provider-clean.py <cluster> openstack|outscale|scaleway", file=sys.stderr)
        return 2
    cluster, provider = sys.argv[1], sys.argv[2]

    check = CHECKS.get(provider)
    if check is None:
        print(f"no provider-side check implemented for '{provider}'", file=sys.stderr)
        return 2

    try:
        leftovers = check(cluster)
    except KeyError as e:
        print(f"missing credential {e} — source .env.sh first", file=sys.stderr)
        return 2
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        print(f"could not reach the {provider} API: {e}", file=sys.stderr)
        return 2

    if not leftovers:
        print(f"✓ {provider}/{cluster}: nothing left (checked: {SCOPE[provider]})")
        print(f"  {UNCHECKED[provider]} are NOT enumerated here — see scripts/ops/purge-orphans/")
        return 0
    for item in leftovers:
        print(item)
    return 1


if __name__ == "__main__":
    sys.exit(main())
