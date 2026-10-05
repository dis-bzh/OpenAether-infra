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
# Real tofu finds no backend outside the image root, and silently pulls nothing there.
[ -f main.tf ] || { echo "stub tofu: no main.tf in $PWD" >&2; exit 99; }
KF="$OA_STUB_LOG.key"   # the state key the backend is inited on, and (KF.<key>) what was pushed to it
case "$1" in
  init) reconf=0 newk=""
        for a in "$@"; do case "$a" in -reconfigure) reconf=1 ;; -backend-config=key=*) newk="${a#-backend-config=key=}" ;; esac; done
        # Real tofu refuses a second init on another key in one .terraform dir unless it is told to reconfigure.
        [ "$reconf" = 1 ] || [ ! -f "$KF" ] || [ "$(cat "$KF")" = "$newk" ] || { echo "stub tofu: Backend configuration changed" >&2; exit 1; }
        [ -z "$newk" ] || printf '%s' "$newk" >"$KF" ;;
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
  destroy) echo "stub: tofu destroy ran"
           case " $* " in *" talos_version=${OA_STUB_DESTROY_FAIL:-none} "*) exit 1 ;; esac ;;  # a version whose destroy fails
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
  # with no terminal to answer a prompt. RUN_DIR runs it from another checkout, RUN_UNSET drops one variable.
  cd "${RUN_DIR:-.}" || return 1
  env ${RUN_UNSET:+-u "$RUN_UNSET"} PATH="${RUN_PATH:-$SB:$PATH}" OA_STUB_LOG="$LOG" OA_STUB_PLAN_EXIT="$pe" TMPDIR="$SB/tmp" \
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
# Twice: with the default version, and with none (what the Taskfile renders for RETAIN=1, which takes no version): the
# first is also refused by --retain's no-version rule, so only the second proves the exclusivity itself.
for combo in '--list --prune' '--prune --list' '--ensure --list' '--ensure --prune' '--retain --prune' '--prune --retain' '--list --retain' '--retain --list' '--ensure --retain'; do
  for ver in v1.13.4 none; do
    # shellcheck disable=SC2086  # the combo IS several arguments
    OUT="$(VER=$ver run 2 $combo)"; RC=$?
    { [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; } && ok "'$combo' (version: $ver) is refused before any call (rc=$RC)" || bad "'$combo' (version: $ver) ran: $(head -c 200 "$LOG")"
    case "$combo" in *--ensure*) ;; *) grep -q 'exclusive' <<<"$OUT" || bad "'$combo' (version: $ver) was refused for another reason than exclusivity: ${OUT:0:160}" ;; esac
  done
done
OUT="$(PROV=outscale run 2 --import-snapshot snap-fixture1 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; } && ok "'--import-snapshot <id> --prune' is refused too" || bad "an import and a prune ran together"
OUT="$(PROV=outscale run 2 --import-snapshot --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; } && ok "a flag is not taken for a snapshot id" || bad "--prune was read as the snapshot id"
OUT="$(VER=none PROV=outscale run 2 --import-snapshot snap-fixture1 --retain)"; RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$LOG" ] && grep -q 'exclusive' <<<"$OUT"; } && ok "'--import-snapshot <id> --retain' is refused too, by exclusivity" || bad "an import and a retention ran together: ${OUT:0:160}"
OUT="$(run 2 --retain)"; RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$LOG" ] && grep -q 'takes no version' <<<"$OUT"; } \
  && ok "--retain with a version is refused before any call: it would read as 'retain around it'" || bad "--retain accepted a version (rc=$RC): ${OUT:0:200}"

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
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate OA_STUB_LEFT=module.scaleway run 2 --prune)"; RC=$?
{ [ "$(calls destroy)" = 1 ] && [ "$(acalls 's3 rm')" = 0 ]; } \
  && ok "a state that still holds objects (destroy declined) is kept" || bad "a state with objects left was removed, or the destroy did not run"
{ [ "$RC" -ne 0 ] && grep -q 'still lists objects' <<<"$OUT"; } \
  && ok "…and that is a failed prune, not a success (rc=$RC): a caller must not report it destroyed" || bad "a prune that left its state exited $RC: ${OUT:0:200}"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.14.2.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ]; } && ok "a version no state holds is refused, not destroyed blind" || bad "prune of an unheld version did not refuse (rc=$RC)"
