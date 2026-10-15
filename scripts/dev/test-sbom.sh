#!/usr/bin/env bash
# gen-sbom.py on a fixture tree (each extractor seen to find its input, and to skip the lookalike) and on the real
# tree (a floor per component kind: an inventory that silently lists nothing is the defect this guards against).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/scripts/dev/gen-sbom.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

F="$TMP/repo"; B=infrastructure/opentofu/cluster/bootstrap-manifests
mkdir -p "$F/scripts/clea" "$F/$B" "$F/infrastructure/opentofu/cluster" "$F/infrastructure/opentofu/talos-image"
cp "$ROOT/scripts/clea/clea.py" "$F/scripts/clea/"
printf '[scan]\nmarker = "# renovate:"\n' >"$F/clea.toml"
printf '# renovate: datasource=github-releases depName=acme/tool\nTOOL_VERSION="1.2.3"\n# renovate: datasource=pypi depName=Acme-Lint\nLINT_VERSION="4.5.6"\n' >"$F/scripts/pins.sh"
cat >"$F/infrastructure/opentofu/cluster/.terraform.lock.hcl" <<'HCL'
provider "registry.opentofu.org/example/widget" {
  version     = "2.9.1"
  constraints = "~> 2.9"
  hashes = [
    "h1:aaaa=",
  ]
}
HCL
D=0000000000000000000000000000000000000000000000000000000000000001
printf 'ghcr.io/acme/ctl:v1.0.0 sha256:%s\n' "$D" >"$F/$B/flux-image-digests.lock"
cat >"$F/$B/m.yaml" <<YAML
spec:
  containers:
    - image: ghcr.io/acme/ctl:v1.0.0
    - image: quay.io/acme/pinned:v2@sha256:$(printf '2%.0s' $(seq 64))
properties:
  image:
    description: not an image, a schema property
    type: string
YAML
H=$(printf '3%.0s' $(seq 64))
printf '%s  %s\n' "$H" "$(printf '4%.0s' $(seq 64))/v9.9.9/nocloud-amd64" >"$F/infrastructure/opentofu/talos-image/images.lock"

out="$TMP/fx.json"
python3 -I "$GEN" --root "$F" --version v0.0.1 --timestamp 2026-01-01T00:00:00Z --output "$out" || bad "the generator failed on the fixture"
q() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$out" "$1"; }
[ "$(q 'd["specVersion"]+" "+d["bomFormat"]')" = "1.5 CycloneDX" ] && ok "CycloneDX 1.5" || bad "wrong header"
[ "$(q 'd["metadata"]["component"]["version"]')" = v0.0.1 ] && ok "the release tag is the described component's version" || bad "version not recorded"
[ "$(q '[c["purl"] for c in d["components"] if c["name"]=="acme/tool"][0]')" = "pkg:github/acme/tool@1.2.3" ] && ok "an anchored GitHub tool becomes pkg:github" || bad "tool purl"
[ "$(q '[c["purl"] for c in d["components"] if c["name"]=="Acme-Lint"][0]')" = "pkg:pypi/acme-lint@4.5.6" ] && ok "a PyPI pin becomes pkg:pypi, name lowercased" || bad "pypi purl"
[ "$(q '[c["version"] for c in d["components"] if c["name"]=="example/widget"][0]')" = 2.9.1 ] && ok "a locked provider is listed at its locked version" || bad "provider missing"
[ "$(q 'len([c for c in d["components"] if c["type"]=="container"])')" = 2 ] && ok "two images; the schema property named image is not one" || bad "image extractor: $(q '[c["name"] for c in d["components"] if c["type"]=="container"]')"
[ "$(q '[c["hashes"][0]["content"] for c in d["components"] if c["name"]=="ghcr.io/acme/ctl"][0]')" = "$D" ] && ok "a tag-only image takes the digest recorded in flux-image-digests.lock" || bad "recorded digest not used"
[ "$(q '[c["hashes"][0]["content"] for c in d["components"] if c["type"]=="file"][0]')" = "$H" ] && ok "a Factory image carries its images.lock sha256" || bad "images.lock not read"
[ "$(q 'len({c["bom-ref"] for c in d["components"]})==len(d["components"])')" = True ] && ok "every bom-ref is unique" || bad "duplicate bom-ref"
python3 -I "$GEN" --root "$F" --version v0.0.1 --timestamp 2026-01-01T00:00:00Z --output "$TMP/again.json"
cmp -s "$out" "$TMP/again.json" && ok "the same tree and timestamp give the same bytes" || bad "the output is not deterministic"
[ "$(python3 -I "$GEN" --root "$F" --images | tr '\n' ' ')" = "ghcr.io/acme/ctl:v1.0.0@sha256:$D quay.io/acme/pinned:v2@sha256:$(printf '2%.0s' $(seq 64)) " ] \
  && ok "--images lists each reference once, with its digest" || bad "--images: $(python3 -I "$GEN" --root "$F" --images)"
mkdir -p "$TMP/empty"; python3 -I "$GEN" --root "$TMP/empty" >/dev/null 2>&1
[ $? -ne 0 ] && ok "a tree with nothing to list fails instead of printing an empty inventory" || bad "an empty tree passed"

echo "=== the real tree ==="
python3 -I "$GEN" --version test --timestamp 2026-01-01T00:00:00Z --output "$TMP/real.json" && ok "generates" || bad "the real tree fails"
python3 -I - "$TMP/real.json" <<'PY' && ok "floors: tools, providers, images and Factory files are all listed" || bad "a component kind is empty or malformed"
import json, sys
d = json.load(open(sys.argv[1]))
by = {}
for c in d["components"]:
    by.setdefault(c["type"], []).append(c)
assert len(by.get("application", [])) >= 15, "tool pins"
assert len(by.get("library", [])) >= 5, "providers"
assert len(by.get("container", [])) >= 8, "images"
assert len(by.get("file", [])) >= 4, "factory images"
assert all(c.get("hashes") for c in by["container"]), "an image without a digest"
assert all(c["name"] != "description:" for c in by["container"]), "a schema property read as an image"
assert len({c["bom-ref"] for c in d["components"]}) == len(d["components"]), "duplicate bom-ref"
PY

python3 -I - "$ROOT/.vex/openaether-infra.openvex.json" <<'PY' && ok "the VEX file is well-formed OpenVEX: required fields, and every not_affected statement says why" || bad "the VEX file is malformed"
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("@context", "@id", "author", "timestamp", "version", "statements"):
    assert k in d, f"missing {k}"
assert d["@context"].startswith("https://openvex.dev/ns/v"), "context"
assert isinstance(d["statements"], list)
for s in d["statements"]:
    assert (s.get("vulnerability") or {}).get("name"), "a statement without a vulnerability name"
    assert s.get("products") and all(p.get("@id", "").startswith("pkg:") for p in s["products"]), "Trivy needs a purl per product"
    assert s.get("status") in ("not_affected", "affected", "fixed", "under_investigation"), "status"
    if s["status"] == "not_affected":
        assert s.get("justification") or s.get("impact_statement"), "not_affected needs a justification or an impact_statement"
PY

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
