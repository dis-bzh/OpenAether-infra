#!/usr/bin/env bash
# ==============================================================================
# The image lane must apply the plan it decided from — not a second, unseen one.
#
# `--ensure` planned with `-detailed-exitcode` and NO `-out`, then ran `tofu
# apply -auto-approve`. So the plan that answered "a rebuild is needed" was
# thrown away and a different one was applied, against buckets, a snapshot
# import and an image publish. And `--ensure` is the branch `task cluster-up`
# always takes, so the always-taken path was the one off the contract:
# plan → yes (a human, or APPROVE=auto) → apply THAT SAVED PLAN.
#
# The same stubs prove the lane's other contracts (#69): one state per version, the copy
# of the legacy single state, prune, and the Outscale same-name refusal.
#
# Offline: the real script runs with stub `tofu`, `aws` and `curl` on PATH, and
# the stubs record their argv. No cloud, no account, no bill, no network.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { # <label> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"
}

SCRIPT=scripts/bootstrap/talos-image.sh
TFROOT=infrastructure/opentofu/talos-image
SB="$(mktemp -d)"
LOG="$SB/tofu.log"
mkdir -p "$SB/tmp"   # the script's own mktemp lands here, so a leftover is visible
# The pin scans read an envs dir: a sandbox one, so a real gitignored tfvars in
# this checkout can neither fail these cases nor be written next to (#191).
export OA_ENVS_DIR="$SB/envs"; mkdir -p "$OA_ENVS_DIR"
PINFILE="$OA_ENVS_DIR/oa-scaleway.tfvars"
trap 'rm -rf "$SB"; rm -f "$TFROOT"/talos-image-*.tfplan' EXIT

# The schematic gate calls the Image Factory before anything else and refuses a
# build when the live id differs from the cluster pin. Offline, the stub answers
# with the pin itself, so the gate passes and the applies below are what is
# being measured. (Its own drift case belongs to the gate, not to this file.)
PIN="$(awk '/variable "talos_installer_schematic_id"/,/^}/' infrastructure/opentofu/cluster/variables.tf \
       | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([0-9a-f]+)".*/\1/p' | head -1)"

cat >"$SB/tofu" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OA_STUB_LOG"
KF="$OA_STUB_LOG.key"   # the state key the backend is inited on, and (KF.<key>) what was pushed to it
case "$1" in
  init) for a in "$@"; do case "$a" in -backend-config=key=*) printf '%s' "${a#-backend-config=key=}" >"$KF" ;; esac; done ;;
  plan)
    # A real `tofu plan -out=f` writes f even when there are no changes
    # (VERIFIED, OpenTofu 1.12.5) — so the cleanup is on every path, not just
    # the applying one, and this stub has to leave the same crumb.
    for a in "$@"; do case "$a" in -out=*) : >"${a#-out=}" ;; esac; done
    # Only -detailed-exitcode makes a real plan answer 2 for "there are changes".
    # Without it tofu returns 0 and the caller reads "nothing to do" — so the
    # stub must obey argv, not an env var, or dropping the flag is invisible.
    case "$*" in *-detailed-exitcode*) exit "${OA_STUB_PLAN_EXIT:-2}" ;; esac
    exit 0 ;;
  apply)  exit "${OA_STUB_APPLY_EXIT:-0}" ;;
  output) case "$*" in *image_name*) echo oa-talos-stub ;; *image_id*) echo "${OA_STUB_IMAGE_ID:-}" ;; esac ;;
  show)   cat "${OA_STUB_SHOW:-/dev/null}"; exit "${OA_STUB_SHOW_EXIT:-0}" ;;
  state)
    k="$(cat "$KF" 2>/dev/null)"
    case "$2" in
      pull) [ -z "${OA_STUB_PULL_FAIL:-}" ] || exit 1
            if [ -f "$KF.$k" ]; then cat "$KF.$k"; elif [ "$k" = talos-image.tfstate ]; then cat "${OA_STUB_LEGACY:-/dev/null}"; fi ;;
      push) [ -n "${OA_STUB_PUSH_DROP:-}" ] || jq '.lineage = "re-minted" | .serial = 1' "$3" >"$KF.$k" ;;  # the real backend re-mints both
      list) printf '%s' "${OA_STUB_LEFT:-}" ;;
    esac ;;
esac
exit 0
STUB
# Logged (prefixed, so it never collides with a tofu subcommand match below) —
# the zero-spend assertions need to see whether aws was ever invoked, not
# just tofu. The listing behaves like S3's: a bucket other than OA_STUB_BUCKET does not exist, and
# only the keys of OA_STUB_KEYS (tab-separated) that start with --prefix come back, else "None".
# head-bucket answers OA_STUB_HEAD (404 or 403) the way the CLI words it.
cat >"$SB/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws:%s\n' "$*" >>"$OA_STUB_LOG"
bucket="" prefix=""
for ((i = 1; i < $#; i++)); do
  j=$((i + 1))
  case "${!i}" in --bucket) bucket="${!j}" ;; --prefix) prefix="${!j}" ;; esac
done
case "$*" in
  *head-bucket*)
    case "${OA_STUB_HEAD:-}" in
      404) echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2; exit 254 ;;
      403) echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2; exit 254 ;;
    esac ;;
  *list-objects-v2*)
    [ -n "${OA_STUB_BUCKET:-}" ] || { echo "stub aws: OA_STUB_BUCKET unset" >&2; exit 99; }
    [ "$bucket" = "$OA_STUB_BUCKET" ] || { echo "An error occurred (NoSuchBucket) when calling the ListObjectsV2 operation" >&2; exit 254; }
    out=""
    for k in $(tr '\t' ' ' <<<"${OA_STUB_KEYS:-}"); do case "$k" in "$prefix"*) out+="${out:+	}$k" ;; esac; done
    printf '%s\n' "${out:-None}"; exit "${OA_STUB_LIST_EXIT:-0}" ;;
  "s3 mv "*) exit "${OA_STUB_MV_EXIT:-0}" ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nprintf %s "{\\"id\\":\\"%s\\"}"\n' '%s' "${PIN:-deadbeef}" >"$SB/curl"
