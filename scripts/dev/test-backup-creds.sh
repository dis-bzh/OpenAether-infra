#!/usr/bin/env bash
# ==============================================================================
# The backup store is only a backup if it is somewhere else. This measures the
# credential resolution that decides WHERE the copy actually lands.
#
# The trap it exists for: s3_cred falls back to the PRIMARY keys when no backup
# ones are set. That fallback is right for a single-provider cluster and quietly
# wrong for a cross-provider one — the copy then authenticates as provider A
# against provider B, and the only trace used to be one ⚠ in a wall of output.
#
# The variables are namespaced by the cloud that HOLDS THE BUCKET. They used to
# be namespaced by the CLUSTER — a Scaleway cluster backing up to Outscale had
# to put Outscale keys in SCW_BACKUP_AWS_*. The name argued for the wrong value
# and on 2026-08-19 it got one: Scaleway keys, rejected by Outscale, after a
# full plan. The endpoint now decides, and that is asserted here so it cannot
# drift back. The cluster-namespaced form still works as a fallback.
#
# Offline. No cloud, no account, no bill.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/lib/common.sh

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { # <label> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"
}

clear_env() {
  unset SCW_AWS_ACCESS_KEY_ID SCW_AWS_SECRET_ACCESS_KEY SCW_ACCESS_KEY SCW_SECRET_KEY \
        SCW_BACKUP_AWS_ACCESS_KEY_ID SCW_BACKUP_AWS_SECRET_ACCESS_KEY \
        OVH_AWS_ACCESS_KEY_ID OVH_BACKUP_AWS_ACCESS_KEY_ID \
        OUTSCALE_AWS_ACCESS_KEY_ID OUTSCALE_AWS_SECRET_ACCESS_KEY \
        OUTSCALE_BACKUP_AWS_ACCESS_KEY_ID OUTSCALE_BACKUP_AWS_SECRET_ACCESS_KEY \
        OSC_ACCESS_KEY OSC_SECRET_KEY \
        BACKUP_AWS_ACCESS_KEY_ID BACKUP_AWS_SECRET_ACCESS_KEY 2>/dev/null || true
}

echo "--- the namespaced backup key wins ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A SCW_BACKUP_AWS_ACCESS_KEY_ID=KEY-OF-B
is "a Scaleway cluster backing up elsewhere uses SCW_BACKUP_AWS_* for the copy" \
   "KEY-OF-B" "$(s3_cred scaleway backup ak)"
is "and the primary still uses SCW_AWS_* for itself" \
   "KEY-OF-A" "$(s3_cred scaleway primary ak)"

echo "--- the generic name is the second choice, not the first ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A BACKUP_AWS_ACCESS_KEY_ID=GENERIC-B
is "with no namespaced key, the generic BACKUP_AWS_* is used" \
   "GENERIC-B" "$(s3_cred scaleway backup ak)"
export SCW_BACKUP_AWS_ACCESS_KEY_ID=NAMESPACED-B
is "the namespaced one outranks the generic" \
   "NAMESPACED-B" "$(s3_cred scaleway backup ak)"

echo "--- the fallback: silent, correct for one provider, wrong for two ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A
BK="$(s3_cred scaleway backup ak)"
is "with no backup key at all, the copy is written with the PRIMARY's key" "KEY-OF-A" "$BK"
# The assertion that matters: this is INDISTINGUISHABLE from a configured backup,
# so nothing downstream can infer intent from the credentials alone. Whether the
# store is really elsewhere has to be decided from the ENDPOINTS, which is what
# scripts/internal/ensure-buckets.sh now does before creating anything.
if [ "$BK" = "$(s3_cred scaleway primary ak)" ]; then
  ok "and it is byte-identical to the primary's — so intent CANNOT be read from the keys"
else
  bad "the fallback no longer matches the primary; ensure-buckets' endpoint test may now be wrong"
fi

echo "--- one provider's backup key never leaks into another's ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A OVH_BACKUP_AWS_ACCESS_KEY_ID=OVH-ONLY
is "an OVH backup key is not served to a Scaleway cluster" \
   "KEY-OF-A" "$(s3_cred scaleway backup ak)"

