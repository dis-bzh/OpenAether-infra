#!/usr/bin/env python3
"""CycloneDX 1.5 inventory of what this repository pins and ships (ANSSI SBOM25-1/-2/-3, SSDLC CICD-AIP-01b).

Offline and deterministic. It lists, from files already in the tree:
  - every tool pinned behind a `# renovate:` anchor (CI actions' tools, installers, generators),
  - every OpenTofu provider locked in the two committed .terraform.lock.hcl files,
  - every container image of the bootstrap manifests (Cilium, Flux), with the digest it resolves to,
  - the Talos Image Factory raw images of images.lock (the OS of every node), with their sha256.

It is an inventory, not a vulnerability report: the weekly workflow scans the container images
with Trivy (sbom.yml) and Cléa asks OSV about the tool pins. What it cannot see: anything the
applications repository deploys, and the contents of the images (no layer is read here).

Usage: gen-sbom.py [--version <tag>] [--timestamp <iso8601>] [--output <file>] [--images]
  --images prints only the distinct image references, one per line (the scan matrix).
"""
import argparse
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
BOOT = "infrastructure/opentofu/cluster/bootstrap-manifests"
LOCKS = ["infrastructure/opentofu/cluster/.terraform.lock.hcl", "infrastructure/opentofu/talos-image/.terraform.lock.hcl"]
IMAGE_RE = re.compile(r"^[ \t]*-?[ \t]*image:[ \t]*[\"']?([^\"'\s#]+)", re.M)
PROVIDER_RE = re.compile(r'^provider "([^"]+)" \{\s*\n\s*version\s*=\s*"([^"]+)"', re.M)


def load_clea(root):
    spec = importlib.util.spec_from_file_location("clea", root / "scripts/clea/clea.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["clea"] = mod
    spec.loader.exec_module(mod)
    return mod


def tool_purl(datasource, dep, version):
    v = quote(version.lstrip("v") if datasource.startswith("github") else version, safe="")
    if datasource in ("github-releases", "github-tags"):
        return f"pkg:github/{dep}@{v}"
    if datasource == "pypi":
        return f"pkg:pypi/{dep.lower()}@{v}"
    if datasource == "npm":
        return f"pkg:npm/{dep}@{v}"
    return f"pkg:generic/{dep}@{v}"


def split_image(ref):
    """(registry/name, tag or None, digest or None) of an image reference."""
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    tag = None
    last = ref.rsplit("/", 1)[-1]
    if ":" in last:
        ref, tag = ref.rsplit(":", 1)
    return ref, tag, digest


def image_component(ref, recorded):
    name, tag, digest = split_image(ref)
    digest = digest or recorded.get(ref)
    registry, _, path = name.partition("/")
    purl = f"pkg:oci/{path.rsplit('/', 1)[-1]}"
    purl += f"@{quote(digest, safe='')}" if digest else (f"@{quote(tag, safe='')}" if tag else "")
    qual = [f"repository_url={quote(name, safe='')}"] + ([f"tag={quote(tag, safe='')}"] if tag and digest else [])
    purl += "?" + "&".join(qual)
    comp = {"type": "container", "bom-ref": purl, "name": name, "version": tag or digest or "unversioned", "purl": purl}
    if digest and digest.startswith("sha256:"):
        comp["hashes"] = [{"alg": "SHA-256", "content": digest[len("sha256:"):]}]
    return comp


def images(root):
    """{reference: [files]} of every `image:` in the bootstrap manifests."""
    found = {}
    for f in sorted((root / BOOT).glob("*.yaml")):
        for ref in IMAGE_RE.findall(f.read_text(encoding="utf-8")):
            if "${" in ref or "{{" in ref:
                continue
            found.setdefault(ref, []).append(f.relative_to(root).as_posix())
    return found


def recorded_digests(root):
    out = {}
    lock = root / BOOT / "flux-image-digests.lock"
    if lock.is_file():
        for line in lock.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                out[parts[0]] = parts[1]
    return out


def build(root, version, timestamp):
    clea = load_clea(root)
    cfg = clea.load_config(root / "clea.toml")
    anchors, _ = clea.scan_anchors(root, cfg["scan"]["marker"], cfg["scan"]["exclude"], cfg["scan"]["include"])
    comps = {}

    def add(c, where):
        known = comps.setdefault(c["bom-ref"], c)
        props = known.setdefault("properties", [])
        p = {"name": "oa:where", "value": where}
        if p not in props:
            props.append(p)

    for a in anchors:
        purl = tool_purl(a.datasource, a.dep, a.value)
        add({"type": "application", "bom-ref": purl, "name": a.dep, "version": a.value, "purl": purl}, f"{a.path}:{a.line}")
    for lock in LOCKS:
        p = root / lock
        if not p.is_file():
            continue
        for addr, ver in PROVIDER_RE.findall(p.read_text(encoding="utf-8")):
            reg, ns, name = addr.split("/")
            purl = f"pkg:generic/{ns}/{name}@{quote(ver, safe='')}?repository_url={quote('https://' + reg, safe='')}"
            add({"type": "library", "bom-ref": purl, "name": f"{ns}/{name}", "version": ver, "purl": purl,
                 "description": "OpenTofu provider, as locked"}, lock)
    recorded = recorded_digests(root)
    for ref, files in images(root).items():
        for f in files:
            add(image_component(ref, recorded), f)
    images_lock = root / "infrastructure/opentofu/talos-image/images.lock"
    if images_lock.is_file():
        for line in images_lock.read_text().splitlines():
            m = re.fullmatch(r"([0-9a-f]{64})\s+(\S+)", line.strip())
            if m:
                key = m.group(2)
                purl = "pkg:generic/talos-factory/" + quote(key.split("/")[-1], safe="") + "@" + quote(key.split("/")[1], safe="")
                add({"type": "file", "bom-ref": f"{purl}#{key}", "name": key, "version": key.split("/")[1],
                     "hashes": [{"alg": "SHA-256", "content": m.group(1)}],
                     "description": "Talos Image Factory raw.zst, schematic/version/platform-arch"},
                    "infrastructure/opentofu/talos-image/images.lock")
    for c in comps.values():
        c["properties"].sort(key=lambda p: p["value"])
    ordered = sorted(comps.values(), key=lambda c: (c["type"], c["bom-ref"]))
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": {"components": [{"type": "application", "name": "gen-sbom.py", "version": "1"}]},
            "component": {"type": "application", "bom-ref": "openaether-infra", "name": "OpenAether-infra", "version": version},
        },
        "components": ordered,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--version", default="unreleased", help="the tag or commit this inventory describes")
    ap.add_argument("--timestamp", help="ISO 8601; default SOURCE_DATE_EPOCH, else now")
    ap.add_argument("--output", help="write here instead of stdout")
    ap.add_argument("--images", action="store_true", help="print the distinct image references only")
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args(argv)
    root = Path(a.root)
    if a.images:
        rec = recorded_digests(root)
        for ref in sorted(images(root)):
            print(ref if "@" in ref else f"{ref}@{rec[ref]}" if ref in rec else ref)
        return 0
    ts = a.timestamp
    if not ts:
        epoch = os.environ.get("SOURCE_DATE_EPOCH")
        ts = (datetime.fromtimestamp(int(epoch), timezone.utc) if epoch else datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    bom = build(root, a.version, ts)
    if not bom["components"]:
        print("✗ the inventory is empty: the extractors are broken, not the repository", file=sys.stderr)
        return 1
    text = json.dumps(bom, indent=2, sort_keys=True) + "\n"
    if a.output:
        Path(a.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
