#!/usr/bin/env bash
# OpenAether — build + publish the Talos image for a provider (decoupled root).
#
# Built once per Talos version, reused by every cluster on that provider. Its
# own state (one bucket per provider) means building never touches deployed
# cluster infra.
#
# Credentials: AWS_* = the provider's S3 keys, plus its compute creds
# (scaleway SCW_*, ovh OS_*, outscale OSC_*, proxmox PROXMOX_VE_*) and
# TF_VAR_encryption_passphrase.
#
# Usage:
#   ./scripts/bootstrap/talos-image.sh <provider> [talos_version] [--ensure]
#   task image-build PROVIDER=ovh [VERSION=v1.13.4]
#
# --ensure: idempotence gate for `task cluster-up` — plans first and only applies on a
#   real change, so a rerun with the image already published costs nothing.
set -euo pipefail

ENSURE=false
ARGS=()
for a in "$@"; do
  case "$a" in
    --ensure) ENSURE=true ;;
    *) ARGS+=("$a") ;;
  esac
done

RAW="${ARGS[0]:?usage: talos-image.sh <scaleway|ovh|outscale|proxmox> [talos_version] [--ensure]}"
VERSION="${ARGS[1]:-v1.13.4}"
P="$(printf '%s' "$RAW" | tr '[:upper:]' '[:lower:]')"
case "$P" in
  scw | scaleway) P=scaleway; TGT=scaleway; SREGION=fr-par;    SEP="https://s3.fr-par.scw.cloud" ;;
  ovh)            TGT=ovh;      SREGION=eu-west-par;        SEP="https://s3.eu-west-par.io.cloud.ovh.net" ;;
  outscale)       TGT=outscale; SREGION=eu-west-2; SEP="https://oos.eu-west-2.outscale.com" ;;
  proxmox)        TGT=proxmox;  SREGION="${PROXMOX_S3_REGION:-fr-par}"; SEP="${PROXMOX_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}" ;;
  *) echo "✗ unknown provider: $RAW (expected scaleway|ovh|outscale|proxmox)"; exit 1 ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# talos-image's root tracks exactly one image PER PROVIDER (backend.tf:
# key=talos-image.tfstate, not per-version) — retargeting talos_version does not
# add a second image, it REPLACES the sole one tracked, destroying whatever
# version another cluster's tfvars still pins. Nothing breaks that cluster until
# its NEXT plan (Talos boots from local disk, it does not re-fetch the image at
# runtime) — and by then the account has no visible sign of what happened (#93).
# Refuse before the spend: same resolution path as everywhere else that reads a
# cluster's pin (scripts/internal/talos-version.sh), scanned across every real
# tfvars for THIS provider before a single credential is resolved.
# ──────────────────────────────────────────────────────────────────────────────
# OA_ENVS_DIR: a test harness points this at a sandbox, never at the real envs/ (#191).
ENVS_DIR="${OA_ENVS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/cluster/envs}"
INTERNAL="$(dirname "${BASH_SOURCE[0]}")/../internal"
if [ -d "$ENVS_DIR" ]; then
  conflict=0
  for f in "$ENVS_DIR"/*-"$P".tfvars; do
    [ -e "$f" ] || continue
    PINNED="$("$INTERNAL/talos-version.sh" "$(basename "$f")" 2>/dev/null || true)"
    [ -n "$PINNED" ] && [ "$PINNED" != "$VERSION" ] || continue
    echo "✗ $(basename "$f") pins talos_version = ${PINNED}, but this build targets ${VERSION}." >&2
    echo "  talos-image tracks ONE image per provider — building ${VERSION} would replace" >&2
    echo "  the ${PINNED} image that cluster still pins, and it would not notice until its" >&2
    echo "  next plan/apply. Build ${PINNED} instead, or update $(basename "$f") first." >&2
    conflict=1
  done
  [ "$conflict" -eq 0 ] || exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/talos-image" && pwd)"
command -v tofu >/dev/null 2>&1 || { echo "✗ tofu required"; exit 1; }
command -v aws  >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
oa_aws_compat

# Resolve the target provider's S3 creds into AWS_* (aws CLI + tofu S3 backend),
# via lib/common.sh::s3_cred — namespaced per provider, no ambient AWS_* fallback.
PU="$(provider_pu "$TGT")"
AWS_ACCESS_KEY_ID="$(s3_cred "$TGT" primary ak)"
AWS_SECRET_ACCESS_KEY="$(s3_cred "$TGT" primary sk)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] || {
  echo "✗ no S3 creds for '${TGT}': set ${PU}_AWS_ACCESS_KEY_ID + ${PU}_AWS_SECRET_ACCESS_KEY"
  [ "$TGT" = ovh ] && echo "  (OVH S3 needs SEPARATE keys: 'openstack ec2 credentials create' — not OS_PASSWORD)"
  exit 1
}
echo "  S3 creds: ${PU}_AWS_* (${AWS_ACCESS_KEY_ID:0:6}…)"

# Outscale's API (CreateSnapshot/CreateImage) uses the same AK/SK as OOS — feed
# them to the provider explicitly (TF_VAR_*) so it doesn't depend on OSC_* names.
if [ "$P" = outscale ]; then
  export TF_VAR_outscale_access_key_id="$AWS_ACCESS_KEY_ID"
  export TF_VAR_outscale_secret_key_id="$AWS_SECRET_ACCESS_KEY"
fi

# Proxmox downloads server-side onto the host's datastore (no local convert
# step), so it needs the bpg provider's own creds — fail fast if missing
# rather than let `tofu apply` surface an opaque auth error.
if [ "$P" = proxmox ]; then
  [ -n "${PROXMOX_VE_ENDPOINT:-}" ] && [ -n "${PROXMOX_VE_API_TOKEN:-}" ] || {
    echo "✗ Proxmox creds missing: export PROXMOX_VE_ENDPOINT + PROXMOX_VE_API_TOKEN"
    echo "  (PROXMOX_VE_INSECURE=true for a self-signed 8006 cert)"
    exit 1
  }
fi

# ──────────────────────────────────────────────────────────────────────────────
# The schematic decides the image's system extensions AND, since 2026-08-15, the
# installer the machine config names — so a node keeps iscsi-tools across a
# `talosctl upgrade` instead of coming back without it and taking Longhorn with
# it. Two files have to agree on the id, and this is the only place that already
# computes it, so this is where the drift is caught. A build is also the only
# moment the answer can change.
# ──────────────────────────────────────────────────────────────────────────────
SCHEMATIC_YAML="$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/talos-image/schematic.yaml"
CLUSTER_VARS="$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/cluster/variables.tf"
if [ -f "$SCHEMATIC_YAML" ] && [ -f "$CLUSTER_VARS" ]; then
  LIVE_ID="$(curl -sf -X POST -H 'Content-Type: application/yaml' \
    --data-binary @"$SCHEMATIC_YAML" https://factory.talos.dev/schematics \
    | sed -nE 's/.*"id":"([0-9a-f]+)".*/\1/p')"
  PINNED_ID="$(awk '/variable "talos_installer_schematic_id"/,/^}/' "$CLUSTER_VARS" \
    | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([0-9a-f]+)".*/\1/p' | head -1)"
  if [ -n "$LIVE_ID" ] && [ -n "$PINNED_ID" ] && [ "$LIVE_ID" != "$PINNED_ID" ]; then
    echo "✗ schematic.yaml now resolves to ${LIVE_ID}" >&2
    echo "  but cluster/variables.tf pins talos_installer_schematic_id = ${PINNED_ID}." >&2
    echo "  Nodes would install from the OLD schematic and lose the new extensions." >&2
    echo "  Update the default in cluster/variables.tf, then re-run." >&2
    exit 1
  fi
  # An empty LIVE_ID skipped BOTH branches above — no refusal, and no line of
  # reassurance either: the check evaporated and the build went on to "image
  # already up to date", in silence, on the path to a billable publish. Note
  # what empty means here: a curl that FAILS aborts under `set -e`, so this is
  # the narrower case where the Factory answers something carrying no id — a
  # rate limit, an error body, a redirect. Abstaining is allowed; saying
  # nothing is not.
  if [ -n "$LIVE_ID" ]; then
    echo "  ✓ schematic ${LIVE_ID:0:12}… matches the cluster pin"
  elif [ "${TALOS_IMAGE_ALLOW_OFFLINE:-0}" = 1 ]; then
    echo "  ⚠ schematic NOT checked — factory.talos.dev unreachable, and" >&2
    echo "    TALOS_IMAGE_ALLOW_OFFLINE=1 says to build anyway. Nodes may install" >&2
    echo "    from a schematic this tree no longer describes." >&2
  else
    echo "✗ factory.talos.dev returned no schematic id — the pin could not be" >&2
    echo "  verified, and a build is the only moment it can be. Re-run, or set" >&2
    echo "  TALOS_IMAGE_ALLOW_OFFLINE=1 to build against an unverified pin." >&2
    exit 1
  fi
