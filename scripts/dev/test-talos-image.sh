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
      push) [ -n "${OA_STUB_PUSH_DROP:-}" ] || cp "$3" "$KF.$k" ;;
      list) printf '%s' "${OA_STUB_LEFT:-}" ;;
    esac ;;
esac
exit 0
STUB
# Logged (prefixed, so it never collides with a tofu subcommand match below) —
# the zero-spend assertions need to see whether aws was ever invoked, not
# just tofu. The listing of the lane bucket answers from OA_STUB_KEYS.
cat >"$SB/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws:%s\n' "$*" >>"$OA_STUB_LOG"
case "$*" in
  *list-objects-v2*) printf '%s\n' "${OA_STUB_KEYS:-None}"; exit "${OA_STUB_LIST_EXIT:-0}" ;;
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
  env PATH="$SB:$PATH" OA_STUB_LOG="$LOG" OA_STUB_PLAN_EXIT="$pe" \
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
    OA_TFVARS="$SB/t.tfvars" \
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

echo "--- a cluster pinning ANOTHER version no longer blocks a build (it used to, #93) ---"
printf 'talos_version = "v1.13.9"\n' >"$PINFILE"
OUT="$(run 2 --ensure)"; RC=$?
is "the build completes" 0 "$RC"
is "and applies" 1 "$(calls apply)"
rm -f "$PINFILE"

echo "--- --list: the versions held, read from the lane bucket, no tofu ---"
OUT="$(OA_STUB_KEYS=$'talos-image-scaleway-v1.13.4.tfstate\ttalos-image-scaleway-v1.14.2.tfstate\ttalos-image-ovh-v1.13.9.tfstate' run 2 --list)"; RC=$?
is "the script completes" 0 "$RC"
{ grep -q 'v1.13.4' <<<"$OUT" && grep -q 'v1.14.2' <<<"$OUT"; } && ok "it names every version of this provider" || bad "a held version is missing: $OUT"
grep -q 'v1.13.9' <<<"$OUT" && bad "it listed another provider's version" || ok "and no other provider's"
is "tofu is never called" 0 "$(calls init)"
OUT="$(OA_STUB_LIST_EXIT=1 run 2 --list)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'cannot list' <<<"$OUT"; } && ok "a listing that fails is an error, not an empty lane" || bad "a failed listing read as 'nothing held' (rc=$RC)"

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
grep -qE '^destroy .*-var talos_version=v1\.13\.4' "$LOG" && ok "of that version only" || bad "the destroy does not carry the version: $(line destroy)"
is "on that version's own state" "talos-image-scaleway-v1.13.4.tfstate" "$(initkeys)"
is "the emptied state object is removed, or --list would still show the version" 1 "$(acalls "s3 rm .*talos-image-scaleway-v1.13.4.tfstate")"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate OA_STUB_LEFT=module.scaleway run 2 --prune)"
{ [ "$(calls destroy)" = 1 ] && [ "$(acalls 's3 rm')" = 0 ]; } \
  && ok "a state that still holds objects (destroy declined) is kept" || bad "a state with objects left was removed, or the destroy did not run"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.14.2.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ]; } && ok "a version no state holds is refused, not destroyed blind" || bad "prune of an unheld version did not refuse (rc=$RC)"
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

OUT="$(OA_STUB_MV_EXIT=1 run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && grep -q 'could not retire' <<<"$OUT"; } && ok "a rename that fails warns with the command and goes on (the copy is done)" || bad "a failed retire was silent or fatal (rc=$RC)"
OUT="$(OA_STUB_PUSH_DROP=1 run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(acalls 's3 mv')" = 0 ] && [ "$(calls apply)" = 0 ]; } \
  && ok "a push that did not land (lineage differs) stops before the legacy object is touched" || bad "the copy was not verified (rc=$RC)"

OUT="$(VER=v1.13.9 run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls 'state push')" = 0 ] && [ "$(acalls 's3 mv')" = 0 ] && [ "$(initkeys)" = "$LEG talos-image-scaleway-v1.13.9.tfstate" ]; } \
  && ok "a build of ANOTHER version leaves the legacy state where it is" || bad "another version's build moved the legacy state (rc=$RC, keys: $(initkeys))"