chmod +x "$SB/tofu" "$SB/aws" "$SB/curl"

printf 'cluster_name  = "oatest"\nbucket_suffix = "t3st"\n' >"$SB/t.tfvars"

# `OUT="$(run …)"; RC=$?` — the exit status has to be read from the assignment.
# Setting it inside run() sets it in the substitution's subshell, where nothing
# can see it, and every "the script completes" below reads a stale 0 instead.
# PROV and VER (VER=none: no version argument) are set per call: `PROV=ovh run 2 --ensure`.
run() { # <plan-exit> [script args...] — prints the script's output, exits as it did
  : >"$LOG"
  rm -f "$LOG".key* "$TFROOT"/talos-image-*.tfplan
  local pe="$1"; shift
  local ver=("${VER:-v1.13.4}"); [ "${VER:-}" != none ] || ver=()
  # </dev/null is the point of the whole exercise: this is the lane that runs
  # with no terminal to answer a prompt.
  env PATH="${RUN_PATH:-$SB:$PATH}" OA_STUB_LOG="$LOG" OA_STUB_PLAN_EXIT="$pe" TMPDIR="$SB/tmp" \
      OA_STUB_BUCKET="s3-oatest-t3st-${PROV:-scaleway}-talos-image" \
      TALOS_IMAGE_ALLOW_OFFLINE="${TALOS_IMAGE_ALLOW_OFFLINE:-0}" \
      OA_TFVARS="$SB/t.tfvars" \
      SCW_AWS_ACCESS_KEY_ID=STUB-AK SCW_AWS_SECRET_ACCESS_KEY=STUB-SK \
      OVH_AWS_ACCESS_KEY_ID=STUB-AK OVH_AWS_SECRET_ACCESS_KEY=STUB-SK \
      OUTSCALE_AWS_ACCESS_KEY_ID=STUB-AK OUTSCALE_AWS_SECRET_ACCESS_KEY=STUB-SK \
      "$SCRIPT" "${PROV:-scaleway}" "${ver[@]}" "$@" </dev/null 2>&1
}
calls() { grep -c "^$1 " "$LOG"; }          # how many `tofu <subcommand>` calls
acalls() { grep -c "^aws:$1" "$LOG"; }      # ... and `aws <args>` ones
initkeys() { sed -nE 's/^init .*-backend-config=key=([^ ]+).*/\1/p' "$LOG" | tr '\n' ' ' | sed 's/ $//'; }
line()  { grep -m1 "^$1 " "$LOG"; }         # the first one, whole
positional() { # <subcommand> — its non-flag arguments
  local skip=0 out=()
  for tok in $(line "$1"); do
    [ "$tok" = "$1" ] && continue
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$tok" in
      -var | -var-file | -target) skip=1 ;;
      -*) ;;
      *) out+=("$tok") ;;
    esac
  done
  printf '%s' "${out[*]:-}"
}

hasvar() { [[ " $(line "$1") " == *" -var $2 "* ]]; }  # does that `tofu <subcommand>` call carry exactly -var <name=value>?

# The schematic gate's OWN blind case, which this file used to leave to nobody:
# an unreachable Factory left LIVE_ID empty, so the refusal and the line of
# reassurance were both skipped and the build went ahead in silence.
# Note WHICH failure this is. A curl that exits non-zero aborts under `set -e`;
# the case nothing covered is the Factory answering with no id in it — a rate
# limit, an error body — which leaves LIVE_ID empty at exit 0.
echo "--- the Factory answers with no schematic id: the gate must not go quiet ---"
mv "$SB/curl" "$SB/curl.ok"
printf '#!/usr/bin/env bash\nprintf %%s "{\\"error\\":\\"rate limited\\"}"\n' >"$SB/curl"
chmod +x "$SB/curl"
OUT="$(run 2 --ensure)"; RC=$?
[ "$RC" -ne 0 ] \
  && ok "an unverifiable schematic pin refuses the build (rc=$RC)" \
  || bad "the build proceeded with the schematic pin unverified — rc=$RC"
grep -qi "no schematic id" <<<"$OUT" \
  && ok "and it says which check did not happen" \
  || bad "it stopped without naming the unverified check"
OUT="$(TALOS_IMAGE_ALLOW_OFFLINE=1 run 2 --ensure)"; RC=$?
is "TALOS_IMAGE_ALLOW_OFFLINE=1 lets it through" 0 "$RC"
grep -qi "NOT checked" <<<"$OUT" \
  && ok "and the abstention is stated, not silent" \
  || bad "it built anyway without a word about the skipped check"
mv "$SB/curl.ok" "$SB/curl"

echo "--- --ensure, a rebuild IS needed: one plan, to a file, and THAT file is applied ---"
OUT="$(run 2 --ensure)"; RC=$?
is "the script completes" 0 "$RC"
is "exactly one plan" 1 "$(calls plan)"
PLANFILE="$(sed -nE 's/.*-out=([^ ]+).*/\1/p' <<<"$(line plan)")"
[ -n "$PLANFILE" ] \
  && ok "the plan is saved: -out=${PLANFILE}" \
  || bad "the plan has no -out — whatever it decided is gone, and the apply computes its own"
is "exactly one apply" 1 "$(calls apply)"
is "the apply is handed that exact plan file" "$PLANFILE" "$(positional apply)"
grep -q -- '-auto-approve' "$LOG" \
  && bad "-auto-approve on a lane that computed its own plan: $(line apply)" \
  || ok "no -auto-approve — the approval is answered by a saved plan, not removed"
grep -qE '^apply .*-var[ =]' "$LOG" \
  && bad "the apply re-passes -var; a value that disagrees with the plan file is refused outright" \
  || ok "the apply passes no -var — a saved plan carries its own"
[ -e "$TFROOT/$PLANFILE" ] \
  && bad "${PLANFILE:-<no -out>} outlived the run" \
  || ok "the plan file is deleted after the apply"
