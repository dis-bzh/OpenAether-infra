#!/usr/bin/env python3
"""A fake OpenStack for test-ovh-lb-members.sh: enough of a cloud for a real `tofu plan` of the OVH module.

  fake-openstack.py serve <port-file> <request-log>
      Keystone, and the two reads a `plan -refresh=false` makes (the external network, the bastion image). Every
      request is logged, so a test can prove a plan wrote nothing. Anything else is a 404.
  fake-openstack.py fold <state> <plan-json> <seed-json> <types-json>
      Write into <state> what the cloud would hold once <plan-json> is applied: created and changed resources
      take their planned values, a computed one any value of its type (from <types-json>, the provider schema)
      unless <seed-json> gives it ({address: {attribute: value}}, e.g. the nodes' addresses); deleted and
      forgotten ones leave. Folding the plans of one module until they are empty gives the state of a converged cluster.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PROVIDER = 'provider["registry.opentofu.org/terraform-provider-openstack/openstack"]'


def serve(port_file, log_file):
    log = open(log_file, "a", buffering=1)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, code, body, headers=None):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def any(self):
            log.write(f"{self.command} {self.path}\n")
            base = f"http://127.0.0.1:{self.server.server_port}"
            path = self.path.split("?")[0]
            if self.command == "POST" and path == "/v3/auth/tokens":
                def ep(kind, url):
                    return {"type": kind, "name": kind, "endpoints": [
                        {"interface": "public", "region": "R", "region_id": "R", "url": base + url}]}
                domain = {"id": "default", "name": "Default"}
                return self.reply(201, {"token": {
                    "expires_at": "2099-01-01T00:00:00.000000Z", "issued_at": "2020-01-01T00:00:00.000000Z",
                    "methods": ["password"], "user": {"id": "u", "name": "u", "domain": domain},
                    "project": {"id": "t", "name": "t", "domain": domain},
                    "catalog": [ep("network", "/network/"), ep("image", "/image/"),
                                ep("compute", "/compute/v2.1/"), ep("load-balancer", "/lb/")]}},
                    {"X-Subject-Token": "fake"})
            if self.command == "GET" and path == "/network/v2.0/networks":
                return self.reply(200, {"networks": [{
                    "id": "ext-net", "name": "Ext-Net", "status": "ACTIVE", "admin_state_up": True,
                    "router:external": True, "subnets": [], "tenant_id": "t", "project_id": "t", "shared": False,
                    "tags": []}]})
            if self.command == "GET" and path == "/image/v2/images":
                return self.reply(200, {"images": [{
                    "id": "bastion-image", "name": "Ubuntu 22.04", "status": "active", "visibility": "public",
                    "created_at": "2020-01-01T00:00:00Z", "updated_at": "2020-01-01T00:00:00Z", "tags": [],
                    "size": 1, "min_disk": 0, "min_ram": 0}]})
            self.reply(404, {"error": "not served by the fake"})

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = any

    server = HTTPServer(("127.0.0.1", 0), Handler)  # any free port: the harness shards must not collide
    with open(port_file, "w") as f:
        f.write(str(server.server_port))
    server.serve_forever()


def merge(old, new, unknown):
    """The planned value, except where the plan does not know it yet: there, what the state holds."""
    if isinstance(new, dict) and isinstance(old, dict):
        u = unknown if isinstance(unknown, dict) else {}
        return {**old, **{k: merge(old.get(k), v, u.get(k)) for k, v in new.items()}}
    if isinstance(new, list) and isinstance(old, list) and isinstance(unknown, list):
        return [merge(old[i] if i < len(old) else None, v, unknown[i] if i < len(unknown) else None)
                for i, v in enumerate(new)]
    return old if unknown is True and new is None else new


def dummy(kind, text):
    if kind == "string":
        return text
    if kind in ("number", "bool"):
        return 0 if kind == "number" else False
    return {} if kind[0] == "map" else []


def fold(state_path, plan_path, seed_path, types_path):
    plan, seed, types = (json.load(open(p)) for p in (plan_path, seed_path, types_path))
    try:
        state = json.load(open(state_path))
    except FileNotFoundError:
        state = {"version": 4, "terraform_version": "1.13.9", "serial": 0, "lineage": "oa-test", "outputs": {},
                 "resources": []}
    by_key = {(r["module"], r["type"], r["name"]): r for r in state["resources"]}
    for rc in plan.get("resource_changes", []):
        actions, change = rc["change"]["actions"], rc["change"]
        if rc["mode"] != "managed" or actions in (["no-op"], ["read"]):
            continue
        key = (rc["module_address"], rc["type"], rc["name"])
        if key not in by_key:
            by_key[key] = {"module": key[0], "mode": "managed", "type": key[1], "name": key[2],
                           "provider": PROVIDER, "instances": []}
            state["resources"].append(by_key[key])
        instances, index = by_key[key]["instances"], rc.get("index")
        inst = next((i for i in instances if i.get("index_key") == index), None)
        if actions in (["delete"], ["forget"]):
            if inst:
                instances.remove(inst)
            continue
        if inst is None:
            inst = {"schema_version": 0, "attributes": {"id": "id-" + rc["address"].split(".", 2)[-1]}}
            if index is not None:
                inst["index_key"] = index
            instances.append(inst)
        attrs = merge(inst["attributes"], change["after"], change["after_unknown"])
        for name, unknown in change["after_unknown"].items():
            kind = types.get(rc["type"], {}).get(name)
            if unknown is True and attrs.get(name) is None and kind is not None:
                attrs[name] = dummy(kind, f"{name}-of-{rc['address'].split('.', 2)[-1]}")
        attrs.update(seed.get(rc["address"], {}))
        attrs["id"] = attrs.get("id") or inst["attributes"]["id"]
        inst["attributes"] = attrs
    state["resources"] = [r for r in state["resources"] if r["instances"]]
    state["serial"] += 1
    with open(state_path, "w") as f:
        json.dump(state, f, indent=1)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"serve": serve, "fold": fold}[cmd](*args)