OUT="$(OA_STUB_HEAD=404 run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && [ "$(acalls 's3 mb')" = 0 ] && [ "$(calls destroy)" = 0 ]; } \
  && ok "a lane with no bucket has nothing to prune, and none is created" || bad "prune on a missing bucket created it or went on (rc=$RC)"

# What a cluster names is not only its talos_version: an image_name override is looked up at every plan.
printf 'talos_version = "v1.13.9"\nnode_distribution = {\n  scaleway = {\n    image_name = "talos-scaleway-amd64-v1.13.4"\n  }\n}\n' >"$PINFILE"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q "${PINFILE##*/}" <<<"$OUT" && [ ! -s "$LOG" ]; } \
  && ok "a version a tfvars still names through image_name is refused too, before any call" || bad "prune destroyed an image_name-named version (rc=$RC, calls: $(head -c 100 "$LOG"))"
printf 'talos_version = "v1.13.9"\nimage_id = "img-0123"\n' >"$PINFILE"
OUT="$(OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'sets image_id' <<<"$OUT" && [ ! -s "$LOG" ]; } \
  && ok "an image_id names no version: it refuses every prune, naming the file" || bad "prune went ahead past an image_id (rc=$RC)"
rm -f "$PINFILE"
OUT="$(OA_ENVS_DIR=/nonexistent/envs OA_STUB_KEYS=talos-image-scaleway-v1.13.4.tfstate run 2 --prune)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'no envs directory' <<<"$OUT" && [ ! -s "$LOG" ]; } \
  && ok "no envs directory: pins unreadable, nothing destroyed" || bad "prune ran with no envs directory to read (rc=$RC)"

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

echo "--- --retain: N, the version a cluster is on, and the one below it stay; every other one is pruned, lowest first ---"
keys() { # <versions...> — the lane's state keys for them, tab-separated, as the listing returns them
  local acc="" v
  for v in "$@"; do acc+="${acc:+$'\t'}talos-image-${PROV:-scaleway}-$v.tfstate"; done
  printf '%s' "$acc"
}
destroyed() { sed -nE 's/^destroy .*-var talos_version=([^ ]+).*/\1/p' "$LOG" | paste -sd' '; }  # in the order they ran
# The cluster (cur-<provider>.tfvars) pins PINV, default v1.14.2: retention ranks around the version a cluster is ON.
retain_raw() { # <raw key list>: OUT and RC of one run
  printf 'talos_version = "%s"\n' "${PINV:-v1.14.2}" >"$OA_ENVS_DIR/cur-${PROV:-scaleway}.tfvars"
  OUT="$(OA_STUB_KEYS="$1" VER=none run 2 --retain)"; RC=$?
}
retain() { # <versions...>: the cluster pins the highest of them unless PINV says otherwise
  local top; top="$(printf '%s\n' "$@" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
  PINV="${PINV:-${top:-v1.14.2}}" retain_raw "$(keys "$@")"
}
lineno() { grep -n -m1 -- "$1" <<<"$OUT" | cut -d: -f1; }

retain v1.14.1 v1.14.2 v1.14.3
is "three held: the run completes" 0 "$RC"
is "only the lowest is destroyed" v1.14.1 "$(destroyed)"
is "through --prune: one destroy, on that version's own state" "1 talos-image-scaleway-v1.14.1.tfstate" "$(calls destroy) $(initkeys)"
is "and only that version's state object is removed" 1 "$(acalls 's3 rm')"
is "the one removed is the destroyed version's" 1 "$(acalls "s3 rm .*talos-image-scaleway-v1.14.1.tfstate")"
is "no bucket created, nothing built" "0 0 0" "$(acalls 's3 mb') $(calls plan) $(calls apply)"
grep -q 'the newest pin is v1.14.3; keeping the 2 highest at or below it: v1.14.2 v1.14.3' <<<"$OUT" && ok "it names the pin it ranks around and the two it keeps" || bad "the kept versions are not named: $OUT"
w="$(lineno 'will destroy, lowest first: v1.14.1')"; d="$(lineno 'stub: tofu destroy ran')"
{ [ -n "$w" ] && [ -n "$d" ] && [ "$w" -lt "$d" ]; } && ok "it says what it will destroy BEFORE destroying" || bad "the announcement is at line ${w:-none}, the destroy at ${d:-none}"

