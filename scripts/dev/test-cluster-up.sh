#!/usr/bin/env bash
# ==============================================================================
# `task cluster-up` succeeds only when the verifier does (#84).
#
# The real Taskfile runs under the real go-task, from cluster-up's first guard to
# its closing line, in a throwaway copy of the repository layout. Only the leaves
# are stubs: tofu, and every script the journey calls except the S3 credential
# resolver. The verifier's exit code is the one input a case chooses.
#
# Offline, no credentials: the S3 keys the guards insist on are placeholders.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

TASK="$(command -v task)" || { echo "✗ task is required and not on PATH — nothing was checked" >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"
mkdir -p "$C/envs" "$C/bootstrap-manifests" "$W/scripts"/{internal,bootstrap,ops,dev,lib} "$W/bin"
cp Taskfile.yml "$W/"
cp scripts/lib/common.sh "$W/scripts/lib/"
cp scripts/internal/resolve-s3-cred.sh scripts/internal/check-passphrase.sh "$W/scripts/internal/"

# One stub behind every leaf: it logs "<name> <args>" in call order, then answers
# what the next step reads. A plan file must exist for infra-apply to take it.
cat >"$W/stub" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >>"$W/calls.log"
case "\$(basename "\$0") \$*" in
  "tofu plan"*) for a in "\$@"; do case "\$a" in -out=*) : >"\${a#-out=}" ;; esac; done ;;
  "tofu output -raw "*) echo "fixture-\$3" ;;
  # The real tofu, in a cluster directory whose backend was not initialised in THIS shell (lab 26, F1): it refuses unless
  # the task env (TF_DATA_DIR and the S3 credentials of *provider-env) is there.
  "tofu output -json cluster_identity")
    if [ -z "\${TF_DATA_DIR:-}" ] || [ -z "\${AWS_ACCESS_KEY_ID:-}" ] || [ -z "\${AWS_SECRET_ACCESS_KEY:-}" ]; then
      echo "Error: Backend initialization required, please run \"tofu init\"" >&2; exit 1
    fi
    echo '{}' ;;
  "talos-version.sh workload-"*) echo v0.0.1-fixture ;;
  talos-version.sh*) echo v0.0.0-fixture ;;
  tf-backend.sh*) echo -backend-config=path=fixture.tfstate ;;
  bootstrap-in-state.sh*) echo false ;;
  ssh-keygen*) exit 1 ;;
  infra-verify.sh*) echo "fixture verifier \$*: exit \${VERIFY_RC:?}"; exit "\$VERIFY_RC" ;;
  adopt-bootstrap.sh*) exit "\${ADOPT_RC:-0}" ;;
  # The real scripts run tofu from the cluster directory, as the task leaves them; so does the stub.
  cluster-identity-sync.sh*) (cd "$C" && tofu output -json cluster_identity >/dev/null) || { echo "✗ tofu output cluster_identity failed" >&2; exit 1; }
                             case "\$*" in *--apply*) exit "\${APPLY_RC:-0}" ;; *) exit "\${IDENTITY_RC:-0}" ;; esac ;;
  # The presync: a dry run answers PRESYNC_RC (3 = a difference) until an apply has run; then 0, "applied" being what the apply
  # does. REVERT_N makes Flux undo it: that many dry runs after an apply answer 3 again, as a reconcile of the OLD ref would.
  cnpg-presync.sh*--apply*) : >"$W/presync.applied"; echo "\$*" >>"$W/presync.args"; exit "\${PSAPPLY_RC:-0}" ;;
  cnpg-presync.sh*)
    if [ -e "$W/presync.applied" ]; then
      n=\$(cat "$W/presync.undone" 2>/dev/null || echo 0)
      if [ "\$n" -lt "\${REVERT_N:-0}" ]; then echo \$((n + 1)) >"$W/presync.undone"; exit 3; fi
      exit 0
    fi
    [ -n "\${PSAPPLY_RC:-}" ] && exit 3; exit "\${PRESYNC_RC:-0}" ;;
  cluster-coredns-ha.sh*--apply*) : >"$W/coredns.applied"; exit "\${COREDNS_APPLY_RC:-0}" ;;
  cluster-coredns-ha.sh*) [ -e "$W/coredns.applied" ] && exit 0; exit "\${COREDNS_RC:-0}" ;;
  cluster-apps-ref.sh*--apply*) exit "\${REFAPPLY_RC:-0}" ;;
  cluster-apps-ref.sh*) exit "\${REF_RC:-0}" ;;
  cluster-netcheck.sh*|cluster-security-tests.sh*) echo "\$(basename "\$0") KUBECONFIG=\${KUBECONFIG:-unset}" >>"$W/kc.log" ;;
  talos-image.sh*--retain*) echo "fixture retention \$*"; exit "\${RETAIN_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$W/stub"
for s in internal/talos-version.sh internal/ensure-buckets.sh internal/check-openbao-keys.sh internal/converge-versions.sh \
         internal/tf-backend.sh internal/bootstrap-in-state.sh internal/explain-failure.sh bootstrap/talos-image.sh \
         bootstrap/render-bootstrap-manifests.sh bootstrap/talos-tunnels.sh bootstrap/adopt-bootstrap.sh bootstrap/grow-nodes.sh internal/refuse-node-deletes.sh \
         ops/backup-state.sh ops/cnpg-presync.sh ops/cluster-coredns-ha.sh ops/cluster-identity-sync.sh ops/cluster-apps-ref.sh ops/cluster-netcheck.sh ops/cluster-security-tests.sh dev/infra-verify.sh; do
  ln -s "$W/stub" "$W/scripts/$s"