case "$PLANFILE" in *.tfplan) ok "it is named *.tfplan" ;; *) bad "${PLANFILE:-<no -out>} does not end in .tfplan" ;; esac
is "the plan filename carries the \$TGT discriminator" "talos-image-scaleway.tfplan" "$PLANFILE"
git check-ignore -q "$TFROOT/$PLANFILE" \
  && ok "and git ignores that path — a plan of a real account is never committable" \
  || bad "${PLANFILE:-<no -out>} is NOT gitignored: a plan file naming real buckets could be committed"

echo "--- --ensure, image already up to date: the normal case stays silent and cheap ---"
OUT="$(run 0 --ensure)"; RC=$?
is "the script completes" 0 "$RC"
is "nothing is applied" 0 "$(calls apply)"
grep -q 'up to date' <<<"$OUT" \
  && ok "and it says so" || bad "it did not report the image as up to date"
PLANFILE0="$(sed -nE 's/.*-out=([^ ]+).*/\1/p' <<<"$(line plan)")"
[ -n "$PLANFILE0" ] && [ ! -e "$TFROOT/$PLANFILE0" ] \
  && ok "the plan file is deleted on the no-change path too" \
  || bad "the up-to-date path left ${PLANFILE0:-<no -out>} behind"

echo "--- --ensure, the plan itself fails: nothing is applied ---"
OUT="$(run 1 --ensure)"; RC=$?
[ "$RC" -ne 0 ] && ok "a failed plan fails the script (exit $RC)" \
                || bad "a failed plan exited 0 — cluster-up would continue on an unbuilt image"
is "and nothing was applied" 0 "$(calls apply)"

echo "--- plain \`task image-build\`: interactive, and interactive means ONE plan ---"
OUT="$(run 2)"; RC=$?
is "the script completes" 0 "$RC"
is "no separate plan is computed" 0 "$(calls plan)"
is "exactly one apply" 1 "$(calls apply)"
grep -q -- '-auto-approve' "$LOG" \
  && bad "-auto-approve here removes the human's approval instead of answering it" \
  || ok "no -auto-approve: tofu shows and applies the SAME in-memory plan, and a human answers it"
grep -qE '^apply .*-var ' "$LOG" \
  && ok "the apply carries its variables — it is a real plan, not a saved-plan replay" \
  || bad "the interactive apply carries no -var; it is no longer planning what it applies"

echo "--- the source itself ---"
# Comments excluded on purpose: the one above the ensure branch NAMES the flag
# to say why it is gone, and a check that cannot tell prose from code gets muted.
is "no -auto-approve in the code of $SCRIPT" 0 \
   "$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$SCRIPT" | grep -c -- '-auto-approve')"

echo "--- a failed apply must fail the run (cluster-up deploys on what it says) ---"
# OA_STUB_APPLY_EXIT existed and nothing ever set it, so `tofu apply "$PLAN" || true`
# — one token — passed unnoticed. An image build that reports success it did not
# have sends cluster-up on to deploy against an image that was never published.
: >"$LOG"; rm -f "$TFROOT"/talos-image-scaleway.tfplan
RC=0
env PATH="$SB:$PATH" OA_STUB_LOG="$LOG" OA_STUB_PLAN_EXIT=2 OA_STUB_APPLY_EXIT=1 \
    OA_STUB_BUCKET=s3-oatest-t3st-scaleway-talos-image OA_TFVARS="$SB/t.tfvars" \
    SCW_AWS_ACCESS_KEY_ID=STUB-AK SCW_AWS_SECRET_ACCESS_KEY=STUB-SK \
    "$SCRIPT" scaleway v1.13.4 --ensure </dev/null >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] && ok "a failing apply propagates (exit $RC), so the caller cannot deploy on it" \
                || bad "the script reported SUCCESS on a failed apply — cluster-up would deploy against an image that does not exist"
[ ! -e "$TFROOT/talos-image-scaleway.tfplan" ] \
  && ok "and the plan file is still cleaned up on that path" \
  || bad "a plan naming real buckets outlived a failed apply, in a public working tree"

echo "--- one state per version: the backend key carries the provider and the version ---"
OUT="$(run 2 --ensure)"; RC=$?
is "the script completes" 0 "$RC"
is "tofu is inited on the version's own key, once" "talos-image-scaleway-v1.13.4.tfstate" "$(initkeys)"
OUT="$(VER=v1.13.9 run 2 --ensure)"
is "another version gets another key" "talos-image-scaleway-v1.13.9.tfstate" "$(initkeys)"
OUT="$(PROV=ovh run 2 --ensure)"
is "another provider too" "talos-image-ovh-v1.13.4.tfstate" "$(initkeys)"
printf 'talos_version = "v1.13.7"\n' >"$OA_ENVS_DIR/management-scaleway.tfvars"
OUT="$(VER=none run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(initkeys)" = "talos-image-scaleway-v1.13.7.tfstate" ]; } \
  && ok "no version argument builds the pin of the cluster tfvars, not a literal kept in the script" \
  || bad "a bare call did not resolve the pin (rc=$RC, keys: $(initkeys))"
rm -f "$OA_ENVS_DIR/management-scaleway.tfvars"
printf 'talos_version = "v1.13.5"\n' >"$OA_ENVS_DIR/prod-scaleway.tfvars"
OUT="$(OA_ROLE=prod VER=none run 2 --ensure)"
is "OA_ROLE picks the tfvars a bare call reads its pin from" "talos-image-scaleway-v1.13.5.tfstate" "$(initkeys)"
rm -f "$OA_ENVS_DIR/prod-scaleway.tfvars"

echo "--- a cluster pinning ANOTHER version no longer blocks a build (it used to, #93) ---"
printf 'talos_version = "v1.13.9"\n' >"$PINFILE"
OUT="$(run 2 --ensure)"; RC=$?
is "the build completes" 0 "$RC"
is "and applies" 1 "$(calls apply)"
rm -f "$PINFILE"