for held in "" "v1.14.2" "v1.14.1 v1.14.2"; do
  # shellcheck disable=SC2086  # the list IS several arguments
  retain $held
  { [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && [ "$(calls init)" = 0 ] && grep -q 'nothing to destroy' <<<"$OUT"; } \
    && ok "holding '${held:-nothing}': a no-op that says so, and no state is even opened" || bad "holding '${held:-nothing}' (rc=$RC, destroyed '$(destroyed)', inits $(calls init)): ${OUT:0:200}"
done

retain v1.14.3 v1.13.4 v1.14.2 v1.14.1  # the order a listing returns is not the order of the versions
is "four held, listed out of order: the two lowest, lowest first" "v1.13.4 v1.14.1" "$(destroyed)"
is "…each on its own state, one at a time" "talos-image-scaleway-v1.13.4.tfstate talos-image-scaleway-v1.14.1.tfstate" "$(initkeys)"
is "…and each emptied state object removed" 2 "$(acalls 's3 rm')"

# What S3 lists is alphabetical, and alphabetical is the wrong order: v1.9.0 would outrank v1.14.0.
retain v1.14.0 v1.14.10 v1.14.9 v1.9.0
is "v1.9.0 ranks below v1.14.0, and v1.14.9 below v1.14.10" "v1.9.0 v1.14.0" "$(destroyed)"
retain v1.14.10 v1.14.11 v1.14.9
is "v1.14.9 is lower than v1.14.10, not higher" v1.14.9 "$(destroyed)"
retain v1.14.10 v1.14.8 v1.14.9
is "…and v1.14.8 is the lowest of 8, 9 and 10" v1.14.8 "$(destroyed)"

echo "--- --retain is relative to the cluster: a version above its pin never takes N-1's place ---"
PINV=v1.14.2 retain v1.14.1 v1.14.2 v1.14.3
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q 'above every pin.*: v1.14.3' <<<"$OUT" && grep -q 'keeping the 2 highest at or below it: v1.14.1 v1.14.2' <<<"$OUT"; } \
  && ok "cluster on v1.14.2, a v1.14.3 held (built ahead, or a bump reverted): N-1 stays, v1.14.3 is kept and named" || bad "a version above the pin evicted N-1 (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
PINV=v1.14.2 retain v1.14.0 v1.14.1 v1.14.2 v1.15.0
is "…and what really is older than N-1 still goes" v1.14.0 "$(destroyed)"
PINV=v1.14.3 retain v1.14.0 v1.14.1 v1.14.2
is "a pin above everything held (its image not built yet): the two highest below it stay" v1.14.0 "$(destroyed)"
PINV=v1.14.3 retain v1.14.1 v1.14.2
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ]; } && ok "…and two held below an unbuilt pin lose nothing" || bad "a version was destroyed below an unbuilt pin (destroyed '$(destroyed)')"

echo "--- --retain and pre-releases: a pre-release is below its own release, and above nothing it is older than ---"
PINV=v1.14.3 retain v1.14.1 v1.14.2 v1.14.3 v1.15.0-rc.1
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.14.1 ] && grep -q 'above every pin.*: v1.15.0-rc.1' <<<"$OUT"; } \
  && ok "a pre-release above the pin is kept and named, and does not count as one of the two" || bad "pre-release above the pin (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
grep -q 'integer expression' <<<"$OUT" && bad "a pre-release reached oa_semver_lt, which cannot read it" || ok "…without handing it to oa_semver_lt, which cannot order it"
retain v1.14.3-rc.1 v1.14.3 v1.14.4 v1.14.5
is "the pre-release of a held version is older than it: both go, the pre-release first" "v1.14.3-rc.1 v1.14.3" "$(destroyed)"
retain v1.15.0-rc.1 v1.15.0-rc.2 v1.15.0 v1.15.1
is "two release candidates under the two kept versions are destroyed, not kept forever" "v1.15.0-rc.1 v1.15.0-rc.2" "$(destroyed)"
PINV=v1.14.3 retain v1.14.2 v1.14.3 v1.15.0-rc.1
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ]; } && ok "with two ranked versions a pre-release above them takes no place and nothing goes" || bad "a pre-release counted as a kept version (destroyed '$(destroyed)')"
PINV=v1.15.0-rc.10 retain v1.15.0-rc.9 v1.15.0-rc.10 v1.15.0-rc.2
is "release candidates order as version strings: rc.2 < rc.9 < rc.10" v1.15.0-rc.2 "$(destroyed)"
PINV=v1.15.0-rc.2 retain v1.15.0-rc.1 v1.15.0-rc.2 v1.15.0
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q 'above every pin.*: v1.15.0' <<<"$OUT"; } \
  && ok "a cluster pinned on a release candidate: its release is above it, kept and named" || bad "a pre-release pin was not an N (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