echo "--- secrets resolve down the same chain as keys ---"
clear_env
export SCW_SECRET_KEY=SECRET-OF-A SCW_BACKUP_AWS_SECRET_ACCESS_KEY=SECRET-OF-B
is "the backup secret comes from SCW_BACKUP_AWS_SECRET_ACCESS_KEY" \
   "SECRET-OF-B" "$(s3_cred scaleway backup sk)"
is "and the primary secret still falls back to SCW_SECRET_KEY" \
   "SECRET-OF-A" "$(s3_cred scaleway primary sk)"

echo "--- the three shapes ensure-buckets.sh must tell apart ---"
# A stub `aws` stands in for the object stores: no account, no bill, and it can
# be made to refuse one endpoint, which is the case that matters.
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mk_stub() { # <endpoint-that-succeeds, or "all"> [no-state] — every call is logged
  {
    printf '#!/usr/bin/env bash\necho "$*" >>%q\n' "$SB/aws.log"
    # no-state: the cluster's tfstate object is absent, i.e. it was never applied.
    [ "${2:-}" = no-state ] && printf 'case " $* " in *" head-object "*) exit 254 ;; esac\n'
    if [ "$1" != all ]; then
      printf 'for a in "$@"; do case "$a" in %s*) exit 0 ;; esac; done\n' "$1"
      printf 'for a in "$@"; do case "$a" in https://*) exit 255 ;; esac; done\n'
    fi
    printf 'exit 0\n'
  } >"$SB/aws"
  chmod +x "$SB/aws"; : >"$SB/aws.log"
}
mk_tfvars() { # <replica-endpoint> [primary-endpoint] [environment] → path
  sed -E "s#^environment[[:space:]].*#environment = \"${3:-dev}\"#;
          s#^s3_primary_endpoint.*#s3_primary_endpoint = \"${2:-https://primary.example}\"#;
          s#^s3_primary_region.*#s3_primary_region = \"r1\"#;
          s#^s3_replica_endpoint.*#s3_replica_endpoint = \"$1\"#;
          s#^s3_replica_region.*#s3_replica_region = \"r2\"#" \
    infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
  printf '%s' "$SB/t.tfvars"
}
run_ensure() { env -u SCW_BACKUP_AWS_ACCESS_KEY_ID -u SCW_BACKUP_AWS_SECRET_ACCESS_KEY \
  PATH="$SB:$PATH" SCW_AWS_ACCESS_KEY_ID=A SCW_AWS_SECRET_ACCESS_KEY=A \
  ./scripts/internal/ensure-buckets.sh "$@" 2>&1; }

mk_stub "https://primary.example"; TF="$(mk_tfvars https://replica.example)"
OUT="$(run_ensure "$TF")"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'Refusing to continue' <<<"$OUT" \
  && ok "a backup asked for on another provider, and not obtainable, REFUSES the deploy" \
  || bad "an unobtainable cross-provider backup exited ${RC} — the deploy would proceed without a copy"
grep -q 'SCW_BACKUP_AWS_ACCESS_KEY_ID' <<<"$OUT" \
  && ok "and it names the variable to set, not just the failure" \
  || bad "the refusal does not say what to do about it"
grep -q 'back at https://primary.example' <<<"$OUT" \
  && ok "dev: it offers the single-cloud way out, replica back on the primary" \
  || bad "dev: the refusal no longer offers pointing the replica back at the primary"
TF="$(mk_tfvars https://replica.example https://primary.example prod)"
OUT="$(run_ensure "$TF")"
! grep -q 'back at' <<<"$OUT" && grep -q 'environment = "dev"' <<<"$OUT" \
  && ok "prod: it offers environment = \"dev\" instead of the shape prod refuses" \
  || bad "prod: the refusal still advises putting the replica back on the primary"

TF="$(mk_tfvars https://primary.example)"
OUT="$(run_ensure "$TF")"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'SAME endpoint' <<<"$OUT" \
  && ok "one provider, replica alongside: allowed, and stated rather than assumed" \
  || bad "the single-provider shape was refused or went unmentioned (exit ${RC})"