echo "--- --list: the versions held, read from the lane bucket; builds nothing, creates nothing ---"
OUT="$(OA_STUB_KEYS=$'talos-image-scaleway-v1.13.4.tfstate\ttalos-image-scaleway-v1.14.2.tfstate\ttalos-image-ovh-v1.13.9.tfstate' run 2 --list)"; RC=$?
is "the script completes" 0 "$RC"
{ grep -q 'v1.13.4' <<<"$OUT" && grep -q 'v1.14.2' <<<"$OUT"; } && ok "it names every version of this provider" || bad "a held version is missing: $OUT"
grep -q 'v1.13.9' <<<"$OUT" && bad "it listed another provider's version" || ok "and no other provider's"
is "tofu is never called" 0 "$(calls init)"
OUT="$(OA_STUB_LIST_EXIT=1 run 2 --list)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'cannot list' <<<"$OUT"; } && ok "a listing that fails is an error, not an empty lane" || bad "a failed listing read as 'nothing held' (rc=$RC)"
OUT="$(OA_STUB_KEYS=$'talos-image.tfstate\ttalos-image-scaleway-v1.13.4.tfstate' run 2 --list)"
grep -q 'pre-#69' <<<"$OUT" && ok "the pre-#69 state is mentioned when the lane holds one" || bad "a legacy key went unmentioned"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --list)"
grep -q 'pre-#69' <<<"$OUT" && bad "the pre-#69 note appeared with no legacy key" || ok "and is absent when it holds none"
OUT="$(OA_STUB_HEAD=404 run 2 --list)"; RC=$?
{ [ "$RC" -eq 0 ] && grep -q 'nothing held' <<<"$OUT" && [ "$(acalls 's3 mb')" = 0 ]; } \
  && ok "a lane with no bucket lists nothing and does not create it (S3 names are global)" || bad "--list on a missing bucket created it or failed (rc=$RC)"
OUT="$(OA_STUB_HEAD=403 run 2 --list)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(acalls 's3 mb')" = 0 ] && ! grep -q 'nothing held' <<<"$OUT"; } \
  && ok "a bucket that cannot be reached (403) is an error, not an empty lane" || bad "a 403 read as 'nothing held' (rc=$RC)"
OUT="$(OA_STUB_HEAD=404 run 2 --ensure)"
is "a build still creates both missing buckets" 2 "$(acalls 's3 mb')"

echo "--- one mode per run: the last flag used to win, so --list --prune destroyed ---"
for combo in '--list --prune' '--prune --list' '--ensure --list' '--ensure --prune'; do
  # shellcheck disable=SC2086  # the combo IS several arguments
  OUT="$(run 2 $combo)"; RC=$?
  { [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; } && ok "'$combo' is refused before any call (rc=$RC)" || bad "'$combo' ran: $(head -c 200 "$LOG")"
done
OUT="$(PROV=outscale run 2 --import-snapshot snap-fixture1 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; } && ok "'--import-snapshot <id> --prune' is refused too" || bad "an import and a prune ran together"
OUT="$(PROV=outscale run 2 --import-snapshot --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; } && ok "a flag is not taken for a snapshot id" || bad "--prune was read as the snapshot id"

echo "--- --prune: explicit, one version, and never while a cluster still pins it ---"
printf 'talos_version = "v1.13.4"\n' >"$PINFILE"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q "${PINFILE##*/}" <<<"$OUT"; } \
  && ok "a pinned version is refused, naming the tfvars (rc=$RC)" || bad "prune went ahead on a pinned version, or did not name it (rc=$RC)"
[ ! -s "$LOG" ] && ok "zero tofu/aws calls: refused before any spend" || bad "calls were made despite the pin: $(cat "$LOG")"
printf 'talos_version = "v1.13.9"\n' >"$PINFILE"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --prune)"; RC=$?
is "an unpinned version is pruned" 0 "$RC"
is "by one destroy" 1 "$(calls destroy)"
for v in target_provider=scaleway talos_version=v1.13.4 import_bucket=s3-oatest-t3st-scaleway-talos-import; do
  hasvar destroy "$v" && ok "the destroy carries -var $v" || bad "the destroy lacks -var $v: $(line destroy)"
done
is "on that version's own state" "talos-image-scaleway-v1.13.4.tfstate" "$(initkeys)"
is "it reads the lane's state bucket and ensures nothing else" 1 "$(acalls 's3api head-bucket')"
is "the emptied state object is removed, or --list would still show the version" 1 "$(acalls "s3 rm .*talos-image-scaleway-v1.13.4.tfstate")"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate OA_STUB_LEFT=module.scaleway run 2 --prune)"
{ [ "$(calls destroy)" = 1 ] && [ "$(acalls 's3 rm')" = 0 ]; } \
  && ok "a state that still holds objects (destroy declined) is kept" || bad "a state with objects left was removed, or the destroy did not run"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.14.2.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ]; } && ok "a version no state holds is refused, not destroyed blind" || bad "prune of an unheld version did not refuse (rc=$RC)"
OUT="$(OA_STUB_HEAD=404 run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(acalls 's3 mb')" = 0 ] && [ "$(calls destroy)" = 0 ]; } \
  && ok "a lane with no bucket has nothing to prune, and none is created" || bad "prune on a missing bucket created it or went on (rc=$RC)"
rm -f "$PINFILE"

# Only a build depends on the Factory: one that disagrees with the pin must not block removing an image.
mv "$SB/curl" "$SB/curl.ok"
printf '#!/usr/bin/env bash\nprintf %%s "{\\"id\\":\\"0000\\"}"\n' >"$SB/curl"; chmod +x "$SB/curl"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --list)"; RC=$?
is "a Factory that disagrees with the pin does not block a listing" 0 "$RC"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --prune)"; RC=$?
is "…nor a prune" 0 "$RC"
mv "$SB/curl.ok" "$SB/curl"