PINV=v1.14.2 retain v1.14.1 v1.14.2 vfoo
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q 'not a version so not ranked: vfoo' <<<"$OUT"; } && ok "a key that is no version is kept and named" || bad "an odd key was ranked or destroyed (rc=$RC): ${OUT:0:200}"

echo "--- --retain never destroys what a tfvars still names ---"
OLD="$OA_ENVS_DIR/old-scaleway.tfvars"
printf 'talos_version = "v1.13.4"\n' >"$OLD"
retain v1.13.4 v1.14.1 v1.14.2 v1.14.3
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.14.1 ] && [ "$(initkeys)" = talos-image-scaleway-v1.14.1.tfstate ]; } \
  && ok "a version a tfvars pins is not destroyed, nor its state opened; the others still go" || bad "a pinned version was touched (rc=$RC, destroyed '$(destroyed)', keys $(initkeys))"
grep -q "kept, named by a tfvars: v1.13.4 (${OLD##*/})" <<<"$OUT" && ok "and it is named, with the file that pins it" || bad "the pinned version is not named: $OUT"
retain v1.13.4 v1.14.1 v1.14.2
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q 'named by a tfvars: v1.13.4' <<<"$OUT" && grep -q 'nothing to destroy' <<<"$OUT"; } \
  && ok "when the only old version is pinned, the run is a no-op and says why" || bad "a pinned lowest version was destroyed or unmentioned (rc=$RC)"
printf 'talos_version = "v1.14.3"\nnode_distribution = {\n  scaleway = {\n    image_name = "talos-scaleway-amd64-v1.14.1"   # a node on the older image\n  }\n}\n' >"$OLD"
PINV=v1.14.4 retain v1.14.1 v1.14.2 v1.14.3 v1.14.4
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.14.2 ] && grep -q "named by a tfvars: v1.14.1 (${OLD##*/})" <<<"$OUT"; } \
  && ok "an image_name override is a pin too: the cluster looks that name up at every plan" || bad "an image_name-named version was destroyed or unnamed (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
printf 'talos_version = "v1.14.3"\nnode_distribution = { scaleway = { image_name = "talos-scaleway-amd64-v1.14.1" } }\n' >"$OLD"
PINV=v1.14.4 retain v1.14.1 v1.14.2 v1.14.3 v1.14.4
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.14.2 ] && grep -q "named by a tfvars: v1.14.1 (${OLD##*/})" <<<"$OUT"; } \
  && ok "…written on one line as well" || bad "a one-line image_name override was missed (rc=$RC, destroyed '$(destroyed)')"
printf 'talos_version = "v1.14.2"\n# image_name = "talos-scaleway-amd64-v1.14.1"\nimage_name = "Ubuntu-24.04-2025.01"\n' >"$OLD"
PINV=v1.14.4 retain v1.14.1 v1.14.2 v1.14.3 v1.14.4
is "a commented name, and a name that is no lane image, pin nothing" "v1.14.1" "$(destroyed)"
printf 'talos_version = "v1.14.2"\nnode_distribution = { scaleway = { image_name = "talos-scaleway-amd64-v1.14.9" } }\n' >"$OLD"
PINV=v1.14.2 retain v1.14.1 v1.14.2 v1.14.9
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q 'the newest pin is v1.14.2;' <<<"$OUT"; } \
  && ok "N is the version a cluster is ON: an override above its talos_version does not move it" || bad "an image_name moved N (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
printf 'cluster_name = "inherits-the-default"\n' >"$OLD"
DEF="$(scripts/internal/talos-version.sh)"
PINV=v99.0.2 retain "$DEF" v99.0.1 v99.0.2 v99.0.3
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q "named by a tfvars: ${DEF} (${OLD##*/})" <<<"$OUT"; } \
  && ok "a tfvars that pins nothing is on the variables.tf default, and that image stays" || bad "an inherited pin was not read (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
printf 'talos_version = "v1.14.10"\n' >"$OLD"
PINV=v1.14.10 retain v1.14.1 v1.14.2 v1.14.3 v1.14.10
is "a pin on v1.14.10 does not protect v1.14.1: a pin is a whole version, not a prefix" "v1.14.1 v1.14.2" "$(destroyed)"
rm -f "$OLD"
printf 'talos_version = "v1.14.1"\n' >"$OA_ENVS_DIR/oa-ovh.tfvars"
retain v1.14.1 v1.14.2 v1.14.3
is "another provider's pin does not protect this provider's image" v1.14.1 "$(destroyed)"
rm -f "$OA_ENVS_DIR/oa-ovh.tfvars"

