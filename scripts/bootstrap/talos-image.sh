#!/usr/bin/env bash
# OpenAether — build + publish the Talos image for a provider (decoupled root).
#
# Built once per Talos version, reused by every cluster on that provider. Each version has its OWN
# state (key talos-image-<provider>-<version>.tfstate in the provider's lane bucket), so a build can
# only touch its own version and building X never replaces Y. It never touches deployed cluster infra.
#
# Credentials: AWS_* = the provider's S3 keys, plus its compute creds
# (scaleway SCW_*, ovh OS_*, outscale OSC_*, proxmox PROXMOX_VE_*) and
# TF_VAR_encryption_passphrase.
#
# Usage:
#   ./scripts/bootstrap/talos-image.sh <provider> [talos_version] [--ensure|--list|--prune|--retain|--import-snapshot <id>]
#   task image-build PROVIDER=ovh [VERSION=v1.13.4] [ENSURE=1|LIST=1|PRUNE=1|RETAIN=1]
#
# --ensure: idempotence gate for `task cluster-up`: plan first, apply only on a real change.
# --list: the versions this lane holds (one state each); builds nothing and creates no bucket.
# --prune: destroy ONE version's image set (the only way an image leaves the lane); refused while a tfvars names it.
# --retain: keep N (the newest tfvars pin) and the highest held below it; --prune the rest, lowest first, bar what a tfvars names. No version.
# --import-snapshot <id>: Outscale; adopt a snapshot a failed apply orphaned into this version's state (see the module).
# One mode per run, and one run at a time per checkout: runs share a .terraform data dir.
set -euo pipefail

MODE=build ENSURE=false SNAP="" NMODES=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ensure) ENSURE=true ;;
    --list)   MODE=list;  NMODES=$((NMODES + 1)) ;;
    --prune)  MODE=prune; NMODES=$((NMODES + 1)) ;;
    --retain) MODE=retain; NMODES=$((NMODES + 1)) ;;
    --import-snapshot) MODE=import; NMODES=$((NMODES + 1)); SNAP="${2:-}"
      case "$SNAP" in "" | -*) echo "✗ --import-snapshot needs a snapshot id" >&2; exit 1 ;; esac
      shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
# Exclusive on purpose: with the last flag winning, `--list --prune` would destroy.
[ "$NMODES" -le 1 ] || { echo "✗ --list, --prune, --retain and --import-snapshot are exclusive: one per run" >&2; exit 1; }
[ "$ENSURE" = false ] || [ "$MODE" = build ] || { echo "✗ --ensure only goes with a build" >&2; exit 1; }
# A version here would read as "retain around it": it ranks what the lane holds, whatever any pin says.
[ "$MODE" != retain ] || [ -z "${ARGS[1]:-}" ] || { echo "✗ --retain takes no version: it ranks the versions the lane holds" >&2; exit 1; }

INTERNAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../internal" && pwd)"  # absolute: the script cd's to the root below
RAW="${ARGS[0]:?usage: talos-image.sh <scaleway|ovh|outscale|proxmox> [talos_version] [--ensure|--list|--prune|--retain|--import-snapshot <id>]}"
P="$(printf '%s' "$RAW" | tr '[:upper:]' '[:lower:]')"
case "$P" in
  scw | scaleway) P=scaleway; TGT=scaleway; SREGION=fr-par;    SEP="https://s3.fr-par.scw.cloud" ;;
  ovh)            TGT=ovh;      SREGION=eu-west-par;        SEP="https://s3.eu-west-par.io.cloud.ovh.net" ;;
  outscale)       TGT=outscale; SREGION=eu-west-2; SEP="https://oos.eu-west-2.outscale.com" ;;
  proxmox)        TGT=proxmox;  SREGION="${PROXMOX_S3_REGION:-fr-par}"; SEP="${PROXMOX_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}" ;;
  *) echo "✗ unknown provider: $RAW (expected scaleway|ovh|outscale|proxmox)"; exit 1 ;;
