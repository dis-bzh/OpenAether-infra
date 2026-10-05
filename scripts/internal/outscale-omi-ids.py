#!/usr/bin/env python3
"""IDs of this account's OMIs named <image-name>, one per line (nothing printed = none).
Exit 0 answered, 2 could not be answered: a refused or unreachable call is never an empty list.
The caller is the same-name gate of talos-image.sh. The provider's own lookup cannot serve it: on the
real account `data.outscale_images` fails the whole plan when nothing matches (measured 2026-10-05).
Usage: outscale-omi-ids.py <image-name> [region]"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request

if len(sys.argv) not in (2, 3):
    sys.exit(__doc__)
NAME, REGION = sys.argv[1], (sys.argv[2] if len(sys.argv) == 3 else 'eu-west-2')
try:
    AK, SK = os.environ['OUTSCALE_ACCESS_KEY_ID'], os.environ['OUTSCALE_SECRET_KEY']
except KeyError as e:
    print(f"✗ missing credential {e}", file=sys.stderr)
    sys.exit(2)
# OA_OSC_API replaces the endpoint for the offline test only.
BASE = os.environ.get('OA_OSC_API') or f"https://api.{REGION}.outscale.com"
HOST = BASE.split('://', 1)[1]


def call(action, payload):  # same AWS4 signing as scripts/ops/purge-orphans/outscale.py
    body = json.dumps(payload)
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime('%Y%m%dT%H%M%SZ'), t.strftime('%Y%m%d')
    canonical = (f"POST\n/api/v1/{action}\n\ncontent-type:application/json\nhost:{HOST}\n"
                 f"x-amz-date:{amzdate}\n\ncontent-type;host;x-amz-date\n"
                 + hashlib.sha256(body.encode()).hexdigest())
    scope = f"{datestamp}/{REGION}/api/aws4_request"
    to_sign = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n" + hashlib.sha256(canonical.encode()).hexdigest()
    k = f"AWS4{SK}".encode()
    for part in (datestamp, REGION, 'api', 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"{BASE}/api/v1/{action}", data=body.encode(), method='POST',
        headers={'Content-Type': 'application/json', 'X-Amz-Date': amzdate,
                 'Authorization': f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                                  f"SignedHeaders=content-type;host;x-amz-date, Signature={sig}"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        print(f"✗ {action} refused (HTTP {e.code}): {e.read().decode()[:200]}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:  # noqa: BLE001 — unreachable is not "no OMI"
        print(f"✗ {action} unreachable: {str(e)[:100]}", file=sys.stderr)
        sys.exit(2)


# OMI names are unique per account, so only this account's own count; the unscoped catalogue is no fallback.
accounts = call('ReadAccounts', {}).get('Accounts', [])
if not accounts or not accounts[0].get('AccountId'):
    print("✗ ReadAccounts returned no account id", file=sys.stderr)
    sys.exit(2)
found, token = [], None
while True:
    payload = {'Filters': {'AccountIds': [accounts[0]['AccountId']], 'ImageNames': [NAME]}}
    if token:
        payload['NextPageToken'] = token
    page = call('ReadImages', payload)
    found += [i['ImageId'] for i in page.get('Images', []) if i.get('ImageName') == NAME]
    token = page.get('NextPageToken')
    if not token:
        break
if found:
    print('\n'.join(found))