echo "--- the legacy single state: copied by a build of the version it holds, never guessed ---"
LEG=talos-image.tfstate
legacy() { # <build version> <image name> [extra attributes of the image instance, JSON] — a pre-#69 `tofu state pull`
  jq -n --arg bv "$1" --arg img "$2" --argjson x "${3:-null}" '{version:4, serial:3, lineage:"fixture-lineage", resources:[
    {module:"module.scaleway[0]", mode:"managed", type:"terraform_data", name:"build_and_upload",
     instances:[{attributes:{triggers_replace:{value:{version:$bv}, type:["object",{version:"string"}]}}}]},
    {module:"module.scaleway[0]", mode:"managed", type:"scaleway_instance_image", name:"talos",
     instances:[({index_key:"fr-par-1", attributes:{name:$img}} + ($x // {}))]}]}'
}
legacy v1.13.4 talos-scaleway-amd64-v1.13.4 >"$SB/legacy.json"
export OA_STUB_LEGACY="$SB/legacy.json" OA_STUB_KEYS="$LEG"
OUT="$(run 2 --ensure)"; RC=$?
is "a build of the version it holds completes" 0 "$RC"
is "it reads the legacy key first, then works on the version's own" "$LEG talos-image-scaleway-v1.13.4.tfstate" "$(initkeys)"
is "and pushes the pulled state to the new key" 1 "$(calls 'state push')"
awk '/^state push/ {p=NR} /^plan/ {l=NR} END {exit !(p && l && p<l)}' "$LOG" \
  && ok "before the first plan (a plan on an unmoved state would rebuild the image)" || bad "the push did not precede the plan: $(tr '\n' '|' <"$LOG")"
awk '/^state push/ {exit} /^output/ {found=1} END {exit found}' "$LOG" \
  && ok "no root output was read to decide the version" || bad "the version was asked of the root output before the copy"
is "the legacy object is retired by rename, not deleted" 1 "$(acalls "s3 mv s3://s3-oatest-t3st-scaleway-talos-image/$LEG s3://s3-oatest-t3st-scaleway-talos-image/$LEG.migrated-to-v1.13.4")"
is "and nothing was destroyed" 0 "$(acalls 's3 rm')"
is "the decrypted copy of the legacy state is gone after the run" 0 "$(find "$SB/tmp" -type f | wc -l)"

OUT="$(OA_STUB_MV_EXIT=1 run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && grep -q 'could not retire' <<<"$OUT"; } && ok "a rename that fails warns with the command and goes on (the copy is done)" || bad "a failed retire was silent or fatal (rc=$RC)"
OUT="$(OA_STUB_PUSH_DROP=1 run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(acalls 's3 mv')" = 0 ] && [ "$(calls apply)" = 0 ]; } \
  && ok "a push that did not land (the pulled state holds other resources) stops before the legacy object is touched" || bad "the copy was not verified (rc=$RC)"
is "…and the decrypted copy is removed on that path too" 0 "$(find "$SB/tmp" -type f | wc -l)"

OUT="$(VER=v1.13.9 run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls 'state push')" = 0 ] && [ "$(acalls 's3 mv')" = 0 ] && [ "$(initkeys)" = "$LEG talos-image-scaleway-v1.13.9.tfstate" ]; } \
  && ok "a build of ANOTHER version leaves the legacy state where it is" || bad "another version's build moved the legacy state (rc=$RC, keys: $(initkeys))"
grep -q 'stays its authority' <<<"$OUT" && ok "and says whose it stays" || bad "it did not say why the legacy state was left"

OUT="$(OA_STUB_KEYS=$'talos-image.tfstate\ttalos-image-scaleway-v1.13.4.tfstate' run 2 --ensure)"
is "an already migrated version does not read the legacy state again" "talos-image-scaleway-v1.13.4.tfstate" "$(initkeys)"
OUT="$(OA_STUB_PULL_FAIL=1 run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls plan)" = 0 ] && [ "$(calls 'state push')" = 0 ]; } && ok "an unreadable legacy state refuses and changes nothing" || bad "an unreadable legacy state was guessed at (rc=$RC)"

OUT="$(run 2 --prune)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls 'state push')" = 1 ] && [ "$(calls destroy)" = 1 ] && [ "$(acalls 's3 mv')" = 1 ]; } \
  && ok "--prune of a version only the legacy state holds copies it, then destroys that version" || bad "prune ignored the legacy state (rc=$RC): ${OUT:0:200}"
awk '/^state push/ {p=NR} /^destroy/ {d=NR} END {exit !(p && d && p<d)}' "$LOG" \
  && ok "…in that order" || bad "the destroy did not follow the copy: $(tr '\n' '|' <"$LOG")"
OUT="$(VER=v1.13.9 run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ] && [ "$(calls 'state push')" = 0 ]; } \
  && ok "--prune of a version the legacy state does not hold refuses and leaves it alone" || bad "prune touched the legacy state of another version (rc=$RC)"

# A half-finished object only blocks the version it belongs to: a Talos bump on that provider must not wait for a hand edit.
for case_ in 'deposed|{"deposed":"1a2b3c4d"}' 'tainted|{"status":"tainted"}'; do
  IFS='|' read -r what extra <<<"$case_"
  legacy v1.13.4 talos-scaleway-amd64-v1.13.4 "$extra" >"$SB/legacy-bad.json"
  OUT="$(OA_STUB_LEGACY="$SB/legacy-bad.json" run 2 --ensure)"; RC=$?
  { [ "$RC" -ne 0 ] && grep -q 'not clean' <<<"$OUT" && grep -q 'module.scaleway\[0\].scaleway_instance_image.talos' <<<"$OUT" && grep -q 'state rm' <<<"$OUT" \
      && [ "$(calls 'state push')" = 0 ] && [ "$(calls plan)" = 0 ] && [ "$(acalls 's3 mv')" = 0 ]; } \
    && ok "the version a $what legacy state holds is refused, naming the object: nothing moved, no plan" \
    || bad "a $what object was carried over (rc=$RC): ${OUT:0:200}"
  OUT="$(VER=v1.13.9 OA_STUB_LEGACY="$SB/legacy-bad.json" run 2 --ensure)"; RC=$?
  { [ "$RC" -eq 0 ] && [ "$(calls apply)" = 1 ] && [ "$(calls 'state push')" = 0 ] && [ "$(acalls 's3 mv')" = 0 ] \
      && [ "$(initkeys)" = "$LEG talos-image-scaleway-v1.13.9.tfstate" ] && grep -q 'stays its authority' <<<"$OUT"; } \
    && ok "…but another version still builds, the $what legacy state left where it is" \
    || bad "a $what legacy state blocked another version's build (rc=$RC): ${OUT:0:200}"