esac
[ "$MODE" != import ] || [ "$TGT" = outscale ] || { echo "✗ --import-snapshot is Outscale only" >&2; exit 1; }
# A bare call builds the pin of the cluster tfvars, never a literal kept here.
VERSION="${ARGS[1]:-$("$INTERNAL/talos-version.sh" "${OA_ROLE:-management}-${P}.tfvars")}"

# A prune is how an image leaves the lane (--retain runs one per version), so what the clusters still name is read first:
# one that names the version could neither plan nor be DESTROYED once it is gone (#69).
# OA_ENVS_DIR: a test harness points this at a sandbox, never at the real envs/ (#191).
# Absolute, and exported for talos-version.sh: this script cd's to the image root below.
ENVS_DIR="$(cd "${OA_ENVS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/cluster/envs}" 2>/dev/null && pwd)" || ENVS_DIR=""
[ -z "$ENVS_DIR" ] || export OA_ENVS_DIR="$ENVS_DIR"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"  # absolute: --retain re-runs it after the cd below
# Every image an envs/*-<provider>.tfvars names, "<version> <file> <how>" per line: its talos_version (the variables.tf
# default when it pins none), and an image_name / talos_image_file_id override naming a lane image. Fails, saying why,
# when that cannot be known (no envs dir, an unreadable file, an image_id: an id names no version): a destroy never
# decides on missing evidence.
pin_refs() {
  local f b v body
  [ -n "$ENVS_DIR" ] || { echo "✗ no envs directory to read the pins from: what a cluster still needs is unknown." >&2; return 1; }
  for f in "$ENVS_DIR"/*-"$P".tfvars; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [ -r "$f" ] || { echo "✗ cannot read ${b}: what it pins is unknown." >&2; return 1; }
    v="$("$INTERNAL/talos-version.sh" "$b")" || { echo "✗ cannot read the pin of ${b}." >&2; return 1; }
    echo "$v $b talos_version"
    body="$(sed 's/#.*$//' "$f")"
    if grep -qE '(^|[^[:alnum:]_])image_id[[:space:]]*=[[:space:]]*"[^"]' <<<"$body"; then  # not bastion_image_id
      echo "✗ ${b} sets image_id: an id names no version, so what that cluster still needs is unknown." >&2
      echo "  Drop it (the name resolves the image from talos_version), then run this again." >&2
      return 1
    fi
    while read -r v; do
      [ -z "$v" ] || echo "$v $b override"
    done < <(grep -oE "image_name[[:space:]]*=[[:space:]]*\"talos-${P}-amd64-[^\"]+\"" <<<"$body" | sed -E 's/.*-amd64-([^"]+)"$/\1/'
             grep -oE 'talos_image_file_id[[:space:]]*=[[:space:]]*"[^"]*/talos-[^"]+-nocloud-amd64\.img"' <<<"$body" | sed -E 's/.*\/talos-(.+)-nocloud-amd64\.img"$/v\1/')
  done
  return 0
}
pinned_by() { awk -v v="$1" '$1 == v {print $2}' <<<"$PIN_REFS" | sort -u; }  # <version>: the env files naming it, one per line
PIN_REFS=""
if [ "$MODE" = prune ] || [ "$MODE" = retain ]; then
  PIN_REFS="$(pin_refs)" || exit 1
  [ "$MODE" != prune ] || [ -n "$PIN_REFS" ] || echo "  ~ no envs/*-${P}.tfvars here: no cluster was asked whether it still needs ${VERSION}." >&2
fi
if [ "$MODE" = prune ]; then
  pinned="$(pinned_by "$VERSION")"
  if [ -n "$pinned" ]; then
    while read -r f; do
      echo "✗ ${f} still names ${VERSION} (its talos_version, or an image_name / talos_image_file_id override): pruning" >&2
      echo "  its image would leave that cluster unable to plan, or to be destroyed. Move that first, then prune." >&2
    done <<<"$pinned"
    exit 1
  fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/talos-image" && pwd)"
command -v tofu >/dev/null 2>&1 || { echo "✗ tofu required"; exit 1; }
command -v aws  >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "✗ jq required (the plan gate and the legacy-state check read JSON)"; exit 1; }
LEGACY_JSON="" PLAN=""
trap 'rm -f ${LEGACY_JSON:+"$LEGACY_JSON"} ${PLAN:+"$ROOT/$PLAN"}' EXIT

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
if [ "$MODE" = build ] && [ -f "$SCHEMATIC_YAML" ] && [ -f "$CLUSTER_VARS" ]; then
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

