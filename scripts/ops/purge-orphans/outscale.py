#!/usr/bin/env python3
"""Purges an orphaned Outscale Net (CAPI): dependencies first, then the Net.
Order imposed by Outscale: LBU → NAT → route tables → internet service →
security groups → subnets → net. Also REPORTS (never deletes) leftover
snapshots — see the ARTIFACTS block below. Images are deliberately NOT
enumerated here yet; see that block for why.
Usage: purge-orphans-osc.py [--apply]"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.request

APPLY = '--apply' in sys.argv
try:
    AK, SK = os.environ['OUTSCALE_ACCESS_KEY_ID'], os.environ['OUTSCALE_SECRET_KEY']
except KeyError as e:   # not exit 1, which callers read as "leftovers found"
    print(f"✗ missing credential {e} — source .env.sh first. Nothing was checked.")
    sys.exit(2)
REGION, SERVICE = os.environ.get('OSC_REGION', 'eu-west-2'), 'api'
HOST = f"api.{REGION}.outscale.com"


def call(action, payload=None):
    body = json.dumps(payload or {})
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime('%Y%m%dT%H%M%SZ'), t.strftime('%Y%m%d')
    canonical = (f"POST\n/api/v1/{action}\n\ncontent-type:application/json\nhost:{HOST}\n"
                 f"x-amz-date:{amzdate}\n\ncontent-type;host;x-amz-date\n"
                 + hashlib.sha256(body.encode()).hexdigest())
    scope = f"{datestamp}/{REGION}/{SERVICE}/aws4_request"
    to_sign = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n" + hashlib.sha256(canonical.encode()).hexdigest()
    k = f"AWS4{SK}".encode()
    for part in (datestamp, REGION, SERVICE, 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"https://{HOST}/api/v1/{action}", data=body.encode(), method='POST',
        headers={'Content-Type': 'application/json', 'X-Amz-Date': amzdate,
                 'Authorization': f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                                  "SignedHeaders=content-type;host;x-amz-date, "
                                  f"Signature={sig}"})
    global UNREACHABLE
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        # COUNT it and SAY it. This returned {'error': …} in silence, every
        # listing then read as empty, and the script announced "the account is
        # clean" with exit 0 — measured with every call forced to HTTP 403, it
        # printed one line total. A refused question is not an empty answer, and
        # it must be louder than a network error, not quieter.
        UNREACHABLE += 1
        print(f"  ⚠ unreachable: {action} (HTTP {e.code})")
        return {'error': e.read().decode()[:200]}
    except Exception as e:                       # noqa: BLE001 — same reasoning
        UNREACHABLE += 1
        print(f"  ⚠ unreachable: {action} ({str(e)[:60]})")
        return {}


UNREACHABLE = 0


# Counted so a clean account SAYS it is clean. This script is the last thing
# standing between a failed teardown and a bill, and it used to report that by
# printing nothing at all — which reads like a finding, not like an all-clear.
TOTAL = 0


# Counted, not merely printed. A failed delete used to be one ⚠ line in a run
# that still ended "purge complete" with exit 0, so a caller reading the exit
# code heard "the account is clean" while everything was still there. Shown live
# on Outscale 2026-08-20: six resources found, six deletes refused, exit 0.
FAILED = 0


def do(action, payload, label):
    global TOTAL, FAILED
    TOTAL += 1
    if not APPLY:
        print("  [dry-run]", label)
        return
    r = call(action, payload)
    if 'error' in r:
        FAILED += 1
        print("  ⚠ " + label + " : " + str(r['error'])[:110])
    else:
        print("  ✓ " + label)


for lb in call('ReadLoadBalancers').get('LoadBalancers', []):
    do('DeleteLoadBalancer', {'LoadBalancerName': lb['LoadBalancerName']}, f"LBU {lb['LoadBalancerName']}")
for n in call('ReadNatServices').get('NatServices', []):
    if n.get('State') != 'deleted':
        do('DeleteNatService', {'NatServiceId': n['NatServiceId']}, f"NAT {n['NatServiceId']}")
for ip in call('ReadPublicIps').get('PublicIps', []):
    do('DeletePublicIp', {'PublicIpId': ip['PublicIpId']}, f"EIP {ip.get('PublicIp')}")
for rt in call('ReadRouteTables').get('RouteTables', []):
    for link in rt.get('LinkRouteTables') or []:
        do('UnlinkRouteTable', {'LinkRouteTableId': link['LinkRouteTableId']},
           f"unlink RT {rt['RouteTableId']}")
    do('DeleteRouteTable', {'RouteTableId': rt['RouteTableId']}, f"RT {rt['RouteTableId']}")
for igw in call('ReadInternetServices').get('InternetServices', []):
    if igw.get('NetId'):
        do('UnlinkInternetService', {'InternetServiceId': igw['InternetServiceId'],
                                     'NetId': igw['NetId']}, f"unlink IGW {igw['InternetServiceId']}")
    do('DeleteInternetService', {'InternetServiceId': igw['InternetServiceId']},
       f"IGW {igw['InternetServiceId']}")
for sg in call('ReadSecurityGroups').get('SecurityGroups', []):
    if sg.get('SecurityGroupName') != 'default' and sg.get('NetId'):
        do('DeleteSecurityGroup', {'SecurityGroupId': sg['SecurityGroupId']},
           f"SG {sg.get('SecurityGroupName')}")
for sn in call('ReadSubnets').get('Subnets', []):
    do('DeleteSubnet', {'SubnetId': sn['SubnetId']}, f"subnet {sn['SubnetId']}")
for net in call('ReadNets').get('Nets', []):
    do('DeleteNet', {'NetId': net['NetId']}, f"net {net['NetId']} ({net.get('IpRange')})")

# Snapshots are Talos build artifacts, deliberately never deleted by this
# script — same policy scaleway.py already documents, and the reason
# fleet-down.sh's own step 3 only LISTS artifacts (see docs, "Left standing on
# purpose"). Rebuilding one costs about an hour on Outscale; a wrong guess
# here is not recoverable the way a re-run of the delete loop above is.
#
# Images are NOT enumerated here, on purpose, unlike snapshots: ReadImages'
# documented default scope is every OMI you hold LAUNCH PERMISSIONS on, which
# — unlike a Net or a security group — can include Outscale's own public
# catalogue. An unscoped call risks flooding this report with images that were
# never this account's to begin with, teaching an operator to ignore it. That
# needs an account-id filter verified against a live account before it is
# safe to add (#107); snapshots have no such public-catalogue precedent and
# are scoped the same way every other Read* call in this file already is.
#
# What THIS closes: a duplicate snapshot from a failed image build sat in the
# account while this script never looked, so "account is clean" was true of
# everything it asked and false of the account (#71, 2026-08-19). A resource
# class this script cannot see is a resource class it cannot report on — and
# that cuts both ways: a REFUSED question is not a clean answer either, so
# ARTIFACTS_UNVERIFIED tracks a failed ReadSnapshots call separately from a
# genuinely empty one. Measured in review: without this, a refused
# ReadSnapshots call after some OTHER resource was found and deleted fell
# through every branch below to the same false "the account is clean" this
# fix exists to stop.
_unreachable_before_artifacts = UNREACHABLE
ARTIFACTS = call('ReadSnapshots').get('Snapshots', [])
ARTIFACTS_UNVERIFIED = UNREACHABLE > _unreachable_before_artifacts
if ARTIFACTS:
    print(f"\n⚠ {len(ARTIFACTS)} snapshot(s) present — never auto-purged, review by hand:")
    for s in ARTIFACTS:
        print(f"    snapshot {s.get('SnapshotId')} ({s.get('State', '?')}, {s.get('VolumeSize', '?')}GB)")
elif ARTIFACTS_UNVERIFIED:
    print("\n⚠ snapshot visibility was refused — cannot confirm the account holds none.")

# TOTAL>0 is NOT "dirty" on its own — a successful purge (below, FAILED==0)
# with TOTAL>0 is the ordinary clean-after-work case, same as before this
# fix. Only the two branches that already claimed "clean" (nothing to purge,
# and everything purged with nothing failed) need to also ask about
# snapshots; the other two (dry-run, a failed delete) were already non-zero
# and stay exactly as they were. A blanket "is anything at all non-zero"
# flag was tried here first and wrongly turned a plain, fully successful
# purge into a false "not fully clean" — a second bug shaped like the first.
def _artifact_reason():
    return f"{len(ARTIFACTS)} snapshot(s)" if ARTIFACTS else "snapshot visibility (refused, unconfirmed)"


if UNREACHABLE and TOTAL == 0 and not ARTIFACTS:
    # Nothing else was found ANYWHERE and something refused to answer — fires
    # whether the refusal was the snapshot call or an earlier one. A
    # CONFIRMED snapshot below already proves dirty on its own and takes
    # priority (the `not ARTIFACTS` guard), so the two messages never talk
    # over each other the way an unconditional check here used to.
    print(f"\n✗ {UNREACHABLE} call(s) refused — found nothing, but nothing was actually asked.")
    print("  This is NOT an all-clear: check OUTSCALE_ACCESS_KEY_ID / _SECRET_KEY and re-run.")
    sys.exit(2)
if TOTAL == 0 and not ARTIFACTS and not ARTIFACTS_UNVERIFIED:
    print("Nothing to purge — the account is clean.")
elif TOTAL == 0:
    print(f"\n{_artifact_reason()} present — the account is NOT fully clean (see above).")
    sys.exit(1)
elif not APPLY:
    print(f"\n{TOTAL} resource(s) targeted. Re-run with --apply to delete them.")
    # Non-zero: see the note in scaleway.py. Callers read this exit code as
    # "the provider is clean", and it used to say yes regardless.
    sys.exit(1)
elif FAILED:
    print(f"\n✗ {FAILED} of {TOTAL} deletion(s) failed — the account is NOT clean.")
    sys.exit(3)
elif ARTIFACTS or ARTIFACTS_UNVERIFIED:
    # TOTAL>0, APPLY, nothing failed — this is the branch reviewers found
    # unreachable: a refused ReadSnapshots after some OTHER resource was
    # deleted used to fall straight to the final "clean" else below with
    # ARTIFACTS silently empty. Checked AFTER FAILED on purpose: a deletion
    # failure is the more urgent fact and must not be downgraded to a
    # leftover snapshot's milder "not fully clean" wording.
    print(f"\n{TOTAL} resource(s) deleted. {_artifact_reason()} still present (see above) — not fully clean.")
    sys.exit(1)
elif UNREACHABLE:
    # Deleted what it could see; a call that refused was never asked (exit 2, as above).
    print(f"\n✗ {UNREACHABLE} call(s) refused, so what they hold was never asked.")
    print("  This is NOT an all-clear: check OUTSCALE_ACCESS_KEY_ID / _SECRET_KEY and re-run.")
    sys.exit(2)
else:
    print(f"\n{TOTAL} resource(s) deleted. The account is clean.")