grep -q 'stays its authority' <<<"$OUT" && ok "and says whose it stays" || bad "it did not say why the legacy state was left"

OUT="$(OA_STUB_KEYS=$'talos-image.tfstate\ttalos-image-scaleway-v1.13.4.tfstate' run 2 --ensure)"
is "an already migrated version does not read the legacy state again" "talos-image-scaleway-v1.13.4.tfstate" "$(initkeys)"
OUT="$(OA_STUB_PULL_FAIL=1 run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls plan)" = 0 ] && [ "$(calls 'state push')" = 0 ]; } && ok "an unreadable legacy state refuses and changes nothing" || bad "an unreadable legacy state was guessed at (rc=$RC)"

for case_ in 'deposed|{"deposed":"1a2b3c4d"}|deposed or tainted' 'tainted|{"status":"tainted"}|deposed or tainted'; do
  IFS='|' read -r what extra want <<<"$case_"
  legacy v1.13.4 talos-scaleway-amd64-v1.13.4 "$extra" >"$SB/legacy-bad.json"
  OUT="$(OA_STUB_LEGACY="$SB/legacy-bad.json" run 2 --ensure)"; RC=$?
  { [ "$RC" -ne 0 ] && grep -q "$want" <<<"$OUT" && [ "$(calls 'state push')" = 0 ] && [ "$(calls plan)" = 0 ] && [ "$(acalls 's3 mv')" = 0 ]; } \
    && ok "a legacy state holding a $what object is refused, whatever its version: nothing moved, no plan" \
    || bad "a $what object was carried over (rc=$RC): ${OUT:0:200}"
done
legacy v1.13.9 talos-scaleway-amd64-v1.13.4 >"$SB/legacy-mixed.json"
OUT="$(OA_STUB_LEGACY="$SB/legacy-mixed.json" run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'v1.13.4 and v1.13.9' <<<"$OUT" && [ "$(calls 'state push')" = 0 ]; } \
  && ok "objects naming two versions (a build moved, its image did not) are refused" || bad "disagreeing objects were migrated (rc=$RC)"
unset OA_STUB_LEGACY OA_STUB_KEYS

echo "--- image-state-version.sh reads the objects of every provider's lane ---"
HELPER=scripts/internal/image-state-version.sh
objs() { # <type> <name> <attr> <value> — one managed object
  jq -n --arg t "$1" --arg n "$2" --arg a "$3" --arg v "$4" '{type:$t,name:$n,mode:"managed",instances:[{attributes:{($a):$v}}]}'
}
st() { jq -s '{resources:.}'; }
is "outscale: the OMI name" v1.14.2 "$({ objs outscale_image talos image_name talos-outscale-amd64-v1.14.2; } | st | "$HELPER")"
is "ovh: the Glance image name" v1.14.2 "$({ objs openstack_images_image_v2 talos name talos-ovh-amd64-v1.14.2; } | st | "$HELPER")"
is "proxmox: the datastore file, which drops the v" v1.14.2 "$({ objs proxmox_virtual_environment_download_file talos file_name talos-1.14.2-nocloud-amd64.img; } | st | "$HELPER")"
is "a pre-release version is read whole" v1.14.0-beta.1 "$({ objs outscale_image talos image_name talos-outscale-amd64-v1.14.0-beta.1; } | st | "$HELPER")"
is "no managed object: nothing to say" "" "$(echo '{"resources":[]}' | "$HELPER")"
OUT="$({ objs outscale_image talos image_name talos-outscale-amd64; } | st | "$HELPER" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q unreadable <<<"$OUT"; } && ok "a name carrying no version is refused, not guessed" || bad "an unreadable name passed (rc=$RC): $OUT"