done
ln -s "$W/stub" "$W/bin/tofu"; ln -s "$W/stub" "$W/bin/ssh-keygen"
echo 'fixture: rendered' >"$C/bootstrap-manifests/cilium.yaml"
for e in management-scaleway workload-ovh; do echo 'cluster_name = "fixture"' >"$C/envs/$e.tfvars"; done
: >"$W/key"

O="$W/out"
run() { # PCHK=<mode> sets OA_PASSPHRASE_CHECK; <verifier rc> <task args...> — combined output in $O, calls in calls.log; EXTRA="NAME=value [NAME=value]" sets env vars, last, so it overrides the defaults; TTY=1 gives it a terminal that answers "yes" to every question
  local rc="$1"; shift
  local -a xtra=(); [ -n "${EXTRA:-}" ] && read -ra xtra <<<"$EXTRA"
  : >"$W/calls.log"; rm -f "$W/presync.applied" "$W/presync.undone" "$W/presync.args" "$W/coredns.applied"
  local cmd=(env -i PATH="$W/bin:$PATH" HOME="$W" VERIFY_RC="$rc" NO_COLOR=1
      TF_VAR_encryption_passphrase=fixture-passphrase-of-at-least-32-characters
      SCW_ACCESS_KEY=scw-access-key SCW_SECRET_KEY=scw-secret-key
      OVH_AWS_ACCESS_KEY_ID=ovh-access-key OVH_AWS_SECRET_ACCESS_KEY=ovh-secret-key
      ${PCHK:+OA_PASSPHRASE_CHECK="$PCHK"} "${xtra[@]}"
      "$TASK" -d "$W" "$@")
  if [ -n "${TTY:-}" ]; then
    { printf 'yes\n%.0s' $(seq 1 "${TTY_YES:-9}"); printf 'no\n%.0s' 1 2 3; } | script -qefc "$(printf '%q ' "${cmd[@]}")" /dev/null >"$O" 2>&1
    local st=$?; tr -d '\r' <"$O" >"$O.lf" && mv "$O.lf" "$O"; return "$st"
  fi
  "${cmd[@]}" </dev/null >"$O" 2>&1
}
calls() { grep -c "$1" "$W/calls.log"; }
# Last matching line; converge-versions' --check dry run is not the roll.
line_of() { grep -n "$2" "$1" | grep -v -- '--check$' | tail -1 | cut -d: -f1; }
tail_of() { tail -n 4 "$O" | tr '\n' ' '; }
# Phase 2 asks the nodes whether a bootstrap the state forgot already ran (#67): once,
# for this role then provider, after the tunnels it needs and before the plan that would
# re-send the RPC. A hardcoded role or provider reaches another cluster's tfvars.
adopted_once() { # <role> <provider>
  local t a p
  t="$(line_of "$W/calls.log" '^talos-tunnels.sh open')"; a="$(line_of "$W/calls.log" '^adopt-bootstrap.sh ')"
  p="$(line_of "$W/calls.log" '^tofu plan -out=phase2-')"
  [ "$(calls '^adopt-bootstrap.sh ')" = 1 ] && grep -qx "adopt-bootstrap.sh $1 $2" "$W/calls.log" \
    && [ -n "$t" ] && [ -n "$a" ] && [ -n "$p" ] && [ "$t" -lt "$a" ] && [ "$a" -lt "$p" ] \
    && ok "the adoption check runs once, for $1/$2 (role, then provider), between the tunnels and phase 2's plan" \
    || bad "adopt-bootstrap.sh was called $(calls '^adopt-bootstrap.sh ') times, got: $(grep '^adopt-bootstrap' "$W/calls.log"); tunnels at ${t:-none}, it at ${a:-none}, plan at ${p:-none}"
}
UP=(cluster-up KEY="$W/key" APPROVE=auto)


echo "--- a failing verifier fails cluster-up ---"
run 1 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && ok "cluster-up exits $rc" || bad "cluster-up exits 0 on a failing verifier"
grep -q 'cluster-up complete' "$O" \
  && bad "the success line was printed (or echoed) on a failing verifier" \
  || ok "the success line is nowhere in the output"
# Without this, a journey that died on an earlier step would pass both above.
# A plan that deletes a node is refused before the question and before any apply (the stub answers 0 here,
# the real script's verdicts are test-refuse-node-deletes.sh's).
r1="$(grep -n '^refuse-node-deletes.sh up-' "$W/calls.log" | head -1 | cut -d: -f1)"
pl="$(grep -n '^tofu plan -out=up-' "$W/calls.log" | head -1 | cut -d: -f1)"
ap="$(grep -n '^tofu apply up-' "$W/calls.log" | head -1 | cut -d: -f1)"
{ [ -n "$r1" ] && [ -n "$pl" ] && [ -n "$ap" ] && [ "$pl" -lt "$r1" ] && [ "$r1" -lt "$ap" ]; } \
  && ok "the node-delete guard runs after the plan is written and before anything is applied" \
  || bad "the node-delete guard is misplaced: plan at ${pl:-none}, guard at ${r1:-none}, apply at ${ap:-none}"
# Three places, none redundant: cluster-up before its question, infra-apply before its apply, phase 2 before its question.
{ [ "$(calls '^refuse-node-deletes.sh up-')" = 2 ] && [ "$(calls '^refuse-node-deletes.sh phase2-')" = 1 ]; } \
  && ok "the guard is called by cluster-up and infra-apply on the phase-1 plan, and by phase 2 on its own" \
  || bad "the guard was called: $(grep '^refuse-node-deletes' "$W/calls.log" | tr '\n' '|')"