bucket_present() { # <bucket>: 0 present, 1 absent (a 404); any other failure is unknown, never guessed
  local err
  err="$(aws s3api head-bucket --bucket "$1" --endpoint-url "$SEP" --region "$SREGION" 2>&1)" && return 0
  case "$err" in *404* | *NoSuchBucket* | *"Not Found"*) return 1 ;; esac
  echo "✗ cannot reach s3://$1 on ${TGT}: ${err##*: }" >&2; exit 1
}

case "$MODE" in
  list | prune | retain) # reads the lane: S3 names are global, so these never create a bucket
    if ! bucket_present "$STATE_BUCKET"; then
      [ "$MODE" = list ] && { echo "▶ no state bucket ${STATE_BUCKET} on ${TGT}: nothing held"; exit 0; }
      [ "$MODE" = retain ] && { echo "▶ no state bucket ${STATE_BUCKET} on ${TGT}: nothing held, nothing to retain"; exit 0; }
      echo "✗ nothing to prune: no state bucket ${STATE_BUCKET} on ${TGT}." >&2; exit 1
    fi ;;
  *)
    echo "▶ Ensuring talos-image state bucket on ${TGT} (${STATE_BUCKET})"
    ensure "$STATE_BUCKET" ;;
esac

# One state per version. The pre-#69 lane kept every provider's image in ONE state; that object
# stays the authority for the version it holds until a build of that version copies it (below).
NEW_KEY="talos-image-${TGT}-${VERSION}.tfstate"
LEGACY_KEY="talos-image.tfstate"
# A listing that FAILS is not an empty one: guessing "no states" would build a second copy.
KEYS="$(aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix talos-image --query 'Contents[].Key' \
          --output text --endpoint-url "$SEP" --region "$SREGION")" \
  || { echo "✗ cannot list s3://${STATE_BUCKET}: which versions the lane holds is unknown." >&2; exit 1; }
KEYS="$(tr '\t' '\n' <<<"$KEYS" | grep -v '^None$' || true)"
held_by_key() { sed -nE "s/^talos-image-${TGT}-(v.+)\.tfstate$/\1/p" <<<"$KEYS"; }  # the one reading --list and --retain share
if [ "$MODE" = list ]; then
  echo "▶ Versions held on ${TGT} (one state each):"
  held_by_key | sed 's/^/    /'
  grep -qx "$LEGACY_KEY" <<<"$KEYS" && echo "    (${LEGACY_KEY}: the pre-#69 state, copied to its own key by the next build of the version it holds)"
  exit 0
fi

APPLY_VARS=(-var "target_provider=$TGT" -var "talos_version=$VERSION")
case "$P" in
  scaleway | outscale)
    # Scaleway/Outscale upload the raw image to Object Storage, then import it
    # as a snapshot. "import", not "staging": this repository spends that word
    # on environments (dev/prod) and reading it as one here is what it cost.
    IMPORT_BUCKET="s3-${IMG_PROJECT}-${TGT}-talos-import"
    [ "$MODE" != build ] || ensure "$IMPORT_BUCKET"  # only a build uploads to it
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

