#!/usr/bin/env python3
"""Purges the Scaleway resources left behind by an orphaned cluster.
Targets the WHOLE project, like the ovh/outscale scripts.
Usage: scaleway.py [--apply]   (dry-run by default)

Block volumes are the reason this exists: a terminated VM can leave its root
volume behind, and those bill silently. Checking servers/LB/IPs alone made the
account look clean while 7 volumes had been billing for three days (2026-07-28).

Snapshots and images are deliberately NOT touched — they are the Talos image
artifacts, kept between sessions on purpose. verify-provider-clean.py imports
this listing, so the two cannot disagree on what a clean project is.
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = 'https://api.scaleway.com'

# What a teardown must leave empty, in deletion order: (kind, list path,
# response key, field that, when set, means the item is not a leftover on its
# own — an IP still attached, a volume in use, the project's default group).
KINDS = (
    ('server', 'instance/v1/zones/{z}/servers?project={p}', 'servers', None),
    ('LB', 'lb/v1/zones/{z}/lbs?project_id={p}', 'lbs', None),
    ('flexible IP', 'instance/v1/zones/{z}/ips?project={p}', 'ips', 'server'),
    ('LB IP', 'lb/v1/zones/{z}/ips?project_id={p}', 'ips', 'lb_id'),
    ('public gateway', 'vpc-gw/v2/zones/{z}/gateways?project_id={p}', 'gateways', None),
    ('gateway IP', 'vpc-gw/v2/zones/{z}/ips?project_id={p}', 'ips', 'gateway_id'),
    ('volume', 'block/v1alpha1/zones/{z}/volumes?project_id={p}', 'volumes', 'references'),
    # DEV1/GP1 servers run on these (l_ssd, b_ssd); the block API does not list them.
    ('instance volume', 'instance/v1/zones/{z}/volumes?project={p}', 'volumes', 'server'),
    ('security group', 'instance/v1/zones/{z}/security_groups?project={p}',
     'security_groups', 'project_default'),
    # Regional, and only removable once the NICs are gone.
    ('private network', 'vpc/v2/regions/{r}/private-networks?project_id={p}',
     'private_networks', None),
)


def settings():
    """(token, project, region, zones); KeyError names a missing credential."""
    token, project = os.environ['SCW_SECRET_KEY'], os.environ['SCW_DEFAULT_PROJECT_ID']
    region = os.environ.get('SCW_DEFAULT_REGION', 'fr-par')
    zones = os.environ.get('SCW_ZONES', f'{region}-1,{region}-2,{region}-3').split(',')
    return token, project, region, zones


def call(token, url, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'X-Auth-Token': token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=90) as r:
        raw = r.read()
    try:
        return json.loads(raw) if raw else {}
    except ValueError as e:
        # A 200 that is not JSON (a proxy page) is an unanswered question, not a traceback.
        raise urllib.error.URLError(f"answer is not JSON: {raw[:40]!r}") from e


def pages(token, url, key):
    """Every item of a list endpoint: the API answers one page (50) at a time. It
    stops on total_count when the body has one (the instance API keeps it in a
    header), else on the first page that adds nothing."""
    found, page = {}, 1
    while True:
        try:
            data = call(token, f"{url}&page={page}")
        except urllib.error.HTTPError as e:
            if page == 1:
                raise
            # The list exists (page 1 answered): failing later is an incomplete read,
            # not "not offered in this zone", which leftovers() would pass as empty.
            raise urllib.error.URLError(f"page {page} answered HTTP {e.code}") from e
        try:
            new = [i for i in data.get(key, []) if i['id'] not in found]
        except (KeyError, TypeError, AttributeError) as e:
            raise urllib.error.URLError(f"unexpected answer shape ({type(e).__name__}: {e})") from e
        found.update((i['id'], i) for i in new)
        total = data.get('total_count')
        if not new or (total is not None and len(found) >= total):
            return list(found.values())
        page += 1


def leftovers(token, project, region, zones, refused):
    """Yields (kind, zone or region, item, item url) for each leftover. Each
    endpoint that refused is appended to `refused`: a refused question is not
    an empty answer, and both used to leave the count at 0 and print "clean".
    So is a kind that no location answered at all (404/501 everywhere)."""
    seen = set()          # both volume APIs may list the same volume
    for kind, path, key, owner in KINDS:
        locations = zones if '{z}' in path else [region]
        answered, refused_before = False, len(refused)
        for where in locations:
            url = f"{API}/{path.format(z=where, r=where, p=project)}"
            base = url.split('?')[0]
            try:
                items = pages(token, url, key)
            except urllib.error.HTTPError as e:
                if e.code not in (404, 501):          # 404/501: not offered in this zone
                    refused.append(f"{base} (HTTP {e.code})")
                continue
            except (urllib.error.URLError, TimeoutError) as e:
                refused.append(f"{base} ({str(e)[:60]})")
                continue
            answered = True
            for item in items:
                if not (owner and item.get(owner)) and item['id'] not in seen:
                    seen.add(item['id'])
                    yield kind, where, item, f"{base}/{item['id']}"
        if not answered and len(refused) == refused_before:
            refused.append(f"{kind}: not offered in {', '.join(locations)} (404/501 everywhere)")


def describe(kind, item):
    name = item.get('name') or item.get('address') or item.get('ip_address') or item['id']
    return f"{name} ({(item.get('size') or 0) // 10**9}GB)" if kind == 'volume' else name


def delete(token, kind, url):
    if kind == 'server':            # terminate also releases the attached volumes and IPs
        return call(token, url + '/action', 'POST', {'action': 'terminate'})
    if kind == 'LB':                # release_ip, so its flexible IP does not survive it
        url += '?release_ip=true'
    return call(token, url, 'DELETE')


def main():
    apply = '--apply' in sys.argv
    try:
        token, project, region, zones = settings()
    except KeyError as e:
        # Not exit 1: callers read 1 as "leftovers found", and nothing was asked.
        print(f"✗ missing credential {e} — source .env.sh first. Nothing was checked.")
        return 2
    # Counted, not merely printed: a failed delete used to be one ⚠ line in a run
    # that still ended "purge complete" with exit 0 (Outscale, 2026-08-20).
    total, failed, refused = 0, 0, []
    for kind, where, item, url in leftovers(token, project, region, zones, refused):
        total += 1
        label = f"[{where}] {kind} {describe(kind, item)}"
        if not apply:
            print("  [dry-run]", label)
            continue
        try:
            delete(token, kind, url)
            print("  ✓ deleted:", label)
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            failed += 1
            print("  ⚠ failed:", label, str(e)[:80])
    for r in refused:
        print("  ⚠ unreachable:", r)

    if failed:
        print(f"\n✗ {failed} of {total} deletion(s) failed — the project is NOT clean.")
        return 3
    if total and not apply:
        print(f"\n{total} resource(s) targeted. Re-run with --apply to delete them.")
        # Non-zero: callers — a driver script on 2026-08-14, a CI step named
        # "Confirm the provider is clean" — read 0 as clean while ten resources billed.
        return 1
    if refused:
        print(f"\n✗ {len(refused)} endpoint(s) refused to answer, so what they hold was never")
        print("  asked. This is NOT an all-clear: check the credentials and re-run.")
        return 2
    # No re-list: a terminated server leaves the listing asynchronously, so one
    # straight after would call a good purge dirty.
    print(f"\n{total} resource(s) deleted. Re-run without --apply to confirm the project is clean."
          if total else "Nothing to purge — the project is clean.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