# Without a terminal the phase-1 checkpoint is the end of the road for cluster-up (infra #381): its stop message must name the
# command that reaches phase 2, and phase 2's own stop must name what follows it.
grep -q 'task bootstrap-phase2 ROLE={{.ROLE}} PROVIDER={{.PROVIDER}}' Taskfile.yml \
  && grep -q "Then: task kubeconfig" Taskfile.yml \
  && ok "both no-terminal stop messages name the next command (task bootstrap-phase2, then task kubeconfig)" \
  || bad "a no-terminal stop message does not name the next command"
[ "$(calls '^infra-verify.sh ')" = 1 ] && grep -qx 'infra-verify.sh scaleway management' "$W/calls.log" \
  && ok "the verifier ran once, for scaleway/management — it is what failed the run" \
  || bad "the verifier was not what failed: $(tail_of)"
adopted_once management scaleway


echo "--- a passing verifier lets cluster-up say so ---"
# Both variables differ from the case above, so a hardcoded one cannot pass.
run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
[ "$rc" = 0 ] && ok "cluster-up exits 0" || bad "cluster-up exits $rc: $(tail_of)"
grep -qx 'infra-verify.sh ovh workload' "$W/calls.log" \
  && ok "ROLE and PROVIDER reach the verifier" \
  || bad "the verifier got: $(grep '^infra-verify' "$W/calls.log")"
v="$(line_of "$O" '^fixture verifier')"; s="$(line_of "$O" '^✓ cluster-up complete')"
[ -n "$v" ] && [ -n "$s" ] && [ "$s" -gt "$v" ] \
  && ok "the success line is printed, after the verifier's verdict" \
  || bad "verifier at line ${v:-none}, success line at ${s:-none}"
adopted_once workload ovh
# The roll needs a kubeconfig, and so does the verifier after it: every cluster in
# the checkout writes the same path, so the verifier must not trust the pre-roll copy.
K='^tofu output -raw kubeconfig'
k1="$(grep -n "$K" "$W/calls.log" | head -1 | cut -d: -f1)"; k2="$(line_of "$W/calls.log" "$K")"
c="$(line_of "$W/calls.log" '^converge-versions.sh ')"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"
# The identity and apps-ref TASKS fetch it too (lab 26, F1), so "at least two": one before the roll, the last after it.
[ "$(calls "$K")" -ge 2 ] && [ -n "$c" ] && [ -n "$i" ] && [ "${k1:-0}" -lt "$c" ] && [ "$c" -lt "${k2:-0}" ] && [ "$k2" -lt "$i" ] \
  && ok "kubeconfig is fetched before the roll, and again between the roll and the verifier" \
  || bad "fetches: $(calls "$K"), first ${k1:-none}, last ${k2:-none}; roll at ${c:-none}; verify at ${i:-none}"


echo "--- old images: pruned after the verdict, only where someone can answer, never fatal ---"
RET='^talos-image.sh .*--retain'
HINT='~ images below the cluster'"'"'s version and the one under it are pruned by a person, not here:'
# APPROVE=auto never answers a destroy, so it is left, and said.
run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
{ [ "$rc" = 0 ] && [ "$(calls "$RET")" = 0 ] && grep -qxF "$HINT" "$O" \
    && grep -qx '    task image-build PROVIDER=ovh ROLE=workload RETAIN=1' "$O"; } \
  && ok "APPROVE=auto, unattended: nothing is pruned, and the command that does it is named for this role and provider" \
  || bad "unattended retention: exit $rc, retention calls $(calls "$RET"): $(tail_of)"
TTY=1 run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
{ [ "$rc" = 0 ] && [ "$(calls "$RET")" = 0 ] && grep -qxF "$HINT" "$O"; } \
  && ok "APPROVE=auto on a terminal is no more allowed to destroy" \
  || bad "APPROVE=auto reached a destroy, or the run failed: exit $rc, retention calls $(calls "$RET")"
# A real terminal, a person answering: the same journey with the question asked.
ASK=(cluster-up KEY="$W/key" APPROVE=ask)
TTY=1 run 0 "${ASK[@]}" PROVIDER=ovh ROLE=workload; rc=$?
[ "$rc" = 0 ] && grep -q '^✓ cluster-up complete' "$O" \
  && ok "control: the asked journey completes on a terminal (the retention below runs inside it)" \
  || bad "control: the asked journey did not complete (exit $rc): $(tail_of)"
{ [ "$(calls "$RET")" = 1 ] && grep -qx 'talos-image.sh ovh --retain' "$W/calls.log"; } \
  && ok "with a terminal and no APPROVE=auto it prunes once, with no version: the lane ranks what it holds" \
  || bad "retention was called $(calls "$RET") times: $(grep '^talos-image' "$W/calls.log" | tr '\n' '|')"
v="$(line_of "$W/calls.log" '^infra-verify.sh')"; r="$(line_of "$W/calls.log" "$RET")"
{ [ -n "$v" ] && [ -n "$r" ] && [ "$r" -gt "$v" ]; } \
  && ok "after the verifier, not before: until N is verified, N-1's image is the one still needed" \
  || bad "verifier at ${v:-none}, retention at ${r:-none}"
r="$(line_of "$O" '^fixture retention')"; s="$(line_of "$O" '^✓ cluster-up complete')"
{ [ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ]; } \
  && ok "and before the closing success line, which stays the last thing the operator reads" \
  || bad "retention printed at line ${r:-none}, the success line at ${s:-none}"
{ ! grep -qxF "$HINT" "$O" && ! grep -q '^⚠ image retention' "$O"; } \
  && ok "and a retention that succeeds says nothing of the unattended hint or of a failure" \
  || bad "a successful retention printed the unattended hint or a warning: $(tail_of)"
