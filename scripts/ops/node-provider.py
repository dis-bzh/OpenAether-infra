#!/usr/bin/env python3
"""Ask the cloud provider what a node's machine is doing, and hard-reboot it (0.4.0 M4, infra #371).

A node can be dead while OpenTofu and the provider console still show it up: OVH reports the instance ACTIVE with the kubelet
silent (infra #49, #371; lab 17). `state` separates the cases that need different commands:

  running    the provider says the machine runs        -> if the node is silent: `recover` (hard reboot)
  stopped    powered off / shut off                    -> `replace` the node (or power it on at the provider)
  error      the provider put it in an error state     -> `replace`
  absent     no machine of that name or address        -> `replace`
  transition a reboot, a build, a resize in progress   -> wait
  unknown    the provider did not answer               -> nothing is decided from it

Usage: node-provider.py state       <ovh|scaleway|outscale> --name NAME [--ip IP]
       node-provider.py hard-reboot <ovh|scaleway|outscale> --name NAME [--ip IP]
Prints one JSON object on stdout. Exit 0 when the provider answered, 2 for a missing credential or an unreachable API
(nothing was decided), 3 when hard-reboot was refused or failed. NAME is the instance name the modules give
(<cluster>-cp-N, <cluster>-worker-N); IP (the node's private address) is the fallback where the API shows addresses.
The credentials are the ones `source .env.sh` already exports for the provider; this script never prints them.
Scaleway and Outscale are written from their API documentation and have not been run against a real account (UNVERIFIED);
OVH (OpenStack) follows purge-orphans/ovh.py.
`OA_PROVIDER_TEST_BASE` points all three at a local fake for the offline tests and allows plain http there only.
"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request

TEST_BASE = os.environ.get("OA_PROVIDER_TEST_BASE", "")


def die(msg, code=2):
    print(json.dumps({"state": "unknown", "error": msg}), file=sys.stderr if code else sys.stdout)
    sys.exit(code)


def http(method, url, body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=dict({"Content-Type": "application/json"}, **(headers or {})))
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {}), r.headers
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:200]}, e.headers
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        die("provider API unreachable (%s)" % str(e)[:80])


def need(*names):
    miss = [n for n in names if not os.environ.get(n)]
    if miss:
        die("missing credential %s - source .env.sh first. Nothing was decided." % ", ".join(miss))
    return [os.environ[n] for n in names]


# --- OVH (OpenStack) -----------------------------------------------------------------------------------------------
OVH_STATE = {"ACTIVE": "running", "SHUTOFF": "stopped", "ERROR": "error", "BUILD": "transition", "REBOOT": "transition",
             "HARD_REBOOT": "transition", "REBUILD": "transition", "RESIZE": "transition", "PAUSED": "stopped",
             "SUSPENDED": "stopped", "DELETED": "absent", "SOFT_DELETED": "absent"}


def ovh_connect():
    if TEST_BASE:
        return TEST_BASE.rstrip("/") + "/compute/v2.1", {"X-Auth-Token": "test"}
    auth_url, user, pw, project, region = need("OS_AUTH_URL", "OS_USERNAME", "OS_PASSWORD", "OS_PROJECT_ID", "OS_REGION_NAME")
    base = auth_url.rstrip("/")
    if not base.startswith("https://"):  # the password goes in this request
        die("OS_AUTH_URL must be https:// - the password would travel in clear. Nothing was sent.")
    url = base + ("/auth/tokens" if base.endswith("/v3") else "/v3/auth/tokens")
    body = {"auth": {"identity": {"methods": ["password"], "password": {"user": {
        "name": user, "password": pw, "domain": {"name": os.environ.get("OS_USER_DOMAIN_NAME", "Default")}}}},
        "scope": {"project": {"id": project}}}}
    st, d, h = http("POST", url, body)
    if st >= 300:
        die("OpenStack authentication refused (HTTP %s)" % st)
    cat = d["token"]["catalog"]
    ep = next(e["url"] for s in cat if s["type"] == "compute" for e in s["endpoints"]
              if e["interface"] == "public" and e["region"].lower() == region.lower()).rstrip("/")
    return ep, {"X-Auth-Token": h["X-Subject-Token"]}


def ovh_find(ep, hdr, name, ip):
    st, d, _ = http("GET", ep + "/servers/detail", headers=hdr)
    if st >= 300:
        die("server listing refused (HTTP %s)" % st)
    for s in d.get("servers", []):
        addrs = [a.get("addr") for net in (s.get("addresses") or {}).values() for a in net]
        if s.get("name") == name or (ip and ip in addrs):
            return s
    return None


def ovh(action, name, ip):
    ep, hdr = ovh_connect()
    s = ovh_find(ep, hdr, name, ip)
    if s is None:
        return {"provider": "ovh", "state": "absent", "raw": "no server named %s" % name}
    out = {"provider": "ovh", "id": s["id"], "raw": s["status"], "state": OVH_STATE.get(s["status"], "unknown")}
    if action == "hard-reboot":
        st, _, _ = http("POST", "%s/servers/%s/action" % (ep, s["id"]), {"reboot": {"type": "HARD"}}, hdr)
        out["requested"] = "HARD reboot"
        out["accepted"] = st < 300
    return out


# --- Scaleway -----------------------------------------------------------------------------------------------------
SCW_STATE = {"running": "running", "stopped": "stopped", "stopped in place": "stopped", "starting": "transition",
             "stopping": "transition", "locked": "unknown"}


def scw(action, name, ip):
    if TEST_BASE:
        api, token, project, zones = TEST_BASE.rstrip("/") + "/scw", "test", "p", ["z1"]
    else:
        token, project = need("SCW_SECRET_KEY", "SCW_DEFAULT_PROJECT_ID")
        region = os.environ.get("SCW_DEFAULT_REGION", "fr-par")
        api = "https://api.scaleway.com"
        zones = os.environ.get("SCW_ZONES", "%s-1,%s-2,%s-3" % (region, region, region)).split(",")
    hdr = {"X-Auth-Token": token}
    answered = False
    for z in zones:
        st, d, _ = http("GET", "%s/instance/v1/zones/%s/servers?project=%s&name=%s" % (api, z, project, name), headers=hdr)
        if st >= 300:
            continue
        answered = True
        for s in d.get("servers", []):
            if s.get("name") == name:
                out = {"provider": "scaleway", "id": s["id"], "zone": z, "raw": s["state"], "state": SCW_STATE.get(s["state"], "unknown")}
                if action == "hard-reboot":
                    st, _, _ = http("POST", "%s/instance/v1/zones/%s/servers/%s/action" % (api, z, s["id"]), {"action": "reboot"}, hdr)
                    out["requested"] = "reboot"
                    out["accepted"] = st < 300
                return out
    if not answered:
        die("no Scaleway zone answered")
    return {"provider": "scaleway", "state": "absent", "raw": "no server named %s" % name}


# --- Outscale -----------------------------------------------------------------------------------------------------
OSC_STATE = {"running": "running", "stopped": "stopped", "pending": "transition", "stopping": "transition",
             "shutting-down": "transition", "terminated": "absent"}


def osc_call(action, payload):
    if TEST_BASE:
        st, d, _ = http("POST", "%s/osc/api/v1/%s" % (TEST_BASE.rstrip("/"), action), payload)
        return st, d
    ak, sk = need("OUTSCALE_ACCESS_KEY_ID", "OUTSCALE_SECRET_KEY")
    region = os.environ.get("OSC_REGION", os.environ.get("OUTSCALE_REGION", "eu-west-2"))
    host, service, body = "api.%s.outscale.com" % region, "api", json.dumps(payload)
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
    canonical = ("POST\n/api/v1/%s\n\ncontent-type:application/json\nhost:%s\nx-amz-date:%s\n\ncontent-type;host;x-amz-date\n%s"
                 % (action, host, amzdate, hashlib.sha256(body.encode()).hexdigest()))
    scope = "%s/%s/%s/aws4_request" % (datestamp, region, service)
    to_sign = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (amzdate, scope, hashlib.sha256(canonical.encode()).hexdigest())
    k = ("AWS4" + sk).encode()
    for part in (datestamp, region, service, "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    st, d, _ = http("POST", "https://%s/api/v1/%s" % (host, action), payload, {
        "X-Amz-Date": amzdate, "Authorization": "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=content-type;host;x-amz-date, Signature=%s"
        % (ak, scope, sig)})
    return st, d


def osc(action, name, ip):
    flt = {"Tags": ["Name=%s" % name]} if name else {"PrivateIps": [ip]}
    st, d = osc_call("ReadVms", {"Filters": flt})
    if st >= 300:
        die("ReadVms refused (HTTP %s)" % st)
    vms = [v for v in d.get("Vms", []) if v.get("State") != "terminated"]
    if not vms:
        return {"provider": "outscale", "state": "absent", "raw": "no VM named %s" % name}
    v = vms[0]
    out = {"provider": "outscale", "id": v["VmId"], "raw": v.get("State", ""), "state": OSC_STATE.get(v.get("State"), "unknown")}
    if action == "hard-reboot":
        # ForceStop then Start: RebootVms asks the guest, which is exactly what is not answering. The BSU volumes survive.
        st1, _ = osc_call("StopVms", {"VmIds": [v["VmId"]], "ForceStop": True})
        st2, _ = osc_call("StartVms", {"VmIds": [v["VmId"]]})
        out["requested"] = "ForceStop then Start"
        out["accepted"] = st1 < 300 and st2 < 300
    return out


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("state", "hard-reboot") or sys.argv[2] not in ("ovh", "scaleway", "outscale"):
        sys.exit(__doc__)
    action, provider, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    name = ip = ""
    while args:
        a = args.pop(0)
        if a == "--name" and args:
            name = args.pop(0)
        elif a == "--ip" and args:
            ip = args.pop(0)
        else:
            sys.exit("unknown argument: %s" % a)
    if not name and not ip:
        sys.exit("--name or --ip is required")
    out = {"ovh": ovh, "scaleway": scw, "outscale": osc}[provider](action, name, ip)
    print(json.dumps(out))
    if action == "hard-reboot" and (out["state"] in ("absent", "unknown") or not out.get("accepted")):
        sys.exit(3)


if __name__ == "__main__":
    main()