PROV=ovh retain v1.14.1 v1.14.2 v1.14.3
{ [ "$(destroyed)" = v1.14.1 ] && hasvar destroy target_provider=ovh && [ "$(initkeys)" = talos-image-ovh-v1.14.1.tfstate ]; } \
  && ok "the provider reaches every --prune it runs" || bad "the prune did not carry the provider: $(line destroy) / $(initkeys)"
printf 'talos_version = "v1.14.3"\ntalos_image_file_id = "local:iso/talos-1.14.1-nocloud-amd64.img"\n' >"$OA_ENVS_DIR/old-proxmox.tfvars"
PROXMOX_VE_ENDPOINT=https://pve.invalid:8006 PROXMOX_VE_API_TOKEN=stub PROXMOX_AWS_ACCESS_KEY_ID=STUB-AK PROXMOX_AWS_SECRET_ACCESS_KEY=STUB-SK \
  PROV=proxmox retain v1.14.1 v1.14.2 v1.14.3
{ [ "$RC" -eq 0 ] && [ -z "$(destroyed)" ] && grep -q "named by a tfvars: v1.14.1 (old-proxmox.tfvars)" <<<"$OUT"; } \
  && ok "Proxmox: a talos_image_file_id names its image file, so its version stays" || bad "a Proxmox file id was not read (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
rm -f "$OA_ENVS_DIR/old-proxmox.tfvars" "$OA_ENVS_DIR/cur-proxmox.tfvars"