fi

# The image buckets follow the same namespace as every other bucket, read from
# the cluster tfvars for this provider. They used to be the literal string
# "openaether", overridable by nothing — and since S3 names are unique across a
# whole provider (not per account), that made `task cluster-up`'s FIRST billable step
# unrepeatable by anyone else. See oa_project in scripts/lib/common.sh.
IMG_TFVARS="${OA_TFVARS:-$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/cluster/envs/${OA_ROLE:-management}-${TGT}.tfvars}"
if [ -f "$IMG_TFVARS" ]; then
  IMG_PROJECT="$(oa_project "$(tfv "$IMG_TFVARS" cluster_name)" "$(tfv "$IMG_TFVARS" bucket_suffix)")"
else
  IMG_PROJECT=openaether
  echo "  ~ no ${IMG_TFVARS##*/}: falling back to the 'openaether' bucket namespace."
  echo "    Create the tfvars first if these names are not yours — S3 names are"
  echo "    unique across the whole provider, not per account."
fi
STATE_BUCKET="s3-${IMG_PROJECT}-${TGT}-talos-image"

ensure() { # bucket
  aws s3api head-bucket --bucket "$1" --endpoint-url "$SEP" --region "$SREGION" >/dev/null 2>&1 && {
    echo "  ✓ bucket $1"; return 0; }
  if aws s3 mb "s3://$1" --endpoint-url "$SEP" --region "$SREGION" >/dev/null 2>&1; then
    echo "  ✓ bucket $1 (created)"; return 0
  fi
  # The message that turns an hour of confusion into a one-line fix. A
  # head-bucket on someone else's bucket answers 403, so the probe above fails
  # and the failure lands here rather than where the cause is.
  echo "✗ could not create s3://$1 on ${TGT}." >&2
  echo "  The most likely cause is that the NAME IS ALREADY TAKEN — by another" >&2
  echo "  customer, not by you. S3 bucket names are unique across the whole" >&2
  echo "  provider (Scaleway and OVH platform-wide, Outscale per region)." >&2
  echo "  Fix: set a discriminator in ${IMG_TFVARS##*/} —" >&2
  echo "      bucket_suffix = \"$(openssl rand -hex 3 2>/dev/null || echo 'a1b2c3')\"   # or 'task bucket-suffix'" >&2
  echo "  then re-run. Other causes: wrong region, or no S3 quota left." >&2
  exit 1
}

echo "▶ Ensuring talos-image state bucket on ${TGT} (${STATE_BUCKET})"
ensure "$STATE_BUCKET"

APPLY_VARS=(-var "target_provider=$TGT" -var "talos_version=$VERSION")
case "$P" in
  scaleway | outscale)
    # Scaleway/Outscale upload the raw image to Object Storage, then import it
    # as a snapshot. "import", not "staging": this repository spends that word
    # on environments (dev/prod) and reading it as one here is what it cost.
    IMPORT_BUCKET="s3-${IMG_PROJECT}-${TGT}-talos-import"
    ensure "$IMPORT_BUCKET"
    APPLY_VARS+=(-var "import_bucket=$IMPORT_BUCKET" -var "region=$SREGION" -var "s3_endpoint=$SEP")
    ;;
  proxmox)
    # No import bucket — the download lands straight on the host's datastore.
    # PROXMOX_NODE_NAMES is comma-separated (e.g. "pve1,pve2,pve3"); match
    # node_distribution.proxmox.node_names in the cluster envs/*.tfvars.
    IFS=',' read -ra PMX_NODES <<<"${PROXMOX_NODE_NAMES:-pve1}"
    PMX_NODES_HCL="[$(printf '"%s",' "${PMX_NODES[@]}" | sed 's/,$//')]"
    APPLY_VARS+=(
      -var "proxmox_node_names=${PMX_NODES_HCL}"
      -var "proxmox_iso_datastore_id=${PROXMOX_ISO_DATASTORE_ID:-local}"
    )
    ;;