done
legacy v1.13.9 talos-scaleway-amd64-v1.13.4 >"$SB/legacy-mixed.json"
for v in v1.13.4 v1.13.9; do
  OUT="$(VER=$v OA_STUB_LEGACY="$SB/legacy-mixed.json" run 2 --ensure)"; RC=$?
  { [ "$RC" -ne 0 ] && grep -q 'v1.13.4, v1.13.9' <<<"$OUT" && [ "$(calls 'state push')" = 0 ] && [ "$(calls plan)" = 0 ]; } \
    && ok "objects naming two versions (a build moved, its image did not) are refused for $v" || bad "disagreeing objects were migrated for $v (rc=$RC)"
done
OUT="$(VER=v1.13.7 OA_STUB_LEGACY="$SB/legacy-mixed.json" run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls apply)" = 1 ] && [ "$(calls 'state push')" = 0 ]; } \
  && ok "…and a third version builds" || bad "a mixed legacy state blocked a version it does not name (rc=$RC)"
legacy v1.13.4 talos-scaleway-amd64 >"$SB/legacy-blind.json"
OUT="$(VER=v1.13.9 OA_STUB_LEGACY="$SB/legacy-blind.json" run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'no readable version' <<<"$OUT" && [ "$(calls plan)" = 0 ]; } \
  && ok "an object naming no version blocks every build: what the state holds is unknown" || bad "a state of unknown content was passed (rc=$RC)"
unset OA_STUB_LEGACY OA_STUB_KEYS

echo "--- image-state-version.sh reads the objects of every provider's lane ---"
HELPER=scripts/internal/image-state-version.sh
objs() { # <type> <name> <attr> <value> [deposed] — one managed object
  jq -n --arg t "$1" --arg n "$2" --arg a "$3" --arg v "$4" --arg d "${5:-}" \
    '{type:$t,name:$n,mode:"managed",instances:[({attributes:{($a):$v}} + (if $d == "" then {} else {deposed:$d} end))]}'
}
objt() { # <type> <name> <version> — a build object, its version in triggers_replace as `state pull` prints it
  jq -n --arg t "$1" --arg n "$2" --arg v "$3" '{type:$t,name:$n,mode:"managed",instances:[{attributes:{triggers_replace:{value:{version:$v}}}}]}'
}
st() { jq -s '{resources:.}'; }
is "outscale: the OMI name" v1.14.2 "$({ objs outscale_image talos image_name talos-outscale-amd64-v1.14.2; } | st | "$HELPER")"
is "ovh: the Glance image name" v1.14.2 "$({ objs openstack_images_image_v2 talos name talos-ovh-amd64-v1.14.2; } | st | "$HELPER")"
is "proxmox: the datastore file, which drops the v" v1.14.2 "$({ objs proxmox_virtual_environment_download_file talos file_name talos-1.14.2-nocloud-amd64.img; } | st | "$HELPER")"
is "a pre-release version is read whole" v1.14.0-beta.1 "$({ objs outscale_image talos image_name talos-outscale-amd64-v1.14.0-beta.1; } | st | "$HELPER")"
is "ovh: a build and its image agree" v1.14.2 "$({ objt terraform_data build v1.14.2; objs openstack_images_image_v2 talos name talos-ovh-amd64-v1.14.2; } | st | "$HELPER")"
is "ovh: a build that moved while its image did not names both" "v1.14.2 v1.14.3" "$({ objt terraform_data build v1.14.3; objs openstack_images_image_v2 talos name talos-ovh-amd64-v1.14.2; } | st | "$HELPER")"
is "a deposed object is reported on line 2, not hidden" "v1.14.2|outscale_image.talos" \
   "$({ objs outscale_image talos image_name talos-outscale-amd64-v1.14.2 abc123; } | st | "$HELPER" | paste -sd'|')"
is "no managed object: nothing to say" "" "$(echo '{"resources":[]}' | "$HELPER")"
OUT="$({ objs outscale_image talos image_name talos-outscale-amd64; } | st | "$HELPER" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'no readable version' <<<"$OUT"; } && ok "a name carrying no version is refused, not guessed" || bad "an unreadable name passed (rc=$RC): $OUT"
OUT="$({ objt terraform_data build_and_upload ""; } | st | "$HELPER" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "a build whose version is empty is refused too" || bad "an empty build version passed: $OUT"
OUT="$({ objs scaleway_object_bucket other name staging; } | st | "$HELPER" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'none of its objects' <<<"$OUT"; } && ok "objects of no known type are refused: nothing says what the state holds" || bad "a state of unknown objects passed (rc=$RC): $OUT"