mk_stub all; TF="$(mk_tfvars https://replica.example)"
OUT="$(run_ensure "$TF")"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'DIFFERENT provider' <<<"$OUT" \
  && ok "a cross-provider backup that works: allowed, and reported as elsewhere" \
  || bad "a working cross-provider backup was refused (exit ${RC}) — the guard fires on the normal case"

echo "--- prod's replica must leave the primary's cloud: cluster-up's --preflight ---"
SCW_A=https://s3.fr-par.scw.cloud SCW_B=https://s3.nl-ams.scw.cloud OVH_A=https://s3.gra.io.cloud.ovh.net
touched() { grep -qE '(^| )(mb|head-bucket)( |$)' "$SB/aws.log"; }
expect() { # <refused|passes> <label> <env> <primary> <replica> [stub-state] [flag]
  mk_stub all "${6:-no-state}"
  OUT="$(run_ensure "$(mk_tfvars "$5" "$4" "$3")" "${7---preflight}")"; RC=$?
  if [ "$1" = refused ]; then
    [ "$RC" -ne 0 ] && grep -q 'No state was found at' <<<"$OUT" && ! touched \
      && ok "$2: refused before any bucket is touched" \
      || bad "$2: exit ${RC}, or a bucket was touched first — a new prod cluster would deploy with it"
  else
    [ "$RC" -eq 0 ] && ok "$2: passes" || bad "$2: refused (exit ${RC}): $(tail -3 <<<"$OUT")"
  fi
}
expect refused "prod, replica on the primary's endpoint"            prod "$SCW_A" "$SCW_A"
expect refused "prod, a self-hosted replica spelled differently"     prod https://minio.example.internal "HTTPS://MINIO.example.internal/"
expect refused "prod, same provider in another region"               prod "$SCW_A" "$SCW_B"
grep -q 'both endpoints are on scaleway' <<<"$OUT" \
  && ok "and it says why: one cloud, whatever the region" || bad "the same-provider refusal does not name the provider"
expect passes  "prod, replica on another provider"                   prod "$SCW_A" "$OVH_A"
expect passes  "prod, self-hosted S3 (no provider to name), another endpoint" prod https://minio-a.example.internal https://minio-b.example.internal
expect passes  "dev, replica on the primary's endpoint"              dev  "$SCW_A" "$SCW_A"
# The two ways it must NOT reach a deployed cluster, which has to stay
# plannable, upgradable and destroyable whatever its replica. A state object
# also survives a teardown, so the warning must cover a rebuild too.
expect passes  "prod shared, but a state object exists"              prod "$SCW_A" "$SCW_A" state-present
grep -q 'applied' <<<"$OUT" && grep -q 'torn down, this is a rebuild' <<<"$OUT" \
  && ok "and it still warns, for a live cluster and for a rebuild after a teardown" \
  || bad "the warning does not cover both a live prod cluster and one rebuilt after a teardown"
expect passes  "prod shared, called without --preflight (infra-apply)" prod "$SCW_A" "$SCW_A" no-state ""
is "the empty replica gets a reason too (infra-verify reads it)" \
   "s3_replica_endpoint is empty" "$(oa_replica_colocated "$SCW_A" "")"
# The prod examples are copied as-is; one that broke the rule would fail a first deploy.
N=0; BROKEN=""
for f in infrastructure/opentofu/cluster/envs/*.tfvars.example; do
  [ "$(tfv "$f" environment)" = prod ] || continue
  N=$((N + 1))
  W="$(oa_replica_colocated "$(tfv "$f" s3_primary_endpoint)" "$(tfv "$f" s3_replica_endpoint)")"
  [ -z "$W" ] || BROKEN="$BROKEN ${f##*/} ($W)"
done
[ "$N" -gt 0 ] && [ -z "$BROKEN" ] && ok "all $N prod examples keep the replica off the primary's cloud" \
  || bad "prod examples cluster-up would refuse (of $N):${BROKEN}"