# Not fatal: a verified cluster is not a failed one over a leftover image.
EXTRA=RETAIN_RC=1 TTY=1 run 0 "${ASK[@]}" PROVIDER=ovh ROLE=workload; rc=$?
{ [ "$rc" = 0 ] && grep -q '^✓ cluster-up complete' "$O" && grep -q '^⚠ image retention did not finish' "$O" \
    && grep -qx '    task image-build PROVIDER=ovh ROLE=workload RETAIN=1' "$O"; } \
  && ok "a retention that fails warns with the command to run again, and cluster-up still exits 0" \
  || bad "a failing retention changed cluster-up's verdict or said nothing (exit $rc): $(tail_of)"
# A name that generic is often exported for something else; RETAIN takes no version, and the script refuses one.
EXTRA=VERSION=v9.9.9 TTY=1 run 0 "${ASK[@]}" PROVIDER=ovh ROLE=workload; rc=$?
{ [ "$rc" = 0 ] && grep -qx 'talos-image.sh ovh --retain' "$W/calls.log"; } \
  && ok "an exported VERSION does not reach the retention" || bad "VERSION reached the retention (exit $rc): $(grep '^talos-image' "$W/calls.log" | tr '\n' '|')"
# An exported RETAIN would turn the BUILD into a retention, which the script refuses: cluster-up blanks it, as VERSION.
EXTRA=RETAIN=1 run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
{ [ "$rc" = 0 ] && [ "$(calls "$RET")" = 0 ] && grep -q '^talos-image.sh ovh .*--ensure' "$W/calls.log"; } \
  && ok "an exported RETAIN=1 does not reach cluster-up's image build" || bad "RETAIN reached the build (exit $rc): $(grep '^talos-image' "$W/calls.log" | tr '\n' '|')"
TTY=1 run 1 "${ASK[@]}" PROVIDER=ovh ROLE=workload; rc=$?
{ [ "$rc" != 0 ] && [ "$(calls "$RET")" = 0 ] && ! grep -q '^~ images below' "$O"; } \
  && ok "a failing verifier prunes nothing" || bad "retention ran after a failed verdict (exit $rc, calls $(calls "$RET"))"

echo "--- a failing adoption stops phase 2 before its plan ---"
# The script exits 1 only after etcd answered and its import failed: planning on would
# re-send the Bootstrap it exists to prevent.
EXTRA=ADOPT_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && [ "$(calls '^adopt-bootstrap.sh ')" = 1 ] && ok "cluster-up exits $rc after the adoption failed" \
  || bad "exit $rc, adoption calls: $(calls '^adopt-bootstrap.sh ')"
[ "$(calls '^tofu plan -out=phase2-')" = 0 ] && [ "$(calls '^tofu apply phase2-')" = 0 ] \
  && ok "phase 2 never planned nor applied" \
  || bad "phase 2 went on: $(grep -E '^tofu (plan -out=phase2-|apply phase2-)' "$W/calls.log" | tr '\n' '|')"
[ "$(calls '^infra-verify.sh ')" = 0 ] && ! grep -q 'cluster-up complete' "$O" \
  && ok "the verifier is not reached and no success line is printed" \
  || bad "the journey went on: $(tail_of)"


echo "--- the image is the one ROLE's tfvars pins ---"
# Only the workload pin differs from the management one, so a build that
# ignored ROLE would take the management image.
run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
[ "$rc" = 0 ] && grep -qx 'talos-image.sh ovh v0.0.1-fixture --ensure' "$W/calls.log" \
  && ok "a workload cluster builds the workload pin" \
  || bad "exit $rc; the build was: $(grep '^talos-image' "$W/calls.log")"
# VERSION is not a cluster-up option, and a name that generic is often exported
# for something else: neither form may steer the image.
for how in env cli; do
  if [ "$how" = env ]; then EXTRA=VERSION=v9.9.9 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
  else run 0 "${UP[@]}" PROVIDER=scaleway VERSION=v9.9.9; rc=$?; fi
  [ "$rc" = 0 ] && grep -qx 'talos-image.sh scaleway v0.0.0-fixture --ensure' "$W/calls.log" \
    && ok "VERSION given as $how is ignored: the pin is built" \
    || bad "VERSION as $how, exit $rc; the build was: $(grep '^talos-image' "$W/calls.log")"
done


echo "--- a bad passphrase is refused before the buckets are created ---"
# ensure-buckets creates the buckets and the image build follows: neither may have run.
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
# (infra-apply calls it again later, so the control counts the --preflight call.)
[ "$rc" = 0 ] && [ "$(calls '^ensure-buckets.sh .*--preflight$')" = 1 ] \
  && ok "control: a good passphrase reaches the preflight ensure-buckets once" \
  || bad "control, exit $rc, preflight calls $(calls '^ensure-buckets.sh .*--preflight$'): $(tail_of)"
# The OpenBao recovery-share keys are checked in the same pre-flight, before the buckets and before anything bills.
[ "$(calls '^check-openbao-keys.sh .*management-scaleway.tfvars$')" = 1 ] \
  && [ "$(awk '/^check-openbao-keys.sh /{k=NR} /^ensure-buckets.sh .*--preflight$/{b=NR} END{print (k && b && k < b) ? "yes" : "no"}' "$W/calls.log")" = yes ] \
  && ok "the recovery-share keys are checked once, before the preflight ensure-buckets" \
  || bad "check-openbao-keys.sh calls: $(calls '^check-openbao-keys.sh ') / order: $(grep -nE '^(check-openbao-keys|ensure-buckets)' "$W/calls.log" | head -3 | tr '\n' ' ')"