esac

cd "$ROOT"
tofu init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=talos-image.tfstate" \
  -backend-config="region=$SREGION" \
  -backend-config="endpoint=$SEP"

if [ "$ENSURE" = true ]; then
  echo "▶ --ensure: checking whether the image needs (re)building..."
  # Plan ONCE, to a file, and apply THAT file. -auto-approve discarded the plan
  # that decided "rebuild" and applied a second, unseen one — on buckets, a
  # snapshot import and an image publish. A saved plan never prompts either, so
  # the gate stays unattended, and tofu refuses it if the state moved since.
  PLAN="talos-image-${TGT}.tfplan"
  trap 'rm -f "$ROOT/$PLAN"' EXIT
  PLAN_EXIT=0
  tofu plan -detailed-exitcode -out="$PLAN" "${APPLY_VARS[@]}" || PLAN_EXIT=$?
  case "$PLAN_EXIT" in
    0) echo "✓ image already up to date — skipping apply" ;;
    2) tofu apply "$PLAN" ;;
    *)
      echo "✗ tofu plan failed (exit ${PLAN_EXIT})"
      exit 1
      ;;
  esac
else
  # Interactive on purpose: tofu shows and applies the SAME in-memory plan, so
  # the yes a human types answers the plan they just read. Nothing to freeze.
  tofu apply "${APPLY_VARS[@]}"
fi

echo
echo "→ image_name: $(tofu output -raw image_name 2>/dev/null || echo '?')"
tofu output image_id 2>/dev/null || true
[ "$P" = proxmox ] && tofu output image_file_id 2>/dev/null
echo "  (All three clouds look the image up by name — leave image_id unset in the"
echo "   cluster envs/*.tfvars and a version bump needs no edit. Proxmox:"
echo "   talos_image_file_id follows the same convention.)"

# ──────────────────────────────────────────────────────────────────────────────
# A pinned image_id is OPTIONAL on OVH and Outscale (null looks the name up, the
# same way Scaleway does) and it is a trap: nothing compared the pin to the image
# this lane publishes, so a rebuild left a stale id behind and `task cluster-up` — which
# runs this script first, learns the right id, prints it, then deploys with the
# wrong one — failed at server creation with "Can not find requested image",
# after the network and the bastion had been created. Refuse before the spend.
#
# The remedy printed first is DELETING the pin, not updating it: updating keeps
# the hand-copy step, which is what makes an unattended upgrade impossible on
# these two providers (measured 2026-08-15 — the guard fired mid-run on OVH).
# ──────────────────────────────────────────────────────────────────────────────
if [ "$P" = ovh ] || [ "$P" = outscale ]; then
  WANT="$(tofu output -raw image_id 2>/dev/null || true)"
  ENVS="$(cd "${OA_ENVS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/cluster/envs}" && pwd)"
  stale=0
  for f in "$ENVS"/*-"$P".tfvars; do
    [ -e "$f" ] || continue
    # Anchored, because `grep -o 'image_id...'` strips the `bastion_` prefix
    # before the filter downstream can see it: with no Talos pin left in the
    # file, the bastion's own image was read as the pin and this guard refused
    # the very configuration it recommends (measured on OVH, 2026-08-15).
    # `|| true` is load-bearing: under `set -e` + `pipefail`, a grep that
    # matches nothing fails the whole substitution and kills the script HERE,
    # before the emptiness test below can decide there is no pin to compare.
    # It exits 1 having printed nothing at all.
    HAVE="$(grep -E '^[[:space:]]*image_id[[:space:]]*=' "$f" \
            | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    [ -n "$WANT" ] && [ -n "$HAVE" ] && [ "$WANT" != "$HAVE" ] || continue
    echo "✗ $(basename "$f") pins image_id = $HAVE" >&2
    echo "  but the image this lane just resolved is $WANT." >&2
    echo "  Deploying would fail at server creation, after the bill." >&2
    echo "  Preferred: drop the pin so the name resolves it, here and on every bump:" >&2
    echo "    sed -i '/^[[:space:]]*image_id[[:space:]]*=/d' $f" >&2
    echo "  Or, to keep pinning this exact image:" >&2
    echo "    sed -i 's|$HAVE|$WANT|' $f" >&2
    stale=1
  done
  [ "$stale" -eq 0 ] || exit 1
fi