echo "--- --retain decides on evidence, never on its absence ---"
lane="$(keys v1.13.4 v1.14.2 v1.14.3)"
refused() { # <label> — the last run was refused before it destroyed anything, and said why (OUT, RC, and the pattern in $WHY)
  { [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ] && [ "$(acalls 's3 rm')" = 0 ] && grep -q "$WHY" <<<"$OUT"; } \
    && ok "$1" || bad "$1 — rc=$RC, destroys $(calls destroy), wanted '$WHY': ${OUT:0:300}"
}
printf 'talos_version = "v1.14.3"\n' >"$OA_ENVS_DIR/cur-scaleway.tfvars"
OUT="$(OA_ENVS_DIR=/nonexistent/envs OA_STUB_KEYS="$lane" VER=none run 2 --retain)"; RC=$?
WHY='no envs directory' refused "no envs directory: nothing is destroyed"
rm -f "$OA_ENVS_DIR/cur-scaleway.tfvars"
OUT="$(OA_STUB_KEYS="$lane" VER=none run 2 --retain)"; RC=$?
WHY='nothing says which version a cluster is on' refused "no envs/*-scaleway.tfvars (another provider's file does not count): nothing is destroyed"
printf 'talos_version = "latest"\n' >"$OA_ENVS_DIR/cur-scaleway.tfvars"
OUT="$(OA_STUB_KEYS="$lane" VER=none run 2 --retain)"; RC=$?
WHY='no talos_version pin is a vMAJOR.MINOR.PATCH' refused "no pin that reads as a version (latest): there is no N, so nothing is destroyed"
printf 'talos_version = "v1.14.3"\nimage_id = "img-0123"\n' >"$OA_ENVS_DIR/cur-scaleway.tfvars"
OUT="$(OA_STUB_KEYS="$lane" VER=none run 2 --retain)"; RC=$?
WHY='sets image_id' refused "a tfvars that sets image_id: an id names no version, so nothing is destroyed"
grep -q 'cur-scaleway.tfvars' <<<"$OUT" && ok "…and the file is named" || bad "the image_id refusal names no file: ${OUT:0:200}"
printf 'talos_version = "v1.14.3"\n# image_id = "img-0123"\nimage_id = null\nbastion_image_id = "Ubuntu 22.04"\n' >"$OA_ENVS_DIR/cur-scaleway.tfvars"
OUT="$(OA_STUB_KEYS="$lane" VER=none run 2 --retain)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.13.4 ]; } \
  && ok "a commented image_id, image_id = null and bastion_image_id are no image pin: retention runs" || bad "a non-pin refused or misled the run (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
printf 'talos_version = "v1.14.3"\n' >"$OA_ENVS_DIR/cur-scaleway.tfvars"
printf 'talos_version = "v1.13.4"\n' >"$OA_ENVS_DIR/old-scaleway.tfvars"; chmod 000 "$OA_ENVS_DIR/old-scaleway.tfvars"
if [ -r "$OA_ENVS_DIR/old-scaleway.tfvars" ]; then
  echo "  - skipped: an unreadable file is readable to this user (root)"
else
  OUT="$(OA_STUB_KEYS="$lane" VER=none run 2 --retain)"; RC=$?
  WHY='cannot read old-scaleway.tfvars' refused "a tfvars that cannot be read: what it pins is unknown, so nothing is destroyed"
fi
chmod 600 "$OA_ENVS_DIR/old-scaleway.tfvars"
rel="$(realpath --relative-to="$PWD" "$OA_ENVS_DIR")"
OUT="$(OA_ENVS_DIR="$rel" OA_STUB_KEYS="$(keys v1.13.4 v1.14.1 v1.14.2 v1.14.3)" VER=none run 2 --retain)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.14.1 ] && grep -q 'named by a tfvars: v1.13.4 (old-scaleway.tfvars)' <<<"$OUT"; } \
  && ok "a relative OA_ENVS_DIR still finds the pins after the script moves to the image root" \
  || bad "a relative OA_ENVS_DIR blinded the pin scan (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
rm -f "$OA_ENVS_DIR/old-scaleway.tfvars" "$OA_ENVS_DIR/cur-scaleway.tfvars"
# The way the Taskfile runs it: a relative script path and the default envs directory, which the script resolves from its
# own location. A copy of the layout, so no real gitignored tfvars is read or written (#191).
REPO="$SB/repo"; mkdir -p "$REPO/scripts/bootstrap" "$REPO/infrastructure/opentofu/cluster/envs"
cp "$SCRIPT" "$REPO/scripts/bootstrap/"
ln -s "$PWD/scripts/internal" "$PWD/scripts/lib" "$REPO/scripts/"
ln -s "$PWD/$TFROOT" "$REPO/infrastructure/opentofu/talos-image"
cp infrastructure/opentofu/cluster/variables.tf "$REPO/infrastructure/opentofu/cluster/"
printf 'talos_version = "v1.14.3"\n' >"$REPO/infrastructure/opentofu/cluster/envs/cur-scaleway.tfvars"
printf 'talos_version = "v1.13.4"\n' >"$REPO/infrastructure/opentofu/cluster/envs/old-scaleway.tfvars"
OUT="$(RUN_DIR="$REPO" RUN_UNSET=OA_ENVS_DIR OA_STUB_KEYS="$(keys v1.13.4 v1.14.1 v1.14.2 v1.14.3)" VER=none run 2 --retain)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.14.1 ] && grep -q 'named by a tfvars: v1.13.4 (old-scaleway.tfvars)' <<<"$OUT"; } \
  && ok "run from a checkout by a relative path, with the default envs directory: the pins are found, the pinned version kept" \
  || bad "the default envs directory was blind after the cd (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
rm -rf "$REPO"

echo "--- --retain and the pre-#69 single state ---"
legacy v1.13.4 talos-scaleway-amd64-v1.13.4 >"$SB/legacy.json"
export OA_STUB_LEGACY="$SB/legacy.json"
retain_raw "$LEG"$'\t'"$(keys v1.14.1 v1.14.2)"
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.13.4 ] && [ "$(calls 'state push')" = 1 ] && [ "$(acalls 's3 mv')" = 1 ]; } \
  && ok "the version only the legacy state holds is the oldest: copied to its own key, then destroyed, like --prune" || bad "legacy-held oldest (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
awk '/^state push/ {p=NR} /^destroy/ {d=NR} END {exit !(p && d && p<d)}' "$LOG" && ok "…in that order" || bad "the destroy did not follow the copy: $(tr '\n' '|' <"$LOG")"
is "the decrypted copy of the legacy state is gone after the run" 0 "$(find "$SB/tmp" -type f | wc -l)"
legacy v1.14.2 talos-scaleway-amd64-v1.14.2 >"$SB/legacy-top.json"
OA_STUB_LEGACY="$SB/legacy-top.json" retain_raw "$LEG"$'\t'"$(keys v1.13.4 v1.14.1)"
{ [ "$RC" -eq 0 ] && [ "$(destroyed)" = v1.13.4 ] && [ "$(calls 'state push')" = 0 ] && [ "$(acalls 's3 mv')" = 0 ] \
    && grep -q 'keeping the 2 highest at or below it: v1.14.1 v1.14.2' <<<"$OUT"; } \
  && ok "the version the legacy state holds counts, and when it is among the two highest the legacy object is left alone" || bad "legacy-held highest (rc=$RC, destroyed '$(destroyed)'): ${OUT:0:300}"
retain_raw "$LEG"$'\t'"$(keys v1.13.4 v1.14.1 v1.14.2)"
is "a version held by the legacy state AND by its own key is one version, destroyed once" v1.13.4 "$(destroyed)"
legacy v1.13.4 talos-scaleway-amd64-v1.13.4 '{"status":"tainted"}' >"$SB/legacy-bad.json"
OA_STUB_LEGACY="$SB/legacy-bad.json" retain_raw "$LEG"$'\t'"$(keys v1.14.1 v1.14.2)"
{ [ "$RC" -ne 0 ] && [ -z "$(destroyed)" ] && grep -q 'not clean' <<<"$OUT" && grep -q 'pruning v1.13.4 failed' <<<"$OUT"; } \
  && ok "a half-finished legacy object is refused by the prune it goes through, which the run names" || bad "a tainted legacy state was pruned or the failure is unnamed (rc=$RC): ${OUT:0:300}"
OA_STUB_PULL_FAIL=1 retain_raw "$LEG"$'\t'"$(keys v1.14.1 v1.14.2 v1.14.3)"
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ]; } && ok "a legacy state that cannot be read: what is held is unknown, nothing is destroyed" || bad "an unreadable legacy state was guessed at (rc=$RC)"
legacy v1.13.4 talos-scaleway-amd64 >"$SB/legacy-blind.json"
OA_STUB_LEGACY="$SB/legacy-blind.json" retain_raw "$LEG"$'\t'"$(keys v1.14.1 v1.14.2 v1.14.3)"
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ] && grep -q 'no readable version' <<<"$OUT"; } \
  && ok "a legacy state naming no version: nothing is destroyed" || bad "a legacy state of unknown content was passed (rc=$RC)"
