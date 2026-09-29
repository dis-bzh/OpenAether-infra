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
# #93's guard scans an envs dir: a sandbox one, so a real gitignored tfvars in
# this checkout can neither fail these cases nor be written next to (#191).
export OA_ENVS_DIR="$SB/envs"; mkdir -p "$OA_ENVS_DIR"
FIXTURE93="$OA_ENVS_DIR/oa93-scaleway.tfvars"
trap 'rm -rf "$SB"; rm -f "$TFROOT"/talos-image-scaleway.tfplan' EXIT

# The schematic gate calls the Image Factory before anything else and refuses a
# build when the live id differs from the cluster pin. Offline, the stub answers
# with the pin itself, so the gate passes and the applies below are what is
# being measured. (Its own drift case belongs to the gate, not to this file.)
PIN="$(awk '/variable "talos_installer_schematic_id"/,/^}/' infrastructure/opentofu/cluster/variables.tf \
       | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([0-9a-f]+)".*/\1/p' | head -1)"

cat >"$SB/tofu" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OA_STUB_LOG"
case "$1" in
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
  output) case "$*" in *image_name*) echo oa-talos-stub ;; esac ;;
esac
exit 0
STUB
# Logged (prefixed, so it never collides with a tofu subcommand match below) —
# #93's zero-spend assertion needs to see whether aws was ever invoked, not
# just tofu.
cat >"$SB/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws:%s\n' "$*" >>"$OA_STUB_LOG"
exit 0
STUB
printf '#!/usr/bin/env bash\nprintf %s "{\\"id\\":\\"%s\\"}"\n' '%s' "${PIN:-deadbeef}" >"$SB/curl"
chmod +x "$SB/tofu" "$SB/aws" "$SB/curl"

printf 'cluster_name  = "oatest"\nbucket_suffix = "t3st"\n' >"$SB/t.tfvars"

# `OUT="$(run …)"; RC=$?` — the exit status has to be read from the assignment.
# Setting it inside run() sets it in the substitution's subshell, where nothing
# can see it, and every "the script completes" below reads a stale 0 instead.
run() { # <plan-exit> [script args...] — prints the script's output, exits as it did
  : >"$LOG"
  rm -f "$TFROOT"/talos-image-scaleway.tfplan
  local pe="$1"; shift
  # </dev/null is the point of the whole exercise: this is the lane that runs
  # with no terminal to answer a prompt.
  env PATH="$SB:$PATH" OA_STUB_LOG="$LOG" OA_STUB_PLAN_EXIT="$pe" \
      TALOS_IMAGE_ALLOW_OFFLINE="${TALOS_IMAGE_ALLOW_OFFLINE:-0}" \
      OA_TFVARS="$SB/t.tfvars" \
      SCW_AWS_ACCESS_KEY_ID=STUB-AK SCW_AWS_SECRET_ACCESS_KEY=STUB-SK \
      "$SCRIPT" scaleway v1.13.4 "$@" </dev/null 2>&1
}
calls() { grep -c "^$1 " "$LOG"; }          # how many `tofu <subcommand>` calls
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

echo "--- #93: refuses when another cluster's tfvars still pins a different talos_version ---"
printf 'talos_version = "v1.13.9"\n' >"$FIXTURE93"
OUT="$(run 2 --ensure)"; RC=$?
[ "$RC" -ne 0 ] \
  && ok "a conflicting pin in another cluster's tfvars refuses the build (rc=$RC)" \
  || bad "the build proceeded despite ${FIXTURE93##*/} pinning a different talos_version"
grep -q "${FIXTURE93##*/}" <<<"$OUT" \
  && ok "the message names the conflicting tfvars file" \
  || bad "the refusal does not name ${FIXTURE93##*/}"
grep -q 'v1.13.9' <<<"$OUT" && grep -q 'v1.13.4' <<<"$OUT" \
  && ok "the message names both the pinned version and the one being built" \
  || bad "the refusal does not name both versions"
[ ! -s "$LOG" ] \
  && ok "zero tofu/aws calls recorded — refusal happened before any spend" \
  || bad "tofu/aws were invoked despite the conflicting pin: $(cat "$LOG")"

echo "--- #93: a matching pin is not a false positive ---"
printf 'talos_version = "v1.13.4"\n' >"$FIXTURE93"
OUT="$(run 2 --ensure)"; RC=$?
is "the script completes when the fixture's pin matches the build" 0 "$RC"
grep -qi 'pins talos_version' <<<"$OUT" \
  && bad "a matching pin was refused as though it conflicted" \
  || ok "no conflict refusal when the tfvars pin matches the version being built"
is "the run proceeded past the guard (plan+apply as normal)" 1 "$(calls apply)"
rm -f "$FIXTURE93"

echo "--- floors: the stubs really ran (all of the above is vacuous otherwise) ---"
OUT="$(run 2 --ensure)"
[ "$(calls init)" -ge 1 ] && ok "tofu was invoked through the stub ($(wc -l <"$LOG") calls recorded)" \
                          || bad "ZERO tofu calls recorded — the script died before planning, and every assertion above measured nothing"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