for c in "|is not set" "change-me-fixture-passphrase|is still the example"; do
  EXTRA="TF_VAR_encryption_passphrase=${c%%|*}" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
  # Anchored: go-task echoes the whole script into $O, so an unanchored match is always true.
  [ "$rc" != 0 ] && grep -q "^✗ TF_VAR_encryption_passphrase ${c#*|}" "$O" \
    && [ "$(calls '^ensure-buckets.sh ')" = 0 ] && [ "$(calls '^talos-image.sh ')" = 0 ] \
    && ok "passphrase '${c%%|*}': refused, nothing built" \
    || bad "passphrase '${c%%|*}', exit $rc, ensure-buckets $(calls '^ensure-buckets.sh '), image $(calls '^talos-image.sh '): $(tail_of)"
done
# A weak passphrase (not the placeholder) is a warning by default and a refusal only under OA_PASSPHRASE_CHECK=enforce.
EXTRA="TF_VAR_encryption_passphrase=correct-horse-battery-staple-32chars" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && grep -q "^⚠ TF_VAR_encryption_passphrase looks weak" "$O" \
  && ok "a low-diversity passphrase: warned, and the run goes on (default mode)" \
  || bad "weak passphrase, default mode, exit $rc: $(tail_of)"
PCHK=enforce EXTRA="TF_VAR_encryption_passphrase=correct-horse-battery-staple-32chars" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && grep -q "^✗ TF_VAR_encryption_passphrase looks weak" "$O" \
  && [ "$(calls '^ensure-buckets.sh ')" = 0 ] && [ "$(calls '^talos-image.sh ')" = 0 ] \
  && ok "OA_PASSPHRASE_CHECK=enforce: the same passphrase is refused, nothing built" \
  || bad "weak passphrase, enforce, exit $rc, ensure-buckets $(calls '^ensure-buckets.sh '): $(tail_of)"

echo "--- cluster-verify on its own still refreshes kubeconfig ---"
run 0 cluster-verify PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && [ "$(calls '^tofu output -raw kubeconfig')" = 1 ] && [ "$(calls '^infra-verify.sh ')" = 1 ] \
  && ok "one refresh, then the verifier — a cold shell still verifies" \
  || bad "exit $rc, refreshes $(calls '^tofu output -raw kubeconfig'), verifier $(calls '^infra-verify.sh ')"
[ "$(stat -c %a "$C/kubeconfig" "$C/talosconfig" 2>/dev/null | sort -u)" = 600 ] \
  && ok "kubeconfig and talosconfig are written 0600" || bad "modes: $(stat -c '%n %a' "$C/kubeconfig" "$C/talosconfig" 2>&1 | tr '\n' ' ')"


echo "--- cluster-identity: a ConfigMap that differs is written or the run fails, never green over it (lab 25, D9) ---"
ID='^cluster-identity-sync.sh'
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
c="$(line_of "$W/calls.log" '^converge-versions.sh ')"; d="$(line_of "$W/calls.log" "$ID")"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"
[ "$rc" = 0 ] && [ "$(calls "$ID")" = 1 ] && [ "$(calls "$ID --apply")" = 0 ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$i" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$i" ] \
  && ok "in sync: one dry run, after the roll and before the verifier, nothing written" \
  || bad "exit $rc, calls: $(grep -c "$ID" "$W/calls.log"), roll ${c:-none}, sync ${d:-none}, verify ${i:-none}"
EXTRA=IDENTITY_RC=3 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && [ "$(calls "$ID --apply")" = 1 ] && ok "APPROVE=auto and a difference: it is written, the run goes on" \
  || bad "exit $rc, applies $(calls "$ID --apply"): $(tail_of)"
EXTRA=APPLY_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && ok "(control) a sync that was not asked to apply does not fail the run" || bad "control exit $rc"
EXTRA=IDENTITY_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && ! grep -q 'cluster-up complete' "$O" && ok "a sync failure fails cluster-up" || bad "exit $rc"
EXTRA=IDENTITY_RC=4 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && [ "$(calls "$ID --apply")" = 0 ] && ok "ConfigMap not there yet (exit 4): a warning, not a failure" || bad "exit $rc"
TTY=1 EXTRA=IDENTITY_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway; rc=$?
[ "$(calls "$ID --apply")" = 1 ] && grep -q 'Write these cluster-identity keys' "$O" && ok "at a terminal it asks, and writes on yes" || bad "exit $rc, applies $(calls "$ID --apply"): $(tail_of)"


echo "--- F1 (lab 26): the steps run through the TASKS, so tofu has its backend and credentials; the messages name the exact command ---"
# The env of run() holds no TF_DATA_DIR and no AWS_* variable. The stub tofu refuses `output` without them, as the real one does.
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && grep -q '^tofu output -json cluster_identity' "$W/calls.log" \
  && ok "cluster-up resolved the backend and the S3 credentials for the identity step (tofu output answered)" \
  || bad "exit $rc, identity step without the provider env: $(grep -h 'Backend\|failed' "$O" | head -2 | tr '\n' ' ')"
TTY=1 TTY_YES=2 EXTRA=IDENTITY_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway ROLE=management; rc=$?
[ "$rc" != 0 ] && grep -qF '    task cluster-identity-sync PROVIDER=scaleway ROLE=management APPLY=1' "$O" && grep -q 'shows it as 201' "$O" \
  && ok "an answer other than yes: the failure names the command with PROVIDER and ROLE filled in, and says 201" \
  || bad "exit $rc: $(tail_of)"