# Outscale answers 409 (9015) to CreateImage when an OMI holds the name, but only AFTER the 8-14 min build
# (download, upload, snapshot import), so ask before: refuse in seconds. The provider's own lookup cannot ask: on a
# real account `data.outscale_images` fails the whole plan when nothing matches. Deleting an OMI this lane does not
# track is the OWNER's call, never ours.
refuse_taken_omi() {
  [ "$TGT" = outscale ] || return 0
  local name taken
  name="$(tofu show -json "$PLAN" | jq -r '
    [.resource_changes[]? | select(.type == "outscale_image" and (.change.actions | index("create")))] as $c
    | if ($c | length) == 0 then empty
      else ($c[0].change.after.image_name // error("the plan does not name the OMI it creates")) end')" \
    || { echo "✗ cannot read the OMI name from the plan; nothing was applied." >&2; exit 1; }
  [ -z "$name" ] && return 0
  taken="$("${OA_OMI_LOOKUP:-$INTERNAL/outscale-omi-ids.py}" "$name" "$SREGION" | paste -sd' ')" \
    || { echo "✗ cannot list the OMIs of this account; nothing was applied (a refused question is not an empty answer)." >&2; exit 1; }
  [ -z "$taken" ] && return 0
  echo "✗ this plan creates the OMI for ${VERSION}, but the account already holds one under that name: ${taken}" >&2
  echo "  CreateImage would fail with 409 after the snapshot import. Nothing was imported or spent." >&2
  echo "  An OMI this state does not track is the owner's to delete (with its snapshot); to replace the" >&2
  echo "  lane's own, --prune this version first (a pin on it must move first). Or build another version." >&2
  exit 1
}

init_state() { # <key>
  tofu init -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$1" \
    -backend-config="region=$SREGION" \
    -backend-config="endpoint=$SEP"
}

read_legacy() { # sets LEGACY_JSON, LEGACY_VERS (the versions its objects name) and LEGACY_BAD (deposed or tainted ones)
  init_state "$LEGACY_KEY"
  LEGACY_JSON="$(mktemp)"
  tofu state pull >"$LEGACY_JSON" \
    || { echo "✗ cannot read ${LEGACY_KEY}; nothing was changed." >&2; exit 1; }
  HELD="$("$INTERNAL/image-state-version.sh" <"$LEGACY_JSON")" || exit 1
  LEGACY_VERS="$(sed -n 1p <<<"$HELD")" LEGACY_BAD="$(sed -n 2p <<<"$HELD")"
}

# a < b over vMAJOR.MINOR.PATCH[-pre]: a pre-release is below its own release; two of them order as version strings.
SEMVER_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
ver_lt() {
  local ca="${1%%-*}" cb="${2%%-*}" pa pb
  pa="${1#"$ca"}" pb="${2#"$cb"}"
  [ "$ca" = "$cb" ] || { oa_semver_lt "$ca" "$cb"; return; }
  [ "$pa" != "$pb" ] || return 1
  [ -n "$pb" ] || return 0
  [ -n "$pa" ] || return 1
  [ "$(printf '%s\n%s\n' "$pa" "$pb" | sort -V | sed -n 1p)" = "$pa" ]
}

# --retain: relative to the cluster, not to what the lane happens to hold. N is the newest talos_version a tfvars pins;
# keep the RETAIN_KEEP highest versions held at or below N (N and the one before it, so a node can still be made on
# N-1) and --prune each other one, lowest first, through this script's own --prune. Kept and named, never destroyed:
# a version a tfvars names, one above N (built ahead, or a bump reverted), and a key that is no version at all.
RETAIN_KEEP=2
retain_lane() {
  local v i n start pins top="" held=() ranked=() ahead=() odd=() drop=() pinned=() destroyed=() rest=()
  [ -n "$PIN_REFS" ] || { echo "✗ no envs/*-${P}.tfvars: nothing says which version a cluster is on, so nothing is retained." >&2; exit 1; }
  while read -r v _ how; do  # N: the newest version a cluster is ON (an override below it is a node on an older image)
    [ "$how" = talos_version ] && [[ "$v" =~ $SEMVER_RE ]] || continue
    if [ -z "$top" ] || ver_lt "$top" "$v"; then top="$v"; fi
  done <<<"$PIN_REFS"
  [ -n "$top" ] || { echo "✗ no talos_version pin is a vMAJOR.MINOR.PATCH version: there is no N to retain around." >&2; exit 1; }
  LEGACY_VERS=""
  if grep -qx "$LEGACY_KEY" <<<"$KEYS"; then read_legacy; fi
  while read -r v; do  # the keys and the legacy state name the same version once, never twice
    [ -z "$v" ] || [[ " ${held[*]} " == *" $v "* ]] || held+=("$v")
  done < <(held_by_key; tr ' ' '\n' <<<"$LEGACY_VERS")
  for v in "${held[@]}"; do
    if ! [[ "$v" =~ $SEMVER_RE ]]; then
      odd+=("$v")
    elif ver_lt "$top" "$v"; then
      ahead+=("$v")
    else  # insertion sort, ascending (never lexicographic: v1.9.0 is below v1.14.0)
      i=${#ranked[@]}
      while [ "$i" -gt 0 ] && ver_lt "$v" "${ranked[i-1]}"; do ranked[i]="${ranked[i-1]}"; i=$((i - 1)); done
      ranked[i]="$v"
    fi
  done
  for ((i = 0; i < ${#ranked[@]} - RETAIN_KEEP; i++)); do
    pins="$(pinned_by "${ranked[i]}" | paste -sd' ')"
    if [ -n "$pins" ]; then pinned+=("${ranked[i]} (${pins})"); else drop+=("${ranked[i]}"); fi
  done
  n=${#ranked[@]}; start=$((n > RETAIN_KEEP ? n - RETAIN_KEEP : 0))
  echo "▶ ${TGT} holds ${held[*]:-no version}; the newest pin is ${top}; keeping the ${RETAIN_KEEP} highest at or below it: ${ranked[*]:start}"
  [ "${#ahead[@]}" -eq 0 ] || echo "  kept, above every pin (built ahead, or a bump reverted): ${ahead[*]}"
  [ "${#pinned[@]}" -eq 0 ] || echo "  kept, named by a tfvars: ${pinned[*]}"
  [ "${#odd[@]}" -eq 0 ] || echo "  kept, not a version so not ranked: ${odd[*]}"
  if [ "${#drop[@]}" -eq 0 ]; then echo "✓ nothing to destroy"; exit 0; fi
  echo "  will destroy, lowest first: ${drop[*]}"
  for i in "${!drop[@]}"; do
    echo "▶ --prune ${drop[i]}"
    "$SELF" "$P" "${drop[i]}" --prune || {
      rest=("${drop[@]:i+1}")
      echo "✗ pruning ${drop[i]} failed. Destroyed before it: ${destroyed[*]:-none}. Not attempted: ${rest[*]:-none}." >&2
      echo "  Fix the cause and run --retain again (it ranks what is held then)." >&2
      exit 1
    }
    destroyed+=("${drop[i]}")
  done
  echo "✓ destroyed: ${destroyed[*]}"
  exit 0
}

cd "$ROOT"
[ "$MODE" != retain ] || retain_lane
# Legacy state: read first, moved only by a build of the version it holds (copied, then retired). A
# build of another version leaves it alone, whatever state it is in; one it cannot read blocks all.
MIGRATE=false
if grep -qx "$LEGACY_KEY" <<<"$KEYS" && ! grep -qx "$NEW_KEY" <<<"$KEYS"; then
  read_legacy
  if [[ " $LEGACY_VERS " == *" $VERSION "* ]]; then
    if [ "$LEGACY_VERS" != "$VERSION" ] || [ -n "$LEGACY_BAD" ]; then
      echo "✗ ${LEGACY_KEY} holds ${VERSION} but is not clean (versions: ${LEGACY_VERS// /, }; deposed or tainted: ${LEGACY_BAD:-none})." >&2
      echo "  Copying it would carry the half-finished object. Nothing was moved; another version's build is not blocked." >&2
      echo "  Clear it first: the owner deletes the cloud objects it names, then \`tofu state rm\` them from ${LEGACY_KEY} (talos-image README, 'The pre-#69 single state')." >&2
      exit 1
    fi
    MIGRATE=true
  elif [ -n "$LEGACY_VERS" ]; then
    echo "  ~ ${LEGACY_KEY} holds ${LEGACY_VERS// /, } and stays its authority until a build of one of them copies it."
  fi
fi
if [ "$MODE" = prune ] && [ "$MIGRATE" = false ] && ! grep -qx "$NEW_KEY" <<<"$KEYS"; then
  echo "✗ nothing to prune: no state holds ${VERSION} on ${TGT} (--list shows what does)." >&2
  exit 1
fi
init_state "$NEW_KEY"
if [ "$MIGRATE" = true ]; then
  echo "▶ Copying ${LEGACY_KEY} (${VERSION}) to ${NEW_KEY}"
  tofu state push "$LEGACY_JSON"
  # A push into an empty key re-mints lineage and serial (measured: OpenTofu 1.12.6, encrypted S3), so compare what the state holds.
  [ "$(tofu state pull | jq -S '[.resources, .outputs]')" = "$(jq -S '[.resources, .outputs]' "$LEGACY_JSON")" ] \
    || { echo "✗ ${NEW_KEY} does not hold the state just pushed; ${LEGACY_KEY} is untouched." >&2; exit 1; }
  # Retired, not deleted, and not left in place: a legacy object still named so would be copied
  # back as a ghost the day this version is pruned and built again.
  aws s3 mv "s3://${STATE_BUCKET}/${LEGACY_KEY}" "s3://${STATE_BUCKET}/${LEGACY_KEY}.migrated-to-${VERSION}" \
      --endpoint-url "$SEP" --region "$SREGION" >/dev/null \
    || echo "⚠ copied, but could not retire ${LEGACY_KEY}: rename it by hand to ${LEGACY_KEY}.migrated-to-${VERSION}." >&2
fi

case "$MODE" in
  prune)
    tofu destroy "${APPLY_VARS[@]}"
    # An emptied state object would be listed as a held version; one not confirmed empty is kept AND is a failure.
    if LEFT="$(tofu state list -no-color 2>&1)" && [ -z "$LEFT" ]; then
      aws s3 rm "s3://${STATE_BUCKET}/${NEW_KEY}" --endpoint-url "$SEP" --region "$SREGION" >/dev/null
      exit 0
    fi
    echo "✗ ${VERSION}: its state still lists objects, or could not be listed. It is kept, and --list still shows it." >&2
    exit 1 ;;
  import)
    # Adopted without the build in this state, the next plan creates the build and REPLACES the snapshot.
    BUILD='module.outscale[0].terraform_data.build_and_upload'
    ADDRS="$(tofu state list 2>&1 || true)"
    if ! grep -qxF "$BUILD" <<<"$ADDRS"; then
      echo "✗ ${NEW_KEY} does not hold ${BUILD}: an adopted snapshot would be replaced by the next plan (a second import)." >&2
      echo "  The way out is the account owner deleting the orphan snapshot, then a normal build." >&2
      exit 1
    fi
    tofu import "${APPLY_VARS[@]}" 'module.outscale[0].outscale_snapshot.talos' "$SNAP"
    exit 0 ;;
esac

if [ "$ENSURE" = true ]; then
  echo "▶ --ensure: checking whether the image needs (re)building..."
  # Plan ONCE, to a file, and apply THAT file. -auto-approve discarded the plan
  # that decided "rebuild" and applied a second, unseen one — on buckets, a
  # snapshot import and an image publish. A saved plan never prompts either, so
  # the gate stays unattended, and tofu refuses it if the state moved since.
  PLAN="talos-image-${TGT}.tfplan"
  PLAN_EXIT=0
  tofu plan -detailed-exitcode -out="$PLAN" "${APPLY_VARS[@]}" || PLAN_EXIT=$?
  case "$PLAN_EXIT" in
    0) echo "✓ image already up to date — skipping apply" ;;
    2) refuse_taken_omi; tofu apply "$PLAN" ;;
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
    # Only a cluster that pins THIS version: another version's image has another id, on purpose.
    [ "$("$INTERNAL/talos-version.sh" "$(basename "$f")" 2>/dev/null || true)" = "$VERSION" ] || continue
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