legacy v1.13.9 talos-scaleway-amd64-v1.13.4 >"$SB/legacy-mixed.json"
OA_STUB_LEGACY="$SB/legacy-mixed.json" retain_raw "$LEG"$'\t'"$(keys v1.14.1 v1.14.2)"
{ [ "$RC" -ne 0 ] && [ -z "$(destroyed)" ] && grep -q 'Not attempted: v1.13.9' <<<"$OUT"; } \
  && ok "a legacy state naming two versions holds both: the first refusal stops the run, the other is not attempted" || bad "a mixed legacy state was pruned (rc=$RC): ${OUT:0:300}"
unset OA_STUB_LEGACY

echo "--- --retain: a prune that fails stops the run, naming it and what already went ---"
OA_STUB_DESTROY_FAIL=v1.13.4 retain v1.13.3 v1.13.4 v1.14.1 v1.14.2 v1.14.3
[ "$RC" -ne 0 ] && ok "a destroy that fails fails the run (exit $RC)" || bad "a failed prune exited 0"
is "it stopped there: v1.13.3 went, v1.13.4 failed, v1.14.1 was never tried" "v1.13.3 v1.13.4" "$(destroyed)"
grep -q 'pruning v1.13.4 failed. Destroyed before it: v1.13.3. Not attempted: v1.14.1.' <<<"$OUT" \
  && ok "and says so: the failed version, the earlier destroy, what is left" || bad "the failure report is wrong: $OUT"
is "the failed version's state object stays (it still holds what the destroy did not remove)" 1 "$(acalls 's3 rm')"
OA_STUB_DESTROY_FAIL=v1.13.4 retain v1.13.4 v1.14.1 v1.14.2 v1.14.3
{ [ "$RC" -ne 0 ] && grep -q 'Destroyed before it: none. Not attempted: v1.14.1.' <<<"$OUT"; } \
  && ok "the first one failing reports nothing destroyed" || bad "a first failure is misreported (rc=$RC): $OUT"
OA_STUB_LEFT=module.scaleway retain v1.14.1 v1.14.2 v1.14.3
{ [ "$RC" -ne 0 ] && grep -q 'pruning v1.14.1 failed' <<<"$OUT" && ! grep -q 'destroyed:' <<<"$OUT" && [ "$(acalls 's3 rm')" = 0 ]; } \
  && ok "a destroy that exits 0 but leaves objects in the state is not reported destroyed, and the key stays listed" \
  || bad "a prune that left its state counted as destroyed (rc=$RC): ${OUT:0:300}"