echo "--- the Outscale same-name refusal: before the import, not after ---"
mkdir -p "$SB/shows"
show() { # <create|noop> <ids...> — a plan as `tofu show -json` prints it
  local act="$1"; shift
  jq -n --arg act "$act" --args '{resource_changes:[{type:"outscale_image", change:{actions:[(if $act == "create" then "create" else "no-op" end)]}}],
        planned_values:{outputs:{omi_name_collisions:{value:$ARGS.positional}}}}' "$@"
}
show create ami-fixture1 >"$SB/shows/taken.json"
OUT="$(OA_STUB_SHOW="$SB/shows/taken.json" PROV=outscale run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "a plan creating the OMI while one holds the name is refused, nothing applied (rc=$RC)" || bad "the collision reached the apply (rc=$RC)"
grep -q 'ami-fixture1' <<<"$OUT" && ok "the message names the OMI" || bad "the message does not name the OMI: $OUT"
grep -qi "owner" <<<"$OUT" && ok "and says deleting an untracked OMI is the owner's, not this script's" || bad "no word on who deletes it"
show noop ami-fixture1 >"$SB/shows/tracked.json"
OUT="$(OA_STUB_SHOW="$SB/shows/tracked.json" PROV=outscale run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls apply)" = 1 ]; } && ok "the lane's own OMI with no replacement planned does not block" || bad "a tracked, unchanged OMI blocked the run (rc=$RC)"
show create >"$SB/shows/free.json"
OUT="$(OA_STUB_SHOW="$SB/shows/free.json" PROV=outscale run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls apply)" = 1 ]; } && ok "a creation with the name free goes ahead" || bad "a free name was refused (rc=$RC)"
OUT="$(OA_STUB_SHOW="$SB/shows/taken.json" OA_STUB_SHOW_EXIT=1 PROV=outscale run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls apply)" = 0 ]; } && ok "a plan that cannot be read is not applied" || bad "an unreadable plan went to the apply (rc=$RC)"
OUT="$(OA_STUB_SHOW="$SB/shows/taken.json" run 2 --ensure)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(calls show)" = 0 ]; } && ok "other providers never ask (the module only exists on Outscale)" || bad "the Outscale gate ran on scaleway (rc=$RC)"

echo "--- --import-snapshot: an import that outlived a failed apply, into THAT version's state ---"
OUT="$(PROV=outscale run 2 --import-snapshot snap-fixture1)"; RC=$?
is "completes" 0 "$RC"
grep -qE "^import .*-var talos_version=v1\.13\.4 .*module\.outscale\[0\]\.outscale_snapshot\.talos snap-fixture1$" "$LOG" \
  && ok "it imports the snapshot at the address that exists, with the version's variables" || bad "wrong import: $(line import)"
is "into the version's own state" "talos-image-outscale-v1.13.4.tfstate" "$(initkeys)"
is "and builds nothing" 0 "$(calls apply)"
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
# Provisioner text is invisible to `tofu test`, and two versions now build in separate states,
# so a shared scratch name would be clobbered silently. A path under cache_dir needs the version.
for m in scaleway ovh outscale; do
  f="infrastructure/opentofu/modules/talos-image/$m/main.tf"
  [ -z "$(grep -n 'cache_dir}/' "$f" | grep -v 'talos_version')" ] \
    && ok "$m: every cache_dir path carries talos_version" \
    || bad "$m has an unversioned scratch path: $(grep -n 'cache_dir}/' "$f" | grep -v 'talos_version')"
done

# The same-name gate is inert if its lookup filters on nothing, and a mock cannot see the filter.
awk '/data "outscale_images" "same_name"/,/^}/' infrastructure/opentofu/modules/talos-image/outscale/main.tf | grep -q 'values = \[var.image_name\]' \
  && ok "the Outscale same-name lookup filters on the OMI name being built" || bad "the same-name lookup no longer filters on var.image_name: the gate would never fire"

echo "--- the Taskfile forwards LIST and PRUNE to the script ---"
grep -q -- '--prune' <<<"$(task -n image-build PROVIDER=ovh PRUNE=1 VERSION=v1.13.4 2>&1)" \
  && grep -q -- '--list' <<<"$(task -n image-build PROVIDER=ovh LIST=1 2>&1)" \
  && ok "task image-build PRUNE=1 / LIST=1 reach talos-image.sh" || bad "the Taskfile does not forward --prune/--list"

echo "--- floors: the stubs really ran (all of the above is vacuous otherwise) ---"
OUT="$(run 2 --ensure)"
[ "$(calls init)" -ge 1 ] && ok "tofu was invoked through the stub ($(wc -l <"$LOG") calls recorded)" \
                          || bad "ZERO tofu calls recorded — the script died before planning, and every assertion above measured nothing"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