# Only cluster-up may arm it: infra-apply is what cluster-upgrade and
# converge-versions call, and no destroy path reaches ensure-buckets at all.
CALLERS="$(awk '/^  [a-z0-9_-]+:$/ {t=$1} /ensure-buckets\.sh/ && !/^[[:space:]]*#/ {print t, (/--preflight/ ? "armed" : "plain")}' Taskfile.yml)"
is "Taskfile.yml: --preflight is passed by cluster-up alone" \
   "cluster-up: armed|infra-apply: plain" "$(paste -sd'|' <<<"$CALLERS")"


SCW_EP=https://s3.fr-par.scw.cloud
OSC_EP=https://oos.eu-west-2.outscale.com
OVH_EP=https://s3.eu-west-par.io.cloud.ovh.net

echo "--- the endpoint says who owns the bucket ---"
is "a Scaleway host maps to scaleway" "scaleway" "$(provider_of_endpoint "$SCW_EP")"
is "an Outscale host maps to outscale" "outscale" "$(provider_of_endpoint "$OSC_EP")"
is "an OVH host maps to ovh"           "ovh"      "$(provider_of_endpoint "$OVH_EP")"
is "anything else maps to nothing, and is not an error" \
   "" "$(provider_of_endpoint https://minio.example.internal)"

echo "--- the store's own keys outrank the cluster's backup namespace ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-SCW
export SCW_BACKUP_AWS_ACCESS_KEY_ID=WRONG-CLOUDS-KEY
export OUTSCALE_BACKUP_AWS_ACCESS_KEY_ID=KEY-OF-OSC
# The regression that cost the 2026-08-19 deploy: SCW_BACKUP_* is set, and it is
# the WRONG cloud's key. Naming the store is what makes the right one reachable.
is "a bucket on Outscale is opened with the Outscale key, not the SCW_BACKUP_ one" \
   "KEY-OF-OSC" "$(s3_cred scaleway backup ak "$OSC_EP")"
is "and the failure can name which variable it used" \
   "OUTSCALE_BACKUP_AWS_ACCESS_KEY_ID" "$(s3_cred_source scaleway backup ak "$OSC_EP")"

echo "--- with no *_BACKUP_* for the store, its PRIMARY keys are used ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-SCW OUTSCALE_AWS_ACCESS_KEY_ID=PRIMARY-OF-OSC
is "the Outscale bucket is opened with OUTSCALE_AWS_* — no new variable to invent" \
   "PRIMARY-OF-OSC" "$(s3_cred scaleway backup ak "$OSC_EP")"
is "and it says so" \
   "OUTSCALE_AWS_ACCESS_KEY_ID" "$(s3_cred_source scaleway backup ak "$OSC_EP")"

echo "--- same cloud, and unknown clouds, keep the old chain ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-SCW SCW_BACKUP_AWS_ACCESS_KEY_ID=SECOND-BUCKET-KEY
is "a replica on the SAME cloud still uses SCW_BACKUP_AWS_*" \
   "SECOND-BUCKET-KEY" "$(s3_cred scaleway backup ak "$SCW_EP")"
is "an endpoint this repo does not know falls back to the cluster namespace" \
   "SECOND-BUCKET-KEY" "$(s3_cred scaleway backup ak https://minio.example.internal)"
is "and calling it with NO endpoint behaves exactly as before" \
   "SECOND-BUCKET-KEY" "$(s3_cred scaleway backup ak)"

echo "--- a named store with no keys yields NOTHING, not the wrong cloud's key ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-SCW OVH_BACKUP_AWS_ACCESS_KEY_ID=KEY-OF-OVH
# Neither key belongs to Outscale. The old chain ended at the cluster's primary,
# so the copy authenticated as Scaleway against Outscale and failed with a
# provider error naming no variable. Empty is the honest answer: ensure-buckets
# turns it into a refusal that names the pair to export.
is "an OVH backup key is not handed to an Outscale bucket" \
   "" "$(s3_cred scaleway backup ak "$OSC_EP")"
is "and the Scaleway primary is not silently reused either" \
   "" "$(s3_cred scaleway backup ak "$OSC_EP")"


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