echo "--- --retain reads the lane without creating anything ---"
OA_STUB_HEAD=404 retain_raw ""
{ [ "$RC" -eq 0 ] && grep -q 'nothing to retain' <<<"$OUT" && [ "$(acalls 's3 mb')" = 0 ] && [ "$(calls init)" = 0 ] && [ "$(acalls 's3api list-objects-v2')" = 0 ]; } \
  && ok "no state bucket: nothing held, none created, nothing listed" || bad "--retain on a missing bucket created it or went on (rc=$RC): $OUT"
OA_STUB_HEAD=403 retain_raw ""
{ [ "$RC" -ne 0 ] && [ "$(acalls 's3 mb')" = 0 ] && [ "$(calls destroy)" = 0 ]; } && ok "a bucket that cannot be reached (403) is an error, not an empty lane" || bad "a 403 read as nothing held (rc=$RC)"
OA_STUB_LIST_EXIT=1 retain v1.14.1 v1.14.2 v1.14.3
{ [ "$RC" -ne 0 ] && [ "$(calls destroy)" = 0 ] && grep -q 'cannot list' <<<"$OUT"; } \
  && ok "a listing that fails is not an empty one: nothing is destroyed on a guess" || bad "a failed listing was read as the lane (rc=$RC)"
rm -f "$OA_ENVS_DIR"/*.tfvars

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
is "task image-build RETAIN=1 passes --retain and no version" "OA_ROLE=management ./scripts/bootstrap/talos-image.sh ovh --retain" \
   "$(task -n image-build PROVIDER=ovh RETAIN=1 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | sed -nE 's/^task: \[image-build\] //p')"
grep -q -- 'ovh v1.13.4 --retain' <<<"$(task -n image-build PROVIDER=ovh RETAIN=1 VERSION=v1.13.4 2>&1)" \
  && ok "a typed VERSION still reaches the script, which refuses it" || bad "a VERSION given with RETAIN=1 was dropped silently"
grep -q -- '--list --retain' <<<"$(task -n image-build PROVIDER=ovh LIST=1 RETAIN=1 2>&1)" \
  && ok "LIST=1 RETAIN=1 forwards both flags, and the script's exclusivity refuses them" || bad "the Taskfile hid one of two modes"
# RETAIN arms a destroy that needs no version, so only 1 or true arms it: RETAIN=0 is a plain build, not a retention.
for r in 0 false no ""; do
  grep -q -- '--retain' <<<"$(task -n image-build PROVIDER=ovh RETAIN=$r 2>&1)" \
    && bad "RETAIN='$r' armed the retention" || ok "RETAIN='$r' does not arm the retention"
done
grep -q -- 'ovh --retain' <<<"$(task -n image-build PROVIDER=ovh RETAIN=true 2>&1)" \
  && ok "RETAIN=true does" || bad "RETAIN=true did not arm the retention"
grep -Eq 'cd \.\./talos-image .*tofu test' <<<"$(task -n test 2>&1)" \
  && ok "task test runs the image root's tofu test (the image root's own tests are only proven there)" || bad "task test no longer runs the talos-image root"

echo "--- jq is checked up front, not discovered mid-run ---"
mkdir -p "$SB/nojq"
for f in /usr/bin/*; do [ "${f##*/}" = jq ] || ln -sf "$f" "$SB/nojq/${f##*/}"; done
OUT="$(RUN_PATH="$SB:$SB/nojq" run 2 --ensure)"; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'jq required' <<<"$OUT"; } && ok "a missing jq stops the run before anything is read or built" || bad "no jq did not stop the script (rc=$RC): ${OUT:0:200}"

echo "--- the image-build task hands its ROLE to the script: the lane's bucket namespace is that role's tfvars ---"
# Without it a failover cluster looked for management-<provider>.tfvars, absent on the machine that has only the failover file,
# and fell back to the shared 'openaether' namespace, a bucket name another customer may own.
grep -q 'OA_ROLE=failover ./scripts/bootstrap/talos-image.sh scaleway' <<<"$(task -n image-build PROVIDER=scaleway ROLE=failover VERSION=v1.14.2 2>&1)" \
  && ok "task image-build ROLE=failover runs the script with OA_ROLE=failover" || bad "the image-build task does not pass ROLE to the script"

echo "--- floors: the stubs really ran (all of the above is vacuous otherwise) ---"
OUT="$(run 2 --ensure)"
[ "$(calls init)" -ge 1 ] && ok "tofu was invoked through the stub ($(wc -l <"$LOG") calls recorded)" \
                          || bad "ZERO tofu calls recorded — the script died before planning, and every assertion above measured nothing"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
