#!/usr/bin/env bash
# Unit tests for the LAST sentence between a failed teardown and a bill.
#
# `purge-orphans/<provider>.py` is what docs/first-cluster.md ends on, and what
# an operator reads to
# decide a session cost nothing more. It answers a question — "is anything still
# there?" — and the dangerous answer is not "yes". It is "no" said by a script
# that was never allowed to look.
#
# Measured 2026-08-17, before the fix, with every call forced to HTTP 403 and no
# credentials at all: scaleway.py printed thirteen "⚠ unreachable" lines and then
# "Nothing to purge — the project is clean." with exit 0; outscale.py printed
# NOTHING and did the same. A total authentication failure was indistinguishable
# from a clean account, in the output and in the exit code.
#
# verify-provider-clean.py's Scaleway check reads scaleway.py's listing, so it is
# tested here too. No network: urllib is monkey-patched in-process.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# Runs a purge script with every HTTP call answered 403, printing "<rc>\n<output>".
run_403() { # <script> [extra env assignments...]
  local script="$1"; shift
  env "$@" python3 - "$ROOT/scripts/ops/purge-orphans/$script" <<'PY' 2>&1
import runpy, sys, urllib.request, urllib.error, io

def refuse(*a, **k):
    raise urllib.error.HTTPError('https://stub.invalid/x', 403, 'Forbidden', {},
                                 io.BytesIO(b'{"message":"denied"}'))

urllib.request.urlopen = refuse
sys.argv = [sys.argv[1]]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

echo "=== purge-orphans: a refused API is not a clean account ==="

# Credentials must be PRESENT but useless: the scripts read them at import time
# and a KeyError would abort before reaching the logic under test — which would
# pass this file for the wrong reason.
SCW_ENV=(SCW_SECRET_KEY=stub SCW_DEFAULT_PROJECT_ID=stub SCW_DEFAULT_REGION=fr-par)
OSC_ENV=(OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OSC_REGION=eu-west-2)

for case in "scaleway.py:${SCW_ENV[*]}" "outscale.py:${OSC_ENV[*]}"; do
  script="${case%%:*}"; envs="${case#*:}"
  # shellcheck disable=SC2086  # envs is a deliberate list of assignments
  out="$(run_403 "$script" $envs)"; rc=$?

  if [ "$rc" -ne 0 ]; then
    ok "${script}: a fully refused API exits non-zero (rc=${rc})"
  else
    bad "${script}: every call was refused and it exited 0 — a bill looks like an all-clear"
  fi

  if grep -qiE 'clean' <<<"$out"; then
    bad "${script}: it said the account is clean after answering nothing"
  else
    ok "${script}: it does not claim the account is clean"
  fi

  # Silence is the Outscale-specific half of the defect: it swallowed the error
  # into an empty listing and printed one line for the whole run.
  if grep -qiE 'unreachable|refused' <<<"$out"; then
    ok "${script}: it names the refusal in its output"
  else
    bad "${script}: it refused silently — a transcript reader cannot tell"
  fi
done


# --- the OTHER half: the listings ANSWER, the deletions all fail --------------
# Measured live on Outscale 2026-08-20, on a Net only the provider can clear:
# six resources found, six deletions refused, and the run still ended "Outscale
# purge complete" with exit 0. The refusals WERE printed; nothing counted them,
# so every caller reading the exit code heard "the account is clean".
echo
echo "=== --apply: everything found, every deletion refused ==="

run_apply_refused() { # <script>
  env OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OUTSCALE_REGION=eu-west-2 \
      python3 - "$ROOT/scripts/ops/purge-orphans/$1" <<'PYSTUB' 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

# Read* answers with one resource; anything that MUTATES is refused 409 — the
# shape Outscale really returned (ResourceConflict on a Net still in use).
CANNED = {
    'ReadNets':             {'Nets': [{'NetId': 'vpc-stub', 'IpRange': '10.0.0.0/16'}]},
    'ReadSubnets':          {'Subnets': [{'SubnetId': 'subnet-stub'}]},
    'ReadInternetServices': {'InternetServices': [{'InternetServiceId': 'igw-stub', 'NetId': 'vpc-stub'}]},
}

def fake(req, *a, **k):
    action = req.full_url.rsplit('/', 1)[-1]
    if action.startswith('Read'):
        return io.BytesIO(json.dumps(CANNED.get(action, {})).encode())
    raise urllib.error.HTTPError(req.full_url, 409, 'Conflict', {},
                                 io.BytesIO(b'{"Errors":[{"Code":"9092"}]}'))

urllib.request.urlopen = fake
sys.argv = [sys.argv[1], '--apply']
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PYSTUB
}

out="$(run_apply_refused outscale.py)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "outscale.py --apply: every deletion refused and it still exited 0 — a caller reads that as clean"
else
  ok "outscale.py --apply: deletions refused, exit ${rc} — not an all-clear"
fi
if grep -qiE 'NOT clean|deletion' <<<"$out"; then
  ok "outscale.py --apply: it says in words that the deletions failed"
else
  bad "outscale.py --apply: the transcript never says the deletions failed"
fi
if grep -qiE 'resource\(s\) deleted\. The account is clean' <<<"$out"; then
  bad "outscale.py --apply: it claimed resources were deleted when none were"
else
  ok "outscale.py --apply: it does not claim a deletion that did not happen"
fi

# --- ovh.py: auth succeeds, servers are found, one other endpoint is refused --
# A TOTAL auth failure exits 2 before any listing (asserted further down) — not
# this gap. The gap is a PARTIAL refusal: auth works, servers list fine, then floating-ips answers
# 403. Before the fix that exception propagated out of get() uncaught: the run
# died mid-listing with a traceback, never reaching routers/networks/security
# groups or its own summary — which is not "clean", but the run's own findings
# vanished with it. It must count the refusal and keep going, like its
# siblings, and still report what it DID find.
echo
echo "=== ovh.py: auth OK, servers found, floating-ips refused 403 ==="

run_403_ovh_partial() { # [args...] — a DELETE succeeds, so --apply can get past the servers
  env OS_AUTH_URL=https://stub.invalid/v3 OS_USERNAME=stub OS_PASSWORD=stub \
      OS_PROJECT_ID=stub OS_REGION_NAME="${OVH_REGION:-stub}" \
      python3 - "$ROOT/scripts/ops/purge-orphans/ovh.py" "$@" <<'PY' 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

class FakeResp(io.BytesIO):
    def __init__(self, data, headers=None):
        super().__init__(data)
        self.headers = headers or {}
    def __enter__(self): return self
    def __exit__(self, *a): return False

CATALOG = {"token": {"catalog": [
    {"type": "network", "endpoints": [{"interface": "public", "region": "stub", "url": "https://stub.invalid/network"}]},
    {"type": "compute", "endpoints": [{"interface": "public", "region": "stub", "url": "https://stub.invalid/compute"}]},
]}}

def fake(req, *a, **k):
    u = req.full_url
    if u.endswith('/auth/tokens'):
        return FakeResp(json.dumps(CATALOG).encode(), headers={'X-Subject-Token': 'stub'})
    if u.endswith('/servers'):
        return FakeResp(json.dumps({'servers': [{'id': 'srv-stub', 'name': 'stub-server'}]}).encode())
    if req.get_method() == 'DELETE':
        return FakeResp(b'')
    raise urllib.error.HTTPError(u, 403, 'Forbidden', {}, io.BytesIO(b'{}'))

urllib.request.urlopen = fake
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

out="$(run_403_ovh_partial)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "ovh.py: found resources + a refused endpoint still exits non-zero (rc=${rc})"
else
  bad "ovh.py: exited 0 with a refused endpoint in the middle of the run"
fi
if grep -qi 'traceback' <<<"$out"; then
  bad "ovh.py: a refused endpoint crashed the run instead of being counted — later listings never ran"
else
  ok "ovh.py: a refused endpoint does not crash the run"
fi
if grep -qiE 'unreachable' <<<"$out"; then
  ok "ovh.py: it names the refusal in its output"
else
  bad "ovh.py: it refused silently — a transcript reader cannot tell"
fi
if grep -qiE 'resource\(s\) targeted' <<<"$out"; then
  ok "ovh.py: it still reaches its own summary after the refusal"
else
  bad "ovh.py: it never reached its own summary — the refusal ended the run early"
fi

# --- outscale.py: leftover snapshots are visible, and "clean" stops lying ----
# The core of #71: a duplicate snapshot from a failed image build sat in the
# account while outscale.py never even asked ReadSnapshots, so "account is
# clean" was true of everything it looked at and false of the account. Images
# are deliberately out of scope here — see the comment in outscale.py for why.
#
# Five scenarios: #1 is the regression guard (must not cry wolf on the
# ordinary empty case), #2 is #71 itself, #3 is its twin in the --apply
# success path, #4 reproduces the bug review actually caught — a REFUSED
# ReadSnapshots after some other resource was purged clean — and #5 checks
# that a failed deletion still wins the exit code over a leftover snapshot.
echo
echo "=== outscale.py: snapshot artifacts are seen, not silently skipped ==="

run_osc_canned() { # <CANNED python-dict-literal as a string> [extra argv...]
  local canned="$1"; shift
  env OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OSC_REGION=eu-west-2 \
      python3 - "$ROOT/scripts/ops/purge-orphans/outscale.py" "$@" <<PY 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

CANNED = $canned

def fake(req, *a, **k):
    action = req.full_url.rsplit('/', 1)[-1]
    return io.BytesIO(json.dumps(CANNED.get(action, {})).encode())

urllib.request.urlopen = fake
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

# Same as run_osc_canned, but any action named in FAIL_ACTIONS raises HTTP 403
# instead of answering — needed to reproduce a REFUSED call (not just an empty
# one) alongside other calls that succeed normally.
run_osc_canned_fail() { # <CANNED python-dict-literal> <FAIL_ACTIONS python-list-literal> [extra argv...]
  local canned="$1"; local fail_actions="$2"; shift 2
  env OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OSC_REGION=eu-west-2 \
      python3 - "$ROOT/scripts/ops/purge-orphans/outscale.py" "$@" <<PY 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

CANNED = $canned
FAIL_ACTIONS = $fail_actions

def fake(req, *a, **k):
    action = req.full_url.rsplit('/', 1)[-1]
    if action in FAIL_ACTIONS:
        raise urllib.error.HTTPError(req.full_url, 403, 'Forbidden', {},
                                     io.BytesIO(b'{"message":"denied"}'))
    return io.BytesIO(json.dumps(CANNED.get(action, {})).encode())

urllib.request.urlopen = fake
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

# 1. Genuinely empty account — every Read* (including the two new ones)
#    returns nothing. Must still say "clean": the case this fix must not break.
out="$(run_osc_canned '{}')"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "outscale.py: a genuinely empty account (incl. no snapshots/images) still exits 0"
else
  bad "outscale.py: a genuinely empty account no longer exits 0 (rc=${rc}) — false positive"
fi
if grep -qiE 'account is clean' <<<"$out"; then
  ok "outscale.py: it still says clean when nothing at all is present"
else
  bad "outscale.py: it stopped saying clean on a genuinely empty account"
fi

# 2. Only a leftover snapshot — every Net-dependency listing is empty
#    (TOTAL stays 0), but ReadSnapshots answers one. This is #71 itself.
ONLY_SNAPSHOT='{"ReadSnapshots": {"Snapshots": [{"SnapshotId": "snap-orphan", "State": "completed", "VolumeSize": 10}]}}'
out="$(run_osc_canned "$ONLY_SNAPSHOT")"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "outscale.py: an orphan snapshot with nothing else present exits non-zero (rc=${rc})"
else
  bad "outscale.py: an orphan snapshot present and it still exited 0 — the #71 bug"
fi
if grep -qiE 'account is clean' <<<"$out"; then
  bad "outscale.py: it said the account is clean while an orphan snapshot sat there"
else
  ok "outscale.py: it does not claim clean while the snapshot is present"
fi
if grep -q 'snap-orphan' <<<"$out"; then
  ok "outscale.py: it names the orphan snapshot in its output"
else
  bad "outscale.py: the snapshot was found but never named — a transcript reader can't act on it"
fi

# 3. Net resources purged successfully AND a snapshot is left over — the
#    "N resource(s) deleted. The account is clean." branch must not lie either.
DELETED_PLUS_SNAPSHOT='{"ReadNets": {"Nets": [{"NetId": "vpc-stub", "IpRange": "10.0.0.0/16"}]}, "ReadSnapshots": {"Snapshots": [{"SnapshotId": "snap-leftover", "State": "completed", "VolumeSize": 5}]}}'
out="$(run_osc_canned "$DELETED_PLUS_SNAPSHOT" --apply)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "outscale.py --apply: resources deleted but a snapshot remains still exits non-zero (rc=${rc})"
else
  bad "outscale.py --apply: a snapshot remained after a successful purge and it exited 0"
fi
if grep -qiE 'account is clean' <<<"$out" && ! grep -qiE 'NOT fully clean' <<<"$out"; then
  bad "outscale.py --apply: claimed clean while snap-leftover was still listed"
else
  ok "outscale.py --apply: does not claim a plain clean while the snapshot remains"
fi
if grep -q 'snap-leftover' <<<"$out"; then
  ok "outscale.py --apply: names the leftover snapshot after a successful net purge"
else
  bad "outscale.py --apply: the leftover snapshot was never named post-purge"
fi

# 4. The bug review actually caught: a Net is purged successfully (TOTAL>0,
#    FAILED==0) AND ReadSnapshots itself is REFUSED (not merely empty) — a
#    first fix attempt fell through this exact combination to the plain
#    "account is clean" message, because the unreachable-artifacts check only
#    guarded the TOTAL==0 branch.
ONE_NET='{"ReadNets": {"Nets": [{"NetId": "vpc-stub", "IpRange": "10.0.0.0/16"}]}}'
out="$(run_osc_canned_fail "$ONE_NET" "['ReadSnapshots']" --apply)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "outscale.py --apply: net purged + ReadSnapshots refused still exits non-zero (rc=${rc})"
else
  bad "outscale.py --apply: net purged + ReadSnapshots refused exited 0 — the exact bug review caught"
fi
if grep -qiE '^[0-9]+ resource\(s\) deleted\. The account is clean\.$' <<<"$out"; then
  bad "outscale.py --apply: claimed a plain clean while snapshot visibility was refused"
else
  ok "outscale.py --apply: does not claim a plain clean when snapshot visibility was refused"
fi
if grep -qiE 'visibility was refused|refused, unconfirmed' <<<"$out"; then
  ok "outscale.py --apply: says snapshot visibility was refused, not silently clean"
else
  bad "outscale.py --apply: a refused ReadSnapshots after a successful purge left no trace in the output"
fi

# 5. A deletion FAILS in the same run a snapshot is ALSO present — the failed
#    deletion (exit 3) must win over the milder "leftover snapshot" wording
#    (exit 1): FAILED is checked first in outscale.py on purpose.
NET_PLUS_SNAPSHOT='{"ReadNets": {"Nets": [{"NetId": "vpc-stub", "IpRange": "10.0.0.0/16"}]}, "ReadSnapshots": {"Snapshots": [{"SnapshotId": "snap-alongside", "State": "completed", "VolumeSize": 5}]}}'
out="$(run_osc_canned_fail "$NET_PLUS_SNAPSHOT" "['DeleteNet']" --apply)"; rc=$?
if [ "$rc" -eq 3 ]; then
  ok "outscale.py --apply: a failed deletion alongside a leftover snapshot exits 3, not 1"
else
  bad "outscale.py --apply: expected exit 3 (failed deletion wins), got rc=${rc}"
fi
if grep -qiE 'deletion\(s\) failed' <<<"$out"; then
  ok "outscale.py --apply: reports the failed deletion, not just the leftover snapshot"
else
  bad "outscale.py --apply: the failed-deletion message is missing when a snapshot is also present"
fi

# --- Credentials missing or refused: "could not check" (2), never "found" (1) -
# A bare os.environ[...] raised KeyError and exited 1, the code callers read as
# "leftovers found". An unanswered question must keep its own code.
echo
echo "=== missing or refused credentials exit 2 ==="

# One fake Scaleway API for the purge and for verify-provider-clean, which share
# its listing. FAKE_SCW maps a path (no query) to its answer; FAKE_REFUSE lists
# path prefixes answered 403; mutating calls succeed and print "CALL <method> <path>".
# FAKE_PAGE=<n> serves n items per `page=`, like the real API, and FAKE_TOTAL=1
# adds the body's total_count (the instance API reports it in a header instead).
SCW_ENV=(SCW_SECRET_KEY=stub SCW_DEFAULT_PROJECT_ID=stub SCW_DEFAULT_REGION=fr-par SCW_ZONES=fr-par-1)
run_scw() { # <script under scripts/ops/> [args...]
  env "${SCW_ENV[@]}" FAKE_SCW="${FAKE_SCW:-}" FAKE_REFUSE="${FAKE_REFUSE:-}" \
      FAKE_PAGE="${FAKE_PAGE:-}" FAKE_TOTAL="${FAKE_TOTAL:-}" \
      python3 - "$ROOT/scripts/ops/$1" "${@:2}" <<'PY' 2>&1
import io, json, os, runpy, sys, urllib.error, urllib.parse, urllib.request

ANSWERS = json.loads(os.environ['FAKE_SCW'] or '{}')
REFUSE = os.environ['FAKE_REFUSE'].split()
SIZE = int(os.environ['FAKE_PAGE'] or 0)

def fake(req, *a, **k):
    path = req.full_url.split('/', 3)[3]
    bare = path.split('?')[0]
    if any(bare.startswith(r) for r in REFUSE):
        raise urllib.error.HTTPError(req.full_url, 403, 'Forbidden', {}, io.BytesIO(b'{}'))
    if req.get_method() != 'GET':
        print('CALL', req.get_method(), path)
        return io.BytesIO(b'{}')
    data = ANSWERS.get(bare, {})
    if SIZE:
        lo = (int(urllib.parse.parse_qs(path.partition('?')[2]).get('page', ['1'])[0]) - 1) * SIZE
        total = max((len(v) for v in data.values()), default=0)
        data = {key: v[lo:lo + SIZE] for key, v in data.items()}
        if os.environ['FAKE_TOTAL']:
            data['total_count'] = total
    return io.BytesIO(json.dumps(data).encode())

urllib.request.urlopen = fake
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

expect_2() { # <label> <rc> <output> <what the output must name>
  if [ "$2" -eq 2 ] && grep -qF "$4" <<<"$3" && ! grep -q Traceback <<<"$3"; then
    ok "$1: exit 2, names $4"
  else
    bad "$1: expected exit 2 naming '$4', got rc=$2: $(tail -2 <<<"$3" | tr '\n' ' ')"
  fi
}

FAKE_SCW='' FAKE_REFUSE=''
for pair in SCW_SECRET_KEY:SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_PROJECT_ID:SCW_SECRET_KEY; do
  missing="${pair%%:*}"
  SCW_ENV=(-u "$missing" "${pair#*:}=stub" SCW_ZONES=fr-par-1)
  out="$(run_scw purge-orphans/scaleway.py)"; expect_2 "scaleway.py without $missing" $? "$out" "$missing"
  out="$(run_scw verify-provider-clean.py edge-1 scaleway)"
  expect_2 "verify-provider-clean scaleway without $missing" $? "$out" "$missing"
done
SCW_ENV=(SCW_SECRET_KEY=stub SCW_DEFAULT_PROJECT_ID=stub SCW_DEFAULT_REGION=fr-par SCW_ZONES=fr-par-1)

out="$(env -u OS_AUTH_URL OS_USERNAME=s OS_PASSWORD=s OS_PROJECT_ID=s OS_REGION_NAME=s \
       python3 "$ROOT/scripts/ops/purge-orphans/ovh.py" 2>&1)"
expect_2 "ovh.py without OS_AUTH_URL" $? "$out" "OS_AUTH_URL"
out="$(env -u OUTSCALE_SECRET_KEY OUTSCALE_ACCESS_KEY_ID=s \
       python3 "$ROOT/scripts/ops/purge-orphans/outscale.py" 2>&1)"
expect_2 "outscale.py without OUTSCALE_SECRET_KEY" $? "$out" "OUTSCALE_SECRET_KEY"
out="$(run_403 ovh.py OS_AUTH_URL=https://stub.invalid/v3 OS_USERNAME=s OS_PASSWORD=s \
       OS_PROJECT_ID=s OS_REGION_NAME=s)"
expect_2 "ovh.py with its authentication refused" $? "$out" "refused"
out="$(OVH_REGION=GRA9 run_403_ovh_partial)"; expect_2 "ovh.py, region absent from the catalog" $? "$out" "gra9"

# --apply that deleted what it could see while another endpoint refused: not
# clean, and the same exit 2 as scaleway.py below (both said "clean", rc 0).
out="$(run_403_ovh_partial --apply)"; rc=$?
expect_2 "ovh.py --apply, an endpoint refused after a deletion" $rc "$out" "refused"
if grep -qi 'is clean' <<<"$out"; then bad "ovh.py --apply: it called the project clean past a refusal"
  else ok "ovh.py --apply: it does not call the project clean past a refusal"
fi
out="$(run_osc_canned_fail '{"ReadLoadBalancers": {"LoadBalancers": [{"LoadBalancerName": "lb-1"}]}}' \
       "['ReadNets']" --apply)"; rc=$?
expect_2 "outscale.py --apply, ReadNets refused after a deletion" $rc "$out" "refused"
if grep -qi 'is clean' <<<"$out"; then bad "outscale.py --apply: it called the account clean past a refusal"
  else ok "outscale.py --apply: it does not call the account clean past a refusal"
fi

FAKE_REFUSE='instance lb vpc block'
out="$(run_scw purge-orphans/scaleway.py)"; expect_2 "scaleway.py, every call refused" $? "$out" "refused"
out="$(run_scw verify-provider-clean.py edge-1 scaleway)"
expect_2 "verify-provider-clean scaleway, every call refused" $? "$out" "refused"

# Rejected for one product only (a narrow IAM policy): deleting the servers it
# could see is not a clean project, since the load balancers were never asked.
FAKE_SCW='{"instance/v1/zones/fr-par-1/servers": {"servers": [{"id": "srv-1", "name": "edge-1-cp-0"}]}}'
FAKE_REFUSE='lb/'
out="$(run_scw purge-orphans/scaleway.py --apply)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi 'is clean' <<<"$out"
  then ok "scaleway.py --apply: one product refused after a deletion exits 2, not clean"
  else bad "scaleway.py --apply: one product refused, rc=${rc}: $(tail -1 <<<"$out")"
fi

# --- Scaleway: every kind a teardown must leave empty -------------------------
# The purge never listed public gateways, their IPs or LB IPs, so a project
# holding only those read as clean; verify-provider-clean had no Scaleway check.
echo
echo "=== Scaleway: each kind a teardown must leave empty is seen ==="
FAKE_REFUSE=''
Z=instance/v1/zones/fr-par-1
KINDS=(
  "server|$Z/servers|servers|{\"id\": \"srv-1\", \"name\": \"edge-1-cp-0\"}|edge-1-cp-0"
  "LB|lb/v1/zones/fr-par-1/lbs|lbs|{\"id\": \"lb-1\", \"name\": \"edge-1-k8s-lb\"}|edge-1-k8s-lb"
  "flexible IP|$Z/ips|ips|{\"id\": \"ip-1\", \"address\": \"192.0.2.10\", \"server\": null}|192.0.2.10"
  "LB IP|lb/v1/zones/fr-par-1/ips|ips|{\"id\": \"lbip-1\", \"ip_address\": \"192.0.2.11\", \"lb_id\": null}|192.0.2.11"
  "public gateway|vpc-gw/v2/zones/fr-par-1/gateways|gateways|{\"id\": \"gw-1\", \"name\": \"edge-1-gateway\"}|edge-1-gateway"
  "gateway IP|vpc-gw/v2/zones/fr-par-1/ips|ips|{\"id\": \"gwip-1\", \"address\": \"192.0.2.12\", \"gateway_id\": null}|192.0.2.12"
  "volume|block/v1alpha1/zones/fr-par-1/volumes|volumes|{\"id\": \"vol-1\", \"name\": \"orphan-root\", \"size\": 10000000000, \"references\": []}|orphan-root"
  "instance volume|$Z/volumes|volumes|{\"id\": \"iv-1\", \"name\": \"orphan-l_ssd\", \"volume_type\": \"l_ssd\", \"server\": null}|orphan-l_ssd"
  "security group|$Z/security_groups|security_groups|{\"id\": \"sg-1\", \"name\": \"edge-1-sg-cp\", \"project_default\": false}|edge-1-sg-cp"
  "private network|vpc/v2/regions/fr-par/private-networks|private_networks|{\"id\": \"pn-1\", \"name\": \"edge-1-private-network\"}|edge-1-private-network"
)
ALL=''
for k in "${KINDS[@]}"; do
  IFS='|' read -r kind path key item token <<<"$k"
  ALL="${ALL:+$ALL, }\"$path\": {\"$key\": [$item]}"
  FAKE_SCW="{\"$path\": {\"$key\": [$item]}}"
  out="$(run_scw purge-orphans/scaleway.py)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF "$token" <<<"$out"
    then ok "scaleway.py: a lone $kind is targeted (rc=1)"
    else bad "scaleway.py: a lone $kind left rc=${rc}: $(tail -1 <<<"$out")"
  fi
  out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF "$kind $token" <<<"$out"
    then ok "verify-provider-clean scaleway: a lone $kind is a leftover (rc=1)"
    else bad "verify-provider-clean scaleway: a lone $kind left rc=${rc}: $(tail -1 <<<"$out")"
  fi
done

# Deleted through the right call: servers terminate (their local volumes go too)
# and an LB releases its IP; the rest is a DELETE on the listed object.
FAKE_SCW="{$ALL}"
out="$(run_scw purge-orphans/scaleway.py --apply)"; rc=$?
missing_calls=()
for call in "POST $Z/servers/srv-1/action" "DELETE lb/v1/zones/fr-par-1/lbs/lb-1?release_ip=true" \
            "DELETE $Z/ips/ip-1" "DELETE lb/v1/zones/fr-par-1/ips/lbip-1" \
            "DELETE vpc-gw/v2/zones/fr-par-1/gateways/gw-1" "DELETE vpc-gw/v2/zones/fr-par-1/ips/gwip-1" \
            "DELETE block/v1alpha1/zones/fr-par-1/volumes/vol-1" "DELETE $Z/volumes/iv-1" \
            "DELETE $Z/security_groups/sg-1" "DELETE vpc/v2/regions/fr-par/private-networks/pn-1"; do
  grep -qxF "CALL $call" <<<"$out" || missing_calls+=("$call")
done
if [ "$rc" -eq 0 ] && [ "${#missing_calls[@]}" -eq 0 ] && grep -qF '10 resource(s) deleted' <<<"$out"
  then ok "scaleway.py --apply: each of the 10 kinds deleted through its own call"
  else bad "scaleway.py --apply: rc=${rc}, calls not made: ${missing_calls[*]:-none}"
fi

# A live cluster sharing the project: its attached IPs and volume, and the
# project's default security group, are not leftovers of edge-1.
FAKE_SCW="{
  \"$Z/servers\": {\"servers\": [{\"id\": \"s9\", \"name\": \"mgmt-cp-0\", \"tags\": [\"mgmt\"]}]},
  \"$Z/ips\": {\"ips\": [{\"id\": \"i9\", \"address\": \"192.0.2.20\", \"server\": {\"id\": \"s9\"}}]},
  \"$Z/security_groups\": {\"security_groups\": [{\"id\": \"d\", \"name\": \"Default security group\", \"project_default\": true},
                                                {\"id\": \"sg9\", \"name\": \"mgmt-sg-cp\", \"project_default\": false}]},
  \"lb/v1/zones/fr-par-1/lbs\": {\"lbs\": [{\"id\": \"l9\", \"name\": \"mgmt-k8s-lb\"}]},
  \"lb/v1/zones/fr-par-1/ips\": {\"ips\": [{\"id\": \"li9\", \"ip_address\": \"192.0.2.21\", \"lb_id\": \"l9\"}]},
  \"vpc-gw/v2/zones/fr-par-1/gateways\": {\"gateways\": [{\"id\": \"g9\", \"name\": \"mgmt-gateway\"}]},
  \"vpc-gw/v2/zones/fr-par-1/ips\": {\"ips\": [{\"id\": \"gi9\", \"address\": \"192.0.2.22\", \"gateway_id\": \"g9\"}]},
  \"block/v1alpha1/zones/fr-par-1/volumes\": {\"volumes\": [{\"id\": \"v9\", \"name\": \"w\", \"size\": 1, \"references\": [{\"id\": \"r\"}]}]},
  \"$Z/volumes\": {\"volumes\": [{\"id\": \"iv9\", \"name\": \"mgmt-cp-0-l_ssd\", \"server\": {\"id\": \"s9\"}}]},
  \"vpc/v2/regions/fr-par/private-networks\": {\"private_networks\": [{\"id\": \"pn9\", \"name\": \"mgmt-private-network\"}]}}"
out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'nothing left' <<<"$out"
  then ok "verify-provider-clean scaleway: another live cluster in the project is not edge-1's leftover"
  else bad "verify-provider-clean scaleway: another live cluster read as edge-1's, rc=${rc}: $out"
fi
out="$(run_scw purge-orphans/scaleway.py)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF '5 resource(s) targeted' <<<"$out"
  then ok "scaleway.py: 5 targets — attached IPs, the used volume and the default group are not"
  else bad "scaleway.py: expected 5 targets, rc=${rc}: $(tail -1 <<<"$out")"
fi
FAKE_SCW="{\"$Z/servers\": {\"servers\": [{\"id\": \"s8\", \"name\": \"worker-x\", \"tags\": [\"caps-cluster=edge-1\"]}]}}"
out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "verify-provider-clean scaleway: a server named only by its tag is a leftover"
  else bad "verify-provider-clean scaleway: a server tagged edge-1 was missed (rc=${rc})"
fi
FAKE_SCW=''
out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "verify-provider-clean scaleway: an empty project exits 0"
  else bad "verify-provider-clean scaleway: an empty project exited ${rc}: $out"
fi

# edge-10 is not edge-1: a substring match blamed a live cluster's server on the
# one being torn down, and edge-down then failed its teardown after 4 tries. The
# cluster name still matches wherever it sits between separators.
FAKE_SCW="{\"$Z/servers\": {\"servers\": [{\"id\": \"s10\", \"name\": \"edge-10-cp-0\"}]}}"
out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "verify-provider-clean scaleway: edge-10's server is not edge-1's leftover"
  else bad "verify-provider-clean scaleway: edge-10's server read as edge-1's (rc=${rc}): $out"
fi
out="$(run_scw verify-provider-clean.py edge-10 scaleway)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "verify-provider-clean scaleway: the same server is edge-10's leftover"
  else bad "verify-provider-clean scaleway: edge-10's own server was missed (rc=${rc})"
fi
FAKE_SCW="{\"$Z/servers\": {\"servers\": [{\"id\": \"s11\", \"name\": \"kubeapi-edge-1-cp\"}]}}"
out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "verify-provider-clean scaleway: the cluster name between separators still matches"
  else bad "verify-provider-clean scaleway: 'kubeapi-edge-1-cp' was missed (rc=${rc})"
fi

# The same volume listed by the block and the instance API is one leftover.
FAKE_SCW="{\"block/v1alpha1/zones/fr-par-1/volumes\": {\"volumes\": [{\"id\": \"v7\", \"name\": \"twice\", \"size\": 1, \"references\": []}]},
           \"$Z/volumes\": {\"volumes\": [{\"id\": \"v7\", \"name\": \"twice\", \"server\": null}]}}"
out="$(run_scw purge-orphans/scaleway.py)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF '1 resource(s) targeted' <<<"$out"
  then ok "scaleway.py: a volume both APIs list is targeted once"
  else bad "scaleway.py: a volume both APIs list was counted twice, rc=${rc}: $(tail -1 <<<"$out")"
fi

# --- pagination: a listing that stops at page 1 reads the rest as absent -------
# The API returns 50 items a page. Page 2 of 3 gateway IPs (FAKE_PAGE=2) held the
# last one, and 'nothing left' or 'the project is clean' was said over it. Both
# shapes are covered: total_count in the body, and none (the instance API's).
GWIPS="\"vpc-gw/v2/zones/fr-par-1/ips\": {\"ips\": [{\"id\": \"a\", \"address\": \"192.0.2.31\", \"gateway_id\": null},
  {\"id\": \"b\", \"address\": \"192.0.2.32\", \"gateway_id\": null}, {\"id\": \"c\", \"address\": \"192.0.2.33\", \"gateway_id\": null}]}"
SGS="\"$Z/security_groups\": {\"security_groups\": [{\"id\": \"a\", \"name\": \"mgmt-sg-a\", \"project_default\": false},
  {\"id\": \"b\", \"name\": \"mgmt-sg-b\", \"project_default\": false}, {\"id\": \"c\", \"name\": \"edge-1-sg-c\", \"project_default\": false}]}"
for total in without with; do
  FAKE_PAGE=2 FAKE_TOTAL=''; [ "$total" = with ] && FAKE_TOTAL=1
  shape="$total total_count"
  FAKE_SCW="{$GWIPS}"
  out="$(run_scw purge-orphans/scaleway.py --apply)"; rc=$?
  if [ "$rc" -eq 0 ] && grep -qF '3 resource(s) deleted' <<<"$out"
    then ok "scaleway.py --apply: 3 items over 2 pages are all deleted, $shape"
    else bad "scaleway.py --apply: only page 1 was seen, $shape (rc=${rc}): $(tail -1 <<<"$out")"
  fi
  FAKE_SCW="{$SGS}"
  out="$(run_scw verify-provider-clean.py edge-1 scaleway)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'edge-1-sg-c' <<<"$out"
    then ok "verify-provider-clean scaleway: edge-1's group on page 2 is found, $shape"
    else bad "verify-provider-clean scaleway: page 2 was never read, $shape (rc=${rc}): $out"
  fi
done
FAKE_PAGE='' FAKE_TOTAL=''

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
