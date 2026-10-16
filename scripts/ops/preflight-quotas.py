#!/usr/bin/env python3
"""Quota preflight before deploying a cluster or instantiating a CAPI child.

Why this script exists
----------------------
On Outscale an HA management (3 CP + 3 workers + bastion) eats 44 GB of RAM
against a `memory_limit` of 40. The overrun is TOLERATED at creation, but any
further VM is then refused — and the diagnosis is painful: the OscMachine stays
in `VmNotReady` with an endlessly reallocated IP and NO error in the CR; you
have to read the CAPOSC manager's logs. Two deployments were lost to it.

The same trap exists elsewhere: the OVH project in use caps at 10 instances —
a management (7 with the bastion) plus a single child (2), with no room for a
second child.

This script reads the quotas AND the real usage, and can simulate what a given
topology would add. Read-only.

Usage :
    source .env.sh
    python3 scripts/ops/preflight-quotas.py ovh
    python3 scripts/ops/preflight-quotas.py outscale --add-vms 2 --add-cores 4 --add-ram-gb 16

Scaleway is not covered: its quotas have never been a problem on this account,
and guessing an API that cannot be verified here would be worse than nothing.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.request


def bar(used, limit):
    """A fill bar — an overrun must be immediately obvious."""
    if not limit or limit <= 0:
        return "?"
    pct = 100.0 * used / limit
    mark = "✗" if pct >= 100 else ("⚠" if pct >= 80 else "✓")
    return f"{mark} {used}/{limit} ({pct:.0f} %)"


# ─────────────────────────────────────────────────────────── OVH (OpenStack)
def ovh(add_vms, add_cores, add_ram_gb):
    base = os.environ["OS_AUTH_URL"].rstrip("/")
    if not base.startswith("https://"):   # the password goes in this request
        print("✗ OS_AUTH_URL must be https:// — the password would travel in clear. Nothing was sent.", file=sys.stderr)
        sys.exit(2)
    url = base + ("/auth/tokens" if base.endswith("/v3") else "/v3/auth/tokens")
    auth = {"auth": {"identity": {"methods": ["password"], "password": {"user": {
        "name": os.environ["OS_USERNAME"], "password": os.environ["OS_PASSWORD"],
        "domain": {"name": os.environ.get("OS_USER_DOMAIN_NAME", "Default")}}}},
        "scope": {"project": {"id": os.environ["OS_PROJECT_ID"]}}}}
    req = urllib.request.Request(url, data=json.dumps(auth).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        tok, cat = r.headers["X-Subject-Token"], json.load(r)["token"]["catalog"]
    region = os.environ["OS_REGION_NAME"].lower()
    nova = next(e["url"] for s in cat if s["type"] == "compute" for e in s["endpoints"]
                if e["interface"] == "public" and e["region"].lower() == region).rstrip("/")
    req = urllib.request.Request(nova + "/limits", headers={"X-Auth-Token": tok})
    lim = json.load(urllib.request.urlopen(req, timeout=60))["limits"]["absolute"]

    rows = [
        ("instances", lim["totalInstancesUsed"], lim["maxTotalInstances"], add_vms),
        ("vCPU", lim["totalCoresUsed"], lim["maxTotalCores"], add_cores),
        ("RAM (Mo)", lim["totalRAMUsed"], lim["maxTotalRAMSize"], add_ram_gb * 1024),
    ]
    return rows


# ─────────────────────────────────────────────────────────────────── Outscale
def _osc_call(action, body=None):
    ak, sk = os.environ["OUTSCALE_ACCESS_KEY_ID"], os.environ["OUTSCALE_SECRET_KEY"]
    region = os.environ.get("OUTSCALE_REGION", "eu-west-2")
    region = region[:-1] if region[-1].isalpha() and region[-2].isdigit() else region
    host = f"api.{region}.outscale.com"
    body = json.dumps(body or {})
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    canonical = (f"POST\n/api/v1/{action}\n\ncontent-type:application/json\n"
                 f"host:{host}\nx-osc-date:{amzdate}\n\ncontent-type;host;x-osc-date\n"
                 + hashlib.sha256(body.encode()).hexdigest())
    scope = f"{datestamp}/{region}/api/osc4_request"
    to_sign = ("OSC4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n"
               + hashlib.sha256(canonical.encode()).hexdigest())
    k = hmac.new(("OSC4" + sk).encode(), datestamp.encode(), hashlib.sha256).digest()
    for part in (region, "api", "osc4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"https://{host}/api/v1/{action}", data=body.encode(),
        headers={"Content-Type": "application/json", "X-Osc-Date": amzdate,
                 "Authorization": (f"OSC4-HMAC-SHA256 Credential={ak}/{scope}, "
                                   "SignedHeaders=content-type;host;x-osc-date, "
                                   f"Signature={sig}")})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def outscale(add_vms, add_cores, add_ram_gb):
    quotas = {q["Name"]: q for q in _osc_call("ReadQuotas").get("QuotaTypes", [{}])[0].get("Quotas", [])}
    wanted = {
        "vm_limit": ("instances", add_vms),
        "core_limit": ("vCPU", add_cores),
        "memory_limit": ("RAM (Go)", add_ram_gb),
    }
    rows = []
    for name, (label, add) in wanted.items():
        q = quotas.get(name)
        if not q:
            continue
        rows.append((label, q.get("UsedValue", 0), q.get("MaxValue", 0), add))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("provider", choices=["ovh", "outscale"])
    ap.add_argument("--add-vms", type=int, default=0, help="VMs added")
    ap.add_argument("--add-cores", type=int, default=0, help="vCPUs added")
    ap.add_argument("--add-ram-gb", type=int, default=0, help="RAM added, in GB")
    args = ap.parse_args()

    rows = {"ovh": ovh, "outscale": outscale}[args.provider](
        args.add_vms, args.add_cores, args.add_ram_gb)

    simulating = any(add for *_, add in rows)
    print(f"=== Quotas {args.provider} ===")
    over = []
    for label, used, limit, add in rows:
        print(f"  {label:14s} {bar(used, limit)}")
        if simulating and limit:
            after = used + add
            verdict = "OVER LIMIT" if after > limit else "ok"
            print(f"  {'':14s}   → after +{add}: {after}/{limit}  {verdict}")
            if after > limit:
                over.append(label)

    if over:
        print(f"\n✗ The requested topology exceeds: {', '.join(over)}.")
        print("  On Outscale the overrun is TOLERATED at creation, then ANY further")
        print("  VM is refused (CreateVms → 10042 TooManyResources), with no")
        print("  error in the CAPI CR: the OscMachine loops on VmNotReady.")
        return 1
    if simulating:
        print("\n✓ The requested topology fits within the quotas.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