TTY=1 TTY_YES=2 EXTRA=REF_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway ROLE=management; rc=$?
[ "$rc" != 0 ] && grep -qF '    task cluster-apps-ref PROVIDER=scaleway ROLE=management APPLY=1' "$O" && grep -q 'shows it as 201' "$O" \
  && ok "the same for the apps ref" || bad "exit $rc: $(tail_of)"
EXTRA=IDENTITY_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway ROLE=management; rc=$?
[ "$rc" != 0 ] && grep -qF 'task cluster-identity-sync PROVIDER=scaleway ROLE=management' "$O" && grep -q 'failed (exit 1)' "$O" \
  && ok "any other failure keeps its own exit code in the message and names the command to run alone" || bad "exit $rc: $(tail_of)"


echo "--- CNPG presync (study LAB-B2): synchronous replication is enabled BEFORE the apps ref moves, or the run fails ---"
PS='^cnpg-presync.sh'
PSA='^cnpg-presync.sh --tfvars [^ ]* .*--apply'
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
c="$(line_of "$W/calls.log" '^converge-versions.sh ')"; p="$(line_of "$W/calls.log" "$PS")"; a="$(line_of "$W/calls.log" '^cluster-apps-ref.sh')"
d="$(line_of "$W/calls.log" '^cluster-identity-sync.sh')"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"
[ "$rc" = 0 ] && [ "$(calls "$PS")" = 1 ] && [ "$(calls "$PSA")" = 0 ] && [ -n "$p" ] && [ "$c" -lt "$p" ] && [ "$p" -lt "$a" ] && [ "$p" -lt "$d" ] && [ "$a" -lt "$i" ] \
  && ok "nothing to presync (exit 0): one dry run, after the roll and BEFORE the apps ref and the identity steps, nothing written" \
  || bad "exit $rc, calls $(calls "$PS"), roll ${c:-none}, presync ${p:-none}, apps-ref ${a:-none}, identity ${d:-none}"
! grep -qE '^(CNPG Clusters|✓ synchronous|✗ .*(cnpg|CNPG))' "$O" && ok "and it is quiet: a new cluster's bring-up never mentions it" || bad "output mentions the presync: $(grep -E '^(CNPG|✓ synch|✗)' "$O" | head -2)"
K='^tofu output -raw kubeconfig'
[ "$(awk -v p="$p" -v k="$K" 'NR < p && $0 ~ k' "$W/calls.log" | wc -l)" -ge 2 ] \
  && ok "the TASK ran the script: the kubeconfig was fetched again before it (lab 26, F1)" || bad "kubeconfig fetches before the presync: $(grep -n "$K" "$W/calls.log" | tr '\n' ' ')"
EXTRA=PRESYNC_RC=3 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
p2="$(line_of "$W/calls.log" "$PSA")"; a="$(line_of "$W/calls.log" '^cluster-apps-ref.sh')"
[ "$rc" = 0 ] && [ "$(calls "$PSA")" = 1 ] && [ -n "$p2" ] && [ "$p2" -lt "$a" ] && ok "APPROVE=auto and a difference: it is applied, before the apps ref, and the run goes on" || bad "exit $rc, applies $(calls "$PSA"): $(tail_of)"
run 0 cluster-up KEY="$W/key" PROVIDER=ovh ROLE=workload APPROVE=auto; rc=$?
grep -qx 'cnpg-presync.sh --tfvars envs/workload-ovh.tfvars' "$W/calls.log" && ok "ROLE and PROVIDER reach the script (the tfvars of this cluster)" || bad "calls: $(grep '^cnpg-presync' "$W/calls.log")"
TTY=1 TTY_YES=2 EXTRA=PRESYNC_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway ROLE=management; rc=$?
[ "$rc" != 0 ] && grep -q 'Enable synchronous replication on these CNPG Clusters' "$O" && grep -qF '    task cnpg-presync PROVIDER=scaleway ROLE=management APPLY=1 SCALE=1' "$O" && [ "$(calls "$PSA")" = 0 ] && [ "$(calls '^cluster-apps-ref.sh')" = 0 ] \
  && ok "at a terminal an answer other than yes: it fails naming the command, apps ref untouched" || bad "exit $rc: $(tail_of)"
TTY=1 EXTRA=PRESYNC_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway; rc=$?
[ "$(calls "$PSA")" = 1 ] && grep -q 'Enable synchronous replication on these CNPG Clusters' "$O" && ok "at a terminal it asks, and applies on yes" || bad "exit $rc, applies $(calls "$PSA"): $(tail_of)"
EXTRA=PSAPPLY_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && [ "$(calls '^cluster-apps-ref.sh')" = 0 ] && ! grep -q 'cluster-up complete' "$O" && ok "an apply that fails (timeout, break-glass printed) fails cluster-up before the apps ref" || bad "exit $rc, apps-ref calls $(calls '^cluster-apps-ref.sh')"
for r in 1 2; do
  EXTRA=PRESYNC_RC=$r run 0 "${UP[@]}" PROVIDER=scaleway ROLE=management; rc=$?
  [ "$rc" != 0 ] && grep -q "cnpg-presync failed (exit $r)" "$O" && grep -qF 'task cnpg-presync PROVIDER=scaleway ROLE=management' "$O" && [ "$(calls '^cluster-apps-ref.sh')" = 0 ] \
    && ok "exit $r ($([ "$r" = 2 ] && echo a refusal || echo a failure)): cluster-up fails, names the command to run alone, the apps ref is not reached" || bad "exit $rc: $(tail_of)"
done