echo "--- the Outscale same-name refusal: before the import, not after ---"
mkdir -p "$SB/shows"
show() { # <actions, comma-separated> — a plan as `tofu show -json` prints it: the OMI it creates is named in `after`
  jq -n --arg acts "$1" '{resource_changes:[{type:"outscale_image", change:{actions:($acts | split(",")), after:{image_name:"talos-outscale-amd64-v1.13.4"}}}]}'
}
# The account's answer: OA_STUB_OMIS (space-separated ids) and OA_STUB_OMI_EXIT, the name it was asked for kept in $SB/omi.asked.
cat >"$SB/omi-lookup" <<'LOOKUP'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >>"$OA_STUB_OMI_ASKED"
[ "${OA_STUB_OMI_EXIT:-0}" = 0 ] || exit "$OA_STUB_OMI_EXIT"
for id in ${OA_STUB_OMIS:-}; do echo "$id"; done
LOOKUP
chmod +x "$SB/omi-lookup"
export OA_OMI_LOOKUP="$SB/omi-lookup" OA_STUB_OMI_ASKED="$SB/omi.asked"
gate() { # <show file> <omi ids, space-separated> [exit of tofu show] [exit of the lookup] — an Outscale --ensure whose plan is that file
  OUT="$(OA_STUB_SHOW="$1" OA_STUB_OMIS="$2" OA_STUB_SHOW_EXIT="${3:-0}" OA_STUB_OMI_EXIT="${4:-0}" PROV=outscale run 2 --ensure)"; RC=$?
}
show create >"$SB/shows/create.json"
: >"$SB/omi.asked"
gate "$SB/shows/create.json" ami-fixture1
{ [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "a plan creating the OMI while one holds the name is refused, nothing applied (rc=$RC)" || bad "the collision reached the apply (rc=$RC)"
grep -q 'ami-fixture1' <<<"$OUT" && ok "the message names the OMI" || bad "the message does not name the OMI: $OUT"
grep -qi "owner" <<<"$OUT" && ok "and says deleting an untracked OMI is the owner's, not this script's" || bad "no word on who deletes it"
is "the account was asked for the name the plan creates, in the lane's region" "talos-outscale-amd64-v1.13.4 eu-west-2" "$(head -1 "$SB/omi.asked")"
# Replacing the lane's own OMI is create-before-destroy: the same-version case the refusal exists for.
for acts in create,delete delete,create; do
  show "$acts" >"$SB/shows/replace.json"
  gate "$SB/shows/replace.json" ami-fixture1
  { [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "a replacement (actions: $acts) of an OMI that holds the name is refused" || bad "a replace of $acts reached the apply (rc=$RC)"
done
gate "$SB/shows/create.json" "ami-fixture1 ami-fixture2"
grep -q 'ami-fixture1 ami-fixture2' <<<"$OUT" && ok "two OMIs holding the name are both named" || bad "the message lost an id: $OUT"
: >"$SB/omi.asked"
show no-op >"$SB/shows/tracked.json"
gate "$SB/shows/tracked.json" ami-fixture1
{ [ "$RC" -eq 0 ] && [ "$(calls apply)" = 1 ] && [ ! -s "$SB/omi.asked" ]; } && ok "no OMI created: the account is not even asked, and the run goes ahead" || bad "a plan creating no OMI was blocked or asked (rc=$RC)"
gate "$SB/shows/create.json" ""
{ [ "$RC" -eq 0 ] && [ "$(calls apply)" = 1 ]; } && ok "a creation with the name free goes ahead" || bad "a free name was refused (rc=$RC)"
jq '.resource_changes[0].change.after = {}' "$SB/shows/create.json" >"$SB/shows/blind.json"
gate "$SB/shows/blind.json" ""
{ [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "a plan that does not name the OMI is refused: a gate that cannot see is not a gate" || bad "a plan with no OMI name went to the apply (rc=$RC)"
gate "$SB/shows/create.json" ami-fixture1 1
{ [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "a plan that cannot be read is not applied" || bad "an unreadable plan went to the apply (rc=$RC)"
gate "$SB/shows/create.json" "" 0 2
{ [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "an account that cannot answer is not an account with no OMI: nothing applied" || bad "a refused lookup read as 'no OMI' (rc=$RC)"
: >"$SB/omi.asked"
OUT="$(OA_STUB_SHOW="$SB/shows/create.json" OA_STUB_OMIS=ami-fixture1 run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls show)" = 0 ] && [ ! -s "$SB/omi.asked" ]; } && ok "other providers never ask" || bad "the Outscale gate ran on scaleway (rc=$RC)"

# The lookup itself, against a local endpoint that answers like the API: a name nobody holds is an EMPTY answer (the provider's
# data source fails the plan instead, measured on a real account), and a refusal or a dead endpoint is exit 2, never empty.
LOOK=scripts/internal/outscale-omi-ids.py
cat >"$SB/osc-api.py" <<'API'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        act = self.path.rsplit('/', 1)[1]
        if sys.argv[2] == 'deny': code, out = 401, {'Errors': [{'Code': '1'}]}
        elif act == 'ReadAccounts': code, out = 200, {'Accounts': [{'AccountId': 'ACC'}]}
        else:
            f = body['Filters']
            assert f['AccountIds'] == ['ACC'], f
            held = {'taken': [{'ImageId': 'ami-aaaa1111', 'ImageName': f['ImageNames'][0]}, {'ImageId': 'ami-bbbb2222', 'ImageName': f['ImageNames'][0]}]}
            code, out = 200, {'Images': held.get(sys.argv[2], [])}
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps(out).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
API
osc() { # <mode: taken|none|deny> — the answer of the lookup against that stub endpoint, then its exit code
  local port=$((20000 + RANDOM % 20000)); python3 "$SB/osc-api.py" "$port" "$1" & local pid=$!
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
  OUT="$(OUTSCALE_ACCESS_KEY_ID=k OUTSCALE_SECRET_KEY=s OA_OSC_API="http://127.0.0.1:$port" "$LOOK" talos-outscale-amd64-v1.13.4 2>&1)"; RC=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
osc taken; is "lookup: the OMIs of the account holding the name, one id per line" "0 ami-aaaa1111|ami-bbbb2222" "$RC $(paste -sd'|' <<<"$OUT")"
osc none;  is "lookup: nobody holds the name is an empty answer, exit 0" "0 " "$RC $OUT"
osc deny;  { [ "$RC" -eq 2 ] && grep -q 'HTTP 401' <<<"$OUT"; } && ok "lookup: a refusal is exit 2 and says so" || bad "a refused ReadAccounts read as an answer (rc=$RC): $OUT"
OUT="$(OUTSCALE_ACCESS_KEY_ID=k OUTSCALE_SECRET_KEY=s OA_OSC_API="http://127.0.0.1:9" "$LOOK" x 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "lookup: an unreachable endpoint is exit 2, not 'no OMI'" || bad "an unreachable endpoint read as an answer (rc=$RC): $OUT"
OUT="$(env -u OUTSCALE_ACCESS_KEY_ID "$LOOK" x 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "lookup: no credential is exit 2" || bad "a missing credential read as an answer (rc=$RC)"

echo "--- --import-snapshot: an import that outlived a failed apply, into THAT version's state ---"
BUILD_ADDR='module.outscale[0].terraform_data.build_and_upload'
OUT="$(OA_STUB_LEFT="$BUILD_ADDR" PROV=outscale run 2 --import-snapshot snap-fixture1)"; RC=$?
is "completes when that version's state holds the build" 0 "$RC"
grep -qE "^import .*module\.outscale\[0\]\.outscale_snapshot\.talos snap-fixture1$" "$LOG" \
  && ok "it imports the snapshot at the address that exists" || bad "wrong import: $(line import)"
for v in target_provider=outscale talos_version=v1.13.4 import_bucket=s3-oatest-t3st-outscale-talos-import; do
  hasvar import "$v" && ok "…with -var $v" || bad "the import lacks -var $v: $(line import)"
done
is "into the version's own state" "talos-image-outscale-v1.13.4.tfstate" "$(initkeys)"
is "builds nothing, and ensures no bucket but the state's" "0 1" "$(calls apply) $(acalls 's3api head-bucket')"
for held in "" "module.outscale[0].outscale_image.talos"; do
  OUT="$(OA_STUB_LEFT="$held" PROV=outscale run 2 --import-snapshot snap-fixture1)"; RC=$?
  { [ "$RC" -ne 0 ] && [ "$(calls import)" = 0 ] && grep -qi 'owner' <<<"$OUT"; } \
    && ok "a state without the build (${held:-empty}) is refused: the next plan would replace the snapshot; the way out is the owner's" \
    || bad "an import ran against a state that does not hold the build (rc=$RC): ${OUT:0:200}"
done
OUT="$(run 2 --import-snapshot snap-fixture1)"; RC=$?
[ "$RC" -ne 0 ] && ok "on another provider it is refused" || bad "an Outscale-only import ran on scaleway"
OUT="$(PROV=outscale run 2 --import-snapshot)"; RC=$?
[ "$RC" -ne 0 ] && ok "and without an id" || bad "an import without a snapshot id ran"

echo "--- a pinned image_id is only stale for the version it was built for ---"
printf 'talos_version = "v1.13.4"\nimage_id = "img-old"\n' >"$OA_ENVS_DIR/oa-ovh.tfvars"
OUT="$(OA_STUB_IMAGE_ID=img-new PROV=ovh run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'img-old' <<<"$OUT"; } && ok "a cluster pinning this version and an id the build did not produce is refused" || bad "a stale image_id passed (rc=$RC)"
printf 'talos_version = "v1.13.9"\nimage_id = "img-old"\n' >"$OA_ENVS_DIR/oa-ovh.tfvars"
OUT="$(OA_STUB_IMAGE_ID=img-new PROV=ovh run 2 --ensure)"; RC=$?
is "another version's image keeps its own id: not stale" 0 "$RC"
rm -f "$OA_ENVS_DIR/oa-ovh.tfvars"

echo "--- the scratch files of the three builds carry the version ---"
# Provisioner text is invisible to `tofu test`; a shared scratch name would let one version's
# leftover be read as another's. A path under cache_dir needs the version.
for m in scaleway ovh outscale; do
  f="infrastructure/opentofu/modules/talos-image/$m/main.tf"
  [ -z "$(grep -n 'cache_dir}/' "$f" | grep -v 'talos_version')" ] \
    && ok "$m: every cache_dir path carries talos_version" \
    || bad "$m has an unversioned scratch path: $(grep -n 'cache_dir}/' "$f" | grep -v 'talos_version')"
  # ...and a scratch name moved out of cache_dir escapes the grep above, so the definitions are read too.
  moved="$(grep -nE '^[[:space:]]*(raw_zst|raw_path|qcow2_path)[[:space:]]*=' "$f" | grep -v '"${var.cache_dir}/[^"]*${var.talos_version}' || true)"
  [ -z "$moved" ] && ok "$m: every scratch file is defined under cache_dir, with the version" || bad "$m defines a scratch file outside cache_dir or without the version: $moved"
done

# What a mock cannot see: the provider's lookup fails the whole plan when no OMI carries the name, so it must not come back
# in the module (measured on a real account 2026-10-05; the mocked rung had passed it).
grep -rq 'data "outscale_images"' infrastructure/opentofu/modules/talos-image infrastructure/opentofu/talos-image --include='*.tf' \
  && bad "data.outscale_images is back in the image modules: it fails every plan of a name nobody holds" \
  || ok "no data.outscale_images in the image modules (it errors on an empty answer)"
awk '/variable "talos_version"/,/^}/' "$TFROOT/variables.tf" | grep -Eq '^[[:space:]]*default' \
  && bad "talos_version has a default again: a bare apply would replace the image the state holds" \
  || ok "talos_version has no default"

echo "--- the Taskfile forwards LIST and PRUNE to the script, and \`task test\` runs the image root ---"
grep -q -- '--prune' <<<"$(task -n image-build PROVIDER=ovh PRUNE=1 VERSION=v1.13.4 2>&1)" \
  && grep -q -- '--list' <<<"$(task -n image-build PROVIDER=ovh LIST=1 2>&1)" \
  && ok "task image-build PRUNE=1 / LIST=1 reach talos-image.sh" || bad "the Taskfile does not forward --prune/--list"
grep -Eq 'cd \.\./talos-image .*tofu test' <<<"$(task -n test 2>&1)" \
  && ok "task test runs the image root's tofu test (the image root's own tests are only proven there)" || bad "task test no longer runs the talos-image root"

echo "--- jq is checked up front, not discovered mid-run ---"
mkdir -p "$SB/nojq"
for f in /usr/bin/*; do [ "${f##*/}" = jq ] || ln -sf "$f" "$SB/nojq/${f##*/}"; done
OUT="$(RUN_PATH="$SB:$SB/nojq" run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'jq required' <<<"$OUT"; } && ok "a missing jq stops the run before anything is read or built" || bad "no jq did not stop the script (rc=$RC): ${OUT:0:200}"

echo "--- floors: the stubs really ran (all of the above is vacuous otherwise) ---"
OUT="$(run 2 --ensure)"
[ "$(calls init)" -ge 1 ] && ok "tofu was invoked through the stub ($(wc -l <"$LOG") calls recorded)" \
                          || bad "ZERO tofu calls recorded — the script died before planning, and every assertion above measured nothing"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
