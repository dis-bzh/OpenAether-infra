#!/usr/bin/env bash
# Offline schema validation of flux-bootstrap.yaml.tftpl — the manifest that
# tells Flux what to reconcile, and until now validated by nobody (#114).
# ci.yml's security job comment used to claim Trivy scanned it; `.tftpl`
# matches no Trivy detector, and every yamllint invocation (`task lint`, the
# pre-commit hook) is scoped to `*.yaml`/`*.yml`. A wrong key (`internal` for
# `interval`), a quoted boolean, a `60` where `60s` is required, or a
# `v1beta2` that no longer exists would all have reached a cluster.
#
# CRD schemas come from the VENDORED flux-install.yaml, not from upstream or
# from flux-schema's own built-in Flux catalog — either could target a
# different Flux release than the one this repository actually pins,
# reintroducing the drift check-version-drift.sh exists to kill. The template's
# other kind (ConfigMap) falls back to the built-in `default` catalog.
#
# Needs the flux CLI with the flux-schema plugin installed — both pinned in
# ci.yml's lint job and in scripts/setup.sh, same version in each (`flux
# plugin install schema@<version>` does its own checksum verification, per
# fluxcd/flux2 RFC 0013's "centralized catalog with checksum verification").
#
# Usage: check-flux-schema.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MANIFESTS_DIR="infrastructure/opentofu/cluster/bootstrap-manifests"
TEMPLATE="${MANIFESTS_DIR}/flux-bootstrap.yaml.tftpl"
VENDORED="${MANIFESTS_DIR}/flux-install.yaml"

command -v flux >/dev/null 2>&1 || {
  echo "✗ flux CLI not found — scripts/setup.sh installs it (task setup)," >&2
  echo "  or see .github/workflows/ci.yml's lint job for the pinned version" >&2
  exit 1
}
flux schema version >/dev/null 2>&1 || {
  echo "✗ the flux-schema plugin is not installed — flux plugin install schema@<version>" >&2
  echo "  (scripts/setup.sh installs the pinned one — task setup)" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Rendered by OpenTofu's own templatefile(), not by sed: the template has %{ if }/%{ for } directives (the OpenBao
# recovery-share ConfigMap), and a different engine would validate a different manifest. Both shapes are checked: no
# keys (a development cluster) and three keys (a production one). Fixed dummy values — see cluster/main.tf's
# templatefile() call for the real ones (grep it if this list and that call ever disagree). None need to resolve
# to anything real: the point is that the RENDERED yaml is schema-valid, not that these values mean something.
command -v tofu >/dev/null 2>&1 || { echo "✗ tofu not found — the template is rendered with templatefile()" >&2; exit 1; }
mkdir -p "$tmp/render"
cat > "$tmp/render/main.tf" <<HCL
variable "keys" {
  type = list(string)
}
variable "verify" {
  type    = bool
  default = false
}
variable "sink" {
  type    = string
  default = ""
}
variable "sink2" {
  type    = string
  default = ""
}
output "manifest" {
  value = templatefile("$ROOT/$TEMPLATE", {
    namespace         = "flux-system"
    git_repo_url      = "https://example.invalid/openaether.git"
    git_ref           = "refs/heads/main"
    cluster_role      = "management"
    cluster_id        = "openaether-check-flux-schema"
    backup_target_url = "s3://openaether-check@fr-par/"
    backup_s3_bucket  = "openaether-check"
    backup_s3_endpoint = "s3.fr-par.example.invalid"
    backup_replica_s3_bucket   = "openaether-check-backup"
    backup_replica_s3_endpoint = "s3.gra.example.invalid"
    audit_sink_host            = var.sink
    audit_sink_secondary_host  = var.sink2
    openbao_pgp_keys  = var.keys
    openbao_threshold = 2
    flux_git_verify_enabled = var.verify
    flux_git_verify_keys    = var.verify ? ["-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBAAA\n=abcd\n-----END PGP PUBLIC KEY BLOCK-----"] : []
  })
}
HCL
(cd "$tmp/render" && tofu init -input=false >/dev/null 2>&1) || { echo "✗ tofu init failed in the render sandbox" >&2; exit 1; }
render() { # <name> <keys json> [verify true|false] [sink host] [secondary sink host]
  (cd "$tmp/render" && tofu apply -auto-approve -input=false -var "keys=$2" -var "verify=${3:-false}" -var "sink=${4:-}" -var "sink2=${5:-}" >/dev/null 2>&1 && tofu output -raw manifest) > "$tmp/$1.yaml" ||
    { echo "✗ the template does not render ($1)" >&2; exit 1; }
}
render rendered-dev '[]'
render rendered-prod '["AAAA","BBBB","CCCC"]'
render rendered-verify '[]' true # opt-in flux_git_verify: Secret + spec.verify must be schema-valid too
render rendered-sink '[]' false s3.gra.example.invalid s3.par.example.invalid # audit sink (infra #318): two host names for the egress policy
grep -q '^  AUDIT_SINK_HOST: s3.gra.example.invalid$' "$tmp/rendered-sink.yaml" && grep -q '^  AUDIT_SINK_SECONDARY_HOST: s3.par.example.invalid$' "$tmp/rendered-sink.yaml" &&
  ! grep -q 'AUDIT_SINK' "$tmp/rendered-dev.yaml" ||
  { echo "✗ the audit sink hosts are not rendered exactly when they are set" >&2; exit 1; }
grep -q 'name: git-signers' "$tmp/rendered-verify.yaml" && ! grep -q 'git-signers' "$tmp/rendered-dev.yaml" ||
  { echo "✗ git-signers is not rendered exactly when flux_git_verify is on" >&2; exit 1; }
grep -q 'name: openbao-operator-keys' "$tmp/rendered-prod.yaml" && ! grep -q 'name: openbao-operator-keys' "$tmp/rendered-dev.yaml" ||
  { echo "✗ the recovery-share ConfigMap is not rendered exactly when keys are given" >&2; exit 1; }

flux schema extract crd "$VENDORED" -d "$tmp/schemas" >/dev/null

for f in rendered-dev rendered-prod rendered-verify rendered-sink; do
  flux schema validate "$tmp/$f.yaml" \
    --schema-location "$tmp/schemas" --schema-location default --verbose
done

echo "OK — flux-bootstrap.yaml.tftpl renders to schema-valid manifests (CRDs from the vendored flux-install.yaml)."