echo "--- FA (lab 27): the presync and the apps ref move back to back; SCALE under APPROVE=auto; the presync is read again before the ref moves ---"
APPLYREF='^cluster-apps-ref.sh --tfvars [^ ]* --apply'
EXTRA=PRESYNC_RC=3 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
pa="$(grep -n "$PSA" "$W/calls.log" | head -1 | cut -d: -f1)"; ra="$(line_of "$W/calls.log" "$APPLYREF")"
d="$(line_of "$W/calls.log" '^cluster-identity-sync.sh')"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"
between="$(sed -n "$((pa + 1)),$((ra - 1))p" "$W/calls.log" | grep -E '^(cluster-identity-sync|converge-versions|infra-verify|cluster-coredns-ha|tofu (plan|apply))' || true)"
{ [ "$rc" = 0 ] && [ -n "$pa" ] && [ -n "$ra" ] && [ "$pa" -lt "$ra" ] && [ "$ra" -lt "$d" ] && [ -z "$between" ]; } \
  && ok "the presync apply and the apps-ref apply are back to back: only a dry-run re-read of the presync and the kubeconfig fetch between them, the identity step after" \
  || bad "exit $rc, presync apply at ${pa:-none}, ref apply at ${ra:-none}, identity at ${d:-none}, between: $(tr '\n' '|' <<<"$between")"
grep -q -- '--scale --apply' "$W/calls.log" \
  && ok "APPROVE=auto and a Cluster below 3 instances: the presync is applied with --scale (the head declares 3), not stopped" \
  || bad "no --scale on the presync apply: $(grep '^cnpg-presync' "$W/calls.log" | tr '\n' '|')"
{ [ "$(calls '^cluster-apps-ref.sh')" = 2 ] && [ "$(calls "$APPLYREF")" = 1 ]; } \
  && ok "the move is done once: the later ref step is a dry run that finds it in sync" || bad "ref calls: $(grep '^cluster-apps-ref' "$W/calls.log" | tr '\n' '|')"
# Flux, still on the old ref, undoes the presync between the apply and the ref move: it is applied again, and only then does the ref move.
EXTRA="PRESYNC_RC=3 REVERT_N=1" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
ra="$(line_of "$W/calls.log" "$APPLYREF")"; last_pa="$(grep -n "$PSA" "$W/calls.log" | tail -1 | cut -d: -f1)"
{ [ "$rc" = 0 ] && [ "$(calls "$PSA")" = 2 ] && [ -n "$ra" ] && [ "$last_pa" -lt "$ra" ] && grep -q '^~ the presync was undone' "$O"; } \
  && ok "a presync undone before the ref moved is applied again, and the ref moves after the second apply" \
  || bad "exit $rc, presync applies $(calls "$PSA"), last apply at ${last_pa:-none}, ref at ${ra:-none}: $(tail_of)"
EXTRA="PRESYNC_RC=3 REVERT_N=9" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
{ [ "$rc" != 0 ] && [ "$(calls "$APPLYREF")" = 0 ] && grep -q 'apps ref was NOT moved' "$O" && ! grep -q 'cluster-up complete' "$O"; } \
  && ok "a presync that never holds fails cluster-up with the apps ref untouched" \
  || bad "exit $rc, ref applies $(calls "$APPLYREF"): $(tail_of)"
EXTRA="PRESYNC_RC=3 REFAPPLY_RC=1" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
{ [ "$rc" != 0 ] && grep -qF '    task cnpg-presync PROVIDER=scaleway ROLE=management APPLY=1 SCALE=1' "$O" \
    && grep -qF '    task cluster-apps-ref PROVIDER=scaleway ROLE=management APPLY=1' "$O" && [ "$(calls '^infra-verify.sh')" = 0 ]; } \
  && ok "a ref move that fails after the presync fails the run and names both commands, to be run back to back" \
  || bad "exit $rc: $(tail_of)"
# A typed yes answers the combined step once: the presync (scaled) and the ref move follow, then the run goes on.
TTY=1 EXTRA=PRESYNC_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway APPROVE=ask; rc=$?
{ [ "$rc" = 0 ] && grep -q 'then move the apps ref at once' "$O" && [ "$(calls "$APPLYREF")" = 1 ] && grep -q -- '--scale --apply' "$W/calls.log"; } \
  && ok "at a terminal one 'yes' answers the combined step: scaled presync, then the ref move" || bad "exit $rc, ref applies $(calls "$APPLYREF"): $(tail_of)"
# A refusal other than the instance count still fails: --scale is all auto adds.
EXTRA=PSAPPLY_RC=2 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
{ [ "$rc" != 0 ] && [ "$(calls "$APPLYREF")" = 0 ]; } && ok "a presync refusal under APPROVE=auto (exit 2) fails the run, the ref does not move" || bad "exit $rc"

echo "--- FB (lab 27): the CoreDNS shape is converged INSIDE cluster-up, before the verifier ---"
CD='^cluster-coredns-ha.sh'
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
{ [ "$rc" = 0 ] && [ "$(calls "$CD")" = 1 ] && [ "$(calls "$CD --tfvars [^ ]* --apply")" = 0 ]; } \
  && ok "in the declared shape: one dry run, nothing written, nothing asked" || bad "exit $rc, calls $(calls "$CD"): $(tail_of)"
EXTRA=COREDNS_RC=3 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
c="$(line_of "$W/calls.log" "$CD --tfvars [^ ]* --apply")"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"; a="$(line_of "$W/calls.log" '^cluster-apps-ref.sh')"
{ [ "$rc" = 0 ] && [ -n "$c" ] && [ "$a" -lt "$c" ] && [ "$c" -lt "$i" ]; } \
  && ok "APPROVE=auto and a difference: patched after the apps ref and BEFORE the verifier, the run ends 0" \
  || bad "exit $rc, patch at ${c:-none}, apps ref ${a:-none}, verify ${i:-none}: $(tail_of)"
EXTRA=COREDNS_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=ovh ROLE=workload APPROVE=auto
grep -qx 'cluster-coredns-ha.sh --tfvars envs/workload-ovh.tfvars' "$W/calls.log" && ok "ROLE and PROVIDER reach the script (the tfvars of this cluster)" || bad "calls: $(grep '^cluster-coredns' "$W/calls.log")"
TTY=1 EXTRA=COREDNS_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway APPROVE=ask; rc=$?
{ [ "$(calls "$CD --tfvars [^ ]* --apply")" = 1 ] && grep -q 'Patch the CoreDNS Deployment' "$O"; } && ok "at a terminal it asks, and patches on yes" || bad "exit $rc: $(tail_of)"
TTY=1 TTY_YES=2 EXTRA=COREDNS_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway ROLE=management APPROVE=ask; rc=$?
{ [ "$rc" != 0 ] && [ "$(calls "$CD --tfvars [^ ]* --apply")" = 0 ] && grep -qF '    task cluster-coredns-ha PROVIDER=scaleway ROLE=management APPLY=1' "$O"; } \
  && ok "an answer other than yes: nothing patched, the command named" || bad "exit $rc: $(tail_of)"
EXTRA=COREDNS_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
{ [ "$rc" != 0 ] && grep -q 'cluster-coredns-ha failed (exit 1)' "$O" && [ "$(calls '^infra-verify.sh')" = 0 ]; } \
  && ok "a failure of the step fails cluster-up before the verifier" || bad "exit $rc"

echo "--- K3 (lab 26): cluster-netcheck and cluster-security hand their script a KUBECONFIG ---"
: >"$W/kc.log"
run 0 cluster-netcheck PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && grep -qx "cluster-netcheck.sh KUBECONFIG=$C/kubeconfig" "$W/kc.log" \
  && ok "cluster-netcheck: the script sees this cluster's kubeconfig in a shell that exported none" \
  || bad "netcheck exit $rc, saw: $(tr '\n' ' ' <"$W/kc.log")"
: >"$W/kc.log"
EXTRA=KUBECONFIG=/elsewhere/other-cluster run 0 cluster-netcheck PROVIDER=scaleway; rc=$?
grep -qx "cluster-netcheck.sh KUBECONFIG=$C/kubeconfig" "$W/kc.log" \
  && ok "cluster-netcheck: an exported KUBECONFIG of another cluster is not followed" || bad "netcheck followed the caller: $(tr '\n' ' ' <"$W/kc.log")"
: >"$W/kc.log"
run 0 cluster-security; rc=$?
[ "$rc" = 0 ] && grep -qx "cluster-security-tests.sh KUBECONFIG=$W/infrastructure/opentofu/cluster/kubeconfig" "$W/kc.log" \
  && ok "cluster-security: KUBECONFIG defaults to this checkout's cluster" || bad "security exit $rc, saw: $(tr '\n' ' ' <"$W/kc.log")"
: >"$W/kc.log"
EXTRA=KUBECONFIG=/elsewhere/other-cluster run 0 cluster-security; rc=$?
grep -qx "cluster-security-tests.sh KUBECONFIG=/elsewhere/other-cluster" "$W/kc.log" \
  && ok "cluster-security: the caller's own KUBECONFIG wins" || bad "security overrode the caller: $(tr '\n' ' ' <"$W/kc.log")"


echo "--- apps ref: a live ref that differs from git_ref is moved or the run fails, never green over it (infra #408) ---"
AR='^cluster-apps-ref.sh'
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
c="$(line_of "$W/calls.log" '^converge-versions.sh ')"; d="$(line_of "$W/calls.log" "$AR")"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"
[ "$rc" = 0 ] && [ "$(calls "$AR")" = 1 ] && [ "$(calls "$AR --tfvars [^ ]* --apply")" = 0 ] && [ -n "$d" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$i" ] \
  && ok "in sync: one dry run, after the roll and before the verifier, nothing written" || bad "exit $rc, sync ${d:-none}"
EXTRA=REF_RC=3 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && [ "$(calls "$AR --tfvars [^ ]* --apply")" = 1 ] && ok "APPROVE=auto and a difference: the ref is moved, the run goes on" || bad "exit $rc: $(tail_of)"
EXTRA=REF_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && ! grep -q 'cluster-up complete' "$O" && ok "a failure of the ref sync fails cluster-up" || bad "exit $rc"
EXTRA=REF_RC=2 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && ok "a refusal (exit 2) fails cluster-up" || bad "exit $rc"
EXTRA=REF_RC=4 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && [ "$(calls "$AR --tfvars [^ ]* --apply")" = 0 ] && ok "no GitRepository (exit 4): a note, not a failure" || bad "exit $rc"
TTY=1 EXTRA=REF_RC=3 run 0 cluster-up KEY="$W/key" PROVIDER=scaleway; rc=$?
[ "$(calls "$AR --tfvars [^ ]* --apply")" = 1 ] && grep -q 'Point the live GitRepository' "$O" && ok "at a terminal it asks, and moves on yes" || bad "exit $rc: $(tail_of)"
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
grep -q 'cluster-up did NOT change' "$O" && grep -q 'cluster-bootstrap-sync' "$O" && grep -q 'CAPI child' "$O" \
  && ok "the end of cluster-up says what it did NOT change" || bad "no 'did NOT change' statement: $(tail_of)"


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
